import AmbulandoCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The new-tab page: saved sites as a grid of icons over Nostr Browser's default background (`voxel-beach.png` from
/// the Nostr Browser app assets, under the same 20% `#291c3d` tint). Tap opens the site in this tab; the context
/// menu edits, moves or removes one; **Edit** arranges the whole list. Saving the current page is in the browser menu.
struct BrowserStartPage: View {
    @Environment(AppModel.self) private var model
    @State private var editing: BrowserFavourite?
    @State private var arranging = false

    private var browser: BrowserModel { model.browser }
    private static let tint = Color(PlatformColor(hex: 0x291C3D))

    var body: some View {
        let favourites = browser.favourites.items
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button { editing = BrowserFavourite(title: "", url: URL(string: "about:blank")!) } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityLabel("Add favourite")
                    .accessibilityIdentifier("browser.favourites.add")
                    if !favourites.isEmpty {
                        Button { arranging = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                            .accessibilityLabel("Edit favourites")
                            .accessibilityIdentifier("browser.favourites.edit")
                    }
                }
                .buttonStyle(StartPageButtonStyle())
                if favourites.isEmpty {
                    intro
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 148), spacing: 16, alignment: .top)], spacing: 22) {
                        ForEach(favourites) { favourite in tile(favourite, index: favourites.firstIndex(of: favourite) ?? 0, count: favourites.count) }
                    }
                    .accessibilityIdentifier("browser.favourites.grid")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 20)
            .tabletReadingWidth(1056)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { background }
        .accessibilityIdentifier("browser.start")
        .sheet(item: $editing) { favourite in BrowserFavouriteEditor(favourite: favourite) }
        .sheet(isPresented: $arranging) { BrowserFavouritesArrangeView() }
    }

    private var background: some View {
        ZStack {
            Self.tint
            Image("BrowserStartBackground").resizable().scaledToFill()
            Self.tint.opacity(0.2)
        }
        .clipped()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var intro: some View {
        VStack(spacing: 10) {
            Image(systemName: "star").font(.amb(.largeTitle))
            Text("Your favourite sites appear here").font(.amb(.headline))
            Text("Open a site, then choose Add to Favourites in the ••• menu, or tap Add. Pages open with your Nostr key available through window.nostr; each site asks before it can see your key, and every signature asks you first.")
                .font(.amb(.footnote)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: 520)
        .background(Self.tint.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser.favourites.empty")
    }

    private func tile(_ favourite: BrowserFavourite, index: Int, count: Int) -> some View {
        Button { browser.openFavourite(favourite) } label: {
            VStack(spacing: 8) {
                BrowserFavouriteIcon(favourite: favourite, size: 72)
                Text(favourite.title).font(.amb(.caption).weight(.medium)).foregroundStyle(.white)
                    .shadow(color: .black, radius: 2, y: 1).shadow(color: .black.opacity(0.6), radius: 6)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(favourite.title)
        .accessibilityHint(favourite.url.host ?? "")
        .accessibilityIdentifier("browser.favourite")
        .contextMenu {
            Button { editing = favourite } label: { Label("Edit…", systemImage: "pencil") }
            if index > 0 { Button { browser.moveFavourite(favourite.id, by: -1) } label: { Label("Move Earlier", systemImage: "arrow.left") } }
            if index < count - 1 { Button { browser.moveFavourite(favourite.id, by: 1) } label: { Label("Move Later", systemImage: "arrow.right") } }
            Button(role: .destructive) { browser.removeFavourite(favourite.id) } label: { Label("Remove", systemImage: "trash") }
        }
    }
}

/// Light text buttons that read on the photograph.
private struct StartPageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.amb(.subheadline).weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(Color(PlatformColor(hex: 0x291C3D)).opacity(configuration.isPressed ? 0.9 : 0.62), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A favourite's picture: the user's picture or text, else the site's icon, else the title's first letter.
struct BrowserFavouriteIcon: View {
    let favourite: BrowserFavourite
    let size: CGFloat

    var body: some View {
        Group {
            if let data = favourite.image, let image = PlatformImage(data: data) {
                Image(platformImage: image).resizable().scaledToFill()
            } else if let symbol = favourite.symbol {
                letter(symbol)
            } else if let icon = favourite.siteIcon {
                AsyncImage(url: icon) { phase in
                    if let image = phase.image { image.resizable().scaledToFit().background(.white) } else { letter(favourite.initial) }
                }
            } else {
                letter(favourite.initial)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .accessibilityHidden(true)
    }

    private func letter(_ text: String) -> some View {
        ZStack {
            Color(PlatformColor(hex: 0x513568))
            Text(text).font(.system(size: size * (text.count > 1 ? 0.32 : 0.46), weight: .semibold)).foregroundStyle(Color(PlatformColor(hex: 0xF1E8FF)))
                .minimumScaleFactor(0.5).lineLimit(1).padding(4)
        }
    }
}

/// Name, address and icon of one favourite (new or saved).
struct BrowserFavouriteEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrowserFavourite
    @State private var address: String
    @State private var symbol: String
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    #if os(macOS)
    @State private var choosingFile = false
    #endif
    private let isNew: Bool

    init(favourite: BrowserFavourite) {
        _draft = State(initialValue: favourite)
        let isNew = favourite.url.scheme != "https"
        self.isNew = isNew
        _address = State(initialValue: isNew ? "" : favourite.url.absoluteString)
        _symbol = State(initialValue: favourite.symbol ?? "")
    }

    private var preview: BrowserFavourite {
        var shown = draft
        shown.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : symbol
        if let url = BrowserFavourites.address(address) { shown.url = url }
        return shown
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.title).accessibilityIdentifier("favourite.name")
                    TextField("Address", text: $address).urlEntry().autocorrectionDisabled().accessibilityIdentifier("favourite.address")
                }
                Section {
                    HStack(spacing: 16) {
                        BrowserFavouriteIcon(favourite: preview, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(iconDescription).font(.amb(.subheadline))
                            Text("A picture is shown first, then your emoji or text, then the site's own icon.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                        }
                    }
                    .accessibilityIdentifier("favourite.icon.preview")
                    TextField("Emoji or up to 3 letters", text: $symbol).autocorrectionDisabled().accessibilityIdentifier("favourite.symbol")
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose Picture from Photos", systemImage: "photo") }
                        .accessibilityIdentifier("favourite.photo")
                    #if os(macOS)
                    Button { choosingFile = true } label: { Label("Choose Picture File…", systemImage: "folder") }
                        .accessibilityIdentifier("favourite.file")
                    #endif
                    if draft.image != nil {
                        Button(role: .destructive) { draft.image = nil } label: { Label("Remove Picture", systemImage: "xmark.circle") }
                            .accessibilityIdentifier("favourite.photo.remove")
                    }
                } header: { Text("Icon") }
                if let error {
                    Text(error).font(.amb(.footnote)).foregroundStyle(Amb.destructive).accessibilityIdentifier("favourite.error")
                }
                if !isNew {
                    Section {
                        Button(role: .destructive) { model.browser.removeFavourite(draft.id); dismiss() } label: { Text("Remove Favourite") }
                            .accessibilityIdentifier("favourite.remove")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add Favourite" : "Edit Favourite")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold).accessibilityIdentifier("favourite.save")
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    usePicture(data)
                }
            }
            #if os(macOS)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                usePicture(try? Data(contentsOf: url))
            }
            #endif
        }
        .macSheetSize(minWidth: 420, idealWidth: 480, minHeight: 440, idealHeight: 520)
    }

    private var iconDescription: String {
        if draft.image != nil { return "Your picture" }
        if !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Your emoji or text" }
        return draft.siteIcon != nil ? "The site's icon" : "The first letter of the name"
    }

    private func usePicture(_ data: Data?) {
        if let data, let png = BrowserFavourites.iconPNG(from: data) {
            draft.image = png
            error = nil
        } else {
            error = BrowserFavouriteError.image.message
        }
    }

    private func save() {
        guard let url = BrowserFavourites.address(address) else { error = BrowserFavouriteError.address.message; return }
        var saved = draft
        saved.url = url
        saved.symbol = symbol
        do {
            try model.browser.saveFavourite(saved)
            dismiss()
        } catch let refused as BrowserFavouriteError {
            error = refused.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The whole list: drag to reorder, swipe or delete to remove, tap to edit.
struct BrowserFavouritesArrangeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: BrowserFavourite?

    var body: some View {
        let browser = model.browser
        NavigationStack {
            List {
                ForEach(browser.favourites.items) { favourite in
                    Button { editing = favourite } label: {
                        HStack(spacing: 12) {
                            BrowserFavouriteIcon(favourite: favourite, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(favourite.title).font(.amb(.body)).foregroundStyle(Amb.foreground).lineLimit(1)
                                Text(favourite.url.host ?? favourite.url.absoluteString).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("browser.favourites.row")
                    #if os(macOS)
                    .contextMenu {
                        Button(role: .destructive) { browser.removeFavourite(favourite.id) } label: { Label("Remove", systemImage: "trash") }
                    }
                    #endif
                }
                .onMove { browser.moveFavourites(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in for id in offsets.map({ browser.favourites.items[$0].id }) { browser.removeFavourite(id) } }
            }
            .navigationTitle("Favourites")
            .inlineTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { EditButton() }
                #endif
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("browser.favourites.done") }
            }
            .sheet(item: $editing) { favourite in BrowserFavouriteEditor(favourite: favourite) }
        }
        .macSheetSize(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 520)
    }
}
