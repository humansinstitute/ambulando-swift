import QuartzCore
#if os(iOS)
import UIKit
#endif

/// Frame pacing during a measurement window (sample-data diagnostics). A `CADisplayLink` callback records the gap
/// between frames; a gap above 1.5 frame durations is a hitch, counted in Apple's "hitch time ratio" style
/// (hitch milliseconds per second of the window). The simulator's display timing is not an iPhone's, so these are
/// relative numbers for storm-versus-control comparison.
@MainActor
final class FrameMonitor: NSObject {
    #if os(iOS)
    private var link: CADisplayLink?
    #endif
    private var last: CFTimeInterval?
    private var started: CFTimeInterval = 0
    private(set) var gaps: [(at: Double, gap: Double)] = []
    private var expected = 1.0 / 60

    func start() {
        #if os(iOS)
        stop()
        gaps = []
        last = nil
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        #endif
    }

    #if os(iOS)
    @objc private func tick(_ link: CADisplayLink) {
        let duration = link.targetTimestamp - link.timestamp
        if duration > 0 { expected = duration }
        if let last { gaps.append((at: (link.timestamp - started) * 1000, gap: (link.timestamp - last) * 1000)) }
        last = link.timestamp
    }

    #endif

    func stop() {
        #if os(iOS)
        link?.invalidate(); link = nil
        #endif
    }

    struct Summary {
        let frames: Int
        let maxGap: Double
        let hitchRatio: Double
        let hitches: Int
        let worst: [(at: Double, gap: Double)]
    }

    func summary() -> Summary {
        let frameMs = expected * 1000
        let window = max((gaps.last?.at ?? 0) / 1000, 0.001)
        let hitchy = gaps.filter { $0.gap > frameMs * 1.5 }
        let hitchMs = hitchy.reduce(0) { $0 + ($1.gap - frameMs) }
        return Summary(frames: gaps.count, maxGap: gaps.map(\.gap).max() ?? 0, hitchRatio: hitchMs / window, hitches: hitchy.count,
                       worst: Array(gaps.sorted { $0.gap > $1.gap }.prefix(3)))
    }
}
