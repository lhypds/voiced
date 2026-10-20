import Foundation
import WhisperKit

/// A throwaway recognition run for the settings sheet: shows the input level against the energy
/// floor and what the recognizer makes of it, so the threshold can be tuned by ear and eye.
/// Nothing it recognizes reaches the transcript or the history.
@MainActor
final class RecognitionPreview: ObservableObject, LiveTranscriberDelegate {
    /// Committed sentences kept on screen: only the latest one, since the preview exists to check
    /// that speech is picked up, not to read a transcript.
    private static let visibleLines = 1

    @Published private(set) var isActive = false
    /// RMS of the newest 100 ms of input.
    @Published private(set) var level: Float = 0
    @Published private(set) var lines: [String] = []
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
        assembler: SentenceAssembler
    ) {
        stop()
        self.assembler = assembler
        session = RecordingSession(startedAt: Date(), baseLines: [])
        lines = []
        liveText = ""
        level = 0
        errorMessage = nil
        lastFinishedDecode = 0

        let transcriber = LiveTranscriber(
            whisperKit: whisperKit,
            options: options,
            inputDeviceID: inputDeviceID,
            silenceThreshold: silenceThreshold,
            silenceDelay: silenceDelay,
            speechEnergyFloor: speechEnergyFloor,
            delegate: self,
            levelHandler: { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
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
        level = 0
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
        let segmentLines = TranscriptionController.transcriptLines(from: segments, recordingStartedAt: session.startedAt)
        _ = session.update(
            latest: assembler.sentences(from: segmentLines),
            completed: assembler.sentences(from: segmentLines, includeTrailing: false)
        )
        liveText = assembler.draft(from: session.pendingLines.map(\.text))
        publish(session)
        return session.committedEnd
    }

    func transcriberDidDetectPause(_ transcriber: LiveTranscriber) -> Float {
        guard self.transcriber === transcriber, var session else { return 0 }
        session.commitTrailing(finalize: assembler.terminated)
        liveText = ""
        publish(session)
        return session.committedEnd
    }

    func transcriber(_ transcriber: LiveTranscriber, didFailWith error: Error) {
        guard self.transcriber === transcriber else { return }
        fail(with: error.localizedDescription)
    }

    private func publish(_ session: RecordingSession) {
        self.session = session
        lines = session.transcript.suffix(Self.visibleLines).map(\.text)
    }
}
