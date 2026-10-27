import SwiftUI
#if os(macOS)
import AppKit
#endif
import ImageIO
import UniformTypeIdentifiers

/// A stored image opened large (the web's image modal) instead of Quick Look, which cannot tell what a cached attachment
/// is (its file has no extension): it showed a blank "Document" on the Mac and an empty white page on the iPhone.
struct LightboxImage: Equatable, Identifiable {
    let objectId: String
    let file: URL
    let alt: String
    var id: String { objectId }
}

@MainActor
@Observable
final class ImageLightbox {
    var shown: LightboxImage?
    func show(_ image: LightboxImage) { shown = image }
}

extension EnvironmentValues {
    /// Set by `imageLightboxHost()` on the Mac; nil elsewhere (the iPhone and iPad present the lightbox from the image).
    @Entry var imageLightbox: ImageLightbox? = nil
}

extension View {
    /// Hosts the image lightbox over everything inside this Mac window.
    func imageLightboxHost() -> some View { modifier(ImageLightboxHost()) }

    /// The iPhone and iPad show `image` full screen from where it was tapped (inside a thread or canvas cover too).
    func imageLightboxCover(_ image: Binding<LightboxImage?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: image) { shown in
            LightboxOverlay(image: shown) { image.wrappedValue = nil }
                .presentationBackground(.clear)
        }
        #else
        self
        #endif
    }
}

private struct ImageLightboxHost: ViewModifier {
    @State private var lightbox = ImageLightbox()

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .environment(\.imageLightbox, lightbox)
            .overlay {
                if let image = lightbox.shown {
                    LightboxOverlay(image: image) { lightbox.shown = nil }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: lightbox.shown)
        #else
        content
        #endif
    }
}

/// The dimmed screen with the image fitted inside it. A tap or click beside the image, the close button or Escape closes
/// it; pinch, the zoom buttons or a double tap enlarge it. The Mac opens a named copy in Preview; the iPhone shares it.
private struct LightboxOverlay: View {
    let image: LightboxImage
    let close: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var decoded: PlatformImage?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            GeometryReader { proxy in
                if let decoded {
                    let fit = fitted(decoded.size, in: proxy.size)
                    let shown = CGSize(width: fit.width * zoom * pinch, height: fit.height * zoom * pinch)
                    Group {
                        if zoom * pinch > 1.01 {
                            // Enlarged: scroll around the picture.
                            ScrollView([.horizontal, .vertical]) {
                                picture(decoded).frame(width: shown.width, height: shown.height)
                                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                            }
                        } else {
                            // Fitted and centred; a tap beside it reaches the dimmed background, which closes.
                            picture(decoded).frame(width: shown.width, height: shown.height)
                                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        }
                    }
                    .gesture(MagnifyGesture().onChanged { pinch = $0.magnification }.onEnded { _ in
                        zoom = min(max(zoom * pinch, 1), 8); pinch = 1
                    })
                } else if failed {
                    Label("This image could not be shown.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.large).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            #if os(macOS)
            .padding(.horizontal, 56).padding(.top, 64).padding(.bottom, 40)
            #else
            .padding(.horizontal, 8).padding(.top, 64).padding(.bottom, 24)
            #endif
        }
        .overlay(alignment: .top) { toolbar }
        .task(id: image.objectId) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("lightbox")
    }

    private func picture(_ decoded: PlatformImage) -> some View {
        Image(platformImage: decoded).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2 } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("lightbox.image")
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(image.alt).font(.amb(.subheadline).weight(.semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
            Spacer()
            #if os(macOS)
            Button { withAnimation(.snappy) { zoom = max(1, zoom / 1.5) } } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom <= 1).accessibilityLabel("Zoom out")
            Button { withAnimation(.snappy) { zoom = min(8, zoom * 1.5) } } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom in")
            Button { openInPreview() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open in Preview").accessibilityLabel("Open in Preview").accessibilityIdentifier("lightbox.open")
            #else
            if let copy = LightboxFiles.namedCopy(of: image.file, alt: image.alt, objectId: image.objectId) {
                ShareLink(item: copy) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share image").accessibilityIdentifier("lightbox.share")
            }
            #endif
            Button(action: close) { Image(systemName: "xmark").frame(minWidth: 32, minHeight: 32) }
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)").accessibilityLabel("Close image").accessibilityIdentifier("lightbox.close")
        }
        .font(.system(size: 17, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        // Fitted to the screen, so a small image is shown large too (up to 4× its natural size, beyond which it only blurs).
        let scale = min(box.width / size.width, box.height / size.height, 4)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func load() async {
        let file = image.file, pixels = 4096 * max(1, displayScale / 2), scale = displayScale
        let result = await Task.detached(priority: .userInitiated) { StorageImageCache.downsample(file, maxPixels: pixels, scale: scale) }.value
        guard !Task.isCancelled else { return }
        if let result { decoded = result } else { failed = true }
    }

    #if os(macOS)
    /// The cached file has no extension, so a copy named after the image (with its type's extension) is opened.
    private func openInPreview() {
        guard let copy = LightboxFiles.namedCopy(of: image.file, alt: image.alt, objectId: image.objectId) else { return }
        NSWorkspace.shared.open(copy)
    }
    #endif
}

enum LightboxFiles {
    /// A temporary copy of a cached attachment with an extension matching its bytes, for viewers that go by the name.
    static func namedCopy(of file: URL, alt: String, objectId: String) -> URL? {
        let source = CGImageSourceCreateWithURL(file as CFURL, nil)
        let type = (source.flatMap { CGImageSourceGetType($0) as String? }).flatMap { UTType($0) }
        let ext = type?.preferredFilenameExtension ?? "png"
        var base = (alt as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "image" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lightbox-\(objectId)", isDirectory: true)
        let copy = folder.appendingPathComponent(String(base.prefix(80)) + "." + ext)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: file, to: copy) }
            return copy
        } catch { return nil }
    }
}
