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
        didSet {
            settings.recognitionLanguage = selectedLanguage
            // The translator takes the pinned language as the source.
            configureTranslator()
        }
    }
    /// Whisper codes automatic detection picks from, in the order Settings lists them; empty
    /// for any language.
    @Published var detectionLanguages: [String] {
        didSet { settings.detectionLanguages = detectionLanguages }
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
    /// Whether committed lines are translated by `translationRules`.
    @Published var translationEnabled: Bool {
        didSet {
            settings.translation = translationEnabled
            configureTranslator()
        }
    }
    /// Which language each line is translated into, by the language it is in.
    @Published var translationRules: [TranslationRule] {
        didSet {
            guard translationRules != oldValue else { return }
            settings.translationRules = translationRules
            configureTranslator()
        }
    }
    /// Which of a translated line's texts is shown at full size.
    @Published var translationEmphasis: TranslationEmphasis {
        didSet { settings.translationEmphasis = translationEmphasis }
    }
    /// Whether translations of newly recognized lines are read aloud.
    @Published var speakTranslation: Bool {
        didSet {
            settings.speakTranslation = speakTranslation
            if !speakTranslation {
                speaker.stop()
            }
        }
    }
    /// Why the last translation failed; cleared when the translator is next configured.
    @Published private(set) var translationError: String?
    /// The languages the rules translate into, each once, in the rules' order: the ones a voice
    /// can be picked for.
    var translationTargets: [AppLanguage] {
        translationRules.reduce(into: []) { targets, rule in
            if !targets.contains(rule.target) { targets.append(rule.target) }
        }
    }
    /// Translates lines on the device. Nil where the system offers no translation (macOS 14).
    let translator: (any SentenceTranslating)?
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
    /// Whether the voice detector filters what the energy gate lets through, so music and other
    /// non-speech sound is ignored; takes effect at the next recording or preview.
    @Published var voiceFilterEnabled: Bool {
        didSet {
            settings.voiceFilter = voiceFilterEnabled
            if voiceFilterEnabled {
                prepareVoiceFilter()
            }
        }
    }
    /// Folder of the downloaded voice detector model. Nil until it is on disk.
    @Published private(set) var voiceDetectorModelFolder: URL?
    @Published private(set) var isDownloadingVoiceFilter = false
    /// Why the voice filter cannot be used; cleared when the next download starts.
    @Published private(set) var voiceFilterError: String?
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
    /// The translation in flight, at most one at a time.
    private var translationTask: Task<Void, Never>?
    /// Lines the translator rejected since it was last configured, skipped so one bad line does
    /// not hold up the rest.
    private var untranslatableLineIDs: Set<String> = []
    /// Language codes `LineLanguage` found for line texts, nil where it could not tell.
    private var detectedLanguages: [String: String?] = [:]
    /// Lines recognized in this recording whose translation has not been read aloud yet. Lines
    /// already on screen before it, such as a resumed record's, are never read.
    private var unspokenLineIDs: Set<String> = []
    private let speaker = TranslationSpeaker()
    /// Silences every capture while `speaker` plays, so the speech is not recognized as input.
    private let inputMute = InputMute()
    /// Forwards the preview's changes as this object's own: views read `preview.isActive` through
    /// the controller to enable their controls, so they must redraw when the preview stops.
    private var previewForwarding: AnyCancellable?

    var isRecording: Bool { phase == .recording }
    var canRecord: Bool {
        switch phase {
        case .ready, .recording: true
        // A failed recording leaves the model loaded, so the next click simply tries again.
        case .failed(.recognition), .failed(.noInput): whisperKit != nil
        case .downloading, .loading, .failed(.model): false
        }
    }
    var canPreview: Bool { phase == .ready && selectedDeviceID != nil }
    var canCalibrateNoise: Bool { canPreview && !preview.isActive && !isCalibratingNoise }
    var isNoiseReductionActive: Bool { noiseReductionEnabled && noiseProfile != nil }
    var isVoiceFilterActive: Bool { voiceFilterEnabled && voiceDetectorModelFolder != nil }
    var isTranslationAvailable: Bool { translator != nil }
    /// The pairs the rules can translate between; empty when translation is off or unavailable.
    /// A rule for any language takes the pinned recognition language as its source.
    private var translationPairs: [LanguagePair] {
        guard translationEnabled, translator != nil else { return [] }
        return translationRules.reduce(into: []) { pairs, rule in
            let pair = LanguagePair(source: rule.source?.code ?? selectedLanguage.code, target: rule.target.code)
            if pair.source != pair.target, !pairs.contains(pair) { pairs.append(pair) }
        }
    }
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
        promptFileURL: URL = VoicedDirectory.promptFile,
        translator: (any SentenceTranslating)? = nil
    ) {
        self.settings = settings
        self.historyStore = historyStore
        self.noiseProfileURL = noiseProfileURL
        self.promptFileURL = promptFileURL
        // A default argument is evaluated outside the main actor, which the system translator needs.
        self.translator = translator ?? Self.systemTranslator()
        noiseReductionEnabled = settings.noiseReduction
        noiseProfile = NoiseProfile.load(from: noiseProfileURL)
        voiceFilterEnabled = settings.voiceFilter
        voiceDetectorModelFolder = VoiceDetectorModelStore.cachedModelFolder()
        history = historyStore.load()
        appLanguage = settings.appLanguage
        selectedLanguage = settings.recognitionLanguage
        detectionLanguages = settings.detectionLanguages
        timestampMode = settings.timestampMode
        showTimestampDate = settings.showTimestampDate
        keepWindowOnTop = settings.keepWindowOnTop
        selectedEngine = settings.recognitionEngine
        speechEnergyFloor = settings.speechEnergyFloor
        translationEnabled = settings.translation
        // Before rules, every line went into one language.
        translationRules = settings.translationRules?.withoutRepeatedSources
            ?? [TranslationRule(source: nil, target: settings.translationLanguage ?? settings.appLanguage)]
        translationEmphasis = settings.translationEmphasis
        speakTranslation = settings.speakTranslation
        pinLanguageToEngine()
        configureTranslator()
        speaker.onPlayingChange = { [inputMute] playing in
            inputMute.isMuted = playing
        }
        previewForwarding = preview.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if voiceFilterEnabled {
            prepareVoiceFilter()
        }
        Task { await prepare() }
    }

    /// The system's on-device translation, where the system has one.
    private static func systemTranslator() -> (any SentenceTranslating)? {
        if #available(macOS 15, *) {
            return AppleTranslator()
        }
        return nil
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

    /// Puts every preference back to its default, as on a first launch, and applies it. The
    /// history, the noise profile and the prompt file are not preferences and are kept. Reloads
    /// the model when the default engine is not the one loaded.
    func resetSettings() {
        guard !isRecording, !preview.isActive else { return }
        settings.reset()
        appLanguage = settings.appLanguage
        keepWindowOnTop = settings.keepWindowOnTop
        timestampMode = settings.timestampMode
        showTimestampDate = settings.showTimestampDate
        speechEnergyFloor = settings.speechEnergyFloor
        noiseReductionEnabled = settings.noiseReduction
        voiceFilterEnabled = settings.voiceFilter
        if settings.recognitionEngine != selectedEngine {
            selectEngine(settings.recognitionEngine)
        }
        selectedLanguage = settings.recognitionLanguage
        pinLanguageToEngine()
        detectionLanguages = settings.detectionLanguages
        translationEnabled = settings.translation
        translationRules = [TranslationRule(source: nil, target: settings.appLanguage)]
        translationEmphasis = settings.translationEmphasis
        speakTranslation = settings.speakTranslation
        // The assignments above wrote each default back; start the file over so it holds none.
        settings.reset()
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
        unspokenLineIDs = []
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
            voiceDetector: makeVoiceDetector(),
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
            voiceDetector: makeVoiceDetector(),
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
    private func makeAudioSource() -> any AudioProcessing {
        MicrophoneAudioSource(profile: noiseReductionEnabled ? noiseProfile : nil, mute: inputMute)
    }

    // MARK: - Voice filter

    /// The voice detector for a recording or preview: nil when the filter is off or its model is
    /// not on disk, in which case speech is judged by energy alone.
    private func makeVoiceDetector() -> SileroVoiceDetector? {
        guard voiceFilterEnabled, let voiceDetectorModelFolder else { return nil }
        do {
            return try SileroVoiceDetector(modelFolder: voiceDetectorModelFolder)
        } catch {
            voiceFilterError = error.localizedDescription
            return nil
        }
    }

    /// Makes sure the voice detector's model is on disk, downloading it when it is not.
    private func prepareVoiceFilter() {
        if voiceDetectorModelFolder == nil {
            voiceDetectorModelFolder = VoiceDetectorModelStore.cachedModelFolder()
        }
        guard voiceDetectorModelFolder == nil, !isDownloadingVoiceFilter else { return }
        isDownloadingVoiceFilter = true
        voiceFilterError = nil
        Task { [weak self] in
            defer { self?.isDownloadingVoiceFilter = false }
            do {
                let folder = try await VoiceDetectorModelStore.download()
                self?.voiceDetectorModelFolder = folder
            } catch {
                self?.voiceFilterError = error.localizedDescription
            }
        }
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
            show(session.transcript.keepingTranslations(from: lines))
        }
        session = nil
        liveText = ""
        phase = .ready
        persistTranscript()
        translateVisibleLines()
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
        let text = lines.map { line in
            let texts = displayTexts(for: line)
            let entry = "[\(timestamp(for: line))] \(texts.primary)"
            return texts.secondary.map { entry + "\n" + $0 } ?? entry
        }
        .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copy(_ line: TranscriptLine) {
        let texts = displayTexts(for: line)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texts.secondary.map { texts.primary + "\n" + $0 } ?? texts.primary, forType: .string)
    }

    func timestamp(for line: TranscriptLine) -> String {
        line.timestamp(mode: timestampMode, showDate: showTimestampDate)
    }

    /// Stores the session and refreshes the visible lines.
    private func publish(_ session: RecordingSession) {
        self.session = session
        let transcript = session.transcript.keepingTranslations(from: lines)
        if lines != transcript {
            show(transcript)
            persistTranscript()
            translateVisibleLines()
        }
    }

    /// Replaces the visible lines with a recording's transcript, marking the lines it added to
    /// have their translation read aloud.
    private func show(_ transcript: [TranscriptLine]) {
        let shownIDs = Set(lines.map(\.id))
        unspokenLineIDs.formUnion(transcript.map(\.id).filter { !shownIDs.contains($0) })
        lines = transcript
    }

    // MARK: - Translation

    /// The texts a row shows for `line`: the sentence alone, or, with a translation, the main
    /// text first and the other second.
    func displayTexts(for line: TranscriptLine) -> (primary: String, secondary: String?) {
        guard let translation = translation(for: line) else { return (line.text, nil) }
        switch translationEmphasis {
        case .original: return (line.text, translation)
        case .translation: return (translation, line.text)
        }
    }

    /// The translation shown with `line`: only while translation is on and it is in the language
    /// currently chosen. A line already in that language shows none.
    private func translation(for line: TranscriptLine) -> String? {
        guard let pair = translationPair(for: line), let translation = line.translation, translation.language == pair.target else { return nil }
        return translation.displayText
    }

    /// The pair `line` is translated by: from the rule for the pinned recognition language, or,
    /// with automatic recognition, for the language the line reads as. Nil leaves it untranslated.
    private func translationPair(for line: TranscriptLine) -> LanguagePair? {
        guard translationEnabled, translator != nil else { return nil }
        let language = selectedLanguage.code ?? detectedLanguage(of: line.text)
        guard let rule = translationRules.rule(for: language) else { return nil }
        let pair = LanguagePair(source: rule.source?.code ?? selectedLanguage.code, target: rule.target.code)
        return pair.source == pair.target ? nil : pair
    }

    /// `LineLanguage.code(of:)`, remembered per text: rows ask on every redraw.
    private func detectedLanguage(of text: String) -> String? {
        if let known = detectedLanguages[text] { return known }
        let code = LineLanguage.code(of: text)
        detectedLanguages[text] = code
        return code
    }

    /// Points the translator at the current languages, forgets earlier failures and translates
    /// what is on screen.
    private func configureTranslator() {
        guard let translator else { return }
        translationTask?.cancel()
        translationTask = nil
        translationError = nil
        untranslatableLineIDs = []
        // Lines recognized before the change are translated quietly rather than read in a burst.
        unspokenLineIDs = []
        translator.setPairs(translationPairs)
        translateVisibleLines()
    }

    /// Translates the visible lines that are not yet in the target language, newest first and
    /// one at a time, so a sentence just committed is not queued behind an old transcript.
    private func translateVisibleLines() {
        guard let translator, translationTask == nil else { return }
        let next = lines.lazy.reversed().compactMap { line in
            self.translationPair(for: line).map { (line, $0) }
        }.first { line, pair in
            line.needsTranslation(into: pair.target) && !self.untranslatableLineIDs.contains(line.id)
        }
        guard let (line, pair) = next else { return }
        translationTask = Task { [weak self] in
            var translation: TranslatedText?
            do {
                translation = try await translator.translate(line.text, pair: pair)
            } catch is CancellationError {
                // Translation was turned off or reconfigured; that call has already moved on.
                return
            } catch {
                self?.translationError = error.localizedDescription
                self?.untranslatableLineIDs.insert(line.id)
            }
            guard let self, !Task.isCancelled else { return }
            translationTask = nil
            if let translation {
                apply(translation, to: line.id)
            }
            translateVisibleLines()
        }
    }

    /// Attaches a finished translation to its line, if it is still on screen, and saves it.
    private func apply(_ translation: TranslatedText, to lineID: String) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[index] = lines[index].translated(translation)
        persistTranscript()
        if unspokenLineIDs.remove(lineID) != nil, speakTranslation, let text = translation.displayText {
            speaker.speak(text, language: translation.language, voiceID: settings.speechVoices[translation.language])
        }
    }

    /// The system voice picked to read `language`; nil reads it in the default voice.
    func speechVoiceID(for language: AppLanguage) -> String? {
        settings.speechVoices[language.code]
    }

    func setSpeechVoiceID(_ voiceID: String?, for language: AppLanguage) {
        objectWillChange.send()
        settings.speechVoices[language.code] = voiceID
    }

    /// The installed voices that can read `language`.
    func speechVoices(for language: AppLanguage) -> [SpeechVoice] {
        TranslationSpeaker.voices(for: language.code)
    }

    /// Reads a sample sentence in `language` in its chosen voice, in place of anything being read.
    func previewSpeechVoice(for language: AppLanguage) {
        speaker.stop()
        speaker.speak(AppStrings(language: language).speechSample, language: language.code, voiceID: speechVoiceID(for: language))
    }

    // MARK: - History

    /// Puts a saved transcript back on screen so the next recording appends to it.
    func resume(_ record: TranscriptRecord) {
        guard !isRecording else { return }
        lines = record.lines
        liveText = ""
        currentRecordID = record.id
        translateVisibleLines()
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
        (whisperKit.textDecoder as? LanguageLimitedDecoder)?.allowedLanguages = selectedLanguage.isAutomatic && !detectionLanguages.isEmpty ? Set(detectionLanguages) : nil
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
