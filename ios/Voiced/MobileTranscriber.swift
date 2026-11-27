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
    /// The "Send to Mac" switch. While it is on the phone stays connected to a Mac running the voiced
    /// service, and holding the microphone turns what is said meanwhile into a command for it,
    /// left blue in the transcript until sent from its card's menu.
    @Published var sendToMacEnabled: Bool { didSet { settings.phoneInput = sendToMacEnabled; configureMacLink() } }
    /// What the Mac does with what is sent: type it at the cursor, type it and press Return, or
    /// have Claude Code carry it out. Sent with every sentence, so the Mac needs no setting.
    @Published var sendToMacMode: PhoneInput.Mode { didSet { settings.phoneInputMode = sendToMacMode; rememberSending() } }
    /// The Mac sent to, by name; nil for the first one found.
    @Published var sendToMacTarget: String? {
        didSet {
            settings.phoneInputMac = sendToMacTarget
            macLink.preferredName = sendToMacTarget
            recallSending(for: sendToMacTarget ?? macLink.connectedName)
        }
    }
    /// The Mac folder Claude Code runs in for Run; `~` is the home folder. Sent with every sentence.
    @Published var claudeFolder: String { didSet { settings.claudeFolder = claudeFolder; rememberSending() } }
    /// How each machine was last sent to (mode and folder), by name: choosing a machine, or
    /// Automatic connecting to one, brings its way back.
    private var machineSending: [String: AppSettings.MachineSending] = [:]
    private var machineSendingRecalling: AnyCancellable?
    /// Set while a machine's way of sending is put back, which is not a change to remember.
    private var recallingSending = false
    /// Whether the microphone is being held, so speech now goes to the Mac.
    @Published private(set) var holding = false
    /// The input's loudness over the last few seconds while the microphone is held, for the
    /// waveform in the speech card. Its own object, so only the waveform redraws as it moves.
    let waveform = WaveformMeter()
    /// Whether a let-go hold's clip is being transcribed: the speech card waits for its text.
    @Published private(set) var recognizingHold = false
    /// How many holds have begun; UI tests read it to see that a hold took effect.
    @Published private(set) var holdCount = 0
    /// Whether the live text is speech for the Mac: from the start of a hold until what was said
    /// during it is committed, while "Send to Mac" is on. The live card is blue then.
    @Published private(set) var liveForMac = false
    /// The line the latest hold recognised as a command for the Mac; see `pendingCommand`.
    @Published private var pendingCommandID: String?
    /// Bumped when a hold for the Mac heard nothing: the view then opens a blue card to type the
    /// command into instead.
    @Published private(set) var typeCommandRequests = 0
    /// The waiting command a hold in progress records again, replaced once the hold's text arrives.
    private var holdReplaces: String?
    /// The hold in progress: pressed at `start` seconds into the session, at capture sample
    /// `sample`. Live decoding is paused for it; what was said is recorded as one clip and
    /// transcribed whole once let go, and the result is shown whatever it is, unfiltered.
    private var hold: (start: Float, sample: Int)?
    /// Where the earliest hold not yet committed began, in seconds since the session started:
    /// speech before it is ordinary. Nil once every hold is committed and live decoding resumed.
    private var holdBoundary: Float?
    /// Transcribes and commits the latest released hold's clip, after the holds before it.
    private var holdTask: Task<Void, Never>?
    /// Released holds whose clips are not committed yet.
    private var pendingHolds = 0
    /// Every sample captured in the session, from shortly before a hold on, for its clip.
    private var holdTap: HoldAudioTap?
    /// When the capture started, the clock of the tap's sample indices.
    private var captureStartedAt: Date?
    /// The session's decoding options, reused for a hold's clip.
    private var decodingOptions: DecodingOptions?
    /// Whether the hold started the recording, so committing what was said also stops it.
    private var holdStartedRecording = false
    /// Whether the running recording was started by a hold and exists only for it, until it has
    /// fully stopped. The live card is not shown for such a recording, not even while it stops.
    @Published private(set) var recordingForHold = false
    /// Speech that starts this soon after the release still belongs to the hold.
    private static let holdTail: Float = 0.3
    /// The press began this long before the hold was recognised.
    private static let holdLeadIn: Float = 0.6
    @Published var allowLandscape: Bool { didSet { settings.allowLandscape = allowLandscape; OrientationLock.apply(allowLandscape: allowLandscape) } }
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
    /// Whether the recognition model is being downloaded or loaded. It carries on when the
    /// recording that started it is stopped, so the banner shows its progress until it is ready.
    @Published var modelLoading = false
    /// The load in progress, which a recording started meanwhile waits for instead of starting another.
    private var modelLoad: (key: String, task: Task<any SpeechDecoding, Error>)?
    @Published var loadingStartedAt: Date?
    /// How long this load should take, from the last one of the same model; nil when unknown,
    /// such as when the model has to be compiled first. The banner then counts down instead of up.
    @Published var expectedLoadSeconds: TimeInterval?
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
    /// The lines recognized since the shown record was started or opened: only these are
    /// translated, so opening a record from the history translates nothing.
    private var conversationLineIDs: Set<String> = []
    private var aiForwarding: AnyCancellable?
    let macLink = PhoneInputSender()
    private var macLinkForwarding: AnyCancellable?
    private var macRunsKeeping: AnyCancellable?
    /// Records whose Claude Code runs changed since they were last saved, saved shortly after.
    private var recordsWithNewRuns: Set<String> = []
    private var runSave: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private let historyStore: TranscriptHistoryStore
    /// The loaded WhisperKit model or Apple recognizer, and the `modelKey` it was loaded for.
    private var decoder: (any SpeechDecoding)?
    private var loadedModel: String?
    private var transcriber: LiveTranscriber?
    private var session: RecordingSession?
    private var sessionLanguage = RecognitionLanguage.automatic
    private var recorder: SessionRecorder?
    private var sessionInfo: TranscriptRecord.Session?
    private var lastFinishedDecode = 0
    private var preparationID = UUID()
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    var engine: RecognitionEngine { RecognitionEngine(rawValue: engineID).flatMap { $0.isAvailable ? $0 : nil } ?? .platformDefault }
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
        sendToMacEnabled = settings.phoneInput
        sendToMacMode = settings.phoneInputMode
        sendToMacTarget = settings.phoneInputMac
        claudeFolder = settings.claudeFolder
        allowLandscape = settings.allowLandscape
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
        macLinkForwarding = macLink.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // After the change, not while `runs` is about to change.
        macRunsKeeping = macLink.$runs.receive(on: RunLoop.main).sink { [weak self] runs in self?.keep(runs) }
        machineSending = settings.phoneInputMachines
        // Automatic connected to a machine: the way it was last sent to.
        machineSendingRecalling = macLink.$connectedName.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] name in
            guard let self, self.sendToMacTarget == nil, let name else { return }
            self.recallSending(for: name)
        }
        configureMacLink()
        OrientationLock.apply(allowLandscape: allowLandscape)
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
                    if note.name == UIApplication.didEnterBackgroundNotification { self.saveClaudeRuns() }
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
        conversationLineIDs = []
        ai.reset()
        configureTranslation()
        liveText = ""
    }

    /// Starts an ordinary recording, which sends nothing to the Mac unless the microphone is held.
    func start() { begin(preview: false) }

    /// The microphone is being held: what is said until it is let go is recorded as one clip,
    /// transcribed whole and shown as one line, also sent to the Mac when "Send to Mac" is on.
    /// Starts a recording when none is running. In a running one, what was said before the hold
    /// is committed first, as ordinary lines, and live decoding pauses until the clip is done.
    func beginHold() {
        // Not `locked`: that includes a running recording, which is exactly when a hold must work.
        guard !holding, !stopping, !previewActive, !calibrating, !downloadingVoiceFilter else { return }
        holdCount += 1
        holding = true
        liveForMac = sendToMacEnabled
        // A hold over a command waiting to be sent records it again: the new one takes its place.
        holdReplaces = pendingCommand?.id
        waveform.reset()
        guard var session, recording else {
            // Idle or still preparing: the clip starts with the capture; see `begin`.
            hold = (0, 0)
            holdBoundary = holdBoundary ?? 0
            if !(recording || busy) {
                holdStartedRecording = true
                recordingForHold = true
                begin(preview: false)
            }
            return
        }
        if holdBoundary == nil {
            session.commitTrailing(finalize: assembler.terminated)
            publish(session)
        }
        liveText = ""
        let press = Date().addingTimeInterval(-TimeInterval(Self.holdLeadIn))
        let start = max(0, sessionTime(of: press, in: session), session.committedEnd)
        hold = (start, captureSample(at: press))
        holdBoundary = holdBoundary ?? start
        holdTap?.keep(from: hold?.sample ?? 0)
        if let transcriber { Task { await transcriber.pauseDecoding() } }
        trace("beginHold \(String(describing: hold))")
    }

    private func sessionTime(of date: Date, in session: RecordingSession) -> Float {
        Float(date.timeIntervalSince(session.startedAt))
    }

    /// The capture sample recorded at `date`.
    private func captureSample(at date: Date) -> Int {
        guard let captureStartedAt else { return 0 }
        return max(0, Int(Float(date.timeIntervalSince(captureStartedAt)) * Float(WhisperKit.sampleRate)))
    }

    /// The microphone was let go: the clip is transcribed and committed as one line, then live
    /// decoding resumes, or the recording stops when the hold started it.
    func endHold() {
        guard holding else { return }
        holding = false
        guard let session, let pressed = hold else {
            // Let go before the recording was ready: nothing was said into it, so for the Mac the
            // command is typed instead.
            hold = nil
            if holdTask == nil { holdBoundary = nil; liveForMac = false }
            if sendToMacEnabled { typeCommandRequests += 1 }
            if holdStartedRecording {
                holdStartedRecording = false
                stop()
            }
            return
        }
        hold = nil
        let release = Date().addingTimeInterval(TimeInterval(Self.holdTail))
        let end = sessionTime(of: release, in: session)
        let endSample = captureSample(at: release)
        if let transcriber { Task { await transcriber.keepAudio(fromSample: endSample) } }
        trace("endHold \(pressed.start)-\(end) samples=\(pressed.sample)-\(endSample)")
        let previous = holdTask
        let forMac = sendToMacEnabled
        let replaces = holdReplaces
        holdReplaces = nil
        pendingHolds += 1
        recognizingHold = true
        holdTask = Task { [weak self] in
            await previous?.value
            await self?.finishHold(start: pressed.start, end: end, samples: pressed.sample..<endSample, forMac: forMac, replacing: replaces)
        }
    }

    /// The microphone was let go away from it: what was said during the hold is dropped, not
    /// transcribed. Live decoding resumes after it, or the recording the hold started stops.
    func cancelHold() {
        guard holding else { return }
        // Not ready yet: nothing was said into it, the same as letting go on the button.
        guard let session, hold != nil else { endHold(); return }
        holding = false
        hold = nil
        // Dropped: a command it was to record again stays as it was.
        holdReplaces = nil
        let endSample = captureSample(at: Date())
        if let transcriber { Task { await transcriber.keepAudio(fromSample: endSample) } }
        trace("cancelHold at \(sessionTime(of: Date(), in: session))")
        let previous = holdTask
        pendingHolds += 1
        holdTask = Task { [weak self] in
            await previous?.value
            await self?.settleHold()
        }
    }

    /// Transcribes a hold's clip and commits whatever it says as one line, marked as an unsent
    /// command for the Mac when `forMac`, in place of the unsent command `replacing`, if any.
    /// After the last pending hold, live decoding resumes (or the recording the hold started stops).
    private func finishHold(start: Float, end: Float, samples: Range<Int>, forMac: Bool, replacing: String?) async {
        // The tap hears the capture a moment late: wait until it has the clip's end, or the capture stopped.
        let deadline = ContinuousClock.now + .seconds(2)
        while let tap = holdTap, tap.count < samples.upperBound, transcriber != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let clip = holdTap?.clip(samples) ?? []
        // A live decode that was running at the press shares the model: let it finish first.
        if let transcriber { while await transcriber.isDecoding { try? await Task.sleep(for: .milliseconds(50)) } }
        let text = await recognize(clip)
        trace("finishHold clip=\(Float(clip.count) / Float(WhisperKit.sampleRate))s text=\(text)")
        if var session, !text.isEmpty {
            let from = max(start, session.committedEnd)
            let segment = TranscriptionSegment(start: from, end: max(end, from + 0.1), text: text)
            var command: TranscriptLine?
            if let line = session.commitMerged(segments: [segment], assembler: assembler), forMac {
                trace("committed hold line [\(line.start)-\(line.end)] \(line.text)")
                // A command, not sent yet: it waits, blue, until sent with the microphone (now a
                // send button) or its card's menu. Kept with the record, so it stays blue in the
                // transcript and in history.
                current.macCommands = (current.macCommands ?? []).union([line.id])
                command = line
            }
            publish(session)
            if let command {
                pendingCommandID = command.id
                // Recorded again: the command it replaces goes, if it is still unsent.
                if let replacing, replacing != command.id,
                   let old = current.lines.first(where: { $0.id == replacing }), isUnsentMacCommand(old) {
                    deleteLine(old)
                }
            }
        } else if text.isEmpty, forMac {
            // Held for the Mac, but nothing was heard: the command is typed instead.
            typeCommandRequests += 1
        }
        await settleHold()
    }

    /// One pending hold is done. After the last, live decoding resumes (or the recording the
    /// hold started stops).
    private func settleHold() async {
        pendingHolds -= 1
        if pendingHolds == 0 { recognizingHold = false }
        // Another hold has begun or is still to be committed: it carries on from here.
        guard pendingHolds == 0, !holding else { return }
        holdTask = nil
        holdBoundary = nil
        holdTap?.keepLeadInOnly()
        liveText = ""
        liveForMac = false
        await transcriber?.resumeDecoding()
        if holdStartedRecording {
            holdStartedRecording = false
            stop()
        }
    }

    /// The clip's text as Whisper hears it, with nothing filtered out.
    private func recognize(_ clip: [Float]) async -> String {
        guard !clip.isEmpty, let decoder, let decodingOptions else { return "" }
        do {
            let results = try await decoder.decode(clip, options: decodingOptions, callback: nil)
            let text = results.flatMap(\.segments).map(\.text).joined()
            return LiveTranscriber.droppingPartialCharacters(text).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = error.localizedDescription
            return ""
        }
    }

    /// For a line sent to the Mac, whether it went out; nil for every other line.
    func macDelivery(of line: TranscriptLine) -> Bool? {
        current.macDeliveries?[line.id]
    }

    /// Whether the line is a command recognised from a hold that has not been sent yet.
    func isUnsentMacCommand(_ line: TranscriptLine) -> Bool {
        current.macCommands?.contains(line.id) == true
    }

    /// The command the latest hold recognised, while it waits to be sent: the microphone is then
    /// a send button. Nil once it is sent or deleted, or another record is shown.
    var pendingCommand: TranscriptLine? {
        guard sendToMacEnabled, let pendingCommandID,
              let line = current.lines.first(where: { $0.id == pendingCommandID }), isUnsentMacCommand(line)
        else { return nil }
        return line
    }

    /// Adds a command typed into the card a silent hold opened, as a hold's would be: a blue line
    /// waiting to be sent, with the microphone as its send button. Returns the line, or nil when
    /// nothing was typed.
    @discardableResult
    func addTypedCommand(_ text: String) -> TranscriptLine? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sendToMacEnabled else { return nil }
        var line: TranscriptLine
        if var session, !previewActive {
            // Into the running recording, which would otherwise drop it with its next commit.
            let at = session.committedEnd
            session.appendTyped(TranscriptLine(id: "typed-\(UUID().uuidString)", start: at, end: at, recordedAt: Date(), text: text))
            line = session.transcript.last!
            publish(session)
        } else {
            line = TranscriptLine(id: "typed-\(UUID().uuidString)", start: 0, end: 0, recordedAt: Date(), text: text)
            current.lines.append(line)
            conversationLineIDs.insert(line.id)
            translateVisibleLines()
            ai.update(current.lines)
        }
        current.macCommands = (current.macCommands ?? []).union([line.id])
        // A command still waiting goes, as a new hold's would replace it.
        if let old = pendingCommand, old.id != line.id { deleteLine(old) }
        pendingCommandID = line.id
        save()
        return line
    }

    /// Sends the waiting command to the Mac. Returns whether it went out; if not, it keeps waiting.
    @discardableResult
    func sendPendingCommand() -> Bool {
        guard let line = pendingCommand else { return false }
        let delivered = sendLineToMac(line)
        if delivered { pendingCommandID = nil }
        return delivered
    }

    /// Gives up the waiting command, which is deleted, as a new hold's would replace it: the
    /// microphone is the microphone again.
    func discardPendingCommand() {
        guard let line = pendingCommand else { return }
        pendingCommandID = nil
        deleteLine(line)
    }

    func startPreview() { begin(preview: true) }

    private func begin(preview: Bool) {
        guard !locked else { return }
        stopPlayback()
        speaker.stop()
        inputLevelMonitor.stop()
        let preparationID = UUID()
        self.preparationID = preparationID
        busy = true
        if !modelLoading {
            loadingStartedAt = nil
            loadingComponent = nil
            downloadProgress = nil
        }
        error = nil
        startModelLoad(engine)
        task = Task {
            do {
                // The model load's progress, when one is running, says more than this.
                if !modelLoading { status = "请求麦克风权限…" }
                let permitted = await AVAudioApplication.requestRecordPermission()
                try checkPreparation(preparationID)
                guard permitted else {
                    throw NSError(domain: "Voiced", code: 3, userInfo: [NSLocalizedDescriptionKey: "请在系统设置 → Voiced 中允许麦克风访问。"])
                }
                let selected = engine
                let language = recognitionLanguage(for: selected)
                // Stopping only stops waiting here: the model goes on loading, ready for next time.
                let decoder = try await loadModel(selected)
                try checkPreparation(preparationID)
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
                let tokens = decoder.tokenizer.flatMap { RecognitionPrompt.tokens(for: prompt, tokenizer: $0) }
                if #available(iOS 26, *), let apple = decoder as? AppleSpeechDecoder {
                    apple.contextualStrings = RecognitionPrompt.terms(from: dataRoot.appendingPathComponent("prompt.txt"))
                }
                ((decoder as? WhisperKit)?.textDecoder as? LanguageLimitedDecoder)?.allowedLanguages = language.isAutomatic && !detectionLanguages.isEmpty ? Set(detectionLanguages) : nil
                #if DEBUG
                let capture = UITestFixtures.makeCapture()
                #else
                let capture = AudioCapture()
                #endif
                let source = MicrophoneAudioSource(capture: capture, profile: noiseReduction ? noiseProfile : nil, mute: inputMute)
                // Straight from the capture, so the waveform keeps moving while a decode runs.
                source.onSamples = { [waveform] samples in waveform.push(samples) }
                let options = TranscriptionLogic.decodingOptions(for: language, promptTokens: tokens)
                decodingOptions = options
                let tap = HoldAudioTap()
                holdTap = tap
                let transcriber = LiveTranscriber(decoder: decoder, options: options,
                    inputDeviceID: selectedInputID, silenceThreshold: LiveTranscriber.defaultSilenceThreshold, silenceDelay: LiveTranscriber.defaultSilenceDelay, speechEnergyFloor: settings.speechEnergyFloor,
                    voiceDetector: detector, delegate: self, audioProcessor: source,
                    levelHandler: { [weak self] value in Task { @MainActor in self?.level = value } },
                    audioSink: { recorder?.append($0); tap.append($0) })
                self.transcriber = transcriber
                // Held while preparing: the clip starts with the capture, and nothing is decoded live.
                if holding { tap.keep(from: 0); await transcriber.pauseDecoding() }
                try await transcriber.start()
                captureStartedAt = Date()
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

    /// Whether the selected engine's model is loaded, so a press on the microphone can start at once.
    var modelReady: Bool { decoder != nil && loadedModel == modelKey(for: engine) }

    /// Whether a press on the microphone only loads the model, leaving the next press to start.
    /// Whisper models take a while to load; Apple's recognizer is ready almost at once, so a press
    /// with it starts recording straight away and the start readies it on the way.
    var pressOnlyLoadsModel: Bool { engine.isWhisper && !modelReady }

    /// The language a recording with `engine` runs in: the chosen one when the engine has it,
    /// otherwise the engine's default.
    private func recognitionLanguage(for engine: RecognitionEngine) -> RecognitionLanguage {
        let chosen = RecognitionLanguage.choice(id: languageID)
        return RecognitionLanguage.choices(for: engine).contains(chosen) ? chosen : RecognitionLanguage.defaultChoice(for: engine)
    }

    /// What a loaded decoder is good for: a Whisper model for any language, Apple's recognizer
    /// for the one language it was readied for.
    private func modelKey(for engine: RecognitionEngine) -> String {
        engine.isWhisper ? engine.rawValue : "\(engine.rawValue):\(recognitionLanguage(for: engine).id)"
    }

    /// Loads the selected engine's model without starting anything: a press on the microphone
    /// before it is loaded only does this, and once loaded the microphone is back to idle, waiting
    /// for the next press.
    func prepareModel() {
        guard !modelReady, !modelLoading, !locked else { return }
        error = nil
        let task = startModelLoad(engine)
        Task { [weak self] in
            do { _ = try await task.value }
            catch is CancellationError {}
            catch { self?.error = error.localizedDescription; if self?.locked == false { self?.status = self?.strings.ready ?? "" } }
        }
    }

    /// The loaded model for `engine`, downloading and loading it first if needed. The work runs in
    /// a task of its own: cancelling the recording that waits for it does not cancel it, and a
    /// recording started while it runs waits for the same load.
    private func loadModel(_ engine: RecognitionEngine) async throws -> any SpeechDecoding {
        if let decoder, loadedModel == modelKey(for: engine) { return decoder }
        return try await startModelLoad(engine).value
    }

    /// Starts loading the model for `engine` unless it is loaded or loading already, without
    /// waiting for it. Called the moment the microphone is pressed, so even a stop straight away,
    /// while the microphone permission is still being asked for, leaves the model loading.
    @discardableResult
    private func startModelLoad(_ engine: RecognitionEngine) -> Task<any SpeechDecoding, Error> {
        let key = modelKey(for: engine)
        let language = recognitionLanguage(for: engine)
        if let decoder, loadedModel == key { return Task { decoder } }
        if let modelLoad, modelLoad.key == key { return modelLoad.task }
        // Set now, not when the task first runs, so a stop in between already sees the load.
        modelLoading = true
        let task = Task { @MainActor [weak self] () throws -> any SpeechDecoding in
            guard let self else { throw CancellationError() }
            self.modelLoading = true
            defer {
                self.modelLoading = false
                self.modelLoad = nil
                self.loadingStartedAt = nil
                self.loadingComponent = nil
                self.downloadProgress = nil
                // Loaded with nothing waiting for it: the banner goes, and the status with it.
                if !self.busy && !self.recording && !self.stopping { self.status = self.strings.ready }
            }
            self.decoder = nil
            self.loadedModel = nil
            if !engine.isWhisper {
                // Apple's recognizer: the system installs the language's assets when missing,
                // and there is nothing to compile.
                guard #available(iOS 26, *) else { throw AppleSpeechUnavailable() }
                self.loadingStartedAt = Date()
                self.status = self.strings.loadingModel
                let loaded = try await AppleSpeechDecoder.prepare(for: language) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.modelLoading else { return }
                        self.downloadProgress = fraction
                        self.status = self.strings.downloadingModel(fraction)
                    }
                }
                self.decoder = loaded
                self.loadedModel = key
                return loaded
            }
            let folder: URL
            if let cached = WhisperModelStore.cachedModelFolder(for: engine) { folder = cached }
            else {
                self.status = "首次下载模型，请保持应用在前台…"
                self.downloadProgress = 0
                folder = try await WhisperModelStore.download(engine) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.modelLoading, self.downloadProgress != nil else { return }
                        self.downloadProgress = fraction
                        self.status = self.strings.downloadingModel(fraction)
                    }
                }
            }
            self.downloadProgress = nil
            // The first load on this iOS build compiles the model for the Neural Engine: minutes, not seconds.
            let compiling = !self.settings.compiledEngines().contains(engine)
            self.expectedLoadSeconds = compiling ? nil : self.settings.modelLoadSeconds(engine)
            let loadStart = Date()
            self.loadingStartedAt = loadStart
            self.status = self.strings.loadingModel
            let loaded = try await WhisperModelStore.load(modelFolder: folder) { [weak self] component in
                Task { @MainActor in
                    guard let self, self.modelLoading, self.loadingStartedAt != nil else { return }
                    self.loadingComponent = component
                    self.status = self.strings.loadingModel(component)
                }
            }
            self.settings.recordModelLoad(engine, seconds: Date().timeIntervalSince(loadStart), compiled: compiling)
            self.settings.markCompiled(engine)
            self.decoder = loaded
            self.loadedModel = key
            return loaded
        }
        modelLoad = (key, task)
        return task
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
            // A model load in progress is left to finish, its progress still showing.
            if !modelLoading { status = strings.ready }
            if transcriber != nil {
                stopping = true
                task = Task { await finishRecording() }
            } else {
                endHolds()
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
        // Stopped during a hold or before its clip was committed: what was said still goes.
        holdStartedRecording = false
        if holding { endHold() }
        if let holdTask { await holdTask.value }
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
        if !modelLoading {
            loadingStartedAt = nil
            loadingComponent = nil
            downloadProgress = nil
        }
        recording = false
        previewActive = false
        stopping = false
        liveText = ""
        level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        if !modelLoading { status = strings.ready }
        // After the trailing sentence above has been sent.
        endHolds()
        startInputMeter()
    }

    /// The recording is over, and with it any hold.
    private func endHolds() {
        recordingForHold = false
        holding = false
        recognizingHold = false
        liveForMac = false
        hold = nil
        holdBoundary = nil
        holdTask = nil
        pendingHolds = 0
        holdStartedRecording = false
        holdTap = nil
        captureStartedAt = nil
    }

    /// Deletes one line from the current record, also while it is being recorded into.
    /// Replaces a line's text with what was typed. Also edits the running session, which would
    /// otherwise put the old text back with its next commit. The old translation is dropped and
    /// the line translated again; whether it was sent to the Mac stays as it was.
    func editLine(_ line: TranscriptLine, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = current.lines.firstIndex(where: { $0.id == line.id }),
              current.lines[index].text != text else { return }
        if playingLineID != nil { stopPlayback() }
        if var session {
            session.replaceText(ofLine: line.id, with: text)
            self.session = session
        }
        current.lines[index] = current.lines[index].replacingText(text)
        failedTranslations.remove(line.id)
        save()
        translateVisibleLines()
        ai.update(current.lines)
    }

    /// Sends a line to the Mac from its card's menu, in the mode chosen in Settings, and keeps the
    /// outcome with the record: the line turns blue, or says it was not sent. Returns whether it went out.
    @discardableResult
    func sendLineToMac(_ line: TranscriptLine) -> Bool {
        guard sendToMacEnabled, current.lines.contains(where: { $0.id == line.id }) else { return false }
        let delivered = macLink.send(line.text, mode: sendToMacMode, folder: claudeFolder, line: line.id,
                                     history: sendToMacMode == .claude ? claudeHistory(before: line) : nil)
        current.macDeliveries = (current.macDeliveries ?? [:]).merging([line.id: delivered]) { $1 }
        if delivered { current.macCommands?.remove(line.id) }
        save()
        return delivered
    }

    func deleteLine(_ line: TranscriptLine) {
        if playingLineID != nil { stopPlayback() }
        if var session {
            session.removeLine(id: line.id)
            self.session = session
        }
        current.lines.removeAll { $0.id == line.id }
        current.macDeliveries?[line.id] = nil
        current.macCommands?.remove(line.id)
        current.claudeRuns?[line.id] = nil
        unspokenIDs.remove(line.id)
        if current.lines.isEmpty, !recording, !current.sessions.contains(where: { $0.audioFile != nil }) {
            // Nothing left worth keeping: the record goes, as an empty one is never saved and the
            // file on disk still holds the deleted line.
            try? historyStore.delete(id: current.id)
            records = historyStore.load()
        } else {
            save()
        }
        ai.update(current.lines)
    }

    // MARK: Claude Code runs

    /// The Claude Code run shown under a line of the current record: the Mac's, while it still
    /// keeps it, or else the one kept with the record.
    func claudeRun(forLine id: String) -> ClaudeRun? {
        macLink.latestRun(forLine: id) ?? current.claudeRuns?[id]?.asStored
    }

    /// A run by its id, from the Mac or kept with the current record.
    func claudeRun(id: String) -> ClaudeRun? {
        macLink.runs[id] ?? current.claudeRuns?.values.first { $0.id == id }?.asStored
    }

    /// What the earlier lines of the current record sent with Run came to, oldest first: sent
    /// along with `line` so Claude knows the conversation. Runs still going have no conclusion yet.
    private func claudeHistory(before line: TranscriptLine) -> [ClaudeExchange] {
        guard let index = current.lines.firstIndex(where: { $0.id == line.id }) else { return [] }
        return current.lines[..<index].compactMap { earlier in
            guard let run = claudeRun(forLine: earlier.id), let answer = run.conclusion else { return nil }
            return ClaudeExchange(prompt: run.text, answer: answer)
        }
    }

    /// Keeps each line's latest run with the record the line is in, as the Mac reports it, so the
    /// runs are still there once the Mac's service or the app has restarted.
    private func keep(_ runs: [String: ClaudeRun]) {
        let latest = Dictionary(grouping: runs.values.filter { $0.line != nil }, by: { $0.line! })
            .compactMapValues { $0.max { ($0.startedAt ?? .infinity) < ($1.startedAt ?? .infinity) } }
        for (line, run) in latest {
            if current.lines.contains(where: { $0.id == line }) {
                guard Self.replaces(run, current.claudeRuns?[line]) else { continue }
                current.claudeRuns = (current.claudeRuns ?? [:]).merging([line: run]) { $1 }
                recordsWithNewRuns.insert(current.id)
            } else if let index = records.firstIndex(where: { $0.lines.contains { $0.id == line } }) {
                guard Self.replaces(run, records[index].claudeRuns?[line]) else { continue }
                records[index].claudeRuns = (records[index].claudeRuns ?? [:]).merging([line: run]) { $1 }
                recordsWithNewRuns.insert(records[index].id)
            }
        }
        guard !recordsWithNewRuns.isEmpty, runSave == nil else { return }
        // Text streams in a piece at a time: saved once it has settled a little.
        runSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.saveClaudeRuns()
        }
    }

    /// Whether `run` should take the place of the run kept for its line: a change to the same
    /// run, or a later run of the line.
    private static func replaces(_ run: ClaudeRun, _ kept: ClaudeRun?) -> Bool {
        guard let kept else { return true }
        if kept.id == run.id { return kept != run }
        return (run.startedAt ?? .infinity) >= (kept.startedAt ?? .infinity)
    }

    private func saveClaudeRuns() {
        runSave?.cancel()
        runSave = nil
        let ids = recordsWithNewRuns
        recordsWithNewRuns = []
        guard !ids.isEmpty else { return }
        do {
            for record in records where ids.contains(record.id) && record.id != current.id {
                try historyStore.save(record)
            }
        } catch { self.error = "保存历史记录失败：\(error.localizedDescription)" }
        // The current record also reloads the others.
        if ids.contains(current.id) { save() } else { records = historyStore.load() }
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

#if DEBUG
import os
/// End-to-end runs pass `--ui-log` to trace holds and decodes in the system log.
private let holdLog: Logger? = ProcessInfo.processInfo.arguments.contains("--ui-log")
    ? Logger(subsystem: "voiced.ui-test", category: "hold") : nil
/// The same lines in Documents/ui-trace.log, which the simulator's log does not always keep.
private let traceFile: FileHandle? = {
    guard ProcessInfo.processInfo.arguments.contains("--ui-log"),
          let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    let url = documents.appendingPathComponent("ui-trace.log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try? FileHandle(forWritingTo: url)
}()
private func trace(_ message: @autoclosure () -> String) {
    guard let holdLog else { return }
    let text = message()
    holdLog.notice("\(text, privacy: .public)")
    let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    traceFile?.write(Data("\(stamp) \(text)\n".utf8))
}
#else
private func trace(_ message: @autoclosure () -> String) {}
#endif

private func describe(_ segments: [TranscriptionSegment]) -> String {
    segments.map { String(format: "[%.1f-%.1f %@]", $0.start, $0.end, $0.text) }.joined(separator: " ")
}

extension MobileTranscriber: LiveTranscriberDelegate {
    func transcriber(_ transcriber: LiveTranscriber, didUpdateLiveText text: String, decode: Int) {
        // During a hold the live card waits for the clip's text instead.
        guard self.transcriber === transcriber, decode > lastFinishedDecode, session != nil, holdBoundary == nil else { return }
        let trimmed = HallucinationFilter.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { if previewActive { previewText = assembler.normalized(trimmed) } else { liveText = assembler.normalized(trimmed) } }
    }

    func transcriber(_ transcriber: LiveTranscriber, didDecode segments: [TranscriptionSegment], decode: Int) async -> Float {
        guard self.transcriber === transcriber, var session else { return 0 }
        lastFinishedDecode = max(lastFinishedDecode, decode)
        trace("decode \(decode) hold=\(hold) committedEnd=\(session.committedEnd) segments=\(describe(segments))")
        if let holdBoundary {
            // A decode that was running at the press: what was said before it is ordinary, and
            // the rest belongs to the hold's clip.
            commitBeforeHold(segments.filter { $0.start < holdBoundary }, in: &session)
            return session.committedEnd
        }
        session.update(segments: segments, assembler: assembler)
        let draft = assembler.draft(from: session.pendingLines.map(\.text))
        if !draft.isEmpty { if previewActive { previewText = draft } else { liveText = draft } }
        publish(session)
        return session.committedEnd
    }

    func transcriberDidDetectPause(_ transcriber: LiveTranscriber) -> Float {
        guard self.transcriber === transcriber, var session else { return 0 }
        if holdBoundary != nil { return session.committedEnd }
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

    /// Commits speech that started before the press as ordinary lines: it was said before the hold
    /// even when it is decoded during it.
    private func commitBeforeHold(_ segments: [TranscriptionSegment], in session: inout RecordingSession) {
        guard !segments.isEmpty else { return }
        session.update(segments: segments, assembler: assembler)
        session.commitTrailing(finalize: assembler.terminated)
        publish(session)
    }

    private func publish(_ session: RecordingSession) {
        self.session = session
        guard !previewActive else { return }
        let transcript = session.transcript.keepingTranslations(from: current.lines)
        guard current.lines != transcript else { return }
        let addedIDs = Set(transcript.map(\.id)).subtracting(current.lines.map(\.id))
        unspokenIDs.formUnion(addedIDs)
        conversationLineIDs.formUnion(addedIDs)
        current.lines = transcript
        save()
        translateVisibleLines()
        ai.update(current.lines)
    }
}

/// The input's latest moment, for a waveform that shakes in place rather than scrolling, drawn
/// as lo's radio card draws its mirrored scope: the current samples reduced to columns, started
/// at a rising zero crossing so a steady sound stands still, tapered to the centre at both ends
/// and eased frame to frame so speech does not strobe. Fed on the capture thread, read per frame.
final class WaveformMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: [Float] = []
    private var columns: [CGFloat] = []
    /// About 128 ms at 16 kHz: half of it is drawn, the other half leaves room for the trigger.
    private static let window = 2048

    func push(_ chunk: [Float]) {
        lock.withLock {
            recent.append(contentsOf: chunk)
            if recent.count > Self.window * 2 { recent.removeFirst(recent.count - Self.window) }
        }
    }

    func reset() {
        lock.withLock {
            recent = []
            columns = []
        }
    }

    /// The next frame: `count` amplitudes from 0 to 1, eased toward the current samples.
    func frame(columns count: Int) -> [CGFloat] {
        lock.withLock {
            if columns.count != count { columns = Array(repeating: 0, count: count) }
            let samples = Array(recent.suffix(Self.window))
            let span = samples.count / 2
            guard span >= count, count > 1 else {
                for index in columns.indices { columns[index] *= 0.4 }
                return columns
            }
            var start = 0
            for index in 1..<(samples.count - span) where samples[index - 1] < 0 && samples[index] >= 0 {
                start = index
                break
            }
            let bucket = Double(span) / Double(count)
            for index in 0..<count {
                let from = start + Int(Double(index) * bucket)
                let to = max(from + 1, start + Int(Double(index + 1) * bucket))
                // The loudest sample in the column, not the average, which would flatten a consonant.
                let peak = samples[from..<to].reduce(Float(0)) { max($0, abs($1)) }
                // Microphone speech is far quieter than full scale: lifted so it fills the card.
                let target = CGFloat(pow(min(1, peak * 4), 0.7))
                let taper = CGFloat(pow(sin(Double(index) / Double(count - 1) * .pi), 0.35))
                columns[index] += (target * taper - columns[index]) * 0.6
            }
            return columns
        }
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
        // Its lines keep the translations they already have; only what is said from now on is translated.
        conversationLineIDs = []
        ai.reset(existingLines: current.lines)
        liveText = ""
        configureTranslation()
    }

    /// Treats `lines` as recognized in the conversation under way, so they are translated. For
    /// the UI tests' fixture, whose record is opened rather than recorded.
    func adoptIntoConversation(_ lines: [TranscriptLine]) {
        conversationLineIDs.formUnion(lines.map(\.id))
        translateVisibleLines()
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
        // "Play row audio" plays just that line; "Play from row" plays on through the rest.
        if lineClickAction.plays && !recording && !previewActive { play(record, from: line, onlyLine: lineClickAction == .play); return false }
        let texts = displayTexts(line)
        UIPasteboard.general.string = texts.secondary.map { texts.primary + "\n" + $0 } ?? texts.primary
        return true
    }

    /// Plays `record`'s audio from `line` (or from the start) to the end of the file, or only
    /// `line` itself when `onlyLine`.
    func play(_ record: TranscriptRecord, from line: TranscriptLine? = nil, onlyLine: Bool = false) {
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
            try playback.play(url, from: time, until: onlyLine ? line.flatMap(record.audioEnd(of:)) : nil)
            playingRecordID = record.id
            // Light the tapped line at once rather than on the first poll.
            playingLineID = line?.id
            let cues = (onlyLine ? line.map { [$0] } ?? [] : record.lines).compactMap { line -> (id: String, time: TimeInterval)? in
                guard let position = record.audioPosition(of: line), position.file == url.lastPathComponent else { return nil }
                return (line.id, position.time)
            }.sorted { $0.time < $1.time }
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let reported = self.playback.currentTime else { return }
                    // Right after the seek the player reports a moment before the start, which
                    // briefly lit the line before the tapped one (the card below it). Never look
                    // earlier than the start, and allow the same small slack as macOS.
                    let now = max(reported, time) + 0.05
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
            .first(where: { conversationLineIDs.contains($0.0.id) && $0.0.needsTranslation(into: $0.1.target) && !failedTranslations.contains($0.0.id) }) else { return }
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
        // The defaults put back below are not a way of sending to remember for a machine.
        machineSending = settings.phoneInputMachines
        recallingSending = true
        defer { recallingSending = false }
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
        sendToMacEnabled = settings.phoneInput
        sendToMacMode = settings.phoneInputMode
        sendToMacTarget = settings.phoneInputMac
        claudeFolder = settings.claudeFolder
        allowLandscape = settings.allowLandscape
        configureAI()
        configureTranslation()
    }

    /// Connects to the Mac while the switch is on. Turning it off also ends sending for a recording
    /// that is running.
        /// The machine sent to now: the one chosen, else the one Automatic connected to.
    private var sendingMachine: String? { sendToMacTarget ?? macLink.connectedName }

    /// Keeps the current way of sending for the machine sent to now.
    private func rememberSending() {
        guard !recallingSending, let name = sendingMachine else { return }
        let sending = AppSettings.MachineSending(mode: sendToMacMode, folder: claudeFolder)
        guard machineSending[name] != sending else { return }
        machineSending[name] = sending
        settings.phoneInputMachines = machineSending
    }

    /// Sends to `name` the way it was last sent to; a machine never sent to keeps the current way.
    private func recallSending(for name: String?) {
        guard let name, let sending = machineSending[name] else { return }
        recallingSending = true
        defer { recallingSending = false }
        if sendToMacMode != sending.mode { sendToMacMode = sending.mode }
        if claudeFolder != sending.folder { claudeFolder = sending.folder }
    }

    func configureMacLink() {
        macLink.preferredName = sendToMacTarget
        if sendToMacEnabled {
            macLink.start()
        } else {
            macLink.stop()
            endHold()
        }
    }

}

/// Keeps the session's captured audio from a chosen sample on, for transcribing holds as clips.
/// Without a hold only the last couple of seconds are kept, for the next hold's lead-in.
/// Fed on the transcriber's thread, read on the main actor.
final class HoldAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    /// Samples received since the capture started.
    private var total = 0
    /// The earliest capture sample still needed; nil keeps only the lead-in.
    private var keepFrom: Int?
    private var samples: [Float] = []
    /// Capture index of `samples[0]`.
    private var samplesStart = 0
    private let leadIn = 2 * WhisperKit.sampleRate

    var count: Int { lock.withLock { total } }

    func append(_ chunk: [Float]) {
        lock.withLock {
            samples.append(contentsOf: chunk)
            total += chunk.count
            trim()
        }
    }

    /// Keeps everything from capture sample `index` on (as far back as the lead-in reaches),
    /// unless an earlier start is already kept.
    func keep(from index: Int) {
        lock.withLock {
            keepFrom = min(keepFrom ?? Int.max, max(0, index))
            trim()
        }
    }

    /// Back to keeping only a lead-in, once every clip has been taken.
    func keepLeadInOnly() {
        lock.withLock {
            keepFrom = nil
            trim()
        }
    }

    /// The captured samples in `range`, as far as they are kept.
    func clip(_ range: Range<Int>) -> [Float] {
        lock.withLock {
            let lower = max(0, range.lowerBound - samplesStart)
            let upper = min(samples.count, range.upperBound - samplesStart)
            return lower < upper ? Array(samples[lower..<upper]) : []
        }
    }

    private func trim() {
        let from = keepFrom ?? (total - leadIn)
        let drop = min(max(0, from - samplesStart), samples.count)
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        samplesStart += drop
    }
}

private struct AppleSpeechUnavailable: LocalizedError {
    var errorDescription: String? { "Apple speech recognition needs iOS 26 or later." }
}
