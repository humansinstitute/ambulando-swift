import Foundation
import Testing
@testable import AmbulandoCore

/// Synthetic-only fixtures & tests for Ambulando Chief of Staff v1 wire contract, provenance/ACL enforcement,
/// durable correction replay, viewer-own DM resolution, private cohort isolation, runtime_binding pipeline
/// reconciliation, and boundary-scoped local cache invalidation.
@Suite struct ChiefOfStaffTests {
    let wsId = "11111111-1111-4111-8111-111111111111"
    let otherWsId = "99999999-9999-4999-8999-999999999999"
    let scopeId = "22222222-2222-4222-8222-222222222222"
    let dmScopeId = "22222222-2222-4222-8222-222222222223"
    let assignChannelId = "33333333-3333-4333-8333-333333333331"
    let assignFileId = "44444444-4444-4444-8444-444444444441"
    let assignVer1 = "55555555-5555-4555-8555-555555555551"
    let assignVer2 = "55555555-5555-4555-8555-555555555552"
    let cohortChannelId = "33333333-3333-4333-8333-333333333339"
    let jobFileId = "44444444-4444-4444-8444-444444444451"
    let ontoFileId = "44444444-4444-4444-8444-444444444452"
    let corrFileId = "44444444-4444-4444-8444-444444444453"
    let subId = "77777777-7777-4777-8777-777777777777"

    let ownerId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
    let memberId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
    let adminGroupId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1"
    let workspaceGroupId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"

    let ownerNpub = TestKeys.npub
    let appNpub = NostrKeys.npub(publicKeyHex: String(repeating: "aa", count: 32))!
    let otherAppNpub = NostrKeys.npub(publicKeyHex: String(repeating: "ab", count: 32))!
    let agentNpub = NostrKeys.npub(publicKeyHex: String(repeating: "11", count: 32))!
    let memberNpub = NostrKeys.npub(publicKeyHex: String(repeating: "22", count: 32))!
    let otherMemberNpub = NostrKeys.npub(publicKeyHex: String(repeating: "33", count: 32))!

    let nowIso = "2026-11-28T00:00:00.000Z"

    private func sampleAssignment(
        rev: Int = 1,
        assignedActorId: String? = nil,
        assignedNpub: String? = nil,
        updatedByActorId: String? = nil,
        updatedByNpub: String? = nil,
        runtimeBinding: ChiefOfStaffRuntimeBinding? = nil
    ) -> ChiefOfStaffAssignment {
        ChiefOfStaffAssignment(
            workspaceId: wsId,
            workspaceOwnerNpub: ownerNpub,
            appNpub: appNpub,
            assignmentRevision: rev,
            assignedActorId: assignedActorId ?? agentId,
            assignedNpub: assignedNpub ?? agentNpub,
            assignedDisplayName: "Synth Agent",
            previousAssignedNpub: nil,
            runtimeBinding: runtimeBinding,
            updatedByActorId: updatedByActorId ?? ownerId,
            updatedByNpub: updatedByNpub ?? ownerNpub,
            updatedAt: nowIso
        )
    }

    @Test func envelopeRejectsUnknownModeAndForbiddenAssignmentFields() throws {
        let assignment = sampleAssignment()
        let encoded = try ChiefOfStaffEnvelope.encode(assignment.toJSONObject())
        let decoded = try ChiefOfStaffEnvelope.decode(encoded)
        let parsed = try ChiefOfStaffAssignment.parse(decoded, expected: ExpectedWorkspaceContext(workspaceId: wsId, ownerNpub: ownerNpub, appNpub: appNpub))
        #expect(parsed == assignment)

        // Unknown encryption mode fails closed
        let encryptedEnv = try rawJSON([
            "envelope_version": 1,
            "encryption": ["mode": "nip44-v2"],
            "payload": assignment.toJSONObject(),
        ])
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffEnvelope.decode(encryptedEnv)
        }

        // Forbidden private fields in shared assignment fail closed
        for forbidden in ChiefOfStaffContract.forbiddenAssignmentFields {
            var bad = assignment.toJSONObject()
            bad[forbidden] = "leak"
            #expect(throws: ChiefOfStaffError.self) {
                _ = try ChiefOfStaffAssignment.parse(bad)
            }
        }
    }

    @Test func boundaryMismatchAndRuntimeBindingValidationFailClosed() throws {
        let assignment = sampleAssignment()
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffAssignment.parse(
                assignment.toJSONObject(),
                expected: ExpectedWorkspaceContext(workspaceId: otherWsId, ownerNpub: ownerNpub, appNpub: appNpub)
            )
        }
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffAssignment.parse(
                assignment.toJSONObject(),
                expected: ExpectedWorkspaceContext(workspaceId: wsId, ownerNpub: memberNpub, appNpub: appNpub)
            )
        }
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffAssignment.parse(
                assignment.toJSONObject(),
                expected: ExpectedWorkspaceContext(workspaceId: wsId, ownerNpub: ownerNpub, appNpub: otherAppNpub)
            )
        }

        // Valid runtime_binding roundtrips cleanly (canonical autopilot_origin + agent_npub + required subscription_id UUID)
        let binding = ChiefOfStaffRuntimeBinding(
            autopilotOrigin: "https://autopilot.example.invalid",
            reconcilePipelineId: "chief-of-staff-reconcile.v1",
            ontologyPipelineId: "chief-of-staff-ontology.v1",
            subscriptionId: subId,
            workspaceId: wsId,
            ownerNpub: ownerNpub,
            agentNpub: agentNpub,
            cronExpression: "0 * * * *",
            timezone: "Australia/Perth"
        )
        let withBinding = sampleAssignment(runtimeBinding: binding)
        let parsed = try ChiefOfStaffAssignment.parse(withBinding.toJSONObject())
        #expect(parsed.runtimeBinding == binding)

        // Secret key, non-https URL, non-root path, wrong workspace, or mismatched agent fails closed
        var badSecret = binding.toJSONObject(); badSecret["token"] = "nope"
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(badSecret, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        var badHttp = binding.toJSONObject(); badHttp["autopilot_origin"] = "http://insecure.example"
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(badHttp, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        var badPath = binding.toJSONObject(); badPath["autopilot_origin"] = "https://autopilot.example.invalid/non-root"
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(badPath, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        var badAgent = binding.toJSONObject(); badAgent["agent_npub"] = memberNpub
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(badAgent, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        var badWs = binding.toJSONObject(); badWs["workspace_id"] = otherWsId
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(badWs, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        // agent_npub and a UUID subscription_id are required; legacy aliases are not accepted.
        var noAgent = binding.toJSONObject(); noAgent["agent_npub"] = nil
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(noAgent, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        for bad in [nil, "not-a-uuid"] as [String?] {
            var badSub = binding.toJSONObject(); badSub["subscription_id"] = bad
            #expect(throws: ChiefOfStaffError.self) {
                _ = try ChiefOfStaffRuntimeBinding.parse(badSub, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
            }
        }
        var legacy = binding.toJSONObject()
        legacy["autopilot_base_url"] = legacy.removeValue(forKey: "autopilot_origin")
        legacy["bot_npub"] = legacy.removeValue(forKey: "agent_npub")
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(legacy, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        for origin in ["https://user:pw@autopilot.example.invalid", "https://autopilot.example.invalid?x=1", "https://autopilot.example.invalid#f"] {
            var bad = binding.toJSONObject(); bad["autopilot_origin"] = origin
            #expect(throws: ChiefOfStaffError.self) {
                _ = try ChiefOfStaffRuntimeBinding.parse(bad, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
            }
        }
        var badPipeline = binding.toJSONObject(); badPipeline["reconcile_pipeline_id"] = "../admin"
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(badPipeline, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        }
        // A binding never survives on an unassigned assignment: it belongs to exactly one agent.
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffRuntimeBinding.parse(binding.toJSONObject(), workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: nil)
        }
        // Optional ontology_pipeline_id may be absent; unknown future fields survive a roundtrip verbatim.
        var future = binding.toJSONObject()
        future["ontology_pipeline_id"] = nil
        future["future_option"] = ["example": true, "nested": [1, "two"]]
        let parsedFuture = try ChiefOfStaffRuntimeBinding.parse(future, workspaceId: wsId, ownerNpub: ownerNpub, assignedNpub: agentNpub)
        #expect(parsedFuture.ontologyPipelineId == nil)
        #expect(NSDictionary(dictionary: parsedFuture.toJSONObject()).isEqual(to: future))
    }

    @Test func effectiveManagerAgentAndForgedNonManagerProvenance() throws {
        let members = [
            ChiefOfStaffAcl.MemberRoleEntry(actorId: ownerId, npub: ownerNpub, role: "owner"),
            // Effective manager agent: role == "agent" with explicit workspace.manage permission
            ChiefOfStaffAcl.MemberRoleEntry(actorId: agentId, npub: agentNpub, role: "agent", permissions: ["workspace.manage"]),
            ChiefOfStaffAcl.MemberRoleEntry(actorId: memberId, npub: memberNpub, role: "member"),
        ]
        let channelRaw = try rawJSON(["id": assignChannelId]) // Live Tower omits created_by_actor_id on channels

        // Valid write by effective-manager agent succeeds
        let agentFileRaw = try rawJSON([
            "id": assignFileId,
            "created_by_actor_id": agentId,
            "updated_by_actor_id": agentId,
        ])
        try ChiefOfStaffAcl.verifyManagerProvenance(
            channelRaw: channelRaw, fileRaw: agentFileRaw, members: members,
            ownerNpub: ownerNpub, payloadUpdatedByActorId: agentId, payloadUpdatedByNpub: agentNpub
        )

        // Forged non-manager file creator fails closed even if payload claims ownerNpub
        let forgedFileRaw = try rawJSON([
            "id": assignFileId,
            "created_by_actor_id": memberId,
            "updated_by_actor_id": memberId,
        ])
        #expect(throws: ChiefOfStaffError.self) {
            try ChiefOfStaffAcl.verifyManagerProvenance(
                channelRaw: channelRaw, fileRaw: forgedFileRaw, members: members,
                ownerNpub: ownerNpub, payloadUpdatedByActorId: ownerId, payloadUpdatedByNpub: ownerNpub
            )
        }

        // Payload author mismatch against server version writer fails closed
        let ownerFileRaw = try rawJSON([
            "id": assignFileId,
            "created_by_actor_id": ownerId,
            "current_version": ["created_by_actor_id": ownerId, "created_by_actor_npub": ownerNpub],
        ])
        #expect(throws: ChiefOfStaffError.self) {
            try ChiefOfStaffAcl.verifyManagerProvenance(
                channelRaw: channelRaw, fileRaw: ownerFileRaw, members: members,
                ownerNpub: ownerNpub, payloadUpdatedByActorId: agentId, payloadUpdatedByNpub: agentNpub
            )
        }
    }

    @Test func managerStatusComesFromOwnerOrServerAuthorityNeverRoleLabels() throws {
        #expect(ChiefOfStaffAcl.MemberRoleEntry(actorId: ownerId, npub: ownerNpub, role: nil).isWorkspaceManager(ownerNpub: ownerNpub))
        #expect(ChiefOfStaffAcl.MemberRoleEntry(actorId: agentId, npub: agentNpub, role: "agent", canManageWorkspace: true).isWorkspaceManager(ownerNpub: ownerNpub))
        for label in ["owner", "admin", "agent", "manager"] {
            #expect(!ChiefOfStaffAcl.MemberRoleEntry(actorId: memberId, npub: memberNpub, role: label).isWorkspaceManager(ownerNpub: ownerNpub))
        }
        // Only a JSON boolean `true` counts; strings, numbers, nested or missing values fail closed.
        #expect(ChiefOfStaffAcl.MemberRoleEntry.strictCanManageWorkspace(["authority": ["can_manage_workspace": true]]))
        for raw: [String: Any] in [
            [:], ["authority": [:]], ["authority": ["can_manage_workspace": false]],
            ["authority": ["can_manage_workspace": "true"]], ["authority": ["can_manage_workspace": 1]],
            ["authority": ["can_manage_workspace": NSNull()]], ["authority": "true"], ["can_manage_workspace": true],
            ["membership": ["authority": ["can_manage_workspace": true]]],
        ] {
            #expect(!ChiefOfStaffAcl.MemberRoleEntry.strictCanManageWorkspace(raw))
        }
    }

    @Test func assignmentGrantsAndPrivateCohortGrantsEnforceStrictAcl() throws {
        let memberRoles = [
            ChiefOfStaffAcl.MemberRoleEntry(actorId: ownerId, npub: ownerNpub, role: "owner"),
            ChiefOfStaffAcl.MemberRoleEntry(actorId: agentId, npub: agentNpub, role: "agent", permissions: ["workspace.manage"]),
            ChiefOfStaffAcl.MemberRoleEntry(actorId: memberId, npub: memberNpub, role: "member"),
        ]
        let groups = [
            ChiefOfStaffAcl.GroupEntry(id: adminGroupId, kind: "system", name: "Admins", effectiveMemberIds: [ownerId, agentId]),
            ChiefOfStaffAcl.GroupEntry(id: workspaceGroupId, kind: "system", name: "Workspace", effectiveMemberIds: [ownerId, agentId, memberId]),
        ]
        let validAssignGrants: [[String: Any]] = [
            ["principal_type": "group", "principal_id": adminGroupId, "permissions": ["channel.read", "file.read", "file.write", "channel.manage"]],
            ["principal_type": "group", "principal_id": workspaceGroupId, "permissions": ["channel.read", "file.read"]],
        ]
        let res = try ChiefOfStaffAcl.verifyAssignmentChannelGrants(grants: validAssignGrants, members: memberRoles, groups: groups, ownerNpub: ownerNpub)
        #expect(res.hasManagerWriter && res.hasWorkspaceReader)

        // Workspace group with file.write fails closed
        let unsafeAssignGrants: [[String: Any]] = [
            ["principal_type": "group", "principal_id": adminGroupId, "permissions": ["channel.read", "file.read", "file.write"]],
            ["principal_type": "group", "principal_id": workspaceGroupId, "permissions": ["channel.read", "file.read", "file.write"]],
        ]
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffAcl.verifyAssignmentChannelGrants(grants: unsafeAssignGrants, members: memberRoles, groups: groups, ownerNpub: ownerNpub)
        }

        // Strict 2-actor private cohort grants
        let members = [
            MemberRecord(workspaceId: wsId, actorId: ownerId, npub: ownerNpub, kind: "person", displayName: "Owner"),
            MemberRecord(workspaceId: wsId, actorId: agentId, npub: agentNpub, kind: "agent", displayName: "Agent"),
            MemberRecord(workspaceId: wsId, actorId: memberId, npub: memberNpub, kind: "person", displayName: "Member"),
        ]
        let ownerGrant: [String: Any] = [
            "principal_type": "person", "stored_principal_type": "actor", "principal_id": ownerId,
            "principal": ["type": "person", "actor_id": ownerId, "npub": ownerNpub],
            "permissions": ["channel.read", "file.read", "file.write", "channel.manage", "channel.grants.manage"],
        ]
        let agentGrant: [String: Any] = [
            "principal_type": "actor", "principal_id": agentId,
            "principal": ["type": "actor", "actor_id": agentId, "npub": agentNpub],
            "permissions": ["channel.read", "file.read", "file.write"],
        ]
        let pair = try ChiefOfStaffAcl.verifyCohortChannelGrants(grants: [ownerGrant, agentGrant], members: members, ownerNpub: ownerNpub, agentNpub: agentNpub)
        #expect(pair.ownerId == ownerId && pair.agentId == agentId)

        // Adding a 3rd actor or a group grant fails closed
        let extraGrant: [String: Any] = [
            "principal_type": "actor", "principal_id": memberId,
            "principal": ["type": "actor", "actor_id": memberId, "npub": memberNpub],
            "permissions": ["channel.read", "file.read", "file.write"],
        ]
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffAcl.verifyCohortChannelGrants(grants: [ownerGrant, agentGrant, extraGrant], members: members, ownerNpub: ownerNpub, agentNpub: agentNpub)
        }
        let groupGrant: [String: Any] = [
            "principal_type": "group", "principal_id": workspaceGroupId,
            "permissions": ["channel.read", "file.read", "file.write"],
        ]
        #expect(throws: ChiefOfStaffError.self) {
            _ = try ChiefOfStaffAcl.verifyCohortChannelGrants(grants: [ownerGrant, agentGrant, groupGrant], members: members, ownerNpub: ownerNpub, agentNpub: agentNpub)
        }
    }

    @Test func durableCorrectionsReplayAndSearch() throws {
        let evId1 = "66666666-6666-4666-8666-666666666661"
        let evId2 = "66666666-6666-4666-8666-666666666662"
        let topics = [
            ChiefOfStaffTopic(id: "topic_a", name: "Alpha Project", kind: "project", aliases: ["Alpha"]),
            ChiefOfStaffTopic(id: "topic_b", name: "Beta Initiative", kind: "project"),
            ChiefOfStaffTopic(id: "topic_c", name: "Legacy Topic", kind: "area"),
        ]
        let evidence = [
            ChiefOfStaffEvidence(id: "e1", topicId: "topic_a", sourceType: "task", recordId: evId1, sourceTitle: "Ship v1", explanation: "Core milestone", score: 0.7),
            ChiefOfStaffEvidence(id: "e2", topicId: "topic_b", sourceType: "doc", recordId: evId2, sourceTitle: "Spec doc", explanation: "Design notes", score: 0.6),
            ChiefOfStaffEvidence(id: "e3", topicId: "topic_a", sourceType: "doc", recordId: evId2, sourceTitle: "Spec doc", explanation: "Wrong link", score: 0.5),
        ]
        let corrections = [
            ChiefOfStaffCorrection(id: "c1", kind: "rename", createdByNpub: ownerNpub, createdAt: "2026-11-28T00:01:00Z", topicId: "topic_a", name: "Project Atlas"),
            ChiefOfStaffCorrection(id: "c2", kind: "merge_topics", createdByNpub: ownerNpub, createdAt: "2026-11-28T00:02:00Z", sourceTopicId: "topic_b", targetTopicId: "topic_a"),
            ChiefOfStaffCorrection(id: "c3", kind: "pin_evidence", createdByNpub: ownerNpub, createdAt: "2026-11-28T00:03:00Z", topicId: "topic_a", sourceType: "task", recordId: evId1),
            ChiefOfStaffCorrection(id: "c4", kind: "reject_evidence", createdByNpub: ownerNpub, createdAt: "2026-11-28T00:04:00Z", topicId: "topic_b", sourceType: "doc", recordId: evId2),
            ChiefOfStaffCorrection(id: "c5", kind: "archive_topic", createdByNpub: ownerNpub, createdAt: "2026-11-28T00:05:00Z", topicId: "topic_c", archived: true),
        ]
        let applied = ChiefOfStaffOntologyLogic.applyCorrections(discoveredTopics: topics, discoveredEvidence: evidence, corrections: corrections)
        #expect(applied.topics.count == 2)
        let atlas = try #require(applied.topics.first { $0.id == "topic_a" })
        #expect(atlas.name == "Project Atlas")
        #expect(atlas.aliases.contains("Alpha Project"))
        #expect(atlas.aliases.contains("Beta Initiative"))
        #expect(atlas.sourceOrigin == "corrected")
        #expect(applied.evidence.count == 1)
        #expect(applied.evidence[0].recordId == evId1)
        #expect(applied.evidence[0].pinned == true)
        #expect(applied.evidence[0].score >= 0.99)

        // Search excludes archived by default, matches aliases
        #expect(ChiefOfStaffOntologyLogic.searchTopics(topics: applied.topics, evidence: applied.evidence, query: "Beta").map(\.id) == ["topic_a"])
        #expect(ChiefOfStaffOntologyLogic.searchTopics(topics: applied.topics, evidence: applied.evidence, query: "Legacy").isEmpty)
        #expect(ChiefOfStaffOntologyLogic.searchTopics(topics: applied.topics, evidence: applied.evidence, query: "Legacy", includeArchived: true).map(\.id) == ["topic_c"])
    }

    @Test func viewerOwnDirectMessageResolutionNeverLeaksOtherDMs() throws {
        let dmScope = ScopeRecord(workspaceId: wsId, id: dmScopeId, name: "Direct Messages", kind: "dm", updatedAt: nowIso,
                                  raw: try rawJSON(["id": dmScopeId, "workspace_id": wsId, "name": "Direct Messages", "kind": "dm"]))
        let workScope = ScopeRecord(workspaceId: wsId, id: scopeId, name: "Work", kind: "scope", updatedAt: nowIso,
                                    raw: try rawJSON(["id": scopeId, "workspace_id": wsId, "name": "Work", "kind": "scope"]))

        func dmChannel(_ id: String, scope: String, participants: [String], archived: Bool = false) throws -> ChannelRecord {
            var rawObj: [String: Any] = [
                "id": id, "workspace_id": wsId, "scope_id": scope, "name": "DM",
                "kind": "dm", "participant_npubs": participants,
            ]
            if archived { rawObj["archived_at"] = nowIso }
            return ChannelRecord(workspaceId: wsId, id: id, scopeId: scope, name: "DM", kind: "dm", updatedAt: nowIso, raw: try rawJSON(rawObj))
        }

        let otherUserDm = try dmChannel("c0000000-0000-4000-8000-000000000001", scope: dmScopeId, participants: [otherMemberNpub, agentNpub])
        let selfDm = try dmChannel("c0000000-0000-4000-8000-000000000002", scope: dmScopeId, participants: [memberNpub])
        let groupDm = try dmChannel("c0000000-0000-4000-8000-000000000003", scope: dmScopeId, participants: [memberNpub, agentNpub, otherMemberNpub])
        let archivedDm = try dmChannel("c0000000-0000-4000-8000-000000000004", scope: dmScopeId, participants: [memberNpub, agentNpub], archived: true)
        let wrongScopeDm = try dmChannel("c0000000-0000-4000-8000-000000000005", scope: scopeId, participants: [memberNpub, agentNpub])
        let viewerOwnDm = try dmChannel("c0000000-0000-4000-8000-000000000006", scope: dmScopeId, participants: [memberNpub, agentNpub])

        // Without viewerOwnDm, must return nil (never another user's DM, self-DM, group DM, archived, or non-DM scope)
        let none = ChiefOfStaffOntologyLogic.findViewerDirectMessage(
            scopes: [dmScope, workScope],
            channels: [otherUserDm, selfDm, groupDm, archivedDm, wrongScopeDm],
            viewerNpub: memberNpub,
            agentNpub: agentNpub
        )
        #expect(none == nil)

        // With viewerOwnDm present, returns exact match
        let found = ChiefOfStaffOntologyLogic.findViewerDirectMessage(
            scopes: [dmScope, workScope],
            channels: [otherUserDm, selfDm, groupDm, archivedDm, wrongScopeDm, viewerOwnDm],
            viewerNpub: memberNpub,
            agentNpub: agentNpub
        )
        #expect(found?.id == viewerOwnDm.id)
    }

    @Test func normalMemberReadsWithoutAdminEndpointsAndCohortDeniesUnauthorizedViewer() async throws {
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try await makeIdentity(directory: dir)
        let assignment = sampleAssignment()
        let assignmentBytes = try ChiefOfStaffEnvelope.encode(assignment.toJSONObject())
        let sha = SHA256Hex.of(assignmentBytes)

        let transport = StubTransport { request in
            let path = request.url!.path
            // Ordinary members receive 403 on /groups and /grants; must NEVER be required
            if path.hasSuffix("/groups") || path.hasSuffix("/grants") {
                return (403, ["code": "forbidden"])
            }
            if path.hasSuffix("/members") {
                // Live Tower strips membership for non-managers, returning {actor} only
                return (200, ["members": [
                    ["actor": ["actor_id": self.ownerId, "npub": self.ownerNpub, "kind": "person", "display_name": "Owner"]],
                    ["actor": ["actor_id": self.agentId, "npub": self.agentNpub, "kind": "agent", "display_name": "Synth Agent"]],
                    ["actor": ["actor_id": self.memberId, "npub": self.memberNpub, "kind": "person", "display_name": "Member"]],
                ]])
            }
            if path.hasSuffix("/scopes") {
                return (200, ["scopes": [["id": self.scopeId, "workspace_id": self.wsId, "name": "Work", "kind": "scope"]]])
            }
            if path.hasSuffix("/scopes/\(self.scopeId)/channels") {
                return (200, ["channels": [[
                    "id": self.assignChannelId, "workspace_id": self.wsId, "scope_id": self.scopeId,
                    "name": "Chief of Staff", "kind": "channel",
                    "metadata": ChiefOfStaffContract.assignmentChannelMetadata(workspaceId: self.wsId, appNpub: self.appNpub),
                ]]])
            }
            if path.hasSuffix("/channels/\(self.assignChannelId)/files") {
                return (200, ["files": [[
                    "id": self.assignFileId, "workspace_id": self.wsId, "channel_id": self.assignChannelId,
                    "display_name": ChiefOfStaffContract.fileNameAssignment,
                    "content_type": ChiefOfStaffContract.mimeAssignment,
                    "metadata": ChiefOfStaffContract.assignmentFileMetadata(workspaceId: self.wsId, appNpub: self.appNpub),
                ]]])
            }
            if path.hasSuffix("/files/\(self.assignFileId)") {
                return (200, ["file": [
                    "id": self.assignFileId, "workspace_id": self.wsId, "channel_id": self.assignChannelId,
                    "display_name": ChiefOfStaffContract.fileNameAssignment,
                    "content_type": ChiefOfStaffContract.mimeAssignment,
                    "created_by_actor_id": self.ownerId,
                    "updated_by_actor_id": self.ownerId,
                    "current_version_id": self.assignVer1,
                    "metadata": ChiefOfStaffContract.assignmentFileMetadata(workspaceId: self.wsId, appNpub: self.appNpub),
                    "object": ["storage_object": ["sha256_hex": sha, "size_bytes": assignmentBytes.count, "is_public": false]],
                ]])
            }
            if path.hasSuffix("/files/\(self.assignFileId)/versions/\(self.assignVer1)/object") {
                return (200, assignmentBytes)
            }
            return (404, [:])
        }

        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
        let memberService = ChiefOfStaffService(api: api, workspace: wsId, ownerNpub: ownerNpub, appNpub: appNpub, viewerNpub: memberNpub)

        let loaded = try await memberService.readAssignment(verifyAcl: false)
        guard case .ready(let ch, let file, let ver, let got) = loaded else {
            Issue.record("Expected ready assignment for ordinary member"); return
        }
        #expect(ch.id == assignChannelId && file.id == assignFileId && ver == assignVer1 && got == assignment)
        #expect(!transport.recorded.contains { $0.url!.path.hasSuffix("/groups") || $0.url!.path.hasSuffix("/grants") })

        // Unauthorized ordinary member reading private cohort gets .restricted with ZERO additional network calls
        let beforeCount = transport.recorded.count
        let cohort = try await memberService.readCohort(agentNpub: agentNpub, assignmentEpoch: 1)
        #expect(cohort == .restricted)
        #expect(transport.recorded.count == beforeCount)
    }

    @Test func ordinaryMemberVerifiesDelegatedAgentManagerViaAuthorityCanManageWorkspace() async throws {
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try await makeIdentity(directory: dir)
        let assignment = sampleAssignment(updatedByActorId: agentId, updatedByNpub: agentNpub)
        let assignmentBytes = try ChiefOfStaffEnvelope.encode(assignment.toJSONObject())
        let sha = SHA256Hex.of(assignmentBytes)

        func makeService(agentCanManage: Any?) -> ChiefOfStaffService {
            nonisolated(unsafe) let agentCanManage = agentCanManage
            let transport = StubTransport { request in
                let path = request.url!.path
                if path.hasSuffix("/groups") || path.hasSuffix("/grants") { return (403, ["code": "forbidden"]) }
                if path.hasSuffix("/members") {
                    var agentEntry: [String: Any] = [
                        "actor": ["actor_id": self.agentId, "npub": self.agentNpub, "kind": "agent", "display_name": "Agent Manager"],
                    ]
                    if let flag = agentCanManage {
                        agentEntry["authority"] = ["can_manage_workspace": flag]
                    }
                    // No `membership` object for ordinary readers — only `actor` + `authority`
                    return (200, ["members": [
                        ["actor": ["actor_id": self.ownerId, "npub": self.ownerNpub, "kind": "person"], "authority": ["can_manage_workspace": true]],
                        agentEntry,
                        ["actor": ["actor_id": self.memberId, "npub": self.memberNpub, "kind": "person"], "authority": ["can_manage_workspace": false]],
                    ]])
                }
                if path.hasSuffix("/scopes") {
                    return (200, ["scopes": [["id": self.scopeId, "workspace_id": self.wsId, "name": "Work", "kind": "scope"]]])
                }
                if path.hasSuffix("/scopes/\(self.scopeId)/channels") {
                    return (200, ["channels": [[
                        "id": self.assignChannelId, "workspace_id": self.wsId, "scope_id": self.scopeId,
                        "name": "Chief of Staff", "kind": "channel",
                        "metadata": ChiefOfStaffContract.assignmentChannelMetadata(workspaceId: self.wsId, appNpub: self.appNpub),
                    ]]])
                }
                if path.hasSuffix("/channels/\(self.assignChannelId)/files") {
                    return (200, ["files": [[
                        "id": self.assignFileId, "workspace_id": self.wsId, "channel_id": self.assignChannelId,
                        "display_name": ChiefOfStaffContract.fileNameAssignment,
                        "content_type": ChiefOfStaffContract.mimeAssignment,
                        "metadata": ChiefOfStaffContract.assignmentFileMetadata(workspaceId: self.wsId, appNpub: self.appNpub),
                    ]]])
                }
                if path.hasSuffix("/files/\(self.assignFileId)") {
                    return (200, ["file": [
                        "id": self.assignFileId, "workspace_id": self.wsId, "channel_id": self.assignChannelId,
                        "display_name": ChiefOfStaffContract.fileNameAssignment,
                        "content_type": ChiefOfStaffContract.mimeAssignment,
                        "created_by_actor_id": self.agentId,
                        "updated_by_actor_id": self.agentId,
                        "current_version_id": self.assignVer1,
                        "metadata": ChiefOfStaffContract.assignmentFileMetadata(workspaceId: self.wsId, appNpub: self.appNpub),
                        "object": ["storage_object": ["sha256_hex": sha, "size_bytes": assignmentBytes.count, "is_public": false]],
                    ]])
                }
                if path.hasSuffix("/files/\(self.assignFileId)/versions/\(self.assignVer1)/object") {
                    return (200, assignmentBytes)
                }
                return (404, [:])
            }
            let api = TowerAPI(client: TowerClient(origin: try! TowerOrigin("https://tower.example"), transport: transport, signer: identity))
            return ChiefOfStaffService(api: api, workspace: wsId, ownerNpub: ownerNpub, appNpub: appNpub, viewerNpub: memberNpub)
        }

        // authority.can_manage_workspace == true succeeds without membership/groups/grants
        let allowed = try await makeService(agentCanManage: true).readAssignment(verifyAcl: false)
        guard case .ready(_, _, _, let parsed) = allowed else {
            Issue.record("Expected delegated agent-manager assignment to verify"); return
        }
        #expect(parsed.updatedByActorId == agentId && parsed.updatedByNpub == agentNpub)

        // authority.can_manage_workspace == false or omitted fails closed
        await #expect(throws: ChiefOfStaffError.self) {
            _ = try await makeService(agentCanManage: false).readAssignment(verifyAcl: false)
        }
        await #expect(throws: ChiefOfStaffError.self) {
            _ = try await makeService(agentCanManage: nil).readAssignment(verifyAcl: false)
        }
        for spoof: Any in ["true", 1] {
            await #expect(throws: ChiefOfStaffError.self) {
                _ = try await makeService(agentCanManage: spoof).readAssignment(verifyAcl: false)
            }
        }
    }

    @Test func runtimeBindingReconcilesViaGenericPipelineRunAPI() async throws {
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try await makeIdentity(directory: dir)
        let binding = ChiefOfStaffRuntimeBinding(
            autopilotOrigin: "https://autopilot.example.invalid",
            reconcilePipelineId: "chief-of-staff-reconcile.v1",
            subscriptionId: subId,
            workspaceId: wsId,
            ownerNpub: ownerNpub,
            agentNpub: agentNpub,
            cronExpression: "0 * * * *",
            timezone: "Australia/Perth"
        )
        let assignment = sampleAssignment(rev: 2, runtimeBinding: binding)

        func outcome(_ status: Int, _ reply: Any, for a: ChiefOfStaffAssignment? = nil, binding b: ChiefOfStaffRuntimeBinding? = nil)
            async throws -> (ChiefOfStaffScheduleReconciliationResult, [URLRequest]) {
            let reply = try JSONSerialization.data(withJSONObject: reply)
            let transport = StubTransport { request in
                let url = request.url!
                guard url.host == "autopilot.example.invalid", url.path == "/api/pipelines/definitions/chief-of-staff-reconcile.v1/runs" else {
                    return (500, [:])
                }
                return (status, reply)
            }
            let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
            let service = ChiefOfStaffService(api: api, workspace: wsId, ownerNpub: ownerNpub, appNpub: appNpub, viewerNpub: ownerNpub)
            return (try await service.reconcileViaRuntimeBinding(b ?? binding, assignment: a ?? assignment), transport.recorded)
        }

        let (accepted, requests) = try await outcome(202, ["runId": "run-123", "status": "running", "terminal": false, "timedOut": true])
        #expect(accepted == .accepted(runId: "run-123", state: "running"))
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true)
        #expect(request.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub") == nil)
        #expect(request.value(forHTTPHeaderField: "X-App-Npub") == nil)
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
        #expect(body["mode"] as? String == "wait")
        #expect(body["waitSeconds"] as? Int == 20)
        #expect(body["idempotencyKey"] as? String == "chief-of-staff:reconcile:\(wsId):rev:2:\(agentNpub)")
        let input = try #require(body["input"] as? [String: Any])
        #expect(Set(input.keys) == ["workspace_id", "workspace_owner_npub", "app_npub", "assigned_agent_npub", "assignment_revision",
                                    "assignment_epoch", "tower_url", "subscription_id", "cron_expression", "timezone"])
        #expect(input["workspace_id"] as? String == wsId)
        #expect(input["workspace_owner_npub"] as? String == ownerNpub)
        #expect(input["app_npub"] as? String == appNpub)
        #expect(input["assigned_agent_npub"] as? String == agentNpub)
        #expect(input["subscription_id"] as? String == subId)
        #expect(input["assignment_revision"] as? Int == 2)
        #expect(input["tower_url"] as? String == "https://tower.example")

        // 200 RunEnvelope: the engine's schedule_state decides, never the HTTP status alone.
        func envelope(_ status: String, _ reconciled: [String: Any]? = nil) -> [String: Any] {
            var o: [String: Any] = ["runId": "run-1", "status": status, "terminal": true]
            if let reconciled { o["result"] = ["reconciled": reconciled] }
            return o
        }
        #expect(try await outcome(200, envelope("ok", ["schedule_state": "scheduled", "autopilot_job_id": "job-1"])).0
                == .reconciled(jobId: "job-1", state: "scheduled"))
        var replayed = envelope("ok", ["schedule_state": "scheduled", "autopilot_job_id": "job-1"]); replayed["replayed"] = true
        #expect(try await outcome(200, replayed).0 == .reconciled(jobId: "job-1", state: "scheduled"))
        #expect(try await outcome(200, envelope("ok", ["schedule_state": "pending", "last_error": "No subscription"])).0
                == .unavailable(reason: "No subscription"))
        for (status, reply) in [
            (200, envelope("ok", ["schedule_state": "error", "last_error": "boom"])), (200, envelope("ok")), (200, envelope("ok", ["schedule_state": "bogus"])),
            (200, envelope("error")), (200, envelope("needs_input")), (200, envelope("cancelled")), (200, [:]),
            (302, [:]), (404, [:]), (403, ["code": "forbidden"]), (409, ["code": "idempotency_conflict"]), (500, [:]),
        ] as [(Int, [String: Any])] {
            guard case .failed = try await outcome(status, reply).0 else { Issue.record("HTTP \(status) \(reply) must fail honestly"); continue }
        }

        // Setup never serves another agent: zero requests.
        let otherAgent = sampleAssignment(rev: 3, assignedActorId: memberId, assignedNpub: memberNpub)
        let (mismatch, none) = try await outcome(200, [:], for: otherAgent)
        guard case .failed = mismatch else { Issue.record("Binding must not serve another agent"); return }
        #expect(none.isEmpty)

        // Cancellation propagates instead of being reported as a failed setup.
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await outcome(202, [:])
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    }

    @Test func setAssignmentUsesOnlyTheAgentsOwnBindingAndCASGuardsWrites() async throws {
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try await makeIdentity(directory: dir)
        let agentBId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4"
        let binding = ChiefOfStaffRuntimeBinding(
            autopilotOrigin: "https://autopilot.example.invalid", ontologyPipelineId: "chief-of-staff-ontology.v1",
            subscriptionId: subId, workspaceId: wsId, ownerNpub: ownerNpub, agentNpub: agentNpub,
            preserved: ChiefOfStaffPreservedFields(object: ["future_option": ["example": true]])
        )
        var seedObject = sampleAssignment(rev: 1, runtimeBinding: binding).toJSONObject()
        seedObject["future_top_level"] = ["kept": 1]
        let seed = try ChiefOfStaffEnvelope.encode(seedObject)

        func run(agent: String?, expectedRevision: Int? = 1,
                 autopilot: (Int, Any) = (200, ["runId": "run-9", "status": "ok", "terminal": true,
                                                "result": ["reconciled": ["schedule_state": "disabled_stale"]]]),
                 staleWrite: Bool = false) async throws -> (FakeChiefNStack, Result<ChiefOfStaffScheduleReconciliationResult, Error>) {
            let fake = FakeChiefNStack(test: self, agentBId: agentBId, seed: seed, autopilot: autopilot, staleWrite: staleWrite)
            let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport(fake.handle), signer: identity))
            let service = ChiefOfStaffService(api: api, workspace: wsId, ownerNpub: ownerNpub, appNpub: appNpub, viewerNpub: ownerNpub)
            do {
                let saved = try await service.setAssignment(agentNpub: agent, expectedRevision: expectedRevision)
                return (fake, .success(saved.reconciliation))
            } catch {
                return (fake, .failure(error))
            }
        }

        // Change to another agent: saved without the old binding; the old binding only requests cleanup, without its
        // subscription, so no job can be created for the new agent; the new agent stays honestly pending.
        let (changed, changeResult) = try await run(agent: otherMemberNpub)
        guard case .success(.unavailable) = changeResult else { Issue.record("Expected pending after change: \(changeResult)"); return }
        let changeInput = try #require(changed.autopilotInputs.first)
        #expect(changed.autopilotRequests.count == 1)
        #expect(changeInput["subscription_id"] == nil)
        #expect(changeInput["assigned_agent_npub"] as? String == otherMemberNpub)
        let changedDoc = try ChiefOfStaffAssignment.parse(try ChiefOfStaffEnvelope.decode(try #require(changed.currentBytes)))
        #expect(changedDoc.assignmentRevision == 2 && changedDoc.assignedNpub == otherMemberNpub && changedDoc.assignedActorId == agentBId)
        #expect(changedDoc.previousAssignedNpub == agentNpub)
        #expect(changedDoc.runtimeBinding == nil)
        #expect(NSDictionary(dictionary: changedDoc.preserved.object).isEqual(to: ["future_top_level": ["kept": 1]]))

        // Same agent re-saved: its own binding (with unknown fields) is kept and setup is attempted for real.
        let (same, sameResult) = try await run(agent: agentNpub, autopilot: (202, ["runId": "run-7", "status": "running", "terminal": false]))
        #expect(try sameResult.get() == .accepted(runId: "run-7", state: "running"))
        #expect(same.autopilotRequests.count == 1)
        let sameDoc = try ChiefOfStaffAssignment.parse(try ChiefOfStaffEnvelope.decode(try #require(same.currentBytes)))
        #expect(sameDoc.runtimeBinding == binding)
        let sameInput = try #require(same.autopilotInputs.first)
        #expect(sameInput["assigned_agent_npub"] as? String == agentNpub && sameInput["subscription_id"] as? String == subId)

        // Removal: the prior binding only requests stale-schedule cleanup for an unassigned workspace.
        let (removed, removeResult) = try await run(agent: nil)
        #expect(try removeResult.get() == .reconciled(jobId: "run-9", state: "disabled_stale"))
        let removeInput = try #require(removed.autopilotInputs.first)
        #expect(removeInput["assigned_agent_npub"] is NSNull)
        #expect(removeInput["subscription_id"] == nil)

        // A failed cleanup after a change is reported as an error, not as pending.
        let (_, failedCleanup) = try await run(agent: otherMemberNpub, autopilot: (500, [:]))
        guard case .success(.failed) = failedCleanup else { Issue.record("Expected failed cleanup: \(failedCleanup)"); return }
        let removedDoc = try ChiefOfStaffAssignment.parse(try ChiefOfStaffEnvelope.decode(try #require(removed.currentBytes)))
        #expect(removedDoc.assignedNpub == nil && removedDoc.runtimeBinding == nil)

        // CAS: a concurrent version makes the write 409; nothing is reconciled.
        let (stale, staleResult) = try await run(agent: agentNpub, staleWrite: true)
        guard case .failure(ChiefOfStaffError.conflict) = staleResult else { Issue.record("Expected CAS conflict: \(staleResult)"); return }
        #expect(stale.autopilotRequests.isEmpty)

        // A stale UI revision is refused before any write.
        let (outdated, outdatedResult) = try await run(agent: agentNpub, expectedRevision: 0)
        guard case .failure(ChiefOfStaffError.conflict) = outdatedResult else { Issue.record("Expected revision conflict"); return }
        #expect(outdated.versionWrites == 0 && outdated.autopilotRequests.isEmpty)
    }

    @Test func boundaryScopedCacheClearsOnLockAndInvalidation() async throws {
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try await makeIdentity(directory: dir.appendingPathComponent("identity"))
        let store = try LocalStore(directory: dir.appendingPathComponent("store"))
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: ownerNpub, towerNpub: ownerNpub)
        let workspace = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(wsId, label: "Synth")))
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { _ in (404, [:]) }, signer: identity))
        var service = ChiefOfStaffService(api: api, workspace: wsId, ownerNpub: ownerNpub, appNpub: appNpub, viewerNpub: ownerNpub)
        service.cache = LocalContentSnapshot(store: store, identity: identity, boundary: boundary)

        let cached = CachedChiefOfStaffAssignment(assignment: sampleAssignment(), canonicalChannelId: assignChannelId, canonicalFileId: assignFileId)
        await service.saveCachedAssignment(cached, dependencies: [assignChannelId, assignFileId])
        #expect(await service.cachedAssignment() == cached)

        // Locking identity hides cached assignment immediately
        await identity.lock()
        #expect(await service.cachedAssignment() == nil)
        _ = try await identity.unlock(pin: TestKeys.pin)
        #expect(await service.cachedAssignment() == cached)

        // Explicit local access-loss / file removal invalidation clears cache
        try await store.writer.invalidateLocalContent(workspace: wsId, record: assignFileId)
        #expect(await service.cachedAssignment() == nil)
    }

    @Test func jobStatusParsesAllSupportedScheduleStates() throws {
        for state in ChiefOfStaffContract.scheduleStates {
            let doc: [String: Any] = [
                "schema": ChiefOfStaffContract.schemaJobStatus,
                "schema_version": 1,
                "workspace_id": wsId,
                "workspace_owner_npub": ownerNpub,
                "app_npub": appNpub,
                "cohort_id": ChiefOfStaffContract.cohortId(ownerNpub: ownerNpub, agentNpub: agentNpub, assignmentEpoch: 1),
                "assignment_epoch": 1,
                "bound_agent_npub": agentNpub,
                "assignment_revision_seen": 1,
                "schedule_state": state,
                "topic_count": 3,
                "evidence_count": 7,
                "updated_at": nowIso,
            ]
            let parsed = try ChiefOfStaffJobStatus.parse(doc, expected: ExpectedWorkspaceContext(workspaceId: wsId, ownerNpub: ownerNpub, appNpub: appNpub))
            #expect(parsed.scheduleState == state)
            #expect(parsed.topicCount == 3 && parsed.evidenceCount == 7)
        }
    }

    /// The exact plaintext-envelope fixture shared with the Android/engine implementation
    /// (`scripts/chief-of-staff/fixtures/assignment-runtime-binding.v1.json` there). Synthetic identities only.
    @Test func sharedRuntimeBindingFixtureRoundtripsExactly() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/chief-of-staff-assignment-runtime-binding.v1.json")
        let bytes = try Data(contentsOf: url)
        let original = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let payload = try ChiefOfStaffEnvelope.decode(bytes)
        let parsed = try ChiefOfStaffAssignment.parse(payload, expected: ExpectedWorkspaceContext(
            workspaceId: "11111111-1111-4111-8111-111111111111",
            ownerNpub: try #require(payload["workspace_owner_npub"] as? String),
            appNpub: try #require(payload["app_npub"] as? String)
        ))
        #expect(parsed.assignmentRevision == 7)
        let rb = try #require(parsed.runtimeBinding)
        #expect(rb.autopilotOrigin == "https://autopilot.example.invalid")
        #expect(rb.reconcilePipelineId == "chief-of-staff-reconcile.v1")
        #expect(rb.ontologyPipelineId == "chief-of-staff-ontology.v1")
        #expect(rb.ownerNpub == parsed.workspaceOwnerNpub && rb.workspaceId == parsed.workspaceId)
        #expect(rb.agentNpub == parsed.assignedNpub)
        #expect(rb.subscriptionId == "44444444-4444-4444-8444-444444444444")
        #expect(NSDictionary(dictionary: rb.preserved.object).isEqual(to: ["future_option": ["example": true]]))

        // decode → parse → encode → decode yields the identical envelope, unknown fields included.
        let reencoded = try ChiefOfStaffEnvelope.encode(parsed.toJSONObject())
        let roundtripped = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(NSDictionary(dictionary: roundtripped).isEqual(to: original))
        #expect(try ChiefOfStaffAssignment.parse(try ChiefOfStaffEnvelope.decode(reencoded)) == parsed)
    }
}

/// Stateful synthetic NStack + Autopilot for `setAssignment`: owner-manager directory, verified Admins/Workspace
/// grants, storage prepare/upload/complete, `base_version_id` CAS and the pipeline run route.
private final class FakeChiefNStack: @unchecked Sendable {
    private let lock = NSLock()
    private let t: ChiefOfStaffTests
    private let agentBId: String
    private let autopilot: (Int, Any)
    private let staleWrite: Bool
    private var versions: [String: Data]
    private var currentVersion: String
    private var objects: [String: Data] = [:]
    private var completed: Set<String> = []
    private(set) var autopilotRequests: [URLRequest] = []
    private(set) var versionWrites = 0

    init(test: ChiefOfStaffTests, agentBId: String, seed: Data, autopilot: (Int, Any), staleWrite: Bool) {
        t = test; self.agentBId = agentBId; self.autopilot = autopilot; self.staleWrite = staleWrite
        currentVersion = test.assignVer1
        versions = [test.assignVer1: seed]
    }

    var currentBytes: Data? { lock.withLock { versions[currentVersion] } }
    var autopilotInputs: [[String: Any]] {
        lock.withLock { autopilotRequests }.compactMap {
            ((try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data())) as? [String: Any])?["input"] as? [String: Any]
        }
    }

    func handle(_ request: URLRequest) throws -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        let url = request.url!, path = url.path, method = request.httpMethod ?? "GET"
        if url.host == "autopilot.example.invalid" {
            autopilotRequests.append(request)
            return autopilot
        }
        let groupAdmins = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1", groupWorkspace = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
        if path.hasSuffix("/me") {
            return (200, ["identity": ["workspace_id": t.wsId, "workspace_owner_npub": t.ownerNpub, "app_npub": t.appNpub],
                          "actor": ["actor_id": t.ownerId, "npub": t.ownerNpub], "permissions": [String]()])
        }
        if path.hasSuffix("/members") {
            return (200, ["members": [
                ["actor": ["actor_id": t.ownerId, "npub": t.ownerNpub, "kind": "person", "display_name": "Owner"]],
                ["actor": ["actor_id": t.agentId, "npub": t.agentNpub, "kind": "agent", "display_name": "Agent A"]],
                ["actor": ["actor_id": agentBId, "npub": t.otherMemberNpub, "kind": "agent", "display_name": "Agent B"]],
                ["actor": ["actor_id": t.memberId, "npub": t.memberNpub, "kind": "person", "display_name": "Member"]],
            ]])
        }
        if path.hasSuffix("/groups") {
            return (200, ["groups": [
                ["id": groupAdmins, "kind": "system", "name": "Admins", "effective_members": [["actor_id": t.ownerId]]],
                ["id": groupWorkspace, "kind": "system", "name": "Workspace",
                 "effective_members": [["actor_id": t.ownerId], ["actor_id": t.agentId], ["actor_id": agentBId], ["actor_id": t.memberId]]],
            ]])
        }
        if path.hasSuffix("/grants") {
            return (200, ["complete": true, "grants": [
                ["principal_type": "group", "principal_id": groupAdmins, "permissions": ["channel.read", "file.read", "file.write", "channel.manage"]],
                ["principal_type": "group", "principal_id": groupWorkspace, "permissions": ["channel.read", "file.read"]],
            ]])
        }
        if path.hasSuffix("/scopes") {
            return (200, ["scopes": [["id": t.scopeId, "workspace_id": t.wsId, "name": "Work", "kind": "scope"]]])
        }
        if path.hasSuffix("/scopes/\(t.scopeId)/channels") {
            return (200, ["channels": [[
                "id": t.assignChannelId, "workspace_id": t.wsId, "scope_id": t.scopeId, "name": "Chief of Staff", "kind": "channel",
                "metadata": ChiefOfStaffContract.assignmentChannelMetadata(workspaceId: t.wsId, appNpub: t.appNpub),
            ]]])
        }
        let fileMeta: [String: Any] = [
            "id": t.assignFileId, "workspace_id": t.wsId, "channel_id": t.assignChannelId,
            "display_name": ChiefOfStaffContract.fileNameAssignment, "content_type": ChiefOfStaffContract.mimeAssignment,
            "metadata": ChiefOfStaffContract.assignmentFileMetadata(workspaceId: t.wsId, appNpub: t.appNpub),
        ]
        if path.hasSuffix("/channels/\(t.assignChannelId)/files") { return (200, ["files": [fileMeta]]) }
        if path.hasSuffix("/files/\(t.assignFileId)") {
            let bytes = versions[currentVersion]!
            return (200, ["file": fileMeta.merging([
                "created_by_actor_id": t.ownerId,
                "current_version_id": currentVersion,
                "current_version": ["id": currentVersion, "created_by_actor_id": t.ownerId, "created_by_actor_npub": t.ownerNpub],
                "object": ["storage_object": ["sha256_hex": SHA256Hex.of(bytes), "size_bytes": bytes.count, "is_public": false]],
            ]) { $1 }])
        }
        if path.contains("/files/\(t.assignFileId)/versions/"), path.hasSuffix("/object") {
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            return versions[id].map { (200, $0) } ?? (404, [:])
        }
        if path.hasSuffix("/files/\(t.assignFileId)/versions"), method == "POST" {
            versionWrites += 1
            let body = (try JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if staleWrite || body["base_version_id"] as? String != currentVersion { return (409, ["code": "stale_base_version"]) }
            guard let objectId = body["storage_object_id"] as? String, let bytes = objects[objectId], completed.contains(objectId) else { return (400, [:]) }
            let id = UUID().uuidString.lowercased()
            versions[id] = bytes
            currentVersion = id
            return (201, ["version": ["id": id]])
        }
        if path.hasSuffix("/storage/prepare") {
            let id = UUID().uuidString.lowercased()
            return (200, ["object_id": id, "is_public": false, "upload_url": "https://tower.example/api/v4/storage/\(id)"])
        }
        if path.hasPrefix("/api/v4/storage/") {
            let parts = path.split(separator: "/").map(String.init)
            let id = parts[3]
            if parts.count == 5, parts[4] == "complete" {
                completed.insert(id)
                return (200, ["completed_at": "2026-11-28T00:00:00.000Z"])
            }
            if method == "PUT" {
                let body = (try JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                objects[id] = Data(base64Encoded: body["base64_data"] as? String ?? "")
                return (200, [:])
            }
            guard let bytes = objects[id] else { return (200, ["id": id, "is_public": false]) }
            var meta: [String: Any] = ["id": id, "sha256_hex": SHA256Hex.of(bytes), "size_bytes": bytes.count, "is_public": false]
            if completed.contains(id) { meta["completed_at"] = "2026-11-28T00:00:00.000Z" }
            return (200, meta)
        }
        return (404, [:])
    }
}
