#if os(macOS)
import Foundation
import XCTest

final class TemporaryDirectoryLifecycleTests: XCTestCase {
    func testRunnerCleansFixturesAfterSuccessFailureAndEarlyExit() throws {
        let records = temporaryDirectory("lifecycle-records")
        let sibling = temporaryDirectory("other-run-survives")
        let siblingMarker = sibling.appendingPathComponent("marker")
        try Data("keep".utf8).write(to: siblingMarker)

        for mode in ["success", "failure", "early-exit"] {
            let record = records.appendingPathComponent(mode)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "AmbulandoCoreTests.TemporaryDirectoryLifecycleTests/testLifecycleProbe",
                                 Bundle(for: Self.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment["AMBULANDO_CLEANUP_PROBE_RECORD"] = record.path
            environment["AMBULANDO_CLEANUP_PROBE_MODE"] = mode
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, mode == "success" ? 0 : mode == "early-exit" ? 7 : 1)
            let fixturePath = try String(contentsOf: record, encoding: .utf8)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixturePath), "Runner left its fixture directory behind")
            let runnerRoot = URL(fileURLWithPath: fixturePath).deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: runnerRoot.path), "Runner left its root behind")
            XCTAssertTrue(FileManager.default.fileExists(atPath: siblingMarker.path), "Another runner's fixtures must survive")
        }
    }

    func testLifecycleProbe() throws {
        guard let record = ProcessInfo.processInfo.environment["AMBULANDO_CLEANUP_PROBE_RECORD"] else { return }
        let fixture = temporaryDirectory("runner-probe")
        try Data(repeating: 1, count: 4096).write(to: fixture.appendingPathComponent("payload"))
        try fixture.path.write(toFile: record, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["AMBULANDO_CLEANUP_PROBE_MODE"] == "early-exit" { exit(7) }
        if ProcessInfo.processInfo.environment["AMBULANDO_CLEANUP_PROBE_MODE"] == "failure" {
            XCTFail("Intentional failure to verify cleanup")
        }
    }
}
#endif
