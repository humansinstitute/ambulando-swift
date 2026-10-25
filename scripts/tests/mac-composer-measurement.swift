// Run: swiftc -parse-as-library Ambulando/Views/MacComposerMeasurement.swift \
//   scripts/tests/mac-composer-measurement.swift -o /tmp/mac-composer-check && /tmp/mac-composer-check
import AppKit

@main struct MacComposerMeasurementCheck {
    @MainActor static func main() {
        let measurement = MacComposerMeasurement()
        let font = NSFont.systemFont(ofSize: 15)
        let line = ceil(font.ascender - font.descender + font.leading)
        let short = measurement.height(text: "hello", font: font, width: 400, maxLines: 6)
        precondition(short >= line && short < line * 2)
        let multiline = measurement.height(text: "one\ntwo\nthree", font: font, width: 400, maxLines: 6)
        precondition(multiline > short * 2)
        let wrapped = String(repeating: "a wrapping sentence with emoji 👩🏽‍💻 ", count: 8)
        let narrow = measurement.height(text: wrapped, font: font, width: 160, maxLines: 6)
        let wide = measurement.height(text: wrapped, font: font, width: 900, maxLines: 6)
        precondition(narrow > wide)
        precondition(measurement.height(text: wrapped, font: font, width: 160, maxLines: 6) == narrow)
        // Deleting a long draft and changing text size must invalidate measurements for the same width.
        precondition(measurement.height(text: "", font: font, width: 160, maxLines: 6) == short)
        let larger = measurement.height(text: "hello", font: .systemFont(ofSize: 30), width: 400, maxLines: 6)
        precondition(larger > short)
        // Prefix growth must agree with full detached layout even when 4096 code units fit in a wide proposal.
        for draft in [String(repeating: "x", count: 12_000), String(repeating: "emoji 👩🏽‍💻 ", count: 800), "one\ntwo\nthree"] {
            let storage = NSTextStorage(string: draft, attributes: [.font: font])
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 40_000, height: line * 6))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 6
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let expected = min(line * 6, max(line, ceil(layout.usedRect(for: container).height)))
            precondition(measurement.height(text: draft, font: font, width: 40_000, maxLines: 6) == expected)
        }
        precondition(measurement.height(text: wrapped, font: font, width: 160, maxLines: 2) <= line * 2)
        precondition(measurement.height(text: wrapped, font: font, width: 160, maxLines: 6) == narrow)
        for draft in [String(repeating: "long crash report wrapped text 👩🏽‍💻\n", count: 20_000),
                      String(repeating: "x", count: 500_000)] {
            let start = Date()
            for width: CGFloat in [160, 400, 800, 160, 400, 800] {
                let height = measurement.height(text: draft, font: font, width: width, maxLines: 6)
                precondition(height > 0 && height <= line * 6)
            }
            print("\(draft.count) characters, six proposals: \(Date().timeIntervalSince(start)) seconds")
        }
        print("Mac composer measurement checks passed")
    }
}
