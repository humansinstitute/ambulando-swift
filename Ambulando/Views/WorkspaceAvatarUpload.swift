import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceAvatarUpload: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    @Binding var avatar: String
    @State private var importing = false
    @State private var selected: URL?
    @State private var phase = ManagementPhase.idle
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Choose avatar image…") { importing = true }.disabled(phase.isWorking)
            ManagementStatusView(phase: phase)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result { case .success(let url): selected = url; case .failure(let error): phase = .failed(.invalid(error.localizedDescription)) }
        }
        .confirmationDialog("Upload a public workspace avatar?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            Button("Upload public avatar") {
                guard let file = selected else { return }; selected = nil
                Task {
                    guard let manager = model.manager, model.selectedWorkspace?.id == workspace.id, model.connection?.id == connection.id else { return }
                    phase = .working("Uploading public avatar…")
                    do {
                        let png = try await Self.prepare(file)
                        avatar = try await manager.uploadWorkspaceAvatar(connection, workspace, png: png)
                        phase = .done("Avatar uploaded. Save the workspace to use it.")
                    } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
                }
            }
        } message: { Text("The image will be publicly readable on Tower. Location and other image metadata are removed. Save the workspace afterwards to use it as its avatar.") }
    }
    @concurrent nonisolated private static func prepare(_ file: URL) async throws -> Data {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw ManagementError.invalid("Choose an image smaller than 8 MB.") }
        return try ImagePrivacy.strippedPNG(Data(contentsOf: file), maxPixelSize: 1024)
    }
}
