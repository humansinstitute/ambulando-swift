import AppKit
import Darwin

/// Content-free, bounded evidence for a recurrence. No accounts, record IDs, text, URLs or credentials.
/// A watchdog can write while the main thread is stuck; its breadcrumb stack is the last measured
/// UI owner, NOT a sample of the stalled thread. Use macOS `sample` for the latter.
final class MacHangDiagnostics: @unchecked Sendable {
    static let shared = MacHangDiagnostics()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    // Uptime deliberately excludes sleep; wake must not be diagnosed as time spent hung.
    private static var uptime: Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
    private var beat = MacHangDiagnostics.uptime
    private var lastStackAt = 0.0
    private var owner = "startup"
    private var stack: [String] = []
    private var mode = "startup"
    private var reported = false
    private var writes = 0
    private var timer: DispatchSourceTimer?
    private var heartbeat: Timer?
    private var wakeObserver: NSObjectProtocol?

    func mark(_ label: StaticString) {
        let name = label.description
        let now = Self.uptime
        lock.lock()
        counts[name, default: 0] += 1
        let capture = now - lastStackAt >= 10
        lock.unlock()
        if capture {
            let frames = Thread.callStackSymbols.prefix(20).map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            lock.withLock { lastStackAt = now; owner = name; stack = frames }
        }
    }

    func gauge(_ label: StaticString, _ value: Int) { lock.withLock { counts[label.description] = value } }

    func snapshot() -> [String: Int] { lock.withLock { counts } }

    @MainActor func start() {
        guard heartbeat == nil else { return }
        let pulse = Timer(timeInterval: 0.5, repeats: true) { [self] _ in
            let currentMode = RunLoop.current.currentMode?.rawValue ?? "none"
            lock.withLock { beat = Self.uptime; mode = currentMode; reported = false }
        }
        // Divider and menu tracking must keep ticking too; default-mode-only timers report false hangs.
        RunLoop.main.add(pulse, forMode: .common)
        RunLoop.main.add(pulse, forMode: .eventTracking)
        heartbeat = pulse
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [self] _ in
            lock.withLock { beat = Self.uptime; reported = false }
        }
        let worker = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "studio.otherstuff.ambulando.hang-diagnostics", qos: .utility))
        worker.schedule(deadline: .now() + 1, repeating: 1)
        worker.setEventHandler { @Sendable [self] in check() }
        timer = worker
        worker.resume()
    }

    private func check() {
        let now = Self.uptime
        lock.lock()
        let delay = now - beat
        guard delay >= 4, !reported, writes < 8 else { lock.unlock(); return }
        reported = true
        let slot = writes; writes += 1
        let evidence: [String: Any] = ["version": 1, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "timestamp": ISO8601DateFormatter().string(from: Date()), "heartbeatDelaySeconds": delay,
            "lastRunLoopMode": mode, "counts": counts, "lastMeasuredOwner": owner,
            "breadcrumbStackAgeSeconds": now - lastStackAt, "breadcrumbStackNotHangSample": stack]
        lock.unlock()
        // Fixed eight slots across launches, atomic replacement, at most 16 KiB each. Caches are expendable.
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = root.appendingPathComponent("AmbulandoHangDiagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            guard data.count <= 16_384 else { return }
            try data.write(to: directory.appendingPathComponent("hang-\(slot).json"), options: .atomic)
        } catch { /* Diagnostics must never interfere with app work. */ }
    }
}
