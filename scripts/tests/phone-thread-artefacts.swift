// Compile with ThreadArtefactState.swift, AmbulandoCore and -D AMBULANDO_PHONE_STATE_CHECK.
// Runs the production phone state branches on the Mac host; this is not an iOS UI test.
import AmbulandoCore
import Foundation
import AppKit

actor AttachmentFixture {
    let workspace = "11111111-0000-4000-8000-000000000001"
    let channel = "22222222-0000-4000-8000-000000000001"
    let thread = "33333333-0000-4000-8000-000000000001"
    var version = 1
    var members: [ThreadArtefactMember]
    var readError = false
    var writes = 0
    init(_ members: [ThreadArtefactMember]) { self.members = members }
    func set(_ members: [ThreadArtefactMember]) { self.members = members; version += 1 }
    func failReads(_ value: Bool) { readError = value }
    func read() throws -> ThreadRecord {
        if readError { throw URLError(.notConnectedToInternet) }
        let metadata = try ThreadArtefactMembership.replacing(Data(#"{"unrelated":true}"#.utf8), with: members)
        return try ThreadRecord(raw: JSONSerialization.data(withJSONObject: ["id": thread, "workspace_id": workspace,
            "channel_id": channel, "row_version": version, "metadata": try JSONSerialization.jsonObject(with: metadata)]))
    }
    func write(_ base: ThreadRecord, _ metadata: Data) throws -> ThreadRecord {
        guard version == base.rowVersion else { throw TowerError.http(status: 409, code: "stale", stage: nil) }
        writes += 1; members = try ThreadArtefactMembership.read(metadata) ?? []; version += 1
        return try read()
    }
    nonisolated var transport: ThreadArtefactMembershipSync.Transport {
        .init(read: { try await self.read() }, write: { try await self.write($0, $1) }, verify: { _ in })
    }
}

@main struct PhoneThreadArtefactsCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let member = try ThreadArtefactMember(kind: "doc", id: "44444444-0000-4000-8000-000000000001")
        let server = AttachmentFixture([member])
        let target = ChatTarget(connectionId: "fixture", workspaceId: "11111111-0000-4000-8000-000000000001",
            channelId: "22222222-0000-4000-8000-000000000001", threadId: "33333333-0000-4000-8000-000000000001")
        let state = MacThreadArtefacts()
        state.transport = server.transport
        await state.refresh()
        precondition(state.members == [member] && state.tabs.isEmpty, "shared membership loads lazily")
        await server.failReads(true)
        let plain = try await state.prepare(target: target)
        precondition(plain == nil, "unopened sources do not block ordinary chat")
        await server.failReads(false)
        state.open(kind: "doc", id: member.id)
        await settle(state)
        let tab = state.tabs[0]
        precondition(state.shown && state.selected == member.id && state.discussionTarget == member.id)
        state.open(kind: "doc", id: member.id)
        await settle(state)
        precondition(state.tabs.count == 1 && state.tabs[0] === tab, "duplicate add retains editor owner")
        var saves = 0
        tab.prepare = {
            saves += 1
            return ArtefactChatReference(kind: "doc", recordID: member.id, revision: "7", historical: true, digest: String(repeating: "a", count: 64))
        }
        tab.validate = { $0.revision == "7" }
        tab.checkpoint = { true }
        state.shown = false
        let data = try await state.prepare(target: target, holdForEnqueue: true)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(state.busy && saves == 1 && json["workspaceVisible"] as? Bool == false)
        precondition(json["visibleRecordID"] as? String == member.id)
        state.open(kind: "file", id: "44444444-0000-4000-8000-000000000002")
        precondition(state.tabs.count == 1, "enqueue hold blocks navigation")
        state.busy = false // durable enqueue acknowledgement releases the interaction hold
        state.discussionTarget = nil; state.discussionExcluded = true
        let excluded = try await state.prepare(target: target, holdForEnqueue: true)
        precondition(excluded == nil && saves == 2 && state.busy, "chip removal omits hidden context but still saves and holds")
        state.busy = false
        state.show(tab)
        precondition(!state.discussionExcluded && state.discussionTarget == tab.id)
        state.shown = false
        tab.prepare = { throw URLError(.notConnectedToInternet) }
        do { _ = try await state.prepare(target: target, holdForEnqueue: true); preconditionFailure("save failure must block") } catch { }
        precondition(!state.busy && state.failure != nil && tab.open)
        var detached = false
        tab.detach = { detached = true }
        await server.set([])
        await state.refresh()
        precondition(detached && !tab.attached && state.selected == nil && state.discussionTarget == nil)
        let removed = try await state.prepare(target: target)
        precondition(removed == nil, "removed record cannot enter future Send")
        let frozen = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(frozen["visibleRecordID"] as? String == member.id, "frozen previous snapshot survives removal")
        await server.set([member])
        await state.refresh()
        precondition(!tab.attached, "remote readd never resumes detached publishing")
        state.open(kind: "doc", id: member.id)
        await settle(state)
        precondition(!tab.attached && state.failure != nil, "explicit readd still requires source recovery review")
        state.close(tab)
        await settle(state)
        precondition(!tab.open && state.selected == nil, "closing recovery never selects a detached Send target")
        tab.checkpoint = { false }
        let checkpointed = await state.checkpointAll()
        precondition(!checkpointed, "failed checkpoint blocks thread dismissal")
        print("PASS: phone production-state checks (host simulation, no iOS UI/device claim)")
    }
    @MainActor static func settle(_ state: MacThreadArtefacts) async {
        for _ in 0..<1000 { if !state.busy { return }; await Task.yield() }
        preconditionFailure("membership operation did not settle")
    }
}
