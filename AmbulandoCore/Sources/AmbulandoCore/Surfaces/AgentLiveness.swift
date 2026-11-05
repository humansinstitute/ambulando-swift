import Foundation

// Live agent activity on the client (design "Tower-backed live agent activity", §7, §10, §11). Tower owns the lease
// deadline; this file only decides, against an estimate of Tower's clock, whether a lifecycle is still live, and merges
// snapshots and stream events of one lifecycle in an order-independent way. Nothing here ever infers "completed".

/// Tower's clock as seen from this device. A fresh response's `Date` header (or a top-level `server_time`) is anchored
/// to a monotonic clock that keeps running while the device sleeps, so a later wall-clock change on the device never
/// moves a lease. Replayed event timestamps are never used: they are not the current server time.
public final class ServerClock: @unchecked Sendable {
    public static let shared = ServerClock()

    private struct Anchor { var server: Date; var monotonic: UInt64; var uncertainty: TimeInterval }
    private let lock = NSLock()
    private var anchors: [String: Anchor] = [:]
    private var offsets: [String: TimeInterval] = [:]
    /// The device clock, replaceable in tests.
    private let wall: @Sendable () -> Date
    private let monotonic: @Sendable () -> UInt64

    public init(wall: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC) }) {
        self.wall = wall; self.monotonic = monotonic
    }

    /// Records a server time observed in a response that completed `roundTrip` seconds after it was requested. The
    /// midpoint of the request is the best estimate; a second-resolution `Date` header adds up to one second of
    /// uncertainty. A sample is kept only when it is at least as precise as the one it replaces, or the old one is
    /// older than ten minutes (drift).
    public func observe(origin: String, serverTime: Date, roundTrip: TimeInterval, resolution: TimeInterval) {
        let now = monotonic()
        let estimate = serverTime.addingTimeInterval(min(max(roundTrip, 0), 30) / 2)
        let uncertainty = resolution + max(roundTrip, 0) / 2
        lock.lock(); defer { lock.unlock() }
        if let old = anchors[origin], old.uncertainty < uncertainty, Double(now &- old.monotonic) / 1e9 < 600 { return }
        anchors[origin] = Anchor(server: estimate, monotonic: now, uncertainty: uncertainty)
        offsets[origin] = estimate.timeIntervalSince(wall())
    }

    /// The device-clock offset last observed for `origin` (server − device), for persistence across launches.
    public func offset(origin: String) -> TimeInterval? { lock.lock(); defer { lock.unlock() }; return offsets[origin] }

    /// A persisted offset for a cold launch, used only until this process has its own observation.
    public func restore(origin: String, offset: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if anchors[origin] == nil, offsets[origin] == nil { offsets[origin] = offset }
    }

    /// Tower's current time for `origin`: the monotonic anchor if this process has one, else the device clock with the
    /// persisted offset, else the device clock.
    public func now(origin: String?) -> Date {
        lock.lock(); defer { lock.unlock() }
        if let origin, let anchor = anchors[origin] {
            return anchor.server.addingTimeInterval(Double(monotonic() &- anchor.monotonic) / 1e9)
        }
        return wall().addingTimeInterval(origin.flatMap { offsets[$0] } ?? 0)
    }

    /// The device time at which Tower's clock for `origin` reads `server` (for scheduling a refresh at a deadline).
    public func local(_ server: Date, origin: String?) -> Date {
        let skew = now(origin: origin).timeIntervalSince(wall())
        return server.addingTimeInterval(-skew)
    }

    /// Parses an HTTP `Date` header (IMF-fixdate, RFC 9110 §5.6.7).
    public static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return httpDateFormatter.date(from: text)
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}

/// What a client shows for one lifecycle at a given server time (design §11).
public enum AgentActivityPhase: Sendable, Equatable {
    case queued(position: Int?)
    case working
    /// A live turn suspended on a human prompt.
    case waiting
    /// Non-terminal but its lease passed (plus grace): "Stopped responding". Never shown as finished.
    case stopped
    case completed, failed, cancelled

    public var isLive: Bool { switch self { case .queued, .working, .waiting: true; default: false } }
    public var isTerminal: Bool { switch self { case .completed, .failed, .cancelled: true; default: false } }
}

public enum AgentLiveness {
    /// Clients clear "working" at the lease deadline plus this grace (stream poll, delivery delay, clock estimate).
    public static let grace: TimeInterval = 15
    /// An expired lifecycle stays expanded this long after it stopped, then collapses into earlier activity.
    public static let stoppedDisplayWindow: TimeInterval = 10 * 60
    /// Live with no commentary for this long: "Still working · no update for N min" (presentational only).
    public static let quietThreshold: TimeInterval = 5 * 60
    /// While anything is live, screens re-evaluate at least this often (and exactly at the next clear point).
    public static let refreshInterval: TimeInterval = 5

    public static func phase(_ a: AgentActivityRecord, now: Date) -> AgentActivityPhase {
        switch a.state {
        case "completed": return .completed
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: break
        }
        if a.terminalAt != nil { return .completed }
        guard let clear = clearsAt(a), now < clear else { return .stopped }
        switch a.state {
        case "queued": return .queued(position: a.queuePosition)
        case "waiting": return .waiting
        default: return .working
        }
    }

    /// The server time at which a live lifecycle stops counting as live: its lease deadline plus grace, or nil when it
    /// has none (terminal, expired by Tower, or no lease at all).
    public static func clearsAt(_ a: AgentActivityRecord) -> Date? {
        guard !a.isTerminal, a.expiredAt == nil, let deadline = a.leaseExpiresAt else { return nil }
        return deadline.addingTimeInterval(grace)
    }

    /// The earliest clear point among `activities` still live at `now`: the moment a screen must re-evaluate.
    public static func nextChange(_ activities: [AgentActivityRecord], now: Date) -> Date? {
        activities.compactMap(clearsAt).filter { $0 > now }.min()
    }

    /// A turn in progress (working, or suspended on a human prompt) — not queued, stopped or finished.
    /// Parses a Tower timestamp (commentary and lifecycle times are in Tower's clock).
    public static func serverDate(_ text: String?) -> Date? { AgentActivityRecord.time(text) }

    public static func isWorking(_ a: AgentActivityRecord, now: Date) -> Bool {
        switch phase(a, now: now) { case .working, .waiting: true; default: false }
    }

    // MARK: Supersession

    /// Row ids of unsuccessful attempts (failed, cancelled, or stopped responding) that newer authoritative work has
    /// replaced in the current-activity UI. Scope is the same thread and the same agent; order is the lifecycle's
    /// immutable `created_at` (never `updated_at`, which a delayed or replayed event can bump), so an old row replayed
    /// late stays old. Any newer lifecycle that has begun (not queued) supersedes, whatever state it is in now: its
    /// existence is immutable evidence, so the successor completing, failing or its lease expiring never brings the older
    /// failure back. The newest attempt is never hidden, so a current failure or stopped turn stays visible.
    /// This is presentation only; messages, commentary and the stored rows are untouched.
    public static func supersededFailures(_ activities: [AgentActivityRecord], now: Date) -> Set<String> {
        var hidden: Set<String> = []
        for old in activities {
            let phase = phase(old, now: now)
            guard phase == .failed || phase == .cancelled || phase == .stopped, let oldAt = AgentActivityRecord.time(old.createdAt) else { continue }
            let replaced = activities.contains { new in
                guard new.id != old.id, new.threadId == old.threadId, new.agentNpub == old.agentNpub,
                      let newAt = AgentActivityRecord.time(new.createdAt), newAt > oldAt else { return false }
                // Raw state, not phase: an expired queued row classifies as stopped but never started.
                return new.state != "queued"
            }
            if replaced { hidden.insert(old.id) }
        }
        return hidden
    }

    // MARK: Merge

    /// Merges two copies of one lifecycle (same workspace row) whatever order they arrive in: state and commentary take
    /// the higher `sequence`, terminal always wins, the lease takes the higher `(lease_epoch, lease_sequence)` (or, for
    /// v1 rows, the lease of the higher-sequence copy), and an `expired_at` set for an epoch survives that epoch.
    /// Returns nil when `incoming` is a different turn of the same row (Tower forbids it; the stored lifecycle is kept).
    public static func merge(_ stored: AgentActivityRecord?, _ incoming: AgentActivityRecord) -> AgentActivityRecord? {
        guard let stored else { return incoming }
        if let a = stored.turnId, let b = incoming.turnId, a != b { return nil }
        let base: AgentActivityRecord
        if stored.isTerminal != incoming.isTerminal { base = stored.isTerminal ? stored : incoming }
        else { base = incoming.sequence >= stored.sequence ? incoming : stored }
        let other = base == incoming ? stored : incoming
        var lease = AgentLease(base)
        let theirs = AgentLease(other)
        if theirs.supersedes(lease) { lease = theirs }
        // An expiry recorded for an epoch survives every other copy of that epoch; only a higher epoch clears it.
        if lease.expiredAt == nil, let epoch = lease.epoch, theirs.epoch == epoch, let expired = theirs.expiredAt { lease.expiredAt = expired }
        return base.with(lease: lease, turnId: base.turnId ?? other.turnId)
    }
}

/// The lease fields of one lifecycle copy. v1 rows carry no epoch: their lease belongs to their snapshot sequence.
public struct AgentLease: Sendable, Equatable {
    public var epoch: Int?
    public var sequence: Int?
    public var expiresAt: Date?
    public var expiredAt: Date?

    public init(epoch: Int?, sequence: Int?, expiresAt: Date?, expiredAt: Date?) {
        self.epoch = epoch; self.sequence = sequence; self.expiresAt = expiresAt; self.expiredAt = expiredAt
    }

    init(_ a: AgentActivityRecord) { self.init(epoch: a.leaseEpoch, sequence: a.leaseSequence, expiresAt: a.leaseExpiresAt, expiredAt: a.expiredAt) }

    /// Whether this lease is newer than `other`. Only explicit lease ordering can replace the base copy's lease.
    func supersedes(_ other: AgentLease) -> Bool {
        guard let epoch, let sequence else { return false }
        guard let otherEpoch = other.epoch, let otherSequence = other.sequence else { return true }
        if epoch != otherEpoch { return epoch > otherEpoch }
        if sequence != otherSequence { return sequence > otherSequence }
        // Same renewal: an expiry recorded for it wins over a copy that has not seen the expiry.
        return expiredAt != nil && other.expiredAt == nil
    }
}

/// One public commentary entry of a lifecycle (`flightdeck_pg_agent_activity_commentary`). Tower stores only
/// user-visible `working` summaries; nothing else is ever shown.
public struct AgentCommentaryEntry: Sendable, Equatable, Identifiable {
    public let activityRowId: String
    public let turnId: String?
    public let sequence: Int
    /// Tower's per-row delivery cursor (decimal BIGINT), or nil for entries not delivered with one.
    public let deliveryCursor: String?
    public let label: String?
    public let summary: String?
    public let body: String?
    public let createdAt: String
    public var id: String { "\(activityRowId):\(sequence)" }

    /// The text shown: body, else summary, else label.
    public var text: String { body ?? summary ?? label ?? "" }

    public init(activityRowId: String, turnId: String?, sequence: Int, deliveryCursor: String?, label: String?, summary: String?, body: String?, createdAt: String) {
        self.activityRowId = activityRowId; self.turnId = turnId; self.sequence = sequence; self.deliveryCursor = deliveryCursor
        self.label = label; self.summary = summary; self.body = body; self.createdAt = createdAt
    }

    /// Parses one `commentary_history` entry of `activity`. Entries of another row or turn, or that are not
    /// user-visible working text, are refused.
    init?(json o: [String: Any], activity: AgentActivityRecord) {
        guard let sequence = flexibleInt(o["sequence"]), sequence >= 0 else { return nil }
        if let row = o["agent_activity_id"] as? String, lowerUUID(row) != activity.id { return nil }
        if let turn = o["turn_id"] as? String, let mine = activity.turnId, turn != mine { return nil }
        if let visibility = o["visibility"] as? String, visibility != "user_visible" { return nil }
        if let state = o["state"] as? String, state != "working" { return nil }
        func text(_ key: String) -> String? {
            guard let s = o[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let cursor = (o["delivery_cursor"] as? String) ?? flexibleInt(o["delivery_cursor"]).map(String.init)
        guard text("body") != nil || text("summary") != nil || text("label") != nil else { return nil }
        self.init(activityRowId: activity.id, turnId: (o["turn_id"] as? String) ?? activity.turnId, sequence: sequence,
                  deliveryCursor: cursor.flatMap { AgentCommentaryEntry.validCursor($0) ? $0 : nil },
                  label: text("label"), summary: text("summary"), body: text("body"), createdAt: (o["created_at"] as? String) ?? "")
    }

    /// A Tower delivery cursor: a non-negative decimal BIGINT.
    static func validCursor(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 19, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let n = Int64(text) else { return false }
        return n >= 0 && (text == "0" || !text.hasPrefix("0"))
    }
}
