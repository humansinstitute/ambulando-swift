import Foundation

extension GoalsService {
    private struct SavedGoal: Codable { let id: String; let version: String }
    private struct SavedDocument: Codable { let file: Data; let goal: Data; var storage: GoalDocument.Storage? = nil }
    private struct SavedGoals: Codable { let channel: Data; let goals: [SavedGoal] }
    /// The channel was privately verified when saved. It is a read location, never permission to write.
    public func cached() async -> GoalsSnapshot? {
        guard let cache, let bytes = try? await cache.read("goals") else { return nil }
        do {
            let saved = try JSONDecoder().decode(SavedGoals.self, from: bytes)
            let channel = try ChannelRecord(raw: saved.channel)
            guard channel.workspaceId == workspaceId, GoalsSpace.isOwnedBy(channel, viewer: viewer) else { return nil }
            var goals: [GoalDocument] = [], unreadable: [UnreadableGoal] = []
            for row in saved.goals {
                do {
                    guard let bytes = try await cache.read("goal:" + row.id + ":" + row.version) else { throw FileNappletError.unavailable }
                    let document = try JSONDecoder().decode(SavedDocument.self, from: bytes)
                    let file = try FileRecord(raw: document.file)
                    guard file.id == row.id, file.workspaceId == workspaceId, file.channelId == channel.id else { throw FileNappletError.invalid }
                    goals.append(GoalDocument(file: file, versionId: row.version, goal: try Goal.parse(document.goal), storage: document.storage ?? .file))
                } catch {
                    unreadable.append(UnreadableGoal(fileId: row.id, name: "Saved goal", reason: "Saved content is unavailable. Connect to refresh this goal."))
                }
            }
            return GoalsSnapshot(space: .ready(channel: channel, agents: []), goals: goals.sorted(by: Self.order), unreadable: unreadable)
        } catch { return nil }
    }
    func remember(_ snapshot: GoalsSnapshot, epoch: String? = nil) async {
        guard let cache else { return }
        guard case .ready(let channel, _) = snapshot.space else { await cache.remove("goals"); return }
        for document in snapshot.goals {
            if let bytes = try? JSONEncoder().encode(SavedDocument(file: document.file.raw, goal: document.goal.encode(), storage: document.storage)) {
                try? await cache.save("goal:" + document.id + ":" + document.versionId, bytes, dependencies: [channel.id, document.id], expectedEpoch: epoch)
            }
        }
        let saved = SavedGoals(channel: channel.raw, goals: snapshot.goals.map { SavedGoal(id: $0.id, version: $0.versionId) })
        if let bytes = try? JSONEncoder().encode(saved) { try? await cache.save("goals", bytes, dependencies: [channel.id], expectedEpoch: epoch) }
    }
    public func remember(_ document: GoalDocument) async {
        guard var snapshot = await cached() else { return }
        snapshot.goals = (snapshot.goals.filter { $0.id != document.id } + [document]).sorted(by: Self.order)
        await remember(snapshot)
    }
}
