import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Page text view

/// One page of text in a native text view: monospaced, plain, no smart substitutions, so what is shown and what is
/// saved are the same scalars. The text is written to the view only when `identity` changes (another page or version),
/// never while the user types, so the caret and any input method composition are not disturbed.
#if os(iOS)
struct PageTextView: UIViewRepresentable {
    let text: String
    let identity: Int
    let editable: Bool
    let onChange: (String) -> Void
    let onLargeReplacement: (NSRange, String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(Amb.foreground)
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocapitalizationType = .none
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "textfile.content"
        view.text = text
        context.coordinator.identity = identity
        view.isEditable = editable
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.identity != identity {
            context.coordinator.identity = identity
            view.text = text
            view.setContentOffset(.zero, animated: false)
        }
        if view.isEditable != editable { view.isEditable = editable }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PageTextView
        var identity = -1
        init(parent: PageTextView) { self.parent = parent }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let count = text.unicodeScalars.count + (textView.text ?? "").unicodeScalars.count
            if count > TextPages.pageScalars + 2_000 {
                parent.onLargeReplacement(range, text); return false
            }
            return true
        }
        func textViewDidChange(_ view: UITextView) { parent.onChange(view.text ?? "") }
    }
}
#else
struct PageTextView: NSViewRepresentable {
    let text: String
    let identity: Int
    let editable: Bool
    let onChange: (String) -> Void
    let onLargeReplacement: (NSRange, String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textColor = NSColor(Amb.foreground)
        view.drawsBackground = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.setAccessibilityIdentifier("textfile.content")
        view.string = text
        context.coordinator.identity = identity
        view.isEditable = editable
        view.isSelectable = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if context.coordinator.identity != identity {
            context.coordinator.identity = identity
            view.string = text
            view.undoManager?.removeAllActions()
            view.scrollToBeginningOfDocument(nil)
        }
        if view.isEditable != editable { view.isEditable = editable }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PageTextView
        var identity = -1
        init(parent: PageTextView) { self.parent = parent }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            if replacementString.unicodeScalars.count + textView.string.unicodeScalars.count > TextPages.pageScalars + 2_000 {
                parent.onLargeReplacement(affectedCharRange, replacementString); return false
            }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.onChange(view.string)
        }
    }
}
#endif

// MARK: Document model

/// A text file open in the modal: its pages, which page is shown, and its (debounced) size and line counts. Only the
/// current page is ever in a text view; the others are plain strings.
@MainActor
@Observable
final class TextDocumentModel {
    enum Phase: Equatable { case loading, ready, failed(String), notText }

    private(set) var phase = Phase.loading
    private(set) var pages = TextPages(text: "")
    private(set) var pageIndex = 0
    /// Bumps whenever the text view must be reloaded (another page or content).
    private(set) var generation = 0
    private(set) var dirty = false
    private(set) var lines = 0
    private(set) var bytes = 0
    private(set) var chars = 0
    /// Raw bytes of a file that is not UTF-8 text (download/copy only).
    private(set) var rawBytes: Data?
    @ObservationIgnored private var stats: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    var pageCount: Int { pages.pageCount }
    var currentPage: String { pages.page(pageIndex) }

    /// Builds the pages off the main actor (a multi-megabyte file never blocks typing in the composer behind the modal).
    func load(_ produce: @escaping @Sendable () async throws -> Data) {
        loading?.cancel()
        phase = .loading
        loading = Task { [weak self] in
            do {
                let data = try await produce()
                let built = await Task.detached(priority: .userInitiated) { () -> (TextPages?, Int) in (TextPages(data: data), TextAttachmentPolicy.lineCount(data)) }.value
                guard !Task.isCancelled else { return }
                self?.finishLoad(data: data, pages: built.0, lines: built.1)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed((error as? LocalizedError)?.errorDescription ?? "The file could not be loaded.")
            }
        }
    }

    private func finishLoad(data: Data, pages built: TextPages?, lines: Int) {
        if let built {
            pages = built; rawBytes = nil; pageIndex = 0; generation += 1
            self.lines = lines; bytes = built.byteCount; chars = built.codePoints
            dirty = false
            phase = .ready
        } else {
            rawBytes = data; bytes = data.count; self.lines = lines
            phase = .notText
        }
    }

    func edit(_ text: String) {
        guard !text.utf8.elementsEqual(pages.page(pageIndex).utf8) else { return }
        pages.replace(page: pageIndex, with: text)
        dirty = true
        bytes = pages.byteCount; chars = pages.codePoints
        scheduleLineCount()
    }

    func replaceLarge(range: NSRange, text: String) async {
        let snapshot = pages, index = pageIndex, token = generation
        phase = .loading
        let updated = await Task.detached(priority: .userInitiated) { () -> TextPages in
            var next = snapshot
            let page = snapshot.page(index) as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= page.length else { return next }
            next.replace(page: index, with: page.replacingCharacters(in: range, with: text))
            return next
        }.value
        guard generation == token else { return }
        pages = updated; generation += 1; dirty = true; phase = .ready
        bytes = pages.byteCount; chars = pages.codePoints; scheduleLineCount()
    }

    func show(page index: Int) {
        let clamped = min(max(index, 0), pages.pageCount - 1)
        guard clamped != pageIndex else { return }
        pageIndex = clamped
        generation += 1
    }

    /// The full text as bytes, built on demand (save, copy, download).
    func data() -> Data { rawBytes ?? pages.data }

    func markSaved() { dirty = false }

    private func scheduleLineCount() {
        stats?.cancel()
        let snapshot = pages
        stats = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let lines = await Task.detached(priority: .utility) { TextAttachmentPolicy.lineCount(snapshot.data) }.value
            if !Task.isCancelled { self?.lines = lines }
        }
    }
}

/// Bytes for the "Download" file exporter.
struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: Modal

/// What the modal opens: a file staged in the composer (editable, saved back to the draft) or a sent attachment (read,
/// then edited as a new version).
enum TextAttachmentSubject: Identifiable {
    case draft(PendingAttachment)
    case sent(message: MessageRecord, attachment: MessageAttachment)

    var id: String {
        switch self {
        case .draft(let a): "draft:" + a.id
        case .sent(let m, let a): "sent:" + m.id + ":" + a.storageObjectId
        }
    }
}

extension View {
    /// Desktop: a centered sheet. Phone and tablet: full screen.
    func textAttachmentModal<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(macOS)
        sheet(item: item) { content($0).frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640) }
        #else
        fullScreenCover(item: item) { content($0) }
        #endif
    }
}

struct TextAttachmentModal: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let subject: TextAttachmentSubject
    let workspace: WorkspaceRecord
    /// Draft mode: the replacement for the edited attachment (the composer keeps its place in the draft).
    var onSaveDraft: ((PendingAttachment) async throws -> Void)?

    @State private var doc = TextDocumentModel()
    @State private var filename = ""
    @State private var editing = false
    @State private var confirmDiscard = false
    @State private var exporting = false
    @State private var exportData = Data()
    @State private var notice: String?
    @State private var failure: String?
    @State private var saving = false
    @State private var lineage: TextLineage?
    @State private var history: [TextVersionRef] = []
    @State private var currentVersionId: String?
    @State private var viewing: TextVersionRef?
    @State private var conflict: TextVersionRef?
    @State private var historyLoaded = false
    @State private var showingHistory = false
    @State private var jump = ""
    @State private var mutationId = UUID().uuidString.lowercased()
    @State private var pendingEdit: PendingTextEdit?
    @State private var openGeneration = UUID()
    @State private var editAutosave: Task<Void, Never>?

    private var isDraft: Bool { if case .draft = subject { true } else { false } }
    private var sent: (message: MessageRecord, attachment: MessageAttachment)? {
        if case .sent(let m, let a) = subject { (m, a) } else { nil }
    }
    private var viewingLatest: Bool { viewing == nil || viewing?.versionId == currentVersionId || (currentVersionId == nil && viewing?.isOriginal == true) }
    private var service: TextAttachmentService? { model.textService(for: workspace) }
    private var originalFilename: String {
        switch subject { case .draft(let a): a.filename; case .sent(_, let a): a.filename }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Amb.border)
                content
                Divider().overlay(Amb.border)
                pager
            }
            .background(Amb.canvas)
            .navigationTitle(isDraft ? "Text attachment" : filename)
            .inlineTitle()
            .toolbar { toolbar }
            .interactiveDismissDisabled(doc.dirty)
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { Task { await discardLocalEdit(); dismiss() } }
                if !isDraft {
                    Button("Keep edit on this device and close") { Task { await keepLocalAndClose() } }
                        .accessibilityIdentifier("textfile.keepLocal")
                }
                Button("Keep editing", role: .cancel) {}
            }
            .sheet(isPresented: $showingHistory) { NavigationStack { historySheet.navigationTitle("Versions").inlineTitle() }.frame(minWidth: 320, minHeight: 320) }
            .fileExporter(isPresented: $exporting, document: TextFileDocument(data: exportData), contentType: .plainText, defaultFilename: filename) { result in
                if case .failure(let error) = result { failure = error.localizedDescription } else { notice = "Saved a copy." }
            }
        }
        .task { await open() }
        .onChange(of: filename) { _, _ in if editing && !isDraft { persistLocalEdit() } }
        .accessibilityIdentifier("textfile.modal")
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDraft || editing {
                TextField("File name", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .font(.amb(.subheadline).weight(.semibold))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("textfile.name")
                    .disabled(saving || (!isDraft && pendingEdit?.prepared != nil))
            } else {
                Text(filename).font(.amb(.subheadline).weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("textfile.title")
            }
            HStack(spacing: 6) {
                Text(statsLine).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("textfile.stats")
                Spacer(minLength: 4)
                Text(stateLine).font(.amb(.caption).weight(.semibold)).foregroundStyle(stateColor).accessibilityIdentifier("textfile.state")
            }
            if let viewing, !viewing.isOriginal || history.count > 1 {
                Text(versionBanner(viewing)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("textfile.version")
            }
            if let conflict {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Someone saved a newer version first. Your edit is kept here and nothing was overwritten.").font(.amb(.footnote))
                    HStack {
                        Button("Save on top of latest") { Task { await saveSent(rebasedOn: conflict) } }.accessibilityIdentifier("textfile.rebase")
                        Button("Copy my text") { Pasteboard.copy(String(decoding: pendingEdit?.bytes ?? doc.data(), as: UTF8.self)); notice = "Copied your text." }
                            .accessibilityIdentifier("textfile.copyMine")
                        Button("View latest") { Task { await view(version: conflict) } }.accessibilityIdentifier("textfile.viewLatest")
                    }
                    .font(.amb(.footnote).weight(.semibold))
                }
                .padding(10).background(Amb.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityIdentifier("textfile.conflict")
            }
            if let failure {
                Text(failure).font(.amb(.footnote)).foregroundStyle(Amb.destructive).accessibilityIdentifier("textfile.error")
            }
            if let notice {
                Text(notice).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).accessibilityIdentifier("textfile.notice")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        switch doc.phase {
        case .loading:
            VStack { Spacer(); ProgressView("Loading…"); Spacer() }.frame(maxWidth: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Spacer()
                Text(message).font(.amb(.subheadline)).foregroundStyle(Amb.destructive).multilineTextAlignment(.center)
                Button("Try again") { Task { await open() } }.accessibilityIdentifier("textfile.retry")
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
        case .notText:
            VStack(spacing: 10) {
                Spacer()
                Text("This file is not UTF-8 text, so it cannot be shown or edited here. You can still download it.")
                    .font(.amb(.subheadline)).foregroundStyle(Amb.mutedForeground).multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
        case .ready:
            PageTextView(text: doc.currentPage, identity: doc.generation, editable: editing && !saving && pendingEdit?.prepared == nil,
                onChange: { doc.edit($0); persistLocalEdit() }, onLargeReplacement: { range, text in Task { await doc.replaceLarge(range: range, text: text); persistLocalEdit() } })
                .accessibilityIdentifier(editing ? "textfile.editor" : "textfile.reader")
        }
    }

    @ViewBuilder private var pager: some View {
        if doc.phase == .ready, doc.pageCount > 1 {
            HStack(spacing: 10) {
                Button { doc.show(page: doc.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(doc.pageIndex == 0).accessibilityLabel("Previous page").accessibilityIdentifier("textfile.prev")
                Text("Page \(doc.pageIndex + 1) of \(doc.pageCount)").font(.amb(.caption)).monospacedDigit().accessibilityIdentifier("textfile.page")
                Button { doc.show(page: doc.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(doc.pageIndex >= doc.pageCount - 1).accessibilityLabel("Next page").accessibilityIdentifier("textfile.next")
                Spacer()
                TextField("Page", text: $jump).frame(width: 64).textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onSubmit { if let n = Int(jump) { doc.show(page: n - 1) }; jump = "" }
                    .accessibilityIdentifier("textfile.jump")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(editing || isDraft ? "Cancel" : "Close") { if doc.dirty { confirmDiscard = true } else { dismiss() } }
                .accessibilityIdentifier("textfile.cancel")
                .disabled(saving)
                #if os(macOS)
                .buttonStyle(.plain)
                .foregroundStyle(Amb.foreground)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Amb.muted, in: RoundedRectangle(cornerRadius: 6))
                #endif
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { copyAll() } label: { Label("Copy all text", systemImage: "doc.on.doc") }.disabled(doc.phase != .ready)
                Button { exportData = doc.data(); exporting = true } label: { Label("Download…", systemImage: "square.and.arrow.down") }
                    .disabled(doc.phase != .ready && doc.phase != .notText)
                if !isDraft {
                    Button { showingHistory = true } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }.disabled(!historyLoaded)
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More").accessibilityIdentifier("textfile.more")
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .foregroundStyle(Amb.foreground)
                .fixedSize()
                #endif
        }
        ToolbarItem(placement: .confirmationAction) {
            if isDraft {
                Button("Save") { Task { await saveDraft() } }.disabled(saving || doc.phase != .ready || !canSaveDraft).accessibilityIdentifier("textfile.save")
            } else if editing {
                Button(saving ? "Saving…" : "Save") { Task { await saveSent(rebasedOn: nil) } }
                    .disabled(saving || conflict != nil || (!doc.dirty && pendingEdit == nil && filename == originalFilename) || doc.phase != .ready).accessibilityIdentifier("textfile.save")
            } else {
                Button("Edit") { editing = true }.disabled(doc.phase != .ready || !viewingLatest || !historyLoaded || service == nil)
                    .accessibilityIdentifier("textfile.edit")
            }
        }
    }

    // MARK: State text

    private var statsLine: String {
        let size = byteLabel(doc.bytes)
        return "\(doc.lines) \(doc.lines == 1 ? "line" : "lines") · \(size) · \(doc.chars) characters"
    }

    private var stateLine: String {
        if saving { return "Saving…" }
        if pendingEdit != nil { return "Edit saved on this device" }
        if doc.dirty { return isDraft ? "Unsaved changes" : "Edited, not saved" }
        if isDraft { return "Saved on this device" }
        if conflict != nil { return "Conflict" }
        return "Saved"
    }

    private var stateColor: Color { conflict != nil ? Amb.warning : (doc.dirty ? Amb.warning : Amb.mutedForeground) }

    private func versionBanner(_ v: TextVersionRef) -> String {
        let label = v.isOriginal ? "the original as sent" : "version \(v.number)"
        return viewingLatest ? "Showing \(label) (latest)." : "Showing \(label). Switch to the latest version to edit."
    }

    private var canSaveDraft: Bool {
        guard case .draft(let a) = subject else { return false }
        return doc.dirty || TextAttachmentPolicy.sanitizedName(filename) != a.filename
    }

    private func copyAll() {
        Pasteboard.copy(String(decoding: doc.data(), as: UTF8.self))
        notice = "Copied \(doc.chars) characters."
    }

    // MARK: Opening

    private func open() async {
        failure = nil
        switch subject {
        case .draft(let a):
            filename = a.filename
            editing = true
            guard let staging = model.staging else { doc.load { throw TextAttachmentError.missing }; return }
            doc.load { try TextAttachmentStaging.read(a, in: staging) }
        case .sent(let message, let attachment):
            filename = attachment.filename
            guard let service else { failure = "Unlock and connect to read this file."; return }
            let token = UUID(); openGeneration = token
            let recoveredEdit: PendingTextEdit?
            do { recoveredEdit = try await service.recover(message: message, attachment: attachment) }
            catch { doc.load { throw error }; failure = "The saved local edit could not be read. It has been kept on this device."; return }
            if let recovered = recoveredEdit {
                pendingEdit = recovered; filename = recovered.filename; editing = true
                lineage = recovered.canonicalConflict ?? recovered.lineage; currentVersionId = recovered.baseVersionId; conflict = recovered.conflict
                if conflict == nil, recovered.acceptedLineage == nil, recovered.prepared != nil,
                   let canonical = recovered.canonicalConflict, canonical.currentVersionId != recovered.baseVersionId {
                    conflict = TextVersionRef(id: "current", versionId: canonical.currentVersionId, number: 0, storageObjectId: "", sizeBytes: nil, sha256: nil, createdAt: nil, author: nil)
                }
                doc.load { recovered.bytes }
                if let cached = service.cachedHistory(attachment.storageObjectId) { history = cached.versions }
                else { history = (try? await service.history(of: attachment, lineage: nil).versions) ?? [] }
                historyLoaded = true
                notice = "Recovered your edit from this device. Save retries the same change."
                return
            }
            // Show a cached version immediately; refresh metadata independently, without blocking offline reading.
            if let saved = service.cachedHistory(attachment.storageObjectId), let latest = saved.versions.last,
               let bytes = service.cached(latest.storageObjectId), latest.sha256 == nil || SHA256Hex.of(bytes) == latest.sha256 {
                lineage = saved.lineage; history = saved.versions; currentVersionId = saved.currentVersionId
                historyLoaded = true; viewing = latest; filename = saved.lineage?.displayName ?? attachment.filename
                doc.load { bytes }
            } else {
                doc.load { try await service.original(attachment) }
            }
            guard let found = try? await service.lineage(of: attachment, message: message) else { guard openGeneration == token else { return }; await loadHistory(nil, service, message, attachment); return }
            guard openGeneration == token, !editing, !doc.dirty else { return }
            await loadHistory(found, service, message, attachment)
        }
    }

    private func loadHistory(_ found: TextLineage?, _ service: TextAttachmentService, _ message: MessageRecord, _ attachment: MessageAttachment) async {
        lineage = found
        do {
            let listed = try await service.history(of: attachment, lineage: found)
            guard !editing, !doc.dirty, pendingEdit == nil else { return }
            history = listed.versions
            currentVersionId = listed.currentVersionId
            historyLoaded = true
            if let latest = listed.versions.last, !latest.isOriginal, viewing == nil, !editing, !doc.dirty, let found {
                // Keep the readable original on screen while newer bytes load. A slow/offline latest version must
                // never replace cached text with a network spinner, or enable editing unseen latest contents.
                viewing = listed.versions.first
                let token = openGeneration
                do {
                    let bytes = try await service.version(latest, of: found, original: attachment)
                    guard openGeneration == token, !editing, !doc.dirty, pendingEdit == nil else { return }
                    viewing = latest; filename = found.displayName
                    doc.load { bytes }
                } catch {
                    guard openGeneration == token else { return }
                    notice = "The latest version could not be downloaded. Showing the original saved on this device."
                }
            }
        } catch {
            // Reading the original still works offline; history needs Tower.
            historyLoaded = !history.isEmpty
            notice = "Version history could not refresh. Showing the version saved on this device."
        }
    }

    private func view(version: TextVersionRef) async {
        guard let sent, let service else { return }
        openGeneration = UUID() // Explicit history selection supersedes any automatic metadata/bytes refresh.
        viewing = version
        filename = version.isOriginal ? sent.attachment.filename : (lineage?.displayName ?? filename)
        editing = false
        doc.load { try await service.version(version, of: lineage ?? TextLineage(fileId: "", displayName: filename, currentVersionId: nil), original: sent.attachment) }
    }

    // MARK: Saving

    private func saveDraft() async {
        guard !saving, case .draft(let a) = subject, let staging = model.staging else { return }
        saving = true; defer { saving = false }
        let name = TextAttachmentPolicy.sanitizedName(filename)
        let data = doc.data()
        do {
            let next = try TextAttachmentStaging.replacing(a, data: data, name: name, in: staging)
            try await onSaveDraft?(next)
            doc.markSaved()
            dismiss()
        } catch { failure = (error as? LocalizedError)?.errorDescription ?? "Could not save the text on this device." }
    }

    private func persistLocalEdit() {
        guard !isDraft, editing, !saving, pendingEdit?.prepared == nil, let sent, let service, let journal = service.journal else { return }
        let previous = editAutosave
        previous?.cancel()
        editAutosave = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let intent = try localIntent(service: service, sent: sent)
                try await journal.save(intent)
                guard !Task.isCancelled else { return }
                pendingEdit = intent
            } catch {
                guard !Task.isCancelled else { return }
                failure = "Could not keep this edit on this device. Keep this window open and copy the text before closing."
            }
        }
    }

    private func finishAutosave() async {
        let previous = editAutosave
        previous?.cancel()
        await previous?.value // Cancellation alone cannot stop an atomic disk write already in progress.
        editAutosave = nil
    }

    private func localIntent(service: TextAttachmentService, sent: (message: MessageRecord, attachment: MessageAttachment)) throws -> PendingTextEdit {
        let bytes = doc.data(), name = TextAttachmentPolicy.sanitizedName(filename)
        if let pendingEdit { return try pendingEdit.updatingLocal(bytes: bytes, filename: name) }
        return PendingTextEdit(connection: service.connection, workspaceId: workspace.id, message: sent.message,
            attachment: sent.attachment, bytes: bytes, filename: name, lineage: lineage, baseVersionId: currentVersionId)
    }

    private func keepLocalAndClose() async {
        guard !saving else { return }
        saving = true; defer { saving = false }
        await finishAutosave()
        guard let sent, let service, let journal = service.journal else { return }
        do {
            let intent: PendingTextEdit
            if let pendingEdit, pendingEdit.prepared != nil { intent = pendingEdit }
            else {
                intent = try localIntent(service: service, sent: sent)
            }
            try await journal.save(intent)
            pendingEdit = intent
            dismiss()
        } catch { failure = "Could not save this edit on this device. Keep it open and copy your text before closing." }
    }

    private func discardLocalEdit() async {
        await finishAutosave()
        if let pendingEdit, let journal = service?.journal { try? await journal.remove(pendingEdit) }
    }

    private func saveSent(rebasedOn latest: TextVersionRef?) async {
        guard let sent, let service, !saving else { return }
        saving = true; failure = nil; notice = nil
        defer { saving = false }
        await finishAutosave()
        do {
            let intent: PendingTextEdit
            if let latest, let pendingEdit, let lineage, let versionId = latest.versionId {
                intent = pendingEdit.rebasing(on: lineage, versionId: versionId)
            } else if let pendingEdit, pendingEdit.prepared != nil || pendingEdit.acceptedLineage != nil {
                intent = pendingEdit
            } else {
                intent = try localIntent(service: service, sent: sent)
            }
            guard let journal = service.journal else { throw TextAttachmentError.missing }
            try await journal.save(intent)
            pendingEdit = intent
            let outcome = try await service.saveDurably(intent)
            switch outcome {
            case .saved(let file, let version):
                lineage = file
                currentVersionId = file.currentVersionId ?? version?.versionId
                if let version { history.append(version); viewing = version }
                pendingEdit = nil; doc.markSaved(); editing = false; conflict = nil; mutationId = UUID().uuidString.lowercased()
                notice = "Saved as a new version. The original message is unchanged."
                await loadHistory(file, service, sent.message, sent.attachment)
            case .conflict(let file, let current):
                pendingEdit = try await service.recover(message: sent.message, attachment: sent.attachment)
                lineage = file
                currentVersionId = file.currentVersionId
                conflict = current ?? TextVersionRef(id: "current", versionId: file.currentVersionId, number: 0, storageObjectId: "", sizeBytes: nil, sha256: nil, createdAt: nil, author: nil)
                if let current, !history.contains(where: { $0.id == current.id }) { history.append(current) }
            }
        } catch let error as TextVersionError where error == .forbidden {
            pendingEdit = (try? await service.recover(message: sent.message, attachment: sent.attachment)) ?? pendingEdit
            failure = "You do not have permission to edit this file. Your text is kept here; copy it if you need it."
        } catch {
            pendingEdit = (try? await service.recover(message: sent.message, attachment: sent.attachment)) ?? pendingEdit
            // Offline or a lost answer: the edit stays here, and Save retries the same mutation (Tower replays it).
            failure = ((error as? LocalizedError)?.errorDescription).map { $0 + " Your edit is kept; tap Save to try again." }
                ?? "Could not reach Tower. Your edit is kept; tap Save to try again."
        }
    }
}

// MARK: History list (sheet inside the modal)

extension TextAttachmentModal {
    @ViewBuilder var historySheet: some View {
        List(history.reversed()) { v in
            Button { showingHistory = false; Task { await view(version: v) } } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.isOriginal ? "Original (as sent)" : "Version \(v.number)").font(.amb(.subheadline).weight(.semibold))
                    Text([v.sizeBytes.map { byteLabel($0) }, v.createdAt.map { ChatTime.label($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
            }
            .accessibilityIdentifier("textfile.versionrow")
        }
    }
}

// MARK: Cards

/// A text file staged in the composer: name, size, a first-line preview, Open and Remove.
struct ComposerTextCards: View {
    @Environment(AppModel.self) private var model
    @Binding var attachments: [PendingAttachment]
    let staging: URL?
    let open: (PendingAttachment) -> Void
    @State private var previews: [String: String] = [:]

    var body: some View {
        let cards = attachments.filter { $0.text != nil }
        if !cards.isEmpty {
            VStack(spacing: 6) {
                ForEach(cards) { a in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.plaintext").foregroundStyle(Amb.primary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.filename).font(.amb(.footnote).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1).truncationMode(.middle)
                                .accessibilityIdentifier("composer.textcard.name")
                            Text(TextAttachmentCardText.detail(a)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                            if let preview = previews[a.id], !preview.isEmpty {
                                Text(preview).font(.system(.caption, design: .monospaced)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                                    .accessibilityIdentifier("composer.textcard.preview")
                            }
                        }
                        Spacer(minLength: 4)
                        Button("Open") { open(a) }.font(.amb(.footnote).weight(.semibold)).buttonStyle(.borderless)
                            .accessibilityIdentifier("composer.textcard.open")
                        Button { remove(a) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Amb.mutedForeground) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(a.filename)")
                            .accessibilityIdentifier("composer.textcard.remove")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Amb.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("composer.textcard")
                    .task(id: a.staged) { await loadPreview(a) }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .accessibilityIdentifier("composer.textcards")
        }
    }

    private func loadPreview(_ a: PendingAttachment) async {
        guard let staging else { return }
        previews[a.id] = await Task.detached { TextAttachmentStaging.head(a, in: staging) ?? "" }.value
    }

    private func remove(_ a: PendingAttachment) {
        attachments.removeAll { $0.id == a.id }
        // Keep staged bytes until durable draft/outbox references have been collected. Undo may still need them.
    }
}

enum TextAttachmentCardText {
    static func detail(_ a: PendingAttachment) -> String { detail(bytes: a.sizeBytes, lines: a.text?.lines) }

    static func detail(bytes: Int?, lines: Int?) -> String {
        [bytes.map { byteLabel($0) }, lines.map { "\($0) \($0 == 1 ? "line" : "lines")" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A sent text attachment in a message: a compact card that opens the reader.
struct SentTextAttachmentCard: View {
    @Environment(AppModel.self) private var model
    let message: MessageRecord
    let attachment: MessageAttachment
    let workspace: WorkspaceRecord
    @State private var subject: TextAttachmentSubject?
    @State private var preview = ""
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.plaintext").foregroundStyle(Amb.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).font(.amb(.footnote).weight(.semibold)).foregroundStyle(Amb.foreground).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("message.textcard.name")
                Text(TextAttachmentCardText.detail(bytes: attachment.sizeBytes, lines: attachment.textAttachment?.lines))
                    .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                if !preview.isEmpty {
                    Text(preview).font(.system(.caption, design: .monospaced)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                        .accessibilityIdentifier("message.textcard.preview")
                }
            }
            Spacer(minLength: 4)
            Button(copied ? "Copied" : "Copy") { Task { await copy() } }.font(.amb(.footnote).weight(.semibold)).buttonStyle(.borderless)
                .accessibilityIdentifier("message.textcard.copy")
            Button("Open") { subject = .sent(message: message, attachment: attachment) }.font(.amb(.footnote).weight(.semibold)).buttonStyle(.borderless)
                .accessibilityIdentifier("message.textcard.open")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Amb.muted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { subject = .sent(message: message, attachment: attachment) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.textcard")
        .task(id: attachment.storageObjectId) { await loadPreview() }
        .textAttachmentModal(item: $subject) { subject in TextAttachmentModal(subject: subject, workspace: workspace) }
    }

    private func loadPreview() async {
        guard let service = model.textService(for: workspace), let bytes = service.cached(attachment.storageObjectId) else { return }
        preview = await Task.detached { String(data: bytes.prefix(1024), encoding: .utf8).map(TextAttachmentPolicy.preview) ?? "" }.value
    }

    private func copy() async {
        guard let service = model.textService(for: workspace), let bytes = try? await service.original(attachment) else { return }
        Pasteboard.copy(String(decoding: bytes, as: UTF8.self))
        copied = true
        try? await Task.sleep(for: .seconds(2))
        copied = false
    }
}

extension AppModel {
    /// The reader/editor service for a workspace of the signed-in connection (nil when there is no connection yet).
    func textService(for workspace: WorkspaceRecord) -> TextAttachmentService? {
        guard let sync, let connection, workspace.id == selectedWorkspace?.id else { return nil }
        return TextAttachmentService(sync: sync, connection: connection, workspace: workspace, cache: fileCache, editDirectory: staging?.appendingPathComponent("TextEdits", isDirectory: true))
    }
}
