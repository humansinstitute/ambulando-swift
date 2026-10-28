import Foundation

/// What moving a document changes, stated from what this device knows about the two channels. A move is not a copy: the
/// record keeps its id, body, comments, attachments and history, and its access becomes that of the destination channel.
/// A link grants no access, so links to the document keep working only for people who can read it where it now lives.
public struct DocMoveConsequences: Sendable, Equatable {
    public var lines: [String]
    /// The document leaves or enters a private conversation (a direct message or "Note to self"): confirm explicitly.
    public var touchesPrivateConversation: Bool
}

public enum DocMovePlan {
    public static func consequences(from source: ChannelRecord, to destination: ChannelRecord, viewerNpub: String?, names: [String: String] = [:]) -> DocMoveConsequences {
        func label(_ channel: ChannelRecord) -> String { SidebarNavigation.label(channel, viewerNpub: viewerNpub, names: names) }
        let sourcePrivate = SidebarNavigation.isDirectMessageChannel(source), destinationPrivate = SidebarNavigation.isDirectMessageChannel(destination)
        var lines = [
            "The document moves; it is not copied. Its text, comments, attachments and history go with it.",
            "Access follows \(label(destination)): people who can read that channel can open the document, and people who could open it only through \(label(source)) can no longer open it.",
            "Links to it keep pointing at this document, but a link never grants access.",
        ]
        if sourcePrivate {
            let count = SidebarNavigation.participants(source).count
            lines.append(count == 1 ? "It leaves your private note-to-self conversation." : "It leaves a direct message that only its participants can read.")
        }
        if destinationPrivate { lines.append("It enters a direct message: only that conversation's participants can read it.") }
        if source.scopeId != destination.scopeId { lines.append("It also changes scope, so scope-level access and the places that list it change too.") }
        return DocMoveConsequences(lines: lines, touchesPrivateConversation: sourcePrivate || destinationPrivate)
    }
}

public enum DocMoveResult: Sendable, Equatable {
    /// Tower accepted the move; the cached row is already updated (title, channel and scope read from it).
    case moved(DocRecord)
    /// The document changed since this device last read it; nothing moved. Refresh and decide again.
    case stale(String)
    /// The destination is where it already is.
    case sameDestination(String)
    /// The viewer may not move it from here or into the destination; nothing moved.
    case denied(String)
    /// Offline, locked or any other reason nothing was sent or the answer is unknown; nothing is claimed.
    case notMoved(String)
}

extension DocumentSaver {
    /// Moves a document with Tower's own operation (`POST /docs/:d/move`), online only: it needs the current row version,
    /// and an access change is never shown as done before Tower accepts it, so it is never queued for a later blind retry.
    /// A draft on this device is kept: when it was based on the version being moved, its base version moves with the
    /// document (the move changes the row version, not the text, and the body check at save time still protects the text);
    /// a draft based on an older version stops the move so nothing silently becomes a conflict.
    public func move(docId: String, to destination: ChannelRecord, rowVersion: Int, connection: ConnectionRecord, workspace: WorkspaceRecord) async -> DocMoveResult {
        do {
            let draftKey = DocDraft.key(connectionId: connection.id, workspaceId: workspace.id, docId: docId)
            let draft = try await store.reader.docDraft(key: draftKey)
            if let draft {
                guard draft.baseRowVersion == rowVersion else {
                    return .notMoved("You have unsaved edits based on an older version of this document. Save or discard them, then move it.")
                }
                guard draft.state == .editing || draft.state == .failed else {
                    return .notMoved("This document has edits that still need attention. Resolve them, then move it.")
                }
            }
            let api = try await api(connection)
            let request = try rawJSON(["destination_channel_id": destination.id, "destination_scope_id": destination.scopeId, "row_version": rowVersion])
            let reply = try await api.client.exchange(method: "POST", path: try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(docId) + "/move",
                                                      appNpub: workspace.appNpub, jsonBody: request)
            let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
            let code = object?["code"] as? String ?? object?["error"] as? String
            if (200..<300).contains(reply.status), let row = object?["doc"] as? [String: Any], let doc = try? DocRecord(raw: rawJSON(row)),
               doc.workspaceId == workspace.id, doc.id == docId.lowercased(), doc.channelId == destination.id {
                try await store.writer.upsertDocs(workspaceId: workspace.id, [doc])
                if let draft {
                    try await store.writer.saveDocDraft(DocDraft(connectionId: draft.connectionId, workspaceId: draft.workspaceId, docId: draft.docId,
                                                                  title: draft.title, body: draft.body, contentType: draft.contentType,
                                                                  baseRowVersion: doc.rowVersion, baseSha256: draft.baseSha256,
                                                                  baseStorageObjectId: draft.baseStorageObjectId, state: draft.state,
                                                                  lastError: draft.lastError, recoveryId: draft.recoveryId))
                }
                return .moved(doc)
            }
            switch (reply.status, code) {
            case (409, "stale_row_version"?): return .stale("This document changed since you opened it. Nothing was moved; reopen it and try again.")
            case (409, "same_destination"?): return .sameDestination("The document is already in that channel.")
            case (403, _): return .denied("You do not have permission to move this document there. Nothing was moved.")
            case (404, _): return .denied("The document or the destination is no longer available. Nothing was moved.")
            default: return .notMoved("Tower did not move the document (HTTP \(reply.status)). Nothing was changed.")
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? OutboxSender.networkMessage(error)
            return .notMoved("Not moved: \(message). Moving needs a connection; nothing was changed.")
        }
    }
}
