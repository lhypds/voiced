import AVFoundation
import Combine
import SwiftUI
import VoicedCore
@preconcurrency import WhisperKit

/// Mobile presentation and lifecycle adapter. Recognition, sentence commits, settings,
/// models, recordings and history are implemented by VoicedCore on both platforms.
@MainActor
final class MobileTranscriber: ObservableObject {
    @Published var engineID: String {
        didSet {
            settings.recognitionEngine = engine
            if !RecognitionLanguage.choices(for: engine).contains(where: { $0.id == languageID }) {
                languageID = RecognitionLanguage.defaultChoice(for: engine).id
            }
        }
    }
    @Published var languageID: String { didSet { settings.recognitionLanguage = RecognitionLanguage.choice(id: languageID); configureTranslation() } }
    @Published var detectionLanguages: [String] { didSet { settings.detectionLanguages = detectionLanguages } }
    @Published var appLanguage: AppLanguage { didSet { settings.appLanguage = appLanguage; configureAI() } }
    @Published var timestampID: String { didSet { settings.timestampMode = TimestampMode(rawValue: timestampID) ?? .current } }
    @Published var speechEnergyFloor: Float {
        didSet {
            settings.speechEnergyFloor = speechEnergyFloor
            if let transcriber { let floor = speechEnergyFloor; Task { await transcriber.setSpeechEnergyFloor(floor) } }
        }
    }
    @Published var inputGain: Float { didSet { settings.inputGain = inputGain; InputGain.shared.decibels = inputGain } }
    @Published var showDate: Bool { didSet { settings.showTimestampDate = showDate } }
    @Published var lineClickAction: LineClickAction { didSet { settings.lineClickAction = lineClickAction; stopPlayback() } }
    @Published var noiseReduction: Bool { didSet { settings.noiseReduction = noiseReduction } }
    @Published var voiceFilter: Bool { didSet { settings.voiceFilter = voiceFilter } }
    @Published var translationEnabled: Bool { didSet { settings.translation = translationEnabled; configureTranslation() } }
    @Published var translationRules: [TranslationRule] { didSet { settings.translationRules = translationRules; configureTranslation() } }
    @Published var translationEmphasis: TranslationEmphasis { didSet { settings.translationEmphasis = translationEmphasis } }
    @Published var speakTranslation: Bool { didSet { settings.speakTranslation = speakTranslation; if !speakTranslation { speaker.stop() } } }
    @Published var speechVoices: [String: String] { didSet { settings.speechVoices = speechVoices } }
    @Published var apiKey: String { didSet { settings.openAIAPIKey = apiKey; configureAI() } }
    @Published var aiHintsEnabled: Bool { didSet { settings.aiHints = aiHintsEnabled; configureAI() } }
    @Published var hintModel: String { didSet { settings.aiHintModel = hintModel; configureAI() } }
    @Published var hintLanguage: AppLanguage? { didSet { settings.aiHintLanguage = hintLanguage; configureAI() } }
    @Published var hintWebSearch: Bool { didSet { settings.aiHintWebSearch = hintWebSearch; configureAI() } }
    @Published var summaryEnabled: Bool { didSet { settings.aiSummary = summaryEnabled } }
    @Published var summaryModel: String { didSet { settings.summaryModel = summaryModel } }
    @Published var promptText = ""
    @Published var previewActive = false
    @Published var previewText = ""
    @Published var calibrating = false
    @Published var downloadingVoiceFilter = false
    @Published var noiseProfile: NoiseProfile? { didSet { inputLevelMonitor.setNoiseProfile(noiseProfile) } }
    @Published var translationError: String?
    @Published var playingLineID: String?
    @Published var playingRecordID: String?
    @Published var summaryPresentation: SummaryPresentation?
    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var selectedInputID: String?
    @Published var records: [TranscriptRecord] = []
    @Published var current = TranscriptRecord(lines: [])
    @Published var liveText = ""
    @Published var status = ""
    @Published var loadingStartedAt: Date?
    @Published var loadingComponent: ModelComponent?
    @Published var downloadProgress: Double?
    @Published var busy = false
    @Published var recording = false
    @Published var stopping = false
    @Published var error: String?
    @Published var level: Float = 0
    private let dataRoot: URL
    private let settings: AppSettings
    let inputLevelMonitor: InputLevelMonitor
    private var meterForwarding: AnyCancellable?
    private var inputMeterRequested = false
    let ai: TranscriptAI
    let translator: (any SentenceTranslating)?
    private let inputMute = InputMute()
    private let speaker = TranslationSpeaker()
    private let playback = AudioPlayback()
    private var playbackTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var translationGeneration = UUID()
    private var activePairs: [LanguagePair] = []
    private var failedTranslations: Set<String> = []
    private var unspokenIDs: Set<String> = []
    private var aiForwarding: AnyCancellable?
    private var calibrationTask: Task<Void, Never>?
    private let historyStore: TranscriptHistoryStore
    private var whisper: WhisperKit?
    private var loadedEngine: RecognitionEngine?
    private var transcriber: LiveTranscriber?
    private var session: RecordingSession?
    private var sessionLanguage = RecognitionLanguage.automatic
    private var recorder: SessionRecorder?
    private var sessionInfo: TranscriptRecord.Session?
    private var lastFinishedDecode = 0
    private var preparationID = UUID()
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    var engine: RecognitionEngine { RecognitionEngine(rawValue: engineID) ?? .platformDefault }
    var locked: Bool { busy || recording || stopping || previewActive || calibrating || downloadingVoiceFilter }
    var translationAvailable: Bool { translator != nil }
    var canSummarize: Bool { summaryEnabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hints: [TranscriptHint] { ai.hints }
    var hintError: String? { ai.hintError }
    var strings: AppStrings { AppStrings(language: appLanguage) }
    var currentText: String { export(current.lines) }
    var translationTargets: [AppLanguage] { Array(Set(translationRules.map(\.target))).sorted { $0.rawValue < $1.rawValue } }

    private var assembler: SentenceAssembler { SentenceAssembler(language: sessionLanguage) }

    init(directory: URL = VoicedDirectory.root, aiService: TranscriptAI? = nil, translationService: (any SentenceTranslating)? = nil) {
        dataRoot = directory
        let settingsFile = directory.appendingPathComponent("settings.json")
        MobileDataMigration.importSettings(from: .standard, into: settingsFile)
        settings = AppSettings(fileURL: settingsFile)
        historyStore = TranscriptHistoryStore(directory: directory.appendingPathComponent("history", isDirectory: true))
        ai = aiService ?? TranscriptAI()
        inputLevelMonitor = InputLevelMonitor(makeCapture: { AudioCapture() })
        if let translationService { translator = translationService }
        else if #available(iOS 18, *) { translator = AppleTranslator() } else { translator = nil }
        detectionLanguages = settings.detectionLanguages
        appLanguage = settings.appLanguage
        lineClickAction = settings.lineClickAction
        noiseReduction = settings.noiseReduction
        voiceFilter = settings.voiceFilter
        noiseProfile = NoiseProfile.load(from: dataRoot.appendingPathComponent("noise-profile.json"))
        translationEnabled = settings.translation
        translationRules = settings.translationRules?.withoutRepeatedSources
            ?? [TranslationRule(source: nil, target: settings.translationLanguage ?? settings.appLanguage)]
        translationEmphasis = settings.translationEmphasis
        speakTranslation = settings.speakTranslation
        speechVoices = settings.speechVoices
        apiKey = settings.openAIAPIKey ?? ""
        aiHintsEnabled = settings.aiHints
        hintModel = settings.aiHintModel
        hintLanguage = settings.aiHintLanguage
        hintWebSearch = settings.aiHintWebSearch
        summaryEnabled = settings.aiSummary
        summaryModel = settings.summaryModel
        engineID = settings.recognitionEngine.rawValue
        languageID = settings.recognitionLanguage.id
        timestampID = settings.timestampMode.rawValue
        showDate = settings.showTimestampDate
        speechEnergyFloor = settings.speechEnergyFloor
        inputGain = settings.inputGain
        InputGain.shared.decibels = settings.inputGain
        do {
            try MobileDataMigration.importHistory(from: directory.appendingPathComponent("history.json"), into: historyStore)
        } catch { self.error = "迁移历史记录失败：\(error.localizedDescription)" }
        records = historyStore.load()
        promptText = (try? String(contentsOf: dataRoot.appendingPathComponent("prompt.txt"), encoding: .utf8)) ?? RecognitionPrompt.template
        configureAI()
        configureTranslation()
        status = strings.ready
        inputLevelMonitor.setNoiseProfile(noiseProfile)
        meterForwarding = inputLevelMonitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        aiForwarding = ai.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        speaker.onPlayingChange = { [inputMute] playing in inputMute.isMuted = playing }
        playback.onFinish = { [weak self] in self?.stopPlayback() }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == AVAudioSession.routeChangeNotification,
                   let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
                Task { @MainActor in
                    guard let self else { return }
                    if note.name == UIApplication.didBecomeActiveNotification { self.startInputMeter(); return }
                    if note.name == AVAudioSession.interruptionNotification,
                       let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                       raw == AVAudioSession.InterruptionType.ended.rawValue { self.startInputMeter(); return }
                    if note.name == AVAudioSession.routeChangeNotification && (self.busy || (!self.recording && !self.previewActive)) { return }
                    self.stop()
                    self.inputLevelMonitor.stop()
                    if note.name == UIApplication.didEnterBackgroundNotification { self.speaker.stop(); self.stopPlayback() }
                }
            })
        }
    }

    /// Starts a new record, as on macOS: a running recognition or preview is stopped first, and its
    /// last lines and audio stay with the current record, which remains in the history.
    func newRecord() {
        // Calibration and the voice-filter download run from the settings sheet, not the main screen.
        guard !calibrating, !downloadingVoiceFilter else { return }
        stopPlayback()
        if recording || busy || previewActive || stopping {
            stop()
            // Finishing commits the trailing sentence into `current`, so detach only afterwards.
            let finishing = task
            Task { [weak self] in
                await finishing?.value
                self?.detachFromCurrentRecord()
            }
            return
        }
        detachFromCurrentRecord()
    }

    private func detachFromCurrentRecord() {
        save()
        stopPlayback()
        current = TranscriptRecord(lines: [])
        ai.reset()
        configureTranslation()
        liveText = ""
    }

    func start() { begin(preview: false) }
    func startPreview() { begin(preview: true) }

    private func begin(preview: Bool) {
        guard !locked else { return }
        stopPlayback()
        speaker.stop()
        inputLevelMonitor.stop()
        let preparationID = UUID()
        self.preparationID = preparationID
        busy = true
        loadingStartedAt = nil
        loadingComponent = nil
        downloadProgress = nil
        error = nil
        task = Task {
            do {
                status = "请求麦克风权限…"
                let permitted = await AVAudioApplication.requestRecordPermission()
                try checkPreparation(preparationID)
                guard permitted else {
                    throw NSError(domain: "Voiced", code: 3, userInfo: [NSLocalizedDescriptionKey: "请在系统设置 → Voiced 中允许麦克风访问。"])
                }
                let selected = engine
                let chosen = RecognitionLanguage.choice(id: languageID)
                let language = RecognitionLanguage.choices(for: selected).contains(chosen) ? chosen : RecognitionLanguage.defaultChoice(for: selected)
                if whisper == nil || loadedEngine != selected {
                    whisper = nil
                    loadedEngine = nil
                    let folder: URL
                    if let cached = WhisperModelStore.cachedModelFolder(for: selected) { folder = cached }
                    else {
                        status = "首次下载模型，请保持应用在前台…"
                        downloadProgress = 0
                        folder = try await WhisperModelStore.download(selected) { [weak self] fraction in
                            Task { @MainActor in
                                guard let self, self.preparationID == preparationID, self.busy, self.downloadProgress != nil else { return }
                                self.downloadProgress = fraction
                                self.status = self.strings.downloadingModel(fraction)
                            }
                        }
                    }
                    try checkPreparation(preparationID)
                    downloadProgress = nil
                    loadingStartedAt = Date()
                    status = strings.loadingModel
                    let loaded = try await WhisperModelStore.load(modelFolder: folder) { [weak self] component in
                        Task { @MainActor in
                            guard let self, self.preparationID == preparationID, self.busy, self.loadingStartedAt != nil else { return }
                            self.loadingComponent = component
                            self.status = self.strings.loadingModel(component)
                        }
                    }
                    try checkPreparation(preparationID)
                    whisper = loaded
                    loadingStartedAt = nil
                    loadingComponent = nil
                    loadedEngine = selected
                }
                try checkPreparation(preparationID)
                guard let whisper else { throw CancellationError() }
                let detector: SileroVoiceDetector?
                if voiceFilter {
                    status = "加载人声检测模型…"
                    let folder: URL
                    if let cached = VoiceDetectorModelStore.cachedModelFolder() { folder = cached }
                    else { folder = try await VoiceDetectorModelStore.download() }
                    detector = try SileroVoiceDetector(modelFolder: folder)
                } else { detector = nil }
                try checkPreparation(preparationID)
                let startedAt = Date()
                if !preview && !records.contains(where: { $0.id == current.id }) {
                    current = TranscriptRecord(id: historyStore.unusedID(startedAt: startedAt), createdAt: startedAt, lines: [])
                }
                session = RecordingSession(startedAt: startedAt, baseLines: preview ? [] : current.lines)
                sessionLanguage = language
                lastFinishedDecode = 0
                liveText = ""
                previewText = ""
                unspokenIDs = []
                previewActive = preview
                let recorder: SessionRecorder?
                if preview { recorder = nil }
                else {
                    let directory = historyStore.recordDirectory(id: current.id)
                    if let file = current.sessions.last(where: { $0.audioFile != nil })?.audioFile,
                       let appended = SessionRecorder(appendingTo: file, in: directory) { recorder = appended }
                    else { recorder = SessionRecorder(directory: directory, startedAt: startedAt) }
                }
                self.recorder = recorder
                sessionInfo = preview ? nil : TranscriptRecord.Session(startedAt: startedAt, inputDevice: "iOS microphone", language: language.code,
                                                       engine: selected.rawValue, audioFile: recorder?.fileName, audioOffset: recorder?.startOffset)
                let prompt = RecognitionPrompt.load(from: dataRoot.appendingPathComponent("prompt.txt"))
                let tokens = whisper.tokenizer.flatMap { RecognitionPrompt.tokens(for: prompt, tokenizer: $0) }
                (whisper.textDecoder as? LanguageLimitedDecoder)?.allowedLanguages = language.isAutomatic && !detectionLanguages.isEmpty ? Set(detectionLanguages) : nil
                let source = MicrophoneAudioSource(capture: AudioCapture(), profile: noiseReduction ? noiseProfile : nil, mute: inputMute)
                let transcriber = LiveTranscriber(whisperKit: whisper, options: TranscriptionLogic.decodingOptions(for: language, promptTokens: tokens),
                    inputDeviceID: selectedInputID, silenceThreshold: LiveTranscriber.defaultSilenceThreshold, silenceDelay: LiveTranscriber.defaultSilenceDelay, speechEnergyFloor: settings.speechEnergyFloor,
                    voiceDetector: detector, delegate: self, audioProcessor: source,
                    levelHandler: { [weak self] value in Task { @MainActor in self?.level = value } },
                    audioSink: { recorder?.append($0) })
                self.transcriber = transcriber
                try await transcriber.start()
                if var info = sessionInfo {
                    info.inputDevice = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "iOS microphone"
                    sessionInfo = info
                }
                // An interruption during asynchronous startup must not leave a live capture behind.
                try checkPreparation(preparationID)
                busy = false
                recording = !preview
                UIApplication.shared.isIdleTimerDisabled = true
                status = preview ? strings.startPreview : strings.subtitle
            } catch is CancellationError {
                guard self.preparationID == preparationID else { return }
                await finishRecording()
            } catch {
                guard self.preparationID == preparationID else { return }
                self.error = error.localizedDescription
                await finishRecording()
            }
        }
    }

    private func checkPreparation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard preparationID == id else { throw CancellationError() }
    }

    func stop() {
        if calibrating { calibrationTask?.cancel(); return }
        if busy {
            preparationID = UUID()
            task?.cancel()
            task = nil
            busy = false
            loadingStartedAt = nil
            loadingComponent = nil
            downloadProgress = nil
            status = strings.ready
            if transcriber != nil {
                stopping = true
                task = Task { await finishRecording() }
            } else {
                startInputMeter()
            }
            return
        }
        guard recording || previewActive, !stopping else { return }
        recording = false
        stopping = true
        status = "正在完成最后一段…"
        task = Task { await finishRecording() }
    }

    private func finishRecording() async {
        let active = transcriber
        transcriber = nil
        await active?.stop()
        let wasPreview = previewActive
        if var session, !wasPreview {
            session.commitTrailing(finalize: assembler.terminated)
            publish(session)
        }
        session = nil
        let hasAudio = recorder?.finish() ?? false
        recorder = nil
        if var info = sessionInfo {
            info.endedAt = Date()
            if !hasAudio { info.audioFile = nil }
            current.sessions.append(info)
        }
        sessionInfo = nil
        if !wasPreview { save(); translateVisibleLines(); ai.update(current.lines) }
        if !wasPreview && current.lines.isEmpty && !hasAudio { historyStore.deleteIfEmpty(id: current.id) }
        busy = false
        loadingStartedAt = nil
        loadingComponent = nil
        downloadProgress = nil
        recording = false
        previewActive = false
        stopping = false
        liveText = ""
        level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        status = strings.ready
        startInputMeter()
    }

    func save() {
        guard !current.lines.isEmpty || current.sessions.contains(where: { $0.audioFile != nil }) else { return }
        current.updatedAt = Date()
        do {
            try historyStore.save(current)
            records = historyStore.load()
        } catch { self.error = "保存历史记录失败：\(error.localizedDescription)" }
    }

    func delete(at offsets: IndexSet) {
        for record in offsets.map({ records[$0] }) {
            do {
                try historyStore.delete(id: record.id)
                ai.forget(recordID: record.id)
                if playingRecordID == record.id { stopPlayback() }
                if current.id == record.id { current = TranscriptRecord(lines: []); ai.reset(); configureTranslation() }
            } catch { self.error = "删除历史记录失败：\(error.localizedDescription)" }
        }
        records = historyStore.load()
    }
}

extension MobileTranscriber: LiveTranscriberDelegate {
    func transcriber(_ transcriber: LiveTranscriber, didUpdateLiveText text: String, decode: Int) {
        guard self.transcriber === transcriber, decode > lastFinishedDecode, session != nil else { return }
        let trimmed = HallucinationFilter.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { if previewActive { previewText = assembler.normalized(trimmed) } else { liveText = assembler.normalized(trimmed) } }
    }

    func transcriber(_ transcriber: LiveTranscriber, didDecode segments: [TranscriptionSegment], decode: Int) -> Float {
        guard self.transcriber === transcriber, var session else { return 0 }
        lastFinishedDecode = max(lastFinishedDecode, decode)
        session.update(segments: segments, assembler: assembler)
        let draft = assembler.draft(from: session.pendingLines.map(\.text))
        if !draft.isEmpty { if previewActive { previewText = draft } else { liveText = draft } }
        publish(session)
        return session.committedEnd
    }

    func transcriberDidDetectPause(_ transcriber: LiveTranscriber) -> Float {
        guard self.transcriber === transcriber, var session else { return 0 }
        session.commitTrailing(finalize: assembler.terminated)
        liveText = ""
        if previewActive { previewText = session.transcript.last?.text ?? previewText }
        publish(session)
        return session.committedEnd
    }

    func transcriber(_ transcriber: LiveTranscriber, didFailWith error: Error) {
        guard self.transcriber === transcriber else { return }
        self.error = error.localizedDescription
        stop()
    }

    private func publish(_ session: RecordingSession) {
        self.session = session
        guard !previewActive else { return }
        let transcript = session.transcript.keepingTranslations(from: current.lines)
        guard current.lines != transcript else { return }
        unspokenIDs.formUnion(Set(transcript.map(\.id)).subtracting(current.lines.map(\.id)))
        current.lines = transcript
        save()
        translateVisibleLines()
        ai.update(current.lines)
    }
}

struct SummaryPresentation: Identifiable {
    let id: String
    let text: String
}

extension MobileTranscriber {
    func localized(_ key: String) -> String {
        let code = appLanguage == .chinese ? "zh-Hans" : appLanguage.code
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func configureAI() {
        ai.configure(.init(apiKey: apiKey, hintsEnabled: aiHintsEnabled, hintModel: hintModel,
                           webSearch: hintWebSearch, hintLanguage: hintLanguage ?? appLanguage), existingLines: current.lines)
    }

    func summarize(_ record: TranscriptRecord) {
        guard canSummarize else { return }
        Task {
            if let text = await ai.summarize(record, apiKey: apiKey, model: summaryModel, language: appLanguage,
                                             enabled: summaryEnabled, store: historyStore) {
                summaryPresentation = SummaryPresentation(id: record.id, text: text)
            }
        }
    }

    func hasSummary(_ record: TranscriptRecord) -> Bool { historyStore.hasSummary(id: record.id) }
    func openSummary(_ record: TranscriptRecord) {
        do {
            let text = try String(contentsOf: historyStore.summaryFile(id: record.id), encoding: .utf8)
            summaryPresentation = SummaryPresentation(id: record.id, text: text)
        } catch { self.error = error.localizedDescription }
    }

    func resume(_ record: TranscriptRecord) {
        guard !locked else { return }
        stopPlayback()
        current = records.first(where: { $0.id == record.id }) ?? record
        ai.reset(existingLines: current.lines)
        liveText = ""
        configureTranslation()
    }

    func audioURLs(for record: TranscriptRecord) -> [URL] {
        var seen: Set<String> = []
        return record.sessions.compactMap(\.audioFile).filter { seen.insert($0).inserted }
            .map { historyStore.recordDirectory(id: record.id).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func export(_ lines: [TranscriptLine]) -> String {
        TranscriptionLogic.export(lines, mode: TimestampMode(rawValue: timestampID) ?? .current, showDate: showDate, displayTexts: displayTexts)
    }

    func displayTexts(_ line: TranscriptLine) -> (primary: String, secondary: String?) {
        guard translationEnabled, let pair = translationPair(for: line),
              line.translation?.language == pair.target, let translated = line.translation?.displayText else { return (line.text, nil) }
        return translationEmphasis == .translation ? (translated, line.text) : (line.text, translated)
    }

    /// Returns true when the tap copied the line, so the view can confirm it with a toast.
    @discardableResult
    func tap(_ line: TranscriptLine, in record: TranscriptRecord) -> Bool {
        if playback.isPlaying { stopPlayback(); return false }
        if lineClickAction == .play && !recording && !previewActive { play(record, from: line); return false }
        let texts = displayTexts(line)
        UIPasteboard.general.string = texts.secondary.map { texts.primary + "\n" + $0 } ?? texts.primary
        return true
    }

    func play(_ record: TranscriptRecord, from line: TranscriptLine? = nil) {
        guard !locked else { return }
        if playback.isPlaying { stopPlayback(); return }
        let url: URL
        let time: TimeInterval
        if let line {
            guard let position = record.audioPosition(of: line) else { return }
            url = historyStore.recordDirectory(id: record.id).appendingPathComponent(position.file)
            time = position.time
        } else {
            guard let file = audioURLs(for: record).first else { return }
            url = file
            time = 0
        }
        do {
            speaker.stop()
            try prepareOutput()
            try playback.play(url, from: time)
            playingRecordID = record.id
            let cues = record.lines.compactMap { line -> (id: String, time: TimeInterval)? in
                guard let position = record.audioPosition(of: line), position.file == url.lastPathComponent else { return nil }
                return (line.id, position.time)
            }.sorted { $0.time < $1.time }
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let now = self.playback.currentTime else { return }
                    // Assign only on a change: every @Published write, even of the same value,
                    // redraws the whole home list, which made scrolling stutter during playback.
                    let id = cues.last(where: { $0.time <= now })?.id
                    if id != self.playingLineID { self.playingLineID = id }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playback.stop()
        playingLineID = nil
        playingRecordID = nil
    }

    private func prepareOutput() throws {
        if !recording && !previewActive {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        }
    }

    private func translationPair(for line: TranscriptLine) -> LanguagePair? {
        guard translationEnabled, translator != nil else { return nil }
        let language = RecognitionLanguage.choice(id: languageID).code ?? LineLanguage.code(of: line.text)
        guard let rule = translationRules.rule(for: language), let source = rule.source?.code ?? language else { return nil }
        return source == rule.target.code ? nil : LanguagePair(source: source, target: rule.target.code)
    }

    func configureTranslation() {
        translationGeneration = UUID()
        translationTask?.cancel()
        translationTask = nil
        translationError = nil
        failedTranslations = []
        unspokenIDs = []
        activePairs = []
        guard translationEnabled, let translator else { self.translator?.setPairs([]); speaker.stop(); return }
        for line in current.lines {
            if let pair = translationPair(for: line), !activePairs.contains(pair) { activePairs.append(pair) }
        }
        translator.setPairs(activePairs)
        translateVisibleLines()
    }

    private func translateVisibleLines() {
        guard translationEnabled, let translator, translationTask == nil else { return }
        guard let (line, pair) = current.lines.reversed().compactMap({ line in translationPair(for: line).map { (line, $0) } })
            .first(where: { $0.0.needsTranslation(into: $0.1.target) && !failedTranslations.contains($0.0.id) }) else { return }
        if !activePairs.contains(pair) { activePairs.append(pair); translator.setPairs(activePairs) }
        let generation = translationGeneration
        let recordID = current.id
        translationTask = Task { [weak self] in
            do {
                let translation = try await translator.translate(line.text, pair: pair)
                guard let self, !Task.isCancelled, self.translationGeneration == generation, self.current.id == recordID else { return }
                if let index = self.current.lines.firstIndex(where: { $0.id == line.id && $0.text == line.text }) {
                    self.current.lines[index] = self.current.lines[index].translated(translation)
                    self.save()
                    if self.unspokenIDs.remove(line.id) != nil, self.speakTranslation, let text = translation.displayText {
                        try self.prepareOutput()
                        self.speaker.speak(text, language: pair.target, voiceID: self.speechVoices[pair.target])
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.translationGeneration == generation else { return }
                self.failedTranslations.insert(line.id)
                self.translationError = error.localizedDescription
            }
            guard let self, self.translationGeneration == generation else { return }
            self.translationTask = nil
            self.translateVisibleLines()
        }
    }

    func previewVoice(_ language: AppLanguage) {
        do {
            stopPlayback()
            speaker.stop()
            try prepareOutput()
            speaker.speak(AppStrings(language: language).speechSample, language: language.code, voiceID: speechVoices[language.code])
        } catch { self.error = error.localizedDescription }
    }

    func savePrompt() {
        do {
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            try promptText.write(to: dataRoot.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        } catch { self.error = error.localizedDescription }
    }

    func showAudioInputs() { inputMeterRequested = true; refreshInputs() }
    func stopInputMeter() { inputMeterRequested = false; inputLevelMonitor.stop() }
    func startInputMeter() {
        guard inputMeterRequested, !locked, UIApplication.shared.applicationState == .active else { return }
        inputLevelMonitor.setNoiseProfile(noiseProfile)
        inputLevelMonitor.listen(to: selectedInputID, useDefaultInput: true)
    }

    func refreshInputs() {
        guard !locked else { return }
        stopPlayback()
        speaker.stop()
        inputLevelMonitor.stop()
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { return }
            guard inputMeterRequested, !locked, UIApplication.shared.applicationState == .active else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker])
                try session.setActive(true)
                availableInputs = session.availableInputs ?? []
                if let selectedInputID, !availableInputs.contains(where: { $0.uid == selectedInputID }) { self.selectedInputID = nil }
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                startInputMeter()
            } catch { self.error = error.localizedDescription }
        }
    }

    func calibrateNoise() {
        guard !locked else { return }
        stopPlayback()
        speaker.stop()
        inputLevelMonitor.stop()
        calibrating = true
        calibrationTask = Task {
            defer { calibrating = false; startInputMeter() }
            do {
                guard await AVAudioApplication.requestRecordPermission() else { return }
                let samples = try await NoiseCalibration.measure(capture: AudioCapture(), deviceID: selectedInputID)
                guard let profile = NoiseProfile(noise: samples) else { return }
                try profile.save(to: dataRoot.appendingPathComponent("noise-profile.json"))
                noiseProfile = profile
                let heard = noiseReduction ? SpectralDenoiser.denoise(samples, profile: profile) : samples
                if let floor = NoiseCalibration.floor(forNoise: heard) { speechEnergyFloor = floor }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func prepareVoiceFilter() {
        guard !locked, voiceFilter, VoiceDetectorModelStore.cachedModelFolder() == nil else { return }
        downloadingVoiceFilter = true
        Task {
            defer { downloadingVoiceFilter = false }
            do { _ = try await VoiceDetectorModelStore.download() }
            catch { self.error = error.localizedDescription }
        }
    }

    func resetSettings() {
        guard !locked else { return }
        settings.reset()
        appLanguage = settings.appLanguage
        engineID = settings.recognitionEngine.rawValue
        languageID = settings.recognitionLanguage.id
        detectionLanguages = settings.detectionLanguages
        timestampID = settings.timestampMode.rawValue
        showDate = settings.showTimestampDate
        lineClickAction = settings.lineClickAction
        speechEnergyFloor = settings.speechEnergyFloor
        inputGain = settings.inputGain
        noiseReduction = settings.noiseReduction
        voiceFilter = settings.voiceFilter
        translationEnabled = settings.translation
        translationRules = [TranslationRule(source: nil, target: settings.appLanguage)]
        translationEmphasis = settings.translationEmphasis
        speakTranslation = settings.speakTranslation
        speechVoices = settings.speechVoices
        apiKey = settings.openAIAPIKey ?? ""
        aiHintsEnabled = settings.aiHints
        hintModel = settings.aiHintModel
        hintLanguage = settings.aiHintLanguage
        hintWebSearch = settings.aiHintWebSearch
        summaryEnabled = settings.aiSummary
        summaryModel = settings.summaryModel
        configureAI()
        configureTranslation()
    }
}
