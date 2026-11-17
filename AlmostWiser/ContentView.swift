import AppIntents
import AVFoundation
import Combine
import Foundation
#if DEBUG
import OSLog
#endif
import Speech
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var dictation = Dictation.shared

    private var buttonTitle: String {
        switch dictation.phase {
        case .idle: return dictation.shortcutRequested ? "Preparing microphone…" : "Start listening"
        case .starting: return "Preparing microphone…"
        case .listening: return "Stop listening"
        case .finishing: return "Finishing transcript…"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Button {
                        if dictation.phase == .listening {
                            dictation.stop()
                        } else {
                            Task { await dictation.start() }
                        }
                    } label: {
                        Label(buttonTitle,
                              systemImage: dictation.phase == .listening ? "stop.circle" : "mic")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dictation.shortcutRequested || dictation.phase == .starting || dictation.phase == .finishing)

                    if let message = dictation.message {
                        Text(message).foregroundStyle(.secondary)
                    }

                    Text(dictation.transcript.isEmpty ? "Your transcript will appear here." : dictation.transcript)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("AlmostWiser")
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { LaunchTiming.mark("scene active") }
            }
            .task(id: scenePhase == .active && dictation.shortcutRequested) {
                guard scenePhase == .active, dictation.shortcutRequested else { return }
                await dictation.start()
                dictation.shortcutRequested = false
            }
            .onOpenURL { url in
                guard url == URL(string: "almostwiser://listen") else { return }
                LaunchTiming.mark("URL received")
                dictation.shortcutRequested = true
            }
        }
    }
}

@MainActor
private final class Dictation: ObservableObject {
    static let shared = Dictation()
    @Published var shortcutRequested = false

    enum Phase { case idle, starting, listening, finishing }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var transcript = ""
    @Published private(set) var message: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var finishTimeout: Task<Void, Never>?
    private var tapInstalled = false
    private var audioSessionActive = false

    func start() async {
        guard phase == .idle else { return }
        LaunchTiming.mark("capture setup started")
        phase = .starting
        message = nil

        let microphonePermission = AVAudioApplication.shared.recordPermission
        var microphoneAllowed = microphonePermission == .granted
        if microphonePermission == .undetermined {
            microphoneAllowed = await AVAudioApplication.requestRecordPermission()
        }
        guard microphoneAllowed else {
            finish("Allow microphone access in Settings to record a voice note.")
            return
        }
        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard authorization == .authorized else {
            finish("Allow Speech Recognition in Settings to transcribe your voice.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            finish("Speech recognition is unavailable for your current language or connection.")
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            audioSessionActive = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                finish("No microphone input is available.")
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            let id = UUID()
            sessionID = id
            Self.installTap(on: input, format: format, request: request)
            tapInstalled = true
            engine.prepare()
            try engine.start()
            LaunchTiming.mark("microphone engine started")
            transcript = ""
            phase = .listening

            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if let text {
                        if self.transcript.isEmpty && !text.isEmpty {
                            LaunchTiming.mark("first transcript")
                        }
                        self.transcript = text
                    }
                    if final {
                        self.finish(self.transcript.isEmpty ? "No speech was detected. Try again." : nil)
                    } else if failed {
                        self.finish("Transcription ended early. You can try again.")
                    }
                }
            }
        } catch {
            finish("Could not start the microphone. Try again.")
        }
    }

    func stop() {
        guard phase == .listening else { return }
        phase = .finishing
        stopCapture()
        request?.endAudio()
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.finish("Transcription timed out. Any partial text is shown below.")
        }
    }

    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private func stopCapture() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func finish(_ message: String?) {
        sessionID = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        stopCapture()
        recognition?.cancel()
        recognition = nil
        request = nil
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false)
            audioSessionActive = false
        }
        self.message = message
        phase = .idle
    }
}

@available(iOS 26, *)
struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Listening"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchTiming.mark("App Intent received")
        let dictation = Dictation.shared
        dictation.shortcutRequested = true

        if systemContext.currentMode != .foreground {
            LaunchTiming.mark("App Intent requested foreground")
            do {
                try await continueInForeground(alwaysConfirm: false)
            } catch {
                dictation.shortcutRequested = false
                throw error
            }
        }
        return .result()
    }
}

struct AlmostWiserShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: ["Start listening with \(.applicationName)"],
            shortTitle: "Start Listening",
            systemImageName: "mic"
        )
    }
}

private enum LaunchTiming {
    #if DEBUG
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AlmostWiser",
                                       category: "LaunchTiming")
    #endif

    static func mark(_ event: String) {
        #if DEBUG
        logger.notice("AWTiming \(event, privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
        #endif
    }
}
