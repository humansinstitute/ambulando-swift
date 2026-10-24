import Foundation

public enum TowerError: LocalizedError, Equatable, Sendable {
    case unsafeOrigin
    case fipsNotSupported
    case unsafePath
    case http(status: Int, code: String?, stage: String?)
    case malformed(String)
    case listLimitReached(String)
    case descriptor(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeOrigin: "Use an HTTPS origin without credentials, path, query or fragment."
        case .fipsNotSupported: "This iPhone app connects over HTTPS only. FIPS (.fips) endpoints need the Wingman app shell; nothing was sent over another transport."
        case .unsafePath: "Refused a request outside the Tower API."
        case .http(let status, let code, let stage):
            "Tower returned HTTP \(status)" + (stage.map { " during \($0)" } ?? "") + (code.map { " (\(TowerClient.summary($0)))" } ?? "") + "."
        case .malformed(let what): "Tower returned an unexpected \(what) response."
        case .listLimitReached(let what): "Tower returned a full page of \(what) without a continuation cursor; the list may be incomplete."
        case .descriptor(let reason): "nStack descriptor rejected: \(reason)."
        }
    }
}

/// Validated HTTPS Tower origin. FIPS hosts are refused explicitly: the user selected HTTPS,
/// and this client never falls back across a transport boundary.
public struct TowerOrigin: Sendable, Hashable, Codable, CustomStringConvertible {
    public let url: URL
    public var description: String { url.absoluteString }

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { throw TowerError.unsafeOrigin }
        if host.lowercased().hasSuffix(".fips") { throw TowerError.fipsNotSupported }
        guard components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw TowerError.unsafeOrigin }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host.lowercased()
        normalized.port = components.port == 443 ? nil : components.port
        guard let url = normalized.url else { throw TowerError.unsafeOrigin }
        self.url = url
    }

    /// Absolute URL for an exact API path plus optional query items.
    public func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard path.hasPrefix("/api/v4/") || path == "/.well-known/nstack.json", !path.contains(".."), !path.contains("?"), !path.contains("#") else {
            throw TowerError.unsafePath
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url, result.host == url.host, result.scheme == "https" else { throw TowerError.unsafePath }
        return result
    }
}

/// Minimal transport seam: production uses URLSession; tests inject a recorder.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(timeout: TimeInterval = 45) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Delegate callbacks run on URLSession's own serial queue, never the main queue.
        session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TowerError.malformed("non-HTTP") }
        return (data, http)
    }
}

/// Signed Tower API client. Each request gets a fresh NIP-98 event over the exact bytes sent.
public struct TowerClient: Sendable {
    public let origin: TowerOrigin
    let transport: HTTPTransport
    let signer: EventSigner?

    public init(origin: TowerOrigin, transport: HTTPTransport, signer: EventSigner?) {
        self.origin = origin
        self.transport = transport
        self.signer = signer
    }

    static func summary(_ detail: String) -> String {
        let line = detail.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    static func stage(_ path: String) -> String? {
        if path == "/.well-known/nstack.json" { return "service discovery" }
        if path.hasSuffix("/flightdeck-pg/workspaces") { return "workspace discovery" }
        if path.hasSuffix("/scopes") { return "scope list" }
        if path.hasSuffix("/channels") { return "channel list" }
        if path.hasSuffix("/messages") { return "messages" }
        return nil
    }

    /// Unsigned GET for public metadata (the nStack descriptor only).
    public func getPublic(path: String) async throws -> Data {
        guard path == "/.well-known/nstack.json" else { throw TowerError.unsafePath }
        var request = URLRequest(url: try origin.url(path: path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request, path: path)
    }

    public func request(method: String = "GET", path: String, query: [URLQueryItem] = [], appNpub: String? = nil,
                        jsonBody: Data? = nil) async throws -> Data {
        guard let signer else { throw IdentityError.locked }
        try Task.checkCancellation()
        let url = try origin.url(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.httpBody = jsonBody
        request.setValue(try await NIP98.authorization(url: url, method: method, body: jsonBody, signer: signer), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let appNpub { request.setValue(appNpub, forHTTPHeaderField: "x-flightdeck-pg-app-npub") }
        if jsonBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await perform(request, path: path)
    }

    private func perform(_ request: URLRequest, path: String) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw TowerError.http(status: response.statusCode, code: failure?["code"] as? String ?? failure?["error"] as? String,
                                  stage: Self.stage(path))
        }
        return data
    }

    /// Reads every page of a list route. Tower list routes cap `limit` at 200 and some return
    /// `next_cursor: null` always, so a full page without a cursor is reported, not silently truncated.
    public func list(path: String, appNpub: String?, key: String) async throws -> [Data] {
        var rows: [Data] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let data = try await request(path: path, query: query, appNpub: appNpub)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let page = object[key] as? [[String: Any]] else { throw TowerError.malformed(key) }
            for row in page { rows.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) }
            cursor = object["next_cursor"] as? String
            if let cursor {
                guard !cursor.isEmpty, seen.insert(cursor).inserted else { throw TowerError.malformed("\(key) cursor") }
            } else if object["has_more"] as? Bool == true || page.count >= 200 {
                throw TowerError.listLimitReached(key)
            }
        } while cursor != nil
        return rows
    }
}
