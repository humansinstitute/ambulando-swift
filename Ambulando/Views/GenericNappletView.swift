import AmbulandoCore
import SwiftUI
import WebKit

/// The host keeps private values and draft DOM only in memory. Each run pins one verified code head.
@MainActor @Observable
final class GenericNappletHost {
    var page: NappletPage?
    var dirty = false
    var busy = false
    var authorizing = false
    var writing = false
    var failure: String?
    private var closed = false
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var aggregateRange: String?
    private var base: String?
    private var queuedRead: (request: GenericNappletRequest, expires: ContinuousClock.Instant)?
    let code: GenericNappletCode
    let canWrite: Bool
    let authorize: () async throws -> Bool
    let read: (String?) async throws -> FileNappletData
    let save: (String, Data) async throws -> FileNappletData
    init(code: GenericNappletCode, canWrite: Bool, authorize: @escaping () async throws -> Bool,
         read: @escaping (String?) async throws -> FileNappletData, save: @escaping (String, Data) async throws -> FileNappletData) {
        self.code = code; self.canWrite = canWrite; self.authorize = authorize; self.read = read; self.save = save
    }
    func open() {
        let p = NappletPage(html: code.html, binding: code.binding) { [weak self] in self?.receive($0) ?? false }
        p.didFail = { [weak self] _ in self?.destroy("The document ended. Reopen to verify access.") }
        page = p; p.visible = true; p.install()
    }
    func destroy(_ message: String? = nil) {
        closed = true; queuedRead = nil; task?.cancel(); deadline?.cancel(); task = nil; deadline = nil
        page?.destroy(); page = nil; base = nil; aggregateRange = nil; dirty = false; busy = false; authorizing = false; writing = false; failure = message
    }
    private func timer(until expires: ContinuousClock.Instant? = nil) {
        deadline?.cancel()
        let limit = expires ?? ContinuousClock.now.advanced(by: .seconds(45))
        deadline = Task { [weak self] in
            try? await Task.sleep(until: limit, clock: .continuous); guard !Task.isCancelled else { return }
            self?.destroy("Operation could not be confirmed. Reopen before trying again.")
        }
    }
    func reauthorize() {
        guard !closed, !busy, !authorizing, let expectedPage = page else { return }
        authorizing = true; timer()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let write = try await authorize()
                if code.binding.includesWorkspaceStorage { _ = try await read(aggregateRange ?? "30d") }
                guard !Task.isCancelled, !closed, page === expectedPage, write == canWrite else { if !Task.isCancelled { destroy("Permissions or context changed. Reopen to review access.") }; return }
                authorizing = false; deadline?.cancel() // Do not reload or replace a healthy draft DOM.
                if let next = queuedRead {
                    queuedRead = nil
                    _ = receive(next.request, until: next.expires)
                }
            } catch { if !Task.isCancelled { destroy("Access could not be verified. Reopen the napplet.") } }
        }
    }
    @discardableResult func receive(_ request: GenericNappletRequest, until expires: ContinuousClock.Instant? = nil) -> Bool {
        guard !closed, !busy, let p = page else { return false }
        if authorizing {
            // Authorization checks are not bridge operations. Admit one initial read, keeping its
            // original deadline and consumed replay ID, and dispatch only after the fresh check.
            guard request.operation == "read", base == nil, queuedRead == nil else { return false }
            queuedRead = (request, ContinuousClock.now.advanced(by: .seconds(45)))
            return true
        }
        if request.operation == "dirty" { dirty = request.dirty == true; return true }
        if request.operation == "save", !canWrite || request.base != base {
            reply(request.id, code: canWrite ? "conflict" : "invalid"); return true
        }
        busy = true; writing = request.operation == "save"; timer(until: expires)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let data: FileNappletData
                if let value = request.value, let base = request.base { data = try await save(base, value) }
                else { data = try await read(request.range) }
                guard !Task.isCancelled, !closed, page === p, data.canWrite == canWrite else { if !Task.isCancelled { destroy("Access changed. Reopen the napplet.") }; return }
                base = data.versionId; aggregateRange = request.range; busy = false; writing = false; deadline?.cancel()
                if request.operation == "save" { dirty = false }
                var result: [String: Any] = ["type":"wingman-napplet-result", "version":2, "session":p.session, "requestId":request.id, "status":"ready", "canWrite":canWrite, "privacy":code.binding.capability == "private-json-file" ? "self-channel" : "viewer-channels"]
                if code.binding.capability == "private-json-file" { result["baseVersionId"] = data.versionId }
                p.sendGeneric(result,value:data.bytes)
            } catch {
                guard !Task.isCancelled, !closed else { return }
                // A neutral capability failure may keep a draft only after authority is freshly confirmed.
                do {
                    guard try await authorize() == canWrite, !Task.isCancelled, !closed else { throw FileNappletError.unavailable }
                    busy = false; writing = false; deadline?.cancel()
                    let code: String
                    switch error { case FileNappletError.forbidden: code = "forbidden"; case FileNappletError.conflict: code = "conflict"; case FileNappletError.invalid: code = "invalid"; default: code = "unavailable" }
                    reply(request.id, code: code)
                } catch { if !Task.isCancelled { destroy("Access could not be verified. Reopen the napplet.") } }
            }
        }; return true
    }
    private func reply(_ id: String, code: String) {
        guard let page else { return }
        page.send(["type":"wingman-napplet-result","version":2,"session":page.session,"requestId":id,"status":"error","code":code,
                   "message":code == "forbidden" ? "Workspace management permission required." : code == "invalid" ? "Invalid request." : code == "conflict" ? "A newer version exists." : "Operation could not be confirmed."])
    }
}

struct GenericNappletFileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.macArtefactSession) private var macSession
    #endif
    let file: FileRecord
    let workspace: WorkspaceRecord
    @State private var code: GenericNappletCode?
    @State private var receipt: GenericNappletReceipt?
    @State private var canWrite = false
    @State private var host: GenericNappletHost?
    @State private var failure: String?
    @State private var notice: String?
    @State private var loading = false
    @State private var reopen = 0
    @State private var confirmation: String?
    @State private var deferred: (() -> Void)?
    @State private var owner = UUID()
    @State private var invalidations = LiveQuery<Int>(initial:0)
    @State private var suppressRemembered = false
    let trust = GenericNappletTrustStore()
    private var context: [String] { [file.id, workspace.id, model.connection?.id ?? "", model.connection?.origin ?? "", model.connection?.signerNpub ?? "", model.selectedWorkspaceId ?? "", String(model.wikiContextEpoch), String(model.canRead), String(reopen)] }
    var body: some View {
        VStack(spacing: 8) {
            if let host, let page = host.page {
                HStack {
                    Text(code?.binding.title ?? "Napplet").font(.headline)
                    Spacer()
                    if host.busy || host.authorizing { ProgressView().controlSize(.small) }
                    Menu("App") {
                        Button("Check for update") { confirm("update") }.accessibilityIdentifier("generic.update")
                        Button("Forget approval") { confirm("forget") }.accessibilityIdentifier("generic.forget")
                        Button("Uninstall from Apps", role: .destructive) { confirm("uninstall") }
                        Button("Close") { confirm("close") }
                    }.disabled(host.writing).accessibilityIdentifier("generic.menu")
                }.padding(8)
                if let notice { Text(notice).font(.caption) }
                GenericNappletWebView(page:page).id(page.session)
                    .opacity(scenePhase == .active ? 1 : 0).allowsHitTesting(scenePhase == .active && !host.busy && !host.authorizing)
            } else if let failure = host?.failure ?? failure {
                EmptyNote(title:"Napplet unavailable", systemImage:"lock", detail:failure)
                Button("Reopen") { reopen += 1 }
            } else if let code {
                VStack(spacing:16) {
                    Text("\(code.binding.icon) \(code.binding.title)").font(.title2)
                    Text(code.binding.capability == "private-json-file" ? "Allow this code to read\(canWrite ? " and save" : "") its bound JSON File in your personal channel?" : code.binding.includesWorkspaceStorage ? "Allow this code to read workspace activity and workspace-wide retained storage totals, including private scopes? No message or file content is shared. Current server-verified workspace management permission is required." : "Allow this code to read authorized workspace activity and inventory totals?")
                    if canWrite && code.binding.capability == "private-json-file" {
                        Text("Saving replaces the whole JSON object. This app is responsible for its data format.").font(.caption)
                    }
                    Text("Bound \(code.binding.capability == "private-json-file" ? "File" : "workspace"): \(code.binding.resourceId)").font(.caption).textSelection(.enabled)
                    Text("Only enable code you trust. Authorized administrators and storage operators may still access server data. Approval is remembered on this device for this exact code and access.").font(.caption)
                    Button("Trust and open") { Task { await approve(code) } }.disabled(loading).accessibilityIdentifier("generic.approve")
                }.padding().frame(maxWidth:480)
            } else { ProgressView("Verifying napplet…") }
        }
        .navigationTitle(code?.binding.title ?? file.displayName).inlineTitle()
        .navigationBarBackButtonHidden(host?.dirty == true || host?.writing == true)
        .interactiveDismissDisabled(host?.dirty == true || host?.writing == true)
        .confirmationDialog("Discard unsaved changes?", isPresented:Binding(get:{ confirmation != nil },set:{ if !$0 { confirmation = nil } }), titleVisibility:.visible) {
            Button("Discard changes", role:.destructive) { let action = confirmation; confirmation = nil; perform(action ?? "close") }
            Button("Keep editing", role:.cancel) { confirmation = nil }
        }
        .task(id:context) { await run() }
        .onChange(of:scenePhase) { _, phase in if phase == .active { host?.reauthorize() } }
        .onChange(of:model.canRead) { _, read in if !read { host?.destroy(); code = nil } }
        .onChange(of:model.wikiContextEpoch) { _, _ in host?.destroy(); code = nil }
        .onDisappear { cleanup() }
        #if os(macOS)
        .onExitCommand { confirm("close") }
        .onChange(of:host?.dirty) { _, _ in windowGuard() }
        .onChange(of:host?.writing) { _, _ in windowGuard() }
        #endif
    }
    private func makeReceipt(_ c: ConnectionRecord, _ code: GenericNappletCode, _ writable: Bool) throws -> GenericNappletReceipt {
        let raw = try JSONSerialization.jsonObject(with:workspace.raw) as? [String:Any], identity = raw?["identity"] as? [String:String]
        return try GenericNappletReceipt(baseURL:c.origin, tower:c.towerNpub ?? "", service:identity?["workspace_service_npub"] ?? "", app:workspace.appNpub, workspace:workspace.id, viewer:c.signerNpub, file:file.id, digest:code.sha256, binding:code.binding, canWrite:writable)
    }
    private func run() async {
        cleanup(); host = nil; code = nil; receipt = nil; failure = nil
        guard model.canRead else { failure = "Unlock to open this app."; return }
        guard model.selectedWorkspaceId == workspace.id, let c = model.connection, let sync = model.sync else { failure = "Reopen this app in its workspace."; return }
        let boundary = context
        do {
            let result = try await sync.genericNappletCode(c, workspace, fileId:file.id)
            let writable = try await sync.authorizeGenericNapplet(c, workspace, fileId:file.id, code:result)
            if result.binding.capability == "private-json-file" { _ = try await sync.readGenericJSON(c, workspace, fileId:file.id, code:result) }
            guard !Task.isCancelled, context == boundary else { return }
            let r = try makeReceipt(c,result,writable); code = result; canWrite = writable; receipt = r
            if !suppressRemembered, trust.contains(r) { start(result) }
            if let store = model.store {
                invalidations.onLoad = { _ in if scenePhase == .active { host?.reauthorize() } }
                invalidations.start(store:store,matches:{ [.files,.channels,.access,.appState].contains($0.table) }) {
                    let f = try await store.reader.file(workspaceId:workspace.id,id:file.id)
                    return f?.rowVersion ?? 0
                }
            }
            while !Task.isCancelled {
                try await Task.sleep(for:.seconds(30)); guard context == boundary else { break }
                if scenePhase == .active { host?.reauthorize() }
            }
        } catch is CancellationError {} catch { if context == boundary { failure = "The code or its bound resource could not be verified." } }
        host?.destroy()
    }
    private func approve(_ code: GenericNappletCode) async {
        guard !loading, let sync = model.sync, let c = model.connection, let receipt else { return }
        loading = true; defer { loading = false }; let boundary = context
        do {
            let writable = try await sync.authorizeGenericNapplet(c, workspace, fileId:file.id, code:code)
            guard !Task.isCancelled, context == boundary, scenePhase == .active, try makeReceipt(c,code,writable) == receipt else { throw FileNappletError.unavailable }
            do { try trust.remember(receipt); suppressRemembered = false } catch { notice = "Approval applies to this open session; it could not be remembered." }
            start(code)
        } catch { if context == boundary { failure = "Code or access changed. Reopen to review it." } }
    }
    private func start(_ code: GenericNappletCode) {
        guard let c = model.connection, let sync = model.sync else { return }
        let boundary = context, approvedWrite = canWrite
        let current = { context == boundary && model.canRead && model.selectedWorkspaceId == workspace.id }
        let h = GenericNappletHost(code:code, canWrite:approvedWrite, authorize:{
            guard current() else { throw CancellationError() }
            let result = try await sync.authorizeGenericNapplet(c, workspace, fileId:file.id, code:code)
            guard current() else { throw CancellationError() }; return result
        }, read:{ range in
            guard current() else { throw CancellationError() }
            let result: FileNappletData
            if code.binding.capability == "private-json-file" { result = try await sync.readGenericJSON(c,workspace,fileId:file.id,code:code) }
            else { result = FileNappletData(bytes:try await sync.readGenericAggregate(c,workspace,fileId:file.id,code:code,range:range ?? "30d"),versionId:"",canWrite:false) }
            guard current() else { throw CancellationError() }; return result
        }, save:{ base, bytes in
            guard current(), model.isUnlocked, approvedWrite else { throw FileNappletError.unavailable }
            let result = try await sync.saveGenericJSON(c,workspace,fileId:file.id,code:code,base:base,bytes:bytes)
            guard current() else { throw CancellationError() }; return result
        })
        host = h
        model.fileNappletNavigationOwner = owner
        model.fileNappletNavigation = { [weak h] action in
            guard let h, h.page != nil else { return false }
            if h.writing { return true }
            if h.dirty { deferred = action; confirmation = "navigate"; return true }; return false
        }
        model.fileNappletContextLost = { [weak h] in h?.destroy(); deferred = nil; confirmation = nil }
        h.open()
        #if os(macOS)
        windowGuard()
        #endif
    }
    private func cleanup() {
        host?.destroy(); invalidations.stop()
        if model.fileNappletNavigationOwner == owner { model.fileNappletNavigationOwner = nil; model.fileNappletNavigation = nil; model.fileNappletContextLost = nil }
    }
    private func confirm(_ action: String) { guard host?.writing != true else { return }; if host?.dirty == true { confirmation = action } else { perform(action) } }
    private func perform(_ action: String) {
        if action == "forget", let receipt {
            do { try trust.forget(receipt); suppressRemembered = true } catch { notice = "Approval could not be forgotten."; return }
        }
        if action == "uninstall" { model.setPinned(false,type:.file,id:file.id,in:workspace) }
        cleanup()
        if ["update","forget"].contains(action) { reopen += 1 }
        else if action == "navigate" { let next = deferred; deferred = nil; next?() }
        else {
            #if os(macOS)
            if let macSession, macSession.detached { macSession.window?.performClose(nil) }
            else if !model.closeGenericNapplet(fileId:file.id,workspaceId:workspace.id) { dismiss() }
            #else
            if !model.closeGenericNapplet(fileId:file.id,workspaceId:workspace.id) { dismiss() }
            #endif
        }
    }
    #if os(macOS)
    private func windowGuard() {
        macSession?.canDetach = host?.dirty != true && host?.writing != true
        macSession?.checkpoint = { host?.writing != true }
        macSession?.requestClose = { action in
            if host?.writing == true { return true }
            if host?.dirty == true { deferred = action; confirmation = "navigate"; return true }; return false
        }
    }
    #endif
}
#if os(iOS)
struct GenericNappletWebView: UIViewRepresentable {
    let page: NappletPage
    func makeUIView(context:Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateUIView(_ view:WKWebView, context:Context) {}
}
#else
struct GenericNappletWebView: NSViewRepresentable {
    let page: NappletPage
    func makeNSView(context:Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateNSView(_ view:WKWebView, context:Context) {}
}
#endif
