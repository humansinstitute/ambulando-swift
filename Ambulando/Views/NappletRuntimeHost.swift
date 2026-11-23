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
    let manifest: NappletRuntimeManifest
    let html: String
    let authorize: () async throws -> Void
    let command: (NappletRuntimeRequest) async throws -> Data
    init(html: String, manifest: NappletRuntimeManifest, authorize: @escaping () async throws -> Void,
         command: @escaping (NappletRuntimeRequest) async throws -> Data) {
        self.html = html; self.manifest = manifest; self.authorize = authorize; self.command = command
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
    @discardableResult func receive(_ request: NappletRuntimeRequest) -> Bool {
        guard !closed, !busy, let page else { return false }
        if request.operation == "dirty" { dirty = request.dirty == true; return true }
        busy = true
        let epoch = generation
        deadline = Task { [weak self] in
            try? await Task.sleep(for:.seconds(45)); guard !Task.isCancelled else { return }
            self?.destroy("Operation could not be confirmed. Reopen before trying again.")
        }
        task = Task { [weak self, weak page] in
            guard let self, let page else { return }
            do {
                try await authorize()
                let result = try await command(request)
                try await authorize()
                guard !Task.isCancelled, !closed, generation == epoch, self.page === page else { return }
                // Canonical object result bytes retain scalar-distinct JSON object keys.
                let value = try GenericJSON.canonicalData(result)
                page.sendRuntime(["type":"wingman-napplet-result","version":3,"session":page.session,"requestId":request.id,"status":"ready"],result:value)
                if ["create","update","delete"].contains(request.operation) { dirty = false }
                busy = false; deadline?.cancel()
            } catch {
                guard !Task.isCancelled, !closed, generation == epoch, self.page === page else { return }
                // Revocation/offline checks clear the frame; a conflict can keep its current draft.
                do {
                    try await authorize()
                    guard !Task.isCancelled, !closed, generation == epoch else { return }
                    var code = "unavailable"
                    if case TowerError.http(let status,_,_) = error {
                        if status == 403 || status == 404 { destroy("Access was revoked or the napplet is unavailable."); return }
                        if status == 409 { code = "conflict" }
                    }
                    page.send(["type":"wingman-napplet-result","version":3,"session":page.session,"requestId":request.id,"status":"error","code":code,"message":code == "conflict" ? "A newer record revision exists. Refresh before saving." : "Operation could not be confirmed. No automatic retry was made."])
                    busy = false; deadline?.cancel()
                } catch { destroy("Access could not be verified. This runtime requires an online connection.") }
            }
        }
        return true
    }
}
