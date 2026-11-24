// Run: swiftc -swift-version 6 -parse-as-library AmbulandoMac/MacVoiceRecorder.swift
//      scripts/tests/mac-voice-recording.swift -o <ignored-output>; <ignored-output>
// Exercises lifecycle with generated audio, without requesting a microphone or launching/installing an app.
import Foundation
import AVFoundation

@main struct MacVoiceRecordingChecks {
    @MainActor static func main() async throws {
        precondition(MacVoiceCapture.level(-160) == 0)
        precondition(MacVoiceCapture.level(-60) == 0)
        precondition(MacVoiceCapture.level(.nan) == 0)
        precondition(MacVoiceCapture.level(0) == 1)
        precondition(MacVoiceCapture.level(-20) > MacVoiceCapture.level(-40))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-check-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0..<4410 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.1) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let recorder = MacVoiceRecorder()
        recorder.preference = "unavailable-input"
        recorder.receive(.started("Actual system input", "actual-id"))
        precondition(recorder.activeID == "actual-id" && recorder.preference == "unavailable-input")
        precondition(recorder.notice?.contains("unavailable") == true)
        recorder.receive(.meter(0.7, 0.1))
        precondition(recorder.level == 0.7)
        recorder.receive(.disconnected)
        precondition(recorder.phase == .stopping && recorder.level == 0)
        recorder.receive(.meter(0.9, 1))
        precondition(recorder.level == 0)
        recorder.clip = url
        recorder.receive(.finished(url, nil))
        precondition(recorder.phase == .review && recorder.elapsed > 0)
        precondition(recorder.notice?.contains("disconnected") == true)
        recorder.discard()
        precondition(recorder.phase == .idle && recorder.clip == nil && recorder.activeName == nil)
        precondition(!FileManager.default.fileExists(atPath: url.path))
        recorder.receive(.failed("Permission denied"))
        precondition(recorder.phase == .idle && recorder.notice == "Permission denied")
        var permissionReply: CheckedContinuation<Bool, Never>?
        let pending = Task { await recorder.start(permission: {
            await withCheckedContinuation { permissionReply = $0 }
        }) }
        while permissionReply == nil { await Task.yield() }
        recorder.discard()
        var nextPermissionReply: CheckedContinuation<Bool, Never>?
        let newer = Task { await recorder.start(permission: {
            await withCheckedContinuation { nextPermissionReply = $0 }
        }) }
        while nextPermissionReply == nil { await Task.yield() }
        permissionReply?.resume(returning: true)
        await pending.value
        precondition(recorder.phase == .starting, "old permission result cannot overwrite newer recording state")
        nextPermissionReply?.resume(returning: false)
        await newer.value
        precondition(recorder.phase == .idle && recorder.notice?.contains("denied") == true)
        print("MAC_VOICE_LIFECYCLE_PASS: real-level mapping, route/preference separation, disconnect, finalized clip review, cancel cleanup, failure")
    }
}
