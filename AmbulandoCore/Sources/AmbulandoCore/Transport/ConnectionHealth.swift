import Foundation

/// Which failures mean "the connection is bad right now" (worth showing as connection status and retrying a read),
/// as opposed to a refusal or a bug (auth, validation, malformed data), which a retry cannot fix.
public enum ConnectionFailure {
    static let urlCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                                               .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff]
    /// Gateway statuses a proxy or edge returns when the origin is unreachable or too slow.
    static let gatewayStatuses: Set<Int> = [502, 503, 504]

    public static func isTransient(_ error: Error) -> Bool {
        if let url = error as? URLError { return urlCodes.contains(url.code) }
        if case .http(let status, _, _)? = error as? TowerError { return gatewayStatuses.contains(status) }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && urlCodes.contains(URLError.Code(rawValue: ns.code))
    }

    public static func isTransient(status: Int) -> Bool { gatewayStatuses.contains(status) }
}

/// Tracks whether the most recent Tower request reached a working server. Any real response (even a 401 or 404)
/// proves the network path works; a timeout, dropped connection or gateway error marks it failing until the next response.
public actor ConnectionHealth {
    public private(set) var failing = false
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init() {}

    public func updates() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(failing)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    func record(failing now: Bool) {
        guard now != failing else { return }
        failing = now
        for observer in observers.values { observer.yield(now) }
    }
}

/// Wraps the Tower transport to feed `ConnectionHealth` and the diagnostics log. It never alters a request or response
/// and never retries: the signed request goes out exactly once per call.
public struct ObservedTransport: HTTPTransport {
    let base: HTTPTransport
    let health: ConnectionHealth
    let log: DiagnosticsLog

    public init(_ base: HTTPTransport, health: ConnectionHealth, log: DiagnosticsLog) {
        self.base = base; self.health = health; self.log = log
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let clock = ContinuousClock()
        let started = clock.now
        let endpoint = DiagnosticsRedactor.endpoint(method: request.httpMethod ?? "GET", url: request.url)
        func millis() -> Int { let d = started.duration(to: clock.now); return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
        do {
            let (data, response) = try await base.send(request)
            await health.record(failing: ConnectionFailure.isTransient(status: response.statusCode))
            await log.record(DiagnosticEntry(kind: "request", endpoint: endpoint, durationMs: millis(), outcome: (200..<300).contains(response.statusCode) ? "ok" : "http",
                                             status: response.statusCode, correlation: DiagnosticsRedactor.correlation(response)))
            return (data, response)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                await log.record(DiagnosticEntry(kind: "request", endpoint: endpoint, durationMs: millis(), outcome: "cancelled"))
            } else {
                if ConnectionFailure.isTransient(error) { await health.record(failing: true) }
                await log.record(DiagnosticEntry(kind: "request", endpoint: endpoint, durationMs: millis(), outcome: "failed", errorCode: DiagnosticsRedactor.errorCode(error)))
            }
            throw error
        }
    }
}
