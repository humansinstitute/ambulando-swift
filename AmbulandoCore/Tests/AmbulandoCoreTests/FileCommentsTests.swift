import Foundation
import Testing
@testable import AmbulandoCore

@Suite("File Comments")
struct FileCommentsTests {
    private func sampleComment(
        id: String,
        versionId: String,
        versionNumber: Int,
        parentId: String? = nil,
        status: String = "open",
        body: String = "Note"
    ) -> FileCommentRecord {
        FileCommentRecord(
            id: id,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            fileId: "22222222-2222-2222-2222-222222222222",
            fileVersionId: versionId,
            fileVersionNumber: versionNumber,
            parentCommentId: parentId,
            body: body,
            commentStatus: status,
            anchor: HTMLCommentAnchor(
                kind: "html_element",
                elementId: "hero",
                selector: "#hero",
                domPath: [0],
                tagName: "h1",
                textQuote: "Headline",
                attrFingerprint: "aria-label=Hero",
                fileVersionId: versionId,
                fileVersionNumber: versionNumber
            ),
            createdByActorId: "33333333-3333-3333-3333-333333333333",
            createdByActorNpub: "npub1reviewer000000000000000000000000000000000000000000000000000",
            updatedByActorId: "33333333-3333-3333-3333-333333333333",
            updatedByActorNpub: "npub1reviewer000000000000000000000000000000000000000000000000000",
            rowVersion: 1,
            createdAt: "2026-11-25T00:00:00Z",
            updatedAt: "2026-11-25T00:00:00Z",
            canEdit: true,
            canResolve: true,
            canDelete: true
        )
    }

    @Test("Version-scoped threads and unresolved earlier carry-over on latest")
    func versionScopedGrouping() {
        let v1 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1"
        let v2 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2"
        let rows = [
            sampleComment(id: "c1", versionId: v1, versionNumber: 1, status: "open", body: "Tighten hero"),
            sampleComment(id: "c1r", versionId: v1, versionNumber: 1, parentId: "c1", body: "On it"),
            sampleComment(id: "c2", versionId: v1, versionNumber: 1, status: "resolved", body: "Done"),
            sampleComment(id: "c3", versionId: v2, versionNumber: 2, status: "open", body: "Check footer"),
        ]
        let onV1 = groupFileCommentThreads(rows, viewedVersionId: v1, isViewingLatest: false)
        #expect(onV1.map(\.root.id) == ["c1", "c2"])
        #expect(onV1[0].replies.count == 1)
        #expect(!onV1[0].fromEarlierVersion)

        let onV2 = groupFileCommentThreads(rows, viewedVersionId: v2, isViewingLatest: true, includeEarlierUnresolved: true)
        #expect(onV2.map(\.root.id) == ["c1", "c3"])
        #expect(onV2[0].fromEarlierVersion)
        #expect(onV2[0].originVersionNumber == 1)
        #expect(!onV2[1].fromEarlierVersion)
    }

    @Test("Draft keys isolate v1 and v2 and persist atomically")
    func draftIsolationAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileCommentDraftStore(url: dir.appendingPathComponent("drafts.json"))
        let anchor = HTMLCommentAnchor(kind: "html_element", elementId: "cta", selector: "#cta", tagName: "button", textQuote: "Start")
        let k1 = anchor.draftKey(versionId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1")
        let k2 = anchor.draftKey(versionId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2")
        #expect(k1 != k2)

        try store.save(FileCommentDraft(key: k1, body: "Fix v1 CTA", clientRequestId: "req-v1", fileVersionId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1", anchor: anchor))
        let loaded = store.loadAll()
        #expect(loaded[k1]?.body == "Fix v1 CTA")
        #expect(loaded[k1]?.clientRequestId == "req-v1")

        try store.remove(k1)
        #expect(store.loadAll().isEmpty)

        // Failed reply submission must retain text and exact clientRequestId until confirmed acceptance removes it.
        let replyKey = "reply:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1"
        let reqId = "req-reply-retry-1"
        try store.save(FileCommentDraft(key: replyKey, body: "Will retry after network error", clientRequestId: reqId, parentCommentId: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1"))
        let retainedAfterFailure = store.loadAll()[replyKey]
        #expect(retainedAfterFailure?.body == "Will retry after network error")
        #expect(retainedAfterFailure?.clientRequestId == reqId)
        try store.remove(replyKey)
        #expect(store.loadAll()[replyKey] == nil)
        try? FileManager.default.removeItem(at: dir)
    }
}
