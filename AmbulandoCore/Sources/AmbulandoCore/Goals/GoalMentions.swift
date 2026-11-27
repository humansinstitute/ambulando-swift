import Foundation

extension GoalsService {
    /// Uses the same authorized personal home as Goals, with complete File pagination.
    /// A failed or unsafe load remains an error, never a misleading empty list.
    public func mentionSuggestions(query: MentionQuery) async throws -> [MentionSuggestion] {
        guard query.allows(.file) else { return [] }
        let snapshot = try await load()
        if case .unsafe(let reason) = snapshot.space { throw GoalError.invalid(reason) }
        guard snapshot.unreadable.isEmpty else {
            throw GoalError.invalid("Some personal goals could not be read. Open Goals to review them.")
        }
        return GoalMentions.suggestions(snapshot.goals, query: query)
    }
}

public enum GoalMentions {
    /// Names come from verified goal content; identity is always the File UUID, never a version or storage object.
    public static func suggestions(_ documents: [GoalDocument], query: MentionQuery) -> [MentionSuggestion] {
        guard query.allows(.file) else { return [] }
        return documents.filter {
            let raw = (try? JSONSerialization.jsonObject(with: $0.file.raw)) as? [String: Any] ?? [:]
            return GoalFiles.isGoal($0.file) && raw["access_removed"] as? Bool != true
                && !["access_removed", "revoked"].contains(raw["record_state"] as? String ?? "")
                && query.rank($0.goal.name) != nil
        }.map {
            MentionSuggestion(mention: Mention(type: .file, npub: $0.file.id, label: $0.goal.name),
                              detail: "Goal", updatedAt: $0.file.updatedAt)
        }
    }
}
