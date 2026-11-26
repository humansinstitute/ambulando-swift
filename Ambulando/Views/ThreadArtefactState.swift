import AmbulandoCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The existing Mac state/contract is shared with iPhone/iPad; names remain stable for Mac callers.
@MainActor @Observable
final class MacThreadArtefactTab: Identifiable {
    let id: String
    let kind: String
    var title: String
    var icon = "doc"
    #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
    var revisionLabel = "Current editor"
    #endif
    var open = true
    var attached = true
    @ObservationIgnored var detach: (() -> Void)?
    @ObservationIgnored var reattach: (() -> Void)?
    @ObservationIgnored var saveSource: (() async throws -> Void)?
    #if DEBUG
    @ObservationIgnored weak var testingDocument: DocEditorModel?
    #endif
    @ObservationIgnored var validate: ((ArtefactChatReference) async -> Bool)?
    @ObservationIgnored var checkpoint: (() async -> Bool)?
    @ObservationIgnored var prepare: (() async throws -> ArtefactChatReference)?
    init(kind: String, id: String) { self.kind = kind; self.id = id; self.title = kind == "doc" ? "Document" : "Artefact" }
}

@MainActor @Observable
final class MacThreadArtefacts: Equatable {
    nonisolated static func == (lhs: MacThreadArtefacts, rhs: MacThreadArtefacts) -> Bool { lhs === rhs }
    var tabs: [MacThreadArtefactTab] = []
    var selected: String?
    #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
    var discussionTarget: String?
    var discussionExcluded = false
    #endif
    var browsing = false
    var shown = false
    var expanded = false
    var busy = false
    var membershipPending = false
    var failure: String?
    var members: [ThreadArtefactMember] = []
    var labels: [ThreadArtefactMember: String] = [:]
    var membershipError: String?
    var membershipVersion = 0
    private var migrationChecked = false
    private var canonicalInitialized = false
    @ObservationIgnored var openFallback: ((String, String) -> Void)?
    @ObservationIgnored var transport: ThreadArtefactMembershipSync.Transport?
    var attachedTabs: [MacThreadArtefactTab] { tabs.filter { $0.attached } }
    func observe(_ row: ThreadRecord) {
        guard row.rowVersion >= membershipVersion else { return }
        membershipVersion = row.rowVersion
        do {
            let incoming = try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(row))
            membershipError = nil
            // An initial absent observation must not destroy legacy refs before migration captures them.
            if incoming == nil && !canonicalInitialized { return }
            canonicalInitialized = true
            members = incoming ?? []
            for tab in tabs where tab.attached && !members.contains(where: { $0.kind == tab.kind && $0.id == tab.id }) {
                tab.attached = false
                // Stop automatic publication immediately, before any asynchronous local checkpoint.
                tab.detach?()
                #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
                if discussionTarget == tab.id { discussionTarget = nil }
                #endif
                if selected == tab.id { selected = nil; shown = false; expanded = false }
            }
        } catch { membershipError = error.localizedDescription }
    }
    func refresh() async {
        guard let transport else { return }
        do {
            if !migrationChecked {
                let legacy = try attachedTabs.map { try ThreadArtefactMember(kind: $0.kind, id: $0.id) }
                observe(try await ThreadArtefactMembershipSync.migrate(legacy, transport: transport))
                migrationChecked = true
            } else { observe(try await transport.read()) }
        }
        catch { failure = "Could not refresh thread attachments: \(error.localizedDescription)" }
    }
    func remove(_ member: ThreadArtefactMember) {
        guard !busy, membershipError == nil, let transport else { return }
        busy = true; membershipPending = true; failure = nil
        Task { @MainActor in
            defer { busy = false; membershipPending = false }
            do { observe(try await ThreadArtefactMembershipSync.change(member, adding: false, transport: transport)) }
            catch { failure = "Remove was not confirmed: \(error.localizedDescription)"; await refresh() }
        }
    }
    func show(_ tab: MacThreadArtefactTab) {
        selected = tab.id; shown = true
        #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
        discussionTarget = tab.attached ? tab.id : nil
        discussionExcluded = false
        #endif
    }

    #if DEBUG
    static weak var testingState: MacThreadArtefacts?
    #endif
    func open(kind: String, id: String) {
        guard !busy else { return }
        let kind = kind == "document" ? "doc" : kind
        guard let transport else { failure = "Attachments are unavailable until this conversation is loaded."; return }
        guard membershipError == nil else { failure = membershipError; return }
        busy = true; membershipPending = true; failure = nil
        Task { @MainActor in
            defer { busy = false; membershipPending = false }
            do {
                let member = try ThreadArtefactMember(kind: kind, id: id)
                let row = try await ThreadArtefactMembershipSync.change(member, adding: true, transport: transport)
                observe(row)
                guard members.contains(member) else { failure = "Attachment was removed elsewhere. Refresh before reopening."; return }
                if let tab = tabs.first(where: { $0.id == member.id && $0.kind == member.kind && $0.attached }) {
                    tab.open = true; show(tab)
                } else if let tab = tabs.first(where: { $0.id == member.id && $0.kind == member.kind }) {
                    // A re-add must not reactivate detached recovery's automatic publishing.
                    tab.open = true; show(tab)
                    failure = "Attachment added. Review detached recovery, then use Save to source and resume."
                } else {
                    let tab = MacThreadArtefactTab(kind: member.kind, id: member.id)
                    tabs.append(tab); show(tab)
                }
                #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
                browsing = false
                #endif
            } catch ThreadArtefactMembership.Error.unsupported {
                openFallback?(kind, id)
            } catch { failure = "Attachment was not confirmed: \(error.localizedDescription)"; await refresh() }
        }
    }
    func saveRecovery(_ tab: MacThreadArtefactTab) async {
        guard !busy, !tab.attached, let transport else { return }
        busy = true; failure = nil
        defer { busy = false }
        do {
            guard let prepare = tab.prepare else { throw ArtefactChatContext.ContextError.unresolved }
            // This explicit user action may publish. Observing detach or re-add never calls it.
            if let save = tab.saveSource { try await save() }
            let reference = try await prepare()
            let row = try await transport.read(); observe(row)
            if let validate = tab.validate, !(await validate(reference)) { throw ArtefactChatContext.ContextError.unresolved }
            if members.contains(where: { $0.kind == tab.kind && $0.id == tab.id }), membershipError == nil {
                tab.attached = true; tab.reattach?(); show(tab)
            } else { failure = "Source saved. Recovery remains detached because this source is not attached to the thread." }
        } catch { failure = "Source Save was not confirmed: \(error.localizedDescription). Recovery remains held." }
    }
    func close(_ tab: MacThreadArtefactTab) {
        guard !busy else { return }
        busy = true; failure = nil
        Self.endEditing()
        Task { @MainActor in
            defer { busy = false }
            do {
                if tab.attached, let prepare = tab.prepare { _ = try await prepare() }
                else if let checkpoint = tab.checkpoint, !(await checkpoint()) { throw ArtefactChatContext.ContextError.unresolved }
                tab.open = false
                #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
                if selected == tab.id {
                    selected = tabs.first(where: { $0.open && $0.attached })?.id
                    discussionTarget = selected
                }
                #else
                selected = tabs.first(where: \.open)?.id
                #endif
                if selected == nil { shown = false }
            } catch {
                failure = "Tab kept open: \(error.localizedDescription) Save or resolve this tab, then retry close."
            }
        }
    }
    func checkpointAll() async -> Bool {
        guard !busy else { return false }
        Self.endEditing()
        busy = true
        defer { busy = false }
        for tab in tabs {
            if let checkpoint = tab.checkpoint, !(await checkpoint()) {
                failure = "Keep this conversation open: an editor could not preserve its latest changes. Retry closing after resolving the tab."
                return false
            }
        }
        return true
    }
    func prepare(target: ChatTarget, holdForEnqueue: Bool = false) async throws -> Data? {
        guard !busy else { throw ArtefactChatContext.ContextError.unresolved }
        guard let thread = target.threadId, membershipError == nil else { return nil }
        #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
        // Refresh canonical membership before touching sources. Cached tabs never reattach a removed record.
        if tabs.contains(where: { $0.open && $0.attached }), let transport {
            busy = true
            do { observe(try await transport.read()) }
            catch {
                busy = false
                failure = "Send paused: could not confirm thread attachments. \(error.localizedDescription) Retry when connected."
                throw error
            }
            busy = false
            guard membershipError == nil else { throw ArtefactChatContext.ContextError.unresolved }
        }
        #endif
        let open = tabs.filter { $0.open && $0.attached }
        // Hidden workspace has no visible artefact, but dirty open editors must still save.
        guard !open.isEmpty else { return nil }
        Self.endEditing()
        busy = true; failure = nil
        var prepared = false
        defer { if !holdForEnqueue || !prepared { busy = false } }
        var preparingTitle = "artefact"
        do {
            var refs: [ArtefactChatReference] = []
            for tab in open {
                preparingTitle = tab.title
                guard let prepare = tab.prepare else { throw ArtefactChatContext.ContextError.unresolved }
                refs.append(try await prepare())
            }
            #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
            if let transport { observe(try await transport.read()) }
            guard membershipError == nil else { throw ArtefactChatContext.ContextError.unresolved }
            #endif
            for (tab, reference) in zip(open, refs) {
                guard tab.attached else { throw ArtefactChatContext.ContextError.unresolved }
                preparingTitle = tab.title
                if let validate = tab.validate, !(await validate(reference)) { throw ArtefactChatContext.ContextError.unresolved }
            }
            #if os(iOS) || AMBULANDO_PHONE_STATE_CHECK
            // Removing the composer target opts this message out of hidden artefact context too.
            // Dirty editors still passed the same save barrier above.
            if discussionExcluded && !shown { prepared = true; return nil }
            #endif
            let context = try ArtefactChatContext(workspaceID: target.workspaceId, channelID: target.channelId,
                threadID: thread, visibleRecordID: selected ?? open[0].id, workspaceVisible: shown, open: refs).encoded(for: target)
            prepared = true
            return context
        } catch {
            failure = "Send paused for \(preparingTitle): \(error.localizedDescription) Resolve the affected tab, then press Send to retry."
            throw error
        }
    }
    private static func endEditing() {
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

}

extension EnvironmentValues {
    @Entry var macThreadArtefacts: MacThreadArtefacts? = nil
    @Entry var macThreadArtefactTab: MacThreadArtefactTab? = nil
    @Entry var macThreadArtefactsInParentHeader = false
}

struct MacThreadArtefactOwnerKey: PreferenceKey {
    static let defaultValue: MacThreadArtefacts? = nil
    static func reduce(value: inout MacThreadArtefacts?, nextValue: () -> MacThreadArtefacts?) { value = nextValue() ?? value }
}
