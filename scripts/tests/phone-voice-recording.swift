// Host synthetic checks, no microphone, audio session, device or live account.
// swiftc -swift-version 6 -D VOICE_HOST_TEST -parse-as-library
//   Ambulando/Views/PhoneVoiceRecorder.swift scripts/tests/phone-voice-recording.swift -o <ignored-output>
import Foundation
import AVFoundation

@MainActor final class CaptureFixture: PhoneVoiceCaptureDriver {
    var event: ((PhoneVoiceEvent) -> Void)?
    var inputs = [PhoneVoiceInput(id: "built-in", name: "Fixture built-in")]
    var actual: PhoneVoiceInput? = PhoneVoiceInput(id: "built-in", name: "Fixture built-in")
    var starts = 0, stops = 0, shutdowns = 0
    var callbacks = false
    var finishOnStop = false
    var failPrepare = false, failStart = false
    var url: URL?
    func prepare() throws -> [PhoneVoiceInput] {
        if failPrepare { throw NSError(domain: "fixture-prepare", code: 1) }
        return inputs
    }
    func start(preference: String, url: URL) throws {
        starts += 1; self.url = url
        if failStart {
            try Data("partial failed file".utf8).write(to: url)
            throw NSError(domain: "fixture-start", code: 1)
        }
        callbacks = true
        event?(.started(actual))
    }
    func stop() {
        stops += 1; callbacks = false
        if finishOnStop { try! finish() }
    }
    func shutdown() { shutdowns += 1; callbacks = false }
    func finish() throws {
        guard let url else { preconditionFailure("No started clip") }
        // Real generated PCM, copied to the capture URL; content is detected by AVAudioPlayer.
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("voice-fixture-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0..<4410 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.1) }
        do { let file = try AVAudioFile(forWriting: wav, settings: format.settings); try file.write(from: buffer) }
        try Data(contentsOf: wav).write(to: url)
        event?(.finished(url, nil))
    }
}

@main struct PhoneVoiceRecordingChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let driver = CaptureFixture(), model = PhoneVoiceRecorder(driver: driver)
        defer { model.discard() }
        await model.start(permission: { false })
        check(model.phase == .idle && driver.starts == 0, "Denied permission must not capture")
        check(model.notice?.contains("denied") == true && model.devices.isEmpty, "Permission denial is explicit")
        await model.refresh(permission: { true })
        check(model.devices == driver.inputs && driver.starts == 0, "Listing choices does not record")
        driver.inputs = []
        await model.refresh(permission: { true })
        check(model.devices.isEmpty && model.notice?.contains("No microphone") == true, "Missing input is explained without capture")
        driver.inputs = [driver.actual!]
        model.preference = "missing"
        await model.start(permission: { true })
        let first = model.clip!
        check(model.phase == .recording && model.activeInput == driver.actual, "Actual route comes from driver evidence")
        check(model.preference == "missing" && model.notice?.contains("unavailable") == true, "Fallback does not rewrite selected preference")
        await model.start(permission: { true })
        check(driver.starts == 1, "A busy recorder never starts a second capture")
        driver.event?(.meter(-160, 0.1))
        check(model.level == 0 && model.elapsed == 0.1, "Silence remains calm")
        driver.event?(.meter(-20, 0.2))
        check(model.level > 0.6 && model.elapsed == 0.2, "Nonzero captured dB drives level and elapsed")
        driver.event?(.meter(.nan, 0.3))
        check(model.level == 0, "Invalid meter sample remains calm")
        driver.event?(.interrupted("Fixture route disconnected"))
        check(model.phase == .stopping && driver.stops == 1 && !driver.callbacks, "Route interruption stops callbacks")
        driver.event?(.meter(0, 3))
        check(model.level == 0, "Late samples cannot animate stopped capture")
        try driver.finish()
        check(model.phase == .review && model.clip == first && model.elapsed > 0, "Playable interrupted clip survives for review")
        check(model.notice?.contains("disconnected") == true, "Interruption explanation survives finalization")
        check(driver.event == nil && !driver.callbacks, "Finish removes capture callbacks")
        model.suspend()
        check(model.phase == .review && FileManager.default.fileExists(atPath: first.path), "Leaving review preserves clip")
        // A failed attachment does not call discard; the review clip stays available.
        let attach: (URL) -> Bool = { _ in false }
        if attach(first) { model.discard() }
        check(model.clip == first, "Attachment rejection retains the recording")
        model.discard()
        check(model.phase == .idle && !FileManager.default.fileExists(atPath: first.path), "Cancel removes saved clip")

        model.preference = "built-in"
        await model.start(permission: { true })
        check(model.activeInput == driver.actual && model.notice == nil, "Matching selected preference is confirmed by actual route")
        model.stop(); try driver.finish(); model.discard()
        driver.actual = nil
        model.preference = "preferred"
        await model.start(permission: { true })
        check(model.activeInput == nil && model.notice?.contains("not reported") == true, "Unknown actual route never claims preferred input")
        model.discard()
        check(model.phase == .stopping, "Cancel waits for file finalization")
        try driver.finish()
        check(model.phase == .idle && model.clip == nil && !FileManager.default.fileExists(atPath: driver.url!.path), "Cancelled final audio is removed")
        driver.actual = driver.inputs.first
        model.preference = ""
        await model.start(permission: { true })
        check(model.activeInput == driver.actual && model.notice == nil, "System default displays observed route")
        model.suspend()
        try driver.finish()
        check(model.phase == .review && model.clip != nil, "Background stop retains playable clip without attaching or sending")
        model.discard()

        driver.failStart = true
        await model.start(permission: { true })
        check(model.phase == .idle && model.clip == nil && driver.event == nil, "Synchronous start failure resets immediately")
        check(!FileManager.default.fileExists(atPath: driver.url!.path), "Failed start partial file is removed")
        driver.failStart = false; driver.failPrepare = true
        await model.start(permission: { true })
        check(model.phase == .idle && model.clip == nil, "Prepare failure leaves no stuck capture")
        driver.failPrepare = false

        var reply: CheckedContinuation<Bool, Never>?
        let pending = Task { await model.start(permission: { await withCheckedContinuation { reply = $0 } }) }
        while reply == nil { await Task.yield() }
        let priorStarts = driver.starts
        model.discard()
        var nextReply: CheckedContinuation<Bool, Never>?
        let newer = Task { await model.start(permission: { await withCheckedContinuation { nextReply = $0 } }) }
        while nextReply == nil { await Task.yield() }
        reply?.resume(returning: true); await pending.value
        check(model.phase == .starting && driver.starts == priorStarts, "Cancelled permission result cannot start or overwrite newer capture")
        model.suspend()
        nextReply?.resume(returning: true); await newer.value
        check(model.phase == .idle && driver.starts == priorStarts, "Closing during permission does not start capture later")

        // Generated samples → dB → the same model meter; synthetic audio, not physical capture.
        let quiet: [Float] = Array(repeating: 0, count: 4410)
        let tone = (0..<4410).map { Float(sin(Double($0) * 0.1) * 0.1) }
        func db(_ samples: [Float]) -> Float {
            let mean = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
            return mean == 0 ? -160 : 10 * log10(mean)
        }
        await model.start(permission: { true })
        driver.event?(.meter(db(quiet), 0.1))
        check(model.level == 0, "Generated silent PCM stays zero")
        driver.event?(.meter(db(tone), 0.2))
        check(model.level > 0 && model.level <= 1, "Generated nonzero PCM changes meter")
        model.stop(); try driver.finish(); model.discard()

        let synchronous = CaptureFixture()
        // Match AVAudioRecorder.stop's synchronous file closure even when interruption
        // suppresses its delegate. The driver supplies one completion directly.
        let immediate = PhoneVoiceRecorder(driver: synchronous)
        synchronous.finishOnStop = true
        await immediate.start(permission: { true })
        synchronous.event?(.interrupted("Fixture OS interruption without a delegate"))
        check(immediate.phase == .review && synchronous.event == nil, "Synchronous stop finalization retains interruption audio without waiting for delegate")
        immediate.discard()
        let orphanDriver = CaptureFixture()
        var orphan: PhoneVoiceRecorder? = PhoneVoiceRecorder(driver: orphanDriver)
        await orphan!.start(permission: { true }); orphan!.stop(); try orphanDriver.finish()
        let orphanURL = orphan!.clip!
        orphan = nil
        check(!FileManager.default.fileExists(atPath: orphanURL.path), "Destroying reviewed composer removes temporary audio")
        check(PhoneVoiceRecorder.level(0) == 1 && PhoneVoiceRecorder.level(-60) == 0, "Meter clamps endpoints")
        print("PHONE_VOICE_HOST_PASS: \(checks) synthetic state/generated-audio checks; no iOS capture/device evidence")
    }
}
