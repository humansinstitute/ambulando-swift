import AmbulandoCore
import SwiftUI

/// Host-owned administration. No management operation is exposed to cartridge JavaScript.
struct RuntimeManagementView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let installation: RuntimeInstallation
    var changed: () -> Void
    var selectDataset: (String,String) -> Void
    struct Collection: Identifiable {
        let id: String
        let name: String
        let scope: String
        let owner: String
        let revision: Int
        let schema: Int
        let read: [String]
        let write: [String]
    }
    @State private var audience = ""
    @State private var collections: [Collection] = []
    @State private var selected: String?
    @State private var read = ""
    @State private var write = ""
    @State private var source = ""
    @State private var record = "legacy-import"
    @State private var importConfirmation = false
    @State private var busy = false
    @State private var notice: String?
    private var context: [String] { [model.connection?.id ?? "",model.connection?.signerNpub ?? "",model.selectedWorkspaceId ?? "",String(model.wikiContextEpoch),String(model.canRead)] }
    private var collection: Collection? { collections.first { $0.id == selected } }
    var body: some View {
        NavigationStack {
            Form {
                Section("App audience") {
                    Text("Users and agents listed here can discover and open the app. This grants no collection access or personal capabilities.").font(.caption)
                    TextField("Audience npubs, separated by spaces",text:$audience,axis:.vertical)
                    Button("Save audience") { perform(.audience(npubs(audience))) }
                }
                Section("Collections") {
                    Picker("Dataset",selection:$selected) {
                        Text("Choose a collection").tag(nil as String?)
                        ForEach(collections) { c in Text("\(c.name) · \(c.scope) · \(c.owner.prefix(16))…").tag(c.id as String?) }
                    }
                    ForEach(installation.manifest.collections.keys.sorted(),id:\.self) { name in
                        Button("Create my \(name) collection") { perform(.createCollection(name:name)) }
                    }
                    Text("New collections are owned by your identity with no additional grants. NStack enforces creation authority and prevents duplicate datasets. An ambiguous dataset is never selected by the app.").font(.caption)
                }
                if let collection {
                    Section("Record access") {
                        Button("Use this dataset in app") { selectDataset(collection.name,collection.id); dismiss() }
                        Text("Owner: \(collection.owner)").font(.caption).textSelection(.enabled)
                        TextField("Read npubs",text:$read,axis:.vertical)
                        TextField("Write npubs",text:$write,axis:.vertical)
                        Button("Replace grants") { perform(.collectionGrants(id:collection.id,revision:collection.revision,read:npubs(read),write:npubs(write))) }
                        Text("Only the collection owner can replace grants. Removing a name revokes that explicit access. Sharing the app alone leaves these grants unchanged.").font(.caption)
                    }
                    Section("Import existing JSON File") {
                        TextField("Source JSON File UUID",text:$source)
                        TextField("New record ID",text:$record)
                        Text("Explicit compatible import copies the whole source JSON object into one new record. Use only when this app understands that object at schema \(collection.schema). Original File IDs, data and full version history remain unchanged. This does not convert tracker days into collection records. Conflicting record IDs fail without overwriting.").font(.caption)
                        if collection.scope == "team" { Text("The imported object will be readable by this team collection’s granted identities. Review grants before importing.").font(.caption).foregroundStyle(.orange) }
                        Button("Review compatible import") { importConfirmation = true }.disabled(installation.manifest.collections[collection.name]?.operations.contains("create") != true)
                    }
                }
                if let notice { Section { Text(notice).font(.caption) } }
                if busy { ProgressView() }
            }
            .disabled(busy || !model.isUnlocked)
            .navigationTitle("Audience and data")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .task { audience = installation.audience.joined(separator:"\n"); await refresh() }
            .onChange(of:selected) { _, _ in read = collection?.read.joined(separator:"\n") ?? ""; write = collection?.write.joined(separator:"\n") ?? "" }
            .onChange(of:context) { _, _ in collections = []; selected = nil; source = ""; read = ""; write = ""; dismiss() }
            .confirmationDialog("Import the entire source object as a new record?",isPresented:$importConfirmation,titleVisibility:.visible) {
                if let collection { Button("Import compatible copy") { perform(.importFile(collection:collection.id,revision:collection.revision,schema:collection.schema,sourceFile:source.trimmingCharacters(in:.whitespacesAndNewlines),record:record)) } }
                Button("Cancel",role:.cancel) {}
            } message: { Text("Confirm this object is compatible with the selected app and collection schema. NStack will verify the immutable source and your authority. Original Files and history remain available.") }
        }.frame(minWidth:320,minHeight:480)
    }
    private func npubs(_ text: String) -> [String] { text.split(whereSeparator:{ $0.isWhitespace || $0 == "," }).map(String.init) }
    private func refresh() async {
        guard let c = model.connection, let sync = model.sync else { return }
        let boundary = context
        do {
            let data = try await sync.runtimeCollections(c,workspace,id:installation.id)
            guard boundary == context, !Task.isCancelled, let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], let rows = root["collections"] as? [[String:Any]] else { return }
            collections = rows.compactMap { row in
                guard let id = row["id"] as? String, let name = row["name"] as? String, let scope = row["scope"] as? String,
                      let owner = row["owner_npub"] as? String, let revision = row["revision"] as? Int, let schema = row["schema_version"] as? Int,
                      let read = row["read_npubs"] as? [String], let write = row["write_npubs"] as? [String] else { return nil }
                return Collection(id:id,name:name,scope:scope,owner:owner,revision:revision,schema:schema,read:read,write:write)
            }
        } catch { if boundary == context { notice = "Collections could not be verified online." } }
    }
    private func perform(_ action: RuntimeManagement) {
        guard let c = model.connection, let sync = model.sync, !busy else { return }
        let boundary = context; busy = true
        Task {
            defer { busy = false }
            do {
                try await sync.runtimeManage(c,workspace,installation:installation,action:action)
                guard boundary == context else { return }
                notice = "NStack confirmed the change."; await refresh(); changed()
            } catch { if boundary == context { notice = "Change was not confirmed. NStack requires current revision and explicit management or collection-owner authority. No automatic retry was made." } }
        }
    }
}
