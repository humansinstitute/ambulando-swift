import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The few UIKit/AppKit differences the shared views need (iPhone and Mac targets compile the same view files).

#if os(iOS)
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformView = UIView
#else
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformView = NSView
#endif

extension PlatformColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A colour that follows light and dark appearance.
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> PlatformColor {
        #if os(iOS)
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
        #else
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) }
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// A decoded bitmap at `scale` points per pixel.
    static func bitmap(_ image: CGImage, scale: CGFloat) -> PlatformImage {
        #if os(iOS)
        UIImage(cgImage: image, scale: max(1, scale), orientation: .up)
        #else
        NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / max(1, scale), height: CGFloat(image.height) / max(1, scale)))
        #endif
    }

    /// Approximate decoded size in bytes (cache cost).
    var decodedBytes: Int {
        #if os(iOS)
        Int(size.width * scale * size.height * scale * 4)
        #else
        let rep = representations.first
        return (rep?.pixelsWide ?? Int(size.width)) * (rep?.pixelsHigh ?? Int(size.height)) * 4
        #endif
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Keychain service names. The iPhone keeps the shipped names (its Keychain is private to the app). A Mac's login
/// keychain is shared by all of the user's apps, so the Mac app puts its bundle identifier in front instead: the
/// installed app and a Debug build never share (or ask for) each other's items.
enum KeychainServices {
    static func named(_ service: String) -> String {
        #if os(iOS)
        service
        #else
        let prefix = "studio.otherstuff.ambulando.native."
        guard let bundle = Bundle.main.bundleIdentifier, service.hasPrefix(prefix) else { return service }
        return bundle + "." + service.dropFirst(prefix.count)
        #endif
    }
}

/// Wording that names the device the app runs on ("this iPhone" / "this Mac").
enum Device {
    #if os(iOS)
    @MainActor static var name: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    #else
    static let name = "Mac"
    #endif
    @MainActor static var this: String { "this \(name)" }
}

// iOS-only view modifiers under shared names: the iPhone keeps exactly what it had, the Mac gets its own equivalent
// (or nothing, where the concept does not exist, such as keyboard types).
extension View {
    /// Inline navigation title (the Mac's window toolbar has one title style).
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Grouped list (inset grouped on the iPhone, inset on the Mac).
    func groupedList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// Web-address entry: URL keyboard without capitalisation on the iPhone.
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Digits-only entry (PINs): number pad on the iPhone.
    func numberPadEntry() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// No automatic capitalisation (names, keys).
    func noCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// One-time-code autofill hint on the iPhone (PIN fields).
    func oneTimeCodeEntry() -> some View {
        #if os(iOS)
        textContentType(.oneTimeCode)
        #else
        self
        #endif
    }

    /// The on-screen keyboard hiding and showing (the iPhone only; a Mac has no on-screen keyboard).
    func onKeyboard(willHide: @escaping () -> Void, didShow: @escaping () -> Void) -> some View {
        #if os(iOS)
        onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in willHide() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in didShow() }
        #else
        self
        #endif
    }

    /// A menu drawn with its own label view (the Mac otherwise draws a pop-up button with only the label's text).
    func fullLabelMenu() -> some View {
        #if os(iOS)
        self
        #else
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #endif
    }

    /// Icon-only buttons without the Mac's bordered bezel (the iPhone's default already has none).
    func iconButton() -> some View {
        #if os(iOS)
        self
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// A Mac sheet sizes itself to its content's ideal size, which for a `List` is next to nothing: give it room there.
    /// No change on the iPhone/iPad, where sheets fill their presentation.
    func macSheetSize(minWidth: CGFloat, idealWidth: CGFloat, minHeight: CGFloat, idealHeight: CGFloat) -> some View {
        #if os(iOS)
        self
        #else
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
        #endif
    }

    /// A settings-style form on the Mac (labels and controls in grouped rows that scroll) instead of the default column
    /// form, which repeated section names as row labels and clipped multi-line fields. iOS forms are grouped already.
    func macGroupedForm() -> some View {
        #if os(iOS)
        self
        #else
        formStyle(.grouped)
        #endif
    }

    /// Full-screen cover on the iPhone; on the Mac a large sheet over the window.
    func coverSheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) { content().frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 700) }
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Leading navigation-bar item (the Mac toolbar's navigation area).
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Trailing navigation-bar item (the Mac toolbar's primary-action area).
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension SearchFieldPlacement {
    /// Search field in the navigation bar drawer on the iPhone; the toolbar's search field on the Mac.
    static var drawer: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .automatic)
        #else
        .toolbar
        #endif
    }

    static var drawerAlways: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .toolbar
        #endif
    }
}

#if os(macOS)
/// Native file handling on the Mac: copies leave the app's sandbox only through a save panel the user confirms.
enum MacFiles {
    /// Item providers for files the user picked, from copies in the app's temporary directory: the picked files are
    /// readable only while their security scope is open, and uploads read them later.
    static func providers(copying urls: [URL]) -> [NSItemProvider] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Picked-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = directory.appendingPathComponent(url.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return nil }
            return NSItemProvider(contentsOf: copy)
        }
    }

    @MainActor
    static func saveCopy(of url: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
#endif
