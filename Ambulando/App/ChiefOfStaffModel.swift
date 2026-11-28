import AmbulandoCore
import Foundation
import Observation

/// Per-workspace-boundary Chief of Staff state on the main actor.
///
/// Discovery and reads go through `ChiefOfStaffService` (which coalesces through `SyncEngine`);
/// late responses after workspace/account switch are dropped; private topic state is cleared
/// immediately on workspace switch, access loss, or assignment/epoch change.
@MainActor @Observable
final class ChiefOfStaffModel {
    enum AssignmentState: Equatable {
        case idle
        case loading
        case needsSetup
        case ready(ChiefOfStaffAssignment, channelId: String, fileId: String, versionId: String)
        case error(String)
    }

    struct ReadyCohort: Equatable {
        let channelId: String
        let assignmentEpoch: Int
        let jobStatus: ChiefOfStaffJobStatus
        let ontology: ChiefOfStaffOntology
        let corrections: ChiefOfStaffCorrections
        let applied: ChiefOfStaffAppliedOntology
    }

    enum CohortState: Equatable {
        case idle
        case loading
        case restricted
        case pendingSetup(assignmentEpoch: Int)
        case ready(ReadyCohort)
        case error(String)
    }

    let boundary: WorkspaceBoundary
    @ObservationIgnored private let service: ChiefOfStaffService
    @ObservationIgnored private let isCurrent: @MainActor (WorkspaceBoundary) -> Bool
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var cacheRevision: String?
    @ObservationIgnored private var canonicalChannelId: String?
    @ObservationIgnored private var canonicalFileId: String?

    private(set) var assignmentState: AssignmentState = .idle
    private(set) var cohortState: CohortState = .idle
    private(set) var lastReconciliation: ChiefOfStaffScheduleReconciliationResult?
    private(set) var saving = false
    private(set) var actionError: String?
    private(set) var actionNotice: String?

    init(
        boundary: WorkspaceBoundary,
        service: ChiefOfStaffService,
        isCurrent: @escaping @MainActor (WorkspaceBoundary) -> Bool
    ) {
        self.boundary = boundary
        self.service = service
        self.isCurrent = isCurrent
    }

    var currentAssignment: ChiefOfStaffAssignment? {
        if case .ready(let assignment, _, _, _) = assignmentState { return assignment }
        return nil
    }

    var assignedAgentNpub: String? {
        currentAssignment?.assignedNpub
    }

    var assignedDisplayName: String? {
        currentAssignment?.assignedDisplayName
    }

    var viewerCanAccessCohort: Bool {
        guard let agent = assignedAgentNpub else { return false }
        return boundary.signerNpub == service.ownerNpub || boundary.signerNpub == agent
    }

    /// Honest status badge distinguishing unassigned, restricted, pending setup, scheduled/running/healthy/error/stale.
    var statusLabel: String {
        guard let assignment = currentAssignment else {
            if case .loading = assignmentState { return "Checking…" }
            if case .error = assignmentState { return "Verification required" }
            return "Unassigned"
        }
        guard assignment.isAssigned else { return "Unassigned" }
        switch cohortState {
        case .restricted:
            return "Assigned · Private index (Owner & Agent)"
        case .pendingSetup, .idle:
            return "Assigned · Index setup pending"
        case .loading:
            return "Assigned · Checking index…"
        case .error:
            return "Assigned · Index error"
        case .ready(let cohort):
            switch cohort.jobStatus.scheduleState {
            case "healthy": return "Healthy"
            case "running": return "Running"
            case "scheduled": return "Scheduled"
            case "error": return "Error"
            case "disabled_stale": return "Disabled (stale assignment)"
            default: return "Assigned · Index setup pending"
            }
        }
    }

    func refresh(verifyAcl: Bool = false) async {
        guard isCurrent(boundary) else { return }
        if let inflight {
            await inflight.value
            return
        }
        let work = Task { await self.performRefresh(verifyAcl: verifyAcl) }
        inflight = work
        await work.value
        inflight = nil
    }

    func reconcileLocalRemovals() async {
        let next = await service.cacheRevision()
        guard next != cacheRevision, isCurrent(boundary) else { return }
        cacheRevision = next
        if await service.cachedAssignment() == nil {
            clearDerivedState()
        }
    }

    func clearDerivedState() {
        assignmentState = .idle
        cohortState = .idle
        lastReconciliation = nil
        actionError = nil
        actionNotice = nil
        canonicalChannelId = nil
        canonicalFileId = nil
    }

    private func performRefresh(verifyAcl: Bool) async {
        if case .idle = assignmentState {
            assignmentState = .loading
            if let cached = await service.cachedAssignment(), isCurrent(boundary) {
                canonicalChannelId = cached.canonicalChannelId
                canonicalFileId = cached.canonicalFileId
                assignmentState = .ready(
                    cached.assignment,
                    channelId: cached.canonicalChannelId ?? "",
                    fileId: cached.canonicalFileId ?? "",
                    versionId: ""
                )
            }
        }
        guard isCurrent(boundary) else { clearDerivedState(); return }

        do {
            let result = try await service.readAssignment(
                verifyAcl: verifyAcl,
                expectedCanonicalChannelId: canonicalChannelId,
                expectedCanonicalFileId: canonicalFileId
            )
            guard isCurrent(boundary) else { clearDerivedState(); return }
            cacheRevision = await service.cacheRevision()
            switch result {
            case .needsSetup, .needsFile:
                canonicalChannelId = nil
                canonicalFileId = nil
                assignmentState = .needsSetup
                cohortState = .idle
            case .ready(let channel, let file, let versionId, let assignment):
                let previousAgent = currentAssignment?.assignedNpub
                let previousEpoch = currentAssignment?.assignmentEpoch
                canonicalChannelId = channel.id
                canonicalFileId = file.id
                assignmentState = .ready(assignment, channelId: channel.id, fileId: file.id, versionId: versionId)
                if previousAgent != assignment.assignedNpub || previousEpoch != assignment.assignmentEpoch {
                    cohortState = .idle
                }
                await refreshCohort(for: assignment)
            }
        } catch is CancellationError {
            if !isCurrent(boundary) { clearDerivedState() }
        } catch {
            guard isCurrent(boundary) else { clearDerivedState(); return }
            if error is ChiefOfStaffError || CachedContentFailure.invalidates(error) {
                await service.forgetCache()
                canonicalChannelId = nil
                canonicalFileId = nil
                cohortState = .idle
            }
            assignmentState = .error(Self.message(error))
        }
    }

    private func refreshCohort(for assignment: ChiefOfStaffAssignment) async {
        guard isCurrent(boundary) else { clearDerivedState(); return }
        guard let agentNpub = assignment.assignedNpub else {
            cohortState = .idle
            return
        }
        if !viewerCanAccessCohort {
            cohortState = .restricted
            return
        }
        cohortState = .loading
        do {
            let result = try await service.readCohort(agentNpub: agentNpub, assignmentEpoch: assignment.assignmentEpoch)
            guard isCurrent(boundary) else { clearDerivedState(); return }
            switch result {
            case .restricted:
                cohortState = .restricted
            case .pendingSetup(let epoch):
                cohortState = .pendingSetup(assignmentEpoch: epoch)
            case .ready(let channel, let epoch, let jobStatus, _, let ontology, _, let corrections, _, _):
                let applied = ChiefOfStaffOntologyLogic.applyCorrections(
                    discoveredTopics: ontology.topics,
                    discoveredEvidence: ontology.evidence,
                    corrections: corrections.corrections
                )
                cohortState = .ready(ReadyCohort(
                    channelId: channel.id,
                    assignmentEpoch: epoch,
                    jobStatus: jobStatus,
                    ontology: ontology,
                    corrections: corrections,
                    applied: applied
                ))
            }
        } catch is CancellationError {
            if !isCurrent(boundary) { clearDerivedState() }
        } catch let err as ChiefOfStaffError where err == .restricted(err.localizedDescription) {
            guard isCurrent(boundary) else { clearDerivedState(); return }
            cohortState = .restricted
        } catch {
            guard isCurrent(boundary) else { clearDerivedState(); return }
            if case .restricted = error as? ChiefOfStaffError {
                cohortState = .restricted
            } else {
                cohortState = .error(Self.message(error))
            }
        }
    }

    func saveAssignment(
        agentNpub: String?,
        scopeIdForSetup: String?,
        reconcileSchedule: ChiefOfStaffScheduleReconciler? = nil
    ) async {
        guard isCurrent(boundary), !saving else { return }
        saving = true
        actionError = nil
        actionNotice = nil
        defer { saving = false }
        let expectedRev = currentAssignment?.assignmentRevision
        do {
            let saved = try await service.setAssignment(
                agentNpub: agentNpub,
                expectedRevision: expectedRev,
                scopeIdForSetup: scopeIdForSetup,
                reconcileSchedule: reconcileSchedule
            )
            guard isCurrent(boundary) else { clearDerivedState(); return }
            canonicalChannelId = saved.channel.id
            canonicalFileId = saved.file.id
            assignmentState = .ready(saved.assignment, channelId: saved.channel.id, fileId: saved.file.id, versionId: saved.versionId)
            cohortState = .idle
            lastReconciliation = saved.reconciliation
            switch saved.reconciliation {
            case .reconciled(_, let state):
                actionNotice = agentNpub == nil
                    ? "Chief of Staff removed and schedule reconciled (\(state))."
                    : "Chief of Staff saved and schedule reconciled (\(state))."
            case .accepted(_, let state):
                actionNotice = agentNpub == nil
                    ? "Chief of Staff removed. Autopilot accepted the schedule cleanup (\(state)); status updates when it finishes."
                    : "Chief of Staff saved. Autopilot accepted index setup (\(state)); status updates when it finishes."
            case .unavailable(let reason):
                actionNotice = agentNpub == nil
                    ? "Chief of Staff removed. \(reason)"
                    : "Chief of Staff saved. \(reason)"
            case .failed(let reason):
                actionError = "Assignment saved, but schedule reconciliation failed: \(reason)"
            }
            await refreshCohort(for: saved.assignment)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(boundary) else { return }
            actionError = Self.message(error)
        }
    }

    func appendCorrection(_ correction: ChiefOfStaffCorrection) async -> Bool {
        guard isCurrent(boundary), !saving, let assignment = currentAssignment, let agentNpub = assignment.assignedNpub else {
            return false
        }
        saving = true
        actionError = nil
        actionNotice = nil
        defer { saving = false }
        do {
            let updated = try await service.appendCorrection(
                agentNpub: agentNpub,
                assignmentEpoch: assignment.assignmentEpoch,
                correction: correction
            )
            guard isCurrent(boundary) else { clearDerivedState(); return false }
            if case .ready(let existing) = cohortState {
                let applied = ChiefOfStaffOntologyLogic.applyCorrections(
                    discoveredTopics: existing.ontology.topics,
                    discoveredEvidence: existing.ontology.evidence,
                    corrections: updated.corrections
                )
                cohortState = .ready(ReadyCohort(
                    channelId: existing.channelId,
                    assignmentEpoch: existing.assignmentEpoch,
                    jobStatus: existing.jobStatus,
                    ontology: existing.ontology,
                    corrections: updated,
                    applied: applied
                ))
            }
            actionNotice = "Correction saved."
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent(boundary) else { return false }
            actionError = Self.message(error)
            return false
        }
    }

    static func message(_ error: Error) -> String {
        if let err = error as? ChiefOfStaffError { return err.localizedDescription }
        if case TowerError.http(let status, _, _) = error {
            if status == 403 { return "You don’t have permission to access this Chief of Staff resource." }
            if status == 404 { return "This Chief of Staff record is no longer available." }
        }
        return error.localizedDescription
    }
}

// MARK: - AppModel wiring

extension AppModel {
    /// Per-workspace-boundary Chief of Staff model, created on first use and cleared on workspace/account switch.
    func chiefOfStaffModel(for workspace: WorkspaceRecord) -> ChiefOfStaffModel? {
        guard isUnlocked, let sync, let connection, let boundary = selectedWorkspaceBoundary,
              workspace.id == selectedWorkspace?.id,
              workspace.appNpub == selectedWorkspace?.appNpub
        else { return nil }
        if let existing = chiefOfStaffModels[boundary.id] { return existing }
        guard let service = try? sync.chiefOfStaff(connection, workspace) else { return nil }
        let model = ChiefOfStaffModel(boundary: boundary, service: service) { [weak self] b in
            self?.isUnlocked == true && self?.selectedWorkspaceBoundary == b
        }
        chiefOfStaffModels[boundary.id] = model
        return model
    }

    var activeChiefOfStaffModel: ChiefOfStaffModel? {
        guard let workspace = selectedWorkspace else { return nil }
        return chiefOfStaffModel(for: workspace)
    }

    func openChiefOfStaffTopics() {
        guard let workspace = selectedWorkspace?.id else { return }
        if fileNappletNavigation?({ self.openChiefOfStaffTopics() }) == true { return }
        deckPath = [.chiefOfStaffTopics(workspaceId: workspace)]
        show(.deck)
    }

    /// Revalidates the active workspace's Chief of Staff assignment and opens the viewer's OWN authorized 2-party DM
    /// with the assigned agent (`{viewerNpub, assignedNpub}` in the DM scope). Never opens another member's DM,
    /// self-DM, or group DM; refreshes remote DM channels before creating to avoid duplicates.
    func openChiefOfStaffDM() {
        guard let workspace = selectedWorkspace,
              let connection,
              let cos = chiefOfStaffModel(for: workspace),
              let manager
        else { return }
        let boundary = selectedWorkspaceBoundary
        let epoch = wikiContextEpoch
        Task { @MainActor in
            await cos.refresh(verifyAcl: false)
            guard epoch == wikiContextEpoch, selectedWorkspaceBoundary == boundary else { return }
            guard let agentNpub = cos.assignedAgentNpub else {
                notice = "No Chief of Staff is assigned in this workspace."
                return
            }
            let viewerNpub = connection.signerNpub
            if viewerNpub == agentNpub {
                notice = "You are the assigned Chief of Staff for this workspace."
                return
            }
            let nav = navigation.value
            let scopes = nav.groups.map(\.scope)
            let channels = nav.groups.flatMap(\.channels)
            if let existing = ChiefOfStaffOntologyLogic.findViewerDirectMessage(
                scopes: scopes,
                channels: channels,
                viewerNpub: viewerNpub,
                agentNpub: agentNpub
            ) {
                openInChat(channelId: existing.id)
                return
            }
            guard let dmScope = ChiefOfStaffOntologyLogic.directMessageScope(scopes: scopes) else {
                notice = "Direct messages are not available in this workspace yet."
                return
            }
            do {
                let channel = try await manager.createDirectMessage(
                    connection,
                    workspace,
                    scopeId: dmScope.id,
                    participantNpub: agentNpub
                )
                guard epoch == wikiContextEpoch, selectedWorkspaceBoundary == boundary else { return }
                openInChat(channelId: channel.id)
            } catch {
                guard epoch == wikiContextEpoch, selectedWorkspaceBoundary == boundary else { return }
                notice = "Could not open Chief of Staff DM: \(error.localizedDescription)"
            }
        }
    }
}
