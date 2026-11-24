import SwiftUI
import AVFoundation

struct MacVoiceAuthority: Equatable {
    let connection: String?
    let workspace: String?
    let app: String
    let signer: String?
    let unlocked: Bool
}

/// The file output's own audio channels supply the meter. No second capture or synthetic waveform.
final class MacVoiceCapture: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case started(String, String)
        case meter(Float, Double)
        case finished(URL, String?)
        case failed(String)
        case disconnected
    }
    private let queue = DispatchQueue(label: "ambulando.voice.capture")
    private let emit: @Sendable (Event) -> Void
    // Accessed only on queue, except AVFoundation's documented delegate callbacks.
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var timer: DispatchSourceTimer?
    private var route: (name: String, id: String)?
    private var recordingURL: URL?
    private var removeWhenFinished = false

    init(emit: @escaping @Sendable (Event) -> Void) { self.emit = emit }

    func start(preference: String, url: URL) {
        queue.async { [self] in
            recordingURL = url
            do {
                let preferred = preference.isEmpty ? nil : AVCaptureDevice(uniqueID: preference)
                guard let device = preferred.flatMap({ $0.isConnected ? $0 : nil }) ?? AVCaptureDevice.default(for: .audio) else {
                    emit(.failed("No microphone is available. Connect an input and try again.")); return
                }
                let input = try AVCaptureDeviceInput(device: device)
                let session = AVCaptureSession(), output = AVCaptureAudioFileOutput()
                guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.m4a) else {
                    emit(.failed("Audio recording is not supported on this Mac.")); return
                }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    emit(.failed("This microphone cannot record audio.")); return
                }
                session.addInput(input); session.addOutput(output)
                self.session = session; self.output = output
                route = (input.device.localizedName, input.device.uniqueID)
                output.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
                output.maxRecordedFileSize = 90 * 1024 * 1024
                output.maxRecordedDuration = CMTime(seconds: 600, preferredTimescale: 600)
                session.startRunning()
                guard session.isRunning else { cleanup(); emit(.failed("The microphone could not start.")); return }
                output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                timer.setEventHandler { [weak self, weak output, weak device] in
                    guard let self, let output else { return }
                    guard device?.isConnected == true else { self.emit(.disconnected); self.stopOnQueue(); return }
                    let channels = output.connections.flatMap(\.audioChannels)
                    let db = channels.map(\.averagePowerLevel).max() ?? -160
                    self.emit(.meter(Self.level(db), max(0, output.recordedDuration.seconds)))
                }
                self.timer = timer; timer.resume()
            } catch { cleanup(); emit(.failed(error.localizedDescription)) }
        }
    }

    static func level(_ decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        return min(1, max(0, (decibels + 60) / 60))
    }

    func stop() { queue.async { [self] in stopOnQueue() } }
    func cancel() {
        queue.async { [self] in
            removeWhenFinished = true
            if output == nil, let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            stopOnQueue()
        }
    }
    private func stopOnQueue() {
        timer?.cancel(); timer = nil
        output?.stopRecording()
        // didFinishRecording is the only point at which the clip can be reviewed/attached.
    }
    private func cleanup() {
        timer?.cancel(); timer = nil
        session?.stopRunning(); session = nil; output = nil
        route = nil
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async { [self] in
            // Publish the attached input only once AVFoundation confirms file recording started.
            if let route { emit(.started(route.name, route.id)) }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: (any Error)?) {
        let message = error?.localizedDescription
        queue.async { [self] in
            cleanup()
            // Cleanup must survive the composer/model being released before this callback arrives.
            if removeWhenFinished { try? FileManager.default.removeItem(at: url) }
            emit(.finished(url, message))
        }
    }
}

@MainActor @Observable
final class MacVoiceRecorder {
    enum Phase { case idle, starting, recording, stopping, review }
    var phase: Phase = .idle
    var preference = ""
    var devices: [AVCaptureDevice] = []
    var activeName: String?
    var activeID: String?
    var level: Float = 0
    var elapsed = 0.0
    var notice: String?
    var clip: URL?
    private var capture: MacVoiceCapture?
    private var player: AVAudioPlayer?
    private var discarded = false
    private var generation = UUID()
    var busy: Bool { phase == .starting || phase == .recording || phase == .stopping }

    func refresh() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    func start(permission: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) async {
        guard !busy, clip == nil else { return }
        phase = .starting; notice = nil; discarded = false; level = 0; elapsed = 0
        let generation = UUID(); self.generation = generation
        let allowed = await permission()
        // A cancelled permission prompt may finish after a newer clip has started.
        guard self.generation == generation else { return }
        guard !discarded else { phase = .idle; return }
        guard allowed else {
            phase = .idle; notice = "Microphone access is denied. Allow Ambulando in System Settings → Privacy & Security → Microphone."; return
        }
        refresh()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voice-\(UUID().uuidString).m4a")
        clip = url
        let capture = MacVoiceCapture { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.receive(event)
            }
        }
        self.capture = capture
        capture.start(preference: preference, url: url)
    }
    func receive(_ event: MacVoiceCapture.Event) {
        switch event {
        case .started(let name, let id):
            activeName = name; activeID = id
            if !preference.isEmpty, preference != id { notice = "Preferred microphone unavailable. Recording from \(name)." }
            phase = discarded ? .stopping : .recording
            if discarded { capture?.stop() }
        case .meter(let value, let seconds):
            guard phase == .recording else { return }
            level = value; elapsed = seconds
        case .finished(let url, let error):
            capture = nil; level = 0
            if discarded {
                try? FileManager.default.removeItem(at: url); clip = nil; phase = .idle
                activeName = nil; activeID = nil
            }
            else if let audio = try? AVAudioPlayer(contentsOf: url), audio.duration > 0 {
                elapsed = audio.duration; phase = .review
                if let error { notice = "Recording ended: \(error). Review the saved clip before attaching." }
            } else { discard(); notice = error ?? "No audio was recorded. Try another microphone." }
        case .failed(let message):
            capture = nil; discard(); notice = message
        case .disconnected:
            notice = "The active microphone disconnected. Recording stopped; review any saved audio. Choose an input for the next clip."
            phase = .stopping; level = 0
        }
    }
    func stop() { guard busy else { return }; phase = .stopping; level = 0; capture?.stop() }
    func play() {
        guard let clip, phase == .review else { return }
        do { player = try AVAudioPlayer(contentsOf: clip); player?.play() }
        catch { notice = "Could not play this clip: \(error.localizedDescription)" }
    }
    func discard() {
        player?.stop(); player = nil; discarded = true; level = 0
        if busy, capture != nil { phase = .stopping; capture?.cancel(); return }
        generation = UUID()
        if let clip { try? FileManager.default.removeItem(at: clip) }
        clip = nil; phase = .idle; activeName = nil; activeID = nil
    }
}

struct MacVoiceRecorderView: View {
    @Bindable var recorder: MacVoiceRecorder
    let attach: (URL) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Preferred microphone", selection: $recorder.preference) {
                    Text("System default").tag("")
                    ForEach(recorder.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    if !recorder.preference.isEmpty, !recorder.devices.contains(where: { $0.uniqueID == recorder.preference }) {
                        Text("Disconnected preference").tag(recorder.preference)
                    }
                }.disabled(recorder.busy || recorder.phase == .review)
                Button("Refresh inputs") { recorder.refresh() }.disabled(recorder.busy)
            }
            Text(recorder.phase == .review ? "Recorded input: \(recorder.activeName ?? "Unknown")" :
                 "Active input: \(recorder.phase == .recording ? recorder.activeName ?? "Unknown" : "Not recording")")
            if recorder.busy {
                Text("Microphone choice is locked until this clip stops.").font(.caption)
                HStack {
                    Text(recorder.phase == .recording ? "Recording" : recorder.phase == .starting ? "Starting…" : "Finishing…")
                    Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    ProgressView(value: Double(recorder.level)).frame(width: 140)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                        .accessibilityLabel("Recorded input level")
                        .accessibilityValue("\(Int(recorder.level * 100)) percent")
                    if recorder.phase == .recording { Button("Stop") { recorder.stop() } }
                }
            } else if recorder.phase == .review, let clip = recorder.clip {
                HStack {
                    Text("Recorded clip · \(Int(recorder.elapsed)) seconds")
                    Button("Play") { recorder.play() }
                    Button("Attach recording") { if attach(clip) { recorder.discard() } }
                }
            } else { Button("Start recording") { Task { await recorder.start() } } }
            if let notice = recorder.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Text("Up to 10 minutes per recording.").font(.caption)
        }
        .padding(12)
        .task { recorder.refresh() }
    }
}
