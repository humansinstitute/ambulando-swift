import Foundation

/// APNs environment a device token belongs to. A token from one environment is rejected by the other.
public enum PushEnvironment: String, Sendable, Codable, Equatable {
    case sandbox, production

    /// Development-signed builds use the sandbox; TestFlight and App Store builds use production.
    public static func `default`(debugBuild: Bool) -> Self { debugBuild ? .sandbox : .production }
}

/// What the lock screen may show. Generic is the default: Tower sends neutral alert text with no message content.
public enum PushPreview: String, Sendable, Codable, Equatable {
    case generic, full
}

/// The user's notification choices. Locking keeps the registration unless the user turns that off; signing stays
/// locked either way, so renewals wait for unlock and the server lease bounds delivery meanwhile.
public struct PushSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var keepWhileLocked: Bool
    public var preview: PushPreview

    public init(enabled: Bool = false, keepWhileLocked: Bool = true, preview: PushPreview = .generic) {
        self.enabled = enabled
        self.keepWhileLocked = keepWhileLocked
        self.preview = preview
    }
}

/// An APNs device token as lowercase hex. It is sent only in the registration body and never logged in full.
public struct PushDeviceToken: Sendable, Equatable {
    public let hex: String
    public var suffix: String { String(hex.suffix(6)) }

    public init(data: Data) throws { try self.init(hex: data.hex) }

    public init(hex: String) throws {
        let lower = hex.lowercased()
        guard (64...200).contains(lower.count), lower.count.isMultiple(of: 2),
              lower.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw TowerError.malformed("device token") }
        self.hex = lower
    }
}

/// One installation's registration on one Tower origin. Tower records the NIP-98 signer as the owner; presenting a
/// token never changes another actor's row. Every registration carries a bounded lease so delivery stops by itself
/// if renewal or revocation never arrives.
public struct PushRegistration: Sendable, Equatable {
    public static let defaultLeaseSeconds = 7 * 24 * 3600
    public static let maximumLeaseSeconds = 30 * 24 * 3600

    public let workspaceId: String
    public let appNpub: String
    public let installationId: String
    public let environment: PushEnvironment
    public let bundleId: String
    public let preview: PushPreview
    public let leaseSeconds: Int
    /// Presentation routing only (contract: not an attestation). Tower's audience rules use it to pick this app's alerts.
    public let clientAppId: String
    public let platform: String
    public let appVersion: String?

    public init(workspaceId: String, appNpub: String, installationId: String, environment: PushEnvironment,
                bundleId: String, preview: PushPreview = .generic, leaseSeconds: Int = defaultLeaseSeconds,
                clientAppId: String = "ambulando", platform: String = "ios", appVersion: String? = nil) throws {
        guard !bundleId.isEmpty, (1...Self.maximumLeaseSeconds).contains(leaseSeconds) else { throw TowerError.malformed("push registration") }
        self.workspaceId = try TowerAPI.uuid(workspaceId).lowercased()
        self.installationId = try TowerAPI.uuid(installationId).lowercased()
        self.appNpub = appNpub
        self.environment = environment
        self.bundleId = bundleId
        self.preview = preview
        self.leaseSeconds = leaseSeconds
        self.clientAppId = clientAppId
        self.platform = platform
        self.appVersion = appVersion
    }

    public var path: String {
        get throws { try TowerAPI.base(workspaceId) + "/notifications/apns-devices/" + installationId }
    }

    /// Exact body bytes (sorted keys) so the NIP-98 payload hash covers what is sent.
    public func body(token: PushDeviceToken) throws -> Data {
        // Registering is only ever done once the person has allowed alerts, so the permission is stated as granted;
        // a later denial withdraws the registration instead of being reported here.
        var object: [String: Any] = [
            "device_token": token.hex, "environment": environment.rawValue, "bundle_id": bundleId,
            "preview": preview.rawValue, "lease_seconds": leaseSeconds,
            "client_app_id": clientAppId, "platform": platform, "permission_state": "granted",
        ]
        if let appVersion, !appVersion.isEmpty { object["app_version"] = String(appVersion.prefix(64)) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// `PUT …/notifications/apns-devices/:installation_id`, signed. Throws `IdentityError.locked` while locked.
    public func registerRequest(token: PushDeviceToken, client: TowerClient) async throws -> URLRequest {
        try await client.signed(method: "PUT", path: try path, query: [], appNpub: appNpub, jsonBody: try body(token: token))
    }

    /// `DELETE …/notifications/apns-devices/:installation_id`, signed, for this signer's row only.
    public func revokeRequest(client: TowerClient) async throws -> URLRequest {
        try await client.signed(method: "DELETE", path: try path, query: [], appNpub: appNpub, jsonBody: nil)
    }

    /// Reads Tower's acknowledgement. A reply that echoes the full token is treated as malformed. `delivery` is absent
    /// from older Towers; then readiness is unknown rather than assumed.
    public static func acknowledgement(fromResponse data: Data, token: PushDeviceToken) throws -> PushAcknowledgement {
        guard String(decoding: data, as: UTF8.self).lowercased().contains(token.hex) == false,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device"] as? [String: Any], let text = device["lease_expires_at"] as? String,
              let date = ISO8601DateFormatter.tower.date(from: text) else { throw TowerError.malformed("push registration") }
        let delivery = object["delivery"] as? [String: Any]
        return PushAcknowledgement(leaseExpiresAt: date, deliveryReady: delivery?["ready"] as? Bool, deliveryReason: delivery?["reason"] as? String)
    }

    public static func leaseExpiry(fromResponse data: Data, token: PushDeviceToken) throws -> Date {
        try acknowledgement(fromResponse: data, token: token).leaseExpiresAt
    }
}

/// What Tower said about one registration. `deliveryReady == false` is the truthful "registered, but nothing will be
/// sent yet" (no provider key, environment not enabled, alerts denied); it must never be shown as "on".
public struct PushAcknowledgement: Sendable, Equatable, Codable {
    public let leaseExpiresAt: Date
    public let deliveryReady: Bool?
    public let deliveryReason: String?

    public init(leaseExpiresAt: Date, deliveryReady: Bool? = nil, deliveryReason: String? = nil) {
        self.leaseExpiresAt = leaseExpiresAt
        self.deliveryReady = deliveryReady
        self.deliveryReason = deliveryReason
    }
}

/// A server revocation still owed after Disconnect, Remove identity or turning notifications off. It is stored before
/// the local unregister, retried with backoff while a signer is available, and dropped once the lease has run out,
/// because Tower stops delivering to an unrenewed registration by then anyway.
public struct PendingPushRevocation: Sendable, Codable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case done
        case retry(at: Date)
        case leaseExpired
    }

    public let origin: String
    public let workspaceId: String
    public let appNpub: String
    public let installationId: String
    public let signerNpub: String
    public let leaseExpiresAt: Date
    public private(set) var attempts: Int
    public private(set) var nextAttemptAt: Date

    public init(origin: TowerOrigin, workspaceId: String, appNpub: String, installationId: String, signerNpub: String,
                leaseExpiresAt: Date, now: Date) {
        self.origin = origin.description
        self.workspaceId = workspaceId
        self.appNpub = appNpub
        self.installationId = installationId
        self.signerNpub = signerNpub
        self.leaseExpiresAt = leaseExpiresAt
        attempts = 0
        nextAttemptAt = now
    }

    /// Records one attempt. `status` is nil for a transport failure. 2xx and 404 (no active row) are done; anything
    /// else retries, 30 s doubling to at most an hour, until the lease ends.
    public mutating func record(status: Int?, now: Date) -> Outcome {
        if let status, (200..<300).contains(status) || status == 404 { return .done }
        attempts += 1
        guard now < leaseExpiresAt else { return .leaseExpired }
        let delay = min(30 * pow(2, Double(min(attempts - 1, 12))), 3600)
        nextAttemptAt = min(now.addingTimeInterval(delay), leaseExpiresAt)
        return .retry(at: nextAttemptAt)
    }
}
