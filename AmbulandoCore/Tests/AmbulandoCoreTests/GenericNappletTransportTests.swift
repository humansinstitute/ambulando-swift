import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct GenericNappletTransportTests {
    func fixture(_ readOnly: Bool = false) async throws -> (FileNappletFixture, TowerAPI) {
        let f = FileNappletFixture()
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/generic-v2.json"))) as! [String:Any]
        f.codeOverride = "<script id=\"wingman-napplet-manifest\">" + String(decoding:try rawJSON(golden[readOnly ? "readonlyManifest" : "manifest"] as! [String:Any]),as:UTF8.self) + "</script>"
        var meta = golden["metadata"] as! [String:Any], napplet = meta["napplet"] as! [String:Any]
        napplet["bindings"] = ["entries":["file_id":f.dataId]]; meta["napplet"] = napplet
        meta["html_artifact"] = true; meta["artefact"] = ["schema_version":1,"type":"html","format_version":1,"editor_id":"builtin.html"]
        f.genericMetadata = meta; f.bytes = Data("{\"zero\":0,\"answered\":false,\"unanswered\":null}".utf8); f.topLevelWritable = true
        return (f,TowerAPI(client:TowerClient(origin:try TowerOrigin("https://tower.example"),transport:NappletFixtureTransport(fixture:f),signer:try await makeIdentity())))
    }
    @Test func arbitraryDomainCASAndExactUncertainReadback() async throws {
        for lost in [false,true] {
            let (f,api) = try await fixture(); f.lostResponse = lost
            let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
            let current = try await api.readGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code)
            let value = Data("{\"other-domain\":[false,0,null],\"optional\":{}}".utf8)
            let saved = try await api.saveGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code,base:current.versionId,bytes:value)
            #expect(saved.bytes == (try GenericJSON.canonicalData(value))); #expect(saved.versionId != current.versionId); #expect(f.posts == 1); #expect(f.createdFiles.isEmpty)
        }
    }
    @Test func staleAndRacedCASNeverRetries() async throws {
        for raced in [false,true] {
            let (f,api) = try await fixture()
            let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
            let current = try await api.readGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code)
            if raced { f.race = true } else { f.revision += 1 }
            await #expect(throws:FileNappletError.conflict) { try await api.saveGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code,base:current.versionId,bytes:Data("{}".utf8)) }
            #expect(f.posts == (raced ? 1 : 0))
        }
    }
    @Test func topLevelGrantAndDeclarationBothRequired() async throws {
        for mode in 0..<4 {
            let (f,api) = try await fixture(mode == 0)
            if mode == 1 { f.topLevelWritable = false }
            if mode == 2 { f.topLevelWritable = nil; f.writable = false } // explicit nested false when top absent
            let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
            if mode == 3 { f.topLevelWritable = "true" }
            await #expect(throws:(any Error).self) { try await api.saveGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code,base:f.version,bytes:Data("{}".utf8)) }
            #expect(f.posts == 0); #expect(f.uploaded == nil)
        }
    }
    @Test func explicitNestedGrantFallbackOnlyWhenTopAbsent() async throws {
        let (f,api) = try await fixture(); f.topLevelWritable = nil
        let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
        #expect(try await api.authorizeGenericNapplet(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code))
        f.topLevelWritable = false
        #expect(try await !api.authorizeGenericNapplet(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code))
        f.topLevelWritable = NSNull()
        await #expect(throws:(any Error).self) { try await api.authorizeGenericNapplet(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code) }
    }
    @Test func malformedDataAndChangedCodeOrPrivateACLFailClosed() async throws {
        for mode in 0..<7 {
            let (f,api) = try await fixture()
            let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
            switch mode {
            case 0: f.bytes = Data("{\"a\":1,\"a\":2}".utf8)
            case 1: f.corrupt = true
            case 2: f.participants = ["other"]
            case 3: f.channelKind = "project"
            case 4: f.channelWorkspace = Fixtures.scopeA
            case 5: f.codeOverride! += "<!-- revision -->"
            default: f.denied = true
            }
            await #expect(throws:(any Error).self) { try await api.readGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code) }
            #expect(f.posts == 0)
        }
    }
    @Test func sharedCodeUsesNormalACLWhilePrivateDataRemainsSelfOnly() async throws {
        let (f,api) = try await fixture(); f.genericSharedCode = true
        let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
        _ = try await api.readGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code)
        f.participants = ["someone-else"]
        await #expect(throws:(any Error).self) { try await api.readGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code) }
    }
    @Test func uploadAuthorityLossPreventsPublicationAndUncertainSaveDoesNotRetry() async throws {
        for mode in 0..<3 {
            let (f,api) = try await fixture()
            let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
            let base = f.version
            if mode == 0 { f.changeOnUpload = "data-permission" }
            if mode == 1 { f.changeOnUpload = "code" }
            if mode == 2 { f.acknowledgedWrongVersion = true; f.race = true }
            await #expect(throws:(any Error).self) { try await api.saveGenericJSON(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code,base:base,bytes:Data("{}".utf8)) }
            #expect(f.posts == (mode == 2 ? 1 : 0))
        }
    }
    @Test func codeRevisionPreservesDataAndChangesOnlyConsentFingerprint() async throws {
        let (f,api) = try await fixture()
        let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
        let oldBytes = f.bytes, oldVersion = f.version
        func receipt(_ code:GenericNappletCode) throws -> GenericNappletReceipt { try GenericNappletReceipt(baseURL:"https://tower.example",app:Fixtures.appNpub,workspace:Fixtures.workspaceId,viewer:TestKeys.npub,file:f.codeId,digest:code.sha256,binding:code.binding,canWrite:true) }
        f.codeOverride! += "<p>UI revision only</p>"; f.codeVersion = f.objectId
        let updated = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
        #expect(updated.binding == code.binding); #expect(try receipt(code).key == receipt(updated).key); #expect(try receipt(code).fingerprint != receipt(updated).fingerprint)
        #expect(f.bytes == oldBytes && f.version == oldVersion && f.posts == 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = GenericNappletTrustStore(directory:folder)
        try store.remember(receipt(code)); #expect(try store.contains(receipt(code))); #expect(try !store.contains(receipt(updated)))
        try store.remember(receipt(updated)); #expect(try store.contains(receipt(updated))); try store.forget(receipt(updated)); #expect(try !store.contains(receipt(updated)))
    }
    @Test func filePinProjectionPagesPastLegacyLauncherCapAndPartitionsIdentity() async throws {
        let h = try await WorkHarness.make()
        let pins = try (0..<550).map { index in
            try PinRecord(raw:rawJSON(["id":String(format:"00000000-0000-4000-8000-%012d",index),"workspace_id":h.workspace.id,"resource_type":"file","resource_id":UUID().uuidString.lowercased(),"pinned":true,"row_version":1]))
        }
        try await h.store.writer.upsertPins(connectionId:h.connection.id,workspaceId:h.workspace.id,pins,complete:true)
        var cursor = "", count = 0
        while true {
            let page = try await h.store.reader.genericFilePins(connectionId:h.connection.id,workspaceId:h.workspace.id,after:cursor)
            #expect(page.count <= 200); count += page.count
            guard let last = page.last else { break }; cursor = last.id
        }
        #expect(count == 550)
        #expect(try await h.store.reader.genericFilePins(connectionId:"other",workspaceId:h.workspace.id).isEmpty)
        #expect(try await h.store.reader.genericFilePinsRevision(connectionId:h.connection.id,workspaceId:h.workspace.id) == 550)
    }

}
