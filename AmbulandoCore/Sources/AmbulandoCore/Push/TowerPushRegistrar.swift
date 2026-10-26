import Foundation

/// Registers through Tower with the signer's NIP-98 identity. `TowerClient` refuses to sign while the identity is
/// locked, so an upload cannot happen without the PIN.
public struct TowerPushRegistrar: PushRegistrar {
    private let transport: HTTPTransport
    private let signer: EventSigner

    public init(transport: HTTPTransport, signer: EventSigner) {
        self.transport = transport
        self.signer = signer
    }

    public func register(_ registration: PushRegistration, token: PushDeviceToken, origin: TowerOrigin, signerNpub: String) async throws -> PushAcknowledgement {
        let client = TowerClient(origin: origin, transport: transport, signer: signer)
        let request = try await registration.registerRequest(token: token, client: client)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw TowerError.http(status: response.statusCode, code: failure?["code"] as? String ?? failure?["error"] as? String, stage: "push registration")
        }
        return try PushRegistration.acknowledgement(fromResponse: data, token: token)
    }

    public func revoke(_ revocation: PendingPushRevocation) async -> Int? {
        guard let origin = try? TowerOrigin(revocation.origin),
              let registration = try? PushRegistration(workspaceId: revocation.workspaceId, appNpub: revocation.appNpub,
                                                       installationId: revocation.installationId, environment: .production, bundleId: "-"),
              let request = try? await registration.revokeRequest(client: TowerClient(origin: origin, transport: transport, signer: signer)),
              let (_, response) = try? await transport.send(request) else { return nil }
        return response.statusCode
    }
}
