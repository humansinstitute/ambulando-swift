import AmbulandoCore
import SwiftUI

/// Channel-owned HTML artefact viewer with compact control-bar version switcher and
/// shared PostgreSQL threaded visual comments (desktop right-click Add comment).
struct HTMLArtefactReviewView: View {
    @Environment(AppModel.self) private var model
    let file: FileRecord
    let workspace: WorkspaceRecord

    @State private var payload: HTMLArtefactPayload?
    @State private var selectedVersionId: String?
    @State private var failure: String?
    @State private var editingSource = false
    @State private var reloadNonce = 0

    // Visual review state (boundary-scoped; cleared on boundary/file change).
    @State private var showCommentsPanel = false
    @State private var showEarlierUnresolved = true
    @State private var commentList: FileCommentList?
    @State private var commentsBusy = false
    @State private var commentsError: String?
    @State private var commentsReload = 0
    @State private var pendingTarget: HTMLCommentAnchor?
    @State private var focusedThreadId: String?
    @State private var focusThreadNonce: (String, Int)?
    @State private var anchorMatches: [String: Bool] = [:]
    @State private var drafts: [String: FileCommentDraft] = [:]
    @State private var replyAcceptedNonce: [String: Int] = [:]
    @State private var editingCommentId: String?
    @State private var editBodyText = ""

    private var boundaryKey: [String] {
        [file.id, workspace.id, model.connection?.id ?? "", model.connection?.signerNpub ?? "", String(model.canRead)]
    }

    private var draftStore: FileCommentDraftStore? {
        guard let c = model.connection else { return nil }
        let dir = BoardRegistry.draftsDirectory(c.id, dataDirectory: model.fixture?.directory)
        return FileCommentDraftStore(url: dir.appendingPathComponent("file-comments-\(workspace.id)-\(file.id).json"))
    }

    private var viewedVersionId: String? { payload?.versionId ?? selectedVersionId }
    private var viewedVersionNumber: Int { payload?.versionNumber ?? 1 }
    private var isViewingLatest: Bool {
        selectedVersionId == nil || (payload?.currentVersionId != nil && selectedVersionId == payload?.currentVersionId)
    }

    private var visibleThreads: [FileCommentThread] {
        groupFileCommentThreads(
            commentList?.comments ?? [],
            viewedVersionId: viewedVersionId,
            isViewingLatest: isViewingLatest,
            includeEarlierUnresolved: showEarlierUnresolved
        )
    }

    private var openThreadCount: Int { visibleThreads.filter { !$0.root.isResolved }.count }

    private var anchorSpecs: [HTMLAnchorTargetSpec] {
        visibleThreads.compactMap { thread in
            guard let anchor = thread.root.anchor, anchor.kind == "html_element" else { return nil }
            return HTMLAnchorTargetSpec(
                threadId: thread.root.id,
                anchor: anchor,
                resolved: thread.root.isResolved,
                replyCount: thread.replies.count
            )
        }
    }

    private var permissions: FileCommentPermissions {
        commentList?.permissions ?? FileCommentPermissions()
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let failure {
                EmptyNote(title: "HTML artefact unavailable", systemImage: "lock", detail: failure)
                Button("Retry") { reloadNonce += 1 }.padding(.bottom, 12)
            } else if let payload {
                HStack(spacing: 0) {
                    SandboxedHTMLView(
                        html: payload.html,
                        interactive: true,
                        anchorSpecs: anchorSpecs,
                        focusThreadNonce: focusThreadNonce,
                        onTargetSelected: { anchor in
                            guard payload.versionId == viewedVersionId else { return }
                            var enriched = anchor
                            enriched.fileVersionId = payload.versionId
                            enriched.fileVersionNumber = payload.versionNumber
                            enriched.versionDigest = payload.digest.count == 64 ? payload.digest : nil
                            pendingTarget = enriched
                            showCommentsPanel = true
                        },
                        onAnchorMatches: { matches in
                            guard payload.versionId == viewedVersionId else { return }
                            anchorMatches = matches
                        },
                        onBadgeTapped: { threadId in
                            focusedThreadId = threadId
                            showCommentsPanel = true
                        }
                    )
                    .id("\(file.id):\(payload.versionId):\(reloadNonce)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showCommentsPanel {
                        Divider()
                        commentsPanel
                            .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                    }
                }
            } else {
                ProgressView("Loading HTML…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $editingSource, onDismiss: { reloadNonce += 1 }) {
            HTMLSourceSheet(file: file, workspace: workspace)
        }
        .task(id: boundaryKey + [selectedVersionId ?? "latest", String(reloadNonce)]) {
            await loadHTML()
        }
        .task(id: boundaryKey + [String(commentsReload)]) {
            drafts = draftStore?.loadAll() ?? [:]
            await loadComments()
            while !Task.isCancelled && model.canRead {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled || !model.canRead { break }
                await loadComments()
            }
        }
        .onChange(of: boundaryKey) { _, _ in
            payload = nil
            commentList = nil
            drafts = [:]
            replyAcceptedNonce = [:]
            pendingTarget = nil
            focusedThreadId = nil
            anchorMatches = [:]
            commentsError = nil
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Label("Sandboxed HTML", systemImage: "lock.shield")
                .font(.amb(.caption))
                .foregroundStyle(Amb.mutedForeground)
            Spacer()
            // Compact version selector directly in control bar; browsing history never mutates current head.
            if let versions = payload?.versions, !versions.isEmpty {
                Menu {
                    ForEach(versions.sorted { $0.versionNumber > $1.versionNumber }) { v in
                        let isHead = v.id == payload?.currentVersionId
                        Button {
                            selectedVersionId = isHead ? nil : v.id
                            pendingTarget = nil
                            anchorMatches = [:]
                        } label: {
                            let label = isHead ? "v\(v.versionNumber) (Latest)" : "v\(v.versionNumber)"
                            if v.id == viewedVersionId {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isViewingLatest ? "v\(viewedVersionNumber)" : "v\(viewedVersionNumber) · History")
                            .font(.amb(.caption).weight(.medium))
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("artefacts.versionPicker")
            }

            Button {
                showCommentsPanel.toggle()
                if showCommentsPanel { commentsReload += 1 }
            } label: {
                Label(openThreadCount > 0 ? "Comments (\(openThreadCount))" : "Comments", systemImage: "bubble.left.and.bubble.right")
                    .font(.amb(.caption).weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("artefacts.threads")

            Menu {
                Button("Refresh comments", systemImage: "arrow.clockwise") { commentsReload += 1 }
                Divider()
                Button("Edit source…", systemImage: "chevron.left.forwardslash.chevron.right") { editingSource = true }
                    .disabled(!model.isUnlocked)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("artefacts.menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var commentsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Comments · v\(viewedVersionNumber)").font(.amb(.headline))
                Spacer()
                Button { commentsReload += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .disabled(commentsBusy)
            }
            Text("Right-click any element in the HTML and choose “Add comment”.")
                .font(.amb(.caption2))
                .foregroundStyle(Amb.mutedForeground)

            if !permissions.canComment {
                Text("Read-only access: you can view feedback, not add comments.")
                    .font(.amb(.caption))
                    .foregroundStyle(Amb.mutedForeground)
            } else if !permissions.canEditSource {
                Text("Comment access: you can comment and reply (source editing requires file write access).")
                    .font(.amb(.caption))
                    .foregroundStyle(Amb.mutedForeground)
            }

            if isViewingLatest {
                Toggle("Show unresolved from earlier versions", isOn: $showEarlierUnresolved)
                    .font(.amb(.caption))
            }

            if let commentsError {
                Text(commentsError)
                    .font(.amb(.caption))
                    .foregroundStyle(Amb.destructive)
                    .padding(6)
                    .background(Amb.destructive.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            if let target = pendingTarget, let versionId = viewedVersionId {
                let key = target.draftKey(versionId: versionId)
                NewCommentComposer(
                    target: target,
                    initialBody: drafts[key]?.body ?? "",
                    requestId: drafts[key]?.clientRequestId ?? UUID().uuidString.lowercased(),
                    canComment: permissions.canComment,
                    busy: commentsBusy,
                    onDraftChange: { body, reqId in
                        saveDraft(FileCommentDraft(key: key, body: body, clientRequestId: reqId, fileVersionId: versionId, anchor: target))
                    },
                    onSubmit: { body, reqId in
                        Task { await submitRoot(anchor: target, versionId: versionId, body: body, requestId: reqId, draftKey: key) }
                    },
                    onCancel: { pendingTarget = nil }
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if visibleThreads.isEmpty {
                        Text("No comments for v\(viewedVersionNumber) yet.")
                            .font(.amb(.footnote))
                            .foregroundStyle(Amb.mutedForeground)
                            .padding(.top, 12)
                    } else {
                        ForEach(visibleThreads) { thread in
                            threadCard(thread)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func threadCard(_ thread: FileCommentThread) -> some View {
        let root = thread.root
        let hasElementTarget = root.anchor?.kind == "html_element"
        let matched = hasElementTarget ? anchorMatches[root.id] : nil
        let replyKey = "reply:\(root.id)"

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shortAuthor(root.createdByActorNpub)).font(.amb(.caption).weight(.semibold))
                Spacer()
                Text(root.isResolved ? "Resolved" : "Open")
                    .font(.amb(.caption2).weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((root.isResolved ? Color.secondary : Color.accentColor).opacity(0.15), in: Capsule())
            }

            HStack(spacing: 8) {
                Text(String(root.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                    .font(.amb(.caption2))
                    .foregroundStyle(Amb.mutedForeground)
                if thread.fromEarlierVersion {
                    let label = thread.originVersionNumber.map { "From v\($0) · View" } ?? "Earlier · View"
                    Button(label) {
                        selectedVersionId = thread.originVersionId == payload?.currentVersionId ? nil : thread.originVersionId
                    }
                    .buttonStyle(.link)
                    .font(.amb(.caption2))
                }
            }

            if let anchor = root.anchor {
                HStack(spacing: 6) {
                    Text(anchor.targetSummary())
                        .font(.amb(.caption))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                    Spacer()
                    if matched == true {
                        Button("Highlight") {
                            let next = (focusThreadNonce?.1 ?? 0) + 1
                            focusThreadNonce = (root.id, next)
                        }
                        .buttonStyle(.link)
                        .font(.amb(.caption2))
                    } else if matched == false {
                        Text("Target detached in v\(viewedVersionNumber)")
                            .font(.amb(.caption2))
                            .foregroundStyle(Amb.destructive)
                    }
                }
            }

            if editingCommentId == root.id {
                TextField("Edit comment", text: $editBodyText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        let text = editBodyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        editingCommentId = nil
                        if !text.isEmpty { Task { await editComment(root, body: text) } }
                    }.disabled(commentsBusy)
                    Button("Cancel") { editingCommentId = nil }
                }.font(.amb(.caption))
            } else {
                Text(root.body).font(.amb(.callout))
            }

            HStack(spacing: 10) {
                if root.canResolve {
                    Button(root.isResolved ? "Reopen" : "Resolve") {
                        Task { await toggleResolve(root) }
                    }.buttonStyle(.link).font(.amb(.caption)).disabled(commentsBusy)
                }
                if root.canEdit && editingCommentId != root.id {
                    Button("Edit") {
                        editingCommentId = root.id
                        editBodyText = root.body
                    }.buttonStyle(.link).font(.amb(.caption)).disabled(commentsBusy)
                }
                if root.canDelete {
                    Button("Delete") {
                        Task { await deleteComment(root) }
                    }.buttonStyle(.link).font(.amb(.caption)).disabled(commentsBusy)
                }
            }

            if !thread.replies.isEmpty {
                Divider()
                ForEach(thread.replies) { reply in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(shortAuthor(reply.createdByActorNpub)).font(.amb(.caption2).weight(.semibold))
                            Text(String(reply.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                                .font(.amb(.caption2))
                                .foregroundStyle(Amb.mutedForeground)
                        }
                        Text(reply.body).font(.amb(.caption))
                    }
                    .padding(.leading, 10)
                }
            }

            if permissions.canComment {
                ReplyComposer(
                    initialBody: drafts[replyKey]?.body ?? "",
                    requestId: drafts[replyKey]?.clientRequestId ?? UUID().uuidString.lowercased(),
                    acceptedNonce: replyAcceptedNonce[root.id] ?? 0,
                    busy: commentsBusy,
                    onDraftChange: { body, reqId in
                        saveDraft(FileCommentDraft(key: replyKey, body: body, clientRequestId: reqId, parentCommentId: root.id))
                    },
                    onSubmit: { body, reqId in
                        Task { await submitReply(parentId: root.id, body: body, requestId: reqId, draftKey: replyKey) }
                    }
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(focusedThreadId == root.id ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
    }

    private func shortAuthor(_ npub: String?) -> String {
        let clean = (npub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Member" }
        return clean.count > 16 ? "\(clean.prefix(10))…\(clean.suffix(4))" : clean
    }

    private func saveDraft(_ draft: FileCommentDraft) {
        if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.removeValue(forKey: draft.key)
            try? draftStore?.remove(draft.key)
        } else {
            drafts[draft.key] = draft
            try? draftStore?.save(draft)
        }
    }

    private func loadHTML() async {
        // Clear old viewer immediately so a late callback from the previous version cannot target the new selection.
        payload = nil
        anchorMatches = [:]
        guard model.canRead, let sync = model.sync, let c = model.connection else {
            failure = "Unlock to open this artefact."
            return
        }
        let capturedBoundary = boundaryKey
        let capturedSelected = selectedVersionId
        failure = nil
        do {
            let loaded = try await sync.artefactHTMLPayload(c, workspace, fileId: file.id, versionId: capturedSelected)
            guard !Task.isCancelled, boundaryKey == capturedBoundary, selectedVersionId == capturedSelected else { return }
            payload = loaded
        } catch is CancellationError {}
        catch {
            if boundaryKey == capturedBoundary { failure = error.localizedDescription }
        }
    }

    private func loadComments() async {
        guard model.canRead, let sync = model.sync, let c = model.connection else { return }
        let capturedBoundary = boundaryKey
        do {
            let list = try await sync.allFileComments(c, workspace, fileId: file.id)
            guard !Task.isCancelled, boundaryKey == capturedBoundary else { return }
            commentList = list
            commentsError = nil
        } catch is CancellationError {}
        catch {
            if boundaryKey == capturedBoundary { commentsError = error.localizedDescription }
        }
    }

    private func submitRoot(anchor: HTMLCommentAnchor, versionId: String, body: String, requestId: String, draftKey: String) async {
        guard let sync = model.sync, let c = model.connection else { return }
        let capturedBoundary = boundaryKey
        let capturedStore = draftStore
        commentsBusy = true; commentsError = nullError
        defer { if boundaryKey == capturedBoundary { commentsBusy = false } }
        do {
            _ = try await sync.createFileComment(c, workspace, fileId: file.id, body: body, fileVersionId: versionId, anchor: anchor, clientRequestId: requestId)
            try? capturedStore?.remove(draftKey)
            guard boundaryKey == capturedBoundary else { return }
            drafts.removeValue(forKey: draftKey)
            pendingTarget = nil
            await loadComments()
        } catch {
            if boundaryKey == capturedBoundary {
                commentsError = "Could not post comment (draft preserved): \(error.localizedDescription)"
            }
        }
    }

    private func submitReply(parentId: String, body: String, requestId: String, draftKey: String) async {
        guard let sync = model.sync, let c = model.connection else { return }
        let capturedBoundary = boundaryKey
        let capturedStore = draftStore
        commentsBusy = true; commentsError = nil
        defer { if boundaryKey == capturedBoundary { commentsBusy = false } }
        do {
            _ = try await sync.createFileComment(c, workspace, fileId: file.id, body: body, parentCommentId: parentId, clientRequestId: requestId)
            try? capturedStore?.remove(draftKey)
            guard boundaryKey == capturedBoundary else { return }
            drafts.removeValue(forKey: draftKey)
            replyAcceptedNonce[parentId, default: 0] += 1
            await loadComments()
        } catch {
            if boundaryKey == capturedBoundary {
                commentsError = "Could not post reply (draft preserved): \(error.localizedDescription)"
            }
        }
    }

    private var nullError: String? { nil }

    private func toggleResolve(_ comment: FileCommentRecord) async {
        guard let sync = model.sync, let c = model.connection else { return }
        commentsBusy = true; commentsError = nil
        defer { commentsBusy = false }
        do {
            _ = try await sync.updateFileComment(c, workspace, fileId: file.id, commentId: comment.id, rowVersion: comment.rowVersion, commentStatus: comment.isResolved ? "open" : "resolved")
            await loadComments()
        } catch {
            commentsError = error.localizedDescription
        }
    }

    private func editComment(_ comment: FileCommentRecord, body: String) async {
        guard let sync = model.sync, let c = model.connection else { return }
        commentsBusy = true; commentsError = nil
        defer { commentsBusy = false }
        do {
            _ = try await sync.updateFileComment(c, workspace, fileId: file.id, commentId: comment.id, rowVersion: comment.rowVersion, body: body)
            await loadComments()
        } catch {
            commentsError = error.localizedDescription
        }
    }

    private func deleteComment(_ comment: FileCommentRecord) async {
        guard let sync = model.sync, let c = model.connection else { return }
        commentsBusy = true; commentsError = nil
        defer { commentsBusy = false }
        do {
            try await sync.deleteFileComment(c, workspace, fileId: file.id, commentId: comment.id, rowVersion: comment.rowVersion)
            await loadComments()
        } catch {
            commentsError = error.localizedDescription
        }
    }
}

private struct NewCommentComposer: View {
    let target: HTMLCommentAnchor
    let initialBody: String
    let requestId: String
    let canComment: Bool
    let busy: Bool
    let onDraftChange: (String, String) -> Void
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Comment on \(target.targetSummary())").font(.amb(.caption).weight(.semibold)).lineLimit(2)
                Spacer()
                Button("Clear", action: onCancel).buttonStyle(.link).font(.amb(.caption))
            }
            TextField("Add feedback…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .disabled(!canComment || busy)
                .onChange(of: text) { _, next in onDraftChange(next, requestId) }
            HStack {
                Spacer()
                Button(busy ? "Posting…" : "Post comment") {
                    onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines), requestId)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canComment || busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { text = initialBody }
    }
}

private struct ReplyComposer: View {
    let initialBody: String
    let requestId: String
    let acceptedNonce: Int
    let busy: Bool
    let onDraftChange: (String, String) -> Void
    let onSubmit: (String, String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("Reply…", text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
                .onChange(of: text) { _, next in onDraftChange(next, requestId) }
            Button("Reply") {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // Do not clear text before server acceptance; parent bumps acceptedNonce on confirmed save.
                onSubmit(trimmed, requestId)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { text = initialBody }
        .onChange(of: acceptedNonce) { _, _ in text = "" }
    }
}
