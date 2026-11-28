import AmbulandoCore
import SwiftUI

// MARK: - Manage Workspace -> Chief of Staff

/// Workspace Chief of Staff assignment and status view inside Manage Workspace.
/// Workspace managers (`owner`, `admin`, or `workspace.manage`) can select/change/remove an existing
/// workspace agent; ordinary members can view the current assignment and open their own DM shortcut.
struct ChiefOfStaffManagementView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let connection: ConnectionRecord

    @State private var members = LiveQuery<[MemberRecord]>(initial: [])
    @State private var selectedAgentNpub: String = ""
    @State private var confirmRemove = false

    private var cos: ChiefOfStaffModel? { model.chiefOfStaffModel(for: workspace) }
    private var isManager: Bool {
        model.membership?.isAdmin == true || workspace.ownerNpub == connection.signerNpub
    }
    private var workspaceAgents: [MemberRecord] {
        members.value
            .filter { $0.kind?.lowercased() == "agent" }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
    private var setupScopeId: String? {
        model.navigation.value.groups.first {
            $0.scope.kind != "dm" && ChiefOfStaffContract.isActiveRecord($0.scope.raw)
        }?.id
    }

    var body: some View {
        List {
            if let cos {
                assignmentSection(cos)
                if isManager {
                    managerControlsSection(cos)
                } else {
                    Section {
                        Text("Read only. Workspace managers can change the Chief of Staff assignment. Ordinary members can see who is assigned and open their own direct message.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                statusAndTopicsSection(cos)
                transparencySection
            } else {
                ContentUnavailableView(
                    "Unlock to view Chief of Staff",
                    systemImage: "lock.shield",
                    description: Text("Chief of Staff status loads for the active unlocked workspace.")
                )
            }
        }
        .navigationTitle("Chief of Staff")
        .confirmationDialog("Remove Chief of Staff?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Chief of Staff", role: .destructive) {
                guard let cos else { return }
                Task { await cos.saveAssignment(agentNpub: nil, scopeIdForSetup: setupScopeId) }
            }
        } message: {
            Text("This writes a new assignment revision with no assigned agent and preserves previous versions. No workspace records are deleted.")
        }
        .task(id: "\(connection.id):\(workspace.id)") {
            if let store = model.store {
                let wsId = workspace.id
                members.start(store: store, matches: { $0.table == .access || ($0.workspaceId == wsId && $0.table == .members) }) {
                    try await store.reader.members(workspaceId: wsId)
                }
            }
            await cos?.refresh(verifyAcl: isManager)
            if selectedAgentNpub.isEmpty, let assigned = cos?.assignedAgentNpub {
                selectedAgentNpub = assigned
            }
        }
        .onDisappear { members.stop() }
    }

    @ViewBuilder private func assignmentSection(_ cos: ChiefOfStaffModel) -> some View {
        Section("Workspace Assignment") {
            switch cos.assignmentState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Chief of Staff assignment…").foregroundStyle(.secondary)
                }
            case .needsSetup:
                Label("No Chief of Staff assigned", systemImage: "person.badge.shield.checkmark")
                    .foregroundStyle(.secondary)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Amb.destructive)
                    .font(.footnote)
            case .ready(let assignment, _, _, _):
                if assignment.isAssigned, let npub = assignment.assignedNpub {
                    let displayName = assignment.assignedDisplayName
                        ?? workspaceAgents.first(where: { $0.npub == npub })?.label
                        ?? "Assigned agent"
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(displayName, systemImage: "person.badge.shield.checkmark")
                                .font(.headline)
                            Spacer()
                            Text("Rev \(assignment.assignmentRevision)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(npub)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Updated \(assignment.updatedAt)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.openChiefOfStaffDM()
                    } label: {
                        Label("Message \(displayName) (Your DM)", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("cos.admin.openDM")
                } else {
                    Label("Unassigned (revision \(assignment.assignmentRevision))", systemImage: "person.slash")
                        .foregroundStyle(.secondary)
                }
            }

            if let notice = cos.actionNotice {
                Text(notice).font(.caption).foregroundStyle(Amb.primary)
            }
            if let err = cos.actionError {
                Text(err).font(.caption).foregroundStyle(Amb.destructive)
            }

            Button("Refresh assignment and index status") {
                Task { await cos.refresh(verifyAcl: isManager) }
            }
            .disabled(cos.saving)
            .accessibilityIdentifier("cos.admin.refresh")
        }
    }

    @ViewBuilder private func managerControlsSection(_ cos: ChiefOfStaffModel) -> some View {
        Section("Change Assignment") {
            if workspaceAgents.isEmpty {
                Text("No agents are members of this workspace yet. Add an agent in Members first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Workspace agent", selection: $selectedAgentNpub) {
                    Text("Select an agent…").tag("")
                    ForEach(workspaceAgents) { agent in
                        Text(agent.label).tag(agent.npub)
                    }
                }
                .accessibilityIdentifier("cos.admin.agentPicker")

                HStack {
                    Button(cos.assignedAgentNpub == nil ? "Assign Chief of Staff" : "Change Chief of Staff") {
                        let target = selectedAgentNpub
                        guard !target.isEmpty else { return }
                        Task { await cos.saveAssignment(agentNpub: target, scopeIdForSetup: setupScopeId) }
                    }
                    .disabled(cos.saving || selectedAgentNpub.isEmpty || selectedAgentNpub == cos.assignedAgentNpub)
                    .accessibilityIdentifier("cos.admin.save")

                    if cos.assignedAgentNpub != nil {
                        Spacer()
                        Button("Remove", role: .destructive) { confirmRemove = true }
                            .disabled(cos.saving)
                            .accessibilityIdentifier("cos.admin.remove")
                    }
                }
            }
        }
    }

    @ViewBuilder private func statusAndTopicsSection(_ cos: ChiefOfStaffModel) -> some View {
        Section("Topic Index & Schedule Status") {
            LabeledContent("Status", value: cos.statusLabel)
                .accessibilityIdentifier("cos.admin.status")

            switch cos.cohortState {
            case .ready(let cohort):
                let status = cohort.jobStatus
                LabeledContent("Topics", value: "\(cohort.applied.topics.filter { !$0.archived }.count)")
                LabeledContent("Evidence links", value: "\(cohort.applied.evidence.count)")
                if let lastSuccess = status.lastSuccessAt {
                    LabeledContent("Last indexed", value: lastSuccess)
                }
                if let err = status.lastError, !err.isEmpty {
                    Text(err).font(.caption).foregroundStyle(Amb.destructive)
                }
                Button {
                    model.openChiefOfStaffTopics()
                } label: {
                    Label("Open Topic Reference", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("cos.admin.openTopics")
            case .pendingSetup:
                Text("The assignment is saved, and background topic indexing has not published a snapshot for this assignment epoch yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .restricted:
                Text("The living topic ontology is private to the workspace owner and the assigned Chief of Staff agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text(message).font(.caption).foregroundStyle(Amb.destructive)
            case .idle, .loading:
                EmptyView()
            }
        }
    }

    private var transparencySection: some View {
        Section("Authority & Privacy") {
            Text("Assigning a Chief of Staff grants no new channel, task, document, or file access. Normal @ mentions continue to work as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Encryption is deferred in v1 (versioned plaintext envelope). Private topic ontology data is isolated to an owner + assigned agent channel and is never surfaced to ordinary workspace members.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Searchable Living Topic Reference

struct ChiefOfStaffTopicsView: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceRecord
    let store: LocalStore

    @State private var query = ""
    @State private var includeArchived = false
    @State private var selectedTopicId: String?

    private var cos: ChiefOfStaffModel? { model.chiefOfStaffModel(for: workspace) }

    var body: some View {
        Group {
            if let cos {
                content(cos)
            } else {
                ContentUnavailableView("Unlock to view topics", systemImage: "lock.shield")
            }
        }
        .navigationTitle("Chief of Staff Topics")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await cos?.refresh(verifyAcl: false) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("cos.topics.refresh")
            }
        }
        .task(id: "\(model.connection?.id ?? ""):\(workspace.id)") {
            await cos?.refresh(verifyAcl: false)
        }
    }

    @ViewBuilder private func content(_ cos: ChiefOfStaffModel) -> some View {
        switch cos.assignmentState {
        case .idle, .loading:
            ProgressView("Loading Chief of Staff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsSetup:
            ContentUnavailableView(
                "No Chief of Staff assigned",
                systemImage: "person.badge.shield.checkmark",
                description: Text("A workspace manager can assign an existing workspace agent in Manage Workspace → Chief of Staff.")
            )
        case .error(let msg):
            ContentUnavailableView(
                "Could not verify assignment",
                systemImage: "exclamationmark.triangle",
                description: Text(msg)
            )
        case .ready(let assignment, _, _, _):
            if !assignment.isAssigned {
                ContentUnavailableView(
                    "No Chief of Staff assigned",
                    systemImage: "person.slash",
                    description: Text("Assign a workspace agent in Manage Workspace → Chief of Staff.")
                )
            } else {
                cohortContent(cos, assignment: assignment)
            }
        }
    }

    @ViewBuilder private func cohortContent(_ cos: ChiefOfStaffModel, assignment: ChiefOfStaffAssignment) -> some View {
        switch cos.cohortState {
        case .idle, .loading:
            ProgressView("Loading private topic index…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .restricted:
            ContentUnavailableView(
                "Private Topic Index",
                systemImage: "lock.shield",
                description: Text("This living topic reference is restricted to the workspace owner and the assigned Chief of Staff agent. You can still message the Chief of Staff directly from your own DM shortcut.")
            )
        case .pendingSetup:
            ContentUnavailableView(
                "Assigned · Index setup pending",
                systemImage: "clock.badge.checkmark",
                description: Text("\(assignment.assignedDisplayName ?? "Chief of Staff") is assigned (revision \(assignment.assignmentRevision)), but the background index has not published a snapshot for this assignment yet.")
            )
        case .error(let msg):
            ContentUnavailableView(
                "Topic index error",
                systemImage: "exclamationmark.triangle",
                description: Text(msg)
            )
        case .ready(let cohort):
            readySplit(cos, assignment: assignment, cohort: cohort)
        }
    }

    @ViewBuilder private func readySplit(
        _ cos: ChiefOfStaffModel,
        assignment: ChiefOfStaffAssignment,
        cohort: ChiefOfStaffModel.ReadyCohort
    ) -> some View {
        let filtered = ChiefOfStaffOntologyLogic.searchTopics(
            topics: cohort.applied.topics,
            evidence: cohort.applied.evidence,
            query: query,
            includeArchived: includeArchived
        )
        let activeTopic = filtered.first(where: { $0.id == selectedTopicId }) ?? filtered.first

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(assignment.assignedDisplayName ?? "Chief of Staff", systemImage: "person.badge.shield.checkmark")
                    .font(.amb(.subheadline).weight(.semibold))
                Text(cos.statusLabel)
                    .font(.amb(.caption).weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Amb.muted, in: Capsule())
                Spacer()
                Text("Plaintext v1 · Owner + Agent private")
                    .font(.amb(.caption2))
                    .foregroundStyle(Amb.mutedForeground)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Amb.card)
            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        TextField("Search topics, aliases, or evidence…", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("cos.topics.search")
                        #if os(macOS)
                        Toggle("Archived", isOn: $includeArchived)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        #else
                        Toggle("Archived", isOn: $includeArchived)
                            .font(.caption)
                        #endif
                    }
                    .padding(10)
                    Divider()
                    if filtered.isEmpty {
                        ContentUnavailableView("No matching topics", systemImage: "magnifyingglass")
                    } else {
                        List(filtered, selection: $selectedTopicId) { topic in
                            let count = cohort.applied.evidence.filter { $0.topicId == topic.id }.count
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(topic.name).font(.amb(.subheadline).weight(.semibold))
                                    Spacer()
                                    if topic.sourceOrigin == "corrected" {
                                        Text("Corrected")
                                            .font(.caption2)
                                            .foregroundStyle(Amb.primary)
                                    }
                                    Text("\(count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 6) {
                                    Text(topic.kind).font(.caption2).foregroundStyle(.secondary)
                                    if !topic.aliases.isEmpty {
                                        Text("· " + topic.aliases.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .tag(topic.id)
                            .padding(.vertical, 2)
                            .accessibilityIdentifier("cos.topic.\(topic.id)")
                        }
                    }
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

                Divider()

                if let topic = activeTopic {
                    ChiefOfStaffTopicDetailView(
                        cos: cos,
                        topic: topic,
                        allTopics: cohort.applied.topics,
                        evidence: cohort.applied.evidence.filter { $0.topicId == topic.id },
                        viewerNpub: model.connection?.signerNpub ?? ""
                    )
                    .id(topic.id)
                } else {
                    ContentUnavailableView("Select a topic", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Topic detail, native evidence drillthrough & durable corrections

private struct ChiefOfStaffTopicDetailView: View {
    @Environment(AppModel.self) private var model
    let cos: ChiefOfStaffModel
    let topic: ChiefOfStaffTopic
    let allTopics: [ChiefOfStaffTopic]
    let evidence: [ChiefOfStaffEvidence]
    let viewerNpub: String

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showMerge = false
    @State private var mergeTargetId = ""

    private var mergeCandidates: [ChiefOfStaffTopic] {
        allTopics.filter { $0.id != topic.id && !$0.archived }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(topic.name).font(.title2.weight(.bold))
                        Spacer()
                        Text(topic.kind)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Amb.muted, in: Capsule())
                        if topic.archived {
                            Text("Archived")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Amb.warningBackground, in: Capsule())
                        }
                    }
                    if !topic.aliases.isEmpty {
                        Text("Aliases: " + topic.aliases.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !topic.description.isEmpty {
                        Text(topic.description).font(.body)
                    }
                }

                HStack(spacing: 8) {
                    Button("Rename") {
                        renameText = topic.name
                        showRename = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(cos.saving)
                    .accessibilityIdentifier("cos.topic.rename")

                    Button("Merge into…") {
                        mergeTargetId = mergeCandidates.first?.id ?? ""
                        showMerge = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(cos.saving || mergeCandidates.isEmpty)
                    .accessibilityIdentifier("cos.topic.merge")

                    Button(topic.archived ? "Unarchive" : "Archive") {
                        let correction = ChiefOfStaffCorrection(
                            kind: "archive_topic",
                            createdByNpub: viewerNpub,
                            topicId: topic.id,
                            archived: !topic.archived
                        )
                        Task { _ = await cos.appendCorrection(correction) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(cos.saving)
                    .accessibilityIdentifier("cos.topic.archive")
                }

                if let err = cos.actionError {
                    Text(err).font(.caption).foregroundStyle(Amb.destructive)
                } else if let notice = cos.actionNotice {
                    Text(notice).font(.caption).foregroundStyle(Amb.primary)
                }

                Divider()

                Text("Supporting Evidence (\(evidence.count))")
                    .font(.headline)

                if evidence.isEmpty {
                    Text("No active supporting evidence for this topic.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(evidence) { item in
                        evidenceCard(item)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showRename) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Topic").font(.headline)
                TextField("Topic name", text: $renameText).textFieldStyle(.roundedBorder)
                Text("Previous name is retained as an alias and survives future re-indexing.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showRename = false }
                    Button("Save") {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let correction = ChiefOfStaffCorrection(
                            kind: "rename",
                            createdByNpub: viewerNpub,
                            topicId: topic.id,
                            name: trimmed
                        )
                        showRename = false
                        Task { _ = await cos.appendCorrection(correction) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
        .sheet(isPresented: $showMerge) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Merge “\(topic.name)” into…").font(.headline)
                Picker("Target topic", selection: $mergeTargetId) {
                    ForEach(mergeCandidates) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }
                Text("Evidence and aliases move to the target topic and persist across rebuilds.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showMerge = false }
                    Button("Merge") {
                        guard !mergeTargetId.isEmpty else { return }
                        let correction = ChiefOfStaffCorrection(
                            kind: "merge_topics",
                            createdByNpub: viewerNpub,
                            sourceTopicId: topic.id,
                            targetTopicId: mergeTargetId
                        )
                        showMerge = false
                        Task { _ = await cos.appendCorrection(correction) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mergeTargetId.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private func evidenceCard(_ item: ChiefOfStaffEvidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.sourceType.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Amb.muted, in: Capsule())
                if item.pinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Amb.primary)
                }
                if item.status != "active" {
                    Text(item.status.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Amb.warning)
                }
                Spacer()
                Text(String(format: "%.2f", item.score))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(item.sourceTitle.isEmpty ? item.recordId : item.sourceTitle)
                .font(.amb(.subheadline).weight(.semibold))
            if !item.explanation.isEmpty {
                Text(item.explanation)
                    .font(.amb(.footnote))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    openEvidence(item)
                } label: {
                    Label("Open source", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(item.status == "deleted" || item.status == "inaccessible")

                if !item.pinned {
                    Button {
                        let c = ChiefOfStaffCorrection(
                            kind: "pin_evidence",
                            createdByNpub: viewerNpub,
                            topicId: topic.id,
                            sourceType: item.sourceType,
                            recordId: item.recordId
                        )
                        Task { _ = await cos.appendCorrection(c) }
                    } label: {
                        Label("Pin", systemImage: "pin")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(cos.saving)
                }

                Button(role: .destructive) {
                    let c = ChiefOfStaffCorrection(
                        kind: "reject_evidence",
                        createdByNpub: viewerNpub,
                        topicId: topic.id,
                        sourceType: item.sourceType,
                        recordId: item.recordId,
                        reason: "Marked wrong connection by user"
                    )
                    Task { _ = await cos.appendCorrection(c) }
                } label: {
                    Label("Wrong connection", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(cos.saving)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Amb.card, in: RoundedRectangle(cornerRadius: Amb.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: Amb.radiusPanel).stroke(Amb.border, lineWidth: 1))
    }

    private func openEvidence(_ item: ChiefOfStaffEvidence) {
        switch item.sourceType {
        case "task":
            model.openRecord(kind: "task", id: item.recordId)
        case "doc":
            model.openRecord(kind: "doc", id: item.recordId)
        case "file":
            model.openRecord(kind: "file", id: item.recordId)
        case "thread":
            if let cid = item.channelId {
                model.openInChat(channelId: cid, threadId: item.recordId)
            } else {
                model.openRecord(kind: "thread", id: item.recordId)
            }
        case "message", "audio_note":
            let ref = item.channelId.map { "\($0)#\(item.recordId)" } ?? item.recordId
            model.openRecord(kind: "message", id: ref)
        default:
            break
        }
    }
}
