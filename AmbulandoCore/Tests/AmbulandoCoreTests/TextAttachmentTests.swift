import Foundation
import XCTest
@testable import AmbulandoCore

private let ws = Fixtures.workspaceId
private let msg = "11111111-1111-4111-8111-111111111111"
private let orig = "22222222-2222-4222-8222-222222222222"
private let file = "33333333-3333-4333-8333-333333333333"
private let v1 = "44444444-4444-4444-8444-444444444444"
private let v2 = "55555555-5555-4555-8555-555555555555"

private func lineageRow(_ id: String, msg: String, storage: String) -> [String: Any] {
    ["id": id, "workspace_id": ws, "channel_id": Fixtures.channel1, "display_name": id, "row_version": 1, "created_at": "2026-10-26T00:00:00Z",
     "metadata": ["text_attachment_lineage": ["v": 1, "origin_message_id": msg, "origin_storage_object_id": storage]]]
}

/// Pasted text files: exact bytes, paging, durable drafts, the wire shape and the version/lineage calls.
final class TextAttachmentTests: XCTestCase {
    private let samples = [
        "plain", "line1\nline2\n", "crlf\r\nline\r\n", "lone\rcr\rhere", "\u{FEFF}bom first", "emoji 😀👨‍👩‍👧 e\u{301} \u{2028}sep", "", "tab\t\u{0}nul",
    ]

    // MARK: Paging

    func testPagesJoinToTheExactBytes() throws {
        for sample in samples {
            let pages = TextPages(text: sample)
            XCTAssertEqual(pages.data, Data(sample.utf8), sample)
            XCTAssertEqual(pages.byteCount, sample.utf8.count)
            XCTAssertEqual(pages.codePoints, sample.unicodeScalars.count)
        }
        // Many pages, CRLF everywhere, split points inside multi-scalar sequences.
        let big = String(repeating: "αβγ😀\r\nline of text\n\r", count: 20_000)
        let pages = TextPages(text: big)
        XCTAssertGreaterThan(pages.pageCount, 10)
        XCTAssertEqual(pages.data, Data(big.utf8))
        for page in pages.pages { XCTAssertLessThanOrEqual(page.unicodeScalars.count, TextPages.pageScalars + TextPages.lookahead + 1) }
        for (a, b) in zip(pages.pages, pages.pages.dropFirst()) {
            XCTAssertFalse(a.hasSuffix("\r") && b.hasPrefix("\n"), "a CRLF is never split across pages")
        }
    }

    func testPathologicalSingleLineIsPagedByCodePoints() {
        let line = String(repeating: "界😀x", count: 1_400_000)   // ~4.2M scalars, no newline at all
        let pages = TextPages(text: line)
        XCTAssertEqual(pages.pageCount, Int((Double(line.unicodeScalars.count) / Double(TextPages.pageScalars)).rounded(.up)))
        XCTAssertEqual(pages.data.count, line.utf8.count)
        XCTAssertEqual(pages.data, Data(line.utf8))
    }

    func testEditingOnePageKeepsEveryOtherByte() {
        let text = (0..<5_000).map { "row \($0)\r\n" }.joined()
        var pages = TextPages(text: text)
        let target = pages.pageCount / 2
        let original = pages.page(target)
        pages.replace(page: target, with: original + "added é😀")
        var expected = pages.pages
        expected[target] = original + "added é😀"
        XCTAssertEqual(pages.data, Data(expected.joined().utf8))
        XCTAssertEqual(pages.byteCount, pages.data.count)
        XCTAssertEqual(pages.page(containing: 0), 0)
        XCTAssertEqual(pages.page(containing: pages.codePoints - 1), pages.pageCount - 1)
    }

    func testInvalidUTF8IsNotEditableText() {
        XCTAssertNil(TextPages(data: Data([0x66, 0xFF, 0xFE])))
        XCTAssertNotNil(TextPages(data: Data("ok".utf8)))
    }

    // MARK: Staging

    func testStagingKeepsCompleteBytesAndDescribesThem() throws {
        let dir = temporaryDirectory()
        for sample in samples where !sample.isEmpty {
            let a = try TextAttachmentStaging.stage(text: sample, name: "Pasted text.txt", source: .paste, in: dir)
            XCTAssertEqual(try TextAttachmentStaging.read(a, in: dir), Data(sample.utf8))
            XCTAssertEqual(a.sizeBytes, sample.utf8.count)
            XCTAssertEqual(a.sha256, SHA256Hex.of(Data(sample.utf8)))
            XCTAssertEqual(a.text?.chars, sample.unicodeScalars.count)
            XCTAssertEqual(a.text?.lines, TextAttachmentPolicy.lineCount(Data(sample.utf8)))
            XCTAssertEqual(a.mimeType, "text/plain; charset=utf-8")
        }
        let a = try TextAttachmentStaging.stage(text: "héllo\nworld", name: "a/b:c", source: .paste, in: dir)
        XCTAssertEqual(a.filename, "abc.txt", "names are made safe")
        XCTAssertEqual(TextAttachmentStaging.head(a, in: dir), "héllo")
        // A corrupted staged file is refused rather than uploaded.
        try Data("tampered".utf8).write(to: dir.appendingPathComponent(a.staged))
        XCTAssertThrowsError(try TextAttachmentStaging.read(a, in: dir))
    }

    func testReplacingContentKeepsIdentityAndDropsTheOldFile() throws {
        let dir = temporaryDirectory()
        var a = try TextAttachmentStaging.stage(text: "one", name: "Pasted text.txt", source: .paste, in: dir)
        a.objectId = "x"; a.complete = true
        let b = try TextAttachmentStaging.replacing(a, data: Data("two\nthree".utf8), name: "Renamed", in: dir)
        XCTAssertEqual(b.id, a.id)
        XCTAssertEqual(b.filename, "Renamed.txt")
        XCTAssertEqual(b.text?.lines, 2)
        XCTAssertNil(b.objectId)
        XCTAssertFalse(b.complete, "an edited attachment uploads again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(a.staged).path))
        XCTAssertEqual(try TextAttachmentStaging.read(b, in: dir), Data("two\nthree".utf8))
    }

    func testNamesNumberAcrossTheDraft() throws {
        let dir = temporaryDirectory()
        var list: [PendingAttachment] = []
        for _ in 0..<3 { list.append(try TextAttachmentStaging.stage(text: "x", name: TextAttachmentStaging.nextName(among: list), source: .paste, in: dir)) }
        XCTAssertEqual(list.map(\.filename), ["Pasted text.txt", "Pasted text 2.txt", "Pasted text 3.txt"])
        list.remove(at: 1)
        XCTAssertEqual(TextAttachmentStaging.nextName(among: list), "Pasted text 2.txt", "a removed number is free again")
    }

    // MARK: Durable draft and outbox

    func testDraftKeepsAttachmentsAcrossRelaunchAndAttachmentOnlyDrafts() async throws {
        let h = try await ChatHarness.make()
        let dir = temporaryDirectory()
        let a = try TextAttachmentStaging.stage(text: "kept\r\nexactly", name: "Pasted text.txt", source: .paste, in: dir)
        let target = h.target()
        try await h.store.writer.saveDraft(target, Draft(text: "", mentions: [], attachments: [a]))
        let again = try await h.relaunch(unlock: false)
        let draft = try await again.store.reader.draft(target)
        XCTAssertEqual(draft?.attachments, [a], "an attachment-only draft is not discarded as empty")
        XCTAssertEqual(draft?.text, "")
        try await again.store.writer.saveDraft(target, Draft(text: "", mentions: [], attachments: []))
        let cleared = try await again.store.reader.draft(target)
        XCTAssertNil(cleared)
    }

    func testSendingMovesDraftAttachmentsToTheOutboxAndRestoreKeepsTheFiles() async throws {
        let h = try await ChatHarness.make()
        let dir = temporaryDirectory()
        let a = try TextAttachmentStaging.stage(text: "body", name: "Pasted text.txt", source: .paste, in: dir)
        let target = h.target()
        try await h.store.writer.saveDraft(target, Draft(text: "note", mentions: [], attachments: [a]))
        let item = try await h.store.writer.enqueueSend(target: target, origin: h.connection.origin, signerNpub: TestKeys.npub, appNpub: Fixtures.appNpub,
                                                        body: "note", mentions: [], attachments: [a])
        let gone = try await h.store.reader.draft(target)
        XCTAssertNil(gone)
        let kept = try await h.store.writer.discardOutbox(id: item.id, restoreDraft: true)
        XCTAssertTrue(kept)
        let restored = try await h.store.reader.draft(target)
        XCTAssertEqual(restored?.attachments.map(\.id), [a.id])
        XCTAssertEqual(restored?.attachments.first?.complete, false)
    }

    func testWireCarriesCountsAndNeverTheText() async throws {
        let h = try await ChatHarness.make()
        let dir = temporaryDirectory()
        var a = try TextAttachmentStaging.stage(text: "secret body\r\nline 2", name: "Pasted text 2.txt", source: .paste, in: dir)
        a.objectId = "3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"; a.complete = true
        let item = try await h.store.writer.enqueueSend(target: h.target(), origin: h.connection.origin, signerNpub: TestKeys.npub, appNpub: Fixtures.appNpub,
                                                        body: "", mentions: [], attachments: [a])
        let request = try await OutboxRequest.build(item, signer: h.identity)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        XCTAssertEqual(object["body"] as? String, "", "an attachment-only message has an empty body")
        let attachments = try XCTUnwrap((object["metadata"] as? [String: Any])?["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        let wire = attachments[0]
        XCTAssertEqual(wire["kind"] as? String, "file")
        XCTAssertEqual(wire["storage_object_id"] as? String, a.objectId)
        XCTAssertEqual(wire["filename"] as? String, "Pasted text 2.txt")
        XCTAssertEqual(wire["content_type"] as? String, "text/plain; charset=utf-8")
        XCTAssertEqual(wire["size_bytes"] as? Int, a.sizeBytes)
        XCTAssertEqual(wire["sha256_hex"] as? String, a.sha256)
        let text = try XCTUnwrap(wire["text_attachment"] as? [String: Any])
        XCTAssertEqual(text["v"] as? Int, 1)
        XCTAssertEqual(text["source"] as? String, "paste")
        XCTAssertEqual(text["chars"] as? Int, 19)
        XCTAssertEqual(text["lines"] as? Int, 2)
        XCTAssertFalse(String(decoding: request, as: UTF8.self).contains("secret body"), "no text preview in metadata")
        // The same record reads back from a stored message.
        let back = MessageAttachment.from(messageRaw: try JSONSerialization.data(withJSONObject: ["metadata": ["attachments": attachments]]))
        XCTAssertEqual(back.first?.textAttachment, a.text)
        XCTAssertEqual(back.first?.mimeType, "text/plain; charset=utf-8")
    }

    func testOldClientAttachmentsStillParse() throws {
        let raw = try JSONSerialization.data(withJSONObject: ["metadata": ["attachments": [
            ["kind": "file", "storage_object_id": "3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11", "filename": "n.txt", "mime_type": "text/plain", "size_bytes": 4]]]])
        let list = MessageAttachment.from(messageRaw: raw)
        XCTAssertEqual(list.first?.filename, "n.txt")
        XCTAssertNil(list.first?.textAttachment)
    }

    // MARK: Versions and lineage

    private func api(_ handler: @escaping StubTransport.Handler) async throws -> (TowerAPI, StubTransport) {
        let h = try await ChatHarness.make()
        let transport = StubTransport(handler)
        let client = TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: h.identity)
        return (TowerAPI(client: client), transport)
    }

    private func storageHandler(next: @escaping @Sendable (URLRequest) -> (Int, Any)?) -> StubTransport.Handler {
        { request in
            let path = request.url!.path
            if path.hasSuffix("/storage/prepare") { return (200, ["object_id": "66666666-6666-4666-8666-666666666666", "is_public": false, "upload_url": "https://tower.example/api/v4/storage/66666666-6666-4666-8666-666666666666"]) }
            if request.httpMethod == "PUT" { return (200, [:]) }
            if path.hasSuffix("/complete") { return (200, ["completed_at": "2026-10-26T00:00:00Z"]) }
            if path.hasPrefix("/api/v4/storage/") && request.httpMethod == "GET" {
                let body = (try? JSONSerialization.jsonObject(with: Data("{}".utf8))) as Any
                _ = body
                return (200, ["completed_at": "2026-10-26T00:00:00Z", "sha256_hex": SHA256Hex.of(Data("edited".utf8)), "size_bytes": 6, "is_public": false])
            }
            return next(request) ?? (404, ["code": "not_found"])
        }
    }

    func testFirstEditCreatesLineageFileAndLaterEditUsesVersions() async throws {
        let (api, transport) = try await api(storageHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/channels/\(Fixtures.channel1)/files") && request.httpMethod == "POST" {
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let lineage = (body["metadata"] as! [String: Any])["text_attachment_lineage"] as! [String: Any]
                XCTAssertEqual(lineage["origin_message_id"] as? String, msg)
                XCTAssertEqual(lineage["origin_storage_object_id"] as? String, orig)
                XCTAssertEqual(lineage["v"] as? Int, 1)
                return (201, ["file": ["id": file, "display_name": "Pasted text.txt", "current_version_id": v1]])
            }
            if path.hasSuffix("/files/\(file)/versions") && request.httpMethod == "POST" {
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["base_version_id"] as? String, v1)
                XCTAssertNotNil(body["client_mutation_id"])
                return (201, ["file": ["id": file, "display_name": "Pasted text.txt", "current_version_id": v2],
                              "version": ["id": v2, "version_number": 2, "storage_object_id": "66666666-6666-4666-8666-666666666666", "size_bytes": 6]])
            }
            return nil
        })
        let first = try await api.saveTextEdit(workspaceId: ws, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, origin: (msg, orig, "Pasted text.txt"),
                                               lineage: nil, baseVersionId: nil, bytes: Data("edited".utf8), filename: "Pasted text.txt", clientMutationId: "m1")
        guard case .saved(let lineage, _) = first else { return XCTFail("first edit saves") }
        XCTAssertEqual(lineage.fileId, file)
        XCTAssertEqual(lineage.currentVersionId, v1)
        let later = try await api.saveTextEdit(workspaceId: ws, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, origin: (msg, orig, "Pasted text.txt"),
                                               lineage: lineage, baseVersionId: v1, bytes: Data("edited".utf8), filename: "Pasted text.txt", clientMutationId: "m2")
        guard case .saved(let after, let version) = later else { return XCTFail("later edit saves") }
        XCTAssertEqual(after.currentVersionId, v2)
        XCTAssertEqual(version?.number, 2)
        XCTAssertGreaterThan(transport.recorded.count, 4)
    }

    func testStaleBaseAndExistingLineageAreConflictsNotOverwrites() async throws {
        let (api, _) = try await api(storageHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/files/\(file)/versions") && request.httpMethod == "POST" {
                return (409, ["code": "stale_base_version", "file": ["id": file, "display_name": "x.txt", "current_version_id": v2],
                              "current_version": ["id": v2, "version_number": 2, "storage_object_id": "77777777-7777-4777-8777-777777777777"]])
            }
            if path.hasSuffix("/channels/\(Fixtures.channel1)/files") && request.httpMethod == "POST" {
                return (409, ["code": "lineage_file_exists", "file": ["id": file, "display_name": "x.txt", "current_version_id": v1],
                              "current_version": ["id": v1, "version_number": 1, "storage_object_id": "88888888-8888-4888-8888-888888888888"]])
            }
            return nil
        })
        let stale = try await api.saveTextEdit(workspaceId: ws, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, origin: (msg, orig, "x.txt"),
                                               lineage: TextLineage(fileId: file, displayName: "x.txt", currentVersionId: v1), baseVersionId: v1,
                                               bytes: Data("edited".utf8), filename: "x.txt", clientMutationId: "m")
        guard case .conflict(let l1, let c1) = stale else { return XCTFail("stale base is a conflict") }
        XCTAssertEqual(l1.currentVersionId, v2)
        XCTAssertEqual(c1?.versionId, v2)
        let duplicate = try await api.saveTextEdit(workspaceId: ws, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, origin: (msg, orig, "x.txt"),
                                                   lineage: nil, baseVersionId: nil, bytes: Data("edited".utf8), filename: "x.txt", clientMutationId: "m")
        guard case .conflict(let l2, _) = duplicate else { return XCTFail("existing lineage is a conflict") }
        XCTAssertEqual(l2.fileId, file, "the canonical file is adopted, never guessed")
    }

    func testPermissionDeniedIsReportedNotRetried() async throws {
        let (api, _) = try await api(storageHandler { request in
            request.url!.path.hasSuffix("/versions") ? (403, ["code": "forbidden"]) : nil
        })
        do {
            _ = try await api.saveTextEdit(workspaceId: ws, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, origin: (msg, orig, "x.txt"),
                                           lineage: TextLineage(fileId: file, displayName: "x.txt", currentVersionId: v1), baseVersionId: v1,
                                           bytes: Data("edited".utf8), filename: "x.txt", clientMutationId: "m")
            XCTFail("403 must throw")
        } catch { XCTAssertEqual(error as? TextVersionError, .forbidden) }
    }

    func testLineageIsFoundByBothIdsNeverBySiblingOrAge() async throws {
        let (api, _) = try await api { request in
            request.url!.path.hasSuffix("/files") ? (200, ["files": [lineageRow("99999999-9999-4999-8999-999999999999", msg: msg, storage: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                                                                     lineageRow(file, msg: msg, storage: orig)]]) : (404, [:])
        }
        let found = try await api.textLineage(workspaceId: ws, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, originMessageId: msg, originStorageObjectId: orig)
        XCTAssertEqual(found?.fileId, file)
        let none = try await api.textLineage(workspaceId: ws, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, originMessageId: msg,
                                             originStorageObjectId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        XCTAssertNil(none)
    }
}
