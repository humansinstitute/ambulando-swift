#if DEBUG
import AppKit
import AmbulandoCore

/// The focused thread's header menu (web `.thread-title-menu`) through the real AppKit menu: it sits with pin, full
/// screen and close, copies this thread's own FD Ref and first message, and full screen still toggles.
extension MacThreadRegression {
    static func threadMenuCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let focus = model.focusedThread, let workspace = model.selectedWorkspace, let store = model.store else {
            throw Failure(description: "Missing focused thread for the header menu")
        }
        for id in ["pin.toggle", "thread.focus.actions", "thread.focus.expand", "thread.focus.close"] {
            try require(find(window, id) != nil, "thread header shows " + id)
        }
        let record = try await store.reader.thread(workspaceId: workspace.id, id: focus.threadId)
        let rows = try await store.reader.threadMessages(workspaceId: workspace.id, threadId: focus.threadId, limit: 500)
        guard let channel = record?.channelId ?? focus.channelId,
              let rootId = record?.sourceMessageId ?? rows.first(where: { $0.threadSourceId == $0.id })?.id,
              let root = rows.first(where: { $0.id == rootId }) else {
            throw Failure(description: "Missing stored root for the header menu")
        }

        NSPasteboard.general.clearContents()
        try await menuAction(window, title: "FD Ref", button: "thread.focus.actions")
        let reference = "@[Chat thread](mention:chat:\(channel)#\(rootId))"
        try require(NSPasteboard.general.string(forType: .string) == reference, "thread menu copies this thread's FD Ref")
        try require(model.focusedThread == focus, "copying keeps the thread open")

        NSPasteboard.general.clearContents()
        try await menuAction(window, title: "Copy message", button: "thread.focus.actions")
        try require(NSPasteboard.general.string(forType: .string) == MentionCodec.plain(root.body), "Copy message copies the first message")

        // Rename thread: the menu opens the rename sheet; the same call the sheet makes updates the header and the stored title.
        try await menuAction(window, title: "Rename thread", button: "thread.focus.actions")
        for _ in 0..<10 where window.attachedSheet == nil { await settle() }
        guard let sheet = window.attachedSheet else { throw Failure(description: "Rename thread must open its sheet") }
        try require(find(sheet, "thread.rename.field") != nil, "the rename sheet has a title field")
        try press(sheet, "thread.rename.cancel"); await settle()
        try require(window.attachedSheet == nil && model.focusedThread == focus, "Cancel closes the sheet and keeps the thread")
        let editBase = try await model.store?.reader.thread(workspaceId: workspace.id, id: focus.threadId)
        try await model.renameThread(focus.threadId, to: "Renamed from the Mac", in: workspace, originalTitle: editBase?.title, rowVersion: editBase?.rowVersion)
        await settle()
        let renamed = try await store.reader.thread(workspaceId: workspace.id, id: focus.threadId)
        try require(renamed?.title == "Renamed from the Mac", "the stored thread title follows the rename")
        try require(containsText(window, "Renamed from the Mac"), "the header shows the new title")
        print("THREAD_RENAME_PASS title=\(renamed?.title ?? "")")

        for _ in 0..<2 {
            try press(window, "thread.focus.expand"); await settle()
            try require(model.focusedThread == focus, "full screen keeps the thread")
        }
        print("THREAD_MENU_PASS thread=\(focus.threadId) ref=\(reference)")
    }
}
#endif
