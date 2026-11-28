import AmbulandoCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Uses the existing authorized member directory, profile/avatar renderer and task assignment write.
/// Searching and staging a selection never writes; Save retains the existing single-assignee semantics.
struct TaskAssigneeControl: View {
    @Environment(AppModel.self) private var model
    let selected: String?
    let members: [MemberRecord]
    let people: PeopleDirectory
    let save: (String?) -> Void
    @State private var presented = false
    @State private var query = ""
    @State private var draft: String?
    @State private var highlight = 0
    @FocusState private var focused: Bool

    private var options: [MemberRecord] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return members.filter { words.isEmpty || people.person($0.npub).name.localizedStandardContains(words) || $0.label.localizedStandardContains(words) || $0.npub.localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        Button {
            query = ""; draft = selected; highlight = 0; presented = true
        } label: {
            HStack(spacing: 7) {
                if let selected { PersonAvatar(person: people.person(selected), size: 24) }
                else { Image(systemName: "person.crop.circle.badge.questionmark") }
                Text(selected.map { people.person($0).name } ?? "Unassigned").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.amb(.footnote).weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 36)
            .background(Amb.accent, in: Capsule()).foregroundStyle(Amb.accentForeground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assignee, \(selected.map { people.person($0).name } ?? "Unassigned")")
        .accessibilityIdentifier("task.assignee")
        .disabled(!model.isUnlocked)
        .popover(isPresented: $presented) { picker }
        .onDisappear { presented = false }
        .onChange(of: model.isUnlocked) { _, unlocked in if !unlocked { presented = false } }
        .onChange(of: model.selectedWorkspaceBoundary) { _, _ in presented = false }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign task").font(.amb(.headline))
            #if os(macOS)
            AssigneeSearchField(query: $query, move: { delta in
                highlight = min(max(0, highlight + delta), max(0, options.count - 1))
            }, select: chooseHighlighted, cancel: { presented = false })
                .frame(height: 26)
                .accessibilityIdentifier("task.assignee.search")
            #else
            TextField("Search people or agents", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("task.assignee.search")
                .onSubmit { chooseHighlighted() }
                .onKeyPress(.downArrow) { highlight = min(highlight + 1, max(0, options.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlight = max(0, highlight - 1); return .handled }
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        Button { draft = nil } label: {
                            HStack { Image(systemName: "person.crop.circle.badge.minus"); Text("Unassigned"); Spacer(); if draft == nil { Image(systemName: "checkmark") } }
                                .padding(8).frame(minHeight: 40)
                        }.buttonStyle(.plain).accessibilityIdentifier("task.assignee.unassign")
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, member in
                            Button { draft = member.npub; highlight = index } label: {
                                HStack(spacing: 9) {
                                    PersonAvatar(person: people.person(member.npub), size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(people.person(member.npub).name)
                                        Text(member.kind == "agent" ? "Agent" : "Person").font(.caption).foregroundStyle(Amb.mutedForeground)
                                    }
                                    Spacer()
                                    if draft == member.npub { Image(systemName: "checkmark") }
                                }.padding(8).frame(minHeight: 44)
                                    .background(index == highlight ? Amb.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain).id(member.id)
                            .accessibilityLabel("\(people.person(member.npub).name), \(member.kind == "agent" ? "Agent" : "Person")")
                            .accessibilityAddTraits(draft == member.npub ? .isSelected : [])
                            .accessibilityIdentifier("task.assignee.option.\(member.npub)")
                        }
                        if options.isEmpty { Text("No matching people or agents").font(.footnote).padding(8) }
                    }
                }
                .onChange(of: highlight) { _, index in if options.indices.contains(index) { proxy.scrollTo(options[index].id) } }
            }.frame(height: 230)
            HStack {
                Button("Cancel") { presented = false }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("task.assignee.cancel")
                Spacer()
                Button("Save") {
                    guard model.isUnlocked, draft == nil || members.contains(where: { $0.npub == draft }) else { return }
                    if draft != selected { save(draft) }
                    presented = false
                }
                .accessibilityIdentifier("task.assignee.save")
                .disabled(draft != nil && !members.contains(where: { $0.npub == draft }))
            }
        }
        .padding(16).frame(width: 330)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlight = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.assignee.picker")
    }

    private func chooseHighlighted() {
        guard options.indices.contains(highlight) else { return }
        draft = options[highlight].npub
    }
}

#if os(macOS)
/// NSTextField's field editor consumes arrows/Return before SwiftUI key handlers on macOS.
/// Handle its standard commands so selection and cancellation work while the search field owns focus.
private struct AssigneeSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let select: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: query)
        field.placeholderString = "Search people or agents"
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("task.assignee.search")
        field.setAccessibilityLabel("Search people or agents")
        DispatchQueue.main.async { [weak field] in if let field { field.window?.makeFirstResponder(field) } }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AssigneeSearchField
        init(_ parent: AssigneeSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.select()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
#endif
