import Foundation

/// Live-update bookkeeping: tombstones from Tower events and the per-connection event cursor of each workspace.
extension StoreWriter {
    /// Removes records Tower reported deleted, in one transaction. Rows of other workspaces are never touched.
    @discardableResult
    public func applyTombstones(workspaceId: String, _ tombstones: Set<EventPlan.Tombstone>) async throws -> Int {
        guard !tombstones.isEmpty else { return 0 }
        let (removed, keys): (Int, Set<ChangeKey>) = try db.transaction {
            var removed = 0
            var keys = Set<ChangeKey>()
            func run(_ sql: String, _ id: String, _ key: StoreTable...) throws {
                try db.prepare(sql).run([.text(workspaceId), .text(id)])
                if db.changes > 0 { removed += db.changes; for k in key { keys.insert(ChangeKey(k, workspaceId)) } }
            }
            for t in tombstones {
                switch t {
                case .message(let id): try run("DELETE FROM messages WHERE workspace_id = ? AND id = ?", id, .messages)
                case .thread(let id):
                    try run("DELETE FROM threads WHERE workspace_id = ? AND id = ?", id, .threads, .messages)
                    try run("DELETE FROM messages WHERE workspace_id = ? AND thread_id = ?", id, .messages)
                case .task(let id):
                    try run("DELETE FROM tasks WHERE workspace_id = ? AND id = ?", id, .tasks)
                    try run("DELETE FROM comments WHERE workspace_id = ? AND parent = 'task' AND parent_id = ?", id, .comments)
                case .doc(let id):
                    try run("DELETE FROM docs WHERE workspace_id = ? AND id = ?", id, .docs)
                    try run("DELETE FROM doc_bodies WHERE workspace_id = ? AND doc_id = ?", id, .docBodies)
                    try run("DELETE FROM comments WHERE workspace_id = ? AND parent = 'doc' AND parent_id = ?", id, .comments)
                case .file(let id): try run("DELETE FROM files WHERE workspace_id = ? AND id = ?", id, .files)
                case .comment(let id): try run("DELETE FROM comments WHERE workspace_id = ? AND id = ?", id, .comments)
                case .reaction(let id): try run("DELETE FROM reactions WHERE workspace_id = ? AND id = ?", id, .reactions)
                }
            }
            if removed > 0 { keys.insert(ChangeKey(.access, workspaceId)) }
            return (removed, keys)
        }
        await emit(keys)
        return removed
    }

    /// Saves the event cursor without a change notification (no screen renders it), so a stream of events does not
    /// wake observers of app state.
    public func saveEventCursor(connectionId: String, workspaceId: String, _ cursor: String?) async throws {
        let key = LiveCursorKey.events(connectionId: connectionId, workspaceId: workspaceId)
        if let cursor {
            try db.prepare("INSERT INTO app_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
                .run([.text(key), .text(cursor)])
        } else {
            try db.prepare("DELETE FROM app_state WHERE key = ?").run([.text(key)])
        }
    }
}

extension StoreReader {
    public func eventCursor(connectionId: String, workspaceId: String) throws -> String? {
        try state(LiveCursorKey.events(connectionId: connectionId, workspaceId: workspaceId))
    }
}

public enum LiveCursorKey {
    public static func events(connectionId: String, workspaceId: String) -> String { "events.cursor:\(connectionId):\(workspaceId)" }
}
