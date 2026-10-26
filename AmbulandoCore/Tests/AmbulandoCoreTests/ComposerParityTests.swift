import XCTest
@testable import AmbulandoCore

final class ComposerParityTests: XCTestCase {
    let rick = Mention(type: .agent, npub: "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5", label: "Rick")
    let id = "d2baabe4-4d38-4bd7-b64e-4beedd8e1a19"

    func testBackspaceInsideAPickedNameRemovesTheWholeName() {
        let old = "Hi @Rick"
        XCTAssertEqual(MentionCodec.wholeMentionDeletion(old: old, new: "Hi @Ric", mentions: [rick]), "Hi ")
        // Deleting the space after the name only removes the space; the name stays until the next Backspace.
        XCTAssertNil(MentionCodec.wholeMentionDeletion(old: "Hi @Rick ", new: "Hi @Rick", mentions: [rick]))
        XCTAssertEqual(MentionCodec.wholeMentionDeletion(old: "Hi @Rick please", new: "Hi @Rik please", mentions: [rick]), "Hi please")
        XCTAssertNil(MentionCodec.wholeMentionDeletion(old: "Hi there", new: "Hi ther", mentions: [rick]))
    }

    func testPillsFollowTheTextAndRemovalKeepsRouting() {
        XCTAssertEqual(MentionCodec.present([rick], in: "ask @Rick now"), [rick])
        XCTAssertEqual(MentionCodec.present([rick], in: "ask now"), [])
        XCTAssertEqual(MentionCodec.removing(rick, from: "ask @Rick now"), "ask now")
        let (body, mentions) = MentionCodec.encode(text: "ask @Rick now", selected: [rick])
        XCTAssertEqual(body, "ask \(rick.token) now")
        XCTAssertEqual(mentions, [rick])
    }

    func testUploadedReferencesLeaveTheFieldButStayInTheMessage() {
        let image = StorageMarkdown.image(objectId: id, alt: "shot.png")
        let text = "look\n\(image)"
        XCTAssertEqual(StorageMarkdown.strippingReferences(from: text), "look")
        XCTAssertEqual(StorageMarkdown.rawReferences(in: text).map(\.attachment.storageObjectId), [id])
        // Typing more keeps the upload (after the typed text).
        XCTAssertEqual(StorageMarkdown.composing(visible: "look here", keeping: text), "look here\n\(image)")
        XCTAssertEqual(StorageMarkdown.composing(visible: "", keeping: image), image)
        XCTAssertEqual(StorageMarkdown.removing(objectId: id, from: text), "look")
        XCTAssertEqual(StorageMarkdown.removing(objectId: id, from: image), "")
        // A space or line break typed at the end of the field is kept (it is not swallowed by the reference after it).
        XCTAssertEqual(StorageMarkdown.strippingReferences(from: StorageMarkdown.composing(visible: "look ", keeping: image)), "look ")
        XCTAssertEqual(StorageMarkdown.strippingReferences(from: StorageMarkdown.composing(visible: "look\n", keeping: image)), "look\n")
    }
}
