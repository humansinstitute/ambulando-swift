import Foundation

/// One fixed execution allowance, including startup. Duplicate deliveries share work and every OS callback completes
/// once. The deadline never extends on another push; cancellation does not wait for an uncooperative network request.
@MainActor
public final class PushRefreshWindow {
    public enum Result: Sendable, Equatable { case newData, noData, failed }
    public typealias Work = @MainActor @Sendable () async -> Result
    private struct Request {
        var work: Work
        var events: Set<String>
        var again = false
        var changed = false
        var completions: [@MainActor (Result) -> Void]
    }
    private var requests: [String: Request] = [:]
    private var order: [String] = []
    private var active: String?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private let budget: Duration
    private let limit: Int

    public init(budget: Duration = .seconds(25), limit: Int = 5) { self.budget = budget; self.limit = limit }

    public func submit(key: String, event: String?, work: @escaping Work, completion: @escaping @MainActor (Result) -> Void) {
        if var request = requests[key] {
            // A distinct event during a fetch needs one rerun; the same APNs delivery needs none.
            if active == key, event == nil || !request.events.contains(event!) { request.again = true }
            if let event { request.events.insert(event) }
            request.work = work
            request.completions.append(completion)
            requests[key] = request
            return
        }
        guard requests.count < limit else { completion(.noData); return } // foreground catch-up remains authoritative
        requests[key] = Request(work: work, events: Set(event.map { [$0] } ?? []), completions: [completion])
        order.append(key)
        if timer == nil {
            let token = generation
            timer = Task { [weak self, budget] in
                do { try await Task.sleep(for: budget) } catch { return }
                guard let self, self.generation == token else { return }
                self.cancel()
            }
        }
        if worker == nil {
            let token = generation
            worker = Task { [weak self] in await self?.drain(token) }
        }
    }

    /// OS expiration, manual lock or account disconnect. Callbacks are drained before any late work can return.
    public func cancel() {
        generation = UUID()
        worker?.cancel(); worker = nil
        timer?.cancel(); timer = nil
        let callbacks = requests.values.flatMap(\.completions)
        requests.removeAll(); order.removeAll(); active = nil
        for callback in callbacks { callback(.failed) }
    }

    private func drain(_ token: UUID) async {
        while generation == token, let key = order.first, let request = requests[key] {
            active = key
            let result = await request.work()
            guard generation == token else { return }
            if result == .newData { requests[key]?.changed = true }
            if requests[key]?.again == true {
                requests[key]?.again = false
                continue
            }
            let finished = requests.removeValue(forKey: key)
            let callbacks = finished?.completions ?? []
            let final: Result = result == .noData && finished?.changed == true ? .newData : result
            order.removeFirst(); active = nil
            for callback in callbacks { callback(final) }
        }
        guard generation == token else { return }
        worker = nil; timer?.cancel(); timer = nil
        generation = UUID()
    }
}
