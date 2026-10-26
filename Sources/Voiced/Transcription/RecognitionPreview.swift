import VoicedCore
import Foundation
import WhisperKit

/// A throwaway recognition run for the settings sheet: shows what the recognizer makes of the
/// input with the current settings, so the threshold can be tuned by ear and eye. Nothing it
/// recognizes reaches the transcript or the history.
@MainActor
final class RecognitionPreview: ObservableObject, LiveTranscriberDelegate {
    @Published private(set) var isActive = false
    /// The one sentence on screen: the text being recognized, or the last finished sentence while
    /// nothing is in flight. The preview exists to check that speech is picked up, not to read a
    /// transcript, so finished sentences are shown the same way as in-flight text.
    @Published private(set) var liveText = ""
    @Published private(set) var errorMessage: String?

    private var transcriber: LiveTranscriber?
    private var session: RecordingSession?
    private var assembler = SentenceAssembler(languageCode: nil)
    private var lastFinishedDecode = 0
    private var startTask: Task<Void, Never>?

    nonisolated init() {}

    func start(
        whisperKit: WhisperKit,
        options: DecodingOptions,
        inputDeviceID: DeviceID,
        silenceThreshold: Float,
        silenceDelay: TimeInterval,
        speechEnergyFloor: Float,
        voiceDetector: SileroVoiceDetector? = nil,
        assembler: SentenceAssembler,
        audioProcessor: (any AudioProcessing)? = nil
    ) {
        stop()
        self.assembler = assembler
        session = RecordingSession(startedAt: Date(), baseLines: [])
        liveText = ""
        errorMessage = nil
        lastFinishedDecode = 0

        let transcriber = LiveTranscriber(
            whisperKit: whisperKit,
            options: options,
            inputDeviceID: inputDeviceID,
            silenceThreshold: silenceThreshold,
            silenceDelay: silenceDelay,
            speechEnergyFloor: speechEnergyFloor,
            voiceDetector: voiceDetector,
            delegate: self,
            audioProcessor: audioProcessor
        )
        self.transcriber = transcriber
        isActive = true

        startTask = Task { [weak self] in
            do {
                guard await AudioProcessor.requestRecordPermission() else {
                    throw MicrophoneAccessDenied()
                }
                guard let self, self.transcriber === transcriber else { return }
                try await transcriber.start()
            } catch {
                self?.fail(with: error.localizedDescription)
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        if let transcriber {
            Task { await transcriber.stop() }
        }
        transcriber = nil
        session = nil
        isActive = false
        liveText = ""
    }

    func setSpeechEnergyFloor(_ floor: Float) {
        guard let transcriber else { return }
        Task { await transcriber.setSpeechEnergyFloor(floor) }
    }

    private func fail(with detail: String) {
        stop()
        errorMessage = detail
    }

    private struct MicrophoneAccessDenied: LocalizedError {
        var errorDescription: String? { "Microphone access was not granted." }
    }

    // MARK: - LiveTranscriberDelegate

    func transcriber(_ transcriber: LiveTranscriber, didUpdateLiveText text: String, decode: Int) {
        guard self.transcriber === transcriber, decode > lastFinishedDecode, session != nil else { return }
        let trimmed = HallucinationFilter.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            liveText = assembler.normalized(trimmed)
        }
    }

    func transcriber(_ transcriber: LiveTranscriber, didDecode segments: [TranscriptionSegment], decode: Int) -> Float {
        lastFinishedDecode = max(lastFinishedDecode, decode)
        guard self.transcriber === transcriber, var session else { return 0 }
        session.update(segments: segments, assembler: assembler)
        // Keep the streamed preview when every segment was dropped, as the transcript does.
        let draft = assembler.draft(from: session.pendingLines.map(\.text))
        if !draft.isEmpty {
            liveText = draft
        }
        self.session = session
        return session.committedEnd
    }

    func transcriberDidDetectPause(_ transcriber: LiveTranscriber) -> Float {
        guard self.transcriber === transcriber, var session else { return 0 }
        session.commitTrailing(finalize: assembler.terminated)
        // Show the finished sentence until the next one starts, rather than an empty box.
        if let last = session.transcript.last {
            liveText = last.text
        }
        self.session = session
        return session.committedEnd
    }

    func transcriber(_ transcriber: LiveTranscriber, didFailWith error: Error) {
        guard self.transcriber === transcriber else { return }
        fail(with: error.localizedDescription)
    }
}
