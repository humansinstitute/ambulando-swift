#if DEBUG
import AppKit
import AmbulandoCore

extension MacThreadRegression {
    /// Real native window interactions against the separate Test app's local sample transport.
    static func deckComposerCheck(_ window: NSWindow, model: AppModel) async throws {
        guard let fixture = model.fixture, let png = FixtureTower.samplePNG() else {
            throw Failure(description: "Missing sample image")
        }
        let object = fixture.tower.work.seedObject(png, contentType: "image/png", name: "composer-check.png")
        model.selectContext(.home); await settle()
        try press(window, "deck.inbox.new"); await settle()
        try require(find(window, "composer.field") == nil, "Home asks for a channel before composing")
        try press(window, "deck.compose.option.\(FixtureTower.generalChannel)"); await settle()
        try require(find(window, "composer.field") != nil, "explicit channel choice opens the composer")
        try type(window, "@An"); await settle()
        try press(window, "mention.Ana Lima"); await settle()
        try type(window, "Review this ![composer-check.png](storage://\(object))")
        try await waitFor(window, "image.loaded", "composer image tile", seconds: 20)
        try require(find(window, "composer.strip") != nil && find(window, "composer.mention.pill") != nil, "image and mention share the strip")
        let draft = try textView(window).string
        if let tile = find(window, "image.loaded") {
            let selector = NSSelectorFromString("accessibilityFrame")
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            let frame = unsafeBitCast(tile.method(for: selector), to: Frame.self)(tile, selector)
            try require(abs(frame.width - 72) < 1 && abs(frame.height - 72) < 1, "72pt image tile")
        }
        try snapshot(window, model: model, name: "mac-composer-strip")
        try press(window, "image.loaded")
        try await waitFor(window, "lightbox.close", "tile opens the current lightbox")
        try press(window, "lightbox.close"); await settle()
        try require(try textView(window).string == draft, "preview preserves draft")
        for size in [NSSize(width: 900, height: 650), NSSize(width: 1280, height: 820)] {
            window.setContentSize(size); await settle()
            try require(try textView(window).string == draft, "resize preserves draft")
        }
        try press(window, "composer.uploaded.remove"); await settle()
        try require(find(window, "image.loaded") == nil && find(window, "composer.mention.pill") != nil, "remove affects only the image")
        try require(try textView(window).string.contains("Review this"), "remove keeps typed text")
        try press(window, "deck.compose.cancel"); await settle()
        try press(window, "deck.inbox.new"); await settle()
        try require(find(window, "composer.field") == nil, "Home asks again on reopen")
        try press(window, "deck.compose.option.\(FixtureTower.generalChannel)"); await settle()
        try require(try textView(window).string.contains("Review this"), "cancel/reopen keeps the chosen channel's draft")
    }
}
#endif
