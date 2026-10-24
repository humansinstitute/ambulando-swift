import Foundation
import os

/// os_signpost intervals for sync jobs, visible in Instruments ("Points of Interest"/custom logging).
public enum SyncSignposts {
    static let signposter = OSSignposter(subsystem: "studio.otherstuff.ambulando.native", category: "sync")

    public static func begin(_ key: String) -> OSSignpostIntervalState {
        signposter.beginInterval("sync-job", id: signposter.makeSignpostID(), "\(key, privacy: .public)")
    }

    public static func end(_ state: OSSignpostIntervalState) { signposter.endInterval("sync-job", state) }
}

public struct LatencyReport: Sendable, CustomStringConvertible {
    public let samples: [Double]  // milliseconds

    public init(samples: [Double]) { self.samples = samples.sorted() }

    public func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let index = Swift.min(samples.count - 1, Swift.max(0, Int((p / 100 * Double(samples.count)).rounded(.up)) - 1))
        return samples[index]
    }

    public var max: Double { samples.last ?? 0 }
    public var count: Int { samples.count }

    public var description: String {
        String(format: "n=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms", count, percentile(50), percentile(95), percentile(99), max)
    }
}

/// Measures how long the main actor takes to start a submitted job while other work runs: a direct
/// proxy for "would a keystroke, scroll or frame callback have been delayed?". Samples are taken from a
/// background task (hop onto the main actor and back), so the probe itself never sleeps on the main actor.
/// Used by the sync-storm budget tests and available to a debug overlay.
public enum MainActorProbe {
    public static func measure(interval: Duration = .milliseconds(2), until done: @escaping @Sendable () async -> Bool) async -> LatencyReport {
        await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            var samples: [Double] = []
            while await !done() {
                let start = clock.now
                await MainActor.run {}
                let elapsed = clock.now - start
                samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                try? await Task.sleep(for: interval)
            }
            return LatencyReport(samples: samples)
        }.value
    }
}

/// Measures wall-clock latency of a block, in milliseconds.
public func measureMilliseconds<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    let elapsed = clock.now - start
    return (value, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
}
