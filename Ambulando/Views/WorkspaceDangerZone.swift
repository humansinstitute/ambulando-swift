import AmbulandoCore
import SwiftUI

struct WorkspaceDangerZone: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    @State private var confirmation = ""
    @State private var showConfirmation = false
    @State private var phase = ManagementPhase.idle
    var body: some View {
        Form {
            Section {
                WorkspaceIdentityHeader(workspace: workspace)
                Text("Deleting this workspace on Tower affects every member and removes their workspace access. This is not removing a saved device preference. Tower’s owner and protected-workspace safeguards still apply.")
                TextField("Type \(workspace.label) to confirm", text: $confirmation)
                Button("Delete workspace", role: .destructive) { showConfirmation = true }
                    .disabled(phase.isWorking || confirmation != workspace.label || model.membership?.isAdmin != true || model.selectedWorkspace?.id != workspace.id)
            }
        }.macGroupedForm().navigationTitle("Delete workspace")
        .modifier(ManagementStatusInset(phase: phase))
        .confirmationDialog("Delete \(workspace.label) for everyone?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Delete workspace on Tower", role: .destructive) {
                Task {
                    guard let manager = model.manager, model.selectedWorkspace?.id == workspace.id, model.connection?.id == connection.id else { return }
                    phase = .working("Waiting for Tower…")
                    do {
                        try await manager.administer(connection, workspace, command: .deleteWorkspace(confirmation: workspace.id))
                        phase = .done("Tower confirmed the deletion. Refreshing workspace access…"); model.refresh(force: true)
                    } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
                }
            }
        } message: { Text("This changes Tower, affects all members and cannot be undone here. No local cache purge or cursor reset is performed by this screen.") }
    }
}
