import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import AmbulandoCore

/// Pasting images and files into a chat composer (sol `handleChatPaste` / `uploadChatFileDraft`): placeholders at the
/// caret, uploads through the existing storage route, results only in the captured target's text.
@MainActor
final class ComposerUploadTests: XCTestCase {
    // MARK: Helpers shared with the web

    func testStorageMarkdownAndPlaceholdersMatchTheWebHelpers() {
        let id = "3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"
        XCTAssertEqual(StorageMarkdown.image(objectId: id, alt: " shot [1] "), "![shot 1](storage://\(id))")
        XCTAssertEqual(StorageMarkdown.image(objectId: id, alt: "[]"), "![Image](storage://\(id))")
        XCTAssertEqual(StorageMarkdown.file(objectId: id, name: #"a\b [v2].pdf"#), #"[a\\b \[v2\].pdf](storage://\#(id))"#)
        XCTAssertEqual(StorageMarkdown.file(objectId: id, name: " "), "[Uploaded file](storage://\(id))")

        let body = "see ![Board](storage://\(id)) and [notes.txt](storage://0b1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d22) again ![x](storage://\(id))"
        let refs = StorageMarkdown.references(in: body)
        XCTAssertEqual(refs.map(\.kind), ["image", "file"])
        XCTAssertEqual(refs.map(\.filename), ["Board", "notes.txt"])
        let picked = MessageAttachment(kind: "image", storageObjectId: "9a1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d33", filename: "photo.png", mimeType: "image/png", sizeBytes: 3)
        XCTAssertEqual(StorageMarkdown.merged([picked], body: body).map(\.storageObjectId), [picked.storageObjectId, id, "0b1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d22"])
        XCTAssertEqual(StorageMarkdown.standalone(StorageMarkdown.merged([picked], body: body), body: body), [picked], "linked objects are not shown twice")

        let token = UploadToken.make(.image, id: "abc-1")
        XCTAssertEqual(token, "[ Uploading image abc-1... ]")
        let smartToken = token.replacingOccurrences(of: "...", with: "…")
        XCTAssertTrue(UploadToken.contains(in: smartToken))
        XCTAssertEqual(UploadToken.ids(in: smartToken).first?.id, "abc-1")
        XCTAssertEqual(ComposerText.replacing(token, with: "uploaded", in: smartToken, selection: nil)?.text, "uploaded")
        XCTAssertTrue(UploadToken.contains(in: "x \(token) y"))
        XCTAssertTrue(UploadToken.contains(in: "[ Uploading image 3... ]"), "the web's numbered form")
        XCTAssertTrue(UploadToken.contains(in: "[ Uploading file... ]"), "the web's plain form")
        XCTAssertFalse(UploadToken.contains(in: "[ Uploading image soon ]"))
        XCTAssertEqual(UploadToken.ids(in: "\(token) \(UploadToken.make(.file, id: "f2"))").map(\.id), ["abc-1", "f2"])

        // The caret keeps its place around a replaced placeholder.
        let text = "Hi \(token) there"
        let after = NSRange(location: (text as NSString).length, length: 0)
        let replaced = ComposerText.replacing(token, with: "![a](storage://1)", in: text, selection: after)
        XCTAssertEqual(replaced?.text, "Hi ![a](storage://1) there")
        XCTAssertEqual(replaced?.selection, NSRange(location: ("Hi ![a](storage://1) there" as NSString).length, length: 0))
        XCTAssertEqual(ComposerText.replacing(token, with: "", in: text, selection: NSRange(location: 1, length: 0))?.selection, NSRange(location: 1, length: 0))
        XCTAssertNil(ComposerText.replacing(token, with: "x", in: "no placeholder", selection: nil))
        XCTAssertEqual(ComposerText.remap(NSRange(location: 6, length: 0), from: "Hi @Pe", to: "Hi @Pete "), NSRange(location: 9, length: 0))
        XCTAssertEqual(ComposerText.remap(NSRange(location: 2, length: 0), from: "Hi", to: "Hi @"), NSRange(location: 4, length: 0))
        XCTAssertEqual(ComposerText.remap(NSRange(location: 1, length: 0), from: "Hi @Pe", to: "Hi @Pete "), NSRange(location: 1, length: 0))
    }

    func testTextAndLinksAreOrdinaryPastes() {
        let text = NSItemProvider(object: "hello" as NSString)
        let link = NSItemProvider(object: URL(string: "https://example.invalid/a.png")! as NSURL)
        XCTAssertTrue(ComposerUploads.attachments(in: [text, link]).isEmpty)
        let image = NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: UTType.png.identifier)
        let pdf = NSItemProvider(item: Data([4]) as NSData, typeIdentifier: UTType.pdf.identifier)
        XCTAssertEqual(ComposerUploads.attachments(in: [text, image, pdf]).map(\.kind), [.image, .file])
        let namedText = NSItemProvider(item: Data("x".utf8) as NSData, typeIdentifier: UTType.plainText.identifier)
        XCTAssertTrue(ComposerUploads.attachments(in: [namedText]).isEmpty, "copied text is pasted as text")
        namedText.suggestedName = "notes.txt"
        XCTAssertEqual(ComposerUploads.attachments(in: [namedText]).map(\.kind), [.file], "a copied text file is a file")
    }

    // MARK: Sync engine

    func testPerformReturnsResultsAndEndsDroppedJobs() async throws {
        let engine = SyncEngine(maxConcurrent: 1)
        let value = try await engine.perform("p1") { 42 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await engine.perform("p2") { () -> Int in throw URLError(.notConnectedToInternet) }
            XCTFail("expected the job's error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let failures = await engine.failureCount("p2")
        XCTAssertEqual(failures, 0, "the error goes to the caller, not into the key's backoff")

        // A job still queued when everything is cancelled (lock) ends instead of hanging.
        let gate = Gate()
        await engine.enqueue("busy", priority: .user) { await gate.wait() }
        let waiting = Task { try await engine.perform("p3") { 1 } }
        try await Task.sleep(for: .milliseconds(50))
        await engine.cancelAll()
        do { _ = try await waiting.value; XCTFail("dropped job returned") } catch { XCTAssertTrue(error is CancellationError) }
        await gate.open()
    }

    // MARK: Uploads

    func testPastedImageUploadsAndReplacesItsPlaceholderAtTheCaret() async throws {
        let h = try await WorkHarness.make()
        let uploads = center(h)
        let host = Host(h.chat.target(), text: "Hi  there", caret: 3)
        uploads.attach(host)
        let started = Date()
        let tokens = uploads.paste([imageProvider()], target: host.uploadTarget, appNpub: h.workspace.appNpub, context: "message")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "paste returns at once; reading and stripping run off the main actor")
        XCTAssertEqual(tokens.count, 1)
        host.insert(tokens.joined())
        XCTAssertEqual(uploads.uploads(for: host.uploadTarget).first?.phase, .preparing)
        host.type(" more")   // typing continues while the upload runs

        try await eventually { host.uploadText.contains("storage://") }
        let refs = StorageMarkdown.references(in: host.uploadText)
        let ref = try XCTUnwrap(refs.first)
        XCTAssertEqual(ref.kind, "image")
        XCTAssertTrue(ref.filename.hasPrefix("message-image-") && ref.filename.hasSuffix(".png"), ref.filename)
        XCTAssertEqual(host.uploadText, "Hi \(StorageMarkdown.image(objectId: ref.storageObjectId, alt: ref.filename)) more there")
        XCTAssertFalse(UploadToken.contains(in: host.uploadText))
        XCTAssertTrue(uploads.uploads(for: host.uploadTarget).isEmpty)
        XCTAssertEqual(try stagedFiles(h), [], "staged bytes and the record are removed once the link is in the text")
        XCTAssertTrue(h.work.credentialLeaks.isEmpty, "presigned PUT stays unsigned")

        // Sending carries the link as an attachment too, as the web does.
        try await h.outbox.send(text: host.uploadText, mentions: [], target: host.uploadTarget, connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let post = try XCTUnwrap(h.chat.tower.recordedPosts.last)
        let body = try JSONSerialization.jsonObject(with: post.body) as! [String: Any]
        let attachments = ((body["metadata"] as? [String: Any])?["attachments"] as? [[String: Any]]) ?? []
        XCTAssertEqual(attachments.map { $0["storage_object_id"] as? String }, [ref.storageObjectId])
        XCTAssertEqual(attachments.first?["kind"] as? String, "image")
    }

    func testPastedFileBecomesAnEscapedStorageLink() async throws {
        let h = try await WorkHarness.make()
        let uploads = center(h)
        let source = temporaryDirectory().appendingPathComponent("notes [v2].txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("quarterly".utf8).write(to: source)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        provider.suggestedName = "notes [v2].txt"   // as iOS names a copied file
        let host = Host(h.chat.target(thread: "11111111-2222-4333-8444-555555555555"), text: "", caret: 0)
        uploads.attach(host)
        host.insert(uploads.paste([provider], target: host.uploadTarget, appNpub: h.workspace.appNpub, context: "thread").joined())
        XCTAssertTrue(host.uploadText.hasPrefix("[ Uploading file "))
        try await eventually { host.uploadText.contains("storage://") }
        let ref = try XCTUnwrap(StorageMarkdown.references(in: host.uploadText).first)
        XCTAssertEqual(ref.kind, "file")
        XCTAssertEqual(ref.filename, "notes [v2].txt")
        XCTAssertEqual(host.uploadText, #"[notes \[v2\].txt](storage://\#(ref.storageObjectId))"#)
    }

    func testOfflineUploadFailsVisiblyBlocksSendAndRetriesWithThePreparedObject() async throws {
        let h = try await WorkHarness.make()
        let uploads = center(h)
        let host = Host(h.chat.target(), text: "Look ", caret: 5)
        uploads.attach(host)
        h.work.inject(.offline, matching: "presigned")
        host.insert(uploads.paste([imageProvider()], target: host.uploadTarget, appNpub: h.workspace.appNpub, context: "message").joined())
        try await eventually { if case .failed = uploads.uploads(for: host.uploadTarget).first?.phase { true } else { false } }
        let failed = try XCTUnwrap(uploads.uploads(for: host.uploadTarget).first)
        XCTAssertEqual(failed.phase, .failed("Offline. Retry when connected."))
        XCTAssertTrue(failed.retryable)
        XCTAssertTrue(UploadToken.contains(in: host.uploadText), "the placeholder stays so Retry can still fill it")
        do {
            try await h.outbox.send(text: host.uploadText, mentions: [], target: host.uploadTarget, connection: h.connection, workspace: h.workspace)
            XCTFail("a placeholder was sent")
        } catch { XCTAssertEqual(error as? ComposerUploadError, .unresolved) }
        let queued = try await h.store.reader.outbox(target: host.uploadTarget)
        XCTAssertTrue(queued.isEmpty)

        uploads.retry(failed.id)
        try await eventually { host.uploadText.contains("storage://") }
        XCTAssertEqual(h.transport.recorded.filter { $0.url!.path.hasSuffix("/storage/prepare") }.count, 1, "retry reused the prepared object")
    }

    func testLockedIdentityAsksToUnlock() async throws {
        let h = try await WorkHarness.make()
        let uploads = center(h)
        await h.chat.identity.lock()
        let host = Host(h.chat.target(), text: "", caret: 0)
        uploads.attach(host)
        host.insert(uploads.paste([imageProvider()], target: host.uploadTarget, appNpub: h.workspace.appNpub, context: "message").joined())
        try await eventually { if case .failed = uploads.uploads(for: host.uploadTarget).first?.phase { true } else { false } }
        XCTAssertEqual(uploads.uploads(for: host.uploadTarget).first?.phase, .failed("Unlock to upload."))
        XCTAssertFalse(h.transport.recorded.contains { $0.url!.path.contains("/storage") }, "nothing is sent while locked")
    }

    func testResultGoesOnlyToTheCapturedDraftAfterNavigating() async throws {
        let h = try await WorkHarness.make()
        let gate = Gate()
        let uploads = ComposerUploads(store: h.store, staging: h.staging) { _ in await gate.wait(); return "5e1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d55" }
        let first = Host(h.chat.target(Fixtures.channel1), text: "One ", caret: 4)
        uploads.attach(first)
        first.insert(uploads.paste([imageProvider()], target: first.uploadTarget, appNpub: h.workspace.appNpub, context: "message").joined())
        try await eventually { uploads.uploads(for: first.uploadTarget).first?.phase == .uploading }
        // The user leaves: the draft (with its placeholder) is saved and another channel's composer opens.
        try await h.store.writer.saveDraft(first.uploadTarget, Draft(text: first.uploadText, mentions: []))
        uploads.detach(first)
        let second = Host(h.chat.target(Fixtures.channel2), text: "Two", caret: 3)
        uploads.attach(second)
        await gate.open()

        try await eventually { (try? await h.store.reader.draft(first.uploadTarget))??.text.contains("storage://") == true }
        let saved = try await h.store.reader.draft(first.uploadTarget)
        XCTAssertEqual(saved?.text, "One ![\(try XCTUnwrap(StorageMarkdown.references(in: saved?.text ?? "").first?.filename))](storage://5e1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d55)")
        XCTAssertEqual(second.uploadText, "Two", "the open composer of another channel is untouched")
        let other = try await h.store.reader.draft(second.uploadTarget)
        XCTAssertNil(other)
        XCTAssertTrue(uploads.uploads(for: first.uploadTarget).isEmpty)
    }

    func testRemoveCancelsTheUploadAndTakesThePlaceholderOut() async throws {
        let h = try await WorkHarness.make()
        let gate = Gate()
        let uploads = ComposerUploads(store: h.store, staging: h.staging) { _ in
            await gate.wait()
            try Task.checkCancellation()
            return "6e1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d66"
        }
        let host = Host(h.chat.target(), text: "Keep this", caret: 4)
        uploads.attach(host)
        host.insert(uploads.paste([imageProvider()], target: host.uploadTarget, appNpub: h.workspace.appNpub, context: "message").joined())
        try await eventually { uploads.uploads(for: host.uploadTarget).first?.phase == .uploading }
        uploads.remove(try XCTUnwrap(uploads.uploads(for: host.uploadTarget).first).id)
        XCTAssertEqual(host.uploadText, "Keep this")
        XCTAssertEqual(try stagedFiles(h), [])
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(host.uploadText, "Keep this", "a cancelled upload never writes into the text")
    }

    func testAfterRelaunchAnInterruptedUploadCanBeRetried() async throws {
        let h = try await WorkHarness.make()
        h.work.inject(.offline, matching: "presigned")
        let before = center(h)
        let host = Host(h.chat.target(), text: "", caret: 0)
        before.attach(host)
        host.insert(before.paste([imageProvider()], target: host.uploadTarget, appNpub: h.workspace.appNpub, context: "message").joined())
        try await eventually { if case .failed = before.uploads(for: host.uploadTarget).first?.phase { true } else { false } }

        // Relaunch: a new coordinator, the saved draft still holds the placeholder.
        let after = center(h)
        let reopened = Host(h.chat.target(), text: host.uploadText, caret: 0)
        after.attach(reopened)
        let restored = try XCTUnwrap(after.uploads(for: reopened.uploadTarget).first)
        XCTAssertEqual(restored.phase, .failed("Upload was interrupted."))
        XCTAssertTrue(restored.retryable)
        after.retry(restored.id)
        try await eventually { reopened.uploadText.contains("storage://") }

        // A placeholder with nothing behind it (or copied into another conversation) can only be removed.
        let elsewhere = Host(h.chat.target(Fixtures.channel2), text: UploadToken.make(.image, id: restored.id), caret: 0)
        after.attach(elsewhere)
        let orphan = try XCTUnwrap(after.uploads(for: elsewhere.uploadTarget).first)
        XCTAssertFalse(orphan.retryable)
        after.remove(orphan.id)
        XCTAssertEqual(elsewhere.uploadText, "")
    }

    func testApplicationBoundRestoreKeepsForeignPreparedAndCompletedUploadsPrivateAndRecoverable() async throws {
        let h = try await WorkHarness.make()
        let originalApp = Bech32.encode(hrp: "npub", data: Data(repeating: 0x11, count: 32))
        let objectId = "3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"
        let target = h.chat.target(), counter = Counter()
        try FileManager.default.createDirectory(at: h.staging, withIntermediateDirectories: true)
        for completed in [false, true] {
            let id = UUID().uuidString.lowercased(), bytes = Data("private old-application attachment".utf8)
            let file = "paste-\(id).png", token = UploadToken.make(.image, id: id)
            let record = ComposerUploads.Record(id: id, target: target, appNpub: originalApp, kind: .image,
                filename: "private-old-application-filename.png", mimeType: "image/png", sizeBytes: bytes.count,
                sha256: SHA256Hex.of(bytes), staged: file,
                prepared: PreparedObject(objectId: objectId, uploadURL: "https://objects.example/private-old-object"),
                objectId: completed ? objectId : nil)
            let recordURL = h.staging.appendingPathComponent("paste-\(id).json")
            let fileURL = h.staging.appendingPathComponent(file)
            let encoded = try JSONEncoder().encode(record)
            try encoded.write(to: recordURL); try bytes.write(to: fileURL)

            // Connection/workspace/channel/thread IDs are identical; only the application's namespace differs.
            let current = ComposerUploads(store: h.store, staging: h.staging, appNpub: h.workspace.appNpub) { _ in
                await counter.enter("wrong-application upload"); return objectId
            }
            let host = Host(target, text: token, caret: token.count)
            current.attach(host)
            XCTAssertTrue(current.items.isEmpty, "No filename, prepared URL, size or object ID may enter the other application's UI")
            XCTAssertTrue(current.uploads(for: target).isEmpty)
            XCTAssertEqual(host.uploadText, token, "A completed foreign object must not replace the token")
            current.retry(id); current.remove(id)
            XCTAssertEqual(try Data(contentsOf: recordURL), encoded)
            XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

            // The original application can still restore its pending upload or apply its completed object.
            let original = ComposerUploads(store: h.store, staging: h.staging, appNpub: originalApp) { job in
                XCTAssertEqual(job.appNpub, originalApp)
                return objectId
            }
            let restoredHost = Host(target, text: token, caret: token.count)
            original.attach(restoredHost)
            if !completed {
                let restored = try XCTUnwrap(original.uploads(for: target).first)
                XCTAssertEqual(restored.filename, record.filename)
                XCTAssertEqual(restored.prepared, record.prepared)
                XCTAssertTrue(restored.retryable)
                original.retry(id)
                try await eventually { restoredHost.uploadText.contains("storage://") }
            }
            XCTAssertTrue(restoredHost.uploadText.contains(objectId))
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
        let wrongUploads = await counter.total
        XCTAssertEqual(wrongUploads, 0)
    }

    func testApplicationBoundPasteRejectsMismatchedAppBeforeStagingAndAcceptsItsOwnApp() async throws {
        let h = try await WorkHarness.make(), counter = Counter()
        let objectId = "3f1c2b9e-6a0d-4b8e-9d1f-0c2a7e5b4d11"
        let uploads = ComposerUploads(store: h.store, staging: h.staging, appNpub: h.workspace.appNpub) { job in
            await counter.enter(job.appNpub); return objectId
        }
        let host = Host(h.chat.target(), text: "", caret: 0)
        uploads.attach(host)
        let before = try stagedFiles(h)
        let rejected = uploads.paste([imageProvider()], target: host.uploadTarget, appNpub: "another-application", context: "message")
        XCTAssertTrue(rejected.isEmpty); XCTAssertTrue(uploads.items.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try stagedFiles(h), before)
        let rejectedCount = await counter.total
        XCTAssertEqual(rejectedCount, 0)

        host.insert(uploads.paste([imageProvider()], target: host.uploadTarget, appNpub: h.workspace.appNpub, context: "message").joined())
        try await eventually { host.uploadText.contains("storage://") }
        let acceptedApps = await counter.order
        XCTAssertEqual(acceptedApps, [h.workspace.appNpub])
    }

    // MARK: Support

    private func center(_ h: WorkHarness) -> ComposerUploads {
        let transfer = ComposerUploadTransfer(engine: h.engine, identity: h.chat.identity, transport: h.transport)
        let connection = h.connection
        return ComposerUploads(store: h.store, staging: h.staging) { job in try await transfer.upload(job, connection: connection) }
    }

    private func imageProvider() -> NSItemProvider {
        NSItemProvider(item: (try? SamplePixels.jpegWithEXIF()) as NSData?, typeIdentifier: UTType.jpeg.identifier)
    }

    private func stagedFiles(_ h: WorkHarness) throws -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: h.staging.path)) ?? []).filter { $0.hasPrefix("paste-") }
    }

    private func eventually(timeout: Double = 10, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout) s")
        throw CancellationError()
    }
}

/// A composer stand-in: text plus a caret, edited like the text view does.
@MainActor
private final class Host: UploadTokenHost {
    let uploadTarget: ChatTarget
    var uploadText: String
    var selection: NSRange?

    init(_ target: ChatTarget, text: String, caret: Int) {
        uploadTarget = target; uploadText = text; selection = NSRange(location: caret, length: 0)
    }

    func insert(_ s: String) {
        let at = selection ?? NSRange(location: (uploadText as NSString).length, length: 0)
        uploadText = (uploadText as NSString).replacingCharacters(in: at, with: s)
        selection = NSRange(location: at.location + (s as NSString).length, length: 0)
    }

    func type(_ s: String) { insert(s) }

    func replaceUploadToken(_ token: String, with replacement: String) -> Bool {
        guard let next = ComposerText.replacing(token, with: replacement, in: uploadText, selection: selection) else { return false }
        uploadText = next.text; selection = next.selection
        return true
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
