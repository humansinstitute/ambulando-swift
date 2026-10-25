import Foundation

// Public Nostr profiles (schema v5). Rows belong to a connection (origin + signer) and go with it on disconnect. A
// profile is kept only while someone in one of that connection's workspaces (member, agent, message sender or the
// signer) still refers to it, so removing a workspace also forgets the people only it showed.

extension Schema {
    static func migrateV5(_ db: SQLiteConnection) throws {
        try db.execute("""
        CREATE TABLE profiles(
          connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
          pubkey TEXT NOT NULL, npub TEXT NOT NULL,
          display_name TEXT, name TEXT, picture TEXT, nip05 TEXT,
          event_id TEXT, event_created_at INTEGER,
          status TEXT NOT NULL, checked_at REAL NOT NULL,
          PRIMARY KEY(connection_id, pubkey));
        CREATE INDEX profiles_checked ON profiles(connection_id, checked_at);
        CREATE INDEX messages_sender ON messages(workspace_id, sender_npub);
        """)
    }
}

public enum ProfileLimits {
    /// Most profiles kept per connection.
    public static let maxRows = 2000
    /// Most people considered in one refresh.
    public static let maxCandidates = 500
}

extension StoreWriter {
    /// Stores the outcome of one relay check: verified profiles in `found` replace older ones (NIP-01 order) and refresh
    /// `checked_at`; keys in `checked` without a profile keep any earlier profile, or become a `missing` entry.
    /// `unlessOff`: an `app_state` key; when it reads "off" (the user turned profiles off meanwhile) nothing is written.
    /// Checked in the same transaction, so a switch saved through this writer can never be overtaken by a late round.
    public func recordProfileCheck(connectionId: String, found: [ProfileRecord], checked: [String: String], at date: Date,
                                   unlessOff: String? = nil) async throws {
        let changed: Bool = try db.transaction {
            var changed = false
            if let unlessOff {
                let state = try db.prepare("SELECT value FROM app_state WHERE key = ?")
                try state.bind([.text(unlessOff)])
                if try state.step(), state.text(0) == "off" { return false }
            }
            let read = try db.prepare("SELECT event_id, event_created_at, status FROM profiles WHERE connection_id = ? AND pubkey = ?")
            let upsert = try db.prepare("""
            INSERT INTO profiles(connection_id, pubkey, npub, display_name, name, picture, nip05, event_id, event_created_at, status, checked_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(connection_id, pubkey) DO UPDATE SET npub=excluded.npub, display_name=excluded.display_name, name=excluded.name,
              picture=excluded.picture, nip05=excluded.nip05, event_id=excluded.event_id, event_created_at=excluded.event_created_at,
              status=excluded.status, checked_at=excluded.checked_at
            """)
            let touch = try db.prepare("UPDATE profiles SET checked_at = ? WHERE connection_id = ? AND pubkey = ?")
            var stored: Set<String> = []
            for record in found where checked[record.pubkey] != nil {
                try read.bind([.text(connectionId), .text(record.pubkey)])
                let existing: ProfileRecord? = try read.step()
                    ? ProfileRecord(pubkey: record.pubkey, npub: record.npub, eventId: read.text(0), eventCreatedAt: read.isNull(1) ? nil : Int(read.int(1)),
                                    status: ProfileRecord.Status(rawValue: read.text(2) ?? "") ?? .missing, checkedAt: date)
                    : nil
                stored.insert(record.pubkey)
                if let existing, existing.status == .found, !record.isNewer(than: existing) {
                    try touch.run([.double(date.timeIntervalSince1970), .text(connectionId), .text(record.pubkey)])
                    continue
                }
                try upsert.run([.text(connectionId), .text(record.pubkey), .text(record.npub), record.displayName.sql, record.name.sql, record.picture.sql,
                                record.nip05.sql, record.eventId.sql, record.eventCreatedAt.map { .int(Int64($0)) } ?? .null,
                                .text(ProfileRecord.Status.found.rawValue), .double(date.timeIntervalSince1970)])
                changed = true
            }
            let absent = try db.prepare("""
            INSERT INTO profiles(connection_id, pubkey, npub, status, checked_at) VALUES(?,?,?,?,?)
            ON CONFLICT(connection_id, pubkey) DO UPDATE SET checked_at = excluded.checked_at
            """)
            for (pubkey, npub) in checked where !stored.contains(pubkey) {
                try absent.run([.text(connectionId), .text(pubkey), .text(npub), .text(ProfileRecord.Status.missing.rawValue), .double(date.timeIntervalSince1970)])
            }
            return changed
        }
        if changed { await emit([ChangeKey(.profiles)]) }
    }

    /// Forgets profiles nobody in the connection's workspaces refers to any more, then the oldest checks beyond the cap.
    public func pruneProfiles(connectionId: String, maxRows: Int = ProfileLimits.maxRows) async throws {
        let removed: Int = try db.transaction { try pruneProfileRows(connectionId: connectionId, maxRows: maxRows) }
        if removed > 0 { await emit([ChangeKey(.profiles)]) }
    }

    func pruneProfileRows(connectionId: String, maxRows: Int = ProfileLimits.maxRows) throws -> Int {
        let c = SQLValue.text(connectionId)
        try db.prepare("""
        DELETE FROM profiles WHERE connection_id = ?1
          AND npub NOT IN (SELECT signer_npub FROM connections WHERE id = ?1)
          AND npub NOT IN (SELECT npub FROM members WHERE workspace_id IN (SELECT workspace_id FROM workspaces WHERE connection_id = ?1))
          AND npub NOT IN (SELECT agent_npub FROM workspace_agents WHERE workspace_id IN (SELECT workspace_id FROM workspaces WHERE connection_id = ?1))
          AND npub NOT IN (SELECT sender_npub FROM messages WHERE sender_npub IS NOT NULL
                           AND workspace_id IN (SELECT workspace_id FROM workspaces WHERE connection_id = ?1))
        """).run([c])
        var removed = db.changes
        try db.prepare("""
        DELETE FROM profiles WHERE connection_id = ?1 AND pubkey NOT IN
          (SELECT pubkey FROM profiles WHERE connection_id = ?1 ORDER BY checked_at DESC LIMIT ?2)
        """).run([c, .int(Int64(maxRows))])
        removed += db.changes
        return removed
    }

    /// Drops every cached profile of a connection (Settings › Refresh Nostr profiles keeps rows until replaced instead).
    public func clearProfiles(connectionId: String) async throws {
        try db.prepare("DELETE FROM profiles WHERE connection_id = ?").run([.text(connectionId)])
        await emit([ChangeKey(.profiles)])
    }
}

extension StoreReader {
    static let profileColumns = "pubkey, npub, display_name, name, picture, nip05, event_id, event_created_at, status, checked_at"

    static func profile(_ s: SQLiteConnection.Statement) -> ProfileRecord {
        ProfileRecord(pubkey: s.text(0)!, npub: s.text(1)!, displayName: s.text(2), name: s.text(3), picture: s.text(4), nip05: s.text(5),
                      eventId: s.text(6), eventCreatedAt: s.isNull(7) ? nil : Int(s.int(7)),
                      status: ProfileRecord.Status(rawValue: s.text(8) ?? "") ?? .missing, checkedAt: Date(timeIntervalSince1970: s.double(9)))
    }

    /// Cached profiles of a connection, most recently checked first (bounded).
    public func profiles(connectionId: String, limit: Int = ProfileLimits.maxRows) throws -> [ProfileRecord] {
        let s = try db.prepare("SELECT \(Self.profileColumns) FROM profiles WHERE connection_id = ? ORDER BY checked_at DESC LIMIT ?")
        try s.bind([.text(connectionId), .int(Int64(limit))])
        var rows: [ProfileRecord] = []
        while try s.step() { rows.append(Self.profile(s)) }
        return rows
    }

    /// People a workspace shows: the signer, members, agents and the most recent message senders (bounded, valid npubs).
    public func profileCandidates(connectionId: String, workspaceId: String, limit: Int = ProfileLimits.maxCandidates) throws -> [String] {
        let s = try db.prepare("""
        SELECT npub FROM (
          SELECT signer_npub AS npub, 0 AS rank FROM connections WHERE id = ?1
          UNION ALL SELECT npub, 1 FROM members WHERE workspace_id = ?2
          UNION ALL SELECT agent_npub, 2 FROM workspace_agents WHERE workspace_id = ?2
          UNION ALL SELECT sender_npub, 3 FROM (SELECT sender_npub, MAX(created_at) AS latest FROM messages
                                                WHERE workspace_id = ?2 AND sender_npub IS NOT NULL GROUP BY sender_npub
                                                ORDER BY latest DESC LIMIT ?3))
        GROUP BY npub ORDER BY MIN(rank) LIMIT ?3
        """)
        try s.bind([.text(connectionId), .text(workspaceId), .int(Int64(limit))])
        var out: [String] = []
        while try s.step() { if let npub = s.text(0), NostrKeys.isValidNpub(npub) { out.append(npub) } }
        return out
    }

    /// Everyone the workspace knows, resolved for display (see `PeopleDirectory`). Cheap enough to run with every chat
    /// snapshot: three bounded, indexed reads.
    public func people(connectionId: String?, workspaceId: String) throws -> PeopleDirectory {
        let members = try self.members(workspaceId: workspaceId)
        var agents: [String: PeopleDirectory.AgentInfo] = [:]
        let a = try db.prepare("SELECT agent_npub, display_name, raw FROM workspace_agents WHERE workspace_id = ? ORDER BY sort_order LIMIT 500")
        try a.bind([.text(workspaceId)])
        while try a.step() {
            guard let npub = a.text(0), agents[npub] == nil else { continue }
            let raw = (try? JSONSerialization.jsonObject(with: a.blob(2))) as? [String: Any]
            agents[npub] = .init(name: a.text(1) ?? "", avatarURL: raw?["avatar_url"] as? String)
        }
        let profiles = try connectionId.map { try self.profiles(connectionId: $0) } ?? []
        return PeopleDirectory(members: members, agents: agents, profiles: profiles)
    }

    /// `people(connectionId:workspaceId:)` for the connection the workspace belongs to (screens that only know the
    /// workspace: task and document names, pickers, sidebar labels).
    public func people(workspaceId: String) throws -> PeopleDirectory {
        let s = try db.prepare("SELECT connection_id FROM workspaces WHERE workspace_id = ?")
        try s.bind([.text(workspaceId)])
        let connectionId = try s.step() ? s.text(0) : nil
        return try people(connectionId: connectionId, workspaceId: workspaceId)
    }

    /// The workspace's members with `displayName` set to the name the app shows (public profile first, see
    /// `PeopleDirectory`), sorted by it: for pickers, mention suggestions and name maps, which read `label`.
    public func directoryMembers(workspaceId: String) throws -> [MemberRecord] {
        let people = try people(workspaceId: workspaceId)
        return try members(workspaceId: workspaceId).map { member in
            let person = people.person(member.npub)
            return MemberRecord(workspaceId: member.workspaceId, actorId: member.actorId, npub: member.npub, kind: member.kind,
                                displayName: person.nameSource == .npub ? nil : person.name)
        }
        .sorted { a, b in
            switch a.label.localizedCaseInsensitiveCompare(b.label) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.npub < b.npub
            }
        }
    }
}
