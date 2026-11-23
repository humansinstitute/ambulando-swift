import XCTest

@MainActor final class NappletRuntimeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testPostBuildCartridgesSaveAndCodeUpdateRetainsDataWithoutReconsent() throws {
        let run = UUID().uuidString.lowercased()
        var cartridges: [[String:Any]] = []
        for index in 1...2 {
            let id = "cartridge-" + UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            let collection = "c_" + UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            func html(_ version: String, _ title: String) throws -> String {
                let manifest: [String:Any] = ["version":3,"napplet_id":id,"bundle_version":version,"title":title,"icon":"🌱","runtime":["protocol":3,"min_host":3],"collections":[collection:["scope":"personal","schema_version":1,"operations":["list","get","create","update"]]],"capabilities":[:]]
                let json = String(decoding:try JSONSerialization.data(withJSONObject:manifest),as:UTF8.self)
                return """
                <meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:18px system-ui;padding:16px;overflow-wrap:anywhere}button{font:inherit;padding:12px}pre{white-space:pre-wrap}</style>
                <script id="wingman-napplet-manifest" type="application/json">\(json)</script><h1>\(title)</h1><button id="save" disabled>Save</button><p id="state">Loading</p><pre id="value"></pre><script>
                let n=0;const send=(operation,x)=>parent.postMessage({type:'wingman-napplet-data',version:3,session:window.nappletSession,requestId:'r'+(++n),operation,collection:'\(collection)',...x},'*');
                addEventListener('message',e=>{const d=e.data;if(e.source===parent&&d?.type==='wingman-napplet-result'&&d.session===window.nappletSession){document.getElementById('state').textContent=d.status;document.getElementById('value').textContent=JSON.stringify(d.result);document.getElementById('save').disabled=d.status!=='ready';}});
                document.getElementById('save').onclick=()=>send('create',{record_id:'entry',base_revision:0,value:{answered:false,zero:0,unanswered:null,marker:'\(id)'}});send('list',{limit:20,cursor:null});</script>
                """
            }
            cartridges.append(["id":id,"collection":collection,"collectionID":UUID().uuidString.lowercased(),"file":UUID().uuidString.lowercased(),"version":UUID().uuidString.lowercased(),"updateVersion":UUID().uuidString.lowercased(),"html":try html("1","Runtime app \(index)"),"updated":try html("2","Updated runtime app \(index)"),"history":[]])
        }
        let app = XCUIApplication()
        func launch(reset: Bool = false, update: Bool = false) throws {
            let seed = try JSONSerialization.data(withJSONObject:["runID":run,"apps":cartridges]).base64EncodedString()
            app.launchArguments = ["-AmbulandoUITestFixture","-AmbulandoRuntimeSeed",seed] + (reset ? ["-AmbulandoFixtureReset"] : []) + (update ? ["-AmbulandoRuntimeApplyCode"] : [])
            app.launch(); XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout:20),app.debugDescription); app.section("Toolbox")
        }
        func open(_ id: String, approve: Bool) {
            XCTAssertTrue(app.buttons["runtime.app." + id].waitForExistence(timeout:15),app.debugDescription)
            app.buttons["runtime.app." + id].tap()
            if approve { XCTAssertTrue(app.buttons["runtime.approve"].waitForExistence(timeout:15),app.debugDescription); app.buttons["runtime.approve"].tap() }
            XCTAssertTrue(app.webViews.staticTexts["ready"].waitForExistence(timeout:20),app.debugDescription)
            XCTAssertFalse(app.buttons["runtime.approve"].exists)
        }
        func close() {
            app.navigationBars.buttons["Close"].tap()
            XCTAssertTrue(app.buttons["runtime.app." + (cartridges[0]["id"] as! String)].waitForExistence(timeout:10),app.debugDescription)
        }
        try launch(reset:true)
        for (i,cartridge) in cartridges.enumerated() {
            open(cartridge["id"] as! String,approve:true)
            app.webViews.buttons["Save"].tap()
            XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","\"answered\":false")).firstMatch.waitForExistence(timeout:15),app.debugDescription)
            let image = XCTAttachment(screenshot:app.screenshot()); image.name = "runtime-iphone-app-\(i + 1)-saved"; image.lifetime = .keepAlways; add(image)
            close()
        }
        app.terminate(); cartridges[0]["activeUpdate"] = true
        try launch(update:true)
        open(cartridges[0]["id"] as! String,approve:false)
        XCTAssertTrue(app.webViews.staticTexts["Updated runtime app 1"].exists)
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","\"answered\":false")).firstMatch.waitForExistence(timeout:15),app.debugDescription)
        let image = XCTAttachment(screenshot:app.screenshot()); image.name = "runtime-iphone-updated-retained-data"; image.lifetime = .keepAlways; add(image)
        close(); open(cartridges[1]["id"] as! String,approve:false)
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","\"zero\":0")).firstMatch.waitForExistence(timeout:15),app.debugDescription)
    }
}
