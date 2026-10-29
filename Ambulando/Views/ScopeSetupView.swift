import AmbulandoCore
import SwiftUI

/// Scope setup is deliberately staged: creating the scope and each template channel are separate confirmed writes.
/// A saved scope id and the authoritative channel list make interrupted setup recoverable without duplicate creates.
struct ScopeSetupView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord
    @State private var draft: [String: String] = [:]
    @State private var phase = ManagementPhase.idle
    @State private var loaded = false
    @State private var confirm = false
    @State private var existing: ScopeRecord?
    private var key: String { "admin.scope-setup.v1:\(connection.id):\(workspace.id)" }
    private var capturedScope: String? { draft["scope"] }
    var body: some View {
        Form {
            Section {
                WorkspaceIdentityHeader(workspace: workspace)
                Text("Creates a top-level scope, then its starting channels. Each step is saved separately. Interrupted setup keeps its progress on this device.").font(.caption)
            }
            Section("Scope") {
                TextField("Name", text: value("name"))
                TextField("Description", text: value("description"), axis: .vertical)
                Picker("Template", selection: value("template", fallback: "blank")) { Text("Blank").tag("blank"); Text("Product").tag("product") }
                if draft["template"] == "product" {
                    TextField("Working directory", text: value("directory"))
                    Text("Creates Features, Implementation, Bugs and Refactoring using the current product template’s descriptions and context prompts.").font(.caption)
                }
            }.disabled(capturedScope != nil || phase.isWorking)
            if let scope = capturedScope {
                Section("Setup progress") {
                    Text("Scope created: \(scope)").font(.caption).textSelection(.enabled)
                    Text("Continue checks this scope’s current channels and creates only missing template channels. Existing channel settings are preserved.").font(.caption)
                }
            }
            if capturedScope == nil && draft["attempted"] == "true" {
                Section("Recover an interrupted creation") {
                    Button("Check Tower for this scope") { Task { await recover() } }.disabled(phase.isWorking)
                }
            }
            if case .done = phase {
                Section { Button("Start another scope setup") { draft = [:]; phase = .idle } }
            }
            Section {
                Button(capturedScope == nil ? "Create scope…" : "Continue starting channels…") { confirm = true }
                    .disabled(!loaded || phase.isWorking || model.selectedWorkspace?.id != workspace.id || model.connection?.id != connection.id || !ManagementPermissions.canCreateScope(model.membership))
                Text("You receive scope management. Use Permissions to grant scope roles and channel access. No setup is queued offline.").font(.caption)
            }
        }.macGroupedForm().navigationTitle("New scope setup")
        .modifier(ManagementStatusInset(phase: phase))
        .confirmationDialog("Set up this scope in \(workspace.label)?", isPresented: $confirm, titleVisibility: .visible) {
            Button(capturedScope == nil ? "Create scope" : "Continue setup") { Task { await save() } }
        } message: { Text("Each creation is an immediate workspace change. A failure can leave a scope or some channels created; saved progress is retained.") }
        .confirmationDialog("Continue setup in an existing scope?", isPresented: Binding(get: { existing != nil }, set: { if !$0 { existing = nil } }), titleVisibility: .visible) {
            Button("Use this scope for remaining channels") { if let scope = existing { draft["scope"] = scope.id; existing = nil; phase = .idle; Task { try? await persist() } } }
        } message: { Text("Tower already has a scope with this name. Choosing it preserves its current settings and lets the next confirmed step add only missing template channels.") }
        .task {
            if let saved = try? await model.store?.reader.state(key), let stored = try? JSONDecoder().decode([String: String].self, from: Data(saved.utf8)) { draft = stored }
            loaded = true
        }
        .task(id: draft) { guard loaded else { return }; do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation(); try await persist() } catch {} }
        .onDisappear { let d = draft, k = key, store = model.store; Task { try? await store?.writer.setState(k, String(decoding: JSONEncoder().encode(d), as: UTF8.self)) } }
    }
    private func value(_ field: String, fallback: String = "") -> Binding<String> { Binding(get: { draft[field] ?? fallback }, set: { draft[field] = $0 }) }
    private func persist() async throws { try await model.store?.writer.setState(key, String(decoding: JSONEncoder().encode(draft), as: UTF8.self)) }
    private func recover() async {
        guard let manager = model.manager, model.selectedWorkspace?.id == workspace.id else { return }
        phase = .working("Checking the current scopes…")
        do {
            if let scope = try await manager.scopeSetupCandidate(connection, workspace, name: draft["name"] ?? "") { existing = scope; phase = .idle }
            else { draft["attempted"] = nil; try await persist(); phase = .done("Tower lists no scope with this name. You can explicitly try creating it again.") }
        } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)) }
    }
    private func save() async {
        guard let manager = model.manager, model.store != nil, model.selectedWorkspace?.id == workspace.id, model.connection?.id == connection.id else { return }
        phase = .working("Setting up scope…")
        do {
            let template = try ScopeSetupTemplate.load(product: draft["template"] == "product", title: draft["name"] ?? "", directory: draft["directory"] ?? "")
            try await persist()
            if capturedScope == nil {
                guard draft["attempted"] != "true" else { throw ManagementError.conflict("A previous scope create may have reached Tower. Refresh Scopes and inspect its result before starting another setup. The entered values are retained.") }
                draft["attempted"] = "true"; try await persist()
                let scope = try await manager.createScope(connection, workspace, name: draft["name"] ?? "", description: (draft["description"] ?? "").isEmpty ? template.description : draft["description"])
                draft["scope"] = scope.id; try await persist()
            }
            guard let scope = capturedScope else { return }
            let channels = try await manager.setupChannelNames(connection, workspace, scope: scope)
            for channel in template.channels where !channels.contains(channel.name.lowercased()) {
                _ = try await manager.createChannel(connection, workspace, scopeId: scope, name: channel.name, description: channel.description, contextPrompt: channel.prompt)
                draft["lastChannel"] = channel.name; try await persist()
            }
            phase = .done("Scope and starting channels are saved on Tower. Manage access in Permissions.")
            model.refresh(force: true)
        } catch { phase = .failed((error as? ManagementError) ?? .unexpected(error.localizedDescription)); model.refresh(force: true) }
    }
}

private struct ScopeSetupTemplate {
    struct Channel { let name: String; let description: String; let prompt: String }
    let description: String
    let channels: [Channel]
    static func load(product: Bool, title: String, directory: String) throws -> ScopeSetupTemplate {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManagementError.invalid("Scope name is required.") }
        if !product { return ScopeSetupTemplate(description: "", channels: []) }
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ManagementError.invalid("The product template requires a working directory.") }
        guard let url = Bundle.main.url(forResource: "scope-product-template", withExtension: "json"), let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw ManagementError.unexpected("The product template is unavailable.") }
        func render(_ text: String) -> String { text.replacingOccurrences(of: "$title", with: title).replacingOccurrences(of: "$workingdir", with: directory) }
        let scope = object["scope"] as? [String: Any] ?? [:]
        let channels = (object["channels"] as? [[String: Any]] ?? []).map { Channel(name: $0["name"] as? String ?? "", description: render($0["description"] as? String ?? ""), prompt: render($0["basePrompt"] as? String ?? "")) }
        return ScopeSetupTemplate(description: render(scope["description"] as? String ?? ""), channels: channels)
    }
}
