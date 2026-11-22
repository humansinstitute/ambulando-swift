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
            Button("Source & history") { confirm("source") }.disabled(!model.isUnlocked || host?.writing == true)
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


struct DailyTrackerCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let onCreated: (FileRecord) -> Void
    @State private var working = false
    @State private var creation: Task<Void, Never>?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create a personal daily tracker").font(.headline)
                Text("Choose your own yes/no and number metrics after opening. The code and an empty data File will be saved in your personal channel in NStack. Authorized administrators and storage operators may access them.")
                if let failure { Text(failure).foregroundStyle(Amb.destructive) }
                if working { ProgressView("Creating empty tracker…") }
            }.padding().frame(minWidth: 280, idealWidth: 480)
            .navigationTitle("Daily tracker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create() }.disabled(working || !model.isUnlocked) }
            }
            .interactiveDismissDisabled(working)
            .onDisappear { creation?.cancel() }
            .onChange(of: model.wikiContextEpoch) { _, _ in creation?.cancel(); working = false }

        }
    }
    private func create() {
        guard let sync = model.sync, let connection = model.connection,
              let url = Bundle.main.url(forResource: "daily-tracker-v1", withExtension: "html"),
              let template = try? Data(contentsOf: url) else { failure = "The reviewed tracker template is unavailable."; return }
        let epoch = model.wikiContextEpoch
        working = true; failure = nil
        creation = Task {
            do {
                let file = try await sync.createDailyTracker(connection, workspace, template: template)
                guard model.wikiContextEpoch == epoch, model.isUnlocked else { working = false; return }
                working = false; dismiss(); onCreated(file)
            } catch {
                working = false
                failure = "Creation could not be confirmed. Check your personal channel for a tracker before creating another. No existing data was imported."
            }
        }
    }
}
