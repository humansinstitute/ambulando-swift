import AmbulandoCore
import SwiftUI

/// What the next message carries besides its text, in one strip above the field: picked people and agents as pills,
/// then photos and uploaded images as tiles, then uploaded files, wrapping onto further lines when the width runs out.
/// Taller than two tile lines, the strip scrolls, so the field, Photos and Hide keyboard stay on screen.
struct ComposerAttachmentStrip: View {
    let mentions: [Mention]
    let people: [MentionCandidate]
    let removeMention: (Mention) -> Void
    @Binding var attachments: [PendingAttachment]
    let staging: URL?
    let text: String
    let workspace: WorkspaceRecord
    let removeUploaded: (String) -> Void
    /// The items' measured height. Starts at one tile line, so the first frame already shows a line (never a 0-high
    /// strip waiting for measurement); the measured height replaces it straight away.
    @State private var contentHeight: CGFloat = ComposerTile.cell + 4

    private var isEmpty: Bool {
        mentions.isEmpty && !attachments.contains(where: { $0.text == nil }) && StorageMarkdown.rawReferences(in: text).isEmpty
    }

    var body: some View {
        if !isEmpty {
            ScrollView(.vertical) {
                WrappingRows(spacing: 8, lineSpacing: 6) {
                    ComposerMentionPills(mentions: mentions, people: people, remove: removeMention)
                    ComposerAttachments(attachments: $attachments, staging: staging)
                    ComposerUploadedThumbnails(text: text, workspace: workspace, remove: removeUploaded)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, ComposerTile.stripMaxHeight))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer.strip")
        }
    }
}

/// Sizes shared by the composer's tiles.
enum ComposerTile {
    /// An image tile's side: a comfortable preview target.
    static let side: CGFloat = 72
    /// Room above and right of a tile for its Remove badge.
    static let badgeInset: CGFloat = 10
    /// A tile with its badge room.
    static let cell: CGFloat = side + badgeInset
    /// Two lines of tiles; beyond that the strip scrolls.
    static let stripMaxHeight: CGFloat = cell * 2 + 6 + 4
}

/// A tile's Remove control: a 44pt target in the tile's top-right corner, separate from the tile's preview area (which
/// keeps the rest of the tile).
struct ComposerTileRemove: View {
    let label: String
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white, .black.opacity(0.65))
                .frame(width: Amb.touchTarget, height: Amb.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "composer.tile.remove")
    }
}

extension View {
    /// Places a 72pt tile at the bottom left of its cell with the Remove control in the cell's top-right 44pt square:
    /// its badge sits over the tile's corner, and the rest of the tile stays the preview target.
    func composerTile(remove: ComposerTileRemove) -> some View {
        ZStack(alignment: .topTrailing) {
            self.frame(width: ComposerTile.side, height: ComposerTile.side)
                .frame(width: ComposerTile.cell, height: ComposerTile.cell, alignment: .bottomLeading)
            remove
        }
        .frame(width: ComposerTile.cell, height: ComposerTile.cell)
    }
}

/// Lays its items out left to right and starts a new line when the next one does not fit; items on a line are centred
/// vertically. Each item is measured once at its ideal size (kept in the cache until the items change) and narrowed
/// to the width at most: no nested or repeated measuring.
struct WrappingRows: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    struct Cache { var ideal: [CGSize] = [] }

    func makeCache(subviews: Subviews) -> Cache { Cache(ideal: subviews.map { $0.sizeThatFits(.unspecified) }) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.ideal = subviews.map { $0.sizeThatFits(.unspecified) } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let arranged = arrange(cache.ideal, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : arranged.size.width } ?? arranged.size.width, height: arranged.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let arranged = arrange(cache.ideal, width: bounds.width)
        for (index, subview) in subviews.enumerated() where index < arranged.frames.count {
            let frame = arranged.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ ideal: [CGSize], width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        frames.reserveCapacity(ideal.count)
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0, lineStart = 0
        func finishLine(_ end: Int) {
            for i in lineStart..<end { frames[i].origin.y = y + (lineHeight - frames[i].height) / 2 }
        }
        for (index, size) in ideal.enumerated() {
            let item = CGSize(width: min(size.width, width), height: size.height)
            if x > 0, x + item.width > width {
                finishLine(index)
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0; lineStart = index
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: item))
            widest = max(widest, x + item.width)
            x += item.width + spacing
            lineHeight = max(lineHeight, item.height)
        }
        finishLine(frames.count)
        return (frames, CGSize(width: widest, height: frames.isEmpty ? 0 : y + lineHeight))
    }
}
