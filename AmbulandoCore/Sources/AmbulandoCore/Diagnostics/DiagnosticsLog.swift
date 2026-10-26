import Foundation

/// One line of the local diagnostics log. Every field is chosen so it cannot carry a secret, a message body or a user
/// identifier; see `DiagnosticsRedactor`.
public struct DiagnosticEntry: Codable, Sendable, Equatable {
    public var at: Date
    /// "request", "retry", "recovered", "gave-up" or "trigger".
    public var kind: String
    /// "GET host/path/with/:id?known,names": static route words only, no query values except a small numeric limit.
    public var endpoint: String
    public var durationMs: Int?
    /// "ok", "http", "failed", "cancelled" for requests; the retry outcome otherwise.
    public var outcome: String
    public var status: Int?
    /// "NSURLErrorDomain -1001" style code, never a localized message.
    public var errorCode: String?
    /// Server-assigned request or edge ID from a response header, when one was sent.
    public var correlation: String?
    public var note: String?

    public init(at: Date = Date(), kind: String, endpoint: String = "", durationMs: Int? = nil, outcome: String, status: Int? = nil,
                errorCode: String? = nil, correlation: String? = nil, note: String? = nil) {
        self.at = at; self.kind = kind; self.endpoint = endpoint; self.durationMs = durationMs; self.outcome = outcome
        self.status = status; self.errorCode = errorCode; self.correlation = correlation; self.note = note
    }
}

public enum DiagnosticsRedactor {
    /// Static route words of the Tower API this client calls. Any other path segment (ids, slugs, user names, file names,
    /// tokens, encoded text) is replaced, so a lowercase word is never trusted just because it looks like one.
    static let routeWords: Set<String> = [
        "api", "v4", "flightdeck-pg", "workspaces", "scopes", "channels", "messages", "threads", "tasks", "docs", "files", "file-folders",
        "members", "me", "scope-order", "resource-view-states", "reactions", "comments", "events", "event-stream", "stream", "edit-leases",
        "acquire", "renew", "release", "complete", "content", "body", "object", "storage", "prepare", "sync", "record-sync", "snapshot",
        "canvases", "components", "context", "references", "relationships", "naplets", "versions", "branches", "artifacts",
        "agent-activities", "autopilot-agents", "workspace-agents", "personal-wapps", "live", "mark-viewed", "priority", "state",
        "reorder", ".well-known", "nstack.json",
    ]
    /// Query parameter names this client sends. Values are never kept, except a small integer for the two limits.
    static let queryNames: Set<String> = ["channel_id", "cursor", "family", "history_limit", "include_archived", "limit", "row_version", "target_id", "target_type", "thread_id"]
    static let limitNames: Set<String> = ["limit", "history_limit"]

    private static let hostShape = try! NSRegularExpression(pattern: "^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")
    private static let familyShape = try! NSRegularExpression(pattern: "^[a-z][a-z-]{0,23}$")
    private static let uuidShape = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private static let cfRayShape = try! NSRegularExpression(pattern: "^[0-9a-f]{16}-[A-Z]{3}$")

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Method, host and a path template: only the static route words above are kept, every other segment (and anything
    /// percent-encoded) becomes `:id`. Query: known parameter names only (others become `?`), plus a small numeric limit.
    /// The host is the Tower address the user configured; it is the one deployment detail the export includes.
    public static func endpoint(method: String, url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "\(method.uppercased()) unknown" }
        let verb = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(method.uppercased()) ? method.uppercased() : "OTHER"
        let path = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map { segment -> String in
            routeWords.contains(String(segment)) ? String(segment) : ":id"
        }.joined(separator: "/")
        let names = (components.percentEncodedQueryItems ?? []).map { item -> String in
            guard queryNames.contains(item.name) else { return "?" }
            if limitNames.contains(item.name), let value = item.value, let n = Int(value), (0...1000).contains(n) { return "\(item.name)=\(n)" }
            return item.name
        }.sorted()
        let host = components.host.map { matches(hostShape, $0.lowercased()) ? $0.lowercased() : "host" } ?? "host"
        return "\(verb) \(host)/\(path)" + (names.isEmpty ? "" : "?" + names.joined(separator: ","))
    }

    /// A job family such as "inbox": accepted only in the plain lowercase shape the code's own job keys use.
    public static func family(_ text: String) -> String { matches(familyShape, text) ? text : "job" }

    /// "NSURLErrorDomain -1001", an HTTP-derived "http 503", or a fixed word; never `localizedDescription`
    /// (a Foundation description can embed the full URL, including query values).
    public static func errorCode(_ error: Error) -> String {
        if let url = error as? URLError { return "NSURLErrorDomain \(url.code.rawValue)" }
        if case .http(let status, _, _)? = error as? TowerError { return "http \(status)" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "NSURLErrorDomain \(ns.code)" }
        if error is IdentityError { return "identity" }
        return "error"
    }

    /// A correlation value only in a recognised format: a UUID for `x-request-id` / `x-correlation-id`, or Cloudflare's
    /// `cf-ray` (16 hex, dash, 3-letter datacentre). Anything else is omitted, never filtered into the log.
    public static func correlation(_ response: HTTPURLResponse) -> String? {
        for name in ["x-request-id", "x-correlation-id"] {
            if let value = response.value(forHTTPHeaderField: name), matches(uuidShape, value) { return "\(name)=\(value.lowercased())" }
        }
        if let value = response.value(forHTTPHeaderField: "cf-ray"), matches(cfRayShape, value) { return "cf-ray=\(value)" }
        return nil
    }
}

/// Bounded local log of recent Tower requests and recovery decisions, kept on this device and shared only when the
/// user chooses Export diagnostics. Nothing is uploaded automatically.
public actor DiagnosticsLog {
    public static let defaultCapacity = 300
    private let capacity: Int
    private let fileURL: URL?
    private var items: [DiagnosticEntry] = []
    private var loaded = false
    private var lastWrite = Date.distantPast

    public init(fileURL: URL?, capacity: Int = DiagnosticsLog.defaultCapacity) {
        self.fileURL = fileURL; self.capacity = max(1, capacity)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        items = ((try? decoder.decode([DiagnosticEntry].self, from: data)) ?? []).suffix(capacity).map { $0 }
    }

    public func record(_ entry: DiagnosticEntry) {
        load()
        items.append(entry)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
        // Failures are written at once; a steady stream of successes at most every few seconds.
        if entry.outcome != "ok" || Date().timeIntervalSince(lastWrite) > 5 { persist() }
    }

    public func entries() -> [DiagnosticEntry] { load(); return items }

    public func clear() { load(); items = []; persist() }

    private func persist() {
        lastWrite = Date()
        guard let fileURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Plain text for the share sheet: build and platform, UTC export time, then one line per entry (UTC).
    public func exportText(app: String, build: String, platform: String, system: String, now: Date = Date()) -> String {
        load()
        var lines = [
            "Ambulando diagnostics",
            "App: \(app) (\(build))   Platform: \(platform) \(system)",
            "Exported: \(Self.stamp(now)) UTC",
            "Entries: \(items.count) (newest \(capacity) kept; no keys, tokens, message text, record ids or user names; the Tower host name is included)",
            "",
        ]
        for entry in items {
            var parts = [Self.stamp(entry.at), entry.kind, entry.outcome]
            if !entry.endpoint.isEmpty { parts.append(entry.endpoint) }
            if let ms = entry.durationMs { parts.append("\(ms)ms") }
            if let status = entry.status { parts.append("status=\(status)") }
            if let code = entry.errorCode { parts.append("error=\(code)") }
            if let correlation = entry.correlation { parts.append(correlation) }
            if let note = entry.note { parts.append(note) }
            lines.append(parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
