#if DEBUG
import AppKit
import AmbulandoCore
import PDFKit

extension MacThreadRegression {
    /// Exercises the production exporter against local bundled WebKit, without a real account or downloads.
    static func documentExportCheck() async throws {
        let table = "| Item | Meaning |\n| --- | --- |\n" + (0..<90).map { "| Row \($0) | Table value \($0) |" }.joined(separator: "\n")
        let text = "Opening paragraph with **bold**, a [link](https://example.com), and café 日本語.\n\n" + table + "\n\n" +
            (0..<65).map { "Paragraph \($0): " + String(repeating: "A complete line of document text. ", count: 8) }.joined(separator: "\n\n") + "\n\nEXPORT FINAL SENTINEL"
        let body = DocumentBody(bytes: Data(text.utf8), contentType: "text/markdown")
        let markdown = DocumentExport.markdown(title: "Export regression", body: body)
        try require(String(data: markdown, encoding: .utf8) == "# Export regression\n\n" + text, "Markdown preserves title and exact body")
        let data = try await DocumentExport.pdf(title: "Export regression", body: body)
        if let directory = ProcessInfo.processInfo.environment["AMBULANDO_EXPORT_EVIDENCE"] {
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("document-export.pdf"))
        }
        guard let pdf = PDFDocument(data: data) else { throw Failure(description: "Export produced invalid PDF") }
        try require(pdf.pageCount > 5, "long document paginates")
        let extracted = pdf.string ?? ""
        if let directory = ProcessInfo.processInfo.environment["AMBULANDO_EXPORT_EVIDENCE"] {
            try Data(extracted.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("document-export-extracted.txt"))
        }
        // WebKit's CJK fallback font maps 日 to its compatibility-equivalent Kangxi radical ⽇ in the PDF
        // character map. Check NFKC equivalence as well as the visually inspected raster, never drop Unicode coverage.
        try require(extracted.precomposedStringWithCompatibilityMapping.contains("日本語"), "PDF retains compatibility-normalized Japanese")
        for sentinel in ["Export regression", "Opening paragraph", "café", "Row 0", "Row 89", "Paragraph 0:", "Paragraph 64:", "EXPORT FINAL SENTINEL"] {
            try require(extracted.contains(sentinel), "PDF retains \(sentinel)")
        }
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { throw Failure(description: "Missing PDF page") }
            let bounds = page.bounds(for: .mediaBox)
            try require(abs(bounds.width - 595) < 1 && abs(bounds.height - 842) < 1, "fixed A4 page \(index)")
            try require(!(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no empty page \(index)")
        }
        for row in 0..<90 {
            try require((0..<pdf.pageCount).contains { index in
                let source = pdf.page(at: index)?.string ?? ""
                return source.range(of: "Row \(row)(?![0-9])", options: .regularExpression) != nil && source.range(of: "Table value \(row)(?![0-9])", options: .regularExpression) != nil
            }, "table row \(row) stays together")
        }
        let normalized = extracted.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let repeatedPhrase = "A complete line of document text."
        try require(normalized.components(separatedBy: repeatedPhrase).count - 1 == 65 * 8, "pagination retains every repeated text phrase without clipping or duplicates")
        let imageBody = DocumentBody(bytes: Data("![Stored image](storage://01234567-89ab-cdef-0123-456789abcdef)".utf8), contentType: "text/markdown")
        do {
            _ = try await DocumentExport.pdf(title: "Missing image", body: imageBody)
            throw Failure(description: "Missing image silently exported")
        } catch is DocumentExport.Failure { }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Image fixture") }
        var requested: [String] = []
        let imagePDF = try await DocumentExport.pdf(title: "Stored image", body: imageBody) { id in
            requested.append(id); return "data:image/png;base64," + png.base64EncodedString()
        }
        try require(requested == ["01234567-89ab-cdef-0123-456789abcdef"], "storage image uses authenticated resolver")
        guard let imageDocument = PDFDocument(data: imagePDF), imageDocument.pageCount == 1,
              let rendered = imageDocument.page(at: 0)?.thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox).tiffRepresentation,
              let pixels = NSBitmapImageRep(data: rendered) else { throw Failure(description: "Stored-image PDF render") }
        var hasRed = false
        for y in stride(from: 0, to: pixels.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: pixels.pixelsWide, by: 4) {
                if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7 && color.greenComponent < 0.5 && color.blueComponent < 0.5 { hasRed = true; break }
            }
            if hasRed { break }
        }
        try require(hasRed, "resolved image pixels survive PDF rendering")
        print("DOCUMENT_EXPORT_PASS markdownExact paginatedTableUnicodeTail a4Pages=\(pdf.pageCount) storedImage missingImageFails")
    }
}
#endif
