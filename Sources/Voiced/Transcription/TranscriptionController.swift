import AppKit
import Combine
import CoreAudio
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
    /// The component WhisperKit is loading while `phase` is `.loading`, once it has started on one.
    @Published private(set) var loadingComponent: ModelComponent?
    /// When the current load began, for showing how long it has been running.
    @Published private(set) var loadingStartedAt: Date?
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var liveText = ""
    /// Saved transcripts, most recently updated first.
    @Published private(set) var history: [TranscriptRecord] = []
    /// The history record the visible transcript belongs to, if it has been saved.
    @Published private(set) var currentRecordID: String?
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
    /// Whether the main window stays above other apps' windows.
    @Published var keepWindowOnTop: Bool {
        didSet { settings.keepWindowOnTop = keepWindowOnTop }
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
    /// Level of the selected input, shown under the input picker while the settings sheet is open.
    let inputLevelMonitor = InputLevelMonitor()
    /// Whether captured audio is denoised; takes effect at the next recording or preview.
    @Published var noiseReductionEnabled: Bool {
        didSet { settings.noiseReduction = noiseReductionEnabled }
    }
    /// Background noise measured by `calibrateNoise`, used by the denoiser. Nil until measured.
    @Published private(set) var noiseProfile: NoiseProfile?
    /// True while the input is being sampled to measure the background noise.
    @Published private(set) var isCalibratingNoise = false
    /// Why the last noise calibration did not set a floor; cleared when the next one starts.
    @Published private(set) var noiseCalibrationError: String?

    /// Files of the running recording session, separate from the transcript state in `session`.
    private struct ActiveRecording {
        /// The record directory the audio is written to.
        let recordID: String
        /// Start time of the record, used when the session has to create it.
        let recordCreatedAt: Date
        let recorder: SessionRecorder?
        var info: TranscriptRecord.Session
    }

    private let settings: AppSettings
    private let historyStore: TranscriptHistoryStore
    private let noiseProfileURL: URL
    private let promptFileURL: URL
    private var whisperKit: WhisperKit?
    private var transcriber: LiveTranscriber?
    private var startTask: Task<Void, Never>?
    /// Present only while recording.
    private var session: RecordingSession?
    /// Present only while recording.
    private var activeRecording: ActiveRecording?
    /// Identity and start time reserved for the record the next committed line creates, when there is
    /// no current record. Set by `startNewRecord()` to the moment the button was pressed, or by
    /// `startRecording()` to the recording's start when nothing was reserved.
    private var pendingRecord: (id: String, createdAt: Date)?
    /// Progress updates from decodes up to this one are stale and ignored.
    private var lastFinishedDecode = 0
    /// Forwards the preview's changes as this object's own: views read `preview.isActive` through
    /// the controller to enable their controls, so they must redraw when the preview stops.
    private var previewForwarding: AnyCancellable?

    var isRecording: Bool { phase == .recording }
    var canRecord: Bool { phase == .ready || phase == .recording }
    var canPreview: Bool { phase == .ready && selectedDeviceID != nil }
    var canCalibrateNoise: Bool { canPreview && !preview.isActive && !isCalibratingNoise }
    var isNoiseReductionActive: Bool { noiseReductionEnabled && noiseProfile != nil }
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
        case .loading: strings.loadingModel(loadingComponent)
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

    init(
        settings: AppSettings = AppSettings(),
        historyStore: TranscriptHistoryStore = TranscriptHistoryStore(),
        noiseProfileURL: URL = VoicedDirectory.noiseProfileFile,
        promptFileURL: URL = VoicedDirectory.promptFile
    ) {
        self.settings = settings
        self.historyStore = historyStore
        self.noiseProfileURL = noiseProfileURL
        self.promptFileURL = promptFileURL
        noiseReductionEnabled = settings.noiseReduction
        noiseProfile = NoiseProfile.load(from: noiseProfileURL)
        history = historyStore.load()
        appLanguage = settings.appLanguage
        selectedLanguage = settings.recognitionLanguage
        timestampMode = settings.timestampMode
        showTimestampDate = settings.showTimestampDate
        keepWindowOnTop = settings.keepWindowOnTop
        selectedEngine = settings.recognitionEngine
        speechEnergyFloor = settings.speechEnergyFloor
        pinLanguageToEngine()
        previewForwarding = preview.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
            loadingComponent = nil
            loadingStartedAt = Date()
            whisperKit = try await WhisperModelStore.load(modelFolder: modelFolder) { [weak self] component in
                Task { @MainActor [weak self] in
                    self?.loadingComponent = component
                }
            }
            phase = .ready
        } catch {
            phase = .failed(.model(error.localizedDescription))
        }
        loadingComponent = nil
        loadingStartedAt = nil
    }

    func retryPreparation() {
        guard case .failed = phase else { return }
        Task { await prepare() }
    }

    func selectEngine(_ engine: RecognitionEngine) {
        guard engine != selectedEngine, !isRecording else { return }
        selectedEngine = engine
        selectedLanguage = RecognitionLanguage.defaultChoice(for: engine)
        whisperKit = nil
        phase = .loading
        Task { await prepare() }
    }

    /// Keeps a saved language the model supports; a choice it cannot honour, such as one saved
    /// with a different model, is replaced by the model's default.
    private func pinLanguageToEngine() {
        guard !RecognitionLanguage.choices(for: selectedEngine).contains(selectedLanguage) else { return }
        selectedLanguage = RecognitionLanguage.defaultChoice(for: selectedEngine)
    }

    /// Rescans the attached input devices. Keeps the user's choice while it is still attached;
    /// otherwise falls back to the system's default input, and to the first listed device when
    /// there is no default.
    func refreshAudioDevices() {
        let devices = AudioProcessor.getAudioDevices().filter { !Self.isPrivateAggregateDevice($0.id) }
        // Called whenever the input menu opens; an unchanged list must not redraw the open menu.
        if devices != audioDevices {
            audioDevices = devices
        }
        if !audioDevices.contains(where: { $0.id == selectedDeviceID }) {
            let systemDefault = Self.systemDefaultInputDeviceID()
            selectedDeviceID = audioDevices.first(where: { $0.id == systemDefault })?.id ?? audioDevices.first?.id
        }
    }

    /// Whether `deviceID` is an aggregate device marked private in its composition. Core Audio
    /// creates one of these, named `CADefaultDeviceAggregate-<pid>-<n>`, for every process that
    /// opens the system default input, this app included. It is that process's own view of the
    /// default input, not a device the user can pick, so it is kept out of the input menu.
    /// User-made aggregates from Audio MIDI Setup are not private and stay listed.
    private static func isPrivateAggregateDevice(_ deviceID: DeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAggregate else { return false }

        address.mSelector = kAudioAggregateDevicePropertyComposition
        var composition: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any] else { return false }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    /// The input device selected in System Settings > Sound, or nil when there is none.
    private static func systemDefaultInputDeviceID() -> DeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
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

        let startedAt = Date()
        session = RecordingSession(startedAt: startedAt, baseLines: lines)
        lastFinishedDecode = 0

        // The audio goes into the current record's directory, or into the one reserved by the new
        // button, or into a new one reserved for this session.
        let recordID: String
        let recordCreatedAt: Date
        if let currentRecordID {
            recordID = currentRecordID
            recordCreatedAt = history.first(where: { $0.id == currentRecordID })?.createdAt ?? startedAt
        } else {
            (recordID, recordCreatedAt) = pendingRecord ?? (historyStore.unusedID(startedAt: startedAt), startedAt)
            pendingRecord = (recordID, recordCreatedAt)
        }
        let recorder = makeRecorder(recordID: recordID, startedAt: startedAt)
        activeRecording = ActiveRecording(
            recordID: recordID,
            recordCreatedAt: recordCreatedAt,
            recorder: recorder,
            info: TranscriptRecord.Session(
                startedAt: startedAt,
                inputDevice: selectedDeviceName,
                language: selectedLanguage.code,
                engine: selectedEngine.rawValue,
                audioFile: recorder?.fileName,
                audioOffset: recorder?.startOffset
            )
        )
        let transcriber = LiveTranscriber(
            whisperKit: whisperKit,
            options: currentDecodingOptions(whisperKit: whisperKit),
            inputDeviceID: selectedDeviceID,
            silenceThreshold: Self.voiceActivityThreshold,
            silenceDelay: Self.silenceCommitDelay,
            speechEnergyFloor: speechEnergyFloor,
            delegate: self,
            audioProcessor: makeAudioSource(),
            audioSink: recorder.map { recorder in { @Sendable samples in recorder.append(samples) } }
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

    /// Continues the record's audio file when it already has one, so a record resumed from the
    /// history keeps all its audio in one file; otherwise starts a new file.
    private func makeRecorder(recordID: String, startedAt: Date) -> SessionRecorder? {
        let directory = historyStore.recordDirectory(id: recordID)
        if let record = history.first(where: { $0.id == recordID }),
           let audioFile = record.sessions.last(where: { $0.audioFile != nil })?.audioFile,
           let recorder = SessionRecorder(appendingTo: audioFile, in: directory) {
            return recorder
        }
        return SessionRecorder(directory: directory, startedAt: startedAt)
    }

    // MARK: - Preview

    /// Recognizes from the selected input with the current settings without touching the transcript.
    func startPreview() {
        guard let whisperKit, canPreview, let selectedDeviceID else { return }
        preview.start(
            whisperKit: whisperKit,
            options: currentDecodingOptions(whisperKit: whisperKit),
            inputDeviceID: selectedDeviceID,
            silenceThreshold: Self.voiceActivityThreshold,
            silenceDelay: Self.silenceCommitDelay,
            speechEnergyFloor: speechEnergyFloor,
            assembler: assembler,
            audioProcessor: makeAudioSource()
        )
    }

    func stopPreview() {
        preview.stop()
    }

    // MARK: - Noise calibration

    /// Capture source for recordings and previews: the denoising wrapper when noise reduction is
    /// on and a profile exists, otherwise nil for the model's own processor.
    private func makeAudioSource() -> (any AudioProcessing)? {
        guard noiseReductionEnabled, let noiseProfile else { return nil }
        return DenoisingAudioSource(profile: noiseProfile)
    }

    /// Samples the background noise for a moment, keeps its spectrum as the noise profile and sets
    /// the energy floor just above what the pipeline hears of that noise, denoised when noise
    /// reduction is on. The user should keep quiet meanwhile; speech during the measurement only
    /// makes the profile stronger and pushes the floor up, within its range.
    func calibrateNoise() {
        guard canCalibrateNoise, let selectedDeviceID else { return }
        isCalibratingNoise = true
        noiseCalibrationError = nil
        Task { [weak self] in
            defer { self?.isCalibratingNoise = false }
            do {
                guard await AudioProcessor.requestRecordPermission() else {
                    throw MicrophoneAccessDenied()
                }
                let samples = try await NoiseFloorCalibration.measure(inputDeviceID: selectedDeviceID)
                guard let self else { return }
                guard let profile = NoiseProfile(noise: samples) else {
                    throw NoInputCaptured()
                }
                try profile.save(to: noiseProfileURL)
                noiseProfile = profile
                let heard = noiseReductionEnabled ? SpectralDenoiser.denoise(samples, profile: profile) : samples
                if let floor = NoiseFloorCalibration.floor(forNoise: heard) {
                    speechEnergyFloor = floor
                }
            } catch {
                self?.noiseCalibrationError = error.localizedDescription
            }
        }
    }

    private struct NoInputCaptured: LocalizedError {
        var errorDescription: String? { "No audio was captured from the input device." }
    }

    func stopRecording() {
        startTask?.cancel()
        startTask = nil
        let transcriber = transcriber
        let active = activeRecording
        self.transcriber = nil
        activeRecording = nil

        if var session {
            session.commitTrailing(finalize: assembler.terminated)
            lines = session.transcript
        }
        session = nil
        liveText = ""
        phase = .ready
        persistTranscript()
        pendingRecord = nil

        // The transcriber flushes its last samples into the recorder when it stops, so the file is
        // closed only after that.
        guard var active else { return }
        active.info.endedAt = Date()
        Task {
            await transcriber?.stop()
            let hasAudio = active.recorder?.finish() ?? false
            if !hasAudio {
                active.info.audioFile = nil
            }
            attach(active.info, to: active.recordID, createdAt: active.recordCreatedAt)
        }
    }

    private struct MicrophoneAccessDenied: LocalizedError {
        var errorDescription: String? { "Microphone access was not granted." }
    }

    private func fail(with detail: String) {
        stopRecording()
        phase = .failed(.recognition(detail))
    }

    // MARK: - Transcript

    /// Starts a new record: stops a running recognition, whose last lines and audio stay with the
    /// current record, then empties the screen and detaches from that record, which stays in the
    /// history. The new record is named by the time of the press; the next recording is saved into it.
    func startNewRecord() {
        if isRecording {
            stopRecording()
        }
        lines = []
        liveText = ""
        currentRecordID = nil
        let now = Date()
        pendingRecord = (historyStore.unusedID(startedAt: now), now)
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

    /// Shows the record's directory, with its transcript and audio files, in Finder.
    func openRecordFolder(_ record: TranscriptRecord) {
        NSWorkspace.shared.open(historyStore.recordDirectory(id: record.id))
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
            let (id, createdAt) = pendingRecord ?? (historyStore.unusedID(startedAt: now), now)
            record = TranscriptRecord(id: id, createdAt: createdAt, updatedAt: now, lines: lines)
        }
        store(record, makeCurrent: true)
    }

    /// Adds a finished session to its record. A record that does not exist yet is created when the
    /// session left audio behind, so the recording is kept even though nothing was recognized;
    /// otherwise the empty directory is removed.
    private func attach(_ info: TranscriptRecord.Session, to recordID: String, createdAt: Date) {
        var info = info
        if let audioFile = info.audioFile,
           !FileManager.default.fileExists(atPath: historyStore.recordDirectory(id: recordID).appendingPathComponent(audioFile).path) {
            info.audioFile = nil
        }
        var record: TranscriptRecord
        if let existing = history.first(where: { $0.id == recordID }) {
            record = existing
        } else if info.audioFile != nil {
            record = TranscriptRecord(id: recordID, createdAt: createdAt, lines: [])
        } else {
            historyStore.deleteIfEmpty(id: recordID)
            return
        }
        record.sessions.append(info)
        record.updatedAt = info.endedAt ?? Date()
        // With nothing on screen the next recording continues this record, unless the new button
        // has already reserved a newer record for it.
        store(record, makeCurrent: currentRecordID == nil && pendingRecord == nil)
    }

    /// Saves the record and moves it to the top of the history.
    private func store(_ record: TranscriptRecord, makeCurrent: Bool) {
        do {
            try historyStore.save(record)
        } catch {
            return
        }
        if makeCurrent {
            currentRecordID = record.id
        }
        history.removeAll { $0.id == record.id }
        history.insert(record, at: 0)
    }

    // MARK: - WhisperKit adapters

    private static func decodingOptions(for language: RecognitionLanguage, promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language.code,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: language.isAutomatic,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            // Word timings let sentences be cut inside a Whisper segment, at punctuation. Models
            // fine-tuned on Chinese, and any model given a prompt, tend to return one long
            // punctuated segment per window instead of one segment per clause.
            wordTimestamps: true,
            promptTokens: promptTokens,
            logProbThreshold: -0.8,
            noSpeechThreshold: 0.4
        )
    }

    /// Decoding options for a run starting now: the selected language plus whatever is in
    /// `~/.voiced/prompt.txt` at this moment.
    private func currentDecodingOptions(whisperKit: WhisperKit) -> DecodingOptions {
        let prompt = RecognitionPrompt.load(from: promptFileURL)
        let tokens = whisperKit.tokenizer.flatMap { RecognitionPrompt.tokens(for: prompt, tokenizer: $0) }
        return Self.decodingOptions(for: selectedLanguage, promptTokens: tokens)
    }

    /// Creates `prompt.txt` with its template when needed and opens it in the default text editor.
    func openPromptFile() {
        do {
            try RecognitionPrompt.ensureFileExists(at: promptFileURL)
            NSWorkspace.shared.open(promptFileURL)
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([promptFileURL.deletingLastPathComponent()])
        }
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
        // When every segment of this decode was dropped as noise or a hallucination, right after a
        // pause, there is no pending text yet. Keep the streamed preview on screen instead of
        // blanking the row; the next decode or the pause commit replaces it.
        let draft = assembler.draft(from: session.pendingLines.map(\.text))
        if !draft.isEmpty {
            liveText = draft
        }
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
