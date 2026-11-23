import AmbulandoCore
import SwiftUI
import WebKit

@MainActor @Observable
final class WorkspaceReportHost {
    var page: NappletPage?
    var failure: String?
    var pending = false
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    let authorize: () async throws -> Void
    let read: (String) async throws -> Data
    init(authorize: @escaping () async throws -> Void, read: @escaping (String) async throws -> Data) {
        self.authorize = authorize; self.read = read
    }
    func open(_ code: WorkspaceReportCode) {
        let page = NappletPage(html: code.html, reportReceive: { [weak self] in self?.receive($0) })
        page.didFail = { [weak self] _ in self?.destroy("The report closed. Reopen to verify access.") }
        self.page = page; page.install()
    }
    func destroy(_ reason: String? = nil) {
        task?.cancel(); deadline?.cancel(); task = nil; deadline = nil
        page?.destroy(); page = nil; pending = false; failure = reason
    }
    func reauthorize() {
        guard let page, !pending else { return }
        pending = true
        task = Task { [weak self] in
            guard let self else { return }
            do { try await authorize(); guard !Task.isCancelled, self.page === page else { return }; pending = false }
            catch { if !Task.isCancelled { destroy("Access could not be verified. Reopen the report.") } }
        }
        timeout(page)
    }
    private func timeout(_ page: NappletPage) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.page === page, pending else { return }
            destroy("The report request timed out. Reopen to retry.")
        }
    }
    private func receive(_ request: WorkspaceReportRequest) {
        guard let page else { return }
        guard !pending else {
            page.send(["type": "wingman-napplet-result", "version": 1, "session": page.session, "requestId": request.id,
                       "status": "error", "code": "unavailable", "message": "A request is already in progress."]); return
        }
        pending = true; page.visible = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let bytes = try await read(request.range)
                guard !Task.isCancelled, self.page === page else { return }
                pending = false; deadline?.cancel()
                page.send(["type": "wingman-napplet-result", "version": 1, "session": page.session, "requestId": request.id,
                           "status": "ready", "value": try JSONSerialization.jsonObject(with: bytes), "canWrite": false, "privacy": "viewer-channels"])
            } catch {
                guard !Task.isCancelled, self.page === page else { return }
                // Never retain aggregates or bridge after an authorization, server or validation failure.
                destroy("The report is unavailable or access changed. No cached totals are shown. Reopen to retry.")
            }
        }
        timeout(page)
    }
}

struct WorkspaceReportFileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let file: FileRecord
    let workspace: WorkspaceRecord
    @State private var code: WorkspaceReportCode?
    @State private var receipt: FileNappletTrustReceipt?
    @State private var host: WorkspaceReportHost?
    @State private var failure: String?
    @State private var reopen = 0
    @State private var approving = false
    @State private var active = false
    @State private var suppressRemembered = false
    @State private var invalidations = LiveQuery<Int>(initial: 0)
    var trustStore = FileNappletTrustStore.local
    private var context: [String] { [model.connection?.id ?? "", model.connection?.origin ?? "", model.connection?.signerNpub ?? "", model.selectedWorkspaceId ?? "", model.selectedWorkspace?.appNpub ?? "", String(model.wikiContextEpoch), String(model.canRead), String(reopen), file.id] }
    var body: some View {
        VStack(spacing: 8) {
            if let page = host?.page {
                HStack {
                    Label("Read-only workspace report", systemImage: "lock.shield").font(.caption)
                    Spacer()
                    Button("Forget approval") { forget() }.accessibilityIdentifier("report.forget")
                    Button("Reload") { host?.destroy(); reopen += 1 }.accessibilityIdentifier("report.reload")
                    Button("Close") { host?.destroy(); dismiss() }
                }.padding(8)
                ReportWebView(page: page).id(page.session)
                    .opacity(scenePhase == .active && host?.pending != true ? 1 : 0)
                    .allowsHitTesting(scenePhase == .active && host?.pending != true)
                    .overlay { if host?.pending == true { ProgressView("Loading report…") } }
            } else if let error = host?.failure ?? failure {
                EmptyNote(title: "Workspace Report unavailable", systemImage: "lock", detail: error)
                Button("Reopen") { reopen += 1 }
            } else if let code {
                VStack(spacing: 16) {
                    Label("Allow this report to read workspace totals?", systemImage: "lock.shield").font(.headline)
                    Text("This code can read activity and current inventory totals for project channels you can currently access in this workspace. It cannot write data. Only enable code you trust.")
                    Text("Approval is remembered on this device for this exact code, workspace and read-only capability. Current server access is checked on every read.").font(.caption)
                    Button("Trust and open") { Task { await approve(code) } }.disabled(approving).accessibilityIdentifier("report.approve")
                }.padding().frame(maxWidth: 480)
            } else { ProgressView("Verifying report…") }
        }
        .task(id: context) { await run() }
        .onChange(of: model.canRead) { _, value in if !value { host?.destroy(); code = nil } }
        .onChange(of: model.wikiContextEpoch) { _, _ in host?.destroy(); code = nil }
        .onChange(of: scenePhase) { _, phase in if phase == .active { host?.reauthorize() } }
        .onDisappear { active = false; host?.destroy(); code = nil; invalidations.stop() }
    }
    private func run() async {
        host?.destroy(); host = nil; code = nil; receipt = nil; failure = nil; active = true
        guard model.canRead else { failure = "Unlock to open this app."; return }
        guard model.selectedWorkspaceId == workspace.id, let c = model.connection, let sync = model.sync else { failure = "Reopen this app in its workspace."; return }
        let boundary = context
        do {
            let result = try await sync.workspaceReportCode(c, workspace, fileId: file.id)
            try await sync.authorizeWorkspaceReport(c, workspace, fileId: file.id, code: result)
            guard !Task.isCancelled, active, context == boundary else { return }
            let receipt = try FileNappletTrustReceipt(connection: c, workspace: workspace, codeFile: file.id, report: result)
            self.receipt = receipt; code = result
            if !suppressRemembered && trustStore.contains(receipt) { start(result) }
            if let store = model.store {
                invalidations.onLoad = { _ in if scenePhase == .active { host?.reauthorize() } }
                invalidations.start(store: store, matches: { [.files, .channels, .access, .appState].contains($0.table) }) {
                    try await store.reader.file(workspaceId: workspace.id, id: file.id)?.rowVersion ?? 0
                }
            }
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(30))
                guard active, context == boundary else { break }
                if scenePhase == .active { host?.reauthorize() }
            }
        } catch is CancellationError {} catch { if active, context == boundary { failure = "The private report code or current workspace access could not be verified." } }
        host?.destroy()
    }
    private func approve(_ code: WorkspaceReportCode) async {
        guard !approving, let c = model.connection, let sync = model.sync, let receipt else { return }
        let boundary = context; approving = true; defer { approving = false }
        do {
            try await sync.authorizeWorkspaceReport(c, workspace, fileId: file.id, code: code)
            guard active, scenePhase == .active, !Task.isCancelled, context == boundary else { return }
            try trustStore.remember(receipt); suppressRemembered = false; start(code)
        } catch { failure = "Approval or access could not be verified. Reopen to retry."; self.code = nil }
    }
    private func start(_ code: WorkspaceReportCode) {
        guard let c = model.connection, let sync = model.sync else { return }
        let boundary = context
        let host = WorkspaceReportHost(authorize: {
            guard active, context == boundary, model.canRead else { throw FileNappletError.unavailable }
            try await sync.authorizeWorkspaceReport(c, workspace, fileId: file.id, code: code)
            guard active, context == boundary, model.canRead else { throw FileNappletError.unavailable }
        }, read: { range in
            guard active, context == boundary, model.canRead else { throw FileNappletError.unavailable }
            let value = try await sync.readWorkspaceReport(c, workspace, fileId: file.id, code: code, range: range)
            guard active, context == boundary, model.canRead else { throw FileNappletError.unavailable }
            return value
        })
        self.host = host; host.open(code)
    }
    private func forget() {
        host?.destroy(); host = nil; suppressRemembered = true
        do { if let receipt { try trustStore.forget(receipt) }; reopen += 1 }
        catch { failure = "Approval could not be forgotten on this device."; code = nil }
    }
}
#if os(iOS)
private struct ReportWebView: UIViewRepresentable {
    let page: NappletPage
    func makeUIView(context: Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct ReportWebView: NSViewRepresentable {
    let page: NappletPage
    func makeNSView(context: Context) -> WKWebView { page.webView ?? WKWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

struct WorkspaceReportAppView: View {
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

    private var attemptKey: String { "workspace-report.setup:" + [model.connection?.id ?? "", model.connection?.origin ?? "", model.connection?.signerNpub ?? "", workspace.id].joined(separator: "|") }
    private var context: [String] { [model.connection?.id ?? "", model.connection?.origin ?? "", model.connection?.signerNpub ?? "", model.selectedWorkspaceId ?? "", String(model.wikiContextEpoch), String(model.canRead), String(refresh)] }
    var body: some View {
        Group {
            if let selected, model.canRead, model.selectedWorkspaceId == workspace.id {
                #if os(macOS)
                if let store = model.store {
                    MacArtefactSurface(route: .file(workspaceId: workspace.id, fileId: selected.id), workspace: workspace, store: store) {
                        WorkspaceReportFileView(file: selected, workspace: workspace)
                    }.id(selected.id)
                }
                #else
                WorkspaceReportFileView(file: selected, workspace: workspace).id(selected.id)
                #endif
            } else if working { ProgressView("Checking Workspace Report…") }
            else if let failure {
                VStack(spacing: 16) { EmptyNote(title: "Workspace Report unavailable", systemImage: "lock", detail: failure); Button("Check again") { refresh += 1 } }
            } else if loaded && instances.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Set up Workspace Report").font(.headline)
                    Text("See message activity and current inventory for project channels you can access. Setup saves only the report code in your personal channel.")
                    Button("Set up Workspace Report") { setupTask = Task { await setup() } }.disabled(!model.isUnlocked || uncertain)
                }.padding().frame(maxWidth: 480).accessibilityIdentifier("workspace-report.setup")
            } else if loaded {
                List(instances) { file in
                    Button { selected = file } label: { VStack(alignment: .leading) { Text(file.displayName); Text(file.id).font(.caption) } }
                }.accessibilityIdentifier("workspace-report.choose")
            } else if !model.canRead { EmptyNote(title: "Workspace Report locked", systemImage: "lock", detail: "Unlock to open your private report.") }
            else { ProgressView("Opening Workspace Report…") }
        }
        .navigationTitle("Workspace Report")
        .task(id: context) { await discover() }
        .onDisappear { setupTask?.cancel() }
        .onChange(of: model.wikiContextEpoch) { _, _ in setupTask?.cancel(); selected = nil; instances = []; loaded = false }
    }
    private func discover() async {
        selected = nil; instances = []; loaded = false; failure = nil; working = false
        guard model.canRead else { failure = "Unlock to open this app."; return }
        guard model.selectedWorkspaceId == workspace.id, let c = model.connection, let sync = model.sync else { failure = "Reopen this app in its workspace."; return }
        let boundary = context
        working = true
        uncertain = UserDefaults.standard.bool(forKey: attemptKey)
        do {
            let rows = try await sync.workspaceReports(c, workspace)
            guard !Task.isCancelled, context == boundary else { return }
            instances = rows; loaded = true
            if !rows.isEmpty { uncertain = false; UserDefaults.standard.removeObject(forKey: attemptKey) }
            if rows.count == 1 { selected = rows[0] }
            if rows.isEmpty && uncertain { failure = "An earlier setup could not be confirmed. Inspect your personal Files before attempting another setup." }
        } catch { if !Task.isCancelled && context == boundary { failure = "Existing reports could not be fully verified. No new report has been created." } }
        if context == boundary { working = false }
    }
    private func setup() async {
        guard !working, !uncertain, loaded, instances.isEmpty, model.isUnlocked, let c = model.connection, let sync = model.sync,
              let url = Bundle.main.url(forResource: "workspace-report-v1", withExtension: "html"), let template = try? Data(contentsOf: url) else { return }
        let boundary = context
        working = true
        model.fileNappletNavigationOwner = setupOwner
        model.fileNappletNavigation = { _ in model.notice = "Wait for report setup to finish."; return true }
        model.fileNappletContextLost = { setupTask?.cancel() }
        defer {
            if model.fileNappletNavigationOwner == setupOwner {
                model.fileNappletNavigation = nil; model.fileNappletNavigationOwner = nil; model.fileNappletContextLost = nil
            }
        }
        do {
            // Recheck immediately before provisioning; another device may already have set it up.
            let rows = try await sync.workspaceReports(c, workspace)
            guard !Task.isCancelled, context == boundary, model.isUnlocked else { return }
            if !rows.isEmpty { instances = rows; selected = rows.count == 1 ? rows[0] : nil; working = false; return }
            uncertain = true
            UserDefaults.standard.set(true, forKey: attemptKey)
            let file = try await sync.createWorkspaceReport(c, workspace, template: template)
            guard !Task.isCancelled, context == boundary, model.isUnlocked else { return }
            uncertain = false; UserDefaults.standard.removeObject(forKey: attemptKey); instances = [file]; selected = file
        } catch { if context == boundary { failure = "Setup could not be confirmed. Check again to adopt any report already created. Existing data has not been replaced." } }
        if context == boundary { working = false }
    }
}
