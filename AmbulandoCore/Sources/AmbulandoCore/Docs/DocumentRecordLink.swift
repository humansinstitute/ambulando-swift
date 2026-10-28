import Foundation

/// Canvas references keep the web's existing URL contract. They never select another workspace or grant access.
public enum DocumentRecordLink {
    public static func canvas(_ url: URL, workspaceId: String) -> String? {
        guard url.path == "/canvas.html", url.user == nil, url.password == nil, url.scheme == nil, url.host == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems,
              items.filter({ $0.name == "workspaceid" }).count == 1,
              items.filter({ $0.name == "canvasid" }).count == 1,
              let workspace = items.first(where: { $0.name == "workspaceid" })?.value,
              workspace.lowercased() == workspaceId.lowercased(),
              let canvas = items.first(where: { $0.name == "canvasid" })?.value,
              UUID(uuidString: canvas) != nil else { return nil }
        return canvas.lowercased()
    }
}
