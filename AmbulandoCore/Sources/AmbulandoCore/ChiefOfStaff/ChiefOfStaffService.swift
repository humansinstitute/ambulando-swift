import Foundation

// MARK: - Load & reconciliation results

public enum AssignmentLoadResult: Sendable, Equatable {
    case needsSetup
    case needsFile(channel: ChannelRecord)
    case ready(channel: ChannelRecord, file: FileRecord, versionId: String, assignment: ChiefOfStaffAssignment)
}

public enum CohortLoadResult: Sendable, Equatable {
    /// Viewer is not an authorized principal of the owner+agent private ontology cohort.
    case restricted
    /// Assignment exists, but the private cohort channel/files for this assignment epoch have not been provisioned yet.
    case pendingSetup(assignmentEpoch: Int)
    case ready(
        channel: ChannelRecord,
        assignmentEpoch: Int,
        jobStatus: ChiefOfStaffJobStatus,
        jobStatusVersionId: String,
        ontology: ChiefOfStaffOntology,
        ontologyVersionId: String,
        corrections: ChiefOfStaffCorrections,
        correctionsFileId: String,
        correctionsVersionId: String
    )

    public var applied: ChiefOfStaffAppliedOntology? {
        guard case .ready(_, _, _, _, let ontology, _, let corrections, _, _) = self else { return nil }
        return ChiefOfStaffOntologyLogic.applyCorrections(
            discoveredTopics: ontology.topics,
            discoveredEvidence: ontology.evidence,
            corrections: corrections.corrections
        )
    }
}

public enum ChiefOfStaffScheduleReconciliationResult: Sendable, Equatable {
    case reconciled(jobId: String?, state: String)
    /// Autopilot accepted the run (`202`) but it had not finished within the wait window.
    case accepted(runId: String?, state: String)
    case unavailable(reason: String)
    case failed(reason: String)
}

public enum ChiefOfStaffReconcilePurpose: Sendable, Equatable {
    /// Create or update the schedule for the binding's own (currently assigned) agent.
    case setup
    /// Ask Autopilot to disable the schedule of an agent that is no longer assigned.
    case staleCleanup
}

public struct ChiefOfStaffScheduleReconciliationRequest: Sendable, Equatable {
    public let workspaceId: String
    public let ownerNpub: String
    public let appNpub: String
    public let assignedActorId: String?
    public let assignedNpub: String?
    public let assignmentRevision: Int

    public init(
        workspaceId: String,
        ownerNpub: String,
        appNpub: String,
        assignedActorId: String?,
        assignedNpub: String?,
        assignmentRevision: Int
    ) {
        self.workspaceId = workspaceId
        self.ownerNpub = ownerNpub
        self.appNpub = appNpub
        self.assignedActorId = assignedActorId
        self.assignedNpub = assignedNpub
        self.assignmentRevision = assignmentRevision
    }
}

/// Optional verified Autopilot schedule reconciler seam. Native clients never invent unverified routes;
/// when no authorized Autopilot scheduler connection is configured, reconciliation reports `.unavailable`
/// so the UI honestly displays `Assigned · Index setup pending`.
public typealias ChiefOfStaffScheduleReconciler =
    @Sendable (ChiefOfStaffScheduleReconciliationRequest) async -> ChiefOfStaffScheduleReconciliationResult

public struct CachedChiefOfStaffAssignment: Sendable, Equatable {
    public let assignment: ChiefOfStaffAssignment
    public let canonicalChannelId: String?
    public let canonicalFileId: String?

    public init(assignment: ChiefOfStaffAssignment, canonicalChannelId: String? = nil, canonicalFileId: String? = nil) {
        self.assignment = assignment
        self.canonicalChannelId = canonicalChannelId?.lowercased()
        self.canonicalFileId = canonicalFileId?.lowercased()
    }
}

// MARK: - Service

/// One unlocked workspace boundary's Chief of Staff read/write/correction service.
///
/// Discovery and reads are coalesced through `SyncEngine`; boundary-scoped assignment cache uses
/// `LocalContentSnapshot` (encrypted with the unlocked identity's self key). Private ontology prose is NOT
/// stored in the shared assignment cache slot and is cleared on access loss, workspace switch, or epoch change.
public struct ChiefOfStaffService: Sendable {
    public let api: TowerAPI
    public let workspace: String
    public let ownerNpub: String
    public let appNpub: String
    public let viewerNpub: String
    public var engine: SyncEngine?
    var cache: LocalContentSnapshot?
    public var adapter: any ChiefOfStaffEnvelopeAdapter

    private let assignmentCacheSlot = "chief-of-staff.assignment.v1"

    public init(
        api: TowerAPI,
        workspace: String,
        ownerNpub: String,
        appNpub: String,
        viewerNpub: String,
        engine: SyncEngine? = nil,
        adapter: any ChiefOfStaffEnvelopeAdapter = PlaintextChiefOfStaffEnvelopeAdapter()
    ) {
        self.api = api
        self.workspace = workspace.lowercased()
        self.ownerNpub = ownerNpub
        self.appNpub = appNpub
        self.viewerNpub = viewerNpub
        self.engine = engine
        self.adapter = adapter
    }

    // MARK: Local assignment cache (boundary-bound, no private ontology prose)

    public func cacheRevision() async -> String? { try? await cache?.epoch() }

    public func cachedAssignment() async -> CachedChiefOfStaffAssignment? {
        guard let bytes = try? await cache?.read(assignmentCacheSlot),
              let raw = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let assignmentObj = raw["assignment"] as? [String: Any]
        else { return nil }
        let expected = ExpectedWorkspaceContext(workspaceId: workspace, ownerNpub: ownerNpub, appNpub: appNpub)
        guard let assignment = try? ChiefOfStaffAssignment.parse(assignmentObj, expected: expected) else { return nil }
        return CachedChiefOfStaffAssignment(
            assignment: assignment,
            canonicalChannelId: lowerUUID(raw["canonical_channel_id"] as? String),
            canonicalFileId: lowerUUID(raw["canonical_file_id"] as? String)
        )
    }

    public func saveCachedAssignment(_ cached: CachedChiefOfStaffAssignment?, dependencies: [String] = []) async {
        guard let cache else { return }
        guard let cached else {
            await cache.remove(assignmentCacheSlot)
            return
        }
        var obj: [String: Any] = ["assignment": cached.assignment.toJSONObject()]
        if let cid = cached.canonicalChannelId { obj["canonical_channel_id"] = cid.lowercased() }
        if let fid = cached.canonicalFileId { obj["canonical_file_id"] = fid.lowercased() }
        guard let bytes = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? await cache.save(assignmentCacheSlot, bytes, dependencies: dependencies)
    }

    public func forgetCache() async {
        await cache?.remove(assignmentCacheSlot)
    }

    // MARK: Assignment read / setup / update

    /// Discovers and reads the workspace Chief of Staff assignment.
    ///
    /// Ordinary read-only members call with `verifyAcl = false` so reading NEVER requires admin-only `/groups` or
    /// `/grants`, while STILL verifying authoritative NStack channel/file/version manager provenance against
    /// `/members` (failing closed on forged non-manager candidates or canonical channel/file substitution).
    public func readAssignment(
        verifyAcl: Bool = false,
        expectedCanonicalChannelId: String? = nil,
        expectedCanonicalFileId: String? = nil
    ) async throws -> AssignmentLoadResult {
        let key = "chief-of-staff:assignment:\(workspace):\(viewerNpub):\(verifyAcl ? "acl" : "read")"
        if let engine {
            return try await engine.perform(key, priority: .visible) {
                try await self.performReadAssignment(
                    verifyAcl: verifyAcl,
                    expectedCanonicalChannelId: expectedCanonicalChannelId,
                    expectedCanonicalFileId: expectedCanonicalFileId
                )
            }
        }
        return try await performReadAssignment(
            verifyAcl: verifyAcl,
            expectedCanonicalChannelId: expectedCanonicalChannelId,
            expectedCanonicalFileId: expectedCanonicalFileId
        )
    }

    private func performReadAssignment(
        verifyAcl: Bool,
        expectedCanonicalChannelId: String?,
        expectedCanonicalFileId: String?
    ) async throws -> AssignmentLoadResult {
        let memberRoles = try await rawMembersWithRoles()
        let scopes = try await api.scopes(workspaceId: workspace, appNpub: appNpub)
        var found: [ChannelRecord] = []
        for scope in scopes where scope.kind != "dm" && ChiefOfStaffContract.isActiveRecord(scope.raw) {
            let channels = try await api.channels(workspaceId: workspace, scopeId: scope.id, appNpub: appNpub)
            found += channels.filter { ChiefOfStaffContract.isAssignmentChannel($0, workspaceId: workspace, appNpub: appNpub) }
        }
        guard found.count <= 1 else {
            throw ChiefOfStaffError.integrity("Multiple Chief of Staff assignment channels need reconciliation.")
        }
        guard let channel = found.first else {
            await forgetCache()
            return .needsSetup
        }
        if let expectedId = expectedCanonicalChannelId?.lowercased(), channel.id != expectedId {
            throw ChiefOfStaffError.integrity("Chief of Staff assignment channel identity changed unexpectedly.")
        }

        var additionalManagers: [String: String] = [:]
        if verifyAcl {
            let groups = (try? await rawGroups()) ?? []
            let memberNpubById = Dictionary(uniqueKeysWithValues: memberRoles.map { ($0.actorId.lowercased(), $0.npub) })
            // Include verified Admins system group members (e.g. effective-manager agents with role=agent)
            for g in groups where g.kind == "system" && g.name?.lowercased() == "admins" {
                for mid in g.effectiveMemberIds ?? [] {
                    if let npub = memberNpubById[mid.lowercased()] {
                        additionalManagers[mid.lowercased()] = npub
                    }
                }
            }
            let grants = try await checkGrantsComplete(channelId: channel.id)
            _ = try ChiefOfStaffAcl.verifyAssignmentChannelGrants(
                grants: grants,
                members: memberRoles,
                groups: groups,
                ownerNpub: ownerNpub,
                additionalVerifiedManagerIds: Set(additionalManagers.keys)
            )
        }

        let fileRows = try await api.client.list(
            path: try TowerAPI.base(workspace) + "/channels/" + TowerAPI.uuid(channel.id) + "/files",
            appNpub: appNpub,
            key: "files"
        )
        let files = try fileRows.map(FileRecord.init(raw:)).filter {
            ChiefOfStaffContract.isAssignmentFile($0, workspaceId: workspace, appNpub: appNpub)
        }
        guard files.count <= 1 else {
            throw ChiefOfStaffError.integrity("Multiple Chief of Staff assignment files need reconciliation.")
        }
        guard let candidate = files.first else { return .needsFile(channel: channel) }
        if let expectedId = expectedCanonicalFileId?.lowercased(), candidate.id != expectedId {
            throw ChiefOfStaffError.integrity("Chief of Staff assignment file identity changed unexpectedly.")
        }

        let expected = ExpectedWorkspaceContext(workspaceId: workspace, ownerNpub: ownerNpub, appNpub: appNpub)
        let (verifiedFile, versionId, assignment) = try await readVerifiedFile(
            fileId: candidate.id,
            expectedChannelId: channel.id
        ) { payload in
            try ChiefOfStaffAssignment.parse(payload, expected: expected)
        }

        try ChiefOfStaffAcl.verifyManagerProvenance(
            channelRaw: channel.raw,
            fileRaw: verifiedFile.raw,
            members: memberRoles,
            ownerNpub: ownerNpub,
            payloadUpdatedByActorId: assignment.updatedByActorId,
            payloadUpdatedByNpub: assignment.updatedByNpub,
            additionalVerifiedManagers: additionalManagers
        )

        await saveCachedAssignment(
            CachedChiefOfStaffAssignment(assignment: assignment, canonicalChannelId: channel.id, canonicalFileId: verifiedFile.id),
            dependencies: [channel.id, verifiedFile.id]
        )
        return .ready(channel: channel, file: verifiedFile, versionId: versionId, assignment: assignment)
    }

    public func setupAssignment(scopeId: String, now: Date = Date()) async throws -> (channel: ChannelRecord, file: FileRecord, versionId: String, assignment: ChiefOfStaffAssignment) {
        let manager = try await assertManager()
        var current = try await performReadAssignment(verifyAcl: false, expectedCanonicalChannelId: nil, expectedCanonicalFileId: nil)
        if case .needsSetup = current {
            let groups = try await rawGroups()
            let adminsGroup = groups.first { $0.kind == "system" && $0.name?.lowercased() == "admins" }
            let workspaceGroup = groups.first { $0.kind == "system" && $0.name?.lowercased() == "workspace" }
            var grants: [[String: Any]] = []
            if let adminsGroup {
                grants.append(["principal_type": "group", "principal_id": adminsGroup.id, "access_level": "manage"])
            } else {
                grants.append(["principal_type": "actor", "principal_id": manager.actorId, "access_level": "manage"])
            }
            if let workspaceGroup {
                grants.append(["principal_type": "group", "principal_id": workspaceGroup.id, "access_level": "view"])
            }
            let body: [String: Any] = [
                "name": "Chief of Staff",
                "kind": "channel",
                "description": "Workspace Chief of Staff assignment (manager-controlled, workspace-readable).",
                "metadata": ChiefOfStaffContract.assignmentChannelMetadata(workspaceId: workspace, appNpub: appNpub),
                "grants": grants,
            ]
            let reply = try await api.client.exchange(
                method: "POST",
                path: try TowerAPI.base(workspace) + "/scopes/" + TowerAPI.uuid(scopeId) + "/channels",
                appNpub: appNpub,
                jsonBody: try rawJSON(body)
            )
            if reply.status == 403 {
                throw ChiefOfStaffError.forbidden("You do not have permission to create the Chief of Staff assignment channel.")
            }
            guard (200..<300).contains(reply.status) else {
                let code = ((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any])?["code"] as? String
                throw ChiefOfStaffError.invalid("Could not create assignment channel (HTTP \(reply.status)\(code.map { ", \($0)" } ?? "")).")
            }
            current = try await performReadAssignment(verifyAcl: true, expectedCanonicalChannelId: nil, expectedCanonicalFileId: nil)
        }

        if case .needsFile(let channel) = current {
            let initial = ChiefOfStaffAssignment.empty(
                workspaceId: workspace, ownerNpub: ownerNpub, appNpub: appNpub,
                actorId: manager.actorId, actorNpub: manager.actorNpub, now: now
            )
            let bytes = try ChiefOfStaffEnvelope.encode(initial.toJSONObject(), adapter: adapter)
            let objectId = try await api.store(
                workspaceId: workspace, appNpub: appNpub, bytes: bytes,
                contentType: ChiefOfStaffContract.mimeAssignment,
                fileName: ChiefOfStaffContract.fileNameAssignment,
                prepared: nil, onPrepared: { _ in }
            )
            let createBody: [String: Any] = [
                "storage_object_id": objectId,
                "display_name": ChiefOfStaffContract.fileNameAssignment,
                "metadata": ChiefOfStaffContract.assignmentFileMetadata(workspaceId: workspace, appNpub: appNpub),
            ]
            let reply = try await api.client.exchange(
                method: "POST",
                path: try TowerAPI.base(workspace) + "/channels/" + TowerAPI.uuid(channel.id) + "/files",
                appNpub: appNpub,
                jsonBody: try rawJSON(createBody)
            )
            if reply.status == 403 {
                throw ChiefOfStaffError.forbidden("You do not have permission to initialize the Chief of Staff assignment file.")
            }
            guard (200..<300).contains(reply.status) else {
                throw ChiefOfStaffError.invalid("Could not initialize assignment file (HTTP \(reply.status)).")
            }
        }

        let ready = try await performReadAssignment(verifyAcl: true, expectedCanonicalChannelId: nil, expectedCanonicalFileId: nil)
        guard case .ready(let channel, let file, let versionId, let assignment) = ready else {
            throw ChiefOfStaffError.notInitialized("Chief of Staff assignment channel could not be initialized.")
        }
        return (channel, file, versionId, assignment)
    }

    /// Assigns, changes, or removes (`agentNpub = nil`) the workspace Chief of Staff with optimistic revision +
    /// `base_version_id` CAS. Assignment grants no new source authority. Attempts schedule reconciliation via the
    /// verified `reconcileSchedule` hook when provided, or honestly reports `.unavailable` when no Autopilot
    /// reconciler connection is configured.
    public func setAssignment(
        agentNpub: String?,
        expectedRevision: Int? = nil,
        scopeIdForSetup: String? = nil,
        reconcileSchedule: ChiefOfStaffScheduleReconciler? = nil,
        now: Date = Date()
    ) async throws -> (
        channel: ChannelRecord,
        file: FileRecord,
        versionId: String,
        assignment: ChiefOfStaffAssignment,
        reconciliation: ChiefOfStaffScheduleReconciliationResult
    ) {
        let manager = try await assertManager()
        let currentReady: (channel: ChannelRecord, file: FileRecord, versionId: String, assignment: ChiefOfStaffAssignment)
        let loaded = try await performReadAssignment(verifyAcl: true, expectedCanonicalChannelId: nil, expectedCanonicalFileId: nil)
        if case .ready(let ch, let f, let v, let a) = loaded {
            currentReady = (ch, f, v, a)
        } else {
            guard let scopeIdForSetup else {
                throw ChiefOfStaffError.notInitialized("Chief of Staff assignment channel is not initialized.")
            }
            currentReady = try await setupAssignment(scopeId: scopeIdForSetup, now: now)
        }

        if let expectedRevision, currentReady.assignment.assignmentRevision != expectedRevision {
            throw ChiefOfStaffError.conflict(
                "Chief of Staff assignment changed elsewhere (expected revision \(expectedRevision), found \(currentReady.assignment.assignmentRevision)). Refresh and try again."
            )
        }

        var assignedActorId: String? = nil
        var assignedNpub: String? = nil
        var assignedDisplayName: String? = nil
        if let agentNpub {
            let memberRows = try await api.client.list(path: try TowerAPI.base(workspace) + "/members", appNpub: appNpub, key: "members")
            let members = try memberRows.map { try MemberRecord(workspaceId: workspace, raw: $0) }
            guard let match = members.first(where: { $0.npub == agentNpub }) else {
                throw ChiefOfStaffError.invalid("Selected Chief of Staff agent is not a current member of this workspace.")
            }
            guard match.kind?.lowercased() == "agent" else {
                throw ChiefOfStaffError.invalid("Chief of Staff must be an existing workspace agent.")
            }
            assignedActorId = match.actorId.lowercased()
            assignedNpub = match.npub
            if let dn = match.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !dn.isEmpty {
                assignedDisplayName = dn
            }
        }

        // Preserve existing runtime_binding ONLY when the assigned agent has not changed.
        // A prior agent's binding may request cleanup on change/removal, but must never silently serve a new agent.
        let priorBinding = currentReady.assignment.runtimeBinding
        let resolvedBinding: ChiefOfStaffRuntimeBinding? =
            (assignedNpub != nil && priorBinding?.agentNpub == assignedNpub) ? priorBinding : nil
        let next = ChiefOfStaffAssignment(
            workspaceId: workspace,
            workspaceOwnerNpub: ownerNpub,
            appNpub: appNpub,
            assignmentRevision: currentReady.assignment.assignmentRevision + 1,
            assignedActorId: assignedActorId,
            assignedNpub: assignedNpub,
            assignedDisplayName: assignedDisplayName,
            previousAssignedNpub: currentReady.assignment.assignedNpub,
            runtimeBinding: resolvedBinding,
            updatedByActorId: manager.actorId,
            updatedByNpub: manager.actorNpub,
            updatedAt: ChiefOfStaffContract.formatTimestamp(now),
            preserved: currentReady.assignment.preserved
        )
        let bytes = try ChiefOfStaffEnvelope.encode(next.toJSONObject(), adapter: adapter)
        _ = try await writeVerifiedVersion(
            fileId: currentReady.file.id,
            baseVersionId: currentReady.versionId,
            bytes: bytes,
            mime: ChiefOfStaffContract.mimeAssignment,
            fileName: ChiefOfStaffContract.fileNameAssignment
        )

        let verified = try await performReadAssignment(
            verifyAcl: true,
            expectedCanonicalChannelId: currentReady.channel.id,
            expectedCanonicalFileId: currentReady.file.id
        )
        guard case .ready(let ch, let f, let v, let a) = verified else {
            throw ChiefOfStaffError.integrity("Updated Chief of Staff assignment could not be verified.")
        }

        let reconciliation: ChiefOfStaffScheduleReconciliationResult
        if let reconcileSchedule {
            let req = ChiefOfStaffScheduleReconciliationRequest(
                workspaceId: workspace,
                ownerNpub: ownerNpub,
                appNpub: appNpub,
                assignedActorId: a.assignedActorId,
                assignedNpub: a.assignedNpub,
                assignmentRevision: a.assignmentRevision
            )
            reconciliation = await reconcileSchedule(req)
        } else if let binding = a.runtimeBinding {
            reconciliation = try await reconcileViaRuntimeBinding(binding, assignment: a)
        } else if let prior = priorBinding {
            // Removal or change: the prior agent's binding may only ask Autopilot to disable its now-stale schedule.
            // It is sent without its subscription, so it can never create or re-enable a job for the new agent.
            let cleanup = try await reconcileViaRuntimeBinding(prior, assignment: a, purpose: .staleCleanup)
            if a.assignedNpub == nil {
                reconciliation = cleanup
            } else if case .failed(let reason) = cleanup {
                reconciliation = .failed(reason: "The previous agent's schedule cleanup failed (\(reason)). The new Chief of Staff's index setup stays pending.")
            } else {
                reconciliation = .unavailable(
                    reason: "The previous agent's schedule cleanup was requested. The new Chief of Staff has no runtime binding yet, so index setup stays pending."
                )
            }
        } else {
            reconciliation = .unavailable(
                reason: "No runtime binding is configured in this workspace's Chief of Staff assignment yet. Assignment saved; index setup stays pending until Autopilot reconciles it."
            )
        }
        return (ch, f, v, a, reconciliation)
    }

    /// Invokes Autopilot's existing generic pipeline run API (`POST /api/pipelines/definitions/:id/runs`)
    /// using NIP-98 auth signed by the existing unlocked identity and the verified `runtime_binding` stored
    /// in the trusted assignment document. Never invents bespoke endpoints or stores credentials. Redirects are
    /// refused by the transport; no `X-App-Npub` header is sent. `.setup` serves only the binding's own agent and
    /// sends its subscription; `.staleCleanup` is for a binding whose agent is no longer assigned and sends no
    /// subscription, so Autopilot can only disable that agent's schedule. Cancellation propagates.
    public func reconcileViaRuntimeBinding(
        _ binding: ChiefOfStaffRuntimeBinding,
        assignment: ChiefOfStaffAssignment,
        purpose: ChiefOfStaffReconcilePurpose = .setup
    ) async throws -> ChiefOfStaffScheduleReconciliationResult {
        let agentMatches = assignment.assignedNpub == binding.agentNpub
        guard binding.workspaceId == assignment.workspaceId, binding.workspaceId == workspace,
              binding.ownerNpub == assignment.workspaceOwnerNpub, binding.ownerNpub == ownerNpub,
              assignment.appNpub == appNpub,
              purpose == .setup ? agentMatches : !agentMatches
        else { return .failed(reason: "Runtime binding does not match this workspace's Chief of Staff assignment.") }
        guard ChiefOfStaffRuntimeBinding.isValidDefinitionId(binding.reconcilePipelineId) else {
            return .failed(reason: "Invalid reconcile_pipeline_id in runtime_binding.")
        }
        let reply: (status: Int, body: Data)
        do {
            let origin = try TowerOrigin(binding.autopilotOrigin)
            var input: [String: Any] = [
                "workspace_id": assignment.workspaceId,
                "workspace_owner_npub": assignment.workspaceOwnerNpub,
                "app_npub": assignment.appNpub,
                "assigned_agent_npub": assignment.assignedNpub ?? NSNull(),
                "assignment_revision": assignment.assignmentRevision,
                "assignment_epoch": assignment.assignmentEpoch,
                "tower_url": api.client.origin.url.absoluteString.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression),
            ]
            if purpose == .setup { input["subscription_id"] = binding.subscriptionId }
            if let cron = binding.cronExpression { input["cron_expression"] = cron }
            if let timezone = binding.timezone { input["timezone"] = timezone }
            let body: [String: Any] = [
                "mode": "wait",
                "waitSeconds": 20,
                "idempotencyKey": Self.reconcileIdempotencyKey(assignment),
                "input": input,
            ]
            // Route by the key that will actually sign this request, never by the viewer label.
            guard let signer = api.client.signer,
                  let signerNpub = NostrKeys.npub(publicKeyHex: try await signer.publicKeyHex())
            else { return .failed(reason: "Unlock this identity to set up the Chief of Staff schedule.") }
            let autopilotClient = TowerClient(origin: origin, transport: api.client.transport, signer: signer)
            reply = try await autopilotClient.exchange(
                method: "POST",
                path: Self.reconcileRunPath(binding, signerNpub: signerNpub),
                appNpub: nil,
                jsonBody: try rawJSON(body)
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .failed(reason: "Could not reach Autopilot: \(error.localizedDescription)")
        }
        // Autopilot RunEnvelope: top-level runId/status/terminal/result/error (`run` is the legacy full record).
        let obj = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
        let run = obj["run"] as? [String: Any]
        let runId = (obj["runId"] as? String) ?? (run?["id"] as? String)
        let status = ((obj["status"] as? String) ?? (run?["status"] as? String) ?? "").lowercased()
        let message = Self.errorText(obj["error"]) ?? Self.errorText(run?["error"]) ?? (obj["message"] as? String)
        switch reply.status {
        case 200 where status == "ok":
            // The reconcile step assigns the engine's outcome to `result.reconciled`.
            let outcome = ((obj["result"] ?? run?["result"]) as? [String: Any])?["reconciled"] as? [String: Any]
            guard let scheduleState = (outcome?["schedule_state"] as? String)?.lowercased(),
                  ChiefOfStaffContract.scheduleStates.contains(scheduleState)
            else { return .failed(reason: "Autopilot finished the reconciliation run without a readable schedule state.") }
            let engineError = outcome?["last_error"] as? String
            switch scheduleState {
            case "error":
                return .failed(reason: engineError ?? "Autopilot reported a schedule error.")
            case "pending":
                return .unavailable(reason: engineError ?? "Index setup is pending in Autopilot.")
            default:
                return .reconciled(jobId: (outcome?["autopilot_job_id"] as? String) ?? runId, state: scheduleState)
            }
        case 200 where ["queued", "running"].contains(status), 202:
            return .accepted(runId: runId, state: status.isEmpty ? "running" : status)
        case 200:
            return .failed(reason: "Autopilot reconciliation run ended with state \(status.isEmpty ? "unknown" : status)\(message.map { ": \($0)" } ?? "").")
        case 300..<400:
            return .failed(reason: "Autopilot answered with a redirect (HTTP \(reply.status)); redirects are refused.")
        case 404:
            return .failed(reason: "Pipeline \(binding.reconcilePipelineId) is not installed on \(binding.autopilotOrigin).")
        default:
            return .failed(reason: "Autopilot pipeline run refused (\(message ?? "HTTP \(reply.status)")).")
        }
    }

    private static func errorText(_ raw: Any?) -> String? {
        (raw as? String) ?? ((raw as? [String: Any])?["message"] as? String)
    }

    /// Unprefixed run routes resolve definitions in the signer's own Autopilot space. A delegated manager (not the
    /// binding owner) therefore addresses the owner's space explicitly; the owner comes from the verified binding only.
    static func reconcileRunPath(_ binding: ChiefOfStaffRuntimeBinding, signerNpub: String) -> String {
        let run = "/pipelines/definitions/\(binding.reconcilePipelineId)/runs"
        return signerNpub == binding.ownerNpub ? "/api" + run : "/api/owners/\(binding.ownerNpub)" + run
    }

    /// Stable per revision and agent so a retried save replays the same run instead of starting another.
    static func reconcileIdempotencyKey(_ assignment: ChiefOfStaffAssignment) -> String {
        "chief-of-staff:reconcile:\(assignment.workspaceId):rev:\(assignment.assignmentRevision):\(assignment.assignedNpub ?? "unassigned")"
    }

    // MARK: Private ontology cohort read & durable corrections

    /// Reads the private owner+assigned-agent ontology cohort for the exact `assignmentEpoch`.
    /// Unauthorized viewers receive `.restricted` immediately with zero network calls.
    public func readCohort(agentNpub: String, assignmentEpoch: Int) async throws -> CohortLoadResult {
        guard viewerNpub == ownerNpub || viewerNpub == agentNpub else {
            return .restricted
        }
        let epoch = max(1, assignmentEpoch)
        let key = "chief-of-staff:cohort:\(workspace):\(viewerNpub):\(agentNpub):\(epoch)"
        if let engine {
            return try await engine.perform(key, priority: .visible) {
                try await self.performReadCohort(agentNpub: agentNpub, assignmentEpoch: epoch)
            }
        }
        return try await performReadCohort(agentNpub: agentNpub, assignmentEpoch: epoch)
    }

    private func performReadCohort(agentNpub: String, assignmentEpoch: Int) async throws -> CohortLoadResult {
        guard viewerNpub == ownerNpub || viewerNpub == agentNpub else { return .restricted }
        let epoch = max(1, assignmentEpoch)
        let scopes = try await api.scopes(workspaceId: workspace, appNpub: appNpub)
        var found: [ChannelRecord] = []
        for scope in scopes where scope.kind != "dm" && ChiefOfStaffContract.isActiveRecord(scope.raw) {
            let channels = try await api.channels(workspaceId: workspace, scopeId: scope.id, appNpub: appNpub)
            found += channels.filter {
                ChiefOfStaffContract.isCohortChannel($0, workspaceId: workspace, appNpub: appNpub, ownerNpub: ownerNpub, agentNpub: agentNpub, assignmentEpoch: epoch)
            }
        }
        guard found.count <= 1 else {
            throw ChiefOfStaffError.integrity("Multiple Chief of Staff ontology cohort channels for epoch \(epoch) need reconciliation.")
        }
        guard let channel = found.first else {
            return .pendingSetup(assignmentEpoch: epoch)
        }

        func verifyPrivateGrants() async throws {
            let grants = try await checkGrantsComplete(channelId: channel.id)
            let memberRows = try await api.client.list(path: try TowerAPI.base(workspace) + "/members", appNpub: appNpub, key: "members")
            let members = try memberRows.map { try MemberRecord(workspaceId: workspace, raw: $0) }
            _ = try ChiefOfStaffAcl.verifyCohortChannelGrants(grants: grants, members: members, ownerNpub: ownerNpub, agentNpub: agentNpub)
        }

        try await verifyPrivateGrants()

        let fileRows = try await api.client.list(
            path: try TowerAPI.base(workspace) + "/channels/" + TowerAPI.uuid(channel.id) + "/files",
            appNpub: appNpub,
            key: "files"
        )
        let allFiles = try fileRows.map(FileRecord.init(raw:))
        func pick(kind: String, mime: String) throws -> FileRecord? {
            let matches = allFiles.filter {
                ChiefOfStaffContract.isCohortFile(
                    $0, kind: kind, mime: mime, workspaceId: workspace, appNpub: appNpub,
                    ownerNpub: ownerNpub, agentNpub: agentNpub, assignmentEpoch: epoch
                )
            }
            guard matches.count <= 1 else {
                throw ChiefOfStaffError.integrity("Multiple Chief of Staff \(kind) files need reconciliation.")
            }
            return matches.first
        }

        guard let jobStatusFile = try pick(kind: "job_status", mime: ChiefOfStaffContract.mimeJobStatus),
              let ontologyFile = try pick(kind: "ontology", mime: ChiefOfStaffContract.mimeOntology),
              let correctionsFile = try pick(kind: "corrections", mime: ChiefOfStaffContract.mimeCorrections)
        else { return .pendingSetup(assignmentEpoch: epoch) }

        let expected = ExpectedWorkspaceContext(workspaceId: workspace, ownerNpub: ownerNpub, appNpub: appNpub)
        let (_, jobStatusVer, jobStatus) = try await readVerifiedFile(fileId: jobStatusFile.id, expectedChannelId: channel.id) {
            try ChiefOfStaffJobStatus.parse($0, expected: expected)
        }
        let (_, ontologyVer, ontology) = try await readVerifiedFile(fileId: ontologyFile.id, expectedChannelId: channel.id) {
            try ChiefOfStaffOntology.parse($0, expected: expected)
        }
        let (_, correctionsVer, corrections) = try await readVerifiedFile(fileId: correctionsFile.id, expectedChannelId: channel.id) {
            try ChiefOfStaffCorrections.parse($0, expected: expected)
        }
        try await verifyPrivateGrants()

        return .ready(
            channel: channel,
            assignmentEpoch: epoch,
            jobStatus: jobStatus,
            jobStatusVersionId: jobStatusVer,
            ontology: ontology,
            ontologyVersionId: ontologyVer,
            corrections: corrections,
            correctionsFileId: correctionsFile.id,
            correctionsVersionId: correctionsVer
        )
    }

    /// Appends a durable correction to `Chief of Staff.corrections.json` using `base_version_id` CAS with bounded retry.
    public func appendCorrection(
        agentNpub: String,
        assignmentEpoch: Int,
        correction: ChiefOfStaffCorrection,
        now: Date = Date(),
        maxAttempts: Int = 4
    ) async throws -> ChiefOfStaffCorrections {
        guard ChiefOfStaffContract.correctionKinds.contains(correction.kind) else {
            throw ChiefOfStaffError.invalid("Unsupported correction kind.")
        }
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            let state = try await performReadCohort(agentNpub: agentNpub, assignmentEpoch: assignmentEpoch)
            guard case .ready(_, _, _, _, _, _, let cur, let correctionsFileId, let correctionsVersionId) = state else {
                throw ChiefOfStaffError.notInitialized("Chief of Staff topic index is not ready for corrections yet.")
            }
            if cur.corrections.contains(where: { $0.id == correction.id }) { return cur }
            let next = ChiefOfStaffCorrections(
                workspaceId: cur.workspaceId,
                workspaceOwnerNpub: cur.workspaceOwnerNpub,
                appNpub: cur.appNpub,
                cohortId: cur.cohortId,
                assignmentEpoch: cur.assignmentEpoch,
                corrections: cur.corrections + [correction],
                updatedAt: ChiefOfStaffContract.formatTimestamp(now)
            )
            let bytes = try ChiefOfStaffEnvelope.encode(next.toJSONObject(), adapter: adapter)
            do {
                _ = try await writeVerifiedVersion(
                    fileId: correctionsFileId,
                    baseVersionId: correctionsVersionId,
                    bytes: bytes,
                    mime: ChiefOfStaffContract.mimeCorrections,
                    fileName: ChiefOfStaffContract.fileNameCorrections
                )
                return next
            } catch is CancellationError {
                throw CancellationError()
            } catch ChiefOfStaffError.conflict {
                if attempt < maxAttempts - 1 { continue }
                throw ChiefOfStaffError.conflict("Could not save correction after conflict retries.")
            }
        }
        throw ChiefOfStaffError.conflict("Could not save correction after conflict retries.")
    }

    // MARK: Internal Tower helpers

    private struct VerifiedManager { let actorId: String; let actorNpub: String }

    private func assertManager() async throws -> VerifiedManager {
        let me = try api.object(try await api.client.request(path: try TowerAPI.base(workspace) + "/me", appNpub: appNpub), "me")
        guard let identity = me["identity"] as? [String: Any],
              (identity["workspace_id"] as? String)?.lowercased() == workspace,
              identity["workspace_owner_npub"] as? String == ownerNpub,
              identity["app_npub"] as? String == appNpub
        else { throw ChiefOfStaffError.boundaryMismatch("Workspace identity boundary mismatch.") }

        let actor = me["actor"] as? [String: Any]
        guard let actorId = lowerUUID((actor?["actor_id"] ?? actor?["id"]) as? String),
              let actorNpub = actor?["npub"] as? String, NostrKeys.isValidNpub(actorNpub)
        else { throw ChiefOfStaffError.invalid("Manager actor identity is missing.") }
        // Effective server permissions, never the membership role label (an agent can hold delegated manage).
        let perms = Set((me["permissions"] as? [Any])?.compactMap { $0 as? String } ?? [])
        guard actorNpub == ownerNpub || perms.contains("workspace.manage") else {
            throw ChiefOfStaffError.forbidden("Workspace manager access is required to change the Chief of Staff assignment.")
        }
        return VerifiedManager(actorId: actorId, actorNpub: actorNpub)
    }

    private func rawMembersWithRoles() async throws -> [ChiefOfStaffAcl.MemberRoleEntry] {
        let rows = try await api.client.list(path: try TowerAPI.base(workspace) + "/members", appNpub: appNpub, key: "members")
        return rows.compactMap { data in
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let actor = raw["actor"] as? [String: Any]
            guard let id = lowerUUID((raw["actor_id"] ?? actor?["actor_id"] ?? actor?["id"] ?? raw["id"]) as? String),
                  let npub = (raw["npub"] ?? actor?["npub"]) as? String, NostrKeys.isValidNpub(npub)
            else { return nil }
            let role = (raw["role"] as? String) ?? ((raw["membership"] as? [String: Any])?["role"] as? String)
            let permsAny = (raw["permissions"] as? [Any])
                ?? (raw["effective_permissions"] as? [Any])
                ?? ((raw["membership"] as? [String: Any])?["permissions"] as? [Any])
                ?? ((raw["membership"] as? [String: Any])?["effective_permissions"] as? [Any])
            let perms = Set(permsAny?.compactMap { $0 as? String } ?? [])
            let canManageWorkspace = ChiefOfStaffAcl.MemberRoleEntry.strictCanManageWorkspace(raw)
            return ChiefOfStaffAcl.MemberRoleEntry(
                actorId: id,
                npub: npub,
                role: role,
                permissions: perms,
                canManageWorkspace: canManageWorkspace
            )
        }
    }

    private func rawGroups() async throws -> [ChiefOfStaffAcl.GroupEntry] {
        let rows = try await api.client.list(path: try TowerAPI.base(workspace) + "/groups", appNpub: appNpub, key: "groups")
        return rows.compactMap { data in
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = lowerUUID((raw["id"] ?? raw["group_id"]) as? String)
            else { return nil }
            let effRows = (raw["effective_members"] as? [[String: Any]]) ?? (raw["members"] as? [[String: Any]])
            let effIds = effRows.map { Set($0.compactMap { lowerUUID(($0["actor_id"] ?? $0["id"]) as? String) }) }
            return ChiefOfStaffAcl.GroupEntry(
                id: id,
                kind: (raw["kind"] as? String) ?? (raw["group_kind"] as? String),
                name: raw["name"] as? String,
                effectiveMemberIds: effIds
            )
        }
    }

    private func checkGrantsComplete(channelId: String) async throws -> [[String: Any]] {
        let raw = try await api.client.request(
            path: try TowerAPI.base(workspace) + "/channels/" + TowerAPI.uuid(channelId) + "/grants",
            appNpub: appNpub
        )
        let acl = try api.object(raw, "chief of staff grants")
        guard acl["partial"] as? Bool != true,
              acl["complete"] as? Bool != false,
              acl["has_more"] as? Bool != true,
              acl["next_cursor"] as? String == nil,
              let grants = acl["grants"] as? [[String: Any]]
        else { throw ChiefOfStaffError.integrity("Channel grants are incomplete.") }
        return grants
    }

    private func readVerifiedFile<T>(
        fileId: String,
        expectedChannelId: String,
        parse: ([String: Any]) throws -> T
    ) async throws -> (FileRecord, String, T) {
        let base = try TowerAPI.base(workspace) + "/files/" + TowerAPI.uuid(fileId)
        let resp = try api.object(try await api.client.request(path: base, appNpub: appNpub), "chief of staff file")
        guard let fileObj = resp["file"] as? [String: Any] else {
            throw ChiefOfStaffError.invalid("Chief of Staff file could not be read.")
        }
        let file = try FileRecord(raw: try rawJSON(fileObj))
        guard file.id == fileId.lowercased(),
              file.workspaceId == workspace,
              file.channelId == expectedChannelId.lowercased()
        else { throw ChiefOfStaffError.boundaryMismatch("Chief of Staff file boundary mismatch.") }

        guard let versionId = lowerUUID(fileObj["current_version_id"] as? String) else {
            throw ChiefOfStaffError.integrity("Chief of Staff file has no saved version.")
        }
        guard let storage = (fileObj["object"] as? [String: Any])?["storage_object"] as? [String: Any],
              let sha = (storage["sha256_hex"] as? String)?.lowercased(), sha.count == 64,
              let size = flexibleInt(storage["size_bytes"]),
              (0...ChiefOfStaffContract.maxBytes).contains(size),
              storage["is_public"] as? Bool == false
        else { throw ChiefOfStaffError.integrity("Unverified or public Chief of Staff file object.") }

        let bytes = try await api.client.request(path: base + "/versions/" + versionId + "/object", appNpub: appNpub)
        guard bytes.count == size, SHA256Hex.of(bytes) == sha else {
            throw ChiefOfStaffError.integrity("Chief of Staff file content digest mismatch.")
        }
        let payload = try ChiefOfStaffEnvelope.decode(bytes, adapter: adapter)
        return (file, versionId, try parse(payload))
    }

    private func writeVerifiedVersion(
        fileId: String,
        baseVersionId: String,
        bytes: Data,
        mime: String,
        fileName: String
    ) async throws -> String {
        let objectId = try await api.store(
            workspaceId: workspace, appNpub: appNpub, bytes: bytes,
            contentType: mime, fileName: fileName, prepared: nil, onPrepared: { _ in }
        )
        let body = try rawJSON([
            "base_version_id": try TowerAPI.uuid(baseVersionId),
            "storage_object_id": objectId,
            "client_mutation_id": UUID().uuidString.lowercased(),
        ])
        let reply: (status: Int, body: Data)
        do {
            reply = try await api.client.exchange(
                method: "POST",
                path: try TowerAPI.base(workspace) + "/files/" + TowerAPI.uuid(fileId) + "/versions",
                appNpub: appNpub,
                jsonBody: body
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChiefOfStaffError.offline(error.localizedDescription)
        }
        let o = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
        let code = o["code"] as? String
        switch reply.status {
        case 200, 201:
            let versionObj = o["version"] as? [String: Any]
            let fileObj = o["file"] as? [String: Any]
            guard let savedVersionId = lowerUUID((versionObj?["id"] ?? fileObj?["current_version_id"]) as? String) else {
                throw ChiefOfStaffError.integrity("Version write outcome uncertain; refresh before retrying.")
            }
            let readback = try await api.client.request(
                path: try TowerAPI.base(workspace) + "/files/" + TowerAPI.uuid(fileId) + "/versions/" + savedVersionId + "/object",
                appNpub: appNpub
            )
            guard SHA256Hex.of(readback) == SHA256Hex.of(bytes) else {
                throw ChiefOfStaffError.integrity("Chief of Staff file readback digest mismatch.")
            }
            return savedVersionId
        case 409:
            throw ChiefOfStaffError.conflict("This record changed elsewhere (\(code ?? "stale_base_version")). Refresh and try again.")
        case 401, 403:
            throw ChiefOfStaffError.forbidden("You do not have permission to modify this Chief of Staff record.")
        case 408, 425, 429, 500...599:
            throw ChiefOfStaffError.offline("Tower is unavailable (HTTP \(reply.status)); try again.")
        default:
            throw ChiefOfStaffError.invalid("Tower refused the save (HTTP \(reply.status)\(code.map { ", \($0)" } ?? "")).")
        }
    }
}

extension WorkspaceSync {
    public func chiefOfStaff(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord) throws -> ChiefOfStaffService {
        guard let ownerNpub = workspace.ownerNpub, NostrKeys.isValidNpub(ownerNpub) else {
            throw ChiefOfStaffError.boundaryMismatch("Workspace owner identity is unavailable.")
        }
        var service = ChiefOfStaffService(
            api: api(origin: try TowerOrigin(connection.origin)),
            workspace: workspace.id,
            ownerNpub: ownerNpub,
            appNpub: workspace.appNpub,
            viewerNpub: connection.signerNpub,
            engine: engine
        )
        service.cache = LocalContentSnapshot(
            store: store,
            identity: identity,
            boundary: try WorkspaceBoundary(connection: connection, workspace: workspace)
        )
        return service
    }
}
