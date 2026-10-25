import Foundation

// Excalidraw board editing (sol `canvas/board-controller.js`, `board-sync.js`). The editor surface (the embedded
// Excalidraw page) owns no network or storage: it sends scene changes to a `BoardController`, which keeps the working
// draft on this device and only publishes on Save, as a new immutable File version against the version the draft
// started from. Tower routes (all existing, `tower/src/routes/flightdeck-pg.ts`):
//
// - `GET  /files/:f/versions` (history, current version)
// - `GET  /files/:f/versions/:v/object` (exact bytes, checked against the version's sha256)
// - `POST /storage/prepare`, object upload, `POST /storage/:o/complete` (private object for the new version)
// - `POST /files/:f/versions` with `base_version_id` (409 `stale_base_version` when someone saved first)

public struct BoardVersion: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let number: Int
    public let createdAt: String
    public let authorNpub: String
    public let summary: String
    public let sha256: String

    init?(_ row: [String: Any]) {
        guard let id = lowerUUID(row["id"] as? String), let number = flexibleInt(row["version_number"]), number >= 1 else { return nil }
        self.id = id
        self.number = number
        createdAt = (row["created_at"] as? String) ?? ""
        authorNpub = (row["created_by_actor_npub"] as? String) ?? ""
        summary = String(((row["summary"] as? String) ?? "").prefix(BoardScene.maxSummary))
        let sha = ((row["sha256_hex"] as? String) ?? "").lowercased()
        sha256 = sha.count == 64 ? sha : ""
    }

    public init(id: String, number: Int, createdAt: String = "", authorNpub: String = "", summary: String = "", sha256: String = "") {
        self.id = id; self.number = number; self.createdAt = createdAt; self.authorNpub = authorNpub; self.summary = summary; self.sha256 = sha256
    }
}

public enum BoardEditError: LocalizedError, Equatable, Sendable {
    /// Someone saved a newer version first; the draft is kept.
    case stale(current: BoardVersion?)
    /// Tower no longer lets this viewer read (or write) the board.
    case unavailable
    case locked
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .stale: "Someone saved a newer version of this board. Your changes are kept as an unsaved draft."
        case .unavailable: "This board is no longer available to you."
        case .locked: "Unlock to save board changes."
        case .failed(let detail): detail
        }
    }

    static func from(_ error: Error) -> BoardEditError {
        if let e = error as? BoardEditError { return e }
        if case TowerError.http(let status, let code, _) = error {
            if status == 409, code == "stale_base_version" || (code ?? "").contains("stale") { return .stale(current: nil) }
            if [401, 403, 404].contains(status) { return .unavailable }
        }
        return .failed(error.localizedDescription)
    }
}

extension TowerAPI {
    /// A board File's versions, newest first, and its current version.
    public func boardVersions(workspaceId: String, appNpub: String, fileId: String) async throws -> (currentVersionId: String?, versions: [BoardVersion]) {
        let path = try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/versions"
        let o = try object(try await client.request(path: path, query: [URLQueryItem(name: "limit", value: "100")], appNpub: appNpub), "board versions")
        if let f = o["file_id"] as? String, lowerUUID(f) != fileId.lowercased() { throw TowerError.malformed("board versions") }
        let versions = ((o["versions"] as? [[String: Any]]) ?? []).compactMap(BoardVersion.init).sorted { $0.number > $1.number }
        return (lowerUUID(o["current_version_id"] as? String), versions)
    }

    /// Exact bytes of one board version; checked against `sha256` when it is known.
    public func boardVersionBytes(workspaceId: String, appNpub: String, fileId: String, versionId: String, sha256: String?) async throws -> Data {
        let path = try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/versions/" + Self.uuid(versionId) + "/object"
        let bytes = try await client.request(path: path, appNpub: appNpub)
        guard bytes.count <= BoardScene.maxBytes else { throw BoardScene.SceneError.tooLarge("This board is larger than the 24 MB limit.") }
        if let sha256, !sha256.isEmpty, SHA256Hex.of(bytes) != sha256 { throw DocumentBodyError.integrity }
        return bytes
    }

    /// Renames a board File (metadata only: no new version). Tower must confirm the exact name.
    public func renameBoardFile(workspaceId: String, appNpub: String, fileId: String, name: String) async throws -> String {
        let path = try Self.base(workspaceId) + "/files/" + Self.uuid(fileId)
        let o = try object(try await client.request(method: "PATCH", path: path, appNpub: appNpub, jsonBody: try rawJSON(["display_name": name])), "board rename")
        guard let file = o["file"] as? [String: Any], lowerUUID(file["id"] as? String) == fileId.lowercased(), file["display_name"] as? String == name else {
            throw TowerError.malformed("board rename")
        }
        return name
    }

    /// Publishes `bytes` as the board's next version, against `baseVersionId`.
    public func createBoardVersion(workspaceId: String, appNpub: String, fileId: String, baseVersionId: String, bytes: Data, title: String,
                                   summary: String) async throws -> BoardVersion {
        let objectId = try await store(workspaceId: workspaceId, appNpub: appNpub, bytes: bytes, contentType: BoardScene.contentType,
                                       fileName: BoardScene.fileName(title), prepared: nil, onPrepared: { _ in })
        var body: [String: Any] = ["base_version_id": try Self.uuid(baseVersionId), "storage_object_id": objectId,
                                   "client_mutation_id": UUID().uuidString.lowercased()]
        let trimmed = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(BoardScene.maxSummary))
        if !trimmed.isEmpty { body["summary"] = trimmed }
        let path = try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/versions"
        let o = try object(try await client.request(method: "POST", path: path, appNpub: appNpub, jsonBody: try rawJSON(body)), "board version")
        guard let row = o["version"] as? [String: Any], let version = BoardVersion(row) else { throw TowerError.malformed("board version") }
        return version.sha256.isEmpty ? BoardVersion(id: version.id, number: version.number, createdAt: version.createdAt, authorNpub: version.authorNpub,
                                                     summary: version.summary, sha256: SHA256Hex.of(bytes)) : version
    }
}

/// Unsaved board drafts on this device, one per viewer, workspace and board File (sol `canvas_board_drafts`). Files
/// are protected until first unlock; a denial or removed identity deletes them.
public struct BoardDraftStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public struct Draft: Sendable {
        public let baseVersionId: String
        public let baseVersionNumber: Int
        public let scene: Data
    }

    private func url(_ fileId: String) -> URL { directory.appendingPathComponent(fileId.lowercased() + ".json") }

    public func load(_ fileId: String) -> Draft? {
        guard let data = try? Data(contentsOf: url(fileId)), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = o["base_version_id"] as? String, let scene = o["scene"] else { return nil }
        guard let bytes = try? JSONSerialization.data(withJSONObject: scene) else { return nil }
        return Draft(baseVersionId: base, baseVersionNumber: flexibleInt(o["base_version_number"]) ?? 0, scene: bytes)
    }

    func save(_ fileId: String, baseVersionId: String, baseVersionNumber: Int, scene: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["base_version_id": baseVersionId, "base_version_number": baseVersionNumber, "scene": scene,
                                                               "updated_at": ISO8601DateFormatter.tower.string(from: Date())])
        #if os(iOS)
        try data.write(to: url(fileId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(fileId), options: [.atomic])
        #endif
    }

    public func delete(_ fileId: String) { try? FileManager.default.removeItem(at: url(fileId)) }
}

/// What a board screen shows about its board: load and save state, versions and whether the viewer may write.
public struct BoardState: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case loading, ready, denied, error }
    public enum Save: Sendable, Equatable { case saved, unsaved, saving, error, stale }
    public var status: Status = .loading
    public var save: Save = .saved
    public var dirty = false
    public var error = ""
    public var notice = ""
    public var canWrite = false
    public var baseVersionId = ""
    public var baseVersionNumber = 0
    public var latestVersionId = ""
    public var latestVersionNumber = 0
    public var viewingVersionId = ""
    public var viewingVersionNumber = 0
    public var versions: [BoardVersion] = []
    public var versionsLoading = false
    public var conflicts = 0
    /// The board's name after a rename here (the canvas shows Tower's on its next snapshot).
    public var title = ""
    /// Increases with every change, so a screen receiving states across actor hops keeps the newest.
    public var revision = 0
    public init() {}

    public var newerAvailable: Bool { dirty && !latestVersionId.isEmpty && !baseVersionId.isEmpty && latestVersionId != baseVersionId }
    public var readOnly: Bool { !canWrite || !viewingVersionId.isEmpty }

    /// The compact title-bar status of the web board window ("Unsaved · v7").
    public var headerStatus: String {
        switch status {
        case .loading: return ""
        case .denied: return "No access"
        case .error: return "Error"
        case .ready: break
        }
        let base = baseVersionNumber > 0 ? "v\(baseVersionNumber)" : ""
        if !viewingVersionId.isEmpty { return "Viewing v\(viewingVersionNumber) · read-only" }
        if save == .saving { return "Saving…" }
        if save == .error { return "Save failed" }
        if save == .stale || newerAvailable { return "Unsaved · newer v\(latestVersionNumber) saved" }
        if dirty { return base.isEmpty ? "Unsaved changes" : "Unsaved · \(base)" }
        if !canWrite { return base.isEmpty ? "Read-only" : "Read-only · \(base)" }
        return base
    }

    /// Save as the editor floats it (hidden for read-only views).
    public var saveAction: (label: String, enabled: Bool)? {
        guard status == .ready, viewingVersionId.isEmpty, canWrite else { return nil }
        if save == .saving { return ("Saving…", false) }
        return dirty ? ("Save", true) : ("Saved", false)
    }
}

/// The only owner of one board File's draft and saves (sol `BoardController`). Every editor surface showing the board
/// (inline on a canvas and full screen) attaches as a session and shares the draft. Runs off the main actor: scene
/// JSON is parsed, compared and serialised here, never on the UI thread.
public actor BoardController {
    /// Tower access for one board, bound to the workspace and connection by the app.
    public struct Transport: Sendable {
        public var versions: @Sendable () async throws -> (currentVersionId: String?, versions: [BoardVersion])
        public var read: @Sendable (_ versionId: String, _ sha256: String?) async throws -> Data
        public var publish: @Sendable (_ baseVersionId: String, _ bytes: Data, _ summary: String) async throws -> BoardVersion
        /// Whether a signer is available now (a locked identity can read but not save).
        public var canSign: @Sendable () async -> Bool
        /// Renames the board File.
        public var rename: @Sendable (_ name: String) async throws -> String

        public init(versions: @escaping @Sendable () async throws -> (currentVersionId: String?, versions: [BoardVersion]),
                    read: @escaping @Sendable (String, String?) async throws -> Data,
                    publish: @escaping @Sendable (String, Data, String) async throws -> BoardVersion,
                    canSign: @escaping @Sendable () async -> Bool,
                    rename: @escaping @Sendable (String) async throws -> String = { _ in throw BoardEditError.failed("Renaming is not available.") }) {
            self.versions = versions; self.read = read; self.publish = publish; self.canSign = canSign; self.rename = rename
        }
    }

    public typealias Send = @Sendable (String) -> Void

    public let fileId: String
    private let transport: Transport
    private let drafts: BoardDraftStore
    private let author: String
    private var title: String
    private var onState: @Sendable (BoardState) -> Void
    private var state = BoardState()
    private var meta: BoardReference?
    private var metaCanWrite = false

    private var base: (versionId: String, number: Int, scene: BoardScene.Object, fingerprint: String)?
    private var working: BoardScene.Object?
    private var viewing: (versionId: String, number: Int, scene: BoardScene.Object)?
    private var loadKey = ""
    private var sessions: [String: Session] = [:]
    private var cache: [String: BoardScene.Object] = [:]
    private var loading: Task<Void, Never>?
    private var saving = false

    private struct Session {
        let send: Send
        var lastFingerprint = ""
        var flushes: [String: CheckedContinuation<Bool, Never>] = [:]
    }

    public init(fileId: String, title: String, author: String, transport: Transport, drafts: BoardDraftStore,
                onState: @escaping @Sendable (BoardState) -> Void) {
        self.fileId = fileId.lowercased()
        self.title = title
        self.author = author
        self.transport = transport
        self.drafts = drafts
        self.onState = onState
    }

    public func setOnState(_ callback: @escaping @Sendable (BoardState) -> Void) { onState = callback; callback(state) }
    public var current: BoardState { state }

    private func emit(_ change: (inout BoardState) -> Void = { _ in }) {
        change(&state)
        state.revision += 1
        onState(state)
    }

    // MARK: Snapshot metadata

    /// Called with each authorized canvas projection of this board (its current version and `can_write`).
    public func sync(_ reference: BoardReference, title: String) async {
        let previous = meta
        meta = reference
        self.title = title
        metaCanWrite = reference.canWrite
        let canSign = await transport.canSign()
        emit {
            $0.canWrite = reference.canWrite && canSign
            if $0.latestVersionId.isEmpty || previous?.versionId != reference.versionId {
                $0.latestVersionId = reference.versionId; $0.latestVersionNumber = reference.versionNumber
            }
        }
        if base == nil {
            if loading == nil { loading = Task { await initialLoad() } }
            await loading?.value
            return
        }
        if previous?.canWrite != reference.canWrite { broadcastLoad() }
        if previous?.versionId != reference.versionId, !state.dirty, reference.versionId != base?.versionId {
            _ = await loadLatest(force: true, head: (reference.versionId, reference.versionNumber, reference.sha256))
        }
    }

    /// Lock state changed: a locked identity keeps the board readable but not editable.
    public func refreshSigner() async {
        let signer = await transport.canSign()
        let writable = metaCanWrite && signer
        guard writable != state.canWrite else { return }
        emit { $0.canWrite = writable }
        broadcastLoad()
    }

    private func readVersion(_ versionId: String, sha256: String?) async throws -> BoardScene.Object {
        if let cached = cache[versionId] { return cached }
        let bytes = try await transport.read(versionId, sha256)
        let scene = try BoardScene.parse(bytes)
        if cache.count > 8 { cache.removeAll() }
        cache[versionId] = scene
        return scene
    }

    private func initialLoad() async {
        guard let meta else { return }
        do {
            let draft = drafts.load(fileId)
            // A stored canvas snapshot can lag behind a save (this device's or another's): without a draft, open
            // Tower's current version. The projection is used when the version list cannot be read.
            var head = (id: meta.versionId, number: meta.versionNumber, sha256: meta.sha256)
            if draft == nil, let listed = try? await transport.versions(), let id = listed.currentVersionId,
               let row = listed.versions.first(where: { $0.id == id }) {
                head = (id, row.number, row.sha256.isEmpty ? (id == meta.versionId ? meta.sha256 : "") : row.sha256)
                emit { $0.versions = listed.versions; $0.latestVersionId = id; $0.latestVersionNumber = row.number }
            }
            let baseId = draft?.baseVersionId ?? head.id
            let baseNumber = draft != nil ? draft!.baseVersionNumber : head.number
            let scene = try await readVersion(baseId, sha256: baseId == head.id && !head.sha256.isEmpty ? head.sha256 : nil)
            let fingerprint = BoardScene.fingerprint(scene)
            base = (baseId, baseNumber, scene, fingerprint)
            var dirty = false
            if let draft, let restored = try? BoardScene.parse(draft.scene), BoardScene.fingerprint(restored) != fingerprint {
                working = restored; dirty = true
            } else {
                working = scene
                if draft != nil { drafts.delete(fileId) }
            }
            loadKey = "\(baseId):\(UUID().uuidString)"
            emit {
                $0.status = .ready; $0.dirty = dirty; $0.save = dirty ? .unsaved : .saved; $0.error = ""
                $0.notice = dirty ? "Unsaved draft restored from this \(Self.deviceName)." : ""
                $0.baseVersionId = baseId; $0.baseVersionNumber = baseNumber
            }
            broadcastLoad()
        } catch {
            await fail(error)
        }
        loading = nil
    }

    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "device"
        #endif
    }

    private func fail(_ error: Error) async {
        if case .unavailable = BoardEditError.from(error) {
            drafts.delete(fileId)
            cache.removeAll()
            base = nil; working = nil; viewing = nil
            emit { $0.status = .denied; $0.dirty = false; $0.save = .saved; $0.error = "Ask your workspace owner for access." }
            for session in sessions.values { session.send(Self.message(["type": "clear"])) }
            return
        }
        emit { $0.status = base == nil ? .error : .ready; $0.error = BoardEditError.from(error).localizedDescription }
    }

    // MARK: Editor sessions

    private func editorContent() -> (scene: BoardScene.Object, readOnly: Bool, key: String)? {
        if let viewing { return (viewing.scene, true, "history:\(viewing.versionId)") }
        guard let working else { return nil }
        return (working, !state.canWrite, loadKey)
    }

    private func broadcastLoad() { for id in sessions.keys { sendLoad(id) } }

    private func sendLoad(_ id: String) {
        guard let content = editorContent(), sessions[id] != nil else { return }
        sessions[id]?.lastFingerprint = BoardScene.fingerprint(content.scene)
        sessions[id]?.send(Self.message(["type": "load", "key": content.key, "readOnly": content.readOnly, "scene": content.scene]))
    }

    /// One editor message as JSON text.
    public static func message(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// An editor surface joins; it receives the current draft once it reports `ready`.
    public func attach(_ sessionId: String, send: @escaping Send) {
        sessions[sessionId] = Session(send: send)
    }

    public func detach(_ sessionId: String) {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        for waiter in session.flushes.values { waiter.resume(returning: false) }
    }

    public var attached: Bool { !sessions.isEmpty }

    /// One message from an editor page (JSON text from the bridge).
    public func receive(_ sessionId: String, _ json: String) async {
        guard let data = json.data(using: .utf8), let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch message["type"] as? String {
        case "ready":
            if state.status == .ready { sendLoad(sessionId) }
        case "change":
            if let scene = message["scene"] { await editorChanged(sessionId, scene) }
        case "comment-op":
            if let operation = message["operation"] as? [String: Any] { await commentOperation(sessionId, operation) }
        case "flushed":
            if let token = message["token"] as? String, let waiter = sessions[sessionId]?.flushes.removeValue(forKey: token) { waiter.resume(returning: true) }
        case "error":
            emit { $0.error = "The board editor reported a problem: \((message["message"] as? String) ?? "unknown")" }
        default:
            break   // "action" (Save) is handled by the screen, which re-checks the state first
        }
    }

    private func editorChanged(_ sessionId: String, _ raw: Any) async {
        guard sessions[sessionId] != nil, viewing == nil, let base, let current = working, state.canWrite else { return }
        guard var scene = try? BoardScene.normalize(raw) else { emit { $0.error = "The editor sent a board this app could not read; nothing was changed." }; return }
        // Images are sent once; keep those already in the draft. Discussion is owned here, not by the editor.
        scene["files"] = (current["files"] as? BoardScene.Object ?? [:]).merging(scene["files"] as? BoardScene.Object ?? [:]) { _, new in new }
        scene = (try? BoardScene.withComments(scene, BoardScene.followCommentAnchors(BoardScene.comments(current), BoardScene.elements(scene)))) ?? scene
        let fingerprint = BoardScene.fingerprint(scene)
        sessions[sessionId]?.lastFingerprint = fingerprint
        guard fingerprint != BoardScene.fingerprint(current) else { return }
        working = scene
        for (id, other) in sessions where id != sessionId && other.lastFingerprint != fingerprint {
            sessions[id]?.lastFingerprint = fingerprint
            other.send(Self.message(["type": "patch", "scene": scene]))
        }
        let dirty = fingerprint != base.fingerprint
        emit { $0.dirty = dirty; $0.save = dirty ? .unsaved : .saved; $0.error = ""; $0.notice = "" }
        persistDraft()
    }

    private func commentOperation(_ sessionId: String, _ operation: [String: Any]) async {
        guard sessions[sessionId] != nil, viewing == nil, base != nil, let current = working, state.canWrite else { return }
        do {
            working = try BoardScene.applyCommentOperation(current, operation, author: author)
            persistDraft()
            emit { $0.dirty = true; $0.save = .unsaved; $0.error = "" }
            let comments = BoardScene.comments(working!)
            for session in sessions.values { session.send(Self.message(["type": "comments", "comments": comments])) }
        } catch {
            emit { $0.error = error.localizedDescription }
        }
    }

    private func persistDraft() {
        guard let base, let working else { return }
        if BoardScene.fingerprint(working) == base.fingerprint { drafts.delete(fileId); return }
        do { try drafts.save(fileId, baseVersionId: base.versionId, baseVersionNumber: base.number, scene: working) }
        catch { emit { $0.error = "Your draft could not be stored on this \(Self.deviceName): \(error.localizedDescription)" } }
    }

    /// Asks every editor to deliver its debounced change and waits for it (sol `flushEditors`).
    private func flushEditors(timeout: Duration = .seconds(3)) async -> Bool {
        var results: [Bool] = []
        for id in sessions.keys {
            let token = UUID().uuidString
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                sessions[id]?.flushes[token] = continuation
                sessions[id]?.send(Self.message(["type": "flush", "token": token]))
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expireFlush(id, token)
                }
            }
            results.append(ok)
        }
        return !results.contains(false)
    }

    private func expireFlush(_ id: String, _ token: String) {
        sessions[id]?.flushes.removeValue(forKey: token)?.resume(returning: false)
    }

    // MARK: Save

    /// Publishes the draft as a new version against the version it started from. A stale base keeps the draft.
    @discardableResult
    public func save(summary: String = "") async -> Bool {
        guard !saving, base != nil, state.save != .saving else { return false }
        saving = true
        defer { saving = false }
        guard await flushEditors() else {
            emit { $0.save = .error; $0.error = "An open board editor did not confirm its latest changes. Your draft is kept; try Save again." }
            return false
        }
        guard viewing == nil else { emit { $0.error = "Return to the latest version before saving." }; return false }
        guard await transport.canSign() else { emit { $0.error = BoardEditError.locked.localizedDescription }; return false }
        guard state.canWrite else { emit { $0.error = "You can view this board but not save it." }; return false }
        guard state.dirty, let base, let scene = working else { emit { $0.notice = "No unsaved changes." }; return false }
        let fingerprint = BoardScene.fingerprint(scene)
        emit { $0.save = .saving; $0.error = ""; $0.notice = "" }
        do {
            let bytes = try BoardScene.serialize(scene, summary: summary, baseVersionId: base.versionId)
            let version = try await transport.publish(base.versionId, bytes, summary)
            cache[version.id] = scene
            self.base = (version.id, version.number, scene, fingerprint)
            let stillDirty = working.map(BoardScene.fingerprint) != fingerprint
            if stillDirty { persistDraft() } else { drafts.delete(fileId) }
            emit {
                $0.dirty = stillDirty; $0.save = stillDirty ? .unsaved : .saved; $0.conflicts = 0
                $0.baseVersionId = version.id; $0.baseVersionNumber = version.number
                $0.latestVersionId = version.id; $0.latestVersionNumber = version.number
                $0.notice = "Saved version \(version.number)."; $0.versions = []
            }
            return true
        } catch {
            switch BoardEditError.from(error) {
            case .stale:
                let head = try? await transport.versions()
                let latest = head.flatMap { h in h.versions.first { $0.id == h.currentVersionId } }
                emit {
                    $0.save = .stale; $0.error = BoardEditError.stale(current: nil).localizedDescription
                    if let latest { $0.latestVersionId = latest.id; $0.latestVersionNumber = latest.number }
                }
            case .unavailable:
                await fail(error)
            default:
                emit { $0.save = .error; $0.error = "The board could not be saved. Your draft is kept. \(error.localizedDescription)" }
            }
            return false
        }
    }

    // MARK: Versions

    private func fetchHead() async throws -> (id: String, number: Int, sha256: String) {
        let head = try await transport.versions()
        guard let id = head.currentVersionId, let row = head.versions.first(where: { $0.id == id }) else {
            throw BoardEditError.failed("This board has no current version.")
        }
        emit { $0.versions = head.versions; $0.latestVersionId = id; $0.latestVersionNumber = row.number }
        return (id, row.number, row.sha256)
    }

    /// Rebases the draft onto the newest saved version; the result stays unsaved for review.
    public func mergeLatest() async {
        guard let base, let draft = working else { return }
        do {
            let head = try await fetchHead()
            let latest = try await readVersion(head.id, sha256: head.sha256.isEmpty ? nil : head.sha256)
            let merged = BoardScene.rebase(base: base.scene, draft: draft, latest: latest)
            let latestFingerprint = BoardScene.fingerprint(latest)
            self.base = (head.id, head.number, latest, latestFingerprint)
            working = merged.scene
            let dirty = BoardScene.fingerprint(merged.scene) != latestFingerprint
            loadKey = "\(head.id):\(UUID().uuidString)"
            persistDraft()
            let conflicts = merged.conflicts
            emit {
                $0.dirty = dirty; $0.save = dirty ? .unsaved : .saved; $0.error = ""; $0.conflicts = conflicts
                $0.baseVersionId = head.id; $0.baseVersionNumber = head.number
                $0.notice = conflicts > 0 ? "Merged with version \(head.number); \(conflicts) change\(conflicts == 1 ? "" : "s") kept your edit. Review, then save."
                    : "Merged with version \(head.number). Review, then save."
            }
            broadcastLoad()
        } catch { await fail(error) }
    }

    /// Loads the newest saved version, discarding the draft (the screen confirms a dirty discard first).
    @discardableResult
    public func loadLatest(force: Bool = false, head given: (id: String, number: Int, sha256: String)? = nil) async -> Bool {
        do {
            let head: (id: String, number: Int, sha256: String)
            if let given { head = given } else { head = try await fetchHead() }
            let latest = try await readVersion(head.id, sha256: head.sha256.isEmpty ? nil : head.sha256)
            base = (head.id, head.number, latest, BoardScene.fingerprint(latest))
            working = latest; viewing = nil
            drafts.delete(fileId)
            loadKey = "\(head.id):\(UUID().uuidString)"
            emit {
                $0.dirty = false; $0.save = .saved; $0.error = ""; $0.notice = ""; $0.conflicts = 0
                $0.baseVersionId = head.id; $0.baseVersionNumber = head.number; $0.latestVersionId = head.id; $0.latestVersionNumber = head.number
                $0.viewingVersionId = ""; $0.viewingVersionNumber = 0
            }
            broadcastLoad()
            return true
        } catch { await fail(error); return false }
    }

    public func loadVersions() async {
        guard !state.versionsLoading else { return }
        emit { $0.versionsLoading = true }
        do {
            let head = try await transport.versions()
            let latest = head.versions.first { $0.id == head.currentVersionId }
            emit {
                $0.versions = head.versions; $0.versionsLoading = false
                if let latest { $0.latestVersionId = latest.id; $0.latestVersionNumber = latest.number }
            }
        } catch {
            emit { $0.versionsLoading = false }
            await fail(error)
        }
    }

    /// Read-only history browsing; the draft is untouched.
    public func viewVersion(_ version: BoardVersion) async {
        if version.id == base?.versionId && !state.dirty { await returnToLatest(); return }
        do {
            let scene = try await readVersion(version.id, sha256: version.sha256.isEmpty ? nil : version.sha256)
            viewing = (version.id, version.number, scene)
            emit { $0.viewingVersionId = version.id; $0.viewingVersionNumber = version.number; $0.error = "" }
            broadcastLoad()
        } catch { await fail(error) }
    }

    /// Leaves history: back to the draft, or (without one) to Tower's newest version.
    public func returnToLatest() async {
        viewing = nil
        emit { $0.viewingVersionId = ""; $0.viewingVersionNumber = 0 }
        if !state.dirty, !state.latestVersionId.isEmpty, state.latestVersionId != base?.versionId { _ = await loadLatest(force: true); return }
        broadcastLoad()
    }

    /// Starts a draft from the version being viewed, on top of the current base.
    public func restoreViewedVersion() async {
        guard let viewing, let base, state.canWrite else { return }
        working = BoardScene.restore(target: viewing.scene, latest: base.scene)
        self.viewing = nil
        loadKey = "\(base.versionId):\(UUID().uuidString)"
        persistDraft()
        emit {
            $0.dirty = true; $0.save = .unsaved; $0.viewingVersionId = ""; $0.viewingVersionNumber = 0
            $0.notice = "Older version restored as an unsaved draft. Save to make it the latest version."
        }
        broadcastLoad()
    }

    public func clearMessages() { emit { $0.error = ""; $0.notice = "" } }

    /// Renames the board (sol `renameBoard`): 1–200 characters, only with write access and an unlocked signer.
    @discardableResult
    public func rename(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= BoardScene.maxTitle else { emit { $0.error = "Enter a board name of 1–200 characters." }; return false }
        guard state.canWrite, await transport.canSign() else { emit { $0.error = "You cannot rename this board." }; return false }
        do {
            title = try await transport.rename(trimmed)
            emit { $0.title = trimmed; $0.notice = "Renamed to “\(trimmed)”."; $0.error = "" }
            return true
        } catch {
            if case .unavailable = BoardEditError.from(error) { emit { $0.error = "You cannot rename this board." } }
            else { emit { $0.error = "The board could not be renamed. \(error.localizedDescription)" } }
            return false
        }
    }

    /// Lock without background reading: the scene leaves memory and every editor is cleared. The draft stays on disk
    /// (protected) and is restored by the next `sync` after unlocking.
    public func suspend() {
        loading?.cancel(); loading = nil
        base = nil; working = nil; viewing = nil
        cache.removeAll()
        emit { $0.status = .loading; $0.canWrite = false; $0.versions = [] }
        for session in sessions.values { session.send(Self.message(["type": "clear"])) }
    }
}

extension WorkspaceSync {
    /// Tower access for one board of `workspace`, as `connection`'s identity. Reads use the identity (or its background
    /// reader); a save requires the unlocked signer of this connection.
    public func boardTransport(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String, title: String) throws -> BoardController.Transport {
        let api = api(origin: try TowerOrigin(connection.origin))
        let w = workspace.id, app = workspace.appNpub, signer = connection.signerNpub, identity = identity
        return BoardController.Transport(
            versions: { try await api.boardVersions(workspaceId: w, appNpub: app, fileId: fileId) },
            read: { version, sha in try await api.boardVersionBytes(workspaceId: w, appNpub: app, fileId: fileId, versionId: version, sha256: sha) },
            publish: { base, bytes, summary in
                do { try await identity.requireSigner(npub: signer) } catch { throw BoardEditError.locked }
                return try await api.createBoardVersion(workspaceId: w, appNpub: app, fileId: fileId, baseVersionId: base, bytes: bytes, title: title, summary: summary)
            },
            canSign: { (try? await identity.requireSigner(npub: signer)) != nil },
            rename: { name in
                do { try await identity.requireSigner(npub: signer) } catch { throw BoardEditError.locked }
                return try await api.renameBoardFile(workspaceId: w, appNpub: app, fileId: fileId, name: name)
            })
    }
}
