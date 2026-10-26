import Foundation

/// Reads and edits sent text attachments for one connection and workspace, signed by the unlocked identity through the
/// sync engine at `user` priority. Bytes are cached by storage object id (immutable), so a read that happened once
/// works offline later.
public struct TextAttachmentService: Sendable {
    public let sync: WorkspaceSync
    public let connection: ConnectionRecord
    public let workspace: WorkspaceRecord
    public let cache: FileCache?
    public let editDirectory: URL?

    public init(sync: WorkspaceSync, connection: ConnectionRecord, workspace: WorkspaceRecord, cache: FileCache?, editDirectory: URL? = nil) {
        self.sync = sync; self.connection = connection; self.workspace = workspace; self.cache = cache
        self.editDirectory = editDirectory ?? cache?.root.appendingPathComponent("TextEdits", isDirectory: true)
    }

    private func run<T: Sendable>(_ key: String, _ work: @escaping @Sendable (TowerAPI) async throws -> T) async throws -> T {
        let sync = sync, connection = connection
        return try await sync.engine.perform("textatt:\(workspace.id):\(key)", priority: .user) {
            try await sync.identity.requireSigner(npub: connection.signerNpub)
            return try await work(sync.api(origin: try TowerOrigin(connection.origin)))
        }
    }

    // MARK: Cache

    public func cached(_ objectId: String) -> Data? {
        cache?.attachment(workspaceId: workspace.id, objectId: objectId).flatMap { try? Data(contentsOf: $0) }
    }

    func remember(_ bytes: Data, objectId: String) {
        guard let cache else { return }
        let url = cache.root.appendingPathComponent(workspace.id, isDirectory: true).appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(objectId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? bytes.write(to: url, options: [.atomic])
        #endif
    }

    // MARK: Reading

    /// The bytes of the attachment as sent. Checked against the message's recorded checksum when it has one.
    public func original(_ attachment: MessageAttachment) async throws -> Data {
        if let hit = cached(attachment.storageObjectId), attachment.sha256 == nil || SHA256Hex.of(hit) == attachment.sha256 { return hit }
        let id = attachment.storageObjectId
        let bytes = try await run("read:\(id)") { try await $0.storageContent(objectId: id) }
        if let expected = attachment.sha256, SHA256Hex.of(bytes) != expected { throw FileTransferError.integrity }
        remember(bytes, objectId: id)
        return bytes
    }

    public func version(_ version: TextVersionRef, of lineage: TextLineage, original attachment: MessageAttachment) async throws -> Data {
        if version.isOriginal { return try await original(attachment) }
        if let hit = cached(version.storageObjectId), version.sha256 == nil || SHA256Hex.of(hit) == version.sha256 { return hit }
        let workspaceId = workspace.id, appNpub = workspace.appNpub, fileId = lineage.fileId
        let bytes = try await run("version:\(version.id)") {
            try await $0.textVersionBytes(workspaceId: workspaceId, appNpub: appNpub, fileId: fileId, version: version)
        }
        remember(bytes, objectId: version.storageObjectId)
        return bytes
    }

    public struct CachedHistory: Codable, Sendable {
        public let lineage: TextLineage?
        public let versions: [TextVersionRef]
        public let currentVersionId: String?
    }
    private func historyURL(_ objectId: String) -> URL? {
        let key = SHA256Hex.of(Data([connection.id, connection.origin, workspace.id, objectId].joined(separator: "\n").utf8))
        return cache?.root.appendingPathComponent("TextHistory", isDirectory: true).appendingPathComponent(key + ".json")
    }
    public func cachedHistory(_ objectId: String) -> CachedHistory? {
        guard let url = historyURL(objectId), let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedHistory.self, from: bytes)
    }
    private func rememberHistory(_ value: CachedHistory, objectId: String) {
        guard let url = historyURL(objectId), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }

    // MARK: History

    public func lineage(of attachment: MessageAttachment, message: MessageRecord) async throws -> TextLineage? {
        let workspaceId = workspace.id, appNpub = workspace.appNpub, channel = message.channelId, id = message.id, object = attachment.storageObjectId
        return try await run("lineage:\(id):\(object)") {
            try await $0.textLineage(workspaceId: workspaceId, appNpub: appNpub, channelId: channel, originMessageId: id, originStorageObjectId: object)
        }
    }

    /// The original followed by every saved version, oldest first.
    public func history(of attachment: MessageAttachment, lineage: TextLineage?) async throws -> (versions: [TextVersionRef], currentVersionId: String?) {
        let original = TextVersionRef(id: "original:" + attachment.storageObjectId, versionId: nil, number: 0, storageObjectId: attachment.storageObjectId,
                                      sizeBytes: attachment.sizeBytes, sha256: attachment.sha256, createdAt: nil, author: nil)
        guard let lineage else { return ([original], nil) }
        let workspaceId = workspace.id, appNpub = workspace.appNpub, fileId = lineage.fileId
        let listed = try await run("versions:\(fileId)") { try await $0.textVersions(workspaceId: workspaceId, appNpub: appNpub, fileId: fileId) }
        // The first file version holds the first edit; the original is the message's own attachment.
        let versions = [original] + listed.versions
        rememberHistory(CachedHistory(lineage: lineage, versions: versions, currentVersionId: listed.currentVersionId), objectId: attachment.storageObjectId)
        return (versions, listed.currentVersionId)
    }

    public var journal: TextEditJournal? {
        editDirectory.map { TextEditJournal.shared(root: $0) }
    }

    public func recover(message: MessageRecord, attachment: MessageAttachment) async throws -> PendingTextEdit? {
        guard let journal else { throw TextAttachmentError.missing }
        return try await journal.load(connection: connection, workspaceId: workspace.id, messageId: message.id, objectId: attachment.storageObjectId)
    }

    /// Retry exactly the upload and mutation stored before the first network request. If Tower accepted a request
    /// whose response was lost, its replay uses this same object, rather than creating a second edit.
    public func saveDurably(_ intent: PendingTextEdit) async throws -> TextSaveOutcome {
        guard let journal, intent.connectionId == connection.id, intent.towerOrigin == connection.origin,
              intent.workspaceId == workspace.id else { throw TextAttachmentError.integrity }
        try await journal.save(intent)
        let workspaceId = workspace.id, appNpub = workspace.appNpub
        let outcome: TextSaveOutcome
        if let accepted = intent.acceptedLineage {
            outcome = .saved(lineage: accepted, version: intent.acceptedVersion)
        } else {
            outcome = try await run("save:\(intent.mutationId)") { api in
            try await api.saveTextEdit(workspaceId: workspaceId, appNpub: appNpub, channelId: intent.channelId,
                origin: (intent.messageId, intent.originStorageObjectId, intent.originFilename), lineage: intent.lineage,
                baseVersionId: intent.baseVersionId, bytes: intent.bytes, filename: intent.filename,
                clientMutationId: intent.mutationId, prepared: intent.prepared, onPrepared: { prepared in
                    var next = intent; next.prepared = prepared
                    try await journal.save(next)
                })
        }
        }
        switch outcome {
        case .saved(let lineage, let version):
            var retained = try await journal.load(connection: connection, workspaceId: workspaceId,
                messageId: intent.messageId, objectId: intent.originStorageObjectId) ?? intent
            retained.acceptedLineage = lineage; retained.acceptedVersion = version
            try await journal.save(retained) // Version accepted, rename pending: durable before the separate PATCH.
            if let version { remember(intent.bytes, objectId: version.storageObjectId) }
            let savedIntent = retained
            do {
                let renamed = try await run("rename:\(intent.mutationId)") { api in
                    try await api.renameTextFile(workspaceId: workspaceId, appNpub: appNpub, lineage: lineage,
                        filename: intent.filename, refreshBase: intent.renameConflict == true, onCanonical: { canonical in
                            var next = savedIntent; next.acceptedLineage = canonical
                            try await journal.save(next)
                        })
                }
                try await journal.remove(retained)
                return .saved(lineage: renamed, version: version)
            } catch {
                if case TextVersionError.http(409, _) = error {
                    retained.renameConflict = true; try await journal.save(retained)
                }
                throw TextEditSaveError.renamePending
            }
        case .conflict(let lineage, let current):
            var retained = try await journal.load(connection: connection, workspaceId: workspaceId,
                messageId: intent.messageId, objectId: intent.originStorageObjectId) ?? intent
            retained.conflictLineage = lineage; retained.conflict = current
            try await journal.save(retained)
        }
        return outcome
    }

    // MARK: Saving

    /// Saves an edit as a new version; `prepared` resumes an interrupted upload of the same bytes.
    public func save(message: MessageRecord, attachment: MessageAttachment, lineage: TextLineage?, baseVersionId: String?, bytes: Data, filename: String,
                     mutationId: String, prepared: PreparedObject? = nil,
                     onPrepared: @escaping @Sendable (PreparedObject) async throws -> Void = { _ in }) async throws -> TextSaveOutcome {
        let workspaceId = workspace.id, appNpub = workspace.appNpub
        let origin = (messageId: message.id, storageObjectId: attachment.storageObjectId, filename: attachment.filename)
        let outcome = try await run("save:\(mutationId)") {
            try await $0.saveTextEdit(workspaceId: workspaceId, appNpub: appNpub, channelId: message.channelId, origin: origin, lineage: lineage,
                                      baseVersionId: baseVersionId, bytes: bytes, filename: filename, clientMutationId: mutationId,
                                      prepared: prepared, onPrepared: onPrepared)
        }
        if case .saved(_, let version?) = outcome { remember(bytes, objectId: version.storageObjectId) }
        return outcome
    }
}

/// An edit is committed locally before any upload. One atomic envelope owns both its bytes and its upload/mutation
/// identity; an interrupted replacement leaves the previous envelope readable. Never contains signing material.
public struct PendingTextEdit: Codable, Sendable, Equatable {
    public let connectionId: String
    public let towerOrigin: String
    public let workspaceId: String
    public let channelId: String
    public let messageId: String
    public let originStorageObjectId: String
    public let originFilename: String
    public var filename: String
    public var bytes: Data
    public var mutationId: String
    public var prepared: PreparedObject?
    public var lineage: TextLineage?
    public var baseVersionId: String?
    public var conflict: TextVersionRef?
    public var conflictLineage: TextLineage?
    public var acceptedLineage: TextLineage?
    public var acceptedVersion: TextVersionRef?
    public var renameConflict: Bool?
    public var supersedesMutationId: String?

    public init(connection: ConnectionRecord, workspaceId: String, message: MessageRecord, attachment: MessageAttachment,
                bytes: Data, filename: String, lineage: TextLineage?, baseVersionId: String?) {
        connectionId = connection.id; towerOrigin = connection.origin; self.workspaceId = workspaceId
        channelId = message.channelId; messageId = message.id; originStorageObjectId = attachment.storageObjectId
        originFilename = attachment.filename; self.bytes = bytes; self.filename = filename
        mutationId = UUID().uuidString.lowercased(); self.lineage = lineage; self.baseVersionId = baseVersionId
    }
    /// Older journals stored the conflict's canonical lineage in `lineage`; recognize that shape without changing
    /// its original base or reusing a prepared operation for different bytes.
    public var canonicalConflict: TextLineage? {
        if let conflictLineage { return conflictLineage }
        if prepared != nil, acceptedLineage == nil, let lineage, lineage.currentVersionId != baseVersionId { return lineage }
        return nil
    }

    /// Local typing/renaming never adopts a newer server base. A prepared or accepted command is immutable until
    /// replay/reconciliation finishes; changing it would reuse one mutation for different bytes.
    public func updatingLocal(bytes: Data, filename: String) throws -> PendingTextEdit {
        if prepared != nil || acceptedLineage != nil {
            guard self.bytes == bytes, self.filename == filename else { throw TextEditSaveError.pendingUpload }
            return self
        }
        var next = self; next.bytes = bytes; next.filename = filename
        return next
    }

    /// Only the explicit conflict action may replace the saved base. The same uploaded bytes can be reused with a
    /// fresh mutation, while the original message attachment and previous base remain immutable historical records.
    public func rebasing(on lineage: TextLineage, versionId: String) -> PendingTextEdit {
        var next = self
        next.lineage = lineage; next.baseVersionId = versionId; next.supersedesMutationId = mutationId; next.mutationId = UUID().uuidString.lowercased()
        next.conflict = nil; next.conflictLineage = nil; next.acceptedLineage = nil; next.acceptedVersion = nil; next.renameConflict = nil
        return next
    }

}

public actor TextEditJournal {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var journals: [String: TextEditJournal] = [:]
        func journal(root: URL) -> TextEditJournal {
            lock.withLock {
                let key = root.standardizedFileURL.path
                if let existing = journals[key] { return existing }
                let journal = TextEditJournal(root: root); journals[key] = journal
                return journal
            }
        }
    }
    private static let registry = Registry()
    public nonisolated static func shared(root: URL) -> TextEditJournal { registry.journal(root: root) }
    public let root: URL
    public init(root: URL) { self.root = root }

    private func url(connectionId: String, origin: String, workspaceId: String, messageId: String, objectId: String) -> URL {
        // Hash the entire binding, including backend and signer-scoped connection. No cross-account recovery.
        let key = SHA256Hex.of(Data([connectionId, origin, workspaceId, messageId, objectId].joined(separator: "\n").utf8))
        return root.appendingPathComponent(key + ".json")
    }
    public func load(connection: ConnectionRecord, workspaceId: String, messageId: String, objectId: String) throws -> PendingTextEdit? {
        let location = url(connectionId: connection.id, origin: connection.origin, workspaceId: workspaceId, messageId: messageId, objectId: objectId)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let edit = try JSONDecoder().decode(PendingTextEdit.self, from: Data(contentsOf: location))
        guard edit.connectionId == connection.id, edit.towerOrigin == connection.origin, edit.workspaceId == workspaceId,
              edit.messageId == messageId, edit.originStorageObjectId == objectId else { throw TextAttachmentError.integrity }
        return edit
    }
    public func save(_ edit: PendingTextEdit) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(edit)
        let location = url(connectionId: edit.connectionId, origin: edit.towerOrigin, workspaceId: edit.workspaceId, messageId: edit.messageId, objectId: edit.originStorageObjectId)
        if FileManager.default.fileExists(atPath: location.path) {
            let current = try JSONDecoder().decode(PendingTextEdit.self, from: Data(contentsOf: location))
            if current.mutationId == edit.mutationId {
                // A canceled autosave must never roll a prepared/accepted operation backwards.
                if current.prepared != nil && edit.prepared == nil { throw TextEditSaveError.staleLocalWrite }
                if current.acceptedLineage != nil && edit.acceptedLineage == nil { throw TextEditSaveError.staleLocalWrite }
                if current.prepared != nil || current.acceptedLineage != nil {
                    guard current.bytes == edit.bytes, current.filename == edit.filename else { throw TextEditSaveError.pendingUpload }
                }
            } else if current.prepared != nil || current.acceptedLineage != nil {
                guard let conflict = current.canonicalConflict, edit.supersedesMutationId == current.mutationId,
                      edit.baseVersionId == conflict.currentVersionId, edit.lineage?.fileId == conflict.fileId else {
                    throw TextEditSaveError.pendingUpload
                }
            }
        }
        #if os(iOS)
        try data.write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: location, options: [.atomic])
        #endif
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }
    public func remove(_ edit: PendingTextEdit) throws {
        let location = url(connectionId: edit.connectionId, origin: edit.towerOrigin, workspaceId: edit.workspaceId, messageId: edit.messageId, objectId: edit.originStorageObjectId)
        if FileManager.default.fileExists(atPath: location.path) {
            let current = try JSONDecoder().decode(PendingTextEdit.self, from: Data(contentsOf: location))
            guard current.mutationId == edit.mutationId else { throw TextEditSaveError.staleLocalWrite }
            try FileManager.default.removeItem(at: location)
        }
    }
}

public enum TextEditSaveError: LocalizedError, Sendable {
    case renamePending, pendingUpload, staleLocalWrite
    public var errorDescription: String? {
        switch self {
        case .renamePending: "The content version is saved. Its filename is still pending; Save retries only the name. If another person renamed it, Save applies your name to the latest file."
        case .pendingUpload: "This edit has an upload waiting to finish. Retry it before changing its text or filename."
        case .staleLocalWrite: "A newer edit operation is already saved on this device. Reopen it to continue; nothing was overwritten."
        }
    }
}
