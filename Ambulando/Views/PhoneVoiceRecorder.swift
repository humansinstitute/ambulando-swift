#if os(iOS) || VOICE_HOST_TEST
import SwiftUI
import AVFoundation

// Kept independent of AVAudioSession so lifecycle/permission races can be checked on the host.
struct PhoneVoiceAuthority: Equatable {
    let connection: String?
    let workspace: String?
    let app: String
    let signer: String?
    let unlocked: Bool
}

struct PhoneVoiceInput: Equatable, Identifiable {
    let id: String
    let name: String
}

@MainActor protocol PhoneVoiceCaptureDriver: AnyObject {
    var event: ((PhoneVoiceEvent) -> Void)? { get set }
    func prepare() throws -> [PhoneVoiceInput]
    func start(preference: String, url: URL) throws
    func stop()
    func shutdown()
}

enum PhoneVoiceEvent {
    case started(PhoneVoiceInput?)
    case meter(Float, Double)
    case interrupted(String)
    case finished(URL, String?)
}

// The temporary file is also removed if the composer is destroyed after review.
private final class PhoneVoiceClipFiles {
    var url: URL?
    deinit { if let url { try? FileManager.default.removeItem(at: url) } }
}

@MainActor @Observable
final class PhoneVoiceRecorder {
    enum Phase { case idle, starting, recording, stopping, review }
    private(set) var phase: Phase = .idle
    var preference = ""
    private(set) var devices: [PhoneVoiceInput] = []
    private(set) var activeInput: PhoneVoiceInput?
    private(set) var level: Float = 0
    private(set) var elapsed = 0.0
    var notice: String?
    private let clipFiles = PhoneVoiceClipFiles()
    private(set) var clip: URL? { didSet { clipFiles.url = clip } }
    private let driver: any PhoneVoiceCaptureDriver
    private var player: AVAudioPlayer?
    private var generation = UUID()
    private var discarded = false
    var busy: Bool { phase == .starting || phase == .recording || phase == .stopping }

    init(driver: any PhoneVoiceCaptureDriver) { self.driver = driver }
    #if os(iOS)
    convenience init() { self.init(driver: PhoneAudioCapture()) }
    #endif

    static func level(_ decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        return min(1, max(0, (decibels + 60) / 60))
    }

    func refresh(permission: () async -> Bool) async {
        guard phase == .idle else { return }
        phase = .starting
        let token = UUID(); generation = token
        let allowed = await permission()
        guard generation == token else { return }
        phase = .idle
        guard allowed else { denied(); return }
        do { devices = try driver.prepare(); notice = devices.isEmpty ? "No microphone is available. Connect an input and refresh." : nil }
        catch { driver.shutdown(); notice = error.localizedDescription }
    }

    func start(permission: () async -> Bool) async {
        guard phase == .idle, clip == nil else { return }
        phase = .starting; notice = nil; discarded = false; level = 0; elapsed = 0; activeInput = nil
        let token = UUID(); generation = token
        let allowed = await permission()
        guard generation == token else { return }
        guard allowed else { phase = .idle; denied(); return }
        do {
            devices = try driver.prepare()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voice-\(UUID()).m4a")
            clip = url
            driver.event = { [self] event in
                guard self.generation == token else { return }
                self.receive(event)
            }
            try driver.start(preference: preference, url: url)
        } catch {
            // start can fail before there is a recorder/delegate to finish the clip.
            driver.event = nil; driver.shutdown(); removeClip()
            notice = error.localizedDescription
        }
    }

    private func denied() {
        driver.shutdown(); devices = []
        notice = "Microphone access is denied. Allow Ambulando in Settings → Privacy & Security → Microphone."
    }

    func receive(_ event: PhoneVoiceEvent) {
        switch event {
        case .started(let input):
            guard phase == .starting else { return }
            activeInput = input; phase = .recording
            if input == nil { notice = "The system has not reported the recording input." }
            else if !preference.isEmpty, preference != input?.id {
                notice = "Preferred microphone unavailable. Recording from \(input!.name)."
            }
        case .meter(let db, let seconds):
            guard phase == .recording else { return }
            level = Self.level(db); elapsed = max(0, seconds)
        case .interrupted(let message):
            guard busy else { return }
            notice = message; stop()
        case .finished(let url, let error):
            guard busy, clip == url else { return }
            driver.event = nil; driver.shutdown(); level = 0
            if discarded { removeClip(); return }
            if let audio = try? AVAudioPlayer(contentsOf: url), audio.duration > 0 {
                elapsed = audio.duration; phase = .review
                if let error { notice = "Recording ended: \(error). Review the saved clip before attaching." }
            } else { removeClip(); notice = error ?? "No playable audio was recorded. Try another microphone." }
        }
    }

    func stop() {
        guard busy else { return }
        // Permission can still be outstanding; invalidate it without starting capture later.
        if clip == nil { generation = UUID(); phase = .idle; driver.shutdown(); return }
        guard phase != .stopping else { return }
        phase = .stopping; level = 0; driver.stop()
    }
    func suspend() {
        if busy { notice = "Recording stopped. Review the saved clip before attaching."; stop() }
        else { driver.shutdown() }
        player?.stop(); player = nil
    }
    func play() {
        guard phase == .review, let clip else { return }
        do { player = try AVAudioPlayer(contentsOf: clip); player?.play() }
        catch { notice = "Could not play this clip: \(error.localizedDescription)" }
    }
    func discard() {
        player?.stop(); player = nil; discarded = true
        if busy, clip != nil { stop(); return }
        driver.event = nil; driver.shutdown(); removeClip()
    }
    private func removeClip() {
        generation = UUID()
        if let clip { try? FileManager.default.removeItem(at: clip) }
        clip = nil; phase = .idle; level = 0; elapsed = 0; activeInput = nil
    }
}

#if os(iOS)
/// A single recorder supplies the saved clip and average-power meter. Session input is evidence,
/// never inferred from setPreferredInput succeeding. Choice stays locked until the file closes.
@MainActor final class PhoneAudioCapture: NSObject, PhoneVoiceCaptureDriver, AVAudioRecorderDelegate {
    var event: ((PhoneVoiceEvent) -> Void)?
    private let session = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var initialRoute: [String] = []
    private var activated = false
    private var finishError: String?

    static func permission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    func prepare() throws -> [PhoneVoiceInput] {
        if !activated {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true); activated = true
        }
        return (session.availableInputs ?? []).map { PhoneVoiceInput(id: $0.uid, name: $0.portName) }
    }
    func start(preference: String, url: URL) throws {
        guard recorder == nil else { return }
        let preferred = (session.availableInputs ?? []).first { $0.uid == preference }
        // nil explicitly clears a previous preference; the system chooses the route.
        do { try session.setPreferredInput(preferred) }
        catch { try session.setPreferredInput(nil) }
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ])
        recorder.delegate = self; recorder.isMeteringEnabled = true
        self.recorder = recorder; finishError = nil
        guard recorder.record(forDuration: 600) else {
            self.recorder = nil
            throw NSError(domain: "AmbulandoVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone could not start recording."])
        }
        initialRoute = session.currentRoute.inputs.map(\.uid)
        let route = session.currentRoute.inputs.first.map { PhoneVoiceInput(id: $0.uid, name: $0.portName) }
        event?(.started(route))
        observe()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                self.event?(.meter(recorder.averagePower(forChannel: 0), recorder.currentTime))
            }
        }
    }
    private func observe() {
        let clipURL = recorder?.url
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.mediaServicesWereLostNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] notification in
                let name = notification.name
                let interruption = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    guard let self, self.recorder?.url == clipURL else { return }
                    if name == AVAudioSession.interruptionNotification,
                       interruption != AVAudioSession.InterruptionType.began.rawValue { return }
                    if name == AVAudioSession.routeChangeNotification,
                       self.session.currentRoute.inputs.map(\.uid) == self.initialRoute { return }
                    self.finishError = "The audio input changed or was interrupted."
                    self.event?(.interrupted("The audio input changed or was interrupted. Recording stopped; review any saved audio."))
                }
            })
        }
    }
    func stop() {
        detachCallbacks()
        guard let recorder else { return }
        // AVAudioRecorder.stop closes its output file synchronously. Its finish delegate is
        // explicitly NOT called for interruption stops, so finalize here as well as on
        // natural duration completion. The model clears the driver before a late delegate.
        recorder.stop()
        event?(.finished(recorder.url, finishError))
    }
    private func detachCallbacks() {
        timer?.invalidate(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
    func shutdown() {
        detachCallbacks()
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        if activated {
            try? session.setPreferredInput(nil)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            activated = false
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            let error = self.finishError ?? (flag ? nil : "The audio session ended before recording completed.")
            self.event?(.finished(url, error))
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let message = error?.localizedDescription ?? "Audio encoding failed."
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            self.finishError = message
            self.event?(.interrupted(message))
        }
    }
    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

struct PhoneVoiceRecorderView: View {
    @Bindable var recorder: PhoneVoiceRecorder
    let attach: (URL) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Preferred microphone", selection: $recorder.preference) {
                Text("System default").tag("")
                ForEach(recorder.devices) { Text($0.name).tag($0.id) }
                if !recorder.preference.isEmpty, !recorder.devices.contains(where: { $0.id == recorder.preference }) {
                    Text("Unavailable preference").tag(recorder.preference)
                }
            }.disabled(recorder.phase != .idle)
            if recorder.phase == .idle {
                Button("Refresh inputs") { Task { await recorder.refresh(permission: PhoneAudioCapture.permission) } }
            }
            Text(recorder.phase == .review ? "Recorded input: \(recorder.activeInput?.name ?? "Unknown")" :
                 "Active input: \(recorder.phase == .recording ? recorder.activeInput?.name ?? "Unknown" : "Not recording")")
            if recorder.busy {
                Text("Microphone choice is locked until this clip stops.").font(.caption)
                Text("\(recorder.phase == .recording ? "Recording" : recorder.phase == .starting ? "Starting…" : "Finishing…") · \(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))")
                ProgressView(value: Double(recorder.level))
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    .accessibilityLabel("Recorded input level")
                    .accessibilityValue("\(Int(recorder.level * 100)) percent")
                if recorder.phase == .recording { Button("Stop") { recorder.stop() } }
            } else if recorder.phase == .review, let clip = recorder.clip {
                Text("Recorded clip · \(Int(recorder.elapsed)) seconds")
                HStack {
                    Button("Play") { recorder.play() }
                    Button("Attach recording") { if attach(clip) { recorder.discard() } }
                }
            } else {
                Button("Start recording") { Task { await recorder.start(permission: PhoneAudioCapture.permission) } }
            }
            if let notice = recorder.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            Text("Up to 10 minutes. Leaving the app stops recording and keeps the clip for review.").font(.caption)
        }.padding(12)
    }
}
#endif

#endif
