import AmbulandoCore
import SwiftUI

/// User-consented cross-origin activation using the existing catalog and install-intent contracts.
/// A created intent is kept before processing; recovery processes that intent rather than creating a duplicate.
struct ManagedAppActivationView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    let delegations: [AdministrationRow]
    @AppStorage("autopilotAdministrationOrigin") private var configuredOrigin = ""
    @State private var apps: [AdministrationActivationApp] = []
    @State private var draft: [String: String] = [:]
    @State private var phase = ManagementPhase.idle
    @State private var loaded = false
    @State private var confirmation: ActivationConfirmation?
    private enum ActivationConfirmation: String, Identifiable { case catalog, activate, process; var id: String { rawValue } }
    private var key: String { "admin.activation.v1:\(connection.id):\(workspace.id)" }
    private var origin: String { draft["origin"] ?? configuredOrigin }
    private var validWorkspace: Bool { model.selectedWorkspace?.id == workspace.id && model.connection?.id == connection.id }

    var body: some View {
        Form {
            Section {
                Text(workspace.label).font(.headline)
                Text("This signs requests as your unlocked identity to the HTTPS Autopilot origin you explicitly choose. Tower metadata does not select or trust this host. Redirects are refused.").font(.caption)
                TextField("Autopilot HTTPS origin", text: value("origin", fallback: configuredOrigin))
                    .disabled(!(draft["intent"] ?? "").isEmpty)
                Button("Load activation catalog…") { confirmation = .catalog }.disabled(phase.isWorking || !validWorkspace || origin.isEmpty)
            }
            Section("App and destination") {
                Picker("App", selection: value("app")) {
                    Text("Choose an app from the catalog").tag("")
                    ForEach(apps) { Text("\($0.title) (\($0.version))").tag($0.id) }
                }
                Picker("Destination channel", selection: value("channel")) {
                    Text("Choose a channel").tag("")
                    ForEach(model.navigation.value.groups.flatMap(\.channels)) { Text($0.name).tag($0.id) }
                }
                Picker("Authority", selection: value("delegation")) {
                    if model.membership?.isAdmin == true { Text("Workspace administrator").tag("") }
                    ForEach(delegations.filter { $0.fields["delegate_actor_id"] == model.membership?.actorId && $0.fields["revoked_at"] == nil }) { Text("Delegation · \($0.title) · \($0.fields["expires_at"] ?? "")").tag($0.id) }
                }
                if let app = apps.first(where: { $0.id == draft["app"] }) {
                    LabeledContent("Launch URL", value: app.launchURL)
                    LabeledContent("Autopilot public key", value: shortNpub(app.autopilotNpub))
                    LabeledContent("Open origin", value: app.viewOrigin)
                }
                Text("Activation requests Feed publishing only for the selected channel. Tower checks the exact app, delegation, destination and origin; owner-only approvals remain required.").font(.caption)
            }.disabled(phase.isWorking || !(draft["intent"] ?? "").isEmpty)
            Section {
                if let intent = draft["intent"], !intent.isEmpty {
                    Text("Saved activation intent: \(intent)").font(.caption).textSelection(.enabled)
                    Button("Process this saved intent…") { confirmation = .process }.disabled(phase.isWorking || !validWorkspace)
                    Text("An interrupted claim may already have completed. Processing retries this exact intent. It never creates another installation.").font(.caption)
                } else {
                    Button("Activate selected app…") { confirmation = .activate }.disabled(!loaded || phase.isWorking || !validWorkspace || draft["app"] == nil || draft["channel"] == nil)
                }
            }
        }.macGroupedForm()
        .navigationTitle("Activate managed app")
        .modifier(ManagementStatusInset(phase: phase))
        .confirmationDialog("Sign a request to \(origin)?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button(confirmation == .catalog ? "Load catalog from this origin" : "Activate through this origin") {
                guard let action = confirmation else { return }; confirmation = nil
                Task { await run(action) }
            }
        } message: { Text("Uses your public identity and signatures with this exact HTTPS host. Activation changes this workspace and may provision a managed app. Nothing is submitted to an app store.") }
        .task {
            guard !loaded else { return }
            if let saved = try? await model.store?.reader.state(key), let value = try? JSONDecoder().decode([String: String].self, from: Data(saved.utf8)) { draft = value }
            if draft["origin"] == nil { draft["origin"] = configuredOrigin }
            if draft["request"] == nil { draft["request"] = UUID().uuidString.lowercased(); draft["installation"] = UUID().uuidString.lowercased() }
            if let saved = draft["catalog"], let values = try? JSONDecoder().decode([AdministrationActivationApp].self, from: Data(saved.utf8)) { apps = values }
            loaded = true
        }
        .task(id: draft) { guard loaded else { return }; do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation(); try await persist() } catch {} }
        .onDisappear { let values = draft, k = key, store = model.store; Task { try? await store?.writer.setState(k, String(decoding: JSONEncoder().encode(values), as: UTF8.self)) } }
    }
    private func value(_ field: String, fallback: String = "") -> Binding<String> { Binding(get: { draft[field] ?? fallback }, set: { draft[field] = $0 }) }
    private func persist() async throws {
        guard let store = model.store else { throw ManagementError.unexpected("Local storage is unavailable.") }
        try await store.writer.setState(key, String(decoding: JSONEncoder().encode(draft), as: UTF8.self))
    }
    private func run(_ action: ActivationConfirmation) async {
        guard validWorkspace, let manager = model.manager else { return }
        phase = .working("Waiting for signed confirmation…")
        do {
            let acceptedOrigin = try TowerOrigin(origin).description
            switch action {
            case .catalog:
                apps = try await manager.activationCatalog(connection, origin: acceptedOrigin)
                draft["catalog"] = String(decoding: try JSONEncoder().encode(apps), as: UTF8.self)
                draft["origin"] = acceptedOrigin; draft["catalogOrigin"] = acceptedOrigin; draft["app"] = nil
                try await persist(); phase = .done("Catalog loaded. Choose an app and destination.")
            case .activate:
                guard draft["catalogOrigin"] == acceptedOrigin, let app = apps.first(where: { $0.id == draft["app"] }),
                      let channel = model.navigation.value.groups.flatMap(\.channels).first(where: { $0.id == draft["channel"] }) else { throw ManagementError.invalid("Load this origin’s catalog and choose an app and channel.") }
                try await persist()
                let intent = try await manager.createActivationIntent(connection, workspace, app: app, origin: acceptedOrigin, scope: channel.scopeId, channel: channel.id, installation: draft["installation"] ?? "", requestId: draft["request"] ?? "", delegation: draft["delegation"].flatMap { $0.isEmpty ? nil : $0 })
                draft["intent"] = intent; try await persist()
                // Capture before the separate claim; failed claims retain the exact Tower intent for recovery.
                try await manager.processActivationIntent(connection, workspace, origin: acceptedOrigin, intent: intent)
                phase = .done("Autopilot processed the saved intent. Refresh installations to inspect its state.")
            case .process:
                guard let intent = draft["intent"] else { throw ManagementError.invalid("No saved intent is available.") }
                try await manager.processActivationIntent(connection, workspace, origin: acceptedOrigin, intent: intent)
                phase = .done("Autopilot processed this saved intent. Refresh installations to inspect its state.")
            }
        } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
    }
}
