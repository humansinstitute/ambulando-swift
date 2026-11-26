import AmbulandoCore
import PhotosUI
import QuickLook
import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

struct FileGroup: Sendable, Equatable, Identifiable {
    let channel: ChannelRecord
    let folders: [(folder: FolderRecord, files: [FileRecord])]
    let loose: [FileRecord]
    var id: String { channel.id }

    static func == (a: FileGroup, b: FileGroup) -> Bool {
        a.channel == b.channel && a.loose == b.loose && a.folders.count == b.folders.count
            && zip(a.folders, b.folders).allSatisfy { $0.folder == $1.folder && $0.files == $1.files }
    }
}

struct FilesSnapshot: Sendable, Equatable {
    var groups: [FileGroup] = []
    var uploads: [WriteItem] = []
    var choice = ScopeChoice()
}

struct FilesView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore
    /// The shared sidebar context (scope, channel or Home); the list reads and new records are written inside it.
    private var context: WorkContext { model.context }
    private var scopeId: String? { model.context.scopeId }
    @State private var snapshot = LiveQuery<FilesSnapshot>(initial: FilesSnapshot())
    @State private var uploading = false

    var body: some View {
        List {
            if !snapshot.value.uploads.isEmpty {
                Section("Uploading") {
                    ForEach(snapshot.value.uploads) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.string("display_name") ?? "File", systemImage: "arrow.up.doc").font(.amb(.subheadline).weight(.semibold))
                            WriteStatusLine(item: item, label: "Upload")
                        }
                        .accessibilityIdentifier("upload.row")
                    }
                }
            }
            ForEach(snapshot.value.groups) { group in
                Section("#\(snapshot.value.choice.channelName(group.channel.id) ?? "Channel")") {
                    ForEach(group.folders, id: \.folder.id) { entry in
                        DisclosureGroup {
                            ForEach(entry.files) { fileRow($0) }
                            if entry.files.isEmpty { Text("Empty folder").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground) }
                        } label: {
                            Label(entry.folder.title, systemImage: "folder").foregroundStyle(Amb.foreground).appRowTextSize()
                        }
                        .accessibilityIdentifier("folder.\(entry.folder.title)")
                    }
                    ForEach(group.loose) { fileRow($0) }
                }
            }
        }
        .groupedList()
        .scrollContentBackground(.hidden)
        .overlay {
            if snapshot.loaded && snapshot.value.groups.isEmpty && snapshot.value.uploads.isEmpty {
                EmptyNote(title: "No files", systemImage: "folder", detail: model.isUnlocked ? "Files in this scope appear here. Tap + to upload." : "Unlock to load files.")
            }
        }
        .navigationTitle("Files")
        .safeAreaInset(edge: .top, spacing: 0) {
            ListHeaderBar {
                Spacer()
                Button { uploading = true } label: { Image(systemName: "plus.circle.fill").font(.amb(.title2)) }
                    .accessibilityLabel("Upload").accessibilityIdentifier("files.upload")
            }
        }
        .sheet(isPresented: $uploading) { UploadSheet(workspace: workspace, choice: snapshot.value.choice, context: context) }
        .refreshable { model.openFiles(workspace, scopeId: scopeId, force: true) }
        .task(id: model.context) { start(); model.openFiles(workspace, scopeId: scopeId) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openFiles(workspace, scopeId: scopeId) } }
    }

    private func fileRow(_ file: FileRecord) -> some View {
        NavigationLink(value: WorkRoute.file(workspaceId: workspace.id, fileId: file.id)) {
            HStack(spacing: 10) {
                Image(systemName: FileIcon.name(file.contentType)).foregroundStyle(Amb.primary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName).font(.amb(.subheadline)).foregroundStyle(Amb.foreground).lineLimit(2)
                    Text([byteLabel(file.sizeBytes), ChatTime.label(file.updatedAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
            }
        }
        .accessibilityIdentifier("file.\(file.displayName)")
    }

    private func start() {
        let w = workspace.id, context = context, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { ($0.workspaceId == w && [.files, .folders, .writes, .channels, .scopes, .members].contains($0.table)) || $0.table == .profiles }) {
            let choice = try await scopeChoice(store, w)
            let files = try await store.reader.files(workspaceId: w, context: context)
            let byChannel = Dictionary(grouping: files, by: \.channelId)
            var groups: [FileGroup] = []
            for channel in choice.channels(in: context) {
                let folders = try await store.reader.folders(workspaceId: w, channelId: channel.id)
                let all = byChannel[channel.id] ?? []
                let folderIds = Set(folders.map(\.id))
                guard !all.isEmpty || !folders.isEmpty else { continue }
                groups.append(FileGroup(channel: channel, folders: folders.map { f in (f, all.filter { $0.folderId == f.id }) },
                                        loose: all.filter { $0.folderId == nil || !folderIds.contains($0.folderId!) }))
            }
            let uploads = try await store.reader.writes(connectionId: connection, workspaceId: w).filter { $0.kind == .fileUpload }
            return FilesSnapshot(groups: groups, uploads: uploads, choice: choice)
        }
    }
}

enum FileIcon {
    static func name(_ type: String?) -> String {
        let t = (type ?? "").lowercased()
        if t.hasPrefix("image/") { return "photo" }
        if t.hasPrefix("video/") { return "film" }
        if t.hasPrefix("audio/") { return "waveform" }
        if t.contains("pdf") { return "doc.richtext" }
        if t.contains("csv") || t.contains("spreadsheet") { return "tablecells" }
        if t.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }
}

// MARK: Detail and preview

struct FileDetailSnapshot: Sendable, Equatable {
    var file: FileRecord?
    var cached: URL?
    var choice = ScopeChoice()
}

struct FileDetailView: View {
    @Environment(AppModel.self) private var model
    let fileId: String
    let workspace: WorkspaceRecord
    let store: LocalStore
    var renderArtefact = true
    @State private var snapshot = LiveQuery<FileDetailSnapshot>(initial: FileDetailSnapshot())
    @State private var preview: URL?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloading = false
    @State private var downloadError: String?
    @State private var savedDownload: URL?
    @State private var exportFile: BrowserDownloadFile?
    @State private var exporting = false

    var body: some View {
        Group {
            if renderArtefact, let file = snapshot.value.file, let type = ArtefactType.file(file) {
                FileArtefactView(file: file, type: type, workspace: workspace)
            } else { detail }
        }
        .task {
            start()
            if let sync = model.sync, let c = model.connection { await sync.refreshArtefactFile(c, workspace, fileId: fileId) }
        }
    }

    private var detail: some View {
        List {
            if let file = snapshot.value.file {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: FileIcon.name(file.contentType)).font(.amb(.largeTitle)).foregroundStyle(Amb.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.displayName).font(.amb(.headline)).accessibilityIdentifier("file.name")
                            Text([file.contentType, byteLabel(file.sizeBytes)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                        }
                    }
                    if let channel = snapshot.value.choice.channelName(file.channelId) { LabeledContent("Channel", value: "#\(channel)").appRowTextSize() }
                    LabeledContent("Updated", value: ChatTime.label(file.updatedAt)).appRowTextSize()
                    if let description = file.description, !description.isEmpty { Text(description).font(.amb(.footnote)) }
                }
                Section {
                    if downloading {
                        HStack { ProgressView(); Text("Downloading…") }.appRowTextSize()
                        Button("Cancel download") { downloadTask?.cancel() }
                    } else {
                        Button { beginDownload(file) } label: { Label(downloadError == nil ? "Download" : "Retry download", systemImage: "arrow.down.circle").appRowTextSize() }
                            .disabled(!model.isUnlocked).accessibilityIdentifier("file.download")
                        if !model.isUnlocked { Text("Unlock to download.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground) }
                    }
                    if let savedDownload {
                        #if os(macOS)
                        Text("Saved \(savedDownload.lastPathComponent) to Downloads.").accessibilityIdentifier("file.saved")
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedDownload]) }
                        #else
                        Text("Saved \(savedDownload.lastPathComponent) to your chosen location.").accessibilityIdentifier("file.saved")
                        #endif
                    }
                    if let downloadError { Text(downloadError).font(.amb(.footnote)).foregroundStyle(Amb.destructive).accessibilityIdentifier("file.downloadError") }
                    if let url = snapshot.value.cached {
                        Button { preview = url } label: { Label("Preview", systemImage: "eye").appRowTextSize() }.accessibilityIdentifier("file.preview")
                        ShareLink(item: url) { Label("Share or save", systemImage: "square.and.arrow.up").appRowTextSize() }
                        #if os(macOS)
                        Button { MacFiles.saveCopy(of: url, suggestedName: file.displayName) } label: { Label("Save As…", systemImage: "square.and.arrow.down").appRowTextSize() }
                            .accessibilityIdentifier("file.saveAs")
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open in Default App", systemImage: "arrow.up.forward.app").appRowTextSize() }
                            .accessibilityIdentifier("file.openExternally")
                        #endif
                    }
                } footer: {
                    #if os(macOS)
                    Text("Download saves a checked copy in Downloads. Existing files are kept.")
                    #else
                    Text("Download checks the file, then lets you choose where to save it.")
                    #endif
                }
            } else if snapshot.loaded {
                Text("This file is not on this \(Device.name).").foregroundStyle(Amb.mutedForeground).appRowTextSize()
            }
        }
        .groupedList()
        .tabletReadingWidth()
        .scrollContentBackground(.hidden)
        .background(Amb.canvas)   // grouped rows (white) on the recessed surface
        .fixtureLabel()
        .navigationTitle("File")
        .inlineTitle()
        .quickLookPreview($preview)
        .task { start() }
        .onDisappear { downloadTask?.cancel() }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .data,
                      defaultFilename: snapshot.value.file?.displayName ?? "file") { result in
            switch result {
            case .success(let url): savedDownload = url
            case .failure(let error): downloadError = "Could not save: \(error.localizedDescription). Try Download again."
            }
            exportFile = nil
        }
    }

    private func beginDownload(_ file: FileRecord) {
        guard !downloading else { return }
        downloading = true
        downloadError = nil
        savedDownload = nil
        downloadTask = Task { @MainActor in
            defer { downloading = false; downloadTask = nil }
            // Cancelling the foreground waiter releases its engine slot, even for an unresponsive transport.
            let operation = Task { try await model.fileForExport(file, in: workspace) }
            let deadline = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { operation.cancel() } }
            defer { deadline.cancel() }
            do {
                let source = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
                try Task.checkCancellation()
                #if os(macOS)
                let destination = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                savedDownload = try await Task.detached { try DownloadCopy.save(source, name: file.displayName, directory: destination) }.value
                #else
                let bytes = try await Task.detached { try Data(contentsOf: source) }.value
                try Task.checkCancellation()
                exportFile = BrowserDownloadFile(bytes: bytes)
                exporting = true
                #endif
            } catch is CancellationError {
                downloadError = "Download cancelled or timed out. Try Download again."
            } catch {
                downloadError = "Could not save download: \(error.localizedDescription). Try Download again."
            }
        }
    }

    private func start() {
        let w = workspace.id, id = fileId, store = store, cache = model.fileCache
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.files, .channels].contains($0.table) }) {
            let file = try await store.reader.file(workspaceId: w, id: id)
            return FileDetailSnapshot(file: file, cached: file.flatMap { cache?.cached($0) }, choice: try await scopeChoice(store, w))
        }
    }
}

// MARK: Upload

struct UploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceRecord
    let choice: ScopeChoice
    let context: WorkContext
    @State private var channelId: String?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var message: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Channel", selection: $channelId) {
                    ForEach(choice.channels(in: context)) { Text("#\(choice.channelName($0.id) ?? "Channel")").tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("upload.channel")
                Section {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo.on.rectangle") }
                        .accessibilityIdentifier("upload.photo")
                    Button { importing = true } label: { Label("File from Files", systemImage: "folder") }.accessibilityIdentifier("upload.file")
                } footer: {
                    Text("Photos are converted to PNG without location or camera metadata. Uploads wait on this \(Device.name) until they reach Tower.")
                }
                if working { ProgressView() }
                if let message { Text(message).foregroundStyle(Amb.destructive) }
            }
            .navigationTitle("Upload")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { channelId = channelId ?? context.channelId ?? choice.channels(in: context).first?.id }
            .onChange(of: photo) { _, item in if let item { Task { await stagePhoto(item) } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { Task { await stageFile(url) } }
            }
        }
    }

    private func stagePhoto(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else { message = "That photo could not be read."; return }
        let png: Data
        do { png = try await Task.detached { try ImagePrivacy.strippedPNG(data) }.value }
        catch { message = "That photo could not be converted."; return }
        let name = "Photo \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).png".replacingOccurrences(of: ":", with: "-")
        enqueue(bytes: png, name: name, type: "image/png")
    }

    private func stageFile(_ url: URL) async {
        working = true
        defer { working = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard (values?.fileSize ?? 0) <= TowerAPI.maxDownloadBytes else { message = "Files over 100 MB are not uploaded from this app."; return }
        guard let data = try? await Task.detached(operation: { try Data(contentsOf: url) }).value else { message = "That file could not be read."; return }
        enqueue(bytes: data, name: url.lastPathComponent, type: values?.contentType?.preferredMIMEType ?? "application/octet-stream")
    }

    private func enqueue(bytes: Data, name: String, type: String) {
        guard let channelId, let staging = model.staging else { return }
        let staged = UUID().uuidString.lowercased()
        do { try bytes.write(to: staging.appendingPathComponent(staged), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { message = error.localizedDescription; return }
        let payload: [String: any Sendable] = ["channel_id": channelId, "staged": staged, "content_type": type, "file_name": name, "display_name": name]
        if model.submit(WriteIntent(kind: .fileUpload, targetId: channelId, payload: payload), in: workspace) { dismiss() }
    }
}

/// Every channel, chat and personal pin File route opens the same saved artefact.
struct FileArtefactView: View {
    #if os(macOS)
    @Environment(\.macThreadArtefactTab) private var threadTab
    @Environment(\.macArtefactSession) private var macSession
    #endif
    @Environment(AppModel.self) private var model
    let file: FileRecord
    let type: ArtefactType
    let workspace: WorkspaceRecord
    @State private var session: BoardSession?
    @State private var error: String?

    @State private var exportingOriginal = false
    var body: some View {
        VStack(spacing: 0) {
            if let session {
                BoardNotices(session: session).padding(8)
                BoardEditorPanel(session: session)
            } else if type == .html {
                DirectHTMLFileView(file: file, workspace: workspace)
            } else if let error { EmptyNote(title: "Artefact unavailable", systemImage: "lock", detail: error) }
            else { ProgressView("Loading artefact…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        #if os(macOS)
        .onChange(of: session?.key, initial: true) { _, _ in
            threadTab?.title = file.displayName
            if let session {
                threadTab?.checkpoint = { await session.controller.checkpoint() }
                threadTab?.validate = { await session.controller.matchesChatRevision($0) }
                threadTab?.prepare = { try await session.controller.prepareChatRevision() }
            }
            macSession?.checkpoint = { [weak session] in await session?.controller.checkpoint() ?? true }
        }
        #endif
        .sheet(isPresented: $exportingOriginal) {
            if let store = model.store {
                NavigationStack {
                    FileDetailView(fileId: file.id, workspace: workspace, store: store, renderArtefact: false)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { exportingOriginal = false } } }
                }.frame(minWidth: 320, minHeight: 400)
            }
        }
        .navigationTitle(file.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Download or share original", systemImage: "square.and.arrow.up") { exportingOriginal = true }
                    .disabled(!model.canRead).accessibilityIdentifier("artefact.export")
                if let session { BoardStatusPill(state: session.state); BoardMenu(session: session) }
                Button {
                    model.setPinned(!model.pins.value.isPinned(.file, file.id), type: .file, id: file.id, in: workspace)
                } label: { Image(systemName: model.pins.value.isPinned(.file, file.id) ? "pin.fill" : "pin") }
                .accessibilityLabel("Pin artefact").disabled(!model.isUnlocked)
            }
        }
        .task(id: [file.id, String(model.canRead), model.selectedWorkspaceBoundary?.id ?? ""]) {
            session = nil; error = nil
            guard let sync = model.sync, let connection = model.connection, model.canRead else { error = "Unlock to open this artefact."; return }
            let boundary = model.selectedWorkspaceBoundary
            do {
                if type == .whiteboard {
                    let reference = try await sync.artefactBoard(connection, workspace, fileId: file.id)
                    guard boundary == model.selectedWorkspaceBoundary, model.canRead else { return }
                    session = model.boardSession(reference, title: file.displayName, in: workspace)
                }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: model.canRead) { _, canRead in if !canRead { session = nil; error = "Unlock to open this artefact." } }
    }
}

struct HTMLSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: FileRecord
    let workspace: WorkspaceRecord
    @State private var versions: [BoardVersion] = []
    @State private var base = ""
    @State private var selected = ""
    @State private var source = ""
    @State private var message: String?
    @State private var busy = false
    @State private var ready = false
    @State private var loadedSource = ""
    @State private var draftConnectionId: String?
    @State private var draftBoundary: WorkspaceBoundary?
    @State private var legacyRecovery: HTMLSourceDraftStore.Draft?
    @State private var confirmLegacy = false
    private var canWrite: Bool {
        let row = (try? JSONSerialization.jsonObject(with: file.raw)) as? [String: Any]
        return model.isUnlocked && row?["can_write"] as? Bool == true
    }
    private var draftStore: HTMLSourceDraftStore? {
        guard let id = draftConnectionId, let boundary = draftBoundary else { return nil }
        return HTMLSourceDraftStore(directory: BoardRegistry.draftsDirectory(id, dataDirectory: model.fixture?.directory),
                                    boundary: boundary, fileId: file.id, allowLegacy: model.fixture == nil)
    }
    private var draftURL: URL? { draftStore?.url }
    private func keepDraft() {
        guard ready, let url = draftURL, model.isUnlocked, model.connection?.id == draftConnectionId, model.selectedWorkspaceBoundary == draftBoundary, model.selectedWorkspaceId == workspace.id else { return }
        if source == loadedSource { try? FileManager.default.removeItem(at: url); return }
        do {
            try draftStore?.save(.init(base: base, source: source))
        } catch { message = "Could not keep a recovery draft: \(error.localizedDescription)" }
    }
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Version", selection: $selected) {
                    ForEach(versions) { Text("Version \($0.number)").tag($0.id) }
                }.disabled(busy || (ready && source != loadedSource))
                Text("Viewing an older version loads its source as a draft. Save publishes a new revision.")
                    .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                TextEditor(text: $source).font(.system(.body, design: .monospaced)).disabled(!ready || busy || !canWrite)
                if let message { Text(message).foregroundStyle(Amb.warning).padding(8) }
                if legacyRecovery != nil {
                    Button("Review older recovery draft…") { confirmLegacy = true }.disabled(!ready || busy)
                    Text("An older draft for this connection and File has no saved application boundary. Review it before saving; its original copy is kept.").font(.amb(.caption))
                }
                if ready && source != loadedSource {
                    Text("Your draft is kept on close. Save before browsing another revision.").font(.amb(.caption))
                    Button("Keep draft on latest revision…") { Task { await rebase() } }.disabled(busy)
                }
            }.padding()
            .navigationTitle("HTML source & history")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save revision") { Task { await save() } }.disabled(!ready || busy || !canWrite) }
            }
            .task { await load() }
            .onChange(of: selected) { _, id in if ready { Task { await read(id) } } }
            .onChange(of: source) { _, _ in keepDraft() }
            .onDisappear { keepDraft() }
        }
        .frame(minWidth: 300, minHeight: 400)
        .interactiveDismissDisabled(busy)
        .confirmationDialog("Load the older draft for review?", isPresented: $confirmLegacy, titleVisibility: .visible) {
            Button("Load draft for review") {
                guard let recovery = legacyRecovery, model.selectedWorkspaceBoundary == draftBoundary, model.isUnlocked else { return }
                base = recovery.base; source = recovery.source; legacyRecovery = nil
                keepDraft()
                message = "Older source loaded for review. Nothing is published until Save revision. The original recovery copy is kept."
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This replaces the source currently in the editor. The older file did not record which application owned it. Verify its content before publishing.") }
    }
    private func load() async {
        guard let sync = model.sync, let c = model.connection, model.selectedWorkspaceId == workspace.id else { return }
        draftConnectionId = c.id
        draftBoundary = model.selectedWorkspaceBoundary
        do {
            let recovery = draftStore?.load()
            legacyRecovery = draftStore?.legacyForReview()
            let history = try await sync.htmlHistory(c, workspace, fileId: file.id)
            guard model.connection?.id == c.id, model.selectedWorkspaceId == workspace.id, model.selectedWorkspaceBoundary == draftBoundary else { return }
            versions = history.versions; base = history.currentVersionId ?? ""; selected = base
            await read(base)
            guard model.selectedWorkspaceBoundary == draftBoundary, model.canRead else { return }
            if let recovery {
                base = recovery.base; source = recovery.source; ready = true; message = "Recovered your unsaved source. Save checks its original revision."
            }
        } catch { message = error.localizedDescription }
    }
    private func read(_ id: String) async {
        guard let sync = model.sync, let c = model.connection, let version = versions.first(where: { $0.id == id }) else { return }
        busy = true; ready = false
        defer { busy = false }
        do {
            let text = try await sync.htmlSource(c, workspace, fileId: file.id, version: version)
            guard model.connection?.id == c.id, model.selectedWorkspaceId == workspace.id, model.selectedWorkspaceBoundary == draftBoundary else { return }
            source = text; loadedSource = source; ready = true; message = nil
        }
        catch { message = error.localizedDescription }
    }
    private func rebase() async {
        guard let sync = model.sync, let c = model.connection, model.selectedWorkspaceBoundary == draftBoundary, model.isUnlocked else { return }
        busy = true
        defer { busy = false }
        do {
            let history = try await sync.htmlHistory(c, workspace, fileId: file.id)
            guard model.selectedWorkspaceBoundary == draftBoundary, let current = history.currentVersionId else { return }
            base = current; versions = history.versions; keepDraft()
            message = "Your source is retained against the latest revision. Review it, then Save revision to publish."
        } catch { message = error.localizedDescription }
    }
    private func save() async {
        guard let sync = model.sync, let c = model.connection, !base.isEmpty, model.selectedWorkspaceBoundary == draftBoundary, model.isUnlocked else { return }
        busy = true
        defer { busy = false }
        do {
            try await sync.saveHTML(c, workspace, fileId: file.id, base: base, source: source, title: file.displayName)
            guard model.selectedWorkspaceBoundary == draftBoundary else { return }
            if let url = draftURL { try? FileManager.default.removeItem(at: url) }
            ready = false
            dismiss()
        } catch { keepDraft(); message = "Save failed; your source remains here. \(error.localizedDescription)" }
    }
}
