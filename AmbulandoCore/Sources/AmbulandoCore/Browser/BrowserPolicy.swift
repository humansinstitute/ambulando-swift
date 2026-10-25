import Foundation

/// What the in-app browser does with an address. Pages are HTTPS only; a few schemes that belong to other apps (mail,
/// phone, messages, FaceTime, Lightning wallets, Nostr clients) are handed to iOS after the user confirms; everything
/// else is refused. Subframes may also use the local schemes pages build themselves (`about:`, `data:`, `blob:`).
public enum BrowserURLPolicy {
    public enum Decision: Equatable, Sendable {
        case load
        case external(URL)
        case refuse(String)
    }

    public static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio", "lightning", "nostr"]
    static let frameSchemes: Set<String> = ["about", "data", "blob"]
    static let knownSchemes: Set<String> = externalSchemes.union(frameSchemes).union(["http", "file", "javascript", "ftp", "ws", "wss", "storage"])

    public static func decide(_ url: URL, mainFrame: Bool) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "https" {
            return httpsProblem(url).map(Decision.refuse) ?? .load
        }
        // `about:blank` is where `window.open()` and empty frames start; it has no origin of its own to sign for.
        if scheme == "about", ["blank", "srcdoc"].contains(url.absoluteString.dropFirst("about:".count).lowercased()) { return .load }
        if !mainFrame, frameSchemes.contains(scheme) { return .load }
        if externalSchemes.contains(scheme) { return .external(url) }
        if scheme == "http" { return .refuse("Only secure (HTTPS) pages open in the Ambulando browser.") }
        return .refuse("Ambulando does not open \(scheme.isEmpty ? "this" : scheme + ":") addresses.")
    }

    /// Why an HTTPS address is not loaded, or nil.
    static func httpsProblem(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host, !host.isEmpty else {
            return "This address has no host."
        }
        if components.user != nil || components.password != nil { return "Addresses with a user name or password are not opened." }
        if host.lowercased().hasSuffix(".fips") { return "FIPS addresses are not available in the iPhone app." }
        return nil
    }

    /// `https://host[:port]` of a page that can use `window.nostr`, or nil.
    public static func origin(of url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", httpsProblem(url) == nil, let host = url.host?.lowercased() else { return nil }
        return origin(scheme: "https", host: host, port: url.port ?? 0)
    }

    /// The origin string for WebKit's `WKSecurityOrigin` parts (port 0 means the scheme's default).
    public static func origin(scheme: String, host: String, port: Int) -> String? {
        guard scheme.lowercased() == "https", !host.isEmpty else { return nil }
        let base = "https://\(host.lowercased())"
        return port == 0 || port == 443 ? base : "\(base):\(port)"
    }

    /// What the address field opens: an HTTPS URL as typed, a bare host or path with `https://` added, or nil (a plain
    /// `http://` address, a refused scheme or text that is not an address).
    public static func typedAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "https" { return decide(url, mainFrame: true) == .load ? url : nil }
            // Any other scheme the browser knows is not a page to open from the address field. Text such as
            // "example.com:8443/x" parses with a "scheme" of "example.com" and is treated as a host below.
            if knownSchemes.contains(scheme) { return nil }
        }
        guard trimmed.contains("."), let url = URL(string: "https://" + trimmed), decide(url, mainFrame: true) == .load else { return nil }
        return url
    }
}
