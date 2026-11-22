import AmbulandoCore
import AppKit
import SwiftUI

/// Native presentation only. Records, authorization, editor bridges and storage remain owned by the shared views.
@MainActor @Observable
final class MacArtefactSession: NSObject, NSWindowDelegate {
    struct Key: Hashable {
        let signer: String
        let connection: String
        let workspace: String
        let app: String
        let route: WorkRoute
    }
    static var sessions: [Key: MacArtefactSession] = [:]
    let key: Key
    let route: WorkRoute
    let workspace: WorkspaceRecord
    let store: LocalStore
    let model: AppModel
    var window: NSWindow?
    var sources: Set<UUID> = []
    var editors: Set<UUID> = []
    var transferring = false
    var detached = false
    var busy = false
    var canDetach = true
    @ObservationIgnored var checkpoint: (() async -> Bool)?
    @ObservationIgnored var requestClose: ((@escaping () -> Void) -> Bool)?
    @ObservationIgnored var host: NSHostingView<AnyView>?

    init(key: Key, route: WorkRoute, workspace: WorkspaceRecord, store: LocalStore, model: AppModel) {
        self.key = key; self.route = route; self.workspace = workspace; self.store = store; self.model = model
    }
    var active: Bool {
        model.canRead && model.connection?.id == key.connection && model.connection?.signerNpub == key.signer &&
        model.selectedWorkspaceId == key.workspace && model.selectedWorkspace?.appNpub == key.app
    }
    func cleanup() {
        if sources.isEmpty && window == nil && !transferring {
            checkpoint = nil; requestClose = nil
            Self.sessions[key] = nil
        }
    }
    func show() async {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard active, canDetach, !busy, !transferring else { return }
        busy = true
        let allowed = await checkpoint?() ?? true
        busy = false
        guard allowed, active, canDetach else { return }
        // The original surface relinquishes its editor before a new one attaches to the same record/session.
        transferring = true
        detached = true
        // Wait for SwiftUI to release the source view and its WebKit bridge. A new host must
        // never race the old page's detach/clear callbacks or create a second private session.
        for _ in 0..<100 {
            if editors.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard editors.isEmpty, active else {
            detached = false; transferring = false
            return
        }
        checkpoint = nil; requestClose = nil; canDetach = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 640, height: 480)
        window.title = "Artefact — \(workspace.label)"; window.delegate = self
        self.window = window
        let host = NSHostingView(rootView: AnyView(MacArtefactContent(session: self).environment(model)))
        // HTML may initially have only a progress label or web-view intrinsic size. Keep the
        // native viewport stable rather than letting that transient measurement resize the window.
        host.sizingOptions = []
        self.host = host; window.contentView = host
        window.setContentSize(NSSize(width: 1100, height: 800))
        window.minSize = NSSize(width: 640, height: 480)
        window.center(); window.makeKeyAndOrderFront(nil)
        transferring = false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !busy else { return false }
        if requestClose?({ [weak self] in self?.window?.performClose(nil) }) == true { return false }
        busy = true
        Task { @MainActor in
            let allowed = await checkpoint?() ?? true
            busy = false
            guard allowed else { return }
            retire(); sender.close()
        }
        return false
    }
    func retire() {
        checkpoint = nil; requestClose = nil
        host?.rootView = AnyView(EmptyView()); host = nil
    }
    func windowWillClose(_ notification: Notification) {
        window = nil; detached = false; canDetach = true
        cleanup()
    }
}

struct MacArtefactSurface<Content: View>: View {
    @Environment(AppModel.self) private var model
    let route: WorkRoute
    let workspace: WorkspaceRecord
    let store: LocalStore
    @ViewBuilder let content: () -> Content
    @State private var session: MacArtefactSession?
    @State private var surfaceId = UUID()
    var body: some View {
        Group {
            if let session, session.detached {
                ContentUnavailableView {
                    Label("Artefact is open in its own window", systemImage: "macwindow")
                } actions: {
                    Button("Show Artefact Window") { Task { await session.show() } }.accessibilityIdentifier("artefact.window.focus")
                }
            } else {
                content().environment(\.macArtefactSession, session)
                    .onAppear { session?.editors.insert(surfaceId) }
                    .onDisappear { session?.editors.remove(surfaceId) }
                    .toolbar { ToolbarItem(placement: .primaryAction) {
                        if let session { MacArtefactWindowButton(session: session) }
                    } }
            }
        }
        .task(id: route) {
            guard let c = model.connection else { return }
            var recordRoute = route
            switch route {
            case .board(_, let canvas, let naplet):
                if let snapshot = try? await store.reader.canvasSnapshot(workspaceId: workspace.id, canvasId: canvas),
                   let scene = try? CanvasScene.parse(snapshot.bytes),
                   let item = scene.naplets.first(where: { $0.id == naplet }), case .excalidraw(let reference) = item.content {
                    recordRoute = .file(workspaceId: workspace.id, fileId: reference.fileId)
                }
            case .webContent(_, .installedNapplet(let key, _)):
                recordRoute = .webContent(workspaceId: workspace.id, source: .installedNapplet(key: key, title: ""))
            case .webContent(_, .htmlNaplet(let canvas, let naplet, _)):
                recordRoute = .webContent(workspaceId: workspace.id, source: .htmlNaplet(canvasId: canvas, napletId: naplet, title: ""))
                if let snapshot = try? await store.reader.canvasSnapshot(workspaceId: workspace.id, canvasId: canvas),
                   let scene = try? CanvasScene.parse(snapshot.bytes),
                   let item = scene.naplets.first(where: { $0.id == naplet }), case .html(let file, _) = item.content {
                    recordRoute = .file(workspaceId: workspace.id, fileId: file)
                }
            default: break
            }
            guard !Task.isCancelled, model.connection?.id == c.id, model.connection?.signerNpub == c.signerNpub,
                  model.selectedWorkspaceId == workspace.id, model.selectedWorkspace?.appNpub == workspace.appNpub else { return }
            let key = MacArtefactSession.Key(signer: c.signerNpub, connection: c.id, workspace: workspace.id, app: workspace.appNpub, route: recordRoute)
            let found = MacArtefactSession.sessions[key] ?? MacArtefactSession(key: key, route: route, workspace: workspace, store: store, model: model)
            MacArtefactSession.sessions[key] = found
            found.sources.insert(surfaceId)
            if !found.detached { found.editors.insert(surfaceId) }
            session = found
        }
        .onDisappear {
            session?.sources.remove(surfaceId); session?.editors.remove(surfaceId); session?.cleanup()
        }
    }
}

private struct MacArtefactWindowButton: View {
    let session: MacArtefactSession
    var body: some View {
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { Task { await session.show() } }
            .disabled(!session.active || session.busy || !session.canDetach)
            .help(session.canDetach ? "Open this saved artefact in its own window" : "Finish editing or saving before opening a new window")
            .accessibilityIdentifier("artefact.window.open")
    }
}

private struct MacArtefactContent: View {
    let session: MacArtefactSession
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @State private var phase: ScenePhase = .active
    var body: some View {
        NavigationStack {
            Group {
                switch session.route {
                case .file(_, let id): FileDetailView(fileId: id, workspace: session.workspace, store: session.store)
                case .board(_, let canvas, let naplet): BoardSceneView(canvasId: canvas, napletId: naplet, workspace: session.workspace, store: session.store)
                case .webContent(_, let source): WebContentView(source: source, workspace: session.workspace, store: session.store)
                default: EmptyView()
                }
            }
            .disabled(!session.active)
            .allowsHitTesting(session.active)
            .opacity(session.active ? 1 : 0)
            .accessibilityHidden(!session.active)
            .overlay {
                if !session.active {
                    ContentUnavailableView("Artefact workspace is inactive", systemImage: "lock", description: Text("Select \(session.workspace.label) in the main window to continue. This window keeps its original record."))
                        .accessibilityIdentifier("artefact.window.inactive")
                }
            }
            .environment(\.macArtefactSession, session)
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .environment(\.scenePhase, phase)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in phase = .active }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in phase = .inactive }
        .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
        .imageLightboxHost()
        .onChange(of: session.active) { _, active in
            if !active { session.window?.makeFirstResponder(nil) }
        }
    }
}

extension EnvironmentValues {
    @Entry var macArtefactSession: MacArtefactSession? = nil
}

extension AppModel {
    var macFocusedArtefact: Bool {
        let path: [WorkRoute]
        switch mode {
        case .deck: path = deckPath
        case .docs: path = docsPath
        case .files: path = filesPath
        case .tasks: path = tasksPath
        case .agents: path = agentsPath
        case .context: path = contextPath
        case .toolbox: path = toolboxPath
        case .chat: return false
        }
        switch path.last {
        case .doc, .board, .webContent: return true
        case .file: return true
        default: return false
        }
    }
}
