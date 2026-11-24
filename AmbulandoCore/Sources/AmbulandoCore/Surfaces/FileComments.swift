import Foundation

public struct HTMLArtefactVersion: Sendable, Equatable, Identifiable {
    public let id: String
    public let versionNumber: Int
    public let createdAt: String
    public let createdByActorNpub: String?
    public let contentType: String?
    public let sizeBytes: Int?

    public init(id: String, versionNumber: Int, createdAt: String, createdByActorNpub: String?, contentType: String?, sizeBytes: Int?) {
        self.id = id
        self.versionNumber = versionNumber
        self.createdAt = createdAt
        self.createdByActorNpub = createdByActorNpub
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

public struct HTMLArtefactPayload: Sendable, Equatable {
    public let fileId: String
    public let versionId: String
    public let versionNumber: Int
    public let currentVersionId: String?
    public let currentVersionNumber: Int?
    public let digest: String
    public let html: String
    public let versions: [HTMLArtefactVersion]
    public let manifestError: String?
}

public struct HTMLCommentAnchor: Sendable, Equatable {
    public var kind: String
    public var elementId: String?
    public var selector: String?
    public var domPath: [Int]
    public var tagName: String?
    public var textQuote: String?
    public var textPrefix: String?
    public var textSuffix: String?
    public var attrFingerprint: String?
    public var fileVersionId: String?
    public var fileVersionNumber: Int?
    public var versionDigest: String?

    public init(
        kind: String = "html_element",
        elementId: String? = nil,
        selector: String? = nil,
        domPath: [Int] = [],
        tagName: String? = nil,
        textQuote: String? = nil,
        textPrefix: String? = nil,
        textSuffix: String? = nil,
        attrFingerprint: String? = nil,
        fileVersionId: String? = nil,
        fileVersionNumber: Int? = nil,
        versionDigest: String? = nil
    ) {
        self.kind = kind
        self.elementId = elementId
        self.selector = selector
        self.domPath = domPath
        self.tagName = tagName
        self.textQuote = textQuote
        self.textPrefix = textPrefix
        self.textSuffix = textSuffix
        self.attrFingerprint = attrFingerprint
        self.fileVersionId = fileVersionId
        self.fileVersionNumber = fileVersionNumber
        self.versionDigest = versionDigest
    }

    public func draftKey(versionId: String) -> String {
        "root:\(versionId):\(elementId ?? selector ?? attrFingerprint ?? "doc")"
    }

    public func targetSummary() -> String {
        let quote = textQuote?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        let tag = tagName?.lowercased()
        if let quote, !quote.isEmpty, let tag, !tag.isEmpty { return "<\(tag)> “\(quote)”" }
        if let quote, !quote.isEmpty { return "“\(quote)”" }
        if let fp = attrFingerprint, !fp.isEmpty, let tag, !tag.isEmpty { return "<\(tag)> (\(fp.prefix(40)))" }
        if let elementId, !elementId.isEmpty { return "#\(elementId)" }
        if let selector, !selector.isEmpty { return String(selector.prefix(60)) }
        if let tag, !tag.isEmpty { return "<\(tag)>" }
        return "Document"
    }

    public func toJSONObject() -> [String: Any] {
        var out: [String: Any] = ["kind": kind]
        if let elementId, !elementId.isEmpty { out["element_id"] = elementId }
        if let selector, !selector.isEmpty { out["selector"] = selector }
        if !domPath.isEmpty { out["dom_path"] = domPath }
        if let tagName, !tagName.isEmpty { out["tag_name"] = tagName }
        if let textQuote, !textQuote.isEmpty { out["text_quote"] = textQuote }
        if let textPrefix, !textPrefix.isEmpty { out["text_prefix"] = textPrefix }
        if let textSuffix, !textSuffix.isEmpty { out["text_suffix"] = textSuffix }
        if let attrFingerprint, !attrFingerprint.isEmpty { out["attr_fingerprint"] = attrFingerprint }
        if let fileVersionId, !fileVersionId.isEmpty { out["file_version_id"] = fileVersionId }
        if let fileVersionNumber { out["file_version_number"] = fileVersionNumber }
        if let versionDigest, !versionDigest.isEmpty { out["version_digest"] = versionDigest }
        return out
    }

    public static func parse(_ object: [String: Any]?) -> HTMLCommentAnchor? {
        guard let object, !object.isEmpty else { return nil }
        let rawKind = (object["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = (rawKind == "document" || rawKind == "html_element") ? rawKind! : "html_element"
        let domPath: [Int] = ((object["dom_path"] as? [Any]) ?? []).prefix(64).compactMap {
            guard let n = flexibleInt($0), n >= 0, n <= 100_000 else { return nil }
            return n
        }
        func bounded(_ key: String, max: Int) -> String? {
            guard let raw = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return String(raw.prefix(max))
        }
        let digest = bounded("version_digest", max: 64)?.lowercased()
        return HTMLCommentAnchor(
            kind: kind,
            elementId: bounded("element_id", max: 256),
            selector: bounded("selector", max: 1024),
            domPath: domPath,
            tagName: bounded("tag_name", max: 64)?.lowercased(),
            textQuote: bounded("text_quote", max: 240),
            textPrefix: bounded("text_prefix", max: 120),
            textSuffix: bounded("text_suffix", max: 120),
            attrFingerprint: bounded("attr_fingerprint", max: 256),
            fileVersionId: lowerUUID(object["file_version_id"] as? String),
            fileVersionNumber: flexibleInt(object["file_version_number"]),
            versionDigest: digest?.count == 64 ? digest : nil
        )
    }
}

public struct FileCommentRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceId: String
    public let fileId: String
    public let fileVersionId: String
    public let fileVersionNumber: Int?
    public let parentCommentId: String?
    public let body: String
    public let commentStatus: String
    public let anchor: HTMLCommentAnchor?
    public let createdByActorId: String
    public let createdByActorNpub: String?
    public let updatedByActorId: String
    public let updatedByActorNpub: String?
    public let rowVersion: Int
    public let createdAt: String
    public let updatedAt: String
    public let canEdit: Bool
    public let canResolve: Bool
    public let canDelete: Bool

    public var isResolved: Bool { commentStatus == "resolved" }
    public var isRoot: Bool { parentCommentId == nil }

    public static func parse(_ object: [String: Any]) -> FileCommentRecord? {
        guard let id = lowerUUID(object["id"] as? String),
              let workspaceId = lowerUUID(object["workspace_id"] as? String),
              let fileId = lowerUUID(object["file_id"] as? String),
              let fileVersionId = lowerUUID(object["file_version_id"] as? String),
              let body = object["body"] as? String,
              let createdByActorId = lowerUUID(object["created_by_actor_id"] as? String) else { return nil }
        return FileCommentRecord(
            id: id,
            workspaceId: workspaceId,
            fileId: fileId,
            fileVersionId: fileVersionId,
            fileVersionNumber: flexibleInt(object["file_version_number"]),
            parentCommentId: lowerUUID(object["parent_comment_id"] as? String),
            body: body,
            commentStatus: (object["comment_status"] as? String) ?? "open",
            anchor: HTMLCommentAnchor.parse(object["anchor"] as? [String: Any]),
            createdByActorId: createdByActorId,
            createdByActorNpub: (object["created_by_actor_npub"] as? String) ?? (object["sender_npub"] as? String),
            updatedByActorId: lowerUUID(object["updated_by_actor_id"] as? String) ?? createdByActorId,
            updatedByActorNpub: object["updated_by_actor_npub"] as? String,
            rowVersion: flexibleInt(object["row_version"]) ?? 1,
            createdAt: (object["created_at"] as? String) ?? "",
            updatedAt: (object["updated_at"] as? String) ?? "",
            canEdit: (object["can_edit"] as? Bool) == true,
            canResolve: (object["can_resolve"] as? Bool) == true,
            canDelete: (object["can_delete"] as? Bool) == true
        )
    }
}

public struct FileCommentPermissions: Sendable, Equatable {
    public let canRead: Bool
    public let canComment: Bool
    public let canResolveAny: Bool
    public let canEditSource: Bool
    public let canModerate: Bool

    public init(canRead: Bool = true, canComment: Bool = false, canResolveAny: Bool = false, canEditSource: Bool = false, canModerate: Bool = false) {
        self.canRead = canRead
        self.canComment = canComment
        self.canResolveAny = canResolveAny
        self.canEditSource = canEditSource
        self.canModerate = canModerate
    }
}

public struct FileCommentList: Sendable, Equatable {
    public let fileId: String
    public let currentVersionId: String?
    public let permissions: FileCommentPermissions
    public let comments: [FileCommentRecord]
    public let nextCursor: String?
    public let hasMore: Bool
}

public struct FileCommentThread: Sendable, Equatable, Identifiable {
    public var id: String { root.id }
    public let root: FileCommentRecord
    public let replies: [FileCommentRecord]
    public let originVersionId: String
    public let originVersionNumber: Int?
    public let fromEarlierVersion: Bool
}

public func groupFileCommentThreads(
    _ comments: [FileCommentRecord],
    viewedVersionId: String?,
    isViewingLatest: Bool,
    includeEarlierUnresolved: Bool = true
) -> [FileCommentThread] {
    let roots = comments.filter(\.isRoot)
    let repliesByParent = Dictionary(grouping: comments.filter { !$0.isRoot }, by: { $0.parentCommentId ?? "" })
    return roots.compactMap { root in
        let onViewed = viewedVersionId != nil && root.fileVersionId == viewedVersionId
        let carryEarlier = isViewingLatest && includeEarlierUnresolved && !onViewed && !root.isResolved
        guard onViewed || carryEarlier else { return nil }
        return FileCommentThread(
            root: root,
            replies: repliesByParent[root.id] ?? [],
            originVersionId: root.fileVersionId,
            originVersionNumber: root.fileVersionNumber ?? root.anchor?.fileVersionNumber,
            fromEarlierVersion: !onViewed
        )
    }
}

public struct FileCommentDraft: Sendable, Equatable {
    public let key: String
    public let body: String
    public let clientRequestId: String
    public let fileVersionId: String?
    public let parentCommentId: String?
    public let anchor: HTMLCommentAnchor?

    public init(
        key: String,
        body: String,
        clientRequestId: String = UUID().uuidString.lowercased(),
        fileVersionId: String? = nil,
        parentCommentId: String? = nil,
        anchor: HTMLCommentAnchor? = nil
    ) {
        self.key = key
        self.body = body
        self.clientRequestId = clientRequestId
        self.fileVersionId = fileVersionId
        self.parentCommentId = parentCommentId
        self.anchor = anchor
    }
}

public struct FileCommentDraftStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func loadAll() -> [String: FileCommentDraft] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: FileCommentDraft] = [:]
        for (key, value) in raw {
            guard let row = value as? [String: Any], let body = row["body"] as? String else { continue }
            out[key] = FileCommentDraft(
                key: key,
                body: body,
                clientRequestId: (row["client_request_id"] as? String) ?? UUID().uuidString.lowercased(),
                fileVersionId: lowerUUID(row["file_version_id"] as? String),
                parentCommentId: lowerUUID(row["parent_comment_id"] as? String),
                anchor: HTMLCommentAnchor.parse(row["anchor"] as? [String: Any])
            )
        }
        return out
    }

    public func save(_ draft: FileCommentDraft) throws {
        var current: [String: Any] = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.removeValue(forKey: draft.key)
        } else {
            var row: [String: Any] = [
                "body": draft.body,
                "client_request_id": draft.clientRequestId,
            ]
            if let v = draft.fileVersionId { row["file_version_id"] = v }
            if let p = draft.parentCommentId { row["parent_comment_id"] = p }
            if let a = draft.anchor { row["anchor"] = a.toJSONObject() }
            current[draft.key] = row
        }
        try writeAtomically(current)
    }

    public func remove(_ key: String) throws {
        var current: [String: Any] = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        current.removeValue(forKey: key)
        if current.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try writeAtomically(current)
        }
    }

    private func writeAtomically(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
    }
}

extension TowerAPI {
    public func artefactHTMLPayload(workspaceId: String, appNpub: String, fileId: String, versionId: String? = nil) async throws -> HTMLArtefactPayload {
        var query: [URLQueryItem] = []
        if let versionId { query.append(URLQueryItem(name: "version_id", value: try Self.uuid(versionId))) }
        let o = try object(
            try await client.request(
                path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/html",
                query: query,
                appNpub: appNpub
            ),
            "HTML artefact"
        )
        guard o["workspace_id"] as? String == workspaceId,
              let source = o["source"] as? [String: Any], source["id"] as? String == fileId,
              source["type"] as? String == "html",
              let content = o["content"] as? [String: Any],
              let rawHtml = content["html"] as? String,
              let resolvedVersionId = lowerUUID(content["version_id"] as? String) else {
            throw TowerError.malformed("HTML artefact")
        }
        let html = try await hydratedArtefactHTML(rawHtml, content: content, workspaceId: workspaceId, appNpub: appNpub)
        let versions = ((o["versions"] as? [[String: Any]]) ?? []).compactMap { row -> HTMLArtefactVersion? in
            guard let id = lowerUUID(row["id"] as? String), let num = flexibleInt(row["version_number"]) else { return nil }
            return HTMLArtefactVersion(
                id: id,
                versionNumber: num,
                createdAt: (row["created_at"] as? String) ?? "",
                createdByActorNpub: row["created_by_actor_npub"] as? String,
                contentType: row["content_type"] as? String,
                sizeBytes: flexibleInt(row["size_bytes"])
            )
        }
        return HTMLArtefactPayload(
            fileId: fileId.lowercased(),
            versionId: resolvedVersionId,
            versionNumber: flexibleInt(content["version_number"]) ?? 1,
            currentVersionId: lowerUUID(content["current_version_id"] as? String),
            currentVersionNumber: flexibleInt(content["current_version_number"]),
            digest: (content["digest"] as? String) ?? "",
            html: html,
            versions: versions,
            manifestError: content["manifest_error"] as? String
        )
    }

    public func fileComments(
        workspaceId: String,
        appNpub: String,
        fileId: String,
        versionId: String? = nil,
        status: String? = nil,
        cursor: String? = nil,
        limit: Int = 200
    ) async throws -> FileCommentList {
        let expectedWorkspace = workspaceId.lowercased()
        let expectedFile = fileId.lowercased()
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        if let versionId { query.append(URLQueryItem(name: "version_id", value: try Self.uuid(versionId))) }
        if let status, !status.isEmpty { query.append(URLQueryItem(name: "status", value: status)) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }

        let o = try object(
            try await client.request(
                path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/comments",
                query: query,
                appNpub: appNpub
            ),
            "file comments"
        )
        guard lowerUUID(o["file_id"] as? String) == expectedFile else {
            throw TowerError.malformed("file comments file_id mismatch")
        }
        let permsObj = o["permissions"] as? [String: Any]
        let perms = FileCommentPermissions(
            canRead: (permsObj?["can_read"] as? Bool) ?? true,
            canComment: (permsObj?["can_comment"] as? Bool) == true,
            canResolveAny: (permsObj?["can_resolve_any"] as? Bool) == true,
            canEditSource: (permsObj?["can_edit_source"] as? Bool) == true,
            canModerate: (permsObj?["can_moderate"] as? Bool) == true
        )
        let rawList = (o["comments"] as? [[String: Any]]) ?? []
        var comments: [FileCommentRecord] = []
        comments.reserveCapacity(rawList.count)
        for row in rawList {
            guard let parsed = FileCommentRecord.parse(row),
                  parsed.workspaceId == expectedWorkspace,
                  parsed.fileId == expectedFile,
                  versionId == nil || parsed.fileVersionId == versionId?.lowercased() else {
                throw TowerError.malformed("file comment binding mismatch")
            }
            comments.append(parsed)
        }
        return FileCommentList(
            fileId: expectedFile,
            currentVersionId: lowerUUID(o["current_version_id"] as? String),
            permissions: perms,
            comments: comments,
            nextCursor: o["next_cursor"] as? String,
            hasMore: (o["has_more"] as? Bool) == true
        )
    }

    public func allFileComments(
        workspaceId: String,
        appNpub: String,
        fileId: String,
        versionId: String? = nil,
        status: String? = nil,
        maxPages: Int = 50
    ) async throws -> FileCommentList {
        var all: [FileCommentRecord] = []
        var seen: Set<String> = []
        var cursor: String? = nil
        var lastPage: FileCommentList? = nil
        for _ in 0..<maxPages {
            let page = try await fileComments(
                workspaceId: workspaceId,
                appNpub: appNpub,
                fileId: fileId,
                versionId: versionId,
                status: status,
                cursor: cursor,
                limit: 200
            )
            lastPage = page
            for item in page.comments where seen.insert(item.id).inserted {
                all.append(item)
            }
            guard page.hasMore, let next = page.nextCursor, !next.isEmpty, next != cursor else {
                return FileCommentList(
                    fileId: page.fileId,
                    currentVersionId: page.currentVersionId,
                    permissions: page.permissions,
                    comments: all,
                    nextCursor: nil,
                    hasMore: false
                )
            }
            cursor = next
        }
        let tail = lastPage ?? FileCommentList(fileId: fileId.lowercased(), currentVersionId: nil, permissions: FileCommentPermissions(), comments: [], nextCursor: nil, hasMore: false)
        return FileCommentList(
            fileId: tail.fileId,
            currentVersionId: tail.currentVersionId,
            permissions: tail.permissions,
            comments: all,
            nextCursor: tail.nextCursor,
            hasMore: tail.hasMore
        )
    }

    public func createFileComment(
        workspaceId: String,
        appNpub: String,
        fileId: String,
        body: String,
        fileVersionId: String? = nil,
        parentCommentId: String? = nil,
        anchor: HTMLCommentAnchor? = nil,
        clientRequestId: String = UUID().uuidString.lowercased()
    ) async throws -> FileCommentRecord {
        var payload: [String: Any] = [
            "body": body.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_request_id": clientRequestId,
        ]
        if let fileVersionId { payload["file_version_id"] = try Self.uuid(fileVersionId) }
        if let parentCommentId { payload["parent_comment_id"] = try Self.uuid(parentCommentId) }
        if let anchor { payload["anchor"] = anchor.toJSONObject() }
        let o = try object(
            try await client.request(
                method: "POST",
                path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/comments",
                appNpub: appNpub,
                jsonBody: rawJSON(payload)
            ),
            "create file comment"
        )
        guard let row = o["comment"] as? [String: Any], let parsed = FileCommentRecord.parse(row) else {
            throw TowerError.malformed("create file comment")
        }
        return parsed
    }

    public func updateFileComment(
        workspaceId: String,
        appNpub: String,
        fileId: String,
        commentId: String,
        rowVersion: Int,
        commentStatus: String? = nil,
        body: String? = nil
    ) async throws -> FileCommentRecord {
        var payload: [String: Any] = ["row_version": rowVersion]
        if let commentStatus { payload["comment_status"] = commentStatus }
        if let body { payload["body"] = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let o = try object(
            try await client.request(
                method: "PATCH",
                path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/comments/" + Self.uuid(commentId),
                appNpub: appNpub,
                jsonBody: rawJSON(payload)
            ),
            "update file comment"
        )
        guard let row = o["comment"] as? [String: Any], let parsed = FileCommentRecord.parse(row) else {
            throw TowerError.malformed("update file comment")
        }
        return parsed
    }

    public func deleteFileComment(
        workspaceId: String,
        appNpub: String,
        fileId: String,
        commentId: String,
        rowVersion: Int
    ) async throws {
        _ = try await client.request(
            method: "DELETE",
            path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/comments/" + Self.uuid(commentId),
            query: [URLQueryItem(name: "row_version", value: String(rowVersion))],
            appNpub: appNpub
        )
    }
}

extension WorkspaceSync {
    public func artefactHTMLPayload(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String, versionId: String? = nil) async throws -> HTMLArtefactPayload {
        try await identity.requireReader(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).artefactHTMLPayload(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: fileId, versionId: versionId)
    }

    public func allFileComments(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, fileId: String) async throws -> FileCommentList {
        try await identity.requireReader(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).allFileComments(workspaceId: workspace.id, appNpub: workspace.appNpub, fileId: fileId)
    }

    public func createFileComment(
        _ connection: ConnectionRecord,
        _ workspace: WorkspaceRecord,
        fileId: String,
        body: String,
        fileVersionId: String? = nil,
        parentCommentId: String? = nil,
        anchor: HTMLCommentAnchor? = nil,
        clientRequestId: String
    ) async throws -> FileCommentRecord {
        try await identity.requireSigner(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).createFileComment(
            workspaceId: workspace.id,
            appNpub: workspace.appNpub,
            fileId: fileId,
            body: body,
            fileVersionId: fileVersionId,
            parentCommentId: parentCommentId,
            anchor: anchor,
            clientRequestId: clientRequestId
        )
    }

    public func updateFileComment(
        _ connection: ConnectionRecord,
        _ workspace: WorkspaceRecord,
        fileId: String,
        commentId: String,
        rowVersion: Int,
        commentStatus: String? = nil,
        body: String? = nil
    ) async throws -> FileCommentRecord {
        try await identity.requireSigner(npub: connection.signerNpub)
        return try await api(origin: try TowerOrigin(connection.origin)).updateFileComment(
            workspaceId: workspace.id,
            appNpub: workspace.appNpub,
            fileId: fileId,
            commentId: commentId,
            rowVersion: rowVersion,
            commentStatus: commentStatus,
            body: body
        )
    }

    public func deleteFileComment(
        _ connection: ConnectionRecord,
        _ workspace: WorkspaceRecord,
        fileId: String,
        commentId: String,
        rowVersion: Int
    ) async throws {
        try await identity.requireSigner(npub: connection.signerNpub)
        try await api(origin: try TowerOrigin(connection.origin)).deleteFileComment(
            workspaceId: workspace.id,
            appNpub: workspace.appNpub,
            fileId: fileId,
            commentId: commentId,
            rowVersion: rowVersion
        )
    }
}
