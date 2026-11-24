import Foundation

/// A capped-group invitation code. It is a bearer secret: its text never appears in `description`, debug output, errors,
/// diagnostics or analytics. The only places the raw value is read are the create-intent request body and the device-only draft.
public struct OnboardingInviteCode: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public var description: String { "inv_••••" }
    public var debugDescription: String { "OnboardingInviteCode(redacted)" }

    /// NStack issues `inv_` + base64url; the server accepts 8...200 characters.
    public init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("inv_"), (8...200).contains(value.count),
              value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        rawValue = value
    }
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let code = Self(text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid invite")) }
        self = code
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// What a pasted invitation contains. NStack defines no invitation link format (only the code itself), so a pasted https link is
/// accepted only as a *claim* about which Tower to use: the origin is a suggestion the user must confirm, it is checked against the
/// Tower's own service descriptor before anything is signed, and nothing is ever sent to it automatically.
public struct OnboardingInviteInput: Sendable, Equatable {
    public let code: OnboardingInviteCode
    public let suggestedOrigin: TowerOrigin?

    public static func parse(_ text: String) -> OnboardingInviteInput? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = OnboardingInviteCode(value) { return OnboardingInviteInput(code: code, suggestedOrigin: nil) }
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, let host = components.host, !host.isEmpty else { return nil }
        let items = (components.queryItems ?? []) + (components.fragment.flatMap { fragment in
            URLComponents(string: "?" + fragment)?.queryItems
        } ?? [])
        let codes = items.filter { $0.name == "invite" }.compactMap { $0.value }.compactMap(OnboardingInviteCode.init)
        guard codes.count == 1, items.filter({ $0.name == "invite" }).count == 1 else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"; origin.host = host; origin.port = components.port
        guard let originString = origin.url?.absoluteString, let tower = try? TowerOrigin(originString) else { return nil }
        return OnboardingInviteInput(code: codes[0], suggestedOrigin: tower)
    }
}
