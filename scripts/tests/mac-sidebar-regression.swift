// First run scripts/test-app.py mac; this defaults to the dedicated Ambulando Test process.
// swift scripts/tests/mac-sidebar-regression.swift [test-pid]
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func find(_ element: AXUIElement, _ identifier: String, depth: Int = 0) -> AXUIElement? {
    if attribute(element, "AXIdentifier") as? String == identifier { return element }
    guard depth < 60 else { return nil }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let match = find(child, identifier, depth: depth + 1) { return match }
    }
    return nil
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
require(CommandLine.arguments.count <= 2, "Use [test-pid], or launch scripts/test-app.py mac first")
let testBundle = "studio.otherstuff.ambulando.mac.test"
let target: NSRunningApplication?
if CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) {
    target = NSRunningApplication(processIdentifier: pid)
} else {
    target = NSRunningApplication.runningApplications(withBundleIdentifier: testBundle).first
}
guard let target, target.bundleIdentifier == testBundle else {
    fatalError("Refusing non-Test app. Launch scripts/test-app.py mac first")
}
let app = AXUIElementCreateApplication(target.processIdentifier)
func window() -> AXUIElement {
    guard let result = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { fatalError("App stopped responding or has no window") }
    return result
}
func item(_ id: String) -> AXUIElement {
    for _ in 0..<100 {
        if let result = find(window(), id) { return result }
        usleep(100_000)
    }
    fatalError("Missing \(id)")
}
func press(_ id: String) {
    require(AXUIElementPerformAction(item(id), kAXPressAction as CFString) == .success, "Cannot press \(id)")
    usleep(100_000)
}
func resize(_ index: Int) {
    var size = CGSize(width: index % 2 == 0 ? 900 : 1440, height: index % 2 == 0 ? 600 : 900)
    require(AXUIElementSetAttributeValue(window(), kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!) == .success, "Cannot resize")
    usleep(100_000)
}
let banner = attribute(item("fixture.banner"), kAXValueAttribute) as? String ?? ""
require(banner.contains("Sample data"), "Refusing to operate on an app without the sample-data banner")
press("section.deck")
if find(window(), "canvas.fit") != nil { press("section.deck") }
press("canvas.Launch board")
_ = item("canvas.fit")
for index in 0..<60 {
    let visible = find(window(), "sidebar.home") != nil
    press("sidebar.toggle")
    resize(index)
    require((find(window(), "sidebar.home") != nil) == !visible, "Sidebar visibility did not change")
    require(attribute(window(), kAXTitleAttribute) as? String == "Launch board", "Canvas navigation changed")
    _ = item("canvas.fit")
}
print("Canvas: 60 toggles and resizes preserved board and toolbar")
for section in ["tasks", "docs", "files", "toolbox", "chat", "deck"] {
    press("section." + section)
    for index in 0..<4 { press("sidebar.toggle"); resize(index) }
}
print("Six sections: 24 toggles and resizes passed")
press("section.chat")
if find(window(), "composer.field") == nil { press("channel.general") }
for draft in [String(repeating: "Crash report SwiftUI constraints 👩🏽‍💻\n", count: 1500), String(repeating: "x", count: 50_000), "Edited after long report"] {
    require(AXUIElementSetAttributeValue(item("composer.field"), kAXValueAttribute as CFString, draft as CFString) == .success, "Cannot set fixture draft")
    for index in 0..<6 { press("sidebar.toggle"); resize(index) }
    require(attribute(item("composer.field"), kAXValueAttribute) as? String == draft, "Composer text changed during resizing")
    print("Draft \(draft.count) characters survived six toggles/resizes")
}
print("Mac sidebar/composer fixture checks passed; nothing sent")
