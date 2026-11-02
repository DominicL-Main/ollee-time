import AVFoundation
import Combine
import Foundation
import Speech

/// Listens continuously while active and reports every complete time it hears.
///
/// The recogniser is not built for open-ended capture: a task finalises after a stretch of silence
/// or roughly a minute of audio. So the stream is torn down and restarted in the background for as
/// long as the caller wants to keep listening, which is what makes "tap once, it keeps listening"
/// behave the way it looks.
@MainActor
final class VoiceClock: ObservableObject {

    /// A freshly heard time. The identifier makes two identical readings distinct values, so
    /// saying the same time twice still reaches the watch.
    struct Detection: Equatable {
        let time: Date
        let id = UUID()
    }

    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var detection: Detection?
    @Published private(set) var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    private var wantsListening = false
    private var restartTimer: Timer?
    private var settleTimer: Timer?
    private var pendingReading: SpokenTime.Reading?
    private var lastEmitted: (label: String, at: Date)?
    private var restartCount = 0
    /// Set while another app (the camera recording video, a call) holds the microphone. Listening is
    /// paused rather than stopped, so it resumes by itself once that app releases the mic.
    private var isInterrupted = false

    /// Waits for a phrase to stop changing before acting, so "ten thirty" is not sent as "ten
    /// thirty" and again as "ten thirty five".
    private static let settleDelay: TimeInterval = 0.8
    /// Repeating the same time within this window is treated as one request.
    private static let repeatWindow: TimeInterval = 5

    init() {
        // Another app taking the microphone ends our input without the user pressing anything, so
        // watch for that and pick the stream back up afterwards.
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    // MARK: - Control

    func toggle() {
        if isListening {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isListening, !wantsListening else { return }
        wantsListening = true
        // Flip the button now so it can also cancel the permission prompt that is about to appear.
        isListening = true
        problem = nil
        transcript = ""
        restartCount = 0

        Task { @MainActor in
            if let failure = await ensurePermissions() {
                stop(with: failure)
                return
            }
            // Stopped while the permission sheet was up.
            guard wantsListening else { return }
            do {
                try beginStreaming()
            } catch {
                stop(with: error.localizedDescription)
            }
        }
    }

    func stop() {
        wantsListening = false
        isListening = false
        restartTimer?.invalidate()
        restartTimer = nil
        settleTimer?.invalidate()
        settleTimer = nil
        pendingReading = nil
        transcript = ""
        teardown()
    }

    private func stop(with message: String) {
        stop()
        problem = message
    }

    /// Called when the app returns to the foreground: an interruption that ended while the app was in
    /// the background does not always restart the stream on its own.
    func resumeIfNeeded() {
        guard wantsListening, !isInterrupted else { return }
        if !engine.isRunning { scheduleRestart() }
    }

    // MARK: - Permission

    private func ensurePermissions() async -> String? {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            switch status {
            case .authorized:
                break
            case .denied:
                return "Speech recognition is switched off. Allow it in Settings › Ollee Time."
            case .restricted:
                return "Speech recognition is restricted on this device."
            default:
                return "Speech recognition permission is needed to hear the time."
            }
        }

        guard await microphonePermission() else {
            return "Microphone access is needed to hear the time. Allow it in Settings › Ollee Time."
        }
        guard recognizer != nil else {
            return "This device cannot transcribe speech right now."
        }
        return nil
    }

    private func microphonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Audio pipeline

    private func beginStreaming() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if let recognizer, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw VoiceClockError.noMicrophone }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()

        guard let recognizer else { throw VoiceClockError.cannotTranscribe }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in self?.receive(result, error: error) }
        }
    }

    private func teardown() {
        pauseStreaming()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Drops the audio pipeline but leaves the session alone, so an interruption can be resumed
    /// without fighting the app that currently owns the microphone.
    private func pauseStreaming() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: - Results

    private func receive(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            restartCount = 0
            transcript = result.bestTranscription.formattedString
            consider(transcript)
            if result.isFinal {
                scheduleRestart()
            }
        }
        // A cancelled task reports an error on purpose; only restart while the caller still wants
        // to listen.
        if error != nil, wantsListening {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard wantsListening, !isInterrupted, restartTimer == nil else { return }
        let delay = min(0.4 * Double(restartCount + 1), 3)
        restartTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
    }

    private func restart() {
        restartTimer?.invalidate()
        restartTimer = nil
        guard wantsListening, !isInterrupted else { return }

        teardown()
        do {
            try beginStreaming()
        } catch {
            restartCount += 1
            if restartCount > 5 {
                stop(with: error.localizedDescription)
            } else {
                scheduleRestart()
            }
        }
    }

    // MARK: - Interruptions

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            guard wantsListening else { return }
            isInterrupted = true
            restartTimer?.invalidate()
            restartTimer = nil
            settleTimer?.invalidate()
            settleTimer = nil
            pendingReading = nil
            transcript = ""
            pauseStreaming()
            problem = "Another app is using the microphone. Listening resumes when it finishes."
        case .ended:
            guard wantsListening else { return }
            isInterrupted = false
            problem = nil
            scheduleRestart()
        @unknown default:
            break
        }
    }

    // MARK: - Acting on speech

    private func consider(_ text: String) {
        guard let reading = SpokenTime.parse(text) else { return }
        pendingReading = reading
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.emit() }
        }
    }

    private func emit() {
        guard let reading = pendingReading else { return }
        pendingReading = nil

        if let lastEmitted, lastEmitted.label == reading.label,
           Date().timeIntervalSince(lastEmitted.at) < Self.repeatWindow {
            return
        }
        lastEmitted = (reading.label, Date())
        detection = Detection(time: date(for: reading))
    }

    private func date(for reading: SpokenTime.Reading) -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: reading.hour,
                             minute: reading.minute,
                             second: 0,
                             of: Date()) ?? Date()
    }
}

enum VoiceClockError: LocalizedError {
    case noMicrophone
    case cannotTranscribe

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone input is available."
        case .cannotTranscribe:
            return "Speech recognition is unavailable right now."
        }
    }
}
