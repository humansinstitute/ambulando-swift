import AmbulandoCore
import SwiftUI
import WebKit

/// In-memory only. Neither tracker values nor its unsaved draft enter the native store or recovery files.
@MainActor @Observable
final class FileNappletHost {
    var page: NappletPage?
    var failure: String?
    var pending = false
    var writing = false
    var dirty = false
    private var base: String?
    private var delivered: Data?
    private var writable: Bool?
    private var task: Task<Void, Never>?
    private var closed = false
    private var queuedRead: FileNappletRequest?
    let read: () async throws -> FileNappletData
    let save: (String, Data) async throws -> FileNappletData
    init(read: @escaping () async throws -> FileNappletData, save: @escaping (String, Data) async throws -> FileNappletData) {
        self.read = read; self.save = save
    }
    func open(html: String) {
        let page = NappletPage(html: html, fileReceive: { [weak self] request in self?.receive(request) })
        page.didFail = { [weak self] reason in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacFileNappletCheck") { print("FILE_NAPPLET_POLICY \(reason)") }
            #endif
            self?.destroy("The napplet is no longer available. Reopen to authorize it again.")
        }
        self.page = page; page.install()
    }
    func destroy(_ message: String? = nil) {
        closed = true; queuedRead = nil; task?.cancel(); task = nil; page?.destroy(); page = nil; base = nil; delivered = nil; writable = nil
        pending = false; writing = false; dirty = false; failure = message
    }
    func reauthorize() {
        guard !closed, !pending, !writing, page != nil else { return }
        pending = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let access = try await read()
                guard !Task.isCancelled, !closed else { return }
                if let writable, writable != access.canWrite { destroy("Permissions changed. Reopen the napplet."); return }
                pending = false // Successful reauthorization preserves DOM, original base and draft.
                if let next = queuedRead { queuedRead = nil; receive(next) }
            } catch { if !Task.isCancelled { destroy("Access could not be verified. Reopen the napplet.") } }
        }
    }
    func interceptNavigation(_ action: @escaping () -> Void, discard: (@escaping () -> Void) -> Void) -> Bool {
        if writing { return true }
        if dirty { discard(action); return true }
        return false
    }
    private func receive(_ request: FileNappletRequest) {
        guard !closed, let page else { return }
        if request.operation == "dirty" { dirty = request.dirty == true; return }
        guard !pending, !writing else {
            if request.operation == "read" { queuedRead = request }
            else { reply(request.id, code: "unavailable") }
            return
        }
        if request.operation == "save", request.base != base || delivered == nil {
            reply(request.id, code: "conflict"); return
        }
        if let bytes = request.value {
            do { try TrackerDocument.validate(bytes, previous: delivered) }
            catch { reply(request.id, code: "invalid"); return }
        }
        page.ready = true; page.visible = true
        pending = true; writing = request.operation == "save"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let data: FileNappletData
                if let bytes = request.value, let base = request.base { data = try await save(base, bytes) }
                else { data = try await read() }
                guard !Task.isCancelled, !closed, self.page === page else { return }
                self.base = data.versionId; delivered = data.bytes; writable = data.canWrite; pending = false; writing = false
                if request.operation == "save" { dirty = false }
                page.send(["type": "wingman-napplet-result", "version": 1, "session": page.session, "requestId": request.id,
                           "status": "ready", "baseVersionId": data.versionId, "value": try JSONSerialization.jsonObject(with: data.bytes),
                           "canWrite": data.canWrite, "privacy": "self-channel"])
                if let next = queuedRead { queuedRead = nil; receive(next) }
            } catch FileNappletError.conflict {
                // Confirm authority before leaving private draft code mounted after a conflict.
                do {
                    _ = try await read()
                    guard !Task.isCancelled, !closed else { return }
                    pending = false; writing = false; reply(request.id, code: "conflict")
                } catch { if !Task.isCancelled { destroy("Access could not be verified. Reopen the napplet.") } }
            } catch { if !Task.isCancelled { destroy("Access or save could not be verified. Reopen the napplet.") } }
        }
    }
    private func reply(_ id: String, code: String) {
        guard let page else { return }
        page.send(["type": "wingman-napplet-result", "version": 1, "session": page.session, "requestId": id,
                   "status": "error", "code": code,
                   "message": code == "conflict" ? "A newer version exists. Your draft is kept; reload explicitly to continue." : "The request is invalid."])
    }
}

struct DirectHTMLFileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let file: FileRecord
    let workspace: WorkspaceRecord
    var appMode = false
    @State private var code: FileNappletCode?
    @State private var host: FileNappletHost?
    @State private var failure: String?
    @State private var trusted = false
    @State private var editing = false
    @State private var confirmation: String?
    @State private var reopen = 0
    @State private var invalidations = LiveQuery<Int>(initial: 0)
    @State private var navigationId = UUID()
    @State private var deferredNavigation: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let host, let page = host.page {
                HStack {
                    Label("Napplet · personal channel data", systemImage: "lock.shield").font(.amb(.caption))
                    Spacer()
                    Button("Reload") { confirm("reload") }.disabled(host.writing)
                    Button("Close") { confirm("close") }.disabled(host.writing)
                }.padding(8)
                FileNappletWebView(page: page).id(page.session)
                    .opacity(!host.pending && scenePhase == .active ? 1 : 0)
                    .allowsHitTesting(!host.pending && scenePhase == .active)
                    .overlay { if host.pending { ProgressView("Verifying access…") } }
            } else if let message = host?.failure ?? failure {
                EmptyNote(title: "Napplet unavailable", systemImage: "lock", detail: message)
                Button("Reopen") { reopen += 1 }
            } else if let code {
                if code.binding != nil {
                    VStack(spacing: 16) {
                        Label("Allow this napplet to use your tracker data?", systemImage: "lock.shield").font(.headline)
                        Text("This code can read and save its bound JSON File in your personal channel. Authorized NStack administrators and storage operators may still access it. Only enable code you trust.")
                        Button("Trust and open") { trusted = true; start(code) }
                    }.padding().frame(maxWidth: 480)
                } else {
                    Label("Sandboxed HTML", systemImage: "lock.shield").font(.amb(.caption)).padding(6)
                    SandboxedHTMLView(html: code.html)
                }
            } else { ProgressView("Loading artefact…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .toolbar { ToolbarItem(placement: .primaryAction) {
            if !appMode { Button("Source & history") { confirm("source") }.disabled(!model.isUnlocked || host?.writing == true) }
        } }
        .navigationBarBackButtonHidden(host?.dirty == true || host?.writing == true)
        .interactiveDismissDisabled(host?.dirty == true || host?.writing == true)
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { let action = confirmation ?? "close"; confirmation = nil; perform(action) }
            Button("Keep editing", role: .cancel) { confirmation = nil }
        }
        .sheet(isPresented: $editing, onDismiss: { reopen += 1 }) { HTMLSourceSheet(file: file, workspace: workspace) }
        .task(id: context) { await run() }

        .onChange(of: model.canRead) { _, readable in if !readable { host?.destroy(); code = nil } }
        .onChange(of: model.wikiContextEpoch) { _, _ in host?.destroy(); code = nil }
        .onChange(of: scenePhase) { _, phase in if phase == .active { host?.reauthorize() } }
        .onDisappear { host?.destroy(); clearNavigation(); invalidations.stop(); code = nil; trusted = false }
        #if os(macOS)
        .onExitCommand { confirm("close") }
        #endif
    }
    private var context: [String] {
        [String(model.wikiContextEpoch), String(model.canRead), String(model.isUnlocked), String(reopen), file.id,
         model.connection?.id ?? "", model.connection?.origin ?? "", model.connection?.signerNpub ?? "",
         model.selectedWorkspaceId ?? "", model.selectedWorkspace?.appNpub ?? ""]
    }
    private func run() async {
        host?.destroy(); host = nil; code = nil; trusted = false; failure = nil
        guard model.canRead, model.selectedWorkspaceId == workspace.id, let sync = model.sync, let connection = model.connection else { return }
        let epoch = model.wikiContextEpoch
        do {
            let result = try await sync.fileNappletCode(connection, workspace, fileId: file.id)
            guard !Task.isCancelled, model.wikiContextEpoch == epoch, model.canRead else { return }
            if appMode && result.binding == nil { throw FileNappletError.invalid }
            code = result
            if let store = model.store {
                invalidations.onLoad = { _ in host?.reauthorize() }
                invalidations.start(store: store, matches: { [.files, .channels, .appState, .access].contains($0.table) }) {
                    // A changed canonical row is an invalidation signal only; never store tracker values.
                    let f = try await store.reader.file(workspaceId: workspace.id, id: file.id)
                    var d: FileRecord?
                    if let binding = result.binding { d = try await store.reader.file(workspaceId: workspace.id, id: binding.dataFileId) }
                    return (f?.rowVersion ?? 0) + (d?.rowVersion ?? 0)
                }
            }
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(30))
                guard model.wikiContextEpoch == epoch, model.canRead else { break }
                if scenePhase == .active { host?.reauthorize() }
            }
        } catch is CancellationError {} catch { failure = "The HTML File could not be verified." }
        host?.destroy()
    }
    private func start(_ code: FileNappletCode) {
        guard trusted, let sync = model.sync, let connection = model.connection else { return }
        let epoch = model.wikiContextEpoch
        let current: () -> Bool = { model.canRead && model.wikiContextEpoch == epoch && model.selectedWorkspaceId == workspace.id }
        let host = FileNappletHost(read: {
            guard current() else { throw CancellationError() }
            let value = try await sync.readFileNapplet(connection, workspace, fileId: file.id, code: code)
            guard current() else { throw CancellationError() }; return value
        }, save: { base, bytes in
            guard current(), model.isUnlocked else { throw CancellationError() }
            let value = try await sync.saveFileNapplet(connection, workspace, fileId: file.id, code: code, base: base, bytes: bytes)
            guard current() else { throw CancellationError() }; return value
        })
        self.host = host
        model.fileNappletNavigationOwner = navigationId
        model.fileNappletNavigation = { [weak host] action in
            guard let host, host.page != nil else { return false }
            if host.writing { model.notice = "Wait for the tracker save to finish." }
            return host.interceptNavigation(action) { next in deferredNavigation = next; confirmation = "navigate" }
        }
        model.fileNappletContextLost = { [weak host] in host?.destroy(); deferredNavigation = nil; confirmation = nil }
        host.open(html: code.html)
    }
    private func confirm(_ action: String) {
        guard host?.writing != true else { return }
        if host?.dirty == true { confirmation = action } else { perform(action) }
    }
    private func clearNavigation() {
        if model.fileNappletNavigationOwner == navigationId { model.fileNappletNavigation = nil; model.fileNappletNavigationOwner = nil; model.fileNappletContextLost = nil }
    }
    private func perform(_ action: String) {
        host?.destroy(); host = nil; trusted = false; clearNavigation()
        if action == "navigate" { let next = deferredNavigation; deferredNavigation = nil; next?(); return }
        if action == "source" { code = nil; editing = true }
        else if action == "reload" { reopen += 1 }
        else { dismiss() }
    }
}

#if os(iOS)
private struct FileNappletWebView: UIViewRepresentable {
    let page: NappletPage
    func makeUIView(context: Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct FileNappletWebView: NSViewRepresentable {
    let page: NappletPage
    func makeNSView(context: Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif


/// Apps resolve private instances before mounting the unchanged File host.
struct DailyMetricsAppView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    @State private var instances: [FileRecord] = []
    @State private var selected: FileRecord?
    @State private var loaded = false
    @State private var working = false
    @State private var failure: String?
    @State private var setupTask: Task<Void, Never>?
    @State private var setupOwner = UUID()
    @State private var uncertain = false
    @State private var refresh = 0

    private var attemptKey: String { "daily-metrics.setup:" + [model.connection?.id ?? "", model.connection?.origin ?? "", model.connection?.signerNpub ?? "", workspace.id].joined(separator: "|") }
    private var context: [String] { [model.connection?.id ?? "", model.connection?.origin ?? "", model.connection?.signerNpub ?? "", model.selectedWorkspaceId ?? "", String(model.wikiContextEpoch), String(model.canRead), String(refresh)] }
    var body: some View {
        Group {
            if let selected, model.canRead, model.selectedWorkspaceId == workspace.id {
                DirectHTMLFileView(file: selected, workspace: workspace, appMode: true).id(selected.id)
            } else if working { ProgressView("Checking Daily Metrics…") }
            else if let failure {
                VStack(spacing: 16) { EmptyNote(title: "Daily Metrics unavailable", systemImage: "lock", detail: failure); Button("Check again") { refresh += 1 } }
            } else if loaded && instances.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Set up Daily Metrics").font(.headline)
                    Text("Choose your own yes/no and number metrics. Setup saves empty private tracker Files in your personal channel. Authorized administrators and storage operators may access them.")
                    Button("Set up Daily Metrics") { setupTask = Task { await setup() } }.disabled(!model.isUnlocked || uncertain)
                }.padding().frame(maxWidth: 480).accessibilityIdentifier("daily-metrics.setup")
            } else if loaded {
                List(instances) { file in
                    Button { selected = file } label: { VStack(alignment: .leading) { Text(file.displayName); Text(file.id).font(.caption) } }
                }.accessibilityIdentifier("daily-metrics.choose")
            } else if !model.canRead { EmptyNote(title: "Daily Metrics locked", systemImage: "lock", detail: "Unlock to open your private tracker.") }
            else { ProgressView("Opening Daily Metrics…") }
        }
        .navigationTitle("Daily Metrics")
        .task(id: context) { await discover() }
        .onDisappear { setupTask?.cancel() }
        .onChange(of: model.wikiContextEpoch) { _, _ in setupTask?.cancel(); selected = nil; instances = []; loaded = false }
    }
    private func discover() async {
        selected = nil; instances = []; loaded = false; failure = nil; working = false
        guard model.canRead, model.selectedWorkspaceId == workspace.id, let c = model.connection, let sync = model.sync else { return }
        let boundary = context
        working = true
        uncertain = UserDefaults.standard.bool(forKey: attemptKey)
        do {
            let rows = try await sync.dailyTrackers(c, workspace)
            guard !Task.isCancelled, context == boundary else { return }
            instances = rows; loaded = true
            if !rows.isEmpty { uncertain = false; UserDefaults.standard.removeObject(forKey: attemptKey) }
            if rows.count == 1 { selected = rows[0] }
            if rows.isEmpty && uncertain { failure = "An earlier setup could not be confirmed. Inspect your personal Files before attempting another setup." }
        } catch { if !Task.isCancelled && context == boundary { failure = "Existing trackers could not be fully verified. No new tracker has been created." } }
        if context == boundary { working = false }
    }
    private func setup() async {
        guard !working, !uncertain, loaded, instances.isEmpty, model.isUnlocked, let c = model.connection, let sync = model.sync,
              let url = Bundle.main.url(forResource: "daily-tracker-v1", withExtension: "html"), let template = try? Data(contentsOf: url) else { return }
        let boundary = context
        working = true
        model.fileNappletNavigationOwner = setupOwner
        model.fileNappletNavigation = { _ in model.notice = "Wait for tracker setup to finish."; return true }
        model.fileNappletContextLost = { setupTask?.cancel() }
        defer {
            if model.fileNappletNavigationOwner == setupOwner {
                model.fileNappletNavigation = nil; model.fileNappletNavigationOwner = nil; model.fileNappletContextLost = nil
            }
        }
        do {
            // Recheck immediately before provisioning; another device may already have set it up.
            let rows = try await sync.dailyTrackers(c, workspace)
            guard !Task.isCancelled, context == boundary, model.isUnlocked else { return }
            if !rows.isEmpty { instances = rows; selected = rows.count == 1 ? rows[0] : nil; working = false; return }
            uncertain = true
            UserDefaults.standard.set(true, forKey: attemptKey)
            let file = try await sync.createDailyTracker(c, workspace, template: template)
            guard !Task.isCancelled, context == boundary, model.isUnlocked else { return }
            uncertain = false; UserDefaults.standard.removeObject(forKey: attemptKey); instances = [file]; selected = file
        } catch { if context == boundary { failure = "Setup could not be confirmed. Check again to adopt any tracker already created. Existing data has not been replaced." } }
        if context == boundary { working = false }
    }
}
