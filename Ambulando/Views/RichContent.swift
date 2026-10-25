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

private struct RichContext {
    var style: RichStyle
    var muted: Bool
    var workspace: WorkspaceRecord?
    var path: [Int] = []
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
        VStack(alignment: .leading, spacing: style == .chat ? 8 : 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                RichBlockView(block: block, context: RichContext(style: style, muted: muted, workspace: workspace, path: [index])).id(index)
            }
        }
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
            #if os(macOS)
            if let selection, let span = selection.spans.first(where: { $0.path == context.path }), span.text == runs.map(\.text).joined() {
                DocumentSelectableText(runs: runs, span: span, selection: selection, heading: level)
            } else {
                Text(InlineText.attributed(runs)).font(headingFont(level)).foregroundStyle(ink).textSelection(.enabled)
            }
            #else
            Text(InlineText.attributed(runs)).font(headingFont(level)).foregroundStyle(ink).textSelection(.enabled)
            #endif
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
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Amb.border).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) {
                        RichBlockView(block: $0.element, context: context.child($0.offset))
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Amb.success : Amb.mutedForeground)
                                    .accessibilityLabel(checked ? "Done" : "Not done")
                            } else {
                                Text(ordered ? "\(start + index)." : "•").foregroundStyle(Amb.mutedForeground).monospacedDigit()
                            }
                        }
                        .frame(minWidth: ordered ? 22 : 14, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { RichBlockView(block: $0.element, context: context.child(index, $0.offset)) }
                        }
                    }
                }
            }
            .padding(.leading, 4)
        case .table(let rows):
            TableBlockView(rows: rows, path: context.path)
        case .image(let alt, let source):
            RichImage(source: source, alt: alt, workspace: context.workspace)
        case .rule:
            Rectangle().fill(Amb.border).frame(height: 1).padding(.vertical, 4).accessibilityHidden(true)
        case .preserved(let type, let text):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(type) block — shown on the web; kept unchanged here", systemImage: "square.dashed").font(.caption).foregroundStyle(Amb.mutedForeground)
                if !text.isEmpty { Text(text).font(.footnote).foregroundStyle(Amb.mutedForeground) }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Amb.radiusControl).stroke(Amb.border, style: StrokeStyle(lineWidth: 1, dash: [4])))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("doc.preserved")
        }
    }

    /// Chat: h1 1.3rem, h2 1.12rem, h3+ 0.98rem (styles.css `.chat-post-markdown`); documents use larger headings.
    private func headingFont(_ level: Int) -> Font {
        switch (context.style, level) {
        case (.chat, ...1): .title3.weight(.bold)
        case (.chat, 2): .headline
        case (.chat, _): .subheadline.weight(.semibold)
        case (.document, ...1): .title2.weight(.bold)
        case (.document, 2): .title3.weight(.semibold)
        case (.document, _): .headline
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
        Text(InlineText.attributed(runs)).font(.body).foregroundStyle(context.muted ? Amb.mutedForeground : Amb.foreground)
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
                    .font(.caption2.monospaced().weight(.semibold)).foregroundStyle(RichPalette.codeMuted).lineLimit(1)
                Spacer()
                Button {
                    Pasteboard.copy(text)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.semibold)).foregroundStyle(RichPalette.codeMuted)
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

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            cellView(cell, row: r, column: c)
                                /* native selection and the normal rich fallback share table sizing */
                                .font(r == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                .foregroundStyle(Amb.foreground)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 48, maxWidth: 260, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 9).padding(.vertical, 7)
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
                part.foregroundColor = Amb.primary
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
                    .font(.footnote).lineLimit(2)
                    .padding(8).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            }
            .accessibilityHint("Opens the image address in your browser")
            .accessibilityIdentifier("image.remote")
        } else {
            Label(alt.isEmpty ? "Image unavailable" : "Image: \(alt)", systemImage: "photo").font(.footnote).foregroundStyle(Amb.mutedForeground)
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
}

/// A stored image: loads the cached bytes, asks the sync engine to download them when missing (signed, typed object
/// route), decodes off the main actor and shows loading, locked and error states. Tap opens Quick Look.
struct StorageImageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let objectId: String
    let alt: String
    let workspace: WorkspaceRecord?
    var maxHeight: CGFloat = 384
    var maxWidth: CGFloat = 448

    @State private var image: PlatformImage?
    @State private var file: URL?
    @State private var preview: URL?
    @State private var attempt = 0
    @State private var requested = false

    /// Object ids are UUIDs (they become a cache path component, so nothing else is accepted).
    static func objectId(_ source: String) -> String? {
        guard source.lowercased().hasPrefix("storage://") else { return nil }
        let id = String(source.dropFirst("storage://".count)).trimmingCharacters(in: .whitespaces)
        return UUID(uuidString: id) != nil ? id.lowercased() : nil
    }

    private var cacheKey: String { "\(workspace?.id ?? "-"):\(objectId):\(Int(maxWidth * displayScale))" }
    private var errorKey: String? { workspace.map { "attachment:\($0.id):\(objectId)" } }

    var body: some View {
        Group {
            if let image {
                Button { preview = file } label: {
                    Image(platformImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(maxWidth, image.size.width), maxHeight: maxHeight, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Amb.radiusPanel))
                        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alt.isEmpty ? "Image" : "Image: \(alt)")
                .accessibilityHint("Opens the image")
                .accessibilityIdentifier("image.loaded")
            } else {
                placeholder
            }
        }
        .quickLookPreview($preview)
        .task(id: "\(cacheKey)#\(attempt)") { await load() }
        .onChange(of: model.syncStatus) { _, _ in if image == nil && file == nil { attempt += 1 } }
        .onChange(of: model.isUnlocked) { _, unlocked in if unlocked && image == nil { requested = false; attempt += 1 } }
    }

    @ViewBuilder private var placeholder: some View {
        let failure = errorKey.flatMap { model.syncError(forKey: $0) }
        let (icon, text, id): (String, String, String) =
            if workspace == nil { ("photo", "Image not available here", "image.error") }
            else if let failure { ("exclamationmark.triangle", "Image could not be loaded: \(failure)", "image.error") }
            else if !model.isUnlocked && file == nil { ("lock", "Unlock to load this image", "image.locked") }
            else { ("photo", "Loading image…", "image.loading") }
        HStack(spacing: 8) {
            if id == "image.loading" { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
            Text(alt.isEmpty ? text : "\(alt) — \(text)").font(.footnote).lineLimit(3)
        }
        .foregroundStyle(Amb.mutedForeground)
        .padding(12)
        .frame(maxWidth: maxWidth, minHeight: 72, alignment: .leading)
        .background(Amb.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
        .overlay(alignment: .topTrailing) {
            if failure != nil {
                Button("Retry") { requested = false; attempt += 1 }.font(.caption.weight(.semibold)).padding(8)
            }
        }
    }

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
        let pixels = maxWidth * displayScale, scale = displayScale
        let decoded = await Task.detached(priority: .userInitiated) { StorageImageCache.downsample(found, maxPixels: pixels, scale: scale) }.value
        guard !Task.isCancelled else { return }
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
