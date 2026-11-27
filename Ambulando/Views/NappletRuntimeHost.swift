import AmbulandoCore
import SwiftUI

/// The view supplies Sync commands; the sandbox never receives a signer or a network client.
@MainActor @Observable
final class NappletRuntimeHost {
    private(set) var page: NappletPage?
    private(set) var dirty = false
    private(set) var busy = false
    private(set) var failure: String?
    private var generation = UUID()
    private var closed = false
    private var task: Task<Void,Never>?
    private var deadline: Task<Void,Never>?
    private var observedReads: [String: (NappletRuntimeRequest, Data)] = [:]
    let manifest: NappletRuntimeManifest
    let html: String
    let authorize: () async throws -> Void
    let cachedRead: (NappletRuntimeRequest) async -> Data?
    let command: (NappletRuntimeRequest) async throws -> Data
    init(html: String, manifest: NappletRuntimeManifest, authorize: @escaping () async throws -> Void,
         cachedRead: @escaping (NappletRuntimeRequest) async -> Data? = { _ in nil },
         command: @escaping (NappletRuntimeRequest) async throws -> Data) {
        self.html = html; self.manifest = manifest; self.authorize = authorize; self.cachedRead = cachedRead; self.command = command
    }
    func open() {
        guard !closed else { return }
        if let reason = manifest.unsupportedReason { failure = reason; return }
        let p = NappletPage(html:html,manifest:manifest) { [weak self] in self?.receive($0) ?? false }
        p.didFail = { [weak self] reason in self?.destroy(reason) }
        page = p; p.visible = true; p.install()
    }
    func destroy(_ reason: String? = nil) {
        closed = true; generation = UUID(); task?.cancel(); deadline?.cancel(); task = nil; deadline = nil
        page?.destroy(); page = nil; dirty = false; busy = false; failure = reason
    }
    func refreshReads() async throws -> Bool {
        guard !closed, !dirty, !busy else { return false }
        let expected = generation
        var changed = false
        for (_, pair) in observedReads {
            try await authorize()
            let bytes = try await command(pair.0)
            guard !closed, !dirty, !busy, generation == expected else { return false }
            changed = changed || bytes != pair.1
        }
        return changed
    }
    @discardableResult func receive(_ request: NappletRuntimeRequest) -> Bool {
        guard !closed, !busy, let page else { return false }
        if request.operation == "dirty" { dirty = request.dirty == true; return true }
        busy = true
        let epoch = generation
        deadline = Task { [weak self] in
            try? await Task.sleep(for:.seconds(45)); guard !Task.isCancelled else { return }
            guard let self else { return }
            task?.cancel(); busy = false
            page.send(["type":"wingman-napplet-result","version":3,"session":page.session,"requestId":request.id,"status":"error","code":"unavailable","message":"Operation could not be confirmed. No automatic retry was made."])
        }
        task = Task { [weak self, weak page] in
            guard let self, let page else { return }
            do {
                let result: Data
                if let cached = await cachedRead(request) { result = cached }
                else {
                    try await authorize()
                    result = try await command(request)
                    try await authorize()
                }
                guard !Task.isCancelled, !closed, generation == epoch, self.page === page else { return }
                // Canonical object result bytes retain scalar-distinct JSON object keys.
                let value = try GenericJSON.canonicalData(result)
                page.sendRuntime(["type":"wingman-napplet-result","version":3,"session":page.session,"requestId":request.id,"status":"ready"],result:value)
                if ["list", "get"].contains(request.operation) {
                    let key = [request.operation, request.collection ?? "", request.record ?? "", String(request.limit ?? 0), request.cursor ?? ""].joined(separator: "|")
                    observedReads[key] = (request, value)
                }
                if ["create","update","delete"].contains(request.operation) { dirty = false }
                busy = false; deadline?.cancel()
            } catch {
                guard !Task.isCancelled, !closed, generation == epoch, self.page === page else { return }
                if CachedContentFailure.invalidates(error) { destroy("Access was revoked or the napplet is unavailable."); return }
                var code = "unavailable"
                if case TowerError.http(let status,_,_) = error, status == 409 { code = "conflict" }
                page.send(["type":"wingman-napplet-result","version":3,"session":page.session,"requestId":request.id,"status":"error","code":code,"message":code == "conflict" ? "A newer record revision exists. Refresh before saving." : "Operation could not be confirmed. No automatic retry was made."])
                busy = false; deadline?.cancel()
            }
        }
        return true
    }
}
