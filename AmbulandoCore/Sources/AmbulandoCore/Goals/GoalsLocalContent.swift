import Foundation

extension GoalsService {
    private struct SavedGoal: Codable { let id: String; let version: String }
    private struct SavedDocument: Codable { let file: Data; let goal: Data; var storage: GoalDocument.Storage? = nil }
    private struct SavedGoals: Codable { let channel: Data; let goals: [SavedGoal] }
    /// The channel was privately verified when saved. It is a read location, never permission to write.
    public func cached() async -> GoalsSnapshot? {
        guard let cache else { return nil }
        var savedBytes = try? await cache.read("goals-relational")
        if savedBytes == nil { savedBytes = try? await cache.read("goals") }
        guard let bytes = savedBytes else { return nil }
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
    func remember(_ snapshot: GoalsSnapshot, epoch: String? = nil, storage: GoalDocument.Storage = .file) async {
        guard let cache else { return }
        guard case .ready(let channel, _) = snapshot.space else { await cache.remove("goals"); await cache.remove("goals-relational"); return }
        // A legacy read started before cutover must not replace a newer canonical SQL snapshot after it finishes.
        if storage == .file, (try? await cache.read("goals-authority:" + channel.id)) != nil { return }
        for document in snapshot.goals {
            if let bytes = try? JSONEncoder().encode(SavedDocument(file: document.file.raw, goal: document.goal.encode(), storage: document.storage)) {
                try? await cache.save("goal:" + document.id + ":" + document.versionId, bytes, dependencies: [channel.id, document.id], expectedEpoch: epoch)
            }
        }
        let saved = SavedGoals(channel: channel.raw, goals: snapshot.goals.map { SavedGoal(id: $0.id, version: $0.versionId) })
        if let bytes = try? JSONEncoder().encode(saved) {
            try? await cache.save(storage == .relational ? "goals-relational" : "goals", bytes, dependencies: [channel.id], expectedEpoch: epoch)
        }
    }
    private struct SavedWorkspaceGoal: Codable { let id: String; let version: String; let channel: String }
    private struct SavedWorkspace: Codable { let goals: [SavedWorkspaceGoal]; let warnings: [String] }

    /// Read-only workspace discovery has its own index; it never narrows or overwrites the private Home index.
    public func cachedWorkspace() async -> GoalsSnapshot? {
        guard let cache, let bytes = try? await cache.read("workspace-goals"),
              let saved = try? JSONDecoder().decode(SavedWorkspace.self, from: bytes) else { return nil }
        guard let epoch = try? await cache.epoch() else { return nil }
        var goals: [GoalDocument] = []
        for row in saved.goals {
            guard let bytes = try? await cache.read("workspace-goal:" + row.id + ":" + row.version),
                  let document = try? JSONDecoder().decode(SavedDocument.self, from: bytes),
                  let file = try? FileRecord(raw: document.file), file.id == row.id,
                  file.workspaceId == workspaceId, file.channelId == row.channel, goalRecordAvailable(file.raw),
                  let goal = try? Goal.parse(document.goal) else { continue }
            goals.append(GoalDocument(file: file, versionId: row.version, goal: goal, storage: document.storage ?? .file))
        }
        guard (try? await cache.epoch()) == epoch else { return nil }
        return GoalsSnapshot(space: .unsafe("Saved workspace goals are read-only until personal Goals access is verified."),
            goals: goals.sorted(by: Self.order), unreadable: [], warnings: saved.warnings)
    }

    func rememberWorkspace(_ snapshot: GoalsSnapshot, epoch: String?, scopeByChannel: [String: String]) async {
        guard let cache else { return }
        for document in snapshot.goals {
            if let bytes = try? JSONEncoder().encode(SavedDocument(file: document.file.raw, goal: document.goal.encode(), storage: document.storage)) {
                let dependencies = [document.file.channelId, document.id] + ((document.file.scopeId ?? scopeByChannel[document.file.channelId]).map { [$0] } ?? [])
                try? await cache.save("workspace-goal:" + document.id + ":" + document.versionId, bytes, dependencies: dependencies, expectedEpoch: epoch)
            }
        }
        let saved = SavedWorkspace(goals: snapshot.goals.map { SavedWorkspaceGoal(id: $0.id, version: $0.versionId, channel: $0.file.channelId) }, warnings: snapshot.warnings)
        if let bytes = try? JSONEncoder().encode(saved) {
            try? await cache.save("workspace-goals", bytes, expectedEpoch: epoch)
        }
    }

    public func remember(_ document: GoalDocument) async {
        guard var snapshot = await cached(), case .ready(let channel, _) = snapshot.space, document.file.channelId == channel.id else { return }
        snapshot.goals = (snapshot.goals.filter { $0.id != document.id } + [document]).sorted(by: Self.order)
        await remember(snapshot, storage: document.storage)
    }
}
