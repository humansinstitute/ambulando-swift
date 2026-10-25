#if os(macOS)
import AppKit

/// Detached, height-bounded text layout. SwiftUI asks for several widths per frame: never lay out the entire draft
/// to choose the height of a six-line viewport, or invalidate the live text view from a measurement callback.
@MainActor
final class MacComposerMeasurement {
    private var text = ""
    private var font: NSFont?
    private var lines = 0
    private var heights: [CGFloat: CGFloat] = [:]
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()

    init() {
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    func height(text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let line = ceil(font.ascender - font.descender + font.leading)
        let maximum = line * CGFloat(maxLines)
        if self.text != text || self.font != font || lines != maxLines {
            self.text = text
            self.font = font
            lines = maxLines
            heights.removeAll(keepingCapacity: true)
        }
        if let cached = heights[width] { return cached }
        container.containerSize = CGSize(width: width, height: maximum)
        container.maximumNumberOfLines = maxLines
        // Even glyph generation for an enormous single paragraph is expensive. Start with a small prefix and grow
        // only if it all fits. Once the container excludes glyphs, later text cannot affect the viewport height.
        let source = text.isEmpty ? " " : text
        var limit = 4096
        while true {
            let prefix = String(decoding: source.utf16.prefix(limit), as: UTF16.self)
            storage.setAttributedString(NSAttributedString(string: prefix, attributes: [.font: font]))
            layout.ensureLayout(for: container)
            let visible = layout.glyphRange(for: container)
            if prefix.utf16.count < limit || limit >= source.utf16.count || NSMaxRange(visible) < layout.numberOfGlyphs { break }
            limit *= 2
        }
        let result = min(maximum, max(line, ceil(layout.usedRect(for: container).height)))
        // A resize can produce many distinct widths. Keep the cache bounded for long-running windows.
        if heights.count >= 8 { heights.removeAll(keepingCapacity: true) }
        heights[width] = result
        return result
    }
}
#endif
