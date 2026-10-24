import XCTest
@testable import AmbulandoCore

/// Budget test from docs/architecture.md §5: a 20k-message sync storm (decode + batched upserts) must not
/// delay the main actor or starve the screen's reads. Thresholds are the documented budgets, not tuned to pass.
final class SyncStormTests: XCTestCase {
    static let total = 20_000
    static let batch = 500

    func payloads() -> [Data] {
        (0..<Self.total).map { i in
            Fixtures.json([
                "id": UUID().uuidString.lowercased(), "workspace_id": Fixtures.workspaceId,
                "channel_id": i % 4 == 0 ? Fixtures.channel1 : Fixtures.channel2, "thread_id": NSNull(),
                "body": "Storm message \(i) " + String(repeating: "lorem ipsum ", count: 12),
                "sender_npub": TestKeys.npub, "created_at": String(format: "2026-10-01T%02d:%02d:%02d.%03dZ", (i / 3600) % 24, (i / 60) % 60, i % 60, i % 1000),
                "updated_at": "2026-10-01T00:00:00.000Z", "row_version": 1, "record_state": "active",
                "attachments": [], "metadata": ["mentions": []],
            ])
        }
    }

    func testProbeBaselineWithoutStorm() async throws {
        let done = DoneFlag()
        Task { try await Task.sleep(for: .milliseconds(300)); await done.set() }
        let idle = await MainActorProbe.measure { await done.value }
        print("SyncStorm baseline main-actor latency (no storm): \(idle)")
        // Sanity only (the probe produces samples). Timer coalescing stretches the 2 ms probe sleep to ~12 ms on a
        // busy host, so ~21–25 samples in 300 ms is normal; the latency budgets are asserted in the storm test.
        XCTAssertGreaterThanOrEqual(idle.count, 10)
    }

    /// Negative control: the probe must detect a deliberately blocked main actor, or the budget test proves nothing.
    func testProbeDetectsMainActorStall() async throws {
        let done = DoneFlag()
        Task {
            try await Task.sleep(for: .milliseconds(50))
            await MainActor.run { Thread.sleep(forTimeInterval: 0.06) }
            try await Task.sleep(for: .milliseconds(50))
            await done.set()
        }
        let report = await MainActorProbe.measure { await done.value }
        print("SyncStorm negative control (60 ms main stall): \(report)")
        XCTAssertGreaterThanOrEqual(report.max, 30)
    }

    func testMainActorAndReadsStayWithinBudgetDuringStorm() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let raw = payloads()
        let done = DoneFlag()

        // Writer: decode + upsert on a detached task, like a SyncEngine job.
        let total = Self.total, batch = Self.batch
        let writer = Task.detached(priority: .utility) { () -> Double in
            let clock = ContinuousClock(), began = clock.now
            for start in stride(from: 0, to: total, by: batch) {
                let records = try raw[start..<min(start + batch, total)].map(MessageRecord.init(raw:))
                try await store.writer.upsertMessages(records)
            }
            await done.set()
            let elapsed = clock.now - began
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }

        // Reader: the visible chat screen re-querying its window, as a coalesced observer would.
        let reader = Task.detached(priority: .userInitiated) { () -> LatencyReport in
            var samples: [Double] = []
            while await !done.value {
                let (_, ms) = try await measureMilliseconds {
                    try await store.reader.latestMessages(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, limit: 50)
                }
                samples.append(ms)
                try await Task.sleep(for: .milliseconds(5))
            }
            return LatencyReport(samples: samples)
        }

        let main = await MainActorProbe.measure { await done.value }
        let writeMs = try await writer.value
        let reads = try await reader.value
        let stored = try await store.reader.messageCount(workspaceId: Fixtures.workspaceId)

        print("SyncStorm: \(Self.total) messages in \(String(format: "%.0f", writeMs)) ms (\(Self.total / Self.batch) transactions)")
        print("SyncStorm main-actor latency: \(main)")
        print("SyncStorm screen read latency: \(reads)")
        XCTAssertEqual(stored, Self.total)
        XCTAssertGreaterThan(main.count, 20, "probe ran throughout the storm")
        XCTAssertGreaterThan(reads.count, 10, "reader ran throughout the storm")
        XCTAssertLessThanOrEqual(main.percentile(99), 16, "main-actor p99 latency budget")
        XCTAssertLessThanOrEqual(main.max, 50, "main-actor max latency budget")
        XCTAssertLessThanOrEqual(reads.percentile(95), 25, "screen read p95 budget")
    }
}

actor DoneFlag {
    private(set) var value = false
    func set() { value = true }
}
