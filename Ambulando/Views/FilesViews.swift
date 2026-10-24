import AmbulandoCore
import PhotosUI
import QuickLook
import SwiftUI
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
    @State private var scopeId: String?
    @State private var snapshot = LiveQuery<FilesSnapshot>(initial: FilesSnapshot())
    @State private var uploading = false

    var body: some View {
        List {
            if !snapshot.value.uploads.isEmpty {
                Section("Uploading") {
                    ForEach(snapshot.value.uploads) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.string("display_name") ?? "File", systemImage: "arrow.up.doc").font(.subheadline.weight(.semibold))
                            WriteStatusLine(item: item, label: "Upload")
                        }
                        .accessibilityIdentifier("upload.row")
                    }
                }
            }
            ForEach(snapshot.value.groups) { group in
                Section("#\(group.channel.name)") {
                    ForEach(group.folders, id: \.folder.id) { entry in
                        DisclosureGroup {
                            ForEach(entry.files) { fileRow($0) }
                            if entry.files.isEmpty { Text("Empty folder").font(.footnote).foregroundStyle(Amb.mutedForeground) }
                        } label: {
                            Label(entry.folder.title, systemImage: "folder").foregroundStyle(Amb.foreground)
                        }
                        .accessibilityIdentifier("folder.\(entry.folder.title)")
                    }
                    ForEach(group.loose) { fileRow($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if snapshot.loaded && snapshot.value.groups.isEmpty && snapshot.value.uploads.isEmpty {
                EmptyNote(title: "No files", systemImage: "folder", detail: model.isUnlocked ? "Files in this scope appear here. Tap + to upload." : "Unlock to load files.")
            }
        }
        .navigationTitle("Files")
        .safeAreaInset(edge: .top, spacing: 0) {
            ListHeaderBar {
                ScopeMenu(choice: snapshot.value.choice, selection: $scopeId)
                Spacer()
                Button { uploading = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                    .accessibilityLabel("Upload").accessibilityIdentifier("files.upload")
            }
        }
        .sheet(isPresented: $uploading) { UploadSheet(workspace: workspace, choice: snapshot.value.choice, scopeId: scopeId) }
        .refreshable { model.openFiles(workspace, scopeId: scopeId, force: true) }
        .task(id: scopeId) { start(); model.openFiles(workspace, scopeId: scopeId) }
        .onChange(of: model.identity) { _, state in if case .unlocked = state { model.openFiles(workspace, scopeId: scopeId) } }
    }

    private func fileRow(_ file: FileRecord) -> some View {
        NavigationLink(value: WorkRoute.file(workspaceId: workspace.id, fileId: file.id)) {
            HStack(spacing: 10) {
                Image(systemName: FileIcon.name(file.contentType)).foregroundStyle(Amb.primary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName).font(.subheadline).foregroundStyle(Amb.foreground).lineLimit(2)
                    Text([byteLabel(file.sizeBytes), ChatTime.label(file.updatedAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Amb.mutedForeground)
                }
            }
        }
        .accessibilityIdentifier("file.\(file.displayName)")
    }

    private func start() {
        let w = workspace.id, scope = scopeId, store = store, connection = model.connection?.id ?? ""
        snapshot.start(store: store, matches: { $0.workspaceId == w && [.files, .folders, .writes, .channels, .scopes].contains($0.table) }) {
            let choice = try await scopeChoice(store, w)
            let files = try await store.reader.files(workspaceId: w)
            let byChannel = Dictionary(grouping: files, by: \.channelId)
            var groups: [FileGroup] = []
            for channel in choice.channels where scope == nil || channel.scopeId == scope {
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
    @State private var snapshot = LiveQuery<FileDetailSnapshot>(initial: FileDetailSnapshot())
    @State private var preview: URL?

    var body: some View {
        List {
            if let file = snapshot.value.file {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: FileIcon.name(file.contentType)).font(.largeTitle).foregroundStyle(Amb.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.displayName).font(.headline).accessibilityIdentifier("file.name")
                            Text([file.contentType, byteLabel(file.sizeBytes)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Amb.mutedForeground)
                        }
                    }
                    if let channel = snapshot.value.choice.channelName(file.channelId) { LabeledContent("Channel", value: "#\(channel)") }
                    LabeledContent("Updated", value: ChatTime.label(file.updatedAt))
                    if let description = file.description, !description.isEmpty { Text(description).font(.footnote) }
                }
                Section {
                    if let url = snapshot.value.cached {
                        Button { preview = url } label: { Label("Preview", systemImage: "eye") }.accessibilityIdentifier("file.preview")
                        ShareLink(item: url) { Label("Share or save", systemImage: "square.and.arrow.up") }
                    } else if model.isSyncing(WorkspaceSync.downloadKey(workspace.id, file.id)) {
                        HStack { ProgressView(); Text("Downloading…").foregroundStyle(Amb.mutedForeground) }
                    } else {
                        Button { model.download(file, in: workspace) } label: { Label("Download", systemImage: "arrow.down.circle") }
                            .disabled(!model.isUnlocked).accessibilityIdentifier("file.download")
                        if !model.isUnlocked { Text("Unlock to download.").font(.footnote).foregroundStyle(Amb.mutedForeground) }
                    }
                    if let error = model.syncError(forKey: WorkspaceSync.downloadKey(workspace.id, file.id)) { Text(error).font(.footnote).foregroundStyle(Amb.destructive) }
                } footer: {
                    Text("Downloads are checked against the file's checksum and kept in this app's cache.")
                }
            } else if snapshot.loaded {
                Text("This file is not on this iPhone.").foregroundStyle(Amb.mutedForeground)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Amb.background)
        .fixtureLabel()
        .navigationTitle("File")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .task { start() }
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
    let scopeId: String?
    @State private var channelId: String?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var message: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Channel", selection: $channelId) {
                    ForEach(choice.channels.filter { scopeId == nil || $0.scopeId == scopeId }) { Text("#\($0.name)").tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("upload.channel")
                Section {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo.on.rectangle") }
                        .accessibilityIdentifier("upload.photo")
                    Button { importing = true } label: { Label("File from Files", systemImage: "folder") }.accessibilityIdentifier("upload.file")
                } footer: {
                    Text("Photos are converted to PNG without location or camera metadata. Uploads wait on this iPhone until they reach Tower.")
                }
                if working { ProgressView() }
                if let message { Text(message).foregroundStyle(Amb.destructive) }
            }
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { channelId = channelId ?? choice.channels.first { scopeId == nil || $0.scopeId == scopeId }?.id }
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
