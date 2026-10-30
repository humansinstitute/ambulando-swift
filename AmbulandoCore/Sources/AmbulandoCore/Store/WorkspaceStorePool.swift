import Foundation
import SQLite3

/// The legacy file is a discovery/configuration catalog only. Content lives in immutable-boundary partitions.
/// See docs/multi-workspace-storage.md for ownership and recovery policy.
public actor WorkspaceStorePool {
    public let directory: URL
    public let legacyBackupURL: URL
    private let catalog: LocalStore
    private var backup: Task<URL, Error>?
    private var stores: [String: Task<LocalStore, Error>] = [:]
    private var connectionIDs: [String: String] = [:]
    private var cacheRestores: [String: Task<Int, Error>] = [:]
    private var cacheRestoreStores: [String: LocalStore] = [:]
    private var removingConnections: Set<String> = []

    public init(catalog: LocalStore, directory: URL) {
        self.catalog = catalog
        self.directory = directory
        legacyBackupURL = directory.appendingPathComponent("legacy-cache-v1.sqlite")
    }

    public func store(connection: ConnectionRecord, workspace: WorkspaceRecord) async throws -> LocalStore {
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        guard !removingConnections.contains(boundary.connectionNamespace) else { throw CancellationError() }
        if let canonical = connectionIDs[boundary.id], canonical != connection.id {
            throw SQLiteError(code: -1, message: "Use the catalog's canonical connection for this workspace")
        }
        if let existing = stores[boundary.id] { return try await existing.value }
        let directory = self.directory, catalog = self.catalog
        let backupTask: Task<URL, Error>
        if let backup { backupTask = backup }
        else {
            let destination = legacyBackupURL
            backupTask = Task { try await catalog.writer.preserveLegacyBackup(at: destination); return destination }
            backup = backupTask
        }
        let task = Task<LocalStore, Error> {
            let source = try await backupTask.value
            let store = try LocalStore(directory: directory.appendingPathComponent(boundary.id, isDirectory: true))
            let canonical = try await store.writer.saveConnection(connection)
            guard canonical.id == connection.id else {
                throw SQLiteError(code: -1, message: "Workspace partition belongs to another local connection identifier")
            }
            try await store.writer.replaceWorkspaces(connectionId: connection.id, [workspace])
            try await store.writer.importLegacyPartition(from: source, connection: connection, workspace: workspace, boundary: boundary)
            return store
        }
        connectionIDs[boundary.id] = connection.id
        stores[boundary.id] = task
        do { return try await task.value }
        catch { stores[boundary.id] = nil; connectionIDs[boundary.id] = nil; backup = nil; throw error }
    }

    /// Restores only uniquely attributed, hash-verified downloaded files. Legacy bytes remain available for recovery.
    /// Bounded metadata pages and streaming hashes keep large histories/files off the main actor and bounded in memory.
    @discardableResult
    public func restoreFileCache(store: LocalStore, workspace: WorkspaceRecord, legacy: FileCache, destination: FileCache) async throws -> Int {
        let key = WorkspaceBoundary.digest([store.path, destination.root.path])
        if let restoring = cacheRestores[key] { return try await restoring.value }
        let task = Task { try await Self.restoreFiles(store: store, workspace: workspace, legacy: legacy, destination: destination) }
        cacheRestores[key] = task
        cacheRestoreStores[key] = store
        defer { cacheRestores[key] = nil; cacheRestoreStores[key] = nil }
        return try await task.value
    }

    private static func restoreFiles(store: LocalStore, workspace: WorkspaceRecord, legacy: FileCache, destination: FileCache) async throws -> Int {
        guard try await store.reader.state("partition.legacy-cache") == "imported" else { return 0 }
        let marker = "partition.file-cache-restored.v1"
        if try await store.reader.state(marker) != nil { return 0 }
        var after = "", restored = 0
        while true {
            try Task.checkCancellation()
            let files = try await store.reader.fileCacheMigrationPage(workspaceId: workspace.id, after: after)
            if files.isEmpty { break }
            for file in files {
                try Task.checkCancellation()
                guard let sha = file.sha256, sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { continue }
                let source = legacy.url(for: file), target = destination.url(for: file)
                if (try? SHA256Hex.ofFile(target)) == sha { continue }
                guard (try? SHA256Hex.ofFile(source)) == sha else { continue }
                _ = try destination.store(fileAt: source, for: file)
                guard try SHA256Hex.ofFile(target) == sha else {
                    try? FileManager.default.removeItem(at: target)
                    throw FileTransferError.integrity
                }
                restored += 1
            }
            after = files.last!.id
        }
        try await store.writer.setState(marker, "complete")
        return restored
    }

    /// Unsaved board edits have no connection/application header of their own. Import only with the same unique
    /// snapshot provenance as cached metadata; ambiguous legacy files remain in their original recovery directory.
    @discardableResult
    public func restoreBoardDrafts(store: LocalStore, workspace: WorkspaceRecord, legacyDirectory: URL,
                                   destinationDirectory: URL) async throws -> Int {
        let key = WorkspaceBoundary.digest(["board-drafts", store.path, destinationDirectory.path])
        if let restoring = cacheRestores[key] { return try await restoring.value }
        let task = Task {
            try await Self.restoreBoards(store: store, workspace: workspace, legacyDirectory: legacyDirectory,
                                         destinationDirectory: destinationDirectory)
        }
        cacheRestores[key] = task; cacheRestoreStores[key] = store
        defer { cacheRestores[key] = nil; cacheRestoreStores[key] = nil }
        return try await task.value
    }

    private static func restoreBoards(store: LocalStore, workspace: WorkspaceRecord, legacyDirectory: URL,
                                      destinationDirectory: URL) async throws -> Int {
        guard try await store.reader.state("partition.legacy-cache") == "imported" else { return 0 }
        let connections = try await store.reader.connections()
        guard let connection = connections.first, let boundary = try? WorkspaceBoundary(connection: connection, workspace: workspace),
              try await store.reader.state("partition.migration.v1") == boundary.id else { return 0 }
        let marker = "partition.board-drafts-restored.v1"
        if try await store.reader.state(marker) != nil { return 0 }
        guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { return 0 }
        let source = BoardDraftStore(directory: legacyDirectory)
        let candidates = try FileManager.default.contentsOfDirectory(at: legacyDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        var copied = 0
        for candidate in candidates {
            try Task.checkCancellation()
            guard candidate.pathExtension == "json", let uuid = UUID(uuidString: candidate.deletingPathExtension().lastPathComponent) else { continue }
            let fileId = uuid.uuidString.lowercased()
            let info = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size <= BoardScene.maxBytes + 65_536,
                  let draft = source.load(fileId), UUID(uuidString: draft.baseVersionId) != nil, draft.baseVersionNumber > 0,
                  (try? BoardScene.parse(draft.scene)) != nil else { continue }
            let target = destinationDirectory.appendingPathComponent(fileId + ".json")
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let temporaryDirectory = destinationDirectory.appendingPathComponent(".migration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let temporary = temporaryDirectory.appendingPathComponent(fileId + ".json")
            try FileManager.default.copyItem(at: candidate, to: temporary)
            let staged = BoardDraftStore(directory: temporaryDirectory)
            guard let verified = staged.load(fileId), UUID(uuidString: verified.baseVersionId) != nil,
                  verified.baseVersionNumber > 0, (try? BoardScene.parse(verified.scene)) != nil else { continue }
            // Same-filesystem rename publishes the complete validated draft atomically, without replacing an edit.
            do { try FileManager.default.moveItem(at: temporary, to: target) }
            catch {
                // Another restore/editor won the race. Never replace an existing unsaved edit.
                if FileManager.default.fileExists(atPath: target.path) { continue }
                throw error
            }
            copied += 1
        }
        try await store.writer.setState(marker, "complete")
        return copied
    }

    /// Explicit account removal only, never workspace pause. Close opened handles before moving matching files
    /// aside, so reconnecting with a new canonical local connection ID cannot inherit the previous account's queues.
    public func remove(connection: ConnectionRecord) async throws {
        let origin = try TowerOrigin(connection.origin).description
        let namespace = WorkspaceBoundary.digest([origin, connection.signerNpub])
        guard removingConnections.insert(namespace).inserted else { throw CancellationError() }
        defer { removingConnections.remove(namespace) }
        for (key, store) in Array(cacheRestoreStores) {
            guard try await store.reader.connections().contains(where: { $0.origin == origin && $0.signerNpub == connection.signerNpub }),
                  let restoration = cacheRestores[key] else { continue }
            restoration.cancel()
            _ = try? await restoration.value
            cacheRestores[key] = nil; cacheRestoreStores[key] = nil
        }
        for (key, pending) in Array(stores) {
            guard let store = try? await pending.value,
                  try await store.reader.connections().contains(where: { $0.origin == origin && $0.signerNpub == connection.signerNpub }) else { continue }
            stores[key] = nil; connectionIDs[key] = nil
            await store.writer.retirePartition()
            await store.reader.retirePartition()
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        let retired = directory.appendingPathComponent("Retired", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard name.count == 64, name.allSatisfy({ $0.isHexDigit }) else { continue }
            let path = candidate.appendingPathComponent(ProductionStorage.databaseFileName).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let matches: Bool = try {
                let db = try SQLiteConnection(path: path, readOnly: true)
                let s = try db.prepare("SELECT 1 FROM connections WHERE origin = ? AND signer_npub = ? LIMIT 1")
                try s.bind([.text(origin), .text(connection.signerNpub)])
                return try withExtendedLifetime(db) { try s.step() }
            }()
            guard matches else { continue }
            try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: candidate, to: retired.appendingPathComponent(name, isDirectory: true))
        }
    }
}

private extension StoreWriter { func retirePartition() { db.close() } }
private extension StoreReader { func retirePartition() { db.close() } }

private extension StoreReader {
    func fileCacheMigrationPage(workspaceId: String, after: String) throws -> [FileRecord] {
        let s = try db.prepare("SELECT \(Self.fileColumns) FROM files WHERE workspace_id = ? AND id > ? ORDER BY id LIMIT 100")
        try s.bind([.text(workspaceId), .text(after)])
        var files: [FileRecord] = []
        while try s.step() { files.append(Self.file(s, workspaceId: workspaceId)) }
        return files
    }
}

extension StoreWriter {
    /// SQLite backup includes committed WAL content without copying a database file under an active writer.
    func preserveLegacyBackup(at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: temporary.path + suffix) }
        }
        // A raw SQLite connection avoids enabling WAL on the standalone backup destination.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw SQLiteError(code: -1, message: "Could not create legacy backup")
        }
        defer { sqlite3_close(handle) }
        guard let copy = sqlite3_backup_init(handle, "main", db.handle, "main") else {
            throw SQLiteError(code: sqlite3_errcode(handle), message: "Could not begin legacy backup")
        }
        let result = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            throw SQLiteError(code: result == SQLITE_DONE ? finish : result, message: "Legacy backup did not finish; source preserved")
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        // No replacement: an existing backup always wins, including a concurrent pool's completed snapshot.
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { if !FileManager.default.fileExists(atPath: destination.path) { throw error } }
    }

    func importLegacyPartition(from source: URL, connection: ConnectionRecord, workspace: WorkspaceRecord, boundary: WorkspaceBoundary) throws {
        let marker = "partition.migration.v1"
        let existing = try db.prepare("SELECT value FROM app_state WHERE key = ?")
        try existing.bind([.text(marker)])
        if try existing.step() {
            guard existing.text(0) == boundary.id else { throw SQLiteError(code: -1, message: "Workspace partition boundary mismatch") }
            return
        }
        try db.prepare("ATTACH DATABASE ? AS legacy").run([.text(source.path)])
        defer { try? db.execute("DETACH DATABASE legacy") }
        try db.transaction {
            // The backup is frozen before the catalog is used for multi-connection discovery.
            let owners = try db.prepare("SELECT COUNT(*) FROM legacy.workspaces WHERE workspace_id = ?")
            try owners.bind([.text(workspace.id)])
            let count = try owners.step() ? owners.int(0) : 0
            let owner = try db.prepare("""
                SELECT 1 FROM legacy.workspaces w JOIN legacy.connections c ON c.id = w.connection_id
                WHERE w.workspace_id = ? AND w.connection_id = ? AND w.app_npub = ? AND c.origin = ? AND c.signer_npub = ?
                """)
            try owner.bind([.text(workspace.id), .text(connection.id), .text(workspace.appNpub), .text(boundary.origin), .text(connection.signerNpub)])
            let matches = try owner.step()
            let unique = matches && count == 1
            let tables = ["scopes", "channels", "messages", "threads", "members", "channel_sync"]
                + Schema.v3WorkspaceTables + Schema.v4WorkspaceTables + Schema.v7WorkspaceTables
                + ["drafts", "doc_drafts", "outbox", "writes", "profiles"]
            for table in tables {
                let columns = try legacyColumns(table)
                guard !columns.isEmpty else { continue }
                var predicate: [String] = []
                var values: [SQLValue] = []
                if columns.contains("workspace_id") { predicate.append("workspace_id = ?"); values.append(.text(workspace.id)) }
                if columns.contains("connection_id") {
                    predicate.append("connection_id = ?"); values.append(.text(connection.id))
                    // Outbox/writes are independently app-qualified; other private tables need discovery provenance.
                    if !columns.contains("app_npub"), !matches { continue }
                } else if !unique { continue }
                if columns.contains("app_npub") { predicate.append("app_npub = ?"); values.append(.text(workspace.appNpub)) }
                if columns.contains("origin") { predicate.append("origin = ?"); values.append(.text(boundary.origin)) }
                if columns.contains("signer_npub") { predicate.append("signer_npub = ?"); values.append(.text(connection.signerNpub)) }
                guard !predicate.isEmpty else { continue }
                let names = columns.map { "\"\($0)\"" }.joined(separator: ",")
                try db.prepare("INSERT OR IGNORE INTO \(table)(\(names)) SELECT \(names) FROM legacy.\(table) WHERE \(predicate.joined(separator: " AND "))").run(values)
            }
            if matches {
                let qualified = [
                    "chat-path:\(connection.id):\(workspace.id)", "thread-focus:\(connection.id):\(workspace.id)",
                    WorkContext.stateKey(connectionId: connection.id, workspaceId: workspace.id),
                    WorkspaceSync.collapsedKey(connectionId: connection.id, workspaceId: workspace.id),
                    LiveCursorKey.events(connectionId: connection.id, workspaceId: workspace.id)
                ]
                for key in qualified + (unique ? [WorkspaceSync.scopeOrderKey(workspace.id)] : []) {
                    try db.prepare("INSERT OR IGNORE INTO app_state(key,value) SELECT key,value FROM legacy.app_state WHERE key = ?").run([.text(key)])
                }
            }
            try db.prepare("INSERT INTO app_state(key,value) VALUES(?,?)").run([.text(marker), .text(boundary.id)])
            try db.prepare("INSERT INTO app_state(key,value) VALUES('partition.legacy-cache',?)").run([.text(unique ? "imported" : "unattributed-source-preserved")])
        }
    }

    private func legacyColumns(_ table: String) throws -> [String] {
        // Only compile-time table names above are interpolated. Values always use bound parameters.
        let s = try db.prepare("PRAGMA legacy.table_info(\(table))")
        var columns: [String] = []
        while try s.step() { if let name = s.text(1) { columns.append(name) } }
        return columns
    }
}
