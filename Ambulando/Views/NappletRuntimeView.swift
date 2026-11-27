import AmbulandoCore
import SwiftUI

struct RuntimeAppsSection: View {
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
    @State private var refresh = 0
    @State private var apps = LiveQuery<[RuntimeInstallation]>(initial:[])
    @State private var selection: RuntimeInstallation?
    @State private var reconnectID = ""
    @State private var reconnecting = false
    @State private var failure: String?
    private var context: [String] { [model.connection?.id ?? "",model.connection?.signerNpub ?? "",workspace.id,String(model.wikiContextEpoch),String(model.canRead), String(active), String(scenePhase == .active), String(refresh)] }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if showsManagement || !apps.value.isEmpty {
                HStack {
                    Text("Workspace apps").font(.headline)
                    Spacer()
                    Button("Refresh apps", systemImage: "arrow.clockwise") { refresh += 1 }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            ForEach(apps.value) { app in
                Button { selection = app } label: { Label(app.manifest.title,systemImage:"app").badge(app.pendingManifest == nil ? 0 : 1) }.buttonStyle(.borderless).accessibilityIdentifier("runtime.app.\(app.id)")
            }
            if showsManagement {
                if apps.value.isEmpty { Text("Your bot can publish an app here for you. Shared access to an app does not grant access to its records.").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Reconnect a removed app") {
                    TextField("Stable app ID",text:$reconnectID)
                    Text("Uses the current removed installation revision. Kept collection data reconnects; deleted data cannot be recovered. NStack requires installation authority.").font(.caption)
                    Button("Reconnect retained app") { reconnect() }.buttonStyle(.borderless).disabled(reconnecting || !model.isUnlocked || !NappletRuntimeManifest.name(reconnectID))
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            }
            #if os(macOS)
            if let error = model.syncError(forKey: WorkspaceSync.runtimeAppsKey(workspace.id)) {
                if showsManagement { Text(error).font(.caption).foregroundStyle(.secondary) }
                else { loadFailure }
            } else if model.syncStatus.connectionFailures.contains(WorkspaceSync.runtimeAppsKey(workspace.id)) {
                loadFailure
            }
            #else
            if let error = model.syncError(forKey: WorkspaceSync.runtimeAppsKey(workspace.id)) { Text(error).font(.caption).foregroundStyle(.secondary) }
            #endif
        }
        .sheet(item:$selection) { item in NavigationStack { NappletRuntimeView(workspace:workspace,id:item.id) }.frame(minWidth:320,minHeight:460) }
        .task(id:context) {
            apps.stop()
            guard active, scenePhase == .active, model.canRead, let c = model.connection, let sync = model.sync, let runtime = try? sync.runtimeContext(c,workspace) else { return }
            apps.start(store:store,matches:{ $0.table == .appState || $0.table == .access }) {
                try await store.reader.runtimeApps(connection:c,workspace:workspace,context:runtime)
            }
            await sync.scheduleRuntimeApps(c, workspace, force: refresh > 0)
        }
        .onChange(of: Array(context.prefix(5))) { _, _ in selection = nil }
        .onDisappear { apps.stop() }
    }
    private var loadFailure: some View {
        HStack {
            Text("Apps could not refresh.").font(.caption).foregroundStyle(.secondary)
            Button("Retry apps") { refresh += 1 }.buttonStyle(.borderless).accessibilityIdentifier("runtime.retry")
        }
    }
    private func reconnect() {
        guard let c = model.connection, let sync = model.sync, !reconnecting else { return }
        let boundary = context, id = reconnectID; reconnecting = true
        Task {
            defer { reconnecting = false }
            do {
                try await sync.reconnectRuntimeApp(c,workspace,id:id)
                if boundary == context { failure = nil; reconnectID = "" }
            } catch { if boundary == context { failure = "Reconnect was not confirmed. The app ID, current revision and your installation authority must be valid." } }
        }
    }

}

struct NappletRuntimeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let workspace: WorkspaceRecord
    let id: String
    @State private var cachedRevision = LiveQuery<String?>(initial: nil)
    @State private var restoredLocal = false
    @State private var code: RuntimeCode?
    @State private var dataAuthority: Data?
    @State private var host: NappletRuntimeHost?
    @State private var failure: String?
    @State private var notice: String?
    @State private var loading = false
    @State private var removal: Bool?
    @State private var confirmExpansion = false
    @State private var management = false
    @State private var collectionBindings: [String:String] = [:]
    @State private var reopen = 0
    @State private var owner = UUID()
    @State private var deferred: (() -> Void)?
    @State private var discard = false
    private let trust = NappletRuntimeTrust()
    private var context: [String] { [model.connection?.id ?? "",model.connection?.origin ?? "",model.connection?.signerNpub ?? "",model.selectedWorkspaceId ?? "",workspace.id,String(model.wikiContextEpoch),String(model.isUnlocked),String(reopen)] }
    var body: some View {
        VStack(spacing:8) {
            if let host, let page = host.page {
                GenericNappletWebView(page:page).id(page.session).opacity(scenePhase == .active ? 1 : 0)
                    .allowsHitTesting(scenePhase == .active && !host.busy)
            } else if let code {
                if let unsupported = code.installation.manifest.unsupportedReason { EmptyNote(title:"Host update required",systemImage:"exclamationmark.shield",detail:unsupported) }
                else {
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            Text("\(code.installation.manifest.icon) \(code.installation.manifest.title)").font(.title2)
                            Text("Allow this authenticated publisher’s app to use the collections below? Approval applies to this identity and workspace. Future code updates within this access load automatically.")
                            access(code.installation.manifest)
                            Text("Record permissions are checked by NStack. App audience, record access and personal capabilities are separate. Previously loaded content is available offline; changes require an online connection.").font(.caption)
                            Button("Approve access and open") { approve(code) }.disabled(loading).accessibilityIdentifier("runtime.approve")
                        }.padding()
                    }
                }
            } else if failure == nil { ProgressView("Verifying workspace app…") }
            if let message = host?.failure ?? failure { Text(message).foregroundStyle(.red).padding(8); Button("Reopen") { reopen += 1 } }
            if let notice { Text(notice).font(.caption).padding(8) }
        }
        .navigationTitle(code?.installation.manifest.title ?? "Workspace app")
        .toolbar {
            ToolbarItem { Menu("App") {
                Button("Check for update") { requestReload() }
                Button("Audience and data") { management = true }.disabled(code == nil || host?.busy == true || host?.dirty == true)
                if code?.installation.pendingManifest != nil { Button("Review expanded access") { confirmExpansion = true } }
                Button("Remove and keep data") { removal = false }.disabled(host?.busy == true)
                Button("Remove and delete data",role:.destructive) { removal = true }.disabled(host?.busy == true)
                Button("Forget approval") { forget() }
            }.disabled(loading || host?.busy == true) }
            ToolbarItem(placement:.cancellationAction) { Button("Close") { if host?.busy != true { if host?.dirty == true { deferred = { dismiss() }; discard = true } else { dismiss() } } }.disabled(host?.busy == true) }
        }
        .interactiveDismissDisabled(host?.dirty == true || host?.busy == true)
        .confirmationDialog("Discard unsaved changes?",isPresented:$discard,titleVisibility:.visible) {
            Button("Discard changes",role:.destructive) { let action = deferred; deferred = nil; host?.destroy(); action?() }
            Button("Keep editing",role:.cancel) { deferred = nil }
        }
        .confirmationDialog(removal == true ? "Delete this app’s collection data and history?" : "Remove this app and keep its data?",isPresented:Binding(get:{ removal != nil },set:{ if !$0 { removal = nil } }),titleVisibility:.visible) {
            Button(removal == true ? "Remove and delete data" : "Remove and keep data",role:.destructive) {
                let delete = removal == true; removal = nil; Task { await manage(.remove(deleteData:delete),close:true) }
            }
            Button("Cancel",role:.cancel) { removal = nil }
        } message: {
            Text(removal == true ? "Deletes all collections and their record history for this app, subject to NStack ownership checks. Source Files and their history remain. This cannot be undone. Unsaved changes will be lost." : "Removes the workspace installation. Collections, source Files and history remain; reinstalling reconnects retained data. Unsaved changes will be lost.")
        }
        .sheet(isPresented:$confirmExpansion) {
            if let pending = code?.installation.pendingManifest {
                NavigationStack { ScrollView { VStack(alignment:.leading,spacing:16) {
                    Text("Review requested access").font(.title2); access(pending)
                    Text("Approving activates the pending release for its audience. Device approval and NStack record grants remain separate. Only an authorized human manager can approve.").font(.caption)
                    if let reason = pending.unsupportedReason { Text(reason) }
                    Button("Approve expanded access") { confirmExpansion = false; Task { await manage(.approveRelease) } }.disabled(pending.unsupportedReason != nil || !model.isUnlocked)
                    Button("Decline and keep current app") { confirmExpansion = false }
                }.padding() } }.frame(minWidth:320,minHeight:400)
            }
        }
        .sheet(isPresented:$management) { if let code { RuntimeManagementView(workspace:workspace,installation:code.installation,changed:{ reopen += 1 },selectDataset:{ name, id in collectionBindings[name] = id; reopen += 1 }) } }
        .onChange(of: cachedRevision.value) { _, _ in
            guard restoredLocal, model.isUnlocked, let sync = model.sync, let c = model.connection else { return }
            let boundary = context
            Task {
                let saved = await sync.cachedRuntime(c, workspace, id: id)
                guard context == boundary, restoredLocal else { return }
                if saved == nil { host?.destroy("Saved code or data access was removed. Reopen to review it.") }
            }
        }
        .task(id:context) { await run() }
        .onChange(of:scenePhase) { _, phase in if phase == .active { verifyOnFocus() } }
        .onChange(of:model.isUnlocked) { _, read in if !read { cleanup(); code = nil } }
        .onChange(of:model.wikiContextEpoch) { _, _ in cleanup(); code = nil; collectionBindings = [:]; dataAuthority = nil }
        .onChange(of:model.connection?.id) { _, _ in collectionBindings = [:]; dataAuthority = nil }
        .onChange(of:model.selectedWorkspaceId) { _, _ in collectionBindings = [:]; dataAuthority = nil }
        .onDisappear { cleanup() }
    }
    @ViewBuilder private func access(_ manifest: NappletRuntimeManifest) -> some View {
        ForEach(manifest.collections.keys.sorted(),id:\.self) { name in
            if let c = manifest.collections[name] { Text("\(name) · \(c.scope) · schema \(c.schema)\n\(c.operations.sorted().joined(separator:", "))").font(.callout) }
        }
        ForEach(manifest.capabilities.keys.sorted(),id:\.self) { name in
            if let c = manifest.capabilities[name] { Text("\(name) v\(c.version): \(c.operations.sorted().joined(separator:", "))\n\(c.resources.sorted().joined(separator:", "))").font(.callout) }
        }
    }
    private func run() async {
        cleanup(); host = nil; code = nil; failure = nil
        guard model.isUnlocked else { failure = "Unlock to open this app."; return }
        guard model.selectedWorkspaceId == workspace.id, let c = model.connection, let sync = model.sync else { failure = "Reopen this app in its workspace."; return }
        restoredLocal = false
        if let store = model.store {
            cachedRevision.start(store: store, matches: { $0.table == .access || $0.table == .appState }) { try await store.reader.state("local-content.epoch") }
        }
        let boundary = context
        if let cached = await sync.cachedRuntime(c, workspace, id: id), context == boundary,
           let runtimeContext = try? sync.runtimeContext(c, workspace),
           trust.approved(context: runtimeContext, publisher: cached.code.installation.publisher, manifest: cached.code.installation.manifest) {
            restoredLocal = true
            code = cached.code; dataAuthority = cached.collections
            start(cached.code, boundary: boundary)
            notice = "Showing saved content. Checking for updates…"
        }
        do {
            let epoch = try await sync.store.reader.state("local-content.epoch") ?? ""
            let result = try await sync.runtimeCode(c,workspace,id:id)
            guard !Task.isCancelled, context == boundary else { return }
            let freshAuthority = try await sync.runtimeCollections(c,workspace,id:id)
            guard !Task.isCancelled, context == boundary else { return }
            if let old = code, !old.installation.sameRelease(as: result.installation) || dataAuthority != freshAuthority {
                host?.destroy(); host = nil
            }
            code = result; dataAuthority = freshAuthority; notice = nil
            await sync.rememberRuntime(c, workspace, code: result, collections: freshAuthority, epoch: epoch)
            restoredLocal = true
            if host == nil, trust.approved(context:try sync.runtimeContext(c,workspace),publisher:result.installation.publisher,manifest:result.installation.manifest) { start(result,boundary:boundary) }
            while !Task.isCancelled {
                try await Task.sleep(for:.seconds(30))
                guard context == boundary, scenePhase == .active else { continue }
                let latest = try await sync.runtimeCode(c,workspace,id:id)
                let latestDataAuthority = try await sync.runtimeCollections(c,workspace,id:id)
                guard !Task.isCancelled, context == boundary else { return }
                if dataAuthority != latestDataAuthority {
                    host?.destroy("Collection access changed. Reopen to verify your datasets."); dataAuthority = nil; return
                }
                if !latest.installation.sameRelease(as:result.installation) {
                    if host?.dirty == true || host?.busy == true { notice = "An update is available. Finish saving, then check for update." }
                    else {
                        await sync.rememberRuntime(c, workspace, code: latest, collections: latestDataAuthority)
                        reopen += 1; return
                    }
                } else {
                    code = latest
                    if let host, try await host.refreshReads() { start(latest, boundary: boundary, replaceWhenReady: true) }
                }
            }
        } catch is CancellationError {} catch {
            guard context == boundary else { return }
            if CachedContentFailure.invalidates(error) {
                await sync.forgetCachedRuntime(c, workspace, id: id)
                host?.destroy("Code or access changed. Reopen to review it."); code = nil
                failure = "The app is no longer available with its saved access."
            } else if host != nil { notice = "Showing saved content. Refresh could not complete." }
            else { failure = "No saved content is available. Connect to verify this app." }
        }
    }
    private func approve(_ code: RuntimeCode) {
        guard let c = model.connection, let sync = model.sync else { return }
        let boundary = context; loading = true
        Task {
            defer { loading = false }
            do {
                _ = try await sync.runtimeAuthorize(c,workspace,installation:code.installation)
                guard boundary == context else { return }
                try trust.remember(context:sync.runtimeContext(c,workspace),publisher:code.installation.publisher,manifest:code.installation.manifest)
                start(code,boundary:boundary)
            } catch { failure = "Approval could not be confirmed. Reopen to review access." }
        }
    }
    private func start(_ code: RuntimeCode, boundary: [String], replaceWhenReady: Bool = false) {
        guard let c = model.connection, let sync = model.sync else { return }
        let approvedAuthority = dataAuthority
        let current = { context == boundary && model.isUnlocked && model.selectedWorkspaceId == workspace.id }
        var cachedRequests = Set<String>()
        let h = NappletRuntimeHost(html:code.html,manifest:code.installation.manifest,authorize:{
            guard current() else { throw CancellationError() }
            _ = try await sync.runtimeAuthorize(c,workspace,installation:code.installation)
            guard try await sync.runtimeCollections(c,workspace,id:id) == approvedAuthority else { throw FileNappletError.unavailable }
            guard current() else { throw CancellationError() }
        },cachedRead:{ request in
            guard current(), ["list", "get"].contains(request.operation) else { return nil }
            let slot = [request.operation, request.collection ?? "", request.record ?? "", String(request.limit ?? 0), request.cursor ?? ""].joined(separator: "|")
            guard cachedRequests.insert(slot).inserted else { return nil }
            return await sync.cachedRuntimeRead(c, workspace, installation: code.installation, request: request, selections: collectionBindings)
        },command:{ request in
            guard current() else { throw CancellationError() }
            let result = try await sync.runtimeCommand(c,workspace,installation:code.installation,request:request,selections:collectionBindings)
            guard current() else { throw CancellationError() }; return result
        })
        if replaceWhenReady, let existing = host {
            h.open()
            Task {
                for _ in 0..<300 {
                    if h.page?.ready == true && !h.busy { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard current(), host === existing, !existing.dirty, !existing.busy, h.page?.ready == true, !h.busy else { h.destroy(); return }
                existing.destroy(); host = h; bindNavigation(h)
            }
        } else { host = h; h.open(); bindNavigation(h) }
    }
    private func bindNavigation(_ h: NappletRuntimeHost) {
        model.fileNappletNavigationOwner = owner
        model.fileNappletContextLost = { [weak h] in h?.destroy(); deferred = nil; discard = false }
        model.fileNappletNavigation = { [weak h] action in
            guard let h, h.page != nil else { return false }
            if h.busy { return true }
            if h.dirty { deferred = action; discard = true; return true }; return false
        }
    }
    private func verifyOnFocus() {
        guard host?.busy != true else { return }
        guard host?.dirty == true, let code, let c = model.connection, let sync = model.sync else { requestReload(); return }
        let boundary = context, approved = dataAuthority
        Task {
            do {
                _ = try await sync.runtimeAuthorize(c,workspace,installation:code.installation)
                let grants = try await sync.runtimeCollections(c,workspace,id:id)
                guard context == boundary else { return }
                if grants != approved { host?.destroy("Collection access changed. Reopen to verify your datasets.") }
            } catch { if context == boundary, CachedContentFailure.invalidates(error) {
                await sync.forgetCachedRuntime(c, workspace, id: id)
                host?.destroy("Code or access changed. Reopen to review it.")
            } }
        }
    }
    private func requestReload() {
        guard host?.busy != true else { return }
        if host?.dirty == true { deferred = { reopen += 1 }; discard = true } else { reopen += 1 }
    }
    private func cleanup() {
        cachedRevision.stop(); host?.destroy()
        if model.fileNappletNavigationOwner == owner { model.fileNappletNavigationOwner = nil; model.fileNappletNavigation = nil; model.fileNappletContextLost = nil }
    }
    private func forget() {
        guard let code, let c = model.connection, let sync = model.sync else { return }
        do { try trust.forget(context:sync.runtimeContext(c,workspace),publisher:code.installation.publisher,napplet:id); requestReload() }
        catch { failure = "Approval could not be forgotten." }
    }
    private func manage(_ action: RuntimeManagement, close: Bool = false) async {
        guard let code, let c = model.connection, let sync = model.sync else { return }
        loading = true; defer { loading = false }; let boundary = context
        do {
            try await sync.runtimeManage(c,workspace,installation:code.installation,action:action)
            guard boundary == context else { return }
            cleanup(); if close { dismiss() } else { reopen += 1 }
        } catch { if boundary == context { notice = "NStack did not confirm this change. Check your authority and current revision before trying again." } }
    }
}
