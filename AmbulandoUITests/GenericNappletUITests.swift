import XCTest

@MainActor final class GenericNappletUITests:XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testUnknownAppsInstallSaveReopenAndCodeRevisionWithUnchangedRuntime() throws {
        let run = UUID().uuidString.lowercased()
        var files:[[String:Any]] = [], codeIDs:[String] = []
        for index in 0..<2 {
            let id = UUID().uuidString.lowercased(), dataID = UUID().uuidString.lowercased()
            let appID = "app-" + UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(), binding = "b_" + String(UUID().uuidString.prefix(8)).lowercased()
            let manifest:[String:Any] = ["version":2,"app_id":appID,"title":"Synthetic app \(index + 1)","icon":"🌱","bindings":[binding:["capability":"private-json-file","version":1,"operations":["read","save"]]]]
            let json = String(decoding:try JSONSerialization.data(withJSONObject:manifest),as:UTF8.self)
            let html = """
            <meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:16px system-ui;padding:16px}button,input{font:inherit;padding:12px;max-width:100%;box-sizing:border-box}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style>
            <script id="wingman-napplet-manifest" type="application/json">\(json)</script><h1>Initial UI \(index + 1)</h1><label>Entry<input id="entry" value="synthetic"></label><button id="save">Save</button><p id="state">Loading</p><pre id="value"></pre>
            <script>let base;let n=0;const send=(op,x={})=>parent.postMessage({type:'wingman-napplet-data',version:2,session:window.nappletSession,requestId:'r'+(++n),operation:op,binding:'\(binding)',...x},'*');
            addEventListener('message',e=>{const d=e.data;if(e.source===parent&&d?.type==='wingman-napplet-result'&&d.session===window.nappletSession){document.getElementById('state').textContent=d.status;if(d.status==='ready'){base=d.baseVersionId;document.getElementById('value').textContent=JSON.stringify(d.value);}}});
            document.getElementById('save').onclick=()=>send('save',{baseVersionId:base,value:{zero:0,answered:false,entry:document.getElementById('entry').value,marker:'\(appID)'}});send('read');</script>
            """
            let metadata:[String:Any] = ["html_artifact":true,"artefact":["schema_version":1,"type":"html","format_version":1,"editor_id":"builtin.html"],"napplet":["version":2,"app_id":appID,"bindings":[binding:["file_id":dataID]]]]
            for (fileID,mime,text,meta) in [(id,"text/html",html,metadata),(dataID,"application/json","{}",[:])] {
                let head = UUID().uuidString.lowercased()
                files.append(["id":fileID,"content_type":mime,"display_name":"Synthetic app \(index + 1)","text":text,"head":head,"history":[head:text],"metadata":meta])
            }
            codeIDs.append(id)
        }
        func seed() throws -> String { try JSONSerialization.data(withJSONObject:["runID":run,"files":files,"pins":[]]).base64EncodedString() }
        let app = XCUIApplication()
        func launch(reset:Bool = false,update:Bool = false) throws {
            app.launchArguments = ["-AmbulandoUITestFixture","-AmbulandoGenericSeed",try seed()] + (reset ? ["-AmbulandoFixtureReset"] : []) + (update ? ["-AmbulandoGenericApplyCode"] : [])
            app.launch(); XCTAssertTrue(app.buttons["channel.general"].waitForExistence(timeout:20),app.debugDescription); app.section("Toolbox")
        }
        try launch(reset:true)
        // Fixture workspace identity comes from the live native sample connection, not a network account.
        // Use UUID fallback in the picker so the test does not assume a workspace identifier.
        for id in codeIDs {
            XCTAssertTrue(app.buttons["generic.add"].waitForExistence(timeout:15)); app.buttons["generic.add"].tap()
            let input = app.textFields["generic.file-link"]; XCTAssertTrue(input.waitForExistence(timeout:10)); input.tap(); input.typeText(id)
            app.buttons["generic.verify"].tap(); XCTAssertTrue(app.buttons["generic.install"].waitForExistence(timeout:15)); app.buttons["generic.install"].tap()
            XCTAssertTrue(app.buttons["generic.app.\(id)"].waitForExistence(timeout:15),app.debugDescription)
        }
        func open(_ id:String,approve:Bool) {
            app.buttons["generic.app.\(id)"].tap()
            XCTAssertFalse(app.textFields["generic.file-link"].exists,"Opening an app must not present the Add sheet")
            let selected = codeIDs.firstIndex(of:id)! + 1
            XCTAssertTrue(app.navigationBars["Synthetic app \(selected)"].waitForExistence(timeout:15),"Only the selected app route should open")
            if approve { XCTAssertTrue(app.buttons["generic.approve"].waitForExistence(timeout:15)); XCTAssertTrue(app.buttons["generic.approve"].isHittable,app.debugDescription); app.buttons["generic.approve"].tap() }
            XCTAssertTrue(app.buttons["generic.menu"].waitForExistence(timeout:15)); XCTAssertTrue(app.webViews.buttons["Save"].waitForExistence(timeout:15),app.debugDescription)
            XCTAssertTrue(app.webViews.staticTexts["ready"].waitForExistence(timeout:15),app.debugDescription)
        }
        func close() { app.buttons["generic.menu"].tap(); app.buttons["Close"].tap(); XCTAssertTrue(app.buttons["generic.add"].waitForExistence(timeout:10),"Close must pop the single selected app to Apps, without exposing another app route") }
        for (index,id) in codeIDs.enumerated() {
            open(id,approve:true)
            app.webViews.buttons["Save"].tap()
            XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","\"answered\":false")).firstMatch.waitForExistence(timeout:15),app.debugDescription)
            let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "generic-iphone-app-\(index + 1)-saved"; shot.lifetime = .keepAlways; add(shot)
            close(); open(id,approve:false); XCTAssertFalse(app.buttons["generic.approve"].exists); close()
        }
        app.terminate()
        let old = files[0]["text"] as! String, changed = old.replacingOccurrences(of:"Initial UI",with:"Updated UI"), head = UUID().uuidString.lowercased()
        var history = files[0]["history"] as! [String:String]; history[head] = changed
        files[0]["text"] = changed; files[0]["head"] = head; files[0]["history"] = history
        try launch(update:true); open(codeIDs[0],approve:true)
        XCTAssertTrue(app.webViews.staticTexts["Updated UI 1"].waitForExistence(timeout:15))
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","\"answered\":false")).firstMatch.waitForExistence(timeout:15),app.debugDescription)
        close(); open(codeIDs[0],approve:false); XCTAssertFalse(app.buttons["generic.approve"].exists)
    }
}
