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
    /// Tower moved it (confirmed by its answer or by reading the document back). The cached row is updated when that
    /// succeeds; sync refreshes it by id otherwise. `draftNote` is set when an unsaved draft could not be re-based.
    case moved(DocRecord, draftNote: String?)
    /// The document changed since this device last read it; nothing moved. Refresh and decide again.
    case stale(String)
    /// The destination is where it already is.
    case sameDestination(String)
    /// The viewer may not move it from here or into the destination; nothing moved.
    case denied(String)
    /// Nothing was sent, or Tower was asked again and confirmed the document is still where it was.
    case notMoved(String)
    /// The request may have reached Tower and its answer, or the read-back, did not arrive. Nothing is claimed either way;
    /// the document is refreshed by id and must be checked before trying again. The move is never retried automatically.
    case unknown(String)
}

extension DocumentSaver {
    /// Moves a document with Tower's own operation (`POST /docs/:d/move`), online only: it needs the current row version,
    /// and an access change is never shown as done before Tower confirms it, so it is never queued for a later blind retry.
    ///
    /// A draft on this device is kept: when it is based on the version being moved, its base version follows the document
    /// (the move changes the row version, not the text, and the body check at save time still protects the text). The
    /// re-basing is a compare-and-set on the draft as it is now, so an edit made while the request was in flight is never
    /// overwritten. A draft based on an older version, or one being saved, stops the move before anything is sent.
    ///
    /// If the answer is lost or unusable, the document is read back by id: moved, still in place, or unknown, never guessed.
    public func move(docId: String, to destination: ChannelRecord, rowVersion: Int, connection: ConnectionRecord, workspace: WorkspaceRecord) async -> DocMoveResult {
        let key = DocDraft.key(connectionId: connection.id, workspaceId: workspace.id, docId: docId)
        let api: TowerAPI
        let request: Data
        do {
            if let blocked = try await draftBlocksMove(key: key, rowVersion: rowVersion) { return .notMoved(blocked) }
            api = try await self.api(connection)
            request = try rawJSON(["destination_channel_id": destination.id, "destination_scope_id": destination.scopeId, "row_version": rowVersion])
        } catch {
            return .notMoved("Not moved: \((error as? LocalizedError)?.errorDescription ?? OutboxSender.networkMessage(error)). Nothing was sent.")
        }
        let path: String
        do { path = try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(docId) + "/move" } catch { return .notMoved("Not moved: invalid document. Nothing was sent.") }
        let reply: (status: Int, body: Data)
        do {
            reply = try await api.client.exchange(method: "POST", path: path, appNpub: workspace.appNpub, jsonBody: request)
        } catch {
            return await reconcile(docId: docId, destination: destination, rowVersion: rowVersion, key: key, api: api, workspace: workspace,
                                   why: OutboxSender.networkMessage(error))
        }
        let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        let code = object?["code"] as? String ?? object?["error"] as? String
        if (200..<300).contains(reply.status) {
            if let row = object?["doc"] as? [String: Any], let doc = try? DocRecord(raw: rawJSON(row)), Self.isTheMove(doc, docId: docId, destination: destination,
                                                                                                                       from: rowVersion, workspace: workspace) {
                return await finish(doc, from: rowVersion, key: key, workspace: workspace)
            }
            return await reconcile(docId: docId, destination: destination, rowVersion: rowVersion, key: key, api: api, workspace: workspace,
                                   why: "Tower's answer could not be read")
        }
        switch (reply.status, code) {
        case (409, "stale_row_version"?): return .stale("This document changed since you opened it. Nothing was moved; reopen it and try again.")
        case (409, "same_destination"?): return .sameDestination("The document is already in that channel.")
        case (403, _): return .denied("You do not have permission to move this document there. Nothing was moved.")
        case (404, _): return .denied("The document or the destination is no longer available. Nothing was moved.")
        default:
            return await reconcile(docId: docId, destination: destination, rowVersion: rowVersion, key: key, api: api, workspace: workspace,
                                   why: "Tower answered HTTP \(reply.status)")
        }
    }

    /// A message when an unsaved draft must be dealt with first; nil when the move may go ahead.
    private func draftBlocksMove(key: String, rowVersion: Int) async throws -> String? {
        guard let draft = try await store.reader.docDraft(key: key) else { return nil }
        guard draft.baseRowVersion == rowVersion else {
            return "You have unsaved edits based on an older version of this document. Save or discard them, then move it."
        }
        guard draft.state == .editing || draft.state == .failed else {
            return "This document has edits that still need attention. Resolve them, then move it."
        }
        return nil
    }

    static func isTheMove(_ doc: DocRecord, docId: String, destination: ChannelRecord, from rowVersion: Int, workspace: WorkspaceRecord) -> Bool {
        doc.workspaceId == workspace.id && doc.id == docId.lowercased() && doc.channelId == destination.id
            && (doc.scopeId == nil || doc.scopeId == destination.scopeId) && doc.rowVersion > rowVersion
    }

    /// Tower has the document at its destination: update the cache and carry a draft along (compare-and-set).
    private func finish(_ doc: DocRecord, from rowVersion: Int, key: String, workspace: WorkspaceRecord) async -> DocMoveResult {
        _ = try? await store.writer.upsertDocs(workspaceId: workspace.id, [doc])
        var note: String?
        if let draft = try? await store.reader.docDraft(key: key), draft.baseRowVersion == rowVersion {
            let rebased = (try? await store.writer.rebaseDocDraft(key: key, workspaceId: workspace.id, from: rowVersion, to: doc.rowVersion)) ?? false
            if !rebased { note = "Your unsaved edits are still on this device, but they changed while the document moved. Saving may ask you to review them." }
        }
        return .moved(doc, draftNote: note)
    }

    /// The reply is missing or unusable: ask Tower where the document is.
    private func reconcile(docId: String, destination: ChannelRecord, rowVersion: Int, key: String, api: TowerAPI, workspace: WorkspaceRecord, why: String) async -> DocMoveResult {
        guard let current = try? await api.doc(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId) else {
            return .unknown("Tower's answer did not arrive (\(why)), so it is not known whether the document moved. It will be checked again when you reconnect. Do not repeat the move until you have looked at where it is.")
        }
        if Self.isTheMove(current, docId: docId, destination: destination, from: rowVersion, workspace: workspace) {
            return await finish(current, from: rowVersion, key: key, workspace: workspace)
        }
        if current.channelId != destination.id, current.rowVersion == rowVersion {
            _ = try? await store.writer.upsertDocs(workspaceId: workspace.id, [current])
            return .notMoved("The move did not happen (\(why)); Tower still has the document where it was.")
        }
        _ = try? await store.writer.upsertDocs(workspaceId: workspace.id, [current])
        return .unknown("The document changed while it was being moved (\(why)). It has been refreshed; check where it is before trying again.")
    }
}
