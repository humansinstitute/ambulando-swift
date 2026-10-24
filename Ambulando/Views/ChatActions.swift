import AmbulandoCore
import PhotosUI
import SwiftUI

/// A sent message with its reactions, attachments and the actions Tower allows: react (anyone who can write here),
/// edit and delete (the author; edits are signed kind 33358 revisions). Unsent edits and deletes show on the message
/// until Tower accepts them.
struct MessageCell: View {
    @Environment(AppModel.self) private var model
    let message: MessageRecord
    let names: [String: String]
    let workspace: WorkspaceRecord
    let extras: MessageExtras
    var route: ChatRoute? = nil
    var replyCount = 0
    @State private var editing = false
    @State private var confirmDelete = false

    private var writes: [WriteItem] { extras.writes[message.id] ?? [] }
    private var pendingEdit: WriteItem? { writes.last { $0.kind == .messageEdit } }
    private var pendingDelete: WriteItem? { writes.last { $0.kind == .messageDelete } }
    private var mine: Bool { message.senderNpub != nil && message.senderNpub == model.identity.npub }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let route {
                    NavigationLink(value: route) {
                        VStack(alignment: .leading, spacing: 0) {
                            row
                            if replyCount > 0 {
                                Label("\(replyCount) \(replyCount == 1 ? "reply" : "replies")", systemImage: "bubble.left.and.text.bubble.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(Amb.primary)
                                    .padding(.leading, 60).padding(.bottom, 8)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("thread.\(replyCount)")
                } else {
                    row
                }
            }
            ReactionBar(reactions: reactions, me: model.identity.npub) { toggle($0) }
                .padding(.leading, 60).padding(.trailing, 16)
            ForEach(writes.filter { [.messageEdit, .messageDelete].contains($0.kind) }) { item in
                WriteStatusLine(item: item, label: item.kind == .messageEdit ? "Edit" : "Delete").padding(.leading, 60).padding(.trailing, 16).padding(.bottom, 6)
            }
        }
        .contextMenu {
            Menu {
                ForEach(ReactionEmoji.allCases, id: \.self) { emoji in
                    Button { toggle(emoji.rawValue) } label: { Label(emoji.name, systemImage: emoji.symbol) }
                        .accessibilityIdentifier("react.\(emoji.rawValue)")
                }
            } label: { Label("React", systemImage: "face.smiling") }
                .accessibilityIdentifier("message.react")
            Button { UIPasteboard.general.string = MentionCodec.plain(message.body) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if mine && !message.deleted {
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }.accessibilityIdentifier("message.edit")
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.accessibilityIdentifier("message.delete")
            }
        }
        .sheet(isPresented: $editing) { MessageEditSheet(message: message, workspace: workspace, currentBody: pendingEdit?.string("body") ?? message.body) }
        .confirmationDialog("Delete this message for everyone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.submit(WriteIntent(kind: .messageDelete, targetId: message.id, payload: ["row_version": message.rowVersion]), in: workspace)
            }
        }
    }

    private var row: some View {
        MessageRow(message: message, names: names, bodyOverride: pendingEdit?.isPending == true ? pendingEdit?.string("body") : nil, workspace: workspace)
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
                        HStack(spacing: 4) { Image(systemName: emoji.symbol); Text("\(list.count)") }.font(.caption.weight(.semibold))
                            .foregroundStyle(emoji == .heart ? Amb.destructive : Amb.primary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(mine ? Amb.accent : Amb.muted, in: Capsule())
                            .overlay(Capsule().stroke(mine ? Amb.primary : Color.clear, lineWidth: 1))
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
                TextField("Message", text: $text, axis: .vertical).lineLimit(3...12).accessibilityIdentifier("editmessage.field")
                Text("Edits are signed with your identity and replace the message for everyone.").font(.footnote).foregroundStyle(Amb.mutedForeground)
            }
            .navigationTitle("Edit message")
            .navigationBarTitleDisplayMode(.inline)
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
                Label(attachment.filename, systemImage: "paperclip").font(.footnote)
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
    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { a in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let image = thumbnails[a.id] { Image(uiImage: image).resizable().scaledToFill() } else { Color(Amb.muted) }
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
        thumbnails[a.id] = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 128, height: 128)) }.value
    }

    private func remove(_ a: PendingAttachment) {
        attachments.removeAll { $0.id == a.id }
        if let staging { try? FileManager.default.removeItem(at: staging.appendingPathComponent(a.staged)) }
    }
}

extension PendingAttachment {
    /// Strips and stages one picked photo (off the main actor).
    static func fromPicker(_ item: PhotosPickerItem, staging: URL) async -> PendingAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached {
            guard let png = try? ImagePrivacy.strippedPNG(data) else { return nil }
            return try? ImagePrivacy.stage(png, in: staging, filename: "photo.png")
        }.value
    }
}
