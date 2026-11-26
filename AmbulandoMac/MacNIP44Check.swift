#if DEBUG
import AppKit
import WebKit
import AmbulandoCore

/// Real WKWebView bridge regression. Run only in the isolated Test bundle; no real keys, relay or user data.
extension MacThreadRegression {
    static func nip44Check(model: AppModel) async throws {
        try require(Bundle.main.bundleIdentifier == "studio.otherstuff.ambulando.mac.test", "NIP44 check requires isolated Test bundle")
        guard let store = model.store else { throw Failure(description: "No fixture store") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = IdentityService(vaultURL: directory.appendingPathComponent("vault.json"), secrets: MacRegressionVaultStore())
        try await identity.importIdentity(nsec: Bech32.encode(hrp: "nsec", data: Data(repeating: 0x43, count: 32)), pin: "123456")
        let own = try await identity.publicKeyHex()
        let initial = "[[\"g\",\"wss://test.invalid\"]]"
        let payload = try await identity.nip44(.encrypt(peer: own, plaintext: initial), expectedPublicKey: own)
        let fixture = try await identity.sign(NostrEventTemplate(kind: 10318, tags: [], content: payload))
        let encoded = String(decoding: try JSONEncoder().encode(fixture), as: UTF8.self)
        let browser = BrowserModel()
        await browser.configure(store: store, signer: { identity }, locked: false)
        let url = URL(string: "https://nip44.sample.invalid/")!
        browser.samplePage = (url, "<html><body>NIP44 synthetic private-service fixture</body></html>")
        browser.open(url)
        guard let tab = browser.selected, let broker = browser.broker else { throw Failure(description: "No test browser") }
        defer { browser.closeAll() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tab.webView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<100 {
            if tab.origin == "https://nip44.sample.invalid", (try? await tab.webView.evaluateJavaScript("typeof window.nostr?.nip44?.encrypt")) as? String == "function" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(tab.origin == "https://nip44.sample.invalid", "WebKit committed HTTPS fixture origin")
        // Approve through the production broker, never replace the JS API or native cipher.
        let approvals = Task { @MainActor in
            while !Task.isCancelled {
                if let prompt = broker.current { broker.resolve(prompt.id, .allow(remember: false)) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let script = """
        localStorage.setItem('ambulando.nip44.fixture', JSON.stringify(\(encoded)));
        window.fixture = JSON.parse(localStorage.getItem('ambulando.nip44.fixture'));
        const pub = await window.nostr.getPublicKey();
        const first = JSON.parse(await window.nostr.nip44.decrypt(pub, window.fixture.content));
        if (first[0][1] !== 'wss://test.invalid') throw Error('initial read');
        first.push(['g', 'wss://edited.invalid']);
        const content = await window.nostr.nip44.encrypt(pub, JSON.stringify(first));
        window.fixture = await window.nostr.signEvent({kind:10318, tags:[], content});
        localStorage.setItem('ambulando.nip44.fixture', JSON.stringify(window.fixture));
        window.fixture = JSON.parse(localStorage.getItem('ambulando.nip44.fixture'));
        const saved = JSON.parse(await window.nostr.nip44.decrypt(pub, window.fixture.content));
        if (saved.length !== 2 || saved[1][1] !== 'wss://edited.invalid') throw Error('readback');
        localStorage.removeItem('ambulando.nip44.fixture');
        return JSON.stringify(window.fixture);
        """
        let savedJSON: String
        do {
            savedJSON = try await tab.webView.callAsyncJavaScript(script, contentWorld: .page) as! String
            approvals.cancel()
        } catch { approvals.cancel(); throw error }
        let saved = try JSONDecoder().decode(NostrEvent.self, from: Data(savedJSON.utf8))
        try require(saved.kind == 10318 && saved.pubkey == own && SignatureVerifier.verify(saved), "actual JS API signed self-encrypted kind10318 edit/save/readback")
        print("NIP44_HOST_PASS synthetic kind10318 JS getPublicKey/decrypt/edit/encrypt/signEvent/save/readback; signed event verified; fixture only, no relay")

        // A frame can access the raw handler even without window.nostr. Native frameInfo must reject it.
        _ = try await tab.webView.evaluateJavaScript("""
        window.frameResult = null;
        window.addEventListener('message', e => { window.frameResult = e.data; });
        const frame = document.createElement('iframe');
        frame.srcdoc = `<script>
          parent.postMessage({injected: typeof window.nostr}, '*');
          window.webkit.messageHandlers.ambulandoNostr.postMessage({method:'getPublicKey', params:null})
            .then(() => parent.postMessage({bad:true}, '*'))
            .catch(e => parent.postMessage({error:String(e), injected:typeof window.nostr}, '*'));
        </script>`;
        document.body.append(frame);
        """)
        var frameResult: [String: Any] = [:]
        for _ in 0..<100 {
            frameResult = (try? await tab.webView.evaluateJavaScript("window.frameResult")) as? [String: Any] ?? [:]
            if frameResult["error"] != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try require(frameResult["injected"] as? String == "undefined" && (frameResult["error"] as? String)?.contains("top page") == true, "real WKWebView subframe rejected by native frameInfo")
        print("NIP44_FRAME_PASS subframe API absent and direct native handler call rejected")

        // Start a real JS request then commit a new document while its native sheet is pending.
        _ = try await tab.webView.evaluateJavaScript("window.nostr.nip44.encrypt('\(own)', 'pending').catch(() => {}); void 0")
        for _ in 0..<100 where broker.current == nil { try await Task.sleep(for: .milliseconds(20)) }
        try require(broker.current != nil, "real JS pending approval")
        let oldDocument = tab.documentId
        browser.load(url, in: tab)
        for _ in 0..<100 where tab.documentId == oldDocument { try await Task.sleep(for: .milliseconds(20)) }
        try require(tab.documentId != oldDocument && broker.current == nil, "real WebKit commit cancels previous document approval")
        print("NIP44_DOCUMENT_PASS actual navigation commit cancels pending request")

        // Persist through the production LocalStore writer and reconstruct a new browser host.
        var rememberedPrompts = 0
        let rememberApprovals = Task { @MainActor in
            while !Task.isCancelled {
                if let prompt = broker.current {
                    rememberedPrompts += 1
                    broker.resolve(prompt.id, .allow(remember: true))
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        do {
            let roundtrip = try await tab.webView.callAsyncJavaScript("""
            const encrypted = await window.nostr.nip44.encrypt('\(own)', 'remembered fixture');
            return await window.nostr.nip44.decrypt('\(own)', encrypted);
            """, contentWorld: .page)
            rememberApprovals.cancel()
            try require(roundtrip as? String == "remembered fixture" && rememberedPrompts == 2,
                        "encrypt and decrypt require independent explicit remembered approval")
        } catch { rememberApprovals.cancel(); throw error }
        await browser.flushPermissionWrites()
        let restored = BrowserModel()
        await restored.configure(store: store, signer: { identity }, locked: false)
        guard let restoredBroker = restored.broker else { throw Failure(description: "No restored broker") }
        let context = NIP07Context(tabId: UUID(), documentId: 1, origin: "https://nip44.sample.invalid")
        try require(restoredBroker.grants.count == 2, "LocalStore restored both operation grants")
        let result = await restoredBroker.handle(method: "nip44.encrypt", params: ["pubkey": own, "plaintext": "restored"],
                                                context: context, isCurrent: { true })
        guard case .success(.text(let restoredPayload)) = result else { throw Failure(description: "durable encrypt grant missing") }
        try require(restoredBroker.current == nil && restoredBroker.grants.count == 2, "LocalStore grant reconstruction")
        guard let encryption = restoredBroker.grants.first(where: { $0.hasSuffix("|nip44.encrypt") }) else {
            throw Failure(description: "No encryption grant")
        }
        restored.revoke(grant: encryption)
        await restored.flushPermissionWrites()
        let decrypted = await restoredBroker.handle(method: "nip44.decrypt", params: ["pubkey": own, "ciphertext": restoredPayload],
                                                   context: context, isCurrent: { true })
        try require(decrypted == .success(.text("restored")) && restoredBroker.grants.count == 1,
                    "revoking encrypt preserves separate decrypt authority")
        restored.forget(origin: context.origin)
        await restored.flushPermissionWrites()
        browser.forget(origin: context.origin)
        await browser.flushPermissionWrites()
        print("NIP44_CONSENT_PASS actual JS separate remembered encrypt/decrypt, LocalStore reconstruction, per-operation revoke, site reset")

        if ProcessInfo.processInfo.arguments.contains("-AmbulandoMacNIP44HostedCheck") {
            guard let address = ProcessInfo.processInfo.environment["AMBULANDO_NIP44_TEST_ORIGIN"],
                  let hostedURL = URL(string: address), let hostedOrigin = BrowserURLPolicy.origin(of: hostedURL) else {
                throw Failure(description: "Hosted check requires AMBULANDO_NIP44_TEST_ORIGIN with an HTTPS URL")
            }
            browser.load(hostedURL, in: tab)
            for _ in 0..<300 {
                if tab.origin == hostedOrigin, !tab.webView.isLoading { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(tab.origin == hostedOrigin, "hosted GitWorkshop root committed")
            let hostedApprovals = Task { @MainActor in
                while !Task.isCancelled {
                    if let prompt = broker.current { broker.resolve(prompt.id, .allow(remember: false)) }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { hostedApprovals.cancel() }
            let hostedJSON = try await tab.webView.callAsyncJavaScript(script, contentWorld: .page) as! String
            let hostedSaved = try JSONDecoder().decode(NostrEvent.self, from: Data(hostedJSON.utf8))
            try require(hostedSaved.kind == 10318 && hostedSaved.pubkey == own && SignatureVerifier.verify(hostedSaved), "hosted-origin synthetic fixture roundtrip")
            print("NIP44_HOSTED_API_PASS actual GitWorkshop HTTPS origin synthetic fixture JS read/edit/localStorage save/readback; not app relay persistence")
            _ = try await tab.webView.evaluateJavaScript("history.pushState({}, '', '/settings#private-git-services'); window.dispatchEvent(new PopStateEvent('popstate')); void 0")
            try await Task.sleep(for: .seconds(2))
            let hasSettings = (try? await tab.webView.evaluateJavaScript("document.getElementById('private-git-services') !== null")) as? Bool ?? false
            print("NIP44_HOSTED_ROUTE privateServicesSection=\(hasSettings); real app list and relay save not verified")
        }

    }
}
#endif
