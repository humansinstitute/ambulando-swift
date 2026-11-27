import Foundation
import XCTest
@testable import AmbulandoCore

@MainActor final class GoalTextLineageTests: XCTestCase {
    enum Mode: Sendable { case primary, mentionOnly, missingMessage, deniedMessage, existing, later }
    static let message = "11111111-1111-4111-8111-111111111111"
    static let thread = "22222222-2222-4222-8222-222222222222"
    static let file = "33333333-3333-4333-8333-333333333333"
    static let versionId = "44444444-4444-4444-8444-444444444444"
    static let original = "55555555-5555-4555-8555-555555555555"
    static let uploaded = "66666666-6666-4666-8666-666666666666"

    func makeAPI(_ mode: Mode) async throws -> (TowerAPI, StubTransport) {
        let w = GoalWireTests.workspace, c = GoalWireTests.channel, g = GoalWireTests.file
        let message = Self.message, thread = Self.thread, file = Self.file, version = Self.versionId, original = Self.original, uploaded = Self.uploaded
        let goal = GoalWireTests.Tower(try Goal.create(name: "Private aim", description: "Never copy the body"))
        let transport = StubTransport { request in
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            if path.hasSuffix("/storage/prepare") { return (200, ["object_id": uploaded, "is_public": false, "upload_url": "https://tower.example/api/v4/storage/\(uploaded)"]) }
            if method == "PUT" { return (200, [:]) }
            if path.hasSuffix("/complete") { return (200, ["completed_at": "2026-11-27T00:00:00Z"]) }
            if path.hasPrefix("/api/v4/storage/"), method == "GET" { return (200, ["completed_at": "2026-11-27T00:00:00Z", "is_public": false, "sha256_hex": SHA256Hex.of(Data("edited".utf8)), "size_bytes": 6]) }
            let lineage: [String: Any] = ["v": 1, "origin_message_id": message, "origin_storage_object_id": original, "origin_filename": "Original.txt"]
            let row: [String: Any] = ["id": file, "workspace_id": w, "channel_id": c, "display_name": "Mine.txt", "current_version_id": version,
                "metadata": ["text_attachment_lineage": lineage, "another_app": ["preserve": true]]]
            if path.hasSuffix("/channels/\(c)/files"), method == "GET" { return (200, ["files": mode == .existing ? [row] : [], "next_cursor": NSNull()]) }
            if path.hasSuffix("/messages/\(message)") {
                if mode == .missingMessage { return (404, ["code": "missing"]) }
                if mode == .deniedMessage || mode == .existing { return (403, ["code": "denied"]) }
                return (200, ["message": ["id": message, "workspace_id": w, "channel_id": c, "thread_id": thread, "body": "Consider @[Goal](mention:file:\(g))", "metadata": ["future": "unchanged"]]])
            }
            if path.hasSuffix("/threads/\(thread)") {
                let metadata: [String: Any] = mode == .mentionOnly ? [:] : [GoalAssociation.key: ["version": 1, "goal_file_id": g, "future": "not copied"]]
                return (200, ["thread": ["id": thread, "workspace_id": w, "channel_id": c, "metadata": metadata]])
            }
            if path.hasSuffix("/files/\(file)/versions"), method == "GET" {
                return (200, ["versions": [["id": version, "storage_object_id": uploaded, "version_number": 1]], "current_version_id": version])
            }
            if method == "POST" && (path.hasSuffix("/channels/\(c)/files") || path.hasSuffix("/files/\(file)/versions")) {
                return (201, ["file": row, "version": ["id": version, "storage_object_id": uploaded, "version_number": 2]])
            }
            return try goal.handle(request)
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: try await makeIdentity()))
        return (api, transport)
    }

    func save(_ api: TowerAPI, lineage: TextLineage? = nil, metadata: JSONValue = .object([])) async throws -> TextSaveOutcome {
        try await api.saveTextEdit(workspaceId: GoalWireTests.workspace, appNpub: GoalWireTests.app, channelId: GoalWireTests.channel,
            origin: (Self.message, Self.original, "Original.txt"), lineage: lineage, baseVersionId: lineage?.currentVersionId,
            bytes: Data("edited".utf8), filename: "Mine.txt", clientMutationId: "stable-mutation", metadata: metadata)
    }

    func testFirstNativeFileUsesAuthoritativePrimaryAndProtectedLineageOnly() async throws {
        let (api, transport) = try await makeAPI(.primary)
        let extra = JSONValue.object([("another_app", .string("keep")), ("text_attachment_lineage", .string("cannot override"))])
        _ = try await save(api, metadata: extra)
        let request = transport.recorded.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/channels/\(GoalWireTests.channel)/files") }!
        let metadata = try JSONValue.parse(request.httpBody!)["metadata"]!
        XCTAssertEqual(GoalWireTests.file, try GoalAssociation.read(metadata))
        XCTAssertEqual(try GoalAssociation.metadata(goalFileId: GoalWireTests.file)[GoalAssociation.key], metadata[GoalAssociation.key])
        XCTAssertEqual(.string(Self.thread), metadata["source_thread_id"])
        XCTAssertEqual(.string("keep"), metadata["another_app"])
        XCTAssertEqual(.string(Self.message), metadata["text_attachment_lineage"]?["origin_message_id"])
        XCTAssertFalse(transport.recorded.contains { $0.httpMethod != "GET" && ($0.url!.path.hasSuffix("/messages/\(Self.message)") || $0.url!.path.hasSuffix("/threads/\(Self.thread)")) })
    }

    func testMentionOnlyAndMissingMessageDoNotInventAGoal() async throws {
        for mode in [Mode.mentionOnly, .missingMessage] {
            let (api, transport) = try await makeAPI(mode)
            _ = try await save(api)
            let request = transport.recorded.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/channels/\(GoalWireTests.channel)/files") }!
            let metadata = try JSONValue.parse(request.httpBody!)["metadata"]!
            XCTAssertNil(try GoalAssociation.read(metadata))
            XCTAssertEqual(mode == .mentionOnly ? .string(Self.thread) : nil, metadata["source_thread_id"])
        }
    }

    func testDeniedSourceRefusesBeforeNativeFileCreation() async throws {
        let (api, transport) = try await makeAPI(.deniedMessage)
        do { _ = try await save(api); XCTFail("denied origin must retain the local edit") } catch {}
        XCTAssertFalse(transport.recorded.contains { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/channels/\(GoalWireTests.channel)/files") })
    }

    func testExistingCanonicalAndLaterVersionsNeverRereadOrReassignTheOrigin() async throws {
        for mode in [Mode.existing, .later] {
            let (api, transport) = try await makeAPI(mode)
            let lineage = mode == .later ? TextLineage(fileId: Self.file, displayName: "Mine.txt", currentVersionId: Self.versionId) : nil
            let outcome = try await save(api, lineage: lineage)
            guard case .saved(let saved, _) = outcome else { return XCTFail("matching canonical object should recover") }
            XCTAssertEqual(Self.file, saved.fileId)
            XCTAssertFalse(transport.recorded.contains { $0.url!.path.hasSuffix("/messages/\(Self.message)") || $0.url!.path.hasSuffix("/threads/\(Self.thread)") })
            XCTAssertFalse(transport.recorded.contains { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/channels/\(GoalWireTests.channel)/files") })
        }
    }
}
