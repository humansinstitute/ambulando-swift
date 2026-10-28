import AmbulandoCore
import ImageIO
import QuickLook
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: Environment

/// Opens a mention or record reference (`mention:<kind>:<id>`). Screens that can route set it; the default does nothing.
struct OpenMentionAction: Sendable {
    let handler: @MainActor @Sendable (_ kind: String, _ id: String) -> Void
    @MainActor func callAsFunction(kind: String, id: String) { handler(kind, id) }
}

extension EnvironmentValues {
    @Entry var openMention = OpenMentionAction { _, _ in }
}

/// Code surfaces from `ambulando-tokens.css` (paired background/ink, not action colours).
enum RichPalette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(PlatformColor.dynamic(light, dark))
    }
    static let codeBackground = dynamic(0xF1F5F3, 0x111D29)
    static let codeForeground = dynamic(0x16354B, 0xE8EEF2)
    static let codeToolbar = dynamic(0xE5EDE8, 0x223442)
    static let codeMuted = dynamic(0x52645C, 0xB3C2C9)
}

/// How blocks are sized: chat posts and comments (`.chat-post-markdown`) or the document reader (`.doc-block-rendered`).
enum RichStyle: Sendable { case chat, document }

/// Desktop chat rhythm is separate from document layout and the compact iOS renderer.
/// Spacing follows the app's text size; a readable measure leaves room for long replies in expanded threads.
@MainActor
struct ChatTypography {
    static var scale: CGFloat {
        #if os(macOS)
        TextScale.shared.factor
        #else
        1
        #endif
    }
    static var lineSpacing: CGFloat {
        #if os(macOS)
        3 * scale
        #else
        0
        #endif
    }
    static var readableWidth: CGFloat {
        #if os(macOS)
        800 * scale
        #else
        .infinity
        #endif
    }
}

private struct RichContext {
    var style: RichStyle
    var muted: Bool
    var workspace: WorkspaceRecord?
    var path: [Int] = []
    var desktopChat: Bool {
        #if os(macOS)
        style == .chat
        #else
        false
        #endif
    }
    @MainActor var blockSpacing: CGFloat { desktopChat ? 14 * ChatTypography.scale : (style == .chat ? 8 : 12) }
    @MainActor var innerSpacing: CGFloat { desktopChat ? 8 * ChatTypography.scale : 4 }
    func child(_ indices: Int...) -> RichContext { var next = self; next.path += indices; return next }
}

// MARK: Blocks

/// Native rendering of Markdown/rich-document blocks: headings, paragraphs, lists, quotes, code, tables, rules and
/// stored images. Long code and tables scroll inside their own box; text stays selectable.
struct RichBlocksView: View {
    let blocks: [RenderBlock]
    var style: RichStyle = .chat
    var muted = false
    var workspace: WorkspaceRecord?
    @Environment(\.openMention) private var openMention
    @Environment(\.openURL) private var parentOpenURL

    var body: some View {
        VStack(alignment: .leading, spacing: RichContext(style: style, muted: muted, workspace: workspace).blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                RichBlockView(block: block, context: RichContext(style: style, muted: muted, workspace: workspace, path: [index])).id(index)
            }
        }
        .frame(maxWidth: style == .chat ? ChatTypography.readableWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let target = RichLinks.mentionTarget(url) { openMention(kind: target.kind, id: target.id); return .handled }
            guard RichLinks.isSafeWeb(url) else { return .discarded }
            parentOpenURL(url)
            return .handled
        })
    }
}

private struct RichBlockView: View {
    let block: RenderBlock
    let context: RichContext

    #if os(macOS)
    @Environment(\.documentSelection) private var selection
    #endif

    private var ink: Color { context.muted ? Amb.mutedForeground : Amb.foreground }

    var body: some View {
        switch block {
        case .heading(let level, let runs):
            Group {
            #if os(macOS)
            if let selection, let span = selection.spans.first(where: { $0.path == context.path }), span.text == runs.map(\.text).joined() {
                DocumentSelectableText(runs: runs, span: span, selection: selection, heading: level)
            } else {
                Text(InlineText.attributed(runs)).font(headingFont(level)).foregroundStyle(ink).textSelection(.enabled)
            }
            #else
            Text(InlineText.attributed(runs)).font(headingFont(level)).foregroundStyle(ink).textSelection(.enabled)
            #endif
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, context.desktopChat && context.path.last != 0 ? 4 * ChatTypography.scale : 0)
        case .paragraph(let runs):
            #if os(macOS)
            if let selection, let span = selection.spans.first(where: { $0.path == context.path }), span.text == runs.map(\.text).joined() {
                DocumentSelectableText(runs: runs, span: span, selection: selection)
            } else { ParagraphView(runs: runs, context: context) }
            #else
            ParagraphView(runs: runs, context: context)
            #endif
        case .code(let language, let text):
            CodeBlockView(language: language, text: text, path: context.path)
        case .quote(let blocks):
            // An overlay rail takes the measured content height without proposing infinite height to a stack.
            VStack(alignment: .leading, spacing: context.desktopChat ? context.innerSpacing : 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) {
                    RichBlockView(block: $0.element, context: context.child($0.offset))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, context.desktopChat ? 14 * ChatTypography.scale : 13)
            .padding(.trailing, context.desktopChat ? 10 * ChatTypography.scale : 0)
            .padding(.vertical, context.desktopChat ? 8 * ChatTypography.scale : 0)
            .background(context.desktopChat ? Amb.muted.opacity(0.35) : Color.clear)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(Amb.border).frame(width: 3)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            // Keep a common marker gutter, including lists starting at double/triple-digit numbers.
            let digits = String(max(abs(start), abs(start + max(0, items.count - 1)))).count
            let markerWidth: CGFloat = ordered ? max(22, CGFloat(digits) * 9 + 7) : 14
            let loose = items.contains { $0.blocks.count > 1 }
            VStack(alignment: .leading, spacing: context.desktopChat ? (loose ? 14 : 8) * ChatTypography.scale : 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: context.desktopChat ? 9 * ChatTypography.scale : 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Amb.success : Amb.mutedForeground)
                                    .accessibilityLabel(checked ? "Done" : "Not done")
                            } else {
                                Text(ordered ? "\(start + index)." : "•").foregroundStyle(Amb.mutedForeground).monospacedDigit()
                            }
                        }
                        .font(.amb(.body))
                        .frame(minWidth: context.desktopChat ? markerWidth * ChatTypography.scale : (ordered ? 22 : 14), alignment: .trailing)
                        VStack(alignment: .leading, spacing: context.innerSpacing) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { RichBlockView(block: $0.element, context: context.child(index, $0.offset)) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, context.desktopChat ? 2 * ChatTypography.scale : 4)
        case .table(let rows):
            TableBlockView(rows: rows, path: context.path)
        case .image(let alt, let source):
            RichImage(source: source, alt: alt, workspace: context.workspace)
        case .rule:
            Rectangle().fill(Amb.border).frame(height: 1).padding(.vertical, 4).accessibilityHidden(true)
        case .preserved(let type, let text):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(type) block — shown on the web; kept unchanged here", systemImage: "square.dashed").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                if !text.isEmpty { Text(text).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("doc.preserved")
        }
    }

    /// Chat: h1 1.3rem, h2 1.12rem, h3+ 0.98rem (styles.css `.chat-post-markdown`); documents use larger headings.
    private func headingFont(_ level: Int) -> Font {
        #if os(macOS)
        if context.style == .chat {
            return switch level {
            case ...1: .amb(.title2).weight(.bold)
            case 2: .amb(.title3).weight(.semibold)
            default: .amb(.headline).weight(.semibold)
            }
        }
        #endif
        return switch (context.style, level) {
        case (.chat, ...1): .amb(.title3).weight(.bold)
        case (.chat, 2): .amb(.headline)
        case (.chat, _): .amb(.subheadline).weight(.semibold)
        case (.document, ...1): .amb(.title2).weight(.bold)
        case (.document, 2): .amb(.title3).weight(.semibold)
        case (.document, _): .amb(.headline)
        }
    }
}

/// A paragraph; inline images split it into text and image pieces.
private struct ParagraphView: View {
    let runs: [InlineRun]
    let context: RichContext

    var body: some View {
        let pieces = Self.pieces(runs)
        if pieces.count == 1, case .text(let text) = pieces[0] {
            line(text)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .text(let text): line(text)
                    case .image(let alt, let source): RichImage(source: source, alt: alt, workspace: context.workspace)
                    }
                }
            }
        }
    }

    private func line(_ runs: [InlineRun]) -> some View {
        Text(InlineText.attributed(runs)).font(.amb(.body).weight(.regular)).foregroundStyle(context.muted ? Amb.mutedForeground : Amb.foreground)
            .lineSpacing(context.style == .chat ? ChatTypography.lineSpacing : 0)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    enum Piece { case text([InlineRun]), image(alt: String, source: String) }

    static func pieces(_ runs: [InlineRun]) -> [Piece] {
        var out: [Piece] = []
        var current: [InlineRun] = []
        for run in runs {
            if let source = run.image {
                if current.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { out.append(.text(current)) }
                current = []
                out.append(.image(alt: run.text, source: source))
            } else {
                current.append(run)
            }
        }
        if current.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) || out.isEmpty { out.append(.text(current)) }
        return out
    }
}

/// `.md-code-block`: language toolbar with Copy, horizontally scrolling monospaced body.
private struct CodeBlockView: View {
    let language: String
    let text: String
    var path: [Int] = []
    #if os(macOS)
    @Environment(\.documentSelection) private var selection
    #endif
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.amb(.caption2).monospaced().weight(.semibold)).foregroundStyle(RichPalette.codeMuted).lineLimit(1)
                Spacer()
                Button {
                    Pasteboard.copy(text)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.amb(.caption2).weight(.semibold)).foregroundStyle(RichPalette.codeMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied code" : "Copy code")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RichPalette.codeToolbar)
            ScrollView(.horizontal) {
                #if os(macOS)
                if let selection, let span = selection.spans.first(where: { $0.path == path }) {
                    DocumentSelectableText(runs: [InlineRun(text: text)], span: span, selection: selection).frame(minWidth: 240).padding(10)
                } else {
                    Text(verbatim: text).font(Amb.code).foregroundStyle(RichPalette.codeForeground).textSelection(.enabled).padding(10)
                }
                #else
                Text(verbatim: text).font(Amb.code).foregroundStyle(RichPalette.codeForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                #endif
            }
            .scrollIndicators(.automatic)
            // Text inside a horizontal scroller is not reliably exposed to VoiceOver; the scroller itself reads the code.
            #if os(macOS)
            .accessibilityElement(children: .contain)
            #else
            .accessibilityElement(children: .ignore)
            #endif
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("rich.code.text")
        }
        .background(RichPalette.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.code")
    }
}

/// GFM table in its own horizontal scroller with cell borders and a card-coloured header.
private struct TableBlockView: View {
    let rows: [[[InlineRun]]]
    var path: [Int] = []
    #if os(macOS)
    @Environment(\.documentSelection) private var selection
    #endif

    /// One width per column from its longest cell, so wrapped text gets a stable measured width.
    private var widths: [CGFloat] {
        let count = rows.map(\.count).max() ?? 0
        return (0..<count).map { c in
            let longest = rows.map { c < $0.count ? $0[c].map(\.text).joined().count : 0 }.max() ?? 0
            return min(260, max(56, CGFloat(longest) * 7.5))
        }
    }

    var body: some View {
        let widths = widths
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            cellView(cell, row: r, column: c)
                                /* native selection and the normal rich fallback share table sizing */
                                .font(r == 0 ? .amb(.subheadline).weight(.semibold) : .amb(.subheadline))
                                .foregroundStyle(Amb.foreground)
                                .textSelection(.enabled)
                                /* fixed column width first, then let height follow the wrapped text, so rows never collapse onto each other */
                                .frame(width: widths[c], alignment: .topLeading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .background(r == 0 ? Amb.card : Color.clear)
                                .overlay(Rectangle().stroke(Amb.border, lineWidth: 0.5))
                        }
                    }
                }
            }
            .overlay(Rectangle().stroke(Amb.border, lineWidth: 1))
            .padding(1)
        }
        // Read row by row ("Surface, State. Chat, Markdown.").
        #if os(macOS)
        .accessibilityElement(children: .contain)
        #else
        .accessibilityElement(children: .ignore)
        #endif
        .accessibilityLabel(Self.spoken(rows))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("rich.table")
    }

    @ViewBuilder private func cellView(_ runs: [InlineRun], row: Int, column: Int) -> some View {
        #if os(macOS)
        if let selection, let span = selection.spans.first(where: { $0.path == path + [row, column, 0] }), span.text == runs.map(\.text).joined() {
            DocumentSelectableText(runs: runs, span: span, selection: selection).frame(minWidth: 80)
        } else { Text(InlineText.attributed(runs)) }
        #else
        Text(InlineText.attributed(runs))
        #endif
    }

    static func spoken(_ rows: [[[InlineRun]]]) -> String {
        "Table. " + rows.map { row in row.map { cell in cell.map(\.text).joined() }.joined(separator: ", ") }.joined(separator: ". ")
    }
}

// MARK: Inline text

enum RichLinks {
    static let mentionScheme = "ambulando-mention"

    static func isSafeWeb(_ url: URL) -> Bool { ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") }

    static func mentionURL(kind: String, id: String) -> URL? {
        var components = URLComponents()
        components.scheme = mentionScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "id", value: id)]
        return components.url
    }

    static func mentionTarget(_ url: URL) -> (kind: String, id: String)? {
        guard url.scheme == mentionScheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let kind = items.first(where: { $0.name == "kind" })?.value, let id = items.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        return (kind, id)
    }
}

enum InlineText {
    /// Styles come from presentation intents so they combine with the block's font (headings stay heading-sized).
    /// Mentions carry an in-app link so they can be tapped while the text stays selectable; only http(s)/mailto links
    /// leave the app.
    static func attributed(_ runs: [InlineRun]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.code { intent.insert(.code) }
            if run.strike { intent.insert(.strikethrough) }
            if !intent.isEmpty { part.inlinePresentationIntent = intent }
            if run.underline { part.underlineStyle = .single }
            if run.code { part.backgroundColor = Amb.card }
            if let link = run.link, let url = URL(string: link), RichLinks.isSafeWeb(url) {
                part.link = url
                part.foregroundColor = Amb.link
                part.underlineStyle = .single
            }
            if run.mention {
                part.foregroundColor = run.mentionKind == "person" || run.mentionKind == "agent" || run.mentionKind == nil ? Amb.primary : Amb.info
                part.backgroundColor = Amb.accent
                if !run.bold { part.inlinePresentationIntent = intent.union(.stronglyEmphasized) }
                if let kind = run.mentionKind, let id = run.mentionId, let url = RichLinks.mentionURL(kind: kind, id: id) { part.link = url }
            } else if run.object {
                part.foregroundColor = Amb.primary
                part.backgroundColor = Amb.accent
            }
            out += part
        }
        return out
    }
}

// MARK: Images

/// An image reference from Markdown or a rich document. Stored images (`storage://<uuid>`) load through the app's
/// authenticated storage route; web images are never fetched (they may track or expose the reader) and show as a link.
struct RichImage: View {
    let source: String
    let alt: String
    let workspace: WorkspaceRecord?

    var body: some View {
        if let objectId = StorageImageView.objectId(source) {
            StorageImageView(objectId: objectId, alt: alt, workspace: workspace)
        } else if let url = URL(string: source), RichLinks.isSafeWeb(url) {
            Link(destination: url) {
                Label(alt.isEmpty ? "Web image (not loaded)" : "\(alt) — web image (not loaded)", systemImage: "photo.badge.arrow.down")
                    .font(.amb(.footnote)).lineLimit(2)
                    .padding(8).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            }
            .accessibilityHint("Opens the image address in your browser")
            .accessibilityIdentifier("image.remote")
        } else {
            Label(alt.isEmpty ? "Image unavailable" : "Image: \(alt)", systemImage: "photo").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                .accessibilityIdentifier("image.error")
        }
    }
}

/// Decoded, downsampled images shared by chat and documents (bounded by count and decoded bytes).
final class StorageImageCache: @unchecked Sendable {
    static let shared = StorageImageCache()
    private let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func image(_ key: String) -> PlatformImage? { cache.object(forKey: key as NSString) }

    func store(_ image: PlatformImage, key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.decodedBytes)
    }

    /// ImageIO thumbnail decode: never inflates the full-size bitmap and never enlarges a small image (shown at its
    /// natural point size, like the web).
    static func downsample(_ url: URL, maxPixels: CGFloat, scale: CGFloat) -> PlatformImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? CGFloat) ?? maxPixels
        let height = (properties?[kCGImagePropertyPixelHeight] as? CGFloat) ?? maxPixels
        let limit = min(max(64, maxPixels), max(width, height))
        let thumbnail = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                         kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: limit] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return nil }
        return PlatformImage.bitmap(image, scale: scale)
    }

    /// Decodes for a square tile of `tile` pixels that the image fills and is cropped to: the long edge comes from the
    /// image's own size (`ImageTileBudget`, metadata only), bounded at 4096 and never above the image.
    static func downsampleFilling(_ url: URL, tile: CGFloat, scale: CGFloat) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let longEdge = ImageTileBudget.longEdge(tile: tile, width: properties?[kCGImagePropertyPixelWidth] as? CGFloat,
                                                height: properties?[kCGImagePropertyPixelHeight] as? CGFloat)
        return downsample(url, maxPixels: longEdge, scale: scale)
    }
}

/// A stored image: loads the cached bytes, asks the sync engine to download them when missing (signed, typed object
/// route), decodes off the main actor and shows loading, locked and error states. Tap opens the in-app image viewer
/// (`ImageLightbox`), as the web opens its image modal; this one view serves sent chat images and attachments,
/// document images and the composer's uploaded thumbnails. `fill` makes it a square, cropped tile of that side (composer
/// tiles); without it the image is fitted whole (chat and documents).
struct StorageImageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @Environment(\.imageLightbox) private var lightbox
    let objectId: String
    let alt: String
    let workspace: WorkspaceRecord?
    var maxHeight: CGFloat = 384
    var maxWidth: CGFloat = 448
    /// Side of a square tile the image fills and is cropped to; nil fits the whole image.
    var fill: CGFloat? = nil

    @State private var image: PlatformImage?
    @State private var file: URL?
    @State private var lightboxImage: LightboxImage?
    @State private var attempt = 0
    @State private var requested = false

    /// Object ids are UUIDs (they become a cache path component, so nothing else is accepted).
    static func objectId(_ source: String) -> String? {
        guard source.lowercased().hasPrefix("storage://") else { return nil }
        let id = String(source.dropFirst("storage://".count)).trimmingCharacters(in: .whitespaces)
        return UUID(uuidString: id) != nil ? id.lowercased() : nil
    }

    /// Fitted images are keyed by their width in pixels, tiles by their side (a different decode of the same object).
    private var cacheKey: String {
        if let fill { return "\(workspace?.id ?? "-"):\(objectId):\(Int(fill * displayScale)):fill" }
        return "\(workspace?.id ?? "-"):\(objectId):\(Int(maxWidth * displayScale))"
    }
    private var errorKey: String? { workspace.map { "attachment:\($0.id):\(objectId)" } }

    var body: some View {
        Group {
            if let image {
                Button { open() } label: {
                    if let fill {
                        Image(platformImage: image).resizable().scaledToFill()
                            .frame(width: fill, height: fill)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
                            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border.opacity(0.3), lineWidth: 1))
                            .contentShape(Rectangle())
                    } else {
                        Image(platformImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: min(maxWidth, image.size.width), maxHeight: maxHeight, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
                            .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border.opacity(0.3), lineWidth: 1))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alt.isEmpty ? "Image" : "Image: \(alt)")
                .accessibilityHint("Opens the image")
                .accessibilityIdentifier("image.loaded")
            } else {
                placeholder
            }
        }
        .imageLightboxCover($lightboxImage)
        .task(id: "\(cacheKey)#\(attempt)") {
            guard let store = model.store, let workspace else { await load(); return }
            // Attachment completion touches messages in this workspace. Subscribe before probing the cache so even
            // a fast download whose start/finish is hidden by throttled sync-status updates wakes this image.
            let changes = await store.changes.stream()
            await load()
            if image != nil { return }
            for await batch in changes {
                guard !Task.isCancelled else { return }
                if batch.contains(where: { $0.table == .messages && $0.workspaceId == workspace.id }) {
                    await load()
                    if image != nil { return }
                }
            }
        }
        .onChange(of: model.syncStatus) { _, _ in if image == nil && file == nil { attempt += 1 } }
        .onChange(of: model.isUnlocked) { _, unlocked in if unlocked && image == nil { requested = false; attempt += 1 } }
    }

    /// The image large: in the window's lightbox on the Mac, full screen from here on the iPhone and iPad.
    private func open() {
        guard let file else { return }
        let shown = LightboxImage(objectId: objectId, file: file, alt: alt)
        if let lightbox { lightbox.show(shown) } else { lightboxImage = shown }
    }

    @ViewBuilder private var placeholder: some View {
        let failure = errorKey.flatMap { model.syncError(forKey: $0) }
        let (icon, text, id): (String, String, String) =
            if workspace == nil { ("photo", "Image not available here", "image.error") }
            else if let failure { ("exclamationmark.triangle", "Image could not be loaded: \(failure)", "image.error") }
            else if !model.isUnlocked && file == nil { ("lock", "Unlock to load this image", "image.locked") }
            else { ("photo", "Loading image…", "image.loading") }
        let label = alt.isEmpty ? text : "\(alt) — \(text)"
        Group {
            if let fill, failure != nil {
                // A failed tile is its own Retry button (the whole tile, at least 44pt): a corner control the tile's owner
                // places over it (Remove) keeps its own corner.
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise").font(.amb(.body).weight(.semibold))
                        .frame(width: max(44, fill), height: max(44, fill))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: fill, height: fill)
                .accessibilityLabel("Retry: \(label)")
            } else if let fill {
                // A tile has room for the state's icon only; the full text is its accessibility label.
                Group { if id == "image.loading" { ProgressView().controlSize(.small) } else { Image(systemName: icon) } }
                    .frame(width: fill, height: fill)
                    .accessibilityElement()
                    .accessibilityLabel(label)
            } else {
                HStack(spacing: 8) {
                    if id == "image.loading" { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
                    Text(label).font(.amb(.footnote)).lineLimit(3)
                }
                .padding(12)
                .frame(maxWidth: maxWidth, minHeight: 72, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(Amb.mutedForeground)
        .background(Amb.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .accessibilityIdentifier(id)
        .overlay(alignment: .topTrailing) {
            if failure != nil && fill == nil {
                Button("Retry", action: retry).font(.amb(.caption).weight(.semibold)).padding(8)
            }
        }
    }

    private func retry() { requested = false; attempt += 1 }

    private func load() async {
        guard let workspace else { return }
        let key = cacheKey
        if let hit = StorageImageCache.shared.image(key) {
            image = hit
            file = model.fileCache?.attachment(workspaceId: workspace.id, objectId: objectId)
            return
        }
        guard let found = model.fileCache?.attachment(workspaceId: workspace.id, objectId: objectId) else {
            if !requested && model.isUnlocked {
                requested = true
                model.downloadAttachment(objectId, in: workspace)
            }
            return
        }
        file = found
        let scale = displayScale
        let decoded: PlatformImage?
        if let fill {
            let tile = fill * scale
            decoded = await Task.detached(priority: .userInitiated) { StorageImageCache.downsampleFilling(found, tile: tile, scale: scale) }.value
        } else {
            let pixels = maxWidth * scale
            decoded = await Task.detached(priority: .userInitiated) { StorageImageCache.downsample(found, maxPixels: pixels, scale: scale) }.value
        }
        // A sync-status change can replace this task after file was set. Dropping the completed decode then leaves
        // a cached file with no image, which the download-only sync observer will never retry. The bounded decode
        // may finish for the same current object/scale; reject it only when the view now represents a different key.
        guard key == cacheKey else { return }
        if let decoded {
            StorageImageCache.shared.store(decoded, key: key)
            image = decoded
        }
    }
}

enum RichBlocksInfo {
    /// Whether blocks include pieces with their own controls (code copy, scrolling tables, images).
    static func hasControls(_ blocks: [RenderBlock]) -> Bool {
        blocks.contains { block in
            switch block {
            case .code, .table, .image: true
            case .quote(let inner): hasControls(inner)
            case .list(_, _, let items): items.contains { hasControls($0.blocks) }
            case .paragraph(let runs): runs.contains { $0.image != nil }
            default: false
            }
        }
    }
}
