import AmbulandoCore
import SwiftUI

/// Personal File pins are bookmarks only. Verify every displayed title/icon from the current immutable HTML.
struct GenericAppsSection: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    var active = true
    var management = false
    private var showsManagement: Bool {
        #if os(macOS)
        management
        #else
        true
        #endif
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var verifiedEntries: [String: Entry] = [:]
    @State private var verifiedContext: [String] = []
    @State private var pins = LiveQuery<Int>(initial:0)
    @State private var apps: [Entry] = []
    @State private var adding = false
    @State private var refreshing = 0
    struct Entry: Identifiable {
        let file: FileRecord
        let binding: GenericNappletBinding
        let code: GenericNappletCode
        var cacheKey: GenericAppDescriptorKey? { GenericAppDescriptorKey(file: file) }
        var id: String { file.id }
    }
    private var context: [String] { [model.connection?.id ?? "", workspace.id, String(model.wikiContextEpoch), String(model.canRead), String(refreshing),String(pins.value), String(active), String(scenePhase == .active)] }
    var body: some View {
        VStack(alignment:.leading, spacing:8) {
            if showsManagement {
                HStack {
                    Button("Add napplet", systemImage:"plus.app") { adding = true }.buttonStyle(.borderless).disabled(!model.canRead).accessibilityIdentifier("generic.add")
                    Spacer()
                    Button("Refresh", systemImage:"arrow.clockwise") { refreshing += 1 }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            ForEach(apps) { app in
                Button { model.push(.file(workspaceId:workspace.id,fileId:app.id),in:model.mode) } label: {
                    HStack { Text(app.binding.icon); Text(app.binding.title); Spacer(); Image(systemName:"chevron.right") }
                }.buttonStyle(.borderless).accessibilityIdentifier("generic.app.\(app.id)")
            }
            if showsManagement {
                Text("Install an existing NStack HTML File. Apps use personal File pins; removing an app keeps its Files and history.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented:$adding, onDismiss:{ refreshing += 1 }) { AddGenericNappletView(workspace:workspace,store:store) }
        .task(id: context.prefix(4).map { $0 } + [String(active), String(scenePhase == .active)]) {
            pins.stop()
            guard active, scenePhase == .active, model.canRead else { return }
            let c = model.connection?.id ?? ""
            pins.start(store:store,matches:{ $0.workspaceId == workspace.id && [.pins,.access].contains($0.table) }) {
                try await store.reader.genericFilePinsRevision(connectionId:c,workspaceId:workspace.id)
            }
        }
        .task(id:context) {
            apps = []; guard active, scenePhase == .active, let c = model.connection, let sync = model.sync, model.canRead else { return }
            let cacheContext = [c.id, c.origin, c.signerNpub, workspace.id, model.selectedWorkspaceBoundary?.id ?? "", String(model.wikiContextEpoch), String(refreshing)]
            if cacheContext != verifiedContext { verifiedEntries = [:]; verifiedContext = cacheContext }
            let boundary = context
            await sync.refreshPins(c,workspace)
            var verified: [Entry] = []
            var all:[PinRecord] = [], cursor = ""
            do {
                while true {
                    let page = try await store.reader.genericFilePins(connectionId:c.id,workspaceId:workspace.id,after:cursor)
                    guard !Task.isCancelled, context == boundary else { return }
                    all += page
                    guard let last = page.last else { break }; cursor = last.id
                }
            } catch { return }
            for pin in all.sorted(by:PinRecord.displayOrder) {
                guard !Task.isCancelled, context == boundary else { return }
                do {
                    let entry: Entry
                    if let cached = verifiedEntries[pin.resourceId],
                       let current = try await store.reader.file(workspaceId: workspace.id, id: pin.resourceId),
                       let key = GenericAppDescriptorKey(file: current), key == cached.cacheKey, key.matches(cached.code) {
                        entry = cached
                    } else {
                        let result = try await sync.genericAppDescriptor(c, workspace, fileId: pin.resourceId)
                        entry = Entry(file: result.file, binding: result.code.binding, code: result.code)
                    }
                    guard !Task.isCancelled, context == boundary else { return }
                    verifiedEntries[pin.resourceId] = entry
                    verified.append(entry)
                    guard !Task.isCancelled, context == boundary else { return }; apps = verified
                } catch { /* Inaccessible or non-v2 pins never become trusted Apps entries. */ }
            }
            guard !Task.isCancelled, context == boundary else { return }; apps = verified
        }
        .onDisappear { pins.stop() }
    }
}

struct AddGenericNappletView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let store: LocalStore
    @State private var files = LiveQuery<[FileRecord]>(initial:[])
    @State private var link = ""
    @State private var selected: String?
    @State private var candidate: FileRecord?
    @State private var code: GenericNappletCode?
    @State private var failure: String?
    @State private var loading = false
    @State private var requestedPin = false
    @State private var pins = LiveQuery<[PinnedItem]>(initial:[])
    private var context:[String] { [model.connection?.id ?? "",model.connection?.origin ?? "",model.connection?.signerNpub ?? "",model.selectedWorkspaceId ?? "",String(model.wikiContextEpoch),String(model.canRead)] }
    var body: some View {
        NavigationStack {
            Form {
                Section("Existing HTML File") {
                    Picker("Loaded Files",selection:$selected) {
                        Text("Choose a File").tag(nil as String?)
                        ForEach(files.value) { file in Text(file.displayName).tag(file.id as String?) }
                    }
                    Text("This picker shows locally loaded Files and may be incomplete. You can also paste a File link.").font(.caption)
                    TextField("File link or UUID",text:$link).textFieldStyle(.roundedBorder).accessibilityIdentifier("generic.file-link")
                    Button("Verify File") { Task { await verify() } }.disabled(loading || requestedPin).accessibilityIdentifier("generic.verify")
                }
                if let candidate, let code {
                    Section("Review app") {
                        Text("\(code.binding.icon) \(code.binding.title)")
                        Text(code.binding.capability == "private-json-file" ? "Uses an existing personal JSON File. No data is created or rebound." : "Reads authorized workspace aggregates.").font(.caption)
                        Button("Install in Apps") {
                            requestedPin = true
                            model.setPinned(true,type:.file,id:candidate.id,in:workspace)
                        }.disabled(requestedPin || !model.isUnlocked).accessibilityIdentifier("generic.install")
                        if requestedPin {
                            if let failed = model.pins.value.failure(.file,candidate.id) {
                                Text(failed.lastError ?? "Installation was not confirmed.").font(.caption).foregroundStyle(.red)
                                Button("Review and retry") { requestedPin = false; self.candidate = nil; self.code = nil }
                            } else { Text("Waiting for NStack to confirm the File pin…").font(.caption) }
                        }
                    }
                }
                if loading { ProgressView() }
                if let failure { Text(failure).foregroundStyle(.red) }
                if requestedPin, let notice = model.notice { Text(notice).font(.caption) }
            }
            .navigationTitle("Add napplet")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                let c = model.connection?.id ?? ""
                files.start(store:store,matches:{ $0.workspaceId == workspace.id && $0.table == .files }) {
                    try await store.reader.files(workspaceId:workspace.id).filter { ArtefactType.file($0) == .html }
                }
                pins.start(store:store,matches:{ $0.workspaceId == workspace.id && $0.table == .pins }) {
                    try await store.reader.pinnedItems(connectionId:c,workspaceId:workspace.id)
                }
            }
            .onChange(of:pins.value) { _, pins in
                if requestedPin, let candidate, pins.contains(where:{ $0.pin.resourceType == .file && $0.pin.resourceId == candidate.id }) { dismiss() }
            }
            .onChange(of:context) { _, _ in candidate = nil; code = nil; requestedPin = false; failure = "Context changed. Verify the File again." }
            .onChange(of:link) { _, _ in candidate = nil; code = nil }
            .onChange(of:selected) { _, _ in candidate = nil; code = nil }
            .onDisappear { files.stop(); pins.stop() }
        }.frame(minWidth:320,minHeight:400)
    }
    private func verify() async {
        guard let c = model.connection, let sync = model.sync, model.canRead else { return }
        loading = true; failure = nil; candidate = nil; code = nil; defer { loading = false }
        do {
            let id: String
            if link.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let selected { id = selected }
            else { id = try GenericNappletFileLink.parse(link, origin:c.origin, workspace:workspace.id) }
            let boundary = model.wikiContextEpoch
            let file = try await sync.genericNappletFile(c,workspace,fileId:id)
            let verified = try await sync.genericNappletCode(c,workspace,fileId:id)
            _ = try await sync.authorizeGenericNapplet(c,workspace,fileId:id,code:verified)
            guard !Task.isCancelled, boundary == model.wikiContextEpoch, model.selectedWorkspaceId == workspace.id else { return }
            candidate = file; code = verified
        } catch { failure = "This File or its declared resource could not be verified in the current workspace." }
    }
}
