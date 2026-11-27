import AmbulandoCore
import Foundation
import Observation

/// Visible state belongs to one unlocked workspace boundary. Publication stays with Rick.
@MainActor @Observable
final class BriefingModel {
    let boundary: WorkspaceBoundary
    @ObservationIgnored private let service: BriefingService
    @ObservationIgnored private let isCurrent: @MainActor (WorkspaceBoundary) -> Bool
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var revision: String?
    private(set) var snapshot: BriefingSnapshot?
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var cached = false
    private(set) var error: String?

    init(boundary: WorkspaceBoundary, service: BriefingService, isCurrent: @escaping @MainActor (WorkspaceBoundary) -> Bool) {
        self.boundary = boundary; self.service = service; self.isCurrent = isCurrent
    }
    func refresh() async {
        guard isCurrent(boundary) else { return }
        if let inflight { await inflight.value; return }
        let work = Task { await self.load() }; inflight = work
        await work.value; inflight = nil
    }
    func reconcileLocalRemovals() async {
        let next = await service.cacheRevision()
        guard next != revision, isCurrent(boundary) else { return }
        revision = next
        if await service.cached() == nil {
            snapshot = nil; cached = false
            error = "The saved briefing is no longer available with its previous access."
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        let nextRevision = await service.cacheRevision()
        if revision != nextRevision {
            revision = nextRevision
            snapshot = await service.cached(); cached = snapshot != nil
        } else if !loaded, snapshot == nil { snapshot = await service.cached(); cached = snapshot != nil }
        guard isCurrent(boundary) else { snapshot = nil; return }
        do {
            let fresh: BriefingSnapshot
            do { fresh = try await service.load() }
            catch is CancellationError {
                guard isCurrent(boundary), !Task.isCancelled else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(250))
                fresh = try await service.load()
            }
            guard isCurrent(boundary) else { snapshot = nil; return }
            snapshot = fresh; cached = false; error = nil; loaded = true
            revision = await service.cacheRevision()
        } catch is CancellationError {
            if !isCurrent(boundary) { snapshot = nil }
            else { error = "Briefing refresh was interrupted. Try again." }
        } catch {
            guard isCurrent(boundary) else { snapshot = nil; return }
            // Connectivity can retain verified writing. Explicit access/source failures remove it.
            let invalidSource: Bool
            switch error {
            case TowerError.malformed, TowerError.listLimitReached: invalidSource = true
            default: invalidSource = false
            }
            if invalidSource || error is BriefingError || CachedContentFailure.invalidates(error) {
                snapshot = nil; await service.forget(); revision = await service.cacheRevision()
            }
            cached = snapshot != nil; loaded = true
            self.error = (error as? BriefingError)?.localizedDescription ?? "Couldn’t refresh Rick’s briefing. Try again when connected."
        }
    }
}
