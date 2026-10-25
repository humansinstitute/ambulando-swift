import SwiftUI

#if os(iOS)
/// Window-local presentation state, shared with the retained section hosts. Domain navigation and drafts stay
/// in AppModel; resizing never creates a second workspace shell or replaces a section host.
@Observable
final class TabletNavigation {
    var available = false
    var collapsed = false
    var visible: Bool { available && !collapsed }
}

extension EnvironmentValues {
    @Entry var tabletNavigation: TabletNavigation? = nil
}

/// The tablet uses the same context navigation as the compact drawer and the Mac column.
struct TabletSidebar: View {
    @Environment(AppModel.self) private var model
    let sections: [AppMode]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.self) { section in
                    let selected = model.mode == section
                    Button {
                        if selected { model.popToRoot(section) } else { model.show(section) }
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.amb(.body).weight(selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                            .padding(.horizontal, 12)
                            .foregroundStyle(selected ? Amb.selectedForeground : Amb.foreground)
                            .background(selected ? Amb.selectedFill : .clear,
                                        in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("section.\(section.rawValue)")
                }
            }
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sections")
            .accessibilityIdentifier("section.bar")
            Divider()
            SidebarContent()
        }
        .background(Amb.card)
        .accessibilityIdentifier("tablet.sidebar")
    }
}

/// A simulator-only compact-window harness for repeatable multitasking layout checks. It requires explicit sample
/// data mode, is visibly labelled, and cannot affect a Release/device installation.
struct TabletFixtureWindow: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-AmbulandoUITestFixture"),
           ProcessInfo.processInfo.arguments.contains("-AmbulandoFixtureCompactWindow") {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text("Sample compact window · 420 pt")
                        .font(.amb(.caption)).foregroundStyle(Amb.warning)
                        .frame(maxWidth: .infinity).padding(6).background(Amb.warningBackground)
                }
                .frame(width: 420)
                .environment(\.horizontalSizeClass, .compact)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
#endif

extension View {
    /// A readable iPad content column; iPhone and Mac keep their existing layout. The surrounding pane still fills
    /// the window, with navigation and list/board surfaces using their own available width.
    @ViewBuilder func tabletReadingWidth(_ width: CGFloat = 860) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            frame(maxWidth: width).frame(maxWidth: .infinity)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
