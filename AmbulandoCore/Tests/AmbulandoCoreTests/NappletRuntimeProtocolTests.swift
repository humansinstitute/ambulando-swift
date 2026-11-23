import XCTest
@testable import AmbulandoCore

final class NappletRuntimeProtocolTests: XCTestCase {
    let session = "0123456789abcdef0123456789abcdef"
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/napplet-runtime-v3/" + name + ".json"))
    }
    func manifest(_ change: ([String:Any]) -> [String:Any] = { $0 }) throws -> NappletRuntimeManifest {
        try .parse(JSONSerialization.data(withJSONObject:change(try JSONSerialization.jsonObject(with:fixture("manifest")) as! [String:Any])))
    }
    func testSharedManifestAndRequests() throws {
        XCTAssertEqual(SHA256Hex.of(try fixture("manifest")),"8197cc564c09eeb7dcea88fb9d712a12e999794ec25dcdf7993c7cd96c5acd8b")
        XCTAssertEqual(SHA256Hex.of(try fixture("requests")),"eed9f86e102039b2bf43ce5aad3d39e43309d7001bb378ac763e012c6c1f7135")
        let m = try manifest(); XCTAssertEqual(m.id,"field-notes"); XCTAssertNil(m.unsupportedReason)
        let html = "<script id='wingman-napplet-manifest' type='application/json'>" + String(decoding:try fixture("manifest"),as:UTF8.self) + "</script>"
        XCTAssertEqual(try NappletRuntimeManifest.parse(html:html),m)
        XCTAssertThrowsError(try NappletRuntimeManifest.parse(html:html + html))
        XCTAssertThrowsError(try NappletRuntimeManifest.parse(html:"<script data-id='wingman-napplet-manifest'>{}</script>"))
        let rows = try JSONSerialization.jsonObject(with:fixture("requests")) as! [[String:Any]]
        for row in rows {
            let data = try JSONSerialization.data(withJSONObject:row)
            let r = try NappletRuntimeRequest.parse(data,session:session,manifest:m)
            XCTAssertEqual(r.operation,row["operation"] as? String)
            XCTAssertThrowsError(try NappletRuntimeRequest.parse(data,session:String(repeating:"a",count:32),manifest:m))
            var forged = row; forged["workspace_id"] = "foreign"
            XCTAssertThrowsError(try NappletRuntimeRequest.parse(JSONSerialization.data(withJSONObject:forged),session:session,manifest:m))
        }
    }
    func testAccessSubsetExcludesCodeAndTitleButIncludesSchemaAndScope() throws {
        let m = try manifest()
        let renamed = try manifest { var o=$0; o["title"]="Renamed"; o["bundle_version"]="2"; return o }
        XCTAssertTrue(m.permits(renamed))
        for field in ["scope","schema_version","operations"] {
            let changed = try manifest { var o=$0; var cs=o["collections"] as! [String:Any]; var c=cs["team_notes"] as! [String:Any]
                c[field] = field == "scope" ? "personal" : field == "schema_version" ? 2 : ["list","get","delete"] as Any
                cs["team_notes"]=c; o["collections"]=cs; return o }
            XCTAssertFalse(m.permits(changed))
        }
        let dm = try manifest { var o=$0; o["capabilities"]=["nostr-dm":["version":1,"resources":["wss://relay.example"],"operations":["read","decrypt"]]]; return o }
        XCTAssertNotNil(dm.unsupportedReason); XCTAssertFalse(m.permits(dm))
        let newer = try manifest { var o=$0; o["runtime"]=["protocol":3,"min_host":4]; return o }
        XCTAssertNotNil(newer.unsupportedReason)
    }
    func testPersonalCapabilityOperationsResourcesAndVersionsAreSeparate() throws {
        func dm(_ operations: [String], resources: [String] = ["wss://relay.example"], version: Int = 1) throws -> NappletRuntimeManifest {
            try manifest { var o=$0; o["capabilities"]=["nostr-dm":["version":version,"resources":resources,"operations":operations]]; return o }
        }
        let approved = try dm(["read","decrypt"])
        XCTAssertTrue(approved.permits(try dm(["read"])))
        for operation in ["send","persist","agent"] { XCTAssertFalse(approved.permits(try dm(["read",operation]))) }
        XCTAssertFalse(approved.permits(try dm(["read"],resources:["wss://other.example"])))
        XCTAssertFalse(approved.permits(try dm(["read"],version:2)))
        XCTAssertNotNil(approved.unsupportedReason)
    }
    func testMalformedAndUnboundedRequestsRejected() throws {
        let m = try manifest()
        let rows = try JSONSerialization.jsonObject(with:fixture("requests")) as! [[String:Any]]
        for patch: [String:Any] in [["limit":101],["limit":true],["limit":1.5],["cursor":""],["cursor":String(repeating:"x",count:2049)],["collection":"undeclared"]] {
            var row=rows[0]; row.merge(patch,uniquingKeysWith: { _,new in new })
            XCTAssertThrowsError(try NappletRuntimeRequest.parse(JSONSerialization.data(withJSONObject:row),session:session,manifest:m))
        }
        for patch: [String:Any] in [["base_revision":0],["base_revision":true],["base_revision":1.5],["value":[]],["record_id":"../escape"]] {
            var row=rows[3]; row.merge(patch,uniquingKeysWith: { _,new in new })
            XCTAssertThrowsError(try NappletRuntimeRequest.parse(JSONSerialization.data(withJSONObject:row),session:session,manifest:m))
        }
        XCTAssertThrowsError(try NappletRuntimeManifest.parse(Data("{\"version\":3,\"version\":3}".utf8)))
    }
}
