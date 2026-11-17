import AVFoundation
import Combine
import Speech
import SwiftUI

struct ContentView: View {
    @StateObject private var dictation = Dictation()

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
                        Label(dictation.phase == .listening ? "Stop listening" : "Start listening",
                              systemImage: dictation.phase == .listening ? "stop.circle" : "mic")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dictation.phase == .starting || dictation.phase == .finishing)

                    if dictation.phase == .starting {
                        ProgressView("Preparing microphone…")
                    } else if dictation.phase == .finishing {
                        ProgressView("Finishing transcript…")
                    }

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
        }
    }
}

@MainActor
private final class Dictation: ObservableObject {
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

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        message = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            finish("Allow microphone access in Settings to record a voice note.")
            return
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
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
            transcript = ""
            phase = .listening

            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if let text { self.transcript = text }
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
        try? AVAudioSession.sharedInstance().setActive(false)
        self.message = message
        phase = .idle
    }
}
