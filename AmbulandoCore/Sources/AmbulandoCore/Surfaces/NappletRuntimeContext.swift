import Foundation

/// Host policy, deliberately independent of the server manifest's wire encoding.
/// Audience is never used as a substitute for resource or personal capability grants.
public struct NappletRuntimeContext: Hashable, Sendable {
    public let origin: String
    public let tower: String
    public let service: String
    public let workspace: String
    public let app: String
    public let viewer: String
    public init(origin: String, tower: String, service: String, workspace: String, app: String, viewer: String) {
        self.origin = origin; self.tower = tower; self.service = service
        self.workspace = workspace; self.app = app; self.viewer = viewer
    }
}
