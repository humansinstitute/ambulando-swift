import Foundation

/// One line of the local diagnostics log. Every field is chosen so it cannot carry a secret, a message body or a user
/// identifier; see `DiagnosticsRedactor`.
public struct DiagnosticEntry: Codable, Sendable, Equatable {
    public var at: Date
    /// "request", "retry", "recovered", "gave-up" or "trigger".
    public var kind: String
    /// "GET host /path/with/:id?query,keys" (no identifiers, no query values except a numeric `limit`).
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
    private static let idShapes = try! NSRegularExpression(pattern: "^v[0-9]+$")
    private static let word = try! NSRegularExpression(pattern: "^[a-z][a-z-]{0,39}$")
    private static let safeValue = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,64}$")

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Method, host and a path template: lowercase route words and `v4` are kept, every other segment (UUIDs, npubs,
    /// hex, file names, numbers) becomes `:id`. Query: parameter names only, plus a numeric `limit`.
    public static func endpoint(method: String, url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "\(method.uppercased()) unknown" }
        let path = components.path.split(separator: "/").map { segment -> String in
            let text = String(segment)
            return matches(word, text) || matches(idShapes, text) ? text : (text == ".well-known" || text == "nstack.json" ? text : ":id")
        }.joined(separator: "/")
        let names = (components.queryItems ?? []).map { item -> String in
            guard matches(word, item.name.replacingOccurrences(of: "_", with: "-")) else { return "?" }
            if item.name == "limit", let value = item.value, Int(value) != nil { return "limit=\(value)" }
            return item.name
        }.sorted()
        let host = components.host.map { matches(safeValue, $0) ? $0 : "host" } ?? "host"
        return "\(method.uppercased()) \(host)/\(path)" + (names.isEmpty ? "" : "?" + names.joined(separator: ","))
    }

    /// "NSURLErrorDomain -1001", an HTTP-derived "http 503", or the error's type name; never `localizedDescription`
    /// (a Foundation description can embed the full URL, including query values).
    public static func errorCode(_ error: Error) -> String {
        if let url = error as? URLError { return "NSURLErrorDomain \(url.code.rawValue)" }
        if case .http(let status, _, _)? = error as? TowerError { return "http \(status)" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "NSURLErrorDomain \(ns.code)" }
        if error is IdentityError { return "identity" }
        return "error"
    }

    /// First usable correlation header, restricted to a short token alphabet so a header cannot smuggle content.
    public static func correlation(_ response: HTTPURLResponse) -> String? {
        for name in ["x-request-id", "x-correlation-id", "cf-ray"] {
            if let value = response.value(forHTTPHeaderField: name), matches(safeValue, value) { return "\(name)=\(value)" }
        }
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
            "Entries: \(items.count) (newest \(capacity) kept; no keys, tokens, message text or account identifiers are recorded)",
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
