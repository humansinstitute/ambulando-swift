#if DEBUG
import AppKit
import SwiftUI
import AmbulandoCore

/// `-AmbulandoMacOvernightCheck` (with `-AmbulandoMacThreadRegression` on the isolated Test app): the image lightbox
/// over the window, and a canvas in a window of its own with its Board items sheet listing its items. Snapshots go to the
/// log as base64 PNGs, as the other checks do.
extension MacThreadRegression {
    static func overnightCheck(_ window: NSWindow, model: AppModel) async throws {
        do { try await overnightSteps(window, model: model) } catch {
            for (index, shown) in NSApp.windows.filter(\.isVisible).enumerated() { try? snapshot(shown, model: model, name: "failure-\(index)") }
            throw error
        }
    }

    private static func overnightSteps(_ window: NSWindow, model: AppModel) async throws {
        // A stored image in a Markdown document opens in the lightbox, and Escape closes it.
        try press(window, "section.docs")
        await settle()
        try await waitFor(window, "doc.Release board (Markdown)", "the Markdown document with a stored image")
        try press(window, "doc.Release board (Markdown)")
        try await waitFor(window, "image.loaded", "the stored image downloads and decodes", seconds: 45)
        try press(window, "image.loaded")
        try await waitFor(window, "lightbox.image", "the image opens in the lightbox over the window", seconds: 10)
        try require(find(window, "lightbox.close") != nil && find(window, "lightbox.open") != nil, "lightbox controls")
        await settle()
        if let node = find(window, "lightbox.image") {
            let selector = NSSelectorFromString("accessibilityFrame")
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            let frame = unsafeBitCast(node.method(for: selector), to: Frame.self)(node, selector)
            print("CHECK lightbox image frame=\(frame) window=\(window.frame)"); fflush(stdout)
            try require(frame.width > 100 && frame.height > 100, "the image is shown large (\(frame.size))")
        }
        try snapshot(window, model: model, name: "lightbox")
        try postKey(window, key: "\u{1b}", code: 53, modifiers: [])
        try await waitGone(window, "lightbox", "Escape closes the lightbox")
        print("CHECK lightbox opened and closed"); fflush(stdout)

        // A canvas opens in its own window beside the main one.
        try press(window, "section.deck")
        await settle()
        try await waitFor(window, "canvas.Launch board", "the Deck canvas row")
        let before = Set(NSApp.windows.map(\.windowNumber))
        try press(window, "canvas.Launch board")
        var canvasWindow: NSWindow?
        for _ in 0..<40 where canvasWindow == nil {
            try? await Task.sleep(for: .milliseconds(250))
            canvasWindow = NSApp.windows.first { !before.contains($0.windowNumber) && $0.isVisible && find($0, "canvas.items") != nil }
        }
        guard let canvasWindow else { throw Failure(description: "the canvas did not open in a window of its own") }
        try require(find(window, "canvas.items") == nil, "the main window keeps its own screen (the canvas is not pushed there)")
        print("CHECK canvas window title=\(canvasWindow.title) main=\(window.title) windows=\(NSApp.windows.filter(\.isVisible).count)"); fflush(stdout)
        canvasWindow.setContentSize(NSSize(width: 1000, height: 700))
        await settle()
        try snapshot(canvasWindow, model: model, name: "canvas-window")

        // Board items lists the canvas's items (the Mac sheet used to collapse its list to nothing).
        try click(canvasWindow, "canvas.items")
        var sheet: NSWindow?
        for _ in 0..<20 where sheet == nil {
            try? await Task.sleep(for: .milliseconds(250))
            sheet = canvasWindow.attachedSheet
        }
        guard let sheet else { throw Failure(description: "Board items sheet did not open") }
        await settle()
        let rows = ["Build 7 launch notes", "General tasks", "Native chat review"].filter { find(sheet, "canvas.item.\($0)") != nil }.count
        print("CHECK board items sheet size=\(sheet.frame.size) rows=\(rows)"); fflush(stdout)
        try require(sheet.frame.height >= 300, "the sheet has room for its list (\(sheet.frame.size))")
        try require(rows > 0, "the sheet lists the canvas's items")
        if let close = find(sheet, "canvas.items.close") {
            print("CHECK items sheet close title=\(value(close, "AXDescription") ?? "-") role=\(value(close, "AXRole") ?? "-") appearance=\(sheet.effectiveAppearance.name.rawValue)"); fflush(stdout)
        }
        try snapshot(sheet, model: model, name: "canvas-items-sheet")
        canvasWindow.endSheet(sheet)
        canvasWindow.close()
    }

    static func waitFor(_ window: NSWindow, _ id: String, _ what: String, seconds: Double = 10) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if find(window, id) != nil { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw Failure(description: "Missing \(what) (\(id))")
    }

    static func waitGone(_ window: NSWindow, _ id: String, _ what: String, seconds: Double = 5) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if find(window, id) == nil { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw Failure(description: what)
    }
}
#endif
