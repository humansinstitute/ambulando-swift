import XCTest
@testable import AmbulandoCore

final class TextAttachmentPolicyTests: XCTestCase {
    func testThresholdBoundaryCountsCodePoints() {
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: String(repeating: "a", count: 2500), existingCodePoints: 0), .inline)
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: String(repeating: "a", count: 2501), existingCodePoints: 0), .file)
        // An emoji is one code point (two UTF-16 units); a flag is two code points, one grapheme.
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: String(repeating: "😀", count: 2500), existingCodePoints: 0), .inline)
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: String(repeating: "😀", count: 2501), existingCodePoints: 0), .file)
        XCTAssertEqual(TextAttachmentPolicy.codePoints("🇦🇺"), 2)
        XCTAssertEqual(TextAttachmentPolicy.codePoints("e\u{301}"), 2)
    }

    func testInlineTotalCapAndByteGuard() {
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: "abc", existingCodePoints: 9997), .inline)
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: "abcd", existingCodePoints: 9997), .file)
        // 2400 four-byte scalars stay under the paste threshold but over the byte guard together with prior text.
        let wide = String(repeating: "😀", count: 2400)
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: wide, existingCodePoints: 100, existingUTF8Bytes: 30_500), .file)
        XCTAssertEqual(TextAttachmentPolicy.decide(paste: wide, existingCodePoints: 100, existingUTF8Bytes: 100), .inline)
    }

    func testTypingLimitAndCounter() {
        XCTAssertTrue(TextAttachmentPolicy.typingFits(insert: "a", replacing: "", existingCodePoints: 9999, existingUTF8Bytes: 9999))
        XCTAssertFalse(TextAttachmentPolicy.typingFits(insert: "ab", replacing: "", existingCodePoints: 9999, existingUTF8Bytes: 9999))
        XCTAssertTrue(TextAttachmentPolicy.typingFits(insert: "ab", replacing: "xy", existingCodePoints: 10_000, existingUTF8Bytes: 10_000))
        XCTAssertNil(TextAttachmentPolicy.remaining(codePoints: 9000))
        XCTAssertEqual(TextAttachmentPolicy.remaining(codePoints: 9500), 500)
        XCTAssertEqual(TextAttachmentPolicy.remaining(codePoints: 10_000), 0)
    }

    func testNamingIsNumberedAndSkipsTaken() {
        XCTAssertEqual(TextAttachmentPolicy.nextName(taken: []), "Pasted text.txt")
        XCTAssertEqual(TextAttachmentPolicy.nextName(taken: ["Pasted text.txt"]), "Pasted text 2.txt")
        XCTAssertEqual(TextAttachmentPolicy.nextName(taken: ["pasted text.txt", "Pasted text 3.txt"]), "Pasted text 2.txt")
        XCTAssertEqual(TextAttachmentPolicy.sanitizedName("  a/b\\c:d\u{7}.txt "), "abcd.txt")
        XCTAssertEqual(TextAttachmentPolicy.sanitizedName("notes"), "notes.txt")
        XCTAssertEqual(TextAttachmentPolicy.sanitizedName(".."), "Pasted text.txt")
        XCTAssertEqual(TextAttachmentPolicy.sanitizedName(""), "Pasted text.txt")
    }

    func testBytesPreserveCRLFAndUnicodeExactly() {
        let text = "line1\r\nline2\rline3\n😀 e\u{301} \u{0}end"
        XCTAssertEqual(TextAttachmentPolicy.fileBytes(text), Data(text.utf8))
        XCTAssertEqual(String(decoding: TextAttachmentPolicy.fileBytes(text), as: UTF8.self).unicodeScalars.map(\.value), text.unicodeScalars.map(\.value))
    }

    func testLineCountAndPreview() {
        XCTAssertEqual(TextAttachmentPolicy.lineCount(Data()), 0)
        XCTAssertEqual(TextAttachmentPolicy.lineCount(Data("a".utf8)), 1)
        XCTAssertEqual(TextAttachmentPolicy.lineCount(Data("a\nb".utf8)), 2)
        XCTAssertEqual(TextAttachmentPolicy.lineCount(Data("a\r\nb\r\n".utf8)), 2)
        XCTAssertEqual(TextAttachmentPolicy.lineCount(Data("a\rb\rc".utf8)), 3)
        XCTAssertEqual(TextAttachmentPolicy.lineCount(Data("\n\n".utf8)), 2)
        XCTAssertEqual(TextAttachmentPolicy.preview("\r\n  hello world\nsecond"), "hello world")
        let long = String(repeating: "😀", count: 5000)
        XCTAssertEqual(TextAttachmentPolicy.preview(long).unicodeScalars.count, 140)
    }
}
