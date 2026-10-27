import AmbulandoCore
import PhotosUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A sent message with its reactions, attachments and the actions Tower allows: react (anyone who can write here),
/// edit and delete (the author; edits are signed kind 33358 revisions). Unsent edits and deletes show on the message
/// until Tower accepts them.
struct MessageCell: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.people == rhs.people && lhs.workspace == rhs.workspace && lhs.extras == rhs.extras
            && lhs.route == rhs.route && lhs.replyCount == rhs.replyCount && lhs.lastReplyAt == rhs.lastReplyAt && lhs.threadTitle == rhs.threadTitle
    }

    @Environment(AppModel.self) private var model
    let message: MessageRecord
    let people: PeopleDirectory
    let workspace: WorkspaceRecord
    let extras: MessageExtras
    var route: ChatRoute? = nil
    var replyCount = 0
    var lastReplyAt: String? = nil
    /// Tower's thread title, shown above the root when it says something the root's first words do not.
    var threadTitle: String? = nil
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var gettingItDone = false
    @State private var autopilot: URL?
    @Environment(\.openURL) private var openURL

    private var writes: [WriteItem] { extras.writes[message.id] ?? [] }
    private var distinctTitle: String? {
        guard let threadTitle else { return nil }
        let title = MentionCodec.plain(threadTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = MentionCodec.plain(message.body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.hasPrefix(title.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))) else { return nil }
        return title
    }
    private var pendingEdit: WriteItem? { writes.last { $0.kind == .messageEdit } }
    private var pendingDelete: WriteItem? { writes.last { $0.kind == .messageDelete } }
    private var mine: Bool { message.senderNpub != nil && message.senderNpub == model.identity.npub }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let route {
                    ThreadRouteLink(route: route) {
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = distinctTitle {
                                Label(title, systemImage: "text.bubble")
                                    .font(.amb(.caption).weight(.semibold)).foregroundStyle(Amb.itemHeading).lineLimit(1)
                                    .padding(.leading, 60).padding(.trailing, 16).padding(.top, 6)
                            }
                            row
                            if replyCount > 0 {
                                // sol `.chat-post-reply-bar.channel-thread-card-open`: a rule, then the reply count in primary.
                                VStack(spacing: 0) {
                                    Rectangle().fill(Amb.border).frame(height: 1)
                                    HStack(spacing: 6) {
                                        Image(systemName: "bubble.left.and.text.bubble.right")
                                        Text("\(replyCount) \(replyCount == 1 ? "reply" : "replies")").fontWeight(.bold)
                                        if let lastReplyAt { Text("· last \(ChatTime.label(lastReplyAt))").fontWeight(.regular).foregroundStyle(Amb.mutedForeground) }
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right").font(.amb(.caption2).weight(.bold)).foregroundStyle(Amb.mutedForeground)
                                    }
                                    .font(.amb(.caption)).foregroundStyle(Amb.primary)
                                    .padding(.vertical, 8)
                                }
                                .padding(.leading, 60).padding(.trailing, 16).padding(.bottom, 2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(replyCount > 0 ? "Opens the thread" : "")
                    .accessibilityIdentifier("thread.\(replyCount)")
                } else {
                    row
                }
            }
            .overlay(alignment: .topTrailing) { messageControls }
            ReactionBar(reactions: reactions, me: model.identity.npub) { toggle($0) }
                .padding(.leading, 60).padding(.trailing, 16)
            ForEach(writes.filter { [.messageEdit, .messageDelete].contains($0.kind) }) { item in
                WriteStatusLine(item: item, label: item.kind == .messageEdit ? "Edit" : "Delete").padding(.leading, 60).padding(.trailing, 16).padding(.bottom, 6)
            }
        }
        .contextMenu { actions }
        .sheet(isPresented: $gettingItDone) { GetItDoneSheet(message: message, workspace: workspace) }
        .sheet(isPresented: $editing) { MessageEditSheet(message: message, workspace: workspace, currentBody: pendingEdit?.string("body") ?? message.body) }
        .confirmationDialog("Delete this message for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.submit(WriteIntent(kind: .messageDelete, targetId: message.id, payload: ["row_version": message.rowVersion]), in: workspace)
            }
        }
    }

    /// The message's actions, shared by the visible ⋮ menu and the long-press / right-click menu.
    @ViewBuilder private var actions: some View {
        Menu {
            ForEach(ReactionEmoji.allCases, id: \.self) { emoji in
                Button { toggle(emoji.rawValue) } label: { Label(emoji.name, systemImage: emoji.symbol) }
                    .accessibilityIdentifier("react.\(emoji.rawValue)")
            }
        } label: { Label("React", systemImage: "face.smiling") }
            .accessibilityIdentifier("message.react")
        if !message.deleted {
            Button { gettingItDone = true } label: { Label("Get it done", systemImage: "checkmark.circle") }
                .accessibilityIdentifier("message.getitdone")
        }
        if message.threadId != nil && !message.deleted {
            Button { model.branch(from: message, in: workspace, recipient: agentSender) } label: { Label("Branch from here", systemImage: "arrow.triangle.branch") }
                .accessibilityIdentifier("message.branch")
        }
        Button { Pasteboard.copy(MentionCodec.plain(message.body)) } label: { Label("Copy message", systemImage: "doc.on.doc") }
            .accessibilityIdentifier("message.copy")
        if AutopilotSessionLink.sessionId(in: message.raw) != nil {
            Button { Task { await openAutopilot() } } label: { Label("Autopilot Link", systemImage: "arrow.up.forward.app") }
                .accessibilityIdentifier("message.autopilot")
        }
        Button { Pasteboard.copy(Self.reference(for: message)) } label: { Label("FD Ref", systemImage: "link") }
            .accessibilityIdentifier("message.ref")
        if mine && !message.deleted {
            Button { editing = true } label: { Label("Edit", systemImage: "pencil") }.accessibilityIdentifier("message.edit")
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete message", systemImage: "trash") }.accessibilityIdentifier("message.delete")
        }
    }

    /// The sender when it is a workspace agent: a branch keeps talking to it, as the web does.
    private var agentSender: String? {
        guard let npub = message.senderNpub, people.isAgent(npub) else { return nil }
        return npub
    }

    private func openAutopilot() async {
        guard let url = await model.autopilotURL(for: message, in: workspace) else {
            model.notice = "This workspace has no Autopilot address to open this session."
            return
        }
        openURL(url)
    }

    /// Flight Deck reference to this message, as the web's "FD Ref" copies it.
    static func reference(for message: MessageRecord) -> String {
        "@[Chat message](mention:chat:\(message.channelId)#\(message.id))"
    }

    /// What is true of this stored message: it came from Tower, unless a change to it is still waiting or was refused.
    private var sync: MessageSyncState {
        let changes = writes.filter { [.messageEdit, .messageDelete].contains($0.kind) }
        if changes.contains(where: { !$0.isPending }) { return .failed }
        if changes.contains(where: \.isPending) { return .pending }
        return .synced
    }

    private var messageControls: some View {
        HStack(spacing: 4) {
            SyncDot(state: sync)
            #if os(macOS)
            NativeMessageActions(items: nativeActions).frame(width: 28, height: 28)
                .accessibilityLabel("Message actions")
                .accessibilityIdentifier("message.actions")
            #else
            Menu { actions } label: {
                Image(systemName: "ellipsis").font(.amb(.footnote).weight(.bold)).foregroundStyle(Amb.mutedForeground)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Message actions")
            .accessibilityIdentifier("message.actions")
            #endif
        }
        .padding(.top, 6).padding(.trailing, 10)
    }

    #if os(macOS)
    private var nativeActions: [NativeMessageAction] {
        var items = [NativeMessageAction("React", "face.smiling", children: ReactionEmoji.allCases.map { emoji in
            NativeMessageAction(emoji.name, emoji.symbol) { toggle(emoji.rawValue) }
        })]
        if !message.deleted {
            items.append(NativeMessageAction("Get it done", "checkmark.circle") { gettingItDone = true })
        }
        if message.threadId != nil && !message.deleted {
            items.append(NativeMessageAction("Branch from here", "arrow.triangle.branch") {
                model.branch(from: message, in: workspace, recipient: agentSender)
            })
        }
        items.append(NativeMessageAction("Copy message", "doc.on.doc") { Pasteboard.copy(MentionCodec.plain(message.body)) })
        if AutopilotSessionLink.sessionId(in: message.raw) != nil {
            items.append(NativeMessageAction("Autopilot Link", "arrow.up.forward.app") { Task { await openAutopilot() } })
        }
        items.append(NativeMessageAction("FD Ref", "link") { Pasteboard.copy(Self.reference(for: message)) })
        if mine && !message.deleted {
            items.append(NativeMessageAction("Edit", "pencil") { editing = true })
            items.append(NativeMessageAction("Delete message", "trash") { confirmDelete = true })
        }
        return items
    }
    #endif

    private var row: some View {
        MessageRow(message: message, people: people, bodyOverride: pendingEdit?.isPending == true ? pendingEdit?.string("body") : nil, workspace: workspace)
            .opacity(pendingDelete?.isPending == true ? 0.45 : 1)
    }

    /// Stored reactions plus unsent ones (and minus unsent removals).
    private var reactions: [ReactionRecord] {
        var list = extras.reactions[message.id] ?? []
        for item in writes where item.isPending {
            if item.kind == .reactionAdd, let emoji = item.string("emoji") {
                list.append(ReactionRecord(workspaceId: workspace.id, id: "pending-\(item.id)", targetType: "message", targetId: message.id, emoji: emoji,
                                           reactorNpub: model.identity.npub, updatedAt: item.createdAt))
            }
            if item.kind == .reactionRemove, let id = item.string("reaction_id") { list.removeAll { $0.id == id } }
        }
        return list
    }

    private func toggle(_ emoji: String) {
        if let existing = reactions.first(where: { $0.emoji == emoji && $0.reactorNpub == model.identity.npub }) {
            if existing.id.hasPrefix("pending-") {
                Task { try? await model.store?.writer.discardWrite(id: String(existing.id.dropFirst("pending-".count))) }
            } else {
                model.submit(WriteIntent(kind: .reactionRemove, targetId: message.id, payload: ["reaction_id": existing.id]), in: workspace)
            }
        } else {
            model.submit(WriteIntent(kind: .reactionAdd, targetId: message.id, payload: ["target_type": "message", "emoji": emoji]), in: workspace)
        }
    }
}

struct ReactionBar: View {
    let reactions: [ReactionRecord]
    let me: String?
    let toggle: (String) -> Void

    var body: some View {
        let counts = Dictionary(grouping: reactions, by: \.emoji)
        let ordered = ReactionEmoji.allCases.filter { counts[$0.rawValue] != nil }
        if !ordered.isEmpty {
            HStack(spacing: 6) {
                ForEach(ordered, id: \.self) { emoji in
                    let list = counts[emoji.rawValue] ?? []
                    let mine = list.contains { $0.reactorNpub == me }
                    Button { toggle(emoji.rawValue) } label: {
                        HStack(spacing: 4) { Image(systemName: emoji.symbol); Text("\(list.count)") }.font(.amb(.caption).weight(.semibold))
                            .foregroundStyle(emoji == .heart ? Amb.destructive : Amb.primary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            // sol `.reaction-pill` / `.reaction-pill-active`: bordered on white; yours on the muted fill.
                            .background(mine ? Amb.selectedFill : Amb.card, in: Capsule())
                            .overlay(Capsule().stroke(mine ? Amb.primary : Amb.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(emoji.name), \(list.count)\(mine ? ", including you" : "")")
                    .accessibilityIdentifier("reaction.\(emoji.rawValue)")
                }
            }
            .padding(.bottom, 6)
        }
    }
}

struct MessageEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: MessageRecord
    let workspace: WorkspaceRecord
    let currentBody: String
    @State private var text = ""
    @State private var mentions: [Mention] = []

    var body: some View {
        NavigationStack {
            Form {
                ContentTextEntry(text: $text, placeholder: "Message", workspace: workspace, field: "edit-message-\(message.id)").lineLimit(3...12).accessibilityIdentifier("editmessage.field")
                Text("Edits are signed with your identity and replace the message for everyone.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            .navigationTitle("Edit message")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("editmessage.save")
                }
            }
            .onAppear { let decoded = MentionCodec.decode(body: currentBody); text = decoded.text; mentions = decoded.mentions }
        }
    }

    private func save() {
        let (encoded, kept) = MentionCodec.encode(text: text, selected: mentions)
        let body = OutboxRequest.normalizedBody(encoded)
        guard !body.isEmpty, body != message.body else { dismiss(); return }
        let payload: [String: any Sendable] = ["channel_id": message.channelId, "thread_id": message.threadId ?? "", "body": body,
                                               "row_version": message.rowVersion, "mentions": kept.map(\.requestObject)]
        if model.submit(WriteIntent(kind: .messageEdit, targetId: message.id, payload: payload), in: workspace) { dismiss() }
    }
}

/// An image or file attached to a message. Bytes come through the signed storage route on the pinned origin and are
/// cached; nothing is fetched while locked.
struct AttachmentView: View {
    @Environment(AppModel.self) private var model
    let attachment: MessageAttachment
    let workspace: WorkspaceRecord
    @State private var url: URL?
    @State private var preview: URL?

    var body: some View {
        if attachment.kind == "image" {
            // Inline, downsampled and cached like images in Markdown and documents.
            StorageImageView(objectId: attachment.storageObjectId, alt: attachment.filename, workspace: workspace, maxHeight: 260, maxWidth: 280)
        } else {
            Button {
                if let url { preview = url } else { model.downloadAttachment(attachment.storageObjectId, in: workspace) }
            } label: {
                Label(attachment.filename, systemImage: "paperclip").font(.amb(.footnote))
                    .padding(8).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            }
            .buttonStyle(.plain)
            .quickLookPreview($preview)
            .accessibilityIdentifier("attachment")
            .task(id: attachment.storageObjectId) { load() }
            .onChange(of: model.syncStatus) { _, _ in if url == nil { load() } }
        }
    }

    private func load() {
        url = model.fileCache?.attachment(workspaceId: workspace.id, objectId: attachment.storageObjectId)
    }
}

/// Selected photos for the composer, privacy-stripped and staged before they join the outbox.
struct ComposerAttachments: View {
    @Binding var attachments: [PendingAttachment]
    let staging: URL?
    @State private var thumbnails: [String: PlatformImage] = [:]

    var body: some View {
        if attachments.contains(where: { $0.text == nil }) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments.filter { $0.text == nil }) { a in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let image = thumbnails[a.id] { Image(platformImage: image).resizable().scaledToFill() } else { Color(Amb.muted) }
                            }
                            .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                            Button { remove(a) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }
                                .accessibilityLabel("Remove photo")
                        }
                        .task(id: a.id) { await thumbnail(a) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .accessibilityIdentifier("composer.attachments")
        }
    }

    private func thumbnail(_ a: PendingAttachment) async {
        guard let staging else { return }
        let url = staging.appendingPathComponent(a.staged)
        thumbnails[a.id] = await Task.detached { StorageImageCache.downsample(url, maxPixels: 256, scale: 2) }.value
    }

    private func remove(_ a: PendingAttachment) {
        attachments.removeAll { $0.id == a.id }
        if let staging { try? FileManager.default.removeItem(at: staging.appendingPathComponent(a.staged)) }
    }
}

/// Images and files already uploaded for this draft (their storage Markdown sits after the typed text): a thumbnail
/// for each image that opens full size, a named chip for each file, and a button to remove either.
struct ComposerUploadedThumbnails: View {
    let text: String
    let workspace: WorkspaceRecord
    let remove: (String) -> Void

    var body: some View {
        let items = StorageMarkdown.rawReferences(in: text).map(\.attachment)
        if !items.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.storageObjectId) { item in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if item.kind == "image" {
                                    StorageImageView(objectId: item.storageObjectId, alt: item.filename, workspace: workspace, maxHeight: 64, maxWidth: 96)
                                } else {
                                    Label(item.filename, systemImage: "paperclip").font(.amb(.footnote)).lineLimit(1)
                                        .padding(8).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                                }
                            }
                            .padding(.top, 6).padding(.trailing, 6)
                            Button { remove(item.storageObjectId) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(item.filename)")
                                .accessibilityIdentifier("composer.uploaded.remove")
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 4)
            }
            .accessibilityIdentifier("composer.uploaded")
        }
    }
}

/// Images and files pasted into this composer while they upload: what is happening, and Retry / Remove. Only uploads
/// whose placeholder is still in the text are shown.
struct ComposerPastedUploads: View {
    let uploads: ComposerUploads
    let target: ChatTarget
    let text: String

    var body: some View {
        let shown = uploads.uploads(for: target).filter { UploadToken.contains(token: $0.token, in: text) }
        let notice = uploads.notice(for: target)
        if !shown.isEmpty || notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { row($0) }
                if let notice {
                    Text(notice).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("composer.upload.notice")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .accessibilityIdentifier("composer.uploads")
        }
    }

    private func row(_ upload: ComposerUpload) -> some View {
        HStack(spacing: 8) {
            Image(systemName: upload.kind == .image ? "photo" : "doc").foregroundStyle(Amb.mutedForeground)
            VStack(alignment: .leading, spacing: 1) {
                Text(upload.filename).font(.amb(.footnote).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1).truncationMode(.middle)
                Text(status(upload)).font(.amb(.caption)).foregroundStyle(isFailed(upload) ? Amb.destructive : Amb.mutedForeground).lineLimit(2)
                    .accessibilityIdentifier("composer.upload.status")
            }
            Spacer(minLength: 4)
            if upload.isActive { ProgressView().controlSize(.small) }
            if isFailed(upload), upload.retryable {
                Button("Retry") { uploads.retry(upload.id) }
                    .font(.amb(.footnote).weight(.semibold))
                    .accessibilityIdentifier("composer.upload.retry")
            }
            Button { uploads.remove(upload.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Amb.mutedForeground) }
                .accessibilityLabel("Remove \(upload.filename)")
                .accessibilityIdentifier("composer.upload.remove")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Amb.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.upload")
    }

    private func isFailed(_ upload: ComposerUpload) -> Bool { if case .failed = upload.phase { true } else { false } }

    private func status(_ upload: ComposerUpload) -> String {
        switch upload.phase {
        case .preparing: "Preparing…"
        case .waiting: "Waiting to upload…"
        case .uploading: "Uploading…"
        case .failed(let message): message
        case .done: "Uploaded"
        }
    }
}

extension PendingAttachment {
    /// Strips and stages one picked photo (off the main actor).
    /// A picked photo as a pasteboard-style item for the upload pipeline. Its bytes load only when the upload reads them.
    static func provider(_ item: PhotosPickerItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .image
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let data = try await item.loadTransferable(type: Data.self)
                    completion(data, nil)
                } catch { completion(nil, error) }
            }
            return nil
        }
        return provider
    }

    static func fromPicker(_ item: PhotosPickerItem, staging: URL) async -> PendingAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached {
            guard let png = try? ImagePrivacy.strippedPNG(data) else { return nil }
            return try? ImagePrivacy.stage(png, in: staging, filename: "photo.png")
        }.value
    }
}

enum MessageSyncState { case synced, pending, failed }

/// The small dot beside a message: green when Tower holds it (as the web shows), amber while a change waits to send, red
/// when Tower refused it.
struct SyncDot: View {
    let state: MessageSyncState

    private var details: (Color, String) {
        switch state {
        case .synced: (Amb.success, "Synced to Tower")
        case .pending: (Amb.warning, "Waiting to sync to Tower")
        case .failed: (Amb.destructive, "Not synced: Tower did not accept the change")
        }
    }

    var body: some View {
        Circle().fill(details.0).frame(width: 8, height: 8)
            .help(details.1)
            .accessibilityLabel(details.1)
            .accessibilityIdentifier("message.sync.\(state)")
    }
}

#if os(macOS)
/// An ordinary stable AppKit button. SwiftUI's popup adaptor eagerly updates menu/accessibility content during
/// layout transactions; incoming replies must not rebuild that native menu graph on every unchanged message.
/// Keep the button identity and current actions, and construct the menu only on explicit user interaction.
struct NativeMessageAction {
    let title: String
    let symbol: String
    var children: [Self] = []
    var perform: (() -> Void)?

    init(_ title: String, _ symbol: String, children: [Self] = [], perform: (() -> Void)? = nil) {
        self.title = title; self.symbol = symbol; self.children = children; self.perform = perform
    }
}

struct NativeMessageActions: NSViewRepresentable {
    let items: [NativeMessageAction]
    /// The message menu by default; the focused thread header reuses this button for the thread menu.
    var identifier = "message.actions"
    var label = "Message actions"
    var help = "Opens the message action menu"

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.image?.isTemplate = true
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(help)
        button.setAccessibilityIdentifier(identifier)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        button.isEnabled = !items.isEmpty
    }

    final class Coordinator: NSObject {
        var items: [NativeMessageAction]
        init(items: [NativeMessageAction]) { self.items = items }

        @objc func open(_ button: NSButton) {
            let menu = makeMenu(items)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
        }
        private func makeMenu(_ actions: [NativeMessageAction]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for action in actions {
                let item = NSMenuItem(title: action.title, action: #selector(invoke(_:)), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                item.representedObject = Action(perform: action.perform)
                if !action.children.isEmpty { item.submenu = makeMenu(action.children) }
                menu.addItem(item)
            }
            return menu
        }
        @objc private func invoke(_ item: NSMenuItem) { (item.representedObject as? Action)?.perform?() }
    }
    private final class Action {
        let perform: (() -> Void)?
        init(perform: (() -> Void)?) { self.perform = perform }
    }
}
#endif
