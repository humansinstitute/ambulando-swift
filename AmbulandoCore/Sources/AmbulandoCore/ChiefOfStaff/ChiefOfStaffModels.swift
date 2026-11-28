import Foundation

/// Ambulando Chief of Staff wire contract (v1) — matches `scripts/chief-of-staff/model.mjs` and Android's
/// `ChiefOfStaffContract`.
///
/// Storage uses existing Ambulando-app-bound versioned NStack Files with server-enforced channel grants and
/// `base_version_id` CAS (`409 stale_base_version`). Encryption is deferred in v1 (`envelope_version = 1`,
/// `encryption.mode = "none"`); the `ChiefOfStaffEnvelopeAdapter` seam allows future client/agent encryption
/// without changing topic IDs, record references, or lookup routes. Never claim payloads are encrypted today.
public enum ChiefOfStaffContract {
    public static let systemKeyAssignment = "ambulando.chief_of_staff"
    public static let systemKeyOntology = "ambulando.chief_of_staff.ontology"

    public static let mimeAssignment = "application/vnd.ambulando.chief-of-staff-assignment+json"
    public static let mimeJobStatus = "application/vnd.ambulando.chief-of-staff-job-status+json"
    public static let mimeOntology = "application/vnd.ambulando.chief-of-staff-ontology+json"
    public static let mimeCorrections = "application/vnd.ambulando.chief-of-staff-corrections+json"

    public static let fileNameAssignment = "Chief of Staff.assignment.json"
    public static let fileNameJobStatus = "Chief of Staff.job-status.json"
    public static let fileNameOntology = "Chief of Staff.ontology.json"
    public static let fileNameCorrections = "Chief of Staff.corrections.json"

    public static let schemaAssignment = "ambulando.chief_of_staff.assignment"
    public static let schemaJobStatus = "ambulando.chief_of_staff.job_status"
    public static let schemaOntology = "ambulando.chief_of_staff.ontology"
    public static let schemaCorrections = "ambulando.chief_of_staff.corrections"

    public static let maxBytes = 4 * 1024 * 1024

    public static let scheduleStates: Set<String> = [
        "unconfigured", "pending", "scheduled", "running", "healthy", "error", "disabled_stale",
    ]
    public static let sourceTypes: Set<String> = [
        "message", "thread", "audio_note", "task", "doc", "file",
    ]
    public static let evidenceStatuses: Set<String> = [
        "active", "stale", "deleted", "inaccessible",
    ]
    public static let correctionKinds: Set<String> = [
        "rename", "set_description", "set_aliases", "set_kind",
        "merge_topics", "reject_evidence", "pin_evidence", "archive_topic",
    ]
    public static let forbiddenAssignmentFields: Set<String> = [
        "topics", "evidence", "cohort_id", "cohort_channel_id", "job_status",
    ]

    public static func isIsoTimestamp(_ value: String?) -> Bool {
        guard let value,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil
        else { return false }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if frac.date(from: value) != nil { return true }
        return ISO8601DateFormatter().date(from: value) != nil
    }

    public static func parseTimestamp(_ value: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    public static func formatTimestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func cohortId(ownerNpub: String, agentNpub: String, assignmentEpoch: Int = 1) -> String {
        let epoch = max(1, assignmentEpoch)
        return "owner:\(ownerNpub):agent:\(agentNpub):epoch:\(epoch)"
    }

    public static func isActiveRecord(_ raw: Data) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return false }
        return isActiveObject(o)
    }

    public static func isActiveObject(_ o: [String: Any]) -> Bool {
        let state = o["record_state"] as? String ?? ""
        let archivedAt = o["archived_at"]
        let deletedAt = o["deleted_at"]
        return !["deleted", "archived"].contains(state)
            && (archivedAt == nil || archivedAt is NSNull)
            && (deletedAt == nil || deletedAt is NSNull)
            && o["is_archived"] as? Bool != true
            && o["access_removed"] as? Bool != true
    }

    // MARK: Metadata builders

    public static func assignmentChannelMetadata(workspaceId: String, appNpub: String) -> [String: Any] {
        [
            "system_key": systemKeyAssignment,
            "chief_of_staff": [
                "schema_version": 1,
                "kind": "assignment",
                "workspace_id": workspaceId.lowercased(),
                "app_npub": appNpub,
            ],
        ]
    }

    public static func assignmentFileMetadata(workspaceId: String, appNpub: String) -> [String: Any] {
        [
            "chief_of_staff": [
                "schema_version": 1,
                "kind": "assignment",
                "workspace_id": workspaceId.lowercased(),
                "app_npub": appNpub,
            ],
        ]
    }

    public static func cohortChannelMetadata(
        workspaceId: String,
        appNpub: String,
        ownerNpub: String,
        agentNpub: String,
        assignmentEpoch: Int = 1
    ) -> [String: Any] {
        let epoch = max(1, assignmentEpoch)
        return [
            "system_key": systemKeyOntology,
            "chief_of_staff": [
                "schema_version": 1,
                "kind": "ontology_cohort",
                "cohort_kind": "owner_agent_private",
                "cohort_id": cohortId(ownerNpub: ownerNpub, agentNpub: agentNpub, assignmentEpoch: epoch),
                "assignment_epoch": epoch,
                "workspace_id": workspaceId.lowercased(),
                "app_npub": appNpub,
                "owner_npub": ownerNpub,
                "agent_npub": agentNpub,
            ],
        ]
    }

    public static func cohortFileMetadata(
        kind: String,
        workspaceId: String,
        appNpub: String,
        ownerNpub: String,
        agentNpub: String,
        assignmentEpoch: Int = 1
    ) -> [String: Any] {
        let epoch = max(1, assignmentEpoch)
        return [
            "chief_of_staff": [
                "schema_version": 1,
                "kind": kind,
                "cohort_kind": "owner_agent_private",
                "cohort_id": cohortId(ownerNpub: ownerNpub, agentNpub: agentNpub, assignmentEpoch: epoch),
                "assignment_epoch": epoch,
                "workspace_id": workspaceId.lowercased(),
                "app_npub": appNpub,
                "owner_npub": ownerNpub,
                "agent_npub": agentNpub,
            ],
        ]
    }

    // MARK: Metadata matchers

    public static func isAssignmentChannel(_ channel: ChannelRecord, workspaceId: String, appNpub: String) -> Bool {
        let ws = workspaceId.lowercased()
        guard channel.kind == "channel", channel.workspaceId == ws, isActiveRecord(channel.raw),
              let raw = try? JSONSerialization.jsonObject(with: channel.raw) as? [String: Any],
              let meta = raw["metadata"] as? [String: Any],
              meta["system_key"] as? String == systemKeyAssignment,
              let cos = meta["chief_of_staff"] as? [String: Any]
        else { return false }
        return flexibleInt(cos["schema_version"]) == 1
            && cos["kind"] as? String == "assignment"
            && (cos["workspace_id"] as? String)?.lowercased() == ws
            && cos["app_npub"] as? String == appNpub
    }

    public static func isCohortChannel(
        _ channel: ChannelRecord,
        workspaceId: String,
        appNpub: String,
        ownerNpub: String,
        agentNpub: String,
        assignmentEpoch: Int? = nil
    ) -> Bool {
        let ws = workspaceId.lowercased()
        guard channel.kind == "channel", channel.workspaceId == ws, isActiveRecord(channel.raw),
              let raw = try? JSONSerialization.jsonObject(with: channel.raw) as? [String: Any],
              let meta = raw["metadata"] as? [String: Any],
              meta["system_key"] as? String == systemKeyOntology,
              let cos = meta["chief_of_staff"] as? [String: Any]
        else { return false }
        let epoch = flexibleInt(cos["assignment_epoch"])
        let epochMatches: Bool
        if let expectedEpoch = assignmentEpoch {
            epochMatches = epoch == expectedEpoch
                && cos["cohort_id"] as? String == cohortId(ownerNpub: ownerNpub, agentNpub: agentNpub, assignmentEpoch: expectedEpoch)
        } else {
            epochMatches = (epoch ?? 0) >= 1
        }
        return flexibleInt(cos["schema_version"]) == 1
            && cos["kind"] as? String == "ontology_cohort"
            && cos["cohort_kind"] as? String == "owner_agent_private"
            && (cos["workspace_id"] as? String)?.lowercased() == ws
            && cos["app_npub"] as? String == appNpub
            && cos["owner_npub"] as? String == ownerNpub
            && cos["agent_npub"] as? String == agentNpub
            && epochMatches
    }

    public static func normalizedMime(_ contentType: String?) -> String {
        contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }

    public static func isAssignmentFile(_ file: FileRecord, workspaceId: String, appNpub: String) -> Bool {
        let ws = workspaceId.lowercased()
        guard !file.archived, file.workspaceId == ws, normalizedMime(file.contentType) == mimeAssignment,
              isActiveRecord(file.raw),
              let raw = try? JSONSerialization.jsonObject(with: file.raw) as? [String: Any],
              let cos = (raw["metadata"] as? [String: Any])?["chief_of_staff"] as? [String: Any]
        else { return false }
        return flexibleInt(cos["schema_version"]) == 1
            && cos["kind"] as? String == "assignment"
            && (cos["workspace_id"] as? String)?.lowercased() == ws
            && cos["app_npub"] as? String == appNpub
    }

    public static func isCohortFile(
        _ file: FileRecord,
        kind: String,
        mime: String,
        workspaceId: String,
        appNpub: String,
        ownerNpub: String,
        agentNpub: String,
        assignmentEpoch: Int
    ) -> Bool {
        let ws = workspaceId.lowercased()
        guard !file.archived, file.workspaceId == ws, normalizedMime(file.contentType) == mime,
              isActiveRecord(file.raw),
              let raw = try? JSONSerialization.jsonObject(with: file.raw) as? [String: Any],
              let cos = (raw["metadata"] as? [String: Any])?["chief_of_staff"] as? [String: Any]
        else { return false }
        return flexibleInt(cos["schema_version"]) == 1
            && cos["kind"] as? String == kind
            && cos["cohort_kind"] as? String == "owner_agent_private"
            && flexibleInt(cos["assignment_epoch"]) == assignmentEpoch
            && cos["cohort_id"] as? String == cohortId(ownerNpub: ownerNpub, agentNpub: agentNpub, assignmentEpoch: assignmentEpoch)
            && (cos["workspace_id"] as? String)?.lowercased() == ws
            && cos["app_npub"] as? String == appNpub
            && cos["owner_npub"] as? String == ownerNpub
            && cos["agent_npub"] as? String == agentNpub
    }
}

// MARK: - Errors

public enum ChiefOfStaffError: Error, LocalizedError, Sendable, Equatable {
    case forbidden(String)
    case conflict(String)
    case notInitialized(String)
    case restricted(String)
    case boundaryMismatch(String)
    case integrity(String)
    case invalid(String)
    case offline(String)

    public var errorDescription: String? {
        switch self {
        case .forbidden(let m), .conflict(let m), .notInitialized(let m), .restricted(let m),
             .boundaryMismatch(let m), .integrity(let m), .invalid(let m), .offline(let m):
            m
        }
    }
}

// MARK: - Encryption-ready envelope adapter (deferred in v1)

public protocol ChiefOfStaffEnvelopeAdapter: Sendable {
    var mode: String { get }
    func encrypt(payload: [String: Any]) throws -> [String: Any]
    func decrypt(envelope: [String: Any]) throws -> [String: Any]
}

public struct PlaintextChiefOfStaffEnvelopeAdapter: ChiefOfStaffEnvelopeAdapter {
    public let mode = "none"
    public init() {}

    public func encrypt(payload: [String: Any]) throws -> [String: Any] {
        [
            "envelope_version": 1,
            "encryption": ["mode": "none"],
            "payload": payload,
        ]
    }

    public func decrypt(envelope: [String: Any]) throws -> [String: Any] {
        guard flexibleInt(envelope["envelope_version"]) == 1,
              let encryption = envelope["encryption"] as? [String: Any]
        else { throw ChiefOfStaffError.invalid("Unsupported Chief of Staff envelope version.") }
        let mode = encryption["mode"] as? String ?? ""
        guard mode == "none" else {
            throw ChiefOfStaffError.invalid("Encrypted Chief of Staff payload (\(mode)) requires a matching decryption adapter.")
        }
        guard let payload = envelope["payload"] as? [String: Any] else {
            throw ChiefOfStaffError.invalid("Invalid Chief of Staff envelope payload.")
        }
        return payload
    }
}

public enum ChiefOfStaffEnvelope {
    public static func encode(_ payload: [String: Any], adapter: any ChiefOfStaffEnvelopeAdapter = PlaintextChiefOfStaffEnvelopeAdapter()) throws -> Data {
        let env = try adapter.encrypt(payload: payload)
        let bytes = try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])
        guard bytes.count <= ChiefOfStaffContract.maxBytes else {
            throw ChiefOfStaffError.invalid("Chief of Staff document exceeds 4 MiB limit.")
        }
        return bytes
    }

    public static func decode(_ bytes: Data, adapter: any ChiefOfStaffEnvelopeAdapter = PlaintextChiefOfStaffEnvelopeAdapter()) throws -> [String: Any] {
        guard bytes.count <= ChiefOfStaffContract.maxBytes else {
            throw ChiefOfStaffError.invalid("Chief of Staff document exceeds 4 MiB limit.")
        }
        // Strict UTF-8 check
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw ChiefOfStaffError.invalid("Chief of Staff document is not valid UTF-8.")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ChiefOfStaffError.invalid("Chief of Staff envelope is not valid JSON.")
        }
        return try adapter.decrypt(envelope: parsed)
    }
}

// MARK: - Domain models

public struct ExpectedWorkspaceContext: Sendable, Equatable {
    public let workspaceId: String
    public let ownerNpub: String
    public let appNpub: String

    public init(workspaceId: String, ownerNpub: String, appNpub: String) {
        self.workspaceId = workspaceId.lowercased()
        self.ownerNpub = ownerNpub
        self.appNpub = appNpub
    }
}

/// Fields a newer writer added that this client does not interpret. They are kept as canonical JSON and written
/// back verbatim on the next save, so an older client never strips another client's or the engine's options.
public struct ChiefOfStaffPreservedFields: Sendable, Equatable {
    public let canonicalJSON: Data

    public static let none = ChiefOfStaffPreservedFields(object: [:])

    public init(object: [String: Any]) {
        canonicalJSON = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    public init(from raw: [String: Any], excluding known: Set<String>) {
        self.init(object: raw.filter { !known.contains($0.key) })
    }

    public var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: canonicalJSON)) as? [String: Any] ?? [:]
    }

    public var isEmpty: Bool { object.isEmpty }

    /// Unknown keys under `o`; keys this client writes always win.
    func merged(under o: [String: Any]) -> [String: Any] {
        o.merging(object) { known, _ in known }
    }
}

public struct ChiefOfStaffRuntimeBinding: Sendable, Equatable {
    public static let forbiddenKeys: Set<String> = [
        "token", "secret", "key", "nsec", "authorization", "topics", "evidence", "cohort_id", "cohort_channel_id",
    ]
    public static let knownKeys: Set<String> = [
        "autopilot_origin", "reconcile_pipeline_id", "ontology_pipeline_id", "subscription_id", "workspace_id",
        "owner_npub", "agent_npub", "cron_expression", "timezone",
    ]
    public static func isValidDefinitionId(_ id: String) -> Bool { TowerOrigin.isSafePipelineDefinitionId(id) }

    public let autopilotOrigin: String
    public let reconcilePipelineId: String
    public let ontologyPipelineId: String?
    public let subscriptionId: String
    public let workspaceId: String
    public let ownerNpub: String
    /// The exact agent this binding (and its `subscription_id`) was provisioned for. Never reused for another agent.
    public let agentNpub: String
    public let cronExpression: String?
    public let timezone: String?
    public let preserved: ChiefOfStaffPreservedFields

    public init(
        autopilotOrigin: String,
        reconcilePipelineId: String = "chief-of-staff-reconcile.v1",
        ontologyPipelineId: String? = nil,
        subscriptionId: String,
        workspaceId: String,
        ownerNpub: String,
        agentNpub: String,
        cronExpression: String? = nil,
        timezone: String? = nil,
        preserved: ChiefOfStaffPreservedFields = .none
    ) {
        self.autopilotOrigin = autopilotOrigin.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        self.reconcilePipelineId = reconcilePipelineId
        self.ontologyPipelineId = ontologyPipelineId
        self.subscriptionId = subscriptionId.lowercased()
        self.workspaceId = workspaceId.lowercased()
        self.ownerNpub = ownerNpub
        self.agentNpub = agentNpub
        self.cronExpression = cronExpression
        self.timezone = timezone
        self.preserved = preserved
    }

    public func toJSONObject() -> [String: Any] {
        var o: [String: Any] = [
            "autopilot_origin": autopilotOrigin,
            "reconcile_pipeline_id": reconcilePipelineId,
            "subscription_id": subscriptionId,
            "workspace_id": workspaceId,
            "owner_npub": ownerNpub,
            "agent_npub": agentNpub,
        ]
        if let ontologyPipelineId { o["ontology_pipeline_id"] = ontologyPipelineId }
        if let cronExpression { o["cron_expression"] = cronExpression }
        if let timezone { o["timezone"] = timezone }
        return preserved.merged(under: o)
    }

    public static func parse(
        _ rb: [String: Any],
        workspaceId: String,
        ownerNpub: String,
        assignedNpub: String?
    ) throws -> ChiefOfStaffRuntimeBinding {
        for forbidden in forbiddenKeys {
            if rb[forbidden] != nil {
                throw ChiefOfStaffError.invalid("runtime_binding must not contain private or secret field: \(forbidden)")
            }
        }
        guard let rawUrl = rb["autopilot_origin"] as? String,
              let url = URL(string: rawUrl),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { throw ChiefOfStaffError.invalid("runtime_binding.autopilot_origin must be a clean https:// origin with no path, query, fragment, or userinfo.") }

        guard let reconcileId = rb["reconcile_pipeline_id"] as? String, isValidDefinitionId(reconcileId)
        else { throw ChiefOfStaffError.invalid("Invalid runtime_binding.reconcile_pipeline_id.") }

        var ontologyId: String? = nil
        if let rawOnt = rb["ontology_pipeline_id"], !(rawOnt is NSNull) {
            guard let s = rawOnt as? String, isValidDefinitionId(s) else {
                throw ChiefOfStaffError.invalid("Invalid runtime_binding.ontology_pipeline_id.")
            }
            ontologyId = s
        }

        guard let subId = lowerUUID(rb["subscription_id"] as? String) else {
            throw ChiefOfStaffError.invalid("Invalid runtime_binding.subscription_id (UUID required).")
        }
        guard lowerUUID(rb["workspace_id"] as? String) == workspaceId.lowercased() else {
            throw ChiefOfStaffError.boundaryMismatch("runtime_binding.workspace_id mismatch.")
        }
        guard rb["owner_npub"] as? String == ownerNpub else {
            throw ChiefOfStaffError.boundaryMismatch("runtime_binding.owner_npub mismatch.")
        }
        guard let agentNpub = rb["agent_npub"] as? String, NostrKeys.isValidNpub(agentNpub) else {
            throw ChiefOfStaffError.invalid("Invalid runtime_binding.agent_npub (required).")
        }
        guard agentNpub == assignedNpub else {
            throw ChiefOfStaffError.boundaryMismatch("runtime_binding.agent_npub does not match assigned_npub.")
        }
        func optionalString(_ key: String) throws -> String? {
            guard let raw = rb[key], !(raw is NSNull) else { return nil }
            guard let s = raw as? String, !s.isEmpty else { throw ChiefOfStaffError.invalid("Invalid runtime_binding.\(key).") }
            return s
        }

        return ChiefOfStaffRuntimeBinding(
            autopilotOrigin: rawUrl,
            reconcilePipelineId: reconcileId,
            ontologyPipelineId: ontologyId,
            subscriptionId: subId,
            workspaceId: workspaceId.lowercased(),
            ownerNpub: ownerNpub,
            agentNpub: agentNpub,
            cronExpression: try optionalString("cron_expression"),
            timezone: try optionalString("timezone"),
            preserved: ChiefOfStaffPreservedFields(from: rb, excluding: knownKeys)
        )
    }
}

public struct ChiefOfStaffAssignment: Sendable, Equatable {
    public static let knownKeys: Set<String> = [
        "schema", "schema_version", "workspace_id", "workspace_owner_npub", "app_npub", "assignment_revision",
        "assigned_actor_id", "assigned_npub", "assigned_display_name", "previous_assigned_npub", "runtime_binding",
        "updated_by_actor_id", "updated_by_npub", "updated_at",
    ]

    public let workspaceId: String
    public let workspaceOwnerNpub: String
    public let appNpub: String
    public let assignmentRevision: Int
    public let assignedActorId: String?
    public let assignedNpub: String?
    public let assignedDisplayName: String?
    public let previousAssignedNpub: String?
    public let runtimeBinding: ChiefOfStaffRuntimeBinding?
    public let updatedByActorId: String
    public let updatedByNpub: String
    public let updatedAt: String
    public let preserved: ChiefOfStaffPreservedFields

    public var isAssigned: Bool { assignedNpub != nil && assignedActorId != nil }
    public var assignmentEpoch: Int { max(1, assignmentRevision) }

    public init(
        workspaceId: String,
        workspaceOwnerNpub: String,
        appNpub: String,
        assignmentRevision: Int,
        assignedActorId: String?,
        assignedNpub: String?,
        assignedDisplayName: String?,
        previousAssignedNpub: String?,
        runtimeBinding: ChiefOfStaffRuntimeBinding? = nil,
        updatedByActorId: String,
        updatedByNpub: String,
        updatedAt: String,
        preserved: ChiefOfStaffPreservedFields = .none
    ) {
        self.workspaceId = workspaceId.lowercased()
        self.workspaceOwnerNpub = workspaceOwnerNpub
        self.appNpub = appNpub
        self.assignmentRevision = assignmentRevision
        self.assignedActorId = assignedActorId?.lowercased()
        self.assignedNpub = assignedNpub
        self.assignedDisplayName = assignedDisplayName
        self.previousAssignedNpub = previousAssignedNpub
        self.runtimeBinding = runtimeBinding
        self.updatedByActorId = updatedByActorId.lowercased()
        self.updatedByNpub = updatedByNpub
        self.updatedAt = updatedAt
        self.preserved = preserved
    }

    public func toJSONObject() -> [String: Any] {
        var o: [String: Any] = [
            "schema": ChiefOfStaffContract.schemaAssignment,
            "schema_version": 1,
            "workspace_id": workspaceId,
            "workspace_owner_npub": workspaceOwnerNpub,
            "app_npub": appNpub,
            "assignment_revision": assignmentRevision,
            "assigned_actor_id": assignedActorId ?? NSNull(),
            "assigned_npub": assignedNpub ?? NSNull(),
            "assigned_display_name": assignedDisplayName ?? NSNull(),
            "previous_assigned_npub": previousAssignedNpub ?? NSNull(),
            "updated_by_actor_id": updatedByActorId,
            "updated_by_npub": updatedByNpub,
            "updated_at": updatedAt,
        ]
        if let runtimeBinding {
            o["runtime_binding"] = runtimeBinding.toJSONObject()
        }
        return preserved.merged(under: o)
    }

    public static func empty(
        workspaceId: String,
        ownerNpub: String,
        appNpub: String,
        actorId: String,
        actorNpub: String,
        now: Date = Date()
    ) -> ChiefOfStaffAssignment {
        ChiefOfStaffAssignment(
            workspaceId: workspaceId.lowercased(),
            workspaceOwnerNpub: ownerNpub,
            appNpub: appNpub,
            assignmentRevision: 0,
            assignedActorId: nil,
            assignedNpub: nil,
            assignedDisplayName: nil,
            previousAssignedNpub: nil,
            updatedByActorId: actorId.lowercased(),
            updatedByNpub: actorNpub,
            updatedAt: ChiefOfStaffContract.formatTimestamp(now)
        )
    }

    public static func parse(_ doc: [String: Any], expected: ExpectedWorkspaceContext? = nil) throws -> ChiefOfStaffAssignment {
        guard doc["schema"] as? String == ChiefOfStaffContract.schemaAssignment,
              flexibleInt(doc["schema_version"]) == 1
        else { throw ChiefOfStaffError.invalid("Invalid Chief of Staff assignment schema.") }

        for forbidden in ChiefOfStaffContract.forbiddenAssignmentFields {
            if doc[forbidden] != nil {
                throw ChiefOfStaffError.invalid("Shared assignment must not contain private field: \(forbidden)")
            }
        }

        guard let workspaceId = lowerUUID(doc["workspace_id"] as? String) else {
            throw ChiefOfStaffError.invalid("Invalid assignment workspace_id.")
        }
        guard let ownerNpub = doc["workspace_owner_npub"] as? String, NostrKeys.isValidNpub(ownerNpub) else {
            throw ChiefOfStaffError.invalid("Invalid assignment workspace_owner_npub.")
        }
        guard let appNpub = doc["app_npub"] as? String, NostrKeys.isValidNpub(appNpub) else {
            throw ChiefOfStaffError.invalid("Invalid assignment app_npub.")
        }
        guard let revision = flexibleInt(doc["assignment_revision"]), revision >= 0 else {
            throw ChiefOfStaffError.invalid("Invalid assignment_revision.")
        }
        guard let updatedByActorId = lowerUUID(doc["updated_by_actor_id"] as? String) else {
            throw ChiefOfStaffError.invalid("Invalid updated_by_actor_id.")
        }
        guard let updatedByNpub = doc["updated_by_npub"] as? String, NostrKeys.isValidNpub(updatedByNpub) else {
            throw ChiefOfStaffError.invalid("Invalid updated_by_npub.")
        }
        guard let updatedAt = doc["updated_at"] as? String, ChiefOfStaffContract.isIsoTimestamp(updatedAt) else {
            throw ChiefOfStaffError.invalid("Invalid assignment updated_at.")
        }

        let rawAssignedActor = doc["assigned_actor_id"]
        let rawAssignedNpub = doc["assigned_npub"]
        let hasActor = rawAssignedActor != nil && !(rawAssignedActor is NSNull)
        let hasNpub = rawAssignedNpub != nil && !(rawAssignedNpub is NSNull)
        let assignedActorId: String?
        let assignedNpub: String?
        if hasActor || hasNpub {
            guard let aid = lowerUUID(rawAssignedActor as? String),
                  let anpub = rawAssignedNpub as? String, NostrKeys.isValidNpub(anpub)
            else { throw ChiefOfStaffError.invalid("Assigned Chief of Staff requires both valid actor_id and npub.") }
            assignedActorId = aid
            assignedNpub = anpub
        } else {
            assignedActorId = nil
            assignedNpub = nil
        }

        var prevNpub: String? = nil
        if let rawPrev = doc["previous_assigned_npub"], !(rawPrev is NSNull) {
            guard let p = rawPrev as? String, NostrKeys.isValidNpub(p) else {
                throw ChiefOfStaffError.invalid("Invalid previous_assigned_npub.")
            }
            prevNpub = p
        }

        var runtimeBinding: ChiefOfStaffRuntimeBinding? = nil
        if let rawBinding = doc["runtime_binding"], !(rawBinding is NSNull) {
            guard let rbDict = rawBinding as? [String: Any] else {
                throw ChiefOfStaffError.invalid("Invalid runtime_binding: must be an object or null.")
            }
            runtimeBinding = try ChiefOfStaffRuntimeBinding.parse(rbDict, workspaceId: workspaceId, ownerNpub: ownerNpub, assignedNpub: assignedNpub)
        }

        if let expected {
            guard workspaceId == expected.workspaceId else { throw ChiefOfStaffError.boundaryMismatch("Assignment workspace_id mismatch.") }
            guard ownerNpub == expected.ownerNpub else { throw ChiefOfStaffError.boundaryMismatch("Assignment workspace_owner_npub mismatch.") }
            guard appNpub == expected.appNpub else { throw ChiefOfStaffError.boundaryMismatch("Assignment app_npub mismatch.") }
        }

        return ChiefOfStaffAssignment(
            workspaceId: workspaceId,
            workspaceOwnerNpub: ownerNpub,
            appNpub: appNpub,
            assignmentRevision: revision,
            assignedActorId: assignedActorId,
            assignedNpub: assignedNpub,
            assignedDisplayName: doc["assigned_display_name"] as? String,
            previousAssignedNpub: prevNpub,
            runtimeBinding: runtimeBinding,
            updatedByActorId: updatedByActorId,
            updatedByNpub: updatedByNpub,
            updatedAt: updatedAt,
            preserved: ChiefOfStaffPreservedFields(from: doc, excluding: knownKeys)
        )
    }
}

public struct ChiefOfStaffCoverage: Sendable, Equatable {
    public let supportedTypes: [String]
    public let scannedCounts: [String: Int]
    public let unsupportedInputs: [String]

    public init(
        supportedTypes: [String] = ["message", "thread", "audio_note", "task", "doc", "file"],
        scannedCounts: [String: Int] = [:],
        unsupportedInputs: [String] = []
    ) {
        self.supportedTypes = supportedTypes
        self.scannedCounts = scannedCounts
        self.unsupportedInputs = unsupportedInputs
    }

    public static func parse(_ raw: [String: Any]?) -> ChiefOfStaffCoverage {
        guard let raw else { return ChiefOfStaffCoverage() }
        let supported = (raw["supported_types"] as? [Any])?.compactMap { $0 as? String }
            ?? ["message", "thread", "audio_note", "task", "doc", "file"]
        var counts: [String: Int] = [:]
        if let map = raw["scanned_counts"] as? [String: Any] {
            for (k, v) in map { counts[k] = flexibleInt(v) ?? 0 }
        }
        let unsupported: [String] = (raw["unsupported_inputs"] as? [Any])?.compactMap { item in
            if let s = item as? String { return s }
            if let o = item as? [String: Any] {
                return (o["reason"] as? String) ?? (o["kind"] as? String) ?? (o["name"] as? String)
            }
            return nil
        } ?? []
        return ChiefOfStaffCoverage(supportedTypes: supported, scannedCounts: counts, unsupportedInputs: unsupported)
    }
}

public struct ChiefOfStaffJobStatus: Sendable, Equatable {
    public let workspaceId: String
    public let workspaceOwnerNpub: String
    public let appNpub: String
    public let cohortId: String?
    public let assignmentEpoch: Int
    public let boundAgentNpub: String
    public let assignmentRevisionSeen: Int
    public let scheduleState: String
    public let autopilotJobId: String?
    public let pipelineDefinitionId: String?
    public let cronExpression: String?
    public let timezone: String?
    public let lastRunAt: String?
    public let lastSuccessAt: String?
    public let lastError: String?
    public let topicCount: Int
    public let evidenceCount: Int
    public let cursorSummary: String?
    public let coverage: ChiefOfStaffCoverage
    public let updatedAt: String

    public static func parse(_ doc: [String: Any], expected: ExpectedWorkspaceContext? = nil) throws -> ChiefOfStaffJobStatus {
        guard doc["schema"] as? String == ChiefOfStaffContract.schemaJobStatus,
              flexibleInt(doc["schema_version"]) == 1
        else { throw ChiefOfStaffError.invalid("Invalid Chief of Staff job status schema.") }

        guard let workspaceId = lowerUUID(doc["workspace_id"] as? String) else {
            throw ChiefOfStaffError.invalid("Invalid job status workspace_id.")
        }
        guard let ownerNpub = doc["workspace_owner_npub"] as? String, NostrKeys.isValidNpub(ownerNpub) else {
            throw ChiefOfStaffError.invalid("Invalid job status owner.")
        }
        guard let appNpub = doc["app_npub"] as? String, NostrKeys.isValidNpub(appNpub) else {
            throw ChiefOfStaffError.invalid("Invalid job status app.")
        }
        guard let agentNpub = doc["bound_agent_npub"] as? String, NostrKeys.isValidNpub(agentNpub) else {
            throw ChiefOfStaffError.invalid("Invalid job status bound_agent_npub.")
        }
        guard let state = doc["schedule_state"] as? String, ChiefOfStaffContract.scheduleStates.contains(state) else {
            throw ChiefOfStaffError.invalid("Invalid job status schedule_state.")
        }
        guard let revSeen = flexibleInt(doc["assignment_revision_seen"]), revSeen >= 0 else {
            throw ChiefOfStaffError.invalid("Invalid job status assignment_revision_seen.")
        }
        guard let updatedAt = doc["updated_at"] as? String, ChiefOfStaffContract.isIsoTimestamp(updatedAt) else {
            throw ChiefOfStaffError.invalid("Invalid job status updated_at.")
        }
        if let expected {
            guard workspaceId == expected.workspaceId else { throw ChiefOfStaffError.boundaryMismatch("Job status workspace_id mismatch.") }
            guard ownerNpub == expected.ownerNpub else { throw ChiefOfStaffError.boundaryMismatch("Job status owner mismatch.") }
            guard appNpub == expected.appNpub else { throw ChiefOfStaffError.boundaryMismatch("Job status app mismatch.") }
        }
        return ChiefOfStaffJobStatus(
            workspaceId: workspaceId,
            workspaceOwnerNpub: ownerNpub,
            appNpub: appNpub,
            cohortId: doc["cohort_id"] as? String,
            assignmentEpoch: flexibleInt(doc["assignment_epoch"]) ?? 1,
            boundAgentNpub: agentNpub,
            assignmentRevisionSeen: revSeen,
            scheduleState: state,
            autopilotJobId: doc["autopilot_job_id"] as? String,
            pipelineDefinitionId: doc["pipeline_definition_id"] as? String,
            cronExpression: doc["cron_expression"] as? String,
            timezone: doc["timezone"] as? String,
            lastRunAt: doc["last_run_at"] as? String,
            lastSuccessAt: doc["last_success_at"] as? String,
            lastError: doc["last_error"] as? String,
            topicCount: flexibleInt(doc["topic_count"]) ?? 0,
            evidenceCount: flexibleInt(doc["evidence_count"]) ?? 0,
            cursorSummary: doc["cursor_summary"] as? String,
            coverage: ChiefOfStaffCoverage.parse(doc["coverage"] as? [String: Any]),
            updatedAt: updatedAt
        )
    }
}

public struct ChiefOfStaffTopic: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let aliases: [String]
    public let description: String
    public let archived: Bool
    public let sourceOrigin: String
    public let updatedAt: String

    public init(
        id: String,
        name: String,
        kind: String,
        aliases: [String] = [],
        description: String = "",
        archived: Bool = false,
        sourceOrigin: String = "discovered",
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.aliases = aliases
        self.description = description
        self.archived = archived
        self.sourceOrigin = sourceOrigin
        self.updatedAt = updatedAt
    }
}

public struct ChiefOfStaffEvidence: Sendable, Equatable, Identifiable {
    public let id: String
    public let topicId: String
    public let sourceType: String
    public let recordId: String
    public let channelId: String?
    public let threadId: String?
    public let sourceRevision: String?
    public let sourceTitle: String
    public let explanation: String
    public let score: Double
    public let status: String
    public let pinned: Bool
    public let updatedAt: String

    public init(
        id: String,
        topicId: String,
        sourceType: String,
        recordId: String,
        channelId: String? = nil,
        threadId: String? = nil,
        sourceRevision: String? = nil,
        sourceTitle: String = "",
        explanation: String = "",
        score: Double = 0.5,
        status: String = "active",
        pinned: Bool = false,
        updatedAt: String = ""
    ) {
        self.id = id
        self.topicId = topicId
        self.sourceType = sourceType
        self.recordId = recordId.lowercased()
        self.channelId = channelId?.lowercased()
        self.threadId = threadId?.lowercased()
        self.sourceRevision = sourceRevision
        self.sourceTitle = sourceTitle
        self.explanation = explanation
        self.score = score
        self.status = status
        self.pinned = pinned
        self.updatedAt = updatedAt
    }
}

public struct ChiefOfStaffOntology: Sendable, Equatable {
    public let workspaceId: String
    public let workspaceOwnerNpub: String
    public let appNpub: String
    public let cohortId: String
    public let assignmentEpoch: Int
    public let agentNpub: String
    public let snapshotRevision: Int
    public let assignmentRevisionSeen: Int
    public let generatedAt: String
    public let coverage: ChiefOfStaffCoverage
    public let topics: [ChiefOfStaffTopic]
    public let evidence: [ChiefOfStaffEvidence]

    public static func parse(_ doc: [String: Any], expected: ExpectedWorkspaceContext? = nil) throws -> ChiefOfStaffOntology {
        guard doc["schema"] as? String == ChiefOfStaffContract.schemaOntology,
              flexibleInt(doc["schema_version"]) == 1
        else { throw ChiefOfStaffError.invalid("Invalid Chief of Staff ontology schema.") }

        guard let workspaceId = lowerUUID(doc["workspace_id"] as? String) else {
            throw ChiefOfStaffError.invalid("Invalid ontology workspace_id.")
        }
        guard let ownerNpub = doc["workspace_owner_npub"] as? String, NostrKeys.isValidNpub(ownerNpub) else {
            throw ChiefOfStaffError.invalid("Invalid ontology owner.")
        }
        guard let appNpub = doc["app_npub"] as? String, NostrKeys.isValidNpub(appNpub) else {
            throw ChiefOfStaffError.invalid("Invalid ontology app.")
        }
        guard let agentNpub = doc["agent_npub"] as? String, NostrKeys.isValidNpub(agentNpub) else {
            throw ChiefOfStaffError.invalid("Invalid ontology agent_npub.")
        }
        guard let cohortId = doc["cohort_id"] as? String, !cohortId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChiefOfStaffError.invalid("Invalid ontology cohort_id.")
        }
        guard let snapshotRev = flexibleInt(doc["snapshot_revision"]), snapshotRev >= 0 else {
            throw ChiefOfStaffError.invalid("Invalid ontology snapshot_revision.")
        }
        guard let assignmentRevSeen = flexibleInt(doc["assignment_revision_seen"]), assignmentRevSeen >= 0 else {
            throw ChiefOfStaffError.invalid("Invalid ontology assignment_revision_seen.")
        }
        guard let generatedAt = doc["generated_at"] as? String, ChiefOfStaffContract.isIsoTimestamp(generatedAt) else {
            throw ChiefOfStaffError.invalid("Invalid ontology generated_at.")
        }
        guard let rawTopics = doc["topics"] as? [[String: Any]],
              let rawEvidence = doc["evidence"] as? [[String: Any]],
              let rawCoverage = doc["coverage"] as? [String: Any]
        else { throw ChiefOfStaffError.invalid("Invalid ontology topics, evidence, or coverage.") }

        let topics: [ChiefOfStaffTopic] = try rawTopics.map { o in
            guard let id = o["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = o["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let kind = o["kind"] as? String,
                  let aliasesRaw = o["aliases"] as? [Any]
            else { throw ChiefOfStaffError.invalid("Invalid topic entry in ontology snapshot.") }
            let aliases = aliasesRaw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return ChiefOfStaffTopic(
                id: id,
                name: name,
                kind: kind,
                aliases: aliases,
                description: o["description"] as? String ?? "",
                archived: o["archived"] as? Bool ?? false,
                sourceOrigin: o["source_origin"] as? String ?? "discovered",
                updatedAt: o["updated_at"] as? String ?? generatedAt
            )
        }

        let evidence: [ChiefOfStaffEvidence] = try rawEvidence.map { o in
            guard let id = o["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let topicId = o["topic_id"] as? String, !topicId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sourceType = o["source_type"] as? String, ChiefOfStaffContract.sourceTypes.contains(sourceType),
                  let recordId = lowerUUID(o["record_id"] as? String),
                  let status = o["status"] as? String, ChiefOfStaffContract.evidenceStatuses.contains(status),
                  let explanation = o["explanation"] as? String
            else { throw ChiefOfStaffError.invalid("Invalid evidence entry in ontology snapshot.") }
            let score = (o["score"] as? Double) ?? (o["score"] as? NSNumber)?.doubleValue ?? 0.5
            let sourceRev: String?
            if let s = o["source_revision"] as? String { sourceRev = s }
            else if let n = o["source_revision"] as? NSNumber { sourceRev = n.stringValue }
            else { sourceRev = nil }
            return ChiefOfStaffEvidence(
                id: id,
                topicId: topicId,
                sourceType: sourceType,
                recordId: recordId,
                channelId: lowerUUID(o["channel_id"] as? String),
                threadId: lowerUUID(o["thread_id"] as? String),
                sourceRevision: sourceRev,
                sourceTitle: o["source_title"] as? String ?? "",
                explanation: explanation,
                score: score,
                status: status,
                pinned: o["pinned"] as? Bool ?? false,
                updatedAt: o["updated_at"] as? String ?? generatedAt
            )
        }

        if let expected {
            guard workspaceId == expected.workspaceId else { throw ChiefOfStaffError.boundaryMismatch("Ontology workspace_id mismatch.") }
            guard ownerNpub == expected.ownerNpub else { throw ChiefOfStaffError.boundaryMismatch("Ontology owner mismatch.") }
            guard appNpub == expected.appNpub else { throw ChiefOfStaffError.boundaryMismatch("Ontology app mismatch.") }
        }

        return ChiefOfStaffOntology(
            workspaceId: workspaceId,
            workspaceOwnerNpub: ownerNpub,
            appNpub: appNpub,
            cohortId: cohortId,
            assignmentEpoch: flexibleInt(doc["assignment_epoch"]) ?? 1,
            agentNpub: agentNpub,
            snapshotRevision: snapshotRev,
            assignmentRevisionSeen: assignmentRevSeen,
            generatedAt: generatedAt,
            coverage: ChiefOfStaffCoverage.parse(rawCoverage),
            topics: topics,
            evidence: evidence
        )
    }
}

public struct ChiefOfStaffCorrection: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let createdByNpub: String
    public let createdAt: String
    public let topicId: String?
    public let name: String?
    public let description: String?
    public let aliases: [String]?
    public let topicKind: String?
    public let sourceTopicId: String?
    public let targetTopicId: String?
    public let sourceType: String?
    public let recordId: String?
    public let archived: Bool?
    public let reason: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: String,
        createdByNpub: String,
        createdAt: String = ChiefOfStaffContract.formatTimestamp(),
        topicId: String? = nil,
        name: String? = nil,
        description: String? = nil,
        aliases: [String]? = nil,
        topicKind: String? = nil,
        sourceTopicId: String? = nil,
        targetTopicId: String? = nil,
        sourceType: String? = nil,
        recordId: String? = nil,
        archived: Bool? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdByNpub = createdByNpub
        self.createdAt = createdAt
        self.topicId = topicId
        self.name = name
        self.description = description
        self.aliases = aliases
        self.topicKind = topicKind
        self.sourceTopicId = sourceTopicId
        self.targetTopicId = targetTopicId
        self.sourceType = sourceType
        self.recordId = recordId?.lowercased()
        self.archived = archived
        self.reason = reason
    }

    public func toJSONObject() -> [String: Any] {
        var o: [String: Any] = [
            "id": id,
            "kind": kind,
            "created_by_npub": createdByNpub,
            "created_at": createdAt,
        ]
        if let topicId { o["topic_id"] = topicId }
        if let name { o["name"] = name }
        if let description { o["description"] = description }
        if let aliases { o["aliases"] = aliases }
        if let topicKind { o["topic_kind"] = topicKind }
        if let sourceTopicId { o["source_topic_id"] = sourceTopicId }
        if let targetTopicId { o["target_topic_id"] = targetTopicId }
        if let sourceType { o["source_type"] = sourceType }
        if let recordId { o["record_id"] = recordId }
        if let archived { o["archived"] = archived }
        if let reason { o["reason"] = reason }
        return o
    }

    public static func parse(_ o: [String: Any]) throws -> ChiefOfStaffCorrection {
        guard let id = o["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChiefOfStaffError.invalid("Invalid correction id.")
        }
        guard let kind = o["kind"] as? String, ChiefOfStaffContract.correctionKinds.contains(kind) else {
            throw ChiefOfStaffError.invalid("Invalid correction kind.")
        }
        guard let createdBy = o["created_by_npub"] as? String, NostrKeys.isValidNpub(createdBy) else {
            throw ChiefOfStaffError.invalid("Invalid correction created_by_npub.")
        }
        guard let createdAt = o["created_at"] as? String, ChiefOfStaffContract.isIsoTimestamp(createdAt) else {
            throw ChiefOfStaffError.invalid("Invalid correction created_at.")
        }
        let aliases = (o["aliases"] as? [Any])?.compactMap { $0 as? String }
        return ChiefOfStaffCorrection(
            id: id,
            kind: kind,
            createdByNpub: createdBy,
            createdAt: createdAt,
            topicId: o["topic_id"] as? String,
            name: o["name"] as? String,
            description: o["description"] as? String,
            aliases: aliases,
            topicKind: o["topic_kind"] as? String,
            sourceTopicId: o["source_topic_id"] as? String,
            targetTopicId: o["target_topic_id"] as? String,
            sourceType: o["source_type"] as? String,
            recordId: lowerUUID(o["record_id"] as? String),
            archived: o["archived"] as? Bool,
            reason: o["reason"] as? String
        )
    }
}

public struct ChiefOfStaffCorrections: Sendable, Equatable {
    public let workspaceId: String
    public let workspaceOwnerNpub: String
    public let appNpub: String
    public let cohortId: String
    public let assignmentEpoch: Int
    public let corrections: [ChiefOfStaffCorrection]
    public let updatedAt: String

    public init(
        workspaceId: String,
        workspaceOwnerNpub: String,
        appNpub: String,
        cohortId: String,
        assignmentEpoch: Int,
        corrections: [ChiefOfStaffCorrection],
        updatedAt: String
    ) {
        self.workspaceId = workspaceId.lowercased()
        self.workspaceOwnerNpub = workspaceOwnerNpub
        self.appNpub = appNpub
        self.cohortId = cohortId
        self.assignmentEpoch = assignmentEpoch
        self.corrections = corrections
        self.updatedAt = updatedAt
    }

    public func toJSONObject() -> [String: Any] {
        [
            "schema": ChiefOfStaffContract.schemaCorrections,
            "schema_version": 1,
            "workspace_id": workspaceId,
            "workspace_owner_npub": workspaceOwnerNpub,
            "app_npub": appNpub,
            "cohort_id": cohortId,
            "assignment_epoch": assignmentEpoch,
            "corrections": corrections.map { $0.toJSONObject() },
            "updated_at": updatedAt,
        ]
    }

    public static func parse(_ doc: [String: Any], expected: ExpectedWorkspaceContext? = nil) throws -> ChiefOfStaffCorrections {
        guard doc["schema"] as? String == ChiefOfStaffContract.schemaCorrections,
              flexibleInt(doc["schema_version"]) == 1
        else { throw ChiefOfStaffError.invalid("Invalid Chief of Staff corrections schema.") }

        guard let workspaceId = lowerUUID(doc["workspace_id"] as? String) else {
            throw ChiefOfStaffError.invalid("Invalid corrections workspace_id.")
        }
        guard let ownerNpub = doc["workspace_owner_npub"] as? String, NostrKeys.isValidNpub(ownerNpub) else {
            throw ChiefOfStaffError.invalid("Invalid corrections owner.")
        }
        guard let appNpub = doc["app_npub"] as? String, NostrKeys.isValidNpub(appNpub) else {
            throw ChiefOfStaffError.invalid("Invalid corrections app.")
        }
        guard let cohortId = doc["cohort_id"] as? String, !cohortId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChiefOfStaffError.invalid("Invalid corrections cohort_id.")
        }
        guard let updatedAt = doc["updated_at"] as? String, ChiefOfStaffContract.isIsoTimestamp(updatedAt) else {
            throw ChiefOfStaffError.invalid("Invalid corrections updated_at.")
        }
        guard let rawList = doc["corrections"] as? [[String: Any]] else {
            throw ChiefOfStaffError.invalid("Invalid corrections list.")
        }
        let list = try rawList.map(ChiefOfStaffCorrection.parse)
        if let expected {
            guard workspaceId == expected.workspaceId else { throw ChiefOfStaffError.boundaryMismatch("Corrections workspace_id mismatch.") }
            guard ownerNpub == expected.ownerNpub else { throw ChiefOfStaffError.boundaryMismatch("Corrections owner mismatch.") }
            guard appNpub == expected.appNpub else { throw ChiefOfStaffError.boundaryMismatch("Corrections app mismatch.") }
        }
        return ChiefOfStaffCorrections(
            workspaceId: workspaceId,
            workspaceOwnerNpub: ownerNpub,
            appNpub: appNpub,
            cohortId: cohortId,
            assignmentEpoch: flexibleInt(doc["assignment_epoch"]) ?? 1,
            corrections: list,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Explicit-permission ACL & authoritative provenance verification

public enum ChiefOfStaffAcl {
    public struct MemberRoleEntry: Sendable, Equatable {
        public let actorId: String
        public let npub: String
        public let role: String?
        public let permissions: Set<String>
        /// Server-derived authoritative boolean from `GET /members` (`member.authority.can_manage_workspace`).
        /// Missing or false fails closed for delegated managers; workspace owner still uses verified `ownerNpub`.
        public let canManageWorkspace: Bool

        public init(
            actorId: String,
            npub: String,
            role: String?,
            permissions: Set<String> = [],
            canManageWorkspace: Bool = false
        ) {
            self.actorId = actorId.lowercased()
            self.npub = npub
            self.role = role
            self.permissions = permissions
            self.canManageWorkspace = canManageWorkspace
        }

        /// `member.authority.can_manage_workspace` from an authoritative `/members` row: only a JSON `true` counts.
        /// Missing (older server), `false`, strings and numbers all fail closed.
        public static func strictCanManageWorkspace(_ member: [String: Any]) -> Bool {
            guard let num = (member["authority"] as? [String: Any])?["can_manage_workspace"] as? NSNumber,
                  CFGetTypeID(num) == CFBooleanGetTypeID()
            else { return false }
            return num.boolValue
        }

        /// Never inferred from membership role or display labels: only the verified workspace owner, the
        /// server-computed authority boolean, or a server-reported effective `workspace.manage` permission.
        public func isWorkspaceManager(ownerNpub: String) -> Bool {
            npub == ownerNpub
                || canManageWorkspace
                || permissions.contains("workspace.manage")
        }
    }

    public struct GroupEntry: Sendable, Equatable {
        public let id: String
        public let kind: String?
        public let name: String?
        public let effectiveMemberIds: Set<String>?

        public init(id: String, kind: String?, name: String?, effectiveMemberIds: Set<String>? = nil) {
            self.id = id.lowercased()
            self.kind = kind
            self.name = name
            self.effectiveMemberIds = effectiveMemberIds.map { Set($0.map { $0.lowercased() }) }
        }
    }

    private static func grantPrincipalId(_ g: [String: Any]) -> String? {
        let p = g["principal"] as? [String: Any]
        return lowerUUID((p?["actor_id"] ?? p?["group_id"] ?? p?["id"] ?? g["principal_id"]) as? String)
    }

    private static func isActorGrant(_ g: [String: Any]) -> Bool {
        let p = g["principal"] as? [String: Any]
        let pType = g["principal_type"] as? String
        let stored = g["stored_principal_type"] as? String
        let nestedType = p?["type"] as? String
        return (pType == "actor" || (pType == "person" && stored == "actor"))
            && (nestedType == nil || nestedType == "actor" || nestedType == "person")
            && (stored == nil || stored == "actor")
    }

    private static func isGroupGrant(_ g: [String: Any]) -> Bool {
        g["principal_type"] as? String == "group"
    }

    private static func permissionsOf(_ g: [String: Any]) -> Set<String>? {
        guard let arr = g["permissions"] as? [Any] else { return nil }
        var perms = Set<String>()
        for el in arr {
            guard let s = el as? String else { return nil }
            perms.insert(s)
        }
        return perms
    }

    /// Verifies authoritative NStack server provenance on the assignment channel, file, and current version
    /// against workspace managers from `/members`, without requiring admin-only `/groups` or `/grants`.
    /// Self-asserted payload actor fields are never trusted on their own.
    public static func verifyManagerProvenance(
        channelRaw: Data,
        fileRaw: Data,
        members: [MemberRoleEntry],
        ownerNpub: String,
        payloadUpdatedByActorId: String,
        payloadUpdatedByNpub: String,
        additionalVerifiedManagers: [String: String] = [:]
    ) throws {
        let channelObj = (try? JSONSerialization.jsonObject(with: channelRaw) as? [String: Any]) ?? [:]
        let fileObj = (try? JSONSerialization.jsonObject(with: fileRaw) as? [String: Any]) ?? [:]

        var managerById: [String: String] = [:]
        for m in members where m.isWorkspaceManager(ownerNpub: ownerNpub) {
            managerById[m.actorId.lowercased()] = m.npub
        }
        for (id, npub) in additionalVerifiedManagers {
            managerById[id.lowercased()] = npub
        }
        guard !managerById.isEmpty else {
            throw ChiefOfStaffError.integrity("No authoritative workspace managers found to verify Chief of Staff provenance.")
        }

        func verifyActor(_ label: String, actorId: String?, actorNpub: String?) throws -> (String, String) {
            guard let id = lowerUUID(actorId) else {
                throw ChiefOfStaffError.integrity("Chief of Staff \(label) is missing authoritative server actor_id.")
            }
            guard let managerNpub = managerById[id] else {
                throw ChiefOfStaffError.integrity("Chief of Staff \(label) was not authored by a verified workspace manager.")
            }
            if let actorNpub, actorNpub != managerNpub {
                throw ChiefOfStaffError.integrity("Chief of Staff \(label) actor npub does not match workspace manager identity.")
            }
            return (id, managerNpub)
        }

        // 1. Channel creator: live Tower /scopes/:id/channels omits created_by_actor_id; enforce whenever present.
        if let channelCreatorId = channelObj["created_by_actor_id"] as? String {
            _ = try verifyActor("assignment channel", actorId: channelCreatorId, actorNpub: channelObj["created_by_actor_npub"] as? String)
        }

        // 2. File creator MUST be a verified workspace manager.
        _ = try verifyActor("assignment file", actorId: fileObj["created_by_actor_id"] as? String, actorNpub: fileObj["created_by_actor_npub"] as? String)

        // 3. Current version creator (or file updated_by_actor_id when current_version is omitted) MUST be a verified
        // workspace manager and match payload.updated_by_*.
        let currentVersion = fileObj["current_version"] as? [String: Any]
        let writerId = (currentVersion?["created_by_actor_id"] as? String)
            ?? (fileObj["updated_by_actor_id"] as? String)
            ?? (fileObj["created_by_actor_id"] as? String)
        let writerNpub = (currentVersion?["created_by_actor_npub"] as? String)
            ?? (fileObj["updated_by_actor_npub"] as? String)
            ?? (fileObj["created_by_actor_npub"] as? String)
        let (verifiedWriterId, verifiedWriterNpub) = try verifyActor("assignment version", actorId: writerId, actorNpub: writerNpub)

        guard payloadUpdatedByActorId.lowercased() == verifiedWriterId, payloadUpdatedByNpub == verifiedWriterNpub else {
            throw ChiefOfStaffError.integrity("Chief of Staff assignment payload author does not match authoritative NStack version provenance.")
        }
    }

    /// Verifies the workspace Assignment channel ACL (used on manager reads/writes; never required for ordinary
    /// read-only workspace members who receive 403 on admin-only `/groups` and `/grants`).
    public static func verifyAssignmentChannelGrants(
        grants: [[String: Any]],
        members: [MemberRoleEntry],
        groups: [GroupEntry],
        ownerNpub: String,
        additionalVerifiedManagerIds: Set<String> = []
    ) throws -> (hasManagerWriter: Bool, hasWorkspaceReader: Bool) {
        var managerActorIds = Set(members.filter { $0.isWorkspaceManager(ownerNpub: ownerNpub) }.map { $0.actorId.lowercased() })
        for id in additionalVerifiedManagerIds { managerActorIds.insert(id.lowercased()) }
        let groupById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id.lowercased(), $0) })

        func isVerifiedAdminGroup(_ group: GroupEntry?) -> Bool {
            guard let group, group.kind == "system" else { return false }
            if let eff = group.effectiveMemberIds {
                return !eff.isEmpty && eff.allSatisfy { managerActorIds.contains($0) }
            }
            return group.name?.lowercased() == "admins"
        }

        func isWorkspaceGroup(_ group: GroupEntry?) -> Bool {
            guard let group, group.kind == "system", !isVerifiedAdminGroup(group) else { return false }
            return group.name?.lowercased() == "workspace"
        }

        var hasManagerWriter = false
        var hasWorkspaceReader = false
        let writePerms: Set<String> = ["file.write", "channel.manage", "channel.grants.manage"]

        for g in grants {
            guard let pid = grantPrincipalId(g) else {
                throw ChiefOfStaffError.integrity("Malformed Chief of Staff assignment grant.")
            }
            guard let perms = permissionsOf(g) else {
                throw ChiefOfStaffError.integrity("Malformed Chief of Staff grant permissions.")
            }
            let canWrite = !perms.isDisjoint(with: writePerms)
            if isGroupGrant(g) {
                let group = groupById[pid]
                if isVerifiedAdminGroup(group) {
                    if Set(["channel.read", "file.read", "file.write"]).isSubset(of: perms) {
                        hasManagerWriter = true
                    }
                } else if isWorkspaceGroup(group) {
                    if canWrite {
                        throw ChiefOfStaffError.integrity("Workspace member group must not have write permission on Chief of Staff assignment.")
                    }
                    if Set(["channel.read", "file.read"]).isSubset(of: perms) {
                        hasWorkspaceReader = true
                    }
                } else if canWrite {
                    throw ChiefOfStaffError.integrity("Non-admin group cannot hold write permission on Chief of Staff assignment.")
                }
            } else if isActorGrant(g) {
                if canWrite {
                    guard managerActorIds.contains(pid) else {
                        throw ChiefOfStaffError.integrity("Non-manager actor cannot hold write permission on Chief of Staff assignment.")
                    }
                    if Set(["channel.read", "file.read", "file.write"]).isSubset(of: perms) {
                        hasManagerWriter = true
                    }
                }
            } else {
                throw ChiefOfStaffError.integrity("Unsupported grant principal type on Chief of Staff assignment channel.")
            }
        }
        guard hasManagerWriter else {
            throw ChiefOfStaffError.integrity("Chief of Staff assignment channel has no verified manager write grant.")
        }
        return (hasManagerWriter, hasWorkspaceReader)
    }

    /// Verifies the owner+agent private ontology cohort channel ACL:
    /// Strictly 2 direct actor grants (owner + assigned agent), zero groups, zero extra principals.
    public static func verifyCohortChannelGrants(
        grants: [[String: Any]],
        members: [MemberRecord],
        ownerNpub: String,
        agentNpub: String
    ) throws -> (ownerId: String, agentId: String) {
        let owners = members.filter { $0.npub == ownerNpub }
        let agents = members.filter { $0.npub == agentNpub }
        guard owners.count == 1, agents.count == 1, ownerNpub != agentNpub else {
            throw ChiefOfStaffError.restricted("Ontology cohort owner and agent must be distinct current workspace members.")
        }
        let ownerId = owners[0].actorId.lowercased()
        let agentId = agents[0].actorId.lowercased()
        guard !ownerId.isEmpty, !agentId.isEmpty, ownerId != agentId else {
            throw ChiefOfStaffError.restricted("Ambiguous ontology cohort identities.")
        }
        var hasOwner = false
        var hasAgent = false
        var seen = Set<String>()
        for g in grants {
            guard isActorGrant(g) else {
                throw ChiefOfStaffError.restricted("Private ontology cohort must not grant access to groups.")
            }
            let p = g["principal"] as? [String: Any]
            guard let pid = grantPrincipalId(g), seen.insert(pid).inserted else {
                throw ChiefOfStaffError.restricted("Ambiguous or duplicate ontology cohort grant identity.")
            }
            let aliases = [p?["actor_id"], p?["id"], g["principal_id"]].compactMap { $0 }
            for alias in aliases {
                guard let s = alias as? String, s.lowercased() == pid else {
                    throw ChiefOfStaffError.restricted("Ambiguous ontology cohort grant identity.")
                }
            }
            let expectedNpub = (pid == ownerId) ? ownerNpub : agentNpub
            if let rawNpub = p?["npub"], !(rawNpub is NSNull) {
                guard let npub = rawNpub as? String, npub == expectedNpub else {
                    throw ChiefOfStaffError.restricted("Ontology cohort grant npub mismatch.")
                }
            }
            guard let perms = permissionsOf(g) else {
                throw ChiefOfStaffError.restricted("Ontology cohort permissions missing.")
            }
            var required: Set<String> = ["channel.read", "file.read", "file.write"]
            if pid == ownerId {
                required.insert("channel.manage")
                required.insert("channel.grants.manage")
            }
            guard required.isSubset(of: perms) else {
                throw ChiefOfStaffError.restricted("Ontology cohort effective permissions are incomplete.")
            }
            if pid == ownerId { hasOwner = true }
            else if pid == agentId { hasAgent = true }
            else {
                throw ChiefOfStaffError.restricted("Private ontology cohort must only include owner and assigned agent.")
            }
        }
        guard hasOwner && hasAgent else {
            throw ChiefOfStaffError.restricted("Ontology cohort owner or agent grant is missing.")
        }
        return (ownerId, agentId)
    }
}

// MARK: - Deterministic correction replay, search, and viewer-specific DM lookup

public struct ChiefOfStaffAppliedOntology: Sendable, Equatable {
    public let topics: [ChiefOfStaffTopic]
    public let evidence: [ChiefOfStaffEvidence]

    public init(topics: [ChiefOfStaffTopic], evidence: [ChiefOfStaffEvidence]) {
        self.topics = topics
        self.evidence = evidence
    }
}

public enum ChiefOfStaffOntologyLogic {
    /// Replays durable corrections deterministically on top of discovered topics & evidence,
    /// matching `applyCorrections` in `scripts/chief-of-staff/model.mjs` and Android.
    public static func applyCorrections(
        discoveredTopics: [ChiefOfStaffTopic],
        discoveredEvidence: [ChiefOfStaffEvidence],
        corrections: [ChiefOfStaffCorrection]
    ) -> ChiefOfStaffAppliedOntology {
        var topicMap: [String: ChiefOfStaffTopic] = [:]
        for t in discoveredTopics {
            var seen = Set<String>()
            let cleanedAliases = t.aliases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
            topicMap[t.id] = ChiefOfStaffTopic(
                id: t.id, name: t.name, kind: t.kind, aliases: cleanedAliases,
                description: t.description, archived: t.archived,
                sourceOrigin: t.sourceOrigin.isEmpty ? "discovered" : t.sourceOrigin, updatedAt: t.updatedAt
            )
        }

        var mergeRedirects: [String: String] = [:]
        func resolveId(_ id: String) -> String {
            var cur = id
            var visited = Set<String>()
            while let next = mergeRedirects[cur], visited.insert(cur).inserted {
                cur = next
            }
            return cur
        }

        var rejectedEvidence = Set<String>()
        var pinnedEvidence = Set<String>()

        let ordered = corrections.sorted { a, b in
            let ta = ChiefOfStaffContract.parseTimestamp(a.createdAt)?.timeIntervalSince1970 ?? 0
            let tb = ChiefOfStaffContract.parseTimestamp(b.createdAt)?.timeIntervalSince1970 ?? 0
            if ta != tb { return ta < tb }
            return a.id < b.id
        }

        for c in ordered {
            switch c.kind {
            case "rename":
                guard let rawTid = c.topicId, let nextName = c.name?.trimmingCharacters(in: .whitespacesAndNewlines), !nextName.isEmpty else { continue }
                let tid = resolveId(rawTid)
                guard let t = topicMap[tid] else { continue }
                var aliases = t.aliases
                if t.name != nextName && !aliases.contains(t.name) { aliases.append(t.name) }
                var seen = Set<String>()
                aliases = aliases.filter { $0 != nextName && seen.insert($0).inserted }
                topicMap[tid] = ChiefOfStaffTopic(
                    id: t.id, name: nextName, kind: t.kind, aliases: aliases,
                    description: t.description, archived: t.archived, sourceOrigin: "corrected", updatedAt: c.createdAt
                )

            case "set_description":
                guard let rawTid = c.topicId, let desc = c.description else { continue }
                let tid = resolveId(rawTid)
                guard let t = topicMap[tid] else { continue }
                topicMap[tid] = ChiefOfStaffTopic(
                    id: t.id, name: t.name, kind: t.kind, aliases: t.aliases,
                    description: desc.trimmingCharacters(in: .whitespacesAndNewlines), archived: t.archived,
                    sourceOrigin: "corrected", updatedAt: c.createdAt
                )

            case "set_aliases":
                guard let rawTid = c.topicId, let list = c.aliases else { continue }
                let tid = resolveId(rawTid)
                guard let t = topicMap[tid] else { continue }
                var seen = Set<String>()
                let aliases = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != t.name && seen.insert($0).inserted }
                topicMap[tid] = ChiefOfStaffTopic(
                    id: t.id, name: t.name, kind: t.kind, aliases: aliases,
                    description: t.description, archived: t.archived, sourceOrigin: "corrected", updatedAt: c.createdAt
                )

            case "set_kind":
                guard let rawTid = c.topicId, let kind = c.topicKind?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty else { continue }
                let tid = resolveId(rawTid)
                guard let t = topicMap[tid] else { continue }
                topicMap[tid] = ChiefOfStaffTopic(
                    id: t.id, name: t.name, kind: kind, aliases: t.aliases,
                    description: t.description, archived: t.archived, sourceOrigin: "corrected", updatedAt: c.createdAt
                )

            case "merge_topics":
                guard let rawSrc = c.sourceTopicId, let rawDst = c.targetTopicId else { continue }
                let srcId = resolveId(rawSrc)
                let dstId = resolveId(rawDst)
                guard srcId != dstId else { continue }
                mergeRedirects[srcId] = dstId
                if let src = topicMap[srcId], let dst = topicMap[dstId] {
                    var seen = Set<String>()
                    let mergedAliases = (dst.aliases + [src.name] + src.aliases)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != dst.name && seen.insert($0).inserted }
                    let mergedDesc = dst.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? src.description : dst.description
                    topicMap[dstId] = ChiefOfStaffTopic(
                        id: dst.id, name: dst.name, kind: dst.kind, aliases: mergedAliases,
                        description: mergedDesc, archived: dst.archived, sourceOrigin: "corrected", updatedAt: c.createdAt
                    )
                    topicMap.removeValue(forKey: srcId)
                } else if let src = topicMap[srcId] {
                    topicMap[dstId] = ChiefOfStaffTopic(
                        id: dstId, name: src.name, kind: src.kind, aliases: src.aliases,
                        description: src.description, archived: src.archived, sourceOrigin: "corrected", updatedAt: c.createdAt
                    )
                    topicMap.removeValue(forKey: srcId)
                }

            case "archive_topic":
                guard let rawTid = c.topicId else { continue }
                let tid = resolveId(rawTid)
                guard let t = topicMap[tid] else { continue }
                topicMap[tid] = ChiefOfStaffTopic(
                    id: t.id, name: t.name, kind: t.kind, aliases: t.aliases,
                    description: t.description, archived: c.archived != false, sourceOrigin: "corrected", updatedAt: c.createdAt
                )

            case "reject_evidence":
                guard let rawTid = c.topicId, let st = c.sourceType, let rid = c.recordId?.lowercased() else { continue }
                let key = "\(resolveId(rawTid))::\(st)::\(rid)"
                rejectedEvidence.insert(key)
                pinnedEvidence.remove(key)

            case "pin_evidence":
                guard let rawTid = c.topicId, let st = c.sourceType, let rid = c.recordId?.lowercased() else { continue }
                let key = "\(resolveId(rawTid))::\(st)::\(rid)"
                rejectedEvidence.remove(key)
                pinnedEvidence.insert(key)

            default:
                continue
            }
        }

        var deduped: [String: ChiefOfStaffEvidence] = [:]
        for ev in discoveredEvidence {
            let tid = resolveId(ev.topicId)
            guard topicMap[tid] != nil else { continue }
            let key = "\(tid)::\(ev.sourceType)::\(ev.recordId.lowercased())"
            if rejectedEvidence.contains(key) { continue }
            let pinned = pinnedEvidence.contains(key) || ev.pinned
            let nextScore = pinned ? max(ev.score, 0.99) : ev.score
            if let existing = deduped[key], nextScore <= existing.score { continue }
            let hashPrefix = String(SHA256Hex.of(Data(key.utf8)).prefix(16))
            deduped[key] = ChiefOfStaffEvidence(
                id: "ev_\(hashPrefix)",
                topicId: tid,
                sourceType: ev.sourceType,
                recordId: ev.recordId,
                channelId: ev.channelId,
                threadId: ev.threadId,
                sourceRevision: ev.sourceRevision,
                sourceTitle: ev.sourceTitle,
                explanation: ev.explanation,
                score: (nextScore * 10_000).rounded() / 10_000,
                status: ev.status,
                pinned: pinned,
                updatedAt: ev.updatedAt
            )
        }

        let sortedTopics = topicMap.values.sorted { a, b in
            if a.archived != b.archived { return !a.archived }
            let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a.id < b.id
        }
        let sortedEvidence = deduped.values.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.score != b.score { return a.score > b.score }
            return a.id < b.id
        }
        return ChiefOfStaffAppliedOntology(topics: sortedTopics, evidence: sortedEvidence)
    }

    public static func searchTopics(
        topics: [ChiefOfStaffTopic],
        evidence: [ChiefOfStaffEvidence],
        query: String,
        includeArchived: Bool = false
    ) -> [ChiefOfStaffTopic] {
        let visible = includeArchived ? topics : topics.filter { !$0.archived }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return visible }
        let byTopic = Dictionary(grouping: evidence, by: \.topicId)
        return visible.filter { t in
            t.name.lowercased().contains(q)
                || t.kind.lowercased().contains(q)
                || t.description.lowercased().contains(q)
                || t.aliases.contains { $0.lowercased().contains(q) }
                || (byTopic[t.id] ?? []).contains { ev in
                    ev.sourceTitle.lowercased().contains(q) || ev.explanation.lowercased().contains(q)
                }
        }
    }

    /// Finds the viewer's OWN authorized 2-party DM channel with `agentNpub` inside an active DM scope.
    /// Never returns another member's DM, a self-DM, a group DM, or an archived/deleted channel.
    public static func findViewerDirectMessage(
        scopes: [ScopeRecord],
        channels: [ChannelRecord],
        viewerNpub: String,
        agentNpub: String
    ) -> ChannelRecord? {
        guard viewerNpub != agentNpub,
              NostrKeys.isValidNpub(viewerNpub),
              NostrKeys.isValidNpub(agentNpub)
        else { return nil }
        let dmScopeIds = Set(
            scopes
                .filter { ChiefOfStaffContract.isActiveRecord($0.raw) && SidebarNavigation.isDirectMessageScope($0) }
                .map(\.id)
        )
        let expected = Set([viewerNpub, agentNpub])
        return channels.first { ch in
            guard dmScopeIds.contains(ch.scopeId),
                  ChiefOfStaffContract.isActiveRecord(ch.raw),
                  SidebarNavigation.isDirectMessageChannel(ch)
            else { return false }
            let participants = Set(SidebarNavigation.participants(ch))
            return participants.count == 2 && participants == expected
        }
    }

    public static func directMessageScope(scopes: [ScopeRecord]) -> ScopeRecord? {
        scopes.first { ChiefOfStaffContract.isActiveRecord($0.raw) && SidebarNavigation.isDirectMessageScope($0) }
    }
}
