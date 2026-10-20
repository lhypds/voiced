import AppKit
import Combine
import Foundation
@preconcurrency import WhisperKit

/// Owns the WhisperKit model, the live audio stream and the transcript shown in the UI.
@MainActor
final class TranscriptionController: ObservableObject {
    enum Failure: Equatable {
        case model(String)
        case noInput
        case recognition(String)
    }

    enum Phase: Equatable {
        case downloading(Double)
        case loading
        case ready
        case recording
        case failed(Failure)
    }

    /// Relative buffer energy above this level counts as speech.
    private static let voiceActivityThreshold: Float = 0.12
    /// A pause this long turns the sentence in progress into a final transcript line.
    private static let silenceCommitDelay: TimeInterval = 2

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var liveText = ""
    /// Saved transcripts, most recently updated first.
    @Published private(set) var history: [TranscriptRecord] = []
    /// The history record the visible transcript belongs to, if it has been saved.
    @Published private(set) var currentRecordID: UUID?
    @Published private(set) var audioDevices: [AudioDevice] = []
    @Published var selectedDeviceID: DeviceID?
    @Published var selectedLanguage: RecognitionLanguage {
        didSet { settings.recognitionLanguage = selectedLanguage }
    }
    @Published var appLanguage: AppLanguage {
        didSet { settings.appLanguage = appLanguage }
    }
    @Published var timestampMode: TimestampMode {
        didSet { settings.timestampMode = timestampMode }
    }
    @Published var showTimestampDate: Bool {
        didSet { settings.showTimestampDate = showTimestampDate }
    }
    @Published private(set) var selectedEngine: RecognitionEngine {
        didSet { settings.recognitionEngine = selectedEngine }
    }
    /// Voice-detection energy floor; takes effect immediately, even mid-recording.
    @Published var speechEnergyFloor: Float {
        didSet {
            settings.speechEnergyFloor = speechEnergyFloor
            if let transcriber {
                let floor = speechEnergyFloor
                Task { await transcriber.setSpeechEnergyFloor(floor) }
            }
            preview.setSpeechEnergyFloor(speechEnergyFloor)
        }
    }
    /// Trial recognition shown in the settings sheet so the user can tune the threshold.
    let preview = RecognitionPreview()

    private let settings: AppSettings
    private let historyStore: TranscriptHistoryStore
    private var whisperKit: WhisperKit?
    private var transcriber: LiveTranscriber?
    private var startTask: Task<Void, Never>?
    /// Present only while recording.
    private var session: RecordingSession?
    /// Progress updates from decodes up to this one are stale and ignored.
    private var lastFinishedDecode = 0

    var isRecording: Bool { phase == .recording }
    var canRecord: Bool { phase == .ready || phase == .recording }
    var canPreview: Bool { phase == .ready && selectedDeviceID != nil }
    var isPreparing: Bool {
        switch phase {
        case .downloading, .loading: true
        default: false
        }
    }
    var strings: AppStrings { AppStrings(language: appLanguage) }
    private var assembler: SentenceAssembler {
        SentenceAssembler(languageCode: selectedLanguage.code)
    }

    var phaseLabel: String {
        switch phase {
        case .downloading(let progress): strings.downloadingModel(progress)
        case .loading: strings.loadingModel
        case .ready: strings.ready
        case .recording: strings.recognizing
        case .failed(.model(let detail)): strings.modelLoadFailed(detail)
        case .failed(.noInput): strings.chooseInput
        case .failed(.recognition(let detail)): strings.recognitionFailed(detail)
        }
    }

    var selectedDeviceName: String {
        audioDevices.first(where: { $0.id == selectedDeviceID })?.name ?? strings.noInput
    }

    init(settings: AppSettings = AppSettings(), historyStore: TranscriptHistoryStore = TranscriptHistoryStore()) {
        self.settings = settings
        self.historyStore = historyStore
        history = historyStore.load()
        appLanguage = settings.appLanguage
        selectedLanguage = settings.recognitionLanguage
        timestampMode = settings.timestampMode
        showTimestampDate = settings.showTimestampDate
        selectedEngine = settings.recognitionEngine
        speechEnergyFloor = settings.speechEnergyFloor
        Task { await prepare() }
    }

    // MARK: - Model lifecycle

    /// Refreshes the device list and loads the selected engine's model, downloading it first if needed.
    func prepare() async {
        refreshAudioDevices()
        let engine = selectedEngine

        do {
            let modelFolder: URL
            if let cached = WhisperModelStore.cachedModelFolder(for: engine) {
                modelFolder = cached
            } else {
                phase = .downloading(0)
                modelFolder = try await WhisperModelStore.download(engine) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.phase = .downloading(fraction)
                    }
                }
            }

            phase = .loading
            whisperKit = try await WhisperModelStore.load(modelFolder: modelFolder)
            phase = .ready
        } catch {
            phase = .failed(.model(error.localizedDescription))
        }
    }

    func retryPreparation() {
        guard case .failed = phase else { return }
        Task { await prepare() }
    }

    func selectEngine(_ engine: RecognitionEngine) {
        guard engine != selectedEngine, !isRecording else { return }
        selectedEngine = engine
        whisperKit = nil
        phase = .loading
        Task { await prepare() }
    }

    private func refreshAudioDevices() {
        audioDevices = AudioProcessor.getAudioDevices()
        if !audioDevices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = audioDevices.first?.id
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard let whisperKit, !isRecording else { return }
        guard let selectedDeviceID else {
            phase = .failed(.noInput)
            return
        }
        preview.stop()

        session = RecordingSession(startedAt: Date(), baseLines: lines)
        lastFinishedDecode = 0
        let transcriber = LiveTranscriber(
            whisperKit: whisperKit,
            options: Self.decodingOptions(for: selectedLanguage),
            inputDeviceID: selectedDeviceID,
            silenceThreshold: Self.voiceActivityThreshold,
            silenceDelay: Self.silenceCommitDelay,
            speechEnergyFloor: speechEnergyFloor,
            delegate: self
        )
        self.transcriber = transcriber
        phase = .recording

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

    // MARK: - Preview

    /// Recognizes from the selected input with the current settings without touching the transcript.
    func startPreview() {
        guard let whisperKit, canPreview, let selectedDeviceID else { return }
        preview.start(
            whisperKit: whisperKit,
            options: Self.decodingOptions(for: selectedLanguage),
            inputDeviceID: selectedDeviceID,
            silenceThreshold: Self.voiceActivityThreshold,
            silenceDelay: Self.silenceCommitDelay,
            speechEnergyFloor: speechEnergyFloor,
            assembler: assembler
        )
    }

    func stopPreview() {
        preview.stop()
    }

    func stopRecording() {
        startTask?.cancel()
        startTask = nil
        if let transcriber {
            Task { await transcriber.stop() }
        }
        transcriber = nil

        if var session {
            session.commitTrailing(finalize: assembler.terminated)
            lines = session.transcript
        }
        session = nil
        liveText = ""
        phase = .ready
        persistTranscript()
    }

    private struct MicrophoneAccessDenied: LocalizedError {
        var errorDescription: String? { "Microphone access was not granted." }
    }

    private func fail(with detail: String) {
        stopRecording()
        phase = .failed(.recognition(detail))
    }

    // MARK: - Transcript

    /// Empties the screen. The saved record stays in the history; the next committed line starts a new one.
    func clear() {
        session?.clearTranscript()
        lines = []
        liveText = ""
        currentRecordID = nil
    }

    func copyTranscript() {
        let text = lines.map { "[\(timestamp(for: $0))] \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copy(_ line: TranscriptLine) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.text, forType: .string)
    }

    func timestamp(for line: TranscriptLine) -> String {
        line.timestamp(mode: timestampMode, showDate: showTimestampDate)
    }

    /// Stores the session and refreshes the visible lines.
    private func publish(_ session: RecordingSession) {
        self.session = session
        if lines != session.transcript {
            lines = session.transcript
            persistTranscript()
        }
    }

    // MARK: - History

    /// Puts a saved transcript back on screen so the next recording appends to it.
    func resume(_ record: TranscriptRecord) {
        guard !isRecording else { return }
        lines = record.lines
        liveText = ""
        currentRecordID = record.id
    }

    func deleteRecord(_ record: TranscriptRecord) {
        do {
            try historyStore.delete(id: record.id)
        } catch {
            return
        }
        history.removeAll { $0.id == record.id }
        if record.id == currentRecordID {
            currentRecordID = nil
            if !isRecording {
                lines = []
            }
        }
    }

    /// Writes the visible lines to the current record, creating one on the first line.
    private func persistTranscript() {
        guard !lines.isEmpty else { return }
        let now = Date()
        var record: TranscriptRecord
        if let currentRecordID, let existing = history.first(where: { $0.id == currentRecordID }) {
            record = existing
            guard record.lines != lines else { return }
            record.lines = lines
            record.updatedAt = now
        } else {
            record = TranscriptRecord(createdAt: now, lines: lines)
        }
        do {
            try historyStore.save(record)
        } catch {
            return
        }
        currentRecordID = record.id
        history.removeAll { $0.id == record.id }
        history.insert(record, at: 0)
    }

    // MARK: - WhisperKit adapters

    private static func decodingOptions(for language: RecognitionLanguage) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language.code,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: language.isAutomatic,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            logProbThreshold: -0.8,
            noSpeechThreshold: 0.4
        )
    }

    static func transcriptLines(
        from segments: [TranscriptionSegment],
        recordingStartedAt: Date
    ) -> [TranscriptLine] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(
                id: "\(segment.id)-\(segment.start)-\(segment.end)",
                start: segment.start,
                end: segment.end,
                recordedAt: recordingStartedAt.addingTimeInterval(TimeInterval(segment.start)),
                text: text
            )
        }
    }
}

// MARK: - LiveTranscriberDelegate

extension TranscriptionController: LiveTranscriberDelegate {
    /// Shows the in-flight text of the current decode as WhisperKit produces it, so the LIVE row
    /// tracks recognition token by token. Updates from a decode that already finished are ignored
    /// because `didDecode` has replaced the preview with the real segments by then.
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
        let assembler = assembler
        let segmentLines = Self.transcriptLines(from: segments, recordingStartedAt: session.startedAt)
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
}
