import AmbulandoCore
import SwiftUI

/// The record an "Add to goal" action refers to. Only the reference is saved; the record keeps its place and access.
struct GoalSource: Equatable {
    let type: GoalLinkType
    let recordId: String
    var channelId: String?
    let workspace: WorkspaceRecord

    static func work(_ route: WorkRoute?, workspace: WorkspaceRecord?) -> GoalSource? {
        guard let route, let workspace, route.workspaceId == workspace.id else { return nil }
        switch route {
        case .task(_, let id): return GoalSource(type: .task, recordId: id, workspace: workspace)
        case .doc(_, let id): return GoalSource(type: .doc, recordId: id, workspace: workspace)
        case .file(_, let id): return GoalSource(type: .file, recordId: id, workspace: workspace)
        case .thread(_, let channel, let id): return GoalSource(type: .chat, recordId: id, channelId: channel, workspace: workspace)
        case .threadById(_, let id): return GoalSource(type: .chat, recordId: id, workspace: workspace)
        default: return nil
        }
    }
}

/// Adds the record to one of the owner's active goals, or removes it from one. Hidden until goals are set up.
struct AddToGoalMenu: View {
    @Environment(AppModel.self) private var model
    let source: GoalSource
    @State private var error: String?

    var body: some View {
        let goals = model.goalsModel(for: source.workspace)
        if let goals, goals.channel != nil {
            let mine = goals.goals(linking: source.type, recordId: source.recordId)
            Menu {
                let open = goals.goals.filter { $0.goal.status != .archived }
                if open.isEmpty { Text("No goals yet") }
                ForEach(open) { doc in
                    let linked = doc.goal.links.contains { $0.type == source.type && $0.recordId == source.recordId.lowercased() }
                    Button {
                        Task {
                            let edit: GoalEdit = linked ? .unlink(source.type, recordId: source.recordId)
                                : .link(GoalLink(type: source.type, recordId: source.recordId, channelId: source.channelId))
                            do { try await goals.edit(doc.id, edit) } catch { self.error = GoalsModel.message(error); await goals.reload(doc.id) }
                        }
                    } label: { Label(doc.goal.name, systemImage: linked ? "checkmark" : "target") }
                }
            } label: {
                Image(systemName: mine.isEmpty ? "target" : "target").foregroundStyle(mine.isEmpty ? Amb.primary : Amb.success)
            }
            .menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(mine.isEmpty ? "Add to goal" : "In \(mine.count) goal\(mine.count == 1 ? "" : "s")")
            .accessibilityIdentifier("goal.add")
            .help(mine.isEmpty ? "Add to goal" : "In goal: " + mine.map(\.goal.name).joined(separator: ", "))
            .task(id: model.selectedWorkspaceBoundary) { if !goals.loaded { await goals.refresh() } }
            .alert("Couldn’t update the goal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        } else if let goals, !goals.loaded {
            Color.clear.frame(width: 0, height: 0).task(id: model.selectedWorkspaceBoundary) { await goals.refresh() }
        }
    }
}
