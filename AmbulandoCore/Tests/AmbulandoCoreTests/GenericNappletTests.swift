import XCTest
@testable import AmbulandoCore

final class GenericNappletTests: XCTestCase {
    func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/generic-v2.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    func binding(_ manifest: Any, _ metadata: Any) throws -> GenericNappletBinding {
        let html = "<script id=\"wingman-napplet-manifest\" type=\"application/json\">" + String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self) + "</script>"
        guard let result = try GenericNappletBinding.parse(html:html,metadata:JSONSerialization.data(withJSONObject:metadata)) else { throw FileNappletError.invalid }; return result
    }
    func testFrozenPortableVectors() throws {
        let f = try fixture(), b = try binding(f["manifest"]!, f["metadata"]!)
        for row in f["canonical"] as! [[String: Any]] {
            let data = try GenericJSON.canonical(row["value"]!)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), row["canonical"] as? String)
            XCTAssertEqual(SHA256Hex.of(data), row["sha256"] as? String)
        }
        for s in f["invalidJson"] as! [String] { XCTAssertThrowsError(try GenericJSON.decode(Data(s.utf8)), s) }
        for row in f["requests"] as! [[String: Any]] {
            let result = try? GenericNappletRequest.parse(JSONSerialization.data(withJSONObject: row["value"]!), session: "0123456789abcdef0123456789abcdef", binding: b)
            XCTAssertEqual(result != nil, row["valid"] as? Bool, row["label"] as! String)
        }
        for (manifest, canWrite, vector) in [("manifest",true,"receipt"),("readonlyManifest",true,"receiptReadonly"),("manifest",false,"receiptNoWrite")] {
            let binding = try binding(f[manifest]!, f["metadata"]!), c = f["context"] as! [String: String]
            let r = try GenericNappletReceipt(baseURL: c["baseUrl"]!, tower:c["tower"]!, service:c["service"]!, app:c["appNpub"]!, workspace:c["workspaceId"]!, viewer:c["viewer"]!, file:f["codeFileId"] as! String, digest:f["digest"] as! String, binding:binding, canWrite:canWrite)
            let expected = f[vector] as! [String: Any]; XCTAssertEqual(r.key, expected["key"] as? String); XCTAssertEqual(r.fingerprint, expected["fingerprint"] as? String)
        }
        let ro = try binding(f["readonlyManifest"]!, f["metadata"]!)
        let save = (f["readonlySaveRejection"] as! [String: Any])["request"]!
        XCTAssertThrowsError(try GenericNappletRequest.parse(JSONSerialization.data(withJSONObject: save), session:"0123456789abcdef0123456789abcdef", binding:ro))
        for row in f["invalidManifests"] as? [[String:Any]] ?? [] {
            XCTAssertThrowsError(try binding(row["manifest"]!,row["metadata"]!))
        }
        for row in f["invalidManifestHtml"] as? [[String:Any]] ?? [] {
            XCTAssertThrowsError(try GenericNappletBinding.parse(html:row["html"] as! String,metadata:JSONSerialization.data(withJSONObject:row["metadata"]!)))
        }
        let aggregate = try binding(f["aggregateManifest"]!, f["aggregateMetadata"]!)
        XCTAssertEqual(aggregate.capability, "workspace-aggregate")
    }
    func testLimitsAndStrictDecoding() throws {
        XCTAssertNoThrow(try GenericJSON.decode(Data("{\"s\":\"\(String(repeating:"a",count:65536))\"}".utf8)))
        XCTAssertThrowsError(try GenericJSON.decode(Data("{\"s\":\"\(String(repeating:"a",count:65537))\"}".utf8)))
        for count in [32,33] {
            let data = Data((String(repeating:"{\"x\":", count:count-1) + "{}" + String(repeating:"}",count:count-1)).utf8)
            XCTAssertEqual((try? GenericJSON.decode(data)) != nil, count == 32)
        }
        for count in [49998,49999] {
            let data = Data(("{\"a\":[" + Array(repeating:"null",count:count).joined(separator:",") + "]}").utf8)
            XCTAssertEqual((try? GenericJSON.decode(data)) != nil, count == 49998)
        }
        for bytes: [UInt8] in [[0xc0,0x80],[0xed,0xa0,0x80],[0xf4,0x90,0x80,0x80],[0xef,0xbb,0xbf,123,125]] { XCTAssertThrowsError(try GenericJSON.decode(Data(bytes))) }
        XCTAssertThrowsError(try GenericJSON.decode(Data("{\"a\":{\"x\":1,\"x\":2}}".utf8)))
    }
}

extension GenericNappletTests {
    func testScalarDistinctKeysSurviveCanonicalStorageAndSaveEnvelope() throws {
        let raw = Data("{\"é\":1,\"e\\u0301\":2}".utf8)
        XCTAssertEqual(String(decoding:try GenericJSON.canonicalData(raw),as:UTF8.self),"{\"e\u{0301}\":2,\"é\":1}")
        let f = try fixture(), b = try binding(f["manifest"]!,f["metadata"]!)
        let envelope = "{\"type\":\"wingman-napplet-data\",\"version\":2,\"session\":\"0123456789abcdef0123456789abcdef\",\"requestId\":\"s\",\"operation\":\"save\",\"binding\":\"entries\",\"baseVersionId\":\"11111111-1111-4111-8111-111111111111\",\"value\":" + String(decoding:raw,as:UTF8.self) + "}"
        let request = try GenericNappletRequest.parse(Data(envelope.utf8),session:"0123456789abcdef0123456789abcdef",binding:b)
        XCTAssertEqual(request.value,try GenericJSON.canonicalData(raw))
    }
    func testManifestTypeAndAttributeStrictnessAndSupportedLinks() throws {
        let f = try fixture(), manifest = f["manifest"] as! [String:Any], metadata = try rawJSON(f["metadata"] as! [String:Any])
        let json = String(decoding:try rawJSON(manifest),as:UTF8.self)
        XCTAssertThrowsError(try GenericNappletBinding.parse(html:"<script id=\"wingman-napplet-manifest\">\(json)</script><script id=\"wingman-napplet-manifest\">\(json)</script>",metadata:Data("{}".utf8)))
        for attr in ["data-id=\"wingman-napplet-manifest\"", "title=\" id='wingman-napplet-manifest'\""] {
            XCTAssertThrowsError(try GenericNappletBinding.parse(html:"<script \(attr)>\(json)</script>",metadata:metadata))
        }
        for value:Any in [NSNull(),true,["portable-example"],1] {
            var m = manifest; m["app_id"] = value
            XCTAssertThrowsError(try binding(m,f["metadata"]!))
        }
        let id = f["codeFileId"] as! String, w = (f["context"] as! [String:String])["workspaceId"]!
        XCTAssertEqual(try GenericNappletFileLink.parse("https://example.test/flight-deck?workspaceid=\(w)&nappletFile=\(id)",origin:"https://example.test",workspace:w),id)
        for link in ["https://evil.test/flight-deck?workspaceid=\(w)&nappletFile=\(id)","https://example.test/flight-deck?workspaceid=wrong&nappletFile=\(id)","https://example.test/flight-deck?workspaceid=\(w)&nappletFile=\(id)&nappletFile=\(id)"] {
            XCTAssertThrowsError(try GenericNappletFileLink.parse(link,origin:"https://example.test",workspace:w))
        }
    }
    func testDeepValueHasIndependentEnvelopeBudget() throws {
        let f = try fixture(), b = try binding(f["manifest"]!,f["metadata"]!)
        let value = String(repeating:"{\"x\":",count:31) + "{}" + String(repeating:"}",count:31)
        let request = "{\"type\":\"wingman-napplet-data\",\"version\":2,\"session\":\"0123456789abcdef0123456789abcdef\",\"requestId\":\"s\",\"operation\":\"save\",\"binding\":\"entries\",\"baseVersionId\":\"11111111-1111-4111-8111-111111111111\",\"value\":\(value)}"
        XCTAssertNoThrow(try GenericNappletRequest.parse(Data(request.utf8),session:"0123456789abcdef0123456789abcdef",binding:b))
    }
}
