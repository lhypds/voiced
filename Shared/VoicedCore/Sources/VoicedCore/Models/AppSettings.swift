import Foundation

/// User preferences persisted as a flat JSON object in `~/.voiced/settings.json`.
///
/// Every property reads and writes the file-backed store directly, so there is no cached state to keep in sync.
/// The keys are stable: changing them would silently reset existing users' preferences.
public struct AppSettings {
    private enum Key: String, CaseIterable {
        case appLanguage
        case recognitionLanguage
        case detectionLanguages
        case timestampMode
        case showTimestampDate
        case recognitionEngine
        case speechEnergyFloor
        case noiseReduction
        case voiceFilter
        case keepWindowOnTop
        case lineClickAction
        case translation
        case translationLanguage
        case translationEmphasis
        case speakTranslation
        case speechVoices
        case translationRules
        case openAIAPIKey
        case aiHints
        case aiHintLanguage
        case aiHintModel
        case aiHintWebSearch
        case aiSummary
        case summaryModel
        case compiledModels
    }

    private let file: SettingsFile

    public init(fileURL: URL = VoicedDirectory.settingsFile) {
        file = SettingsFile(url: fileURL)
    }

    public var fileURL: URL { file.url }

    public var appLanguage: AppLanguage {
        get { rawValue(.appLanguage) ?? AppLanguage.systemDefault }
        nonmutating set { set(newValue.rawValue, for: .appLanguage) }
    }

    public var recognitionLanguage: RecognitionLanguage {
        get { RecognitionLanguage.choice(id: string(.recognitionLanguage)) }
        nonmutating set { set(newValue.id, for: .recognitionLanguage) }
    }

    /// Whisper codes of the languages automatic detection may pick, in the order listed in
    /// Settings. Empty, the default, leaves every language to Whisper, as does a list naming
    /// every one of `RecognitionLanguage.detectable`; unknown and repeated codes are dropped.
    public var detectionLanguages: [String] {
        get {
            let all = RecognitionLanguage.detectable.compactMap(\.code)
            var seen = Set<String>()
            let stored = (file[Key.detectionLanguages.rawValue] as? [String] ?? [])
                .filter { all.contains($0) && seen.insert($0).inserted }
            return stored.count == all.count ? [] : stored
        }
        nonmutating set { set(newValue.isEmpty ? nil : newValue, for: .detectionLanguages) }
    }

    public var recognitionEngine: RecognitionEngine {
        get { rawValue(.recognitionEngine) ?? .turbo }
        nonmutating set { set(newValue.rawValue, for: .recognitionEngine) }
    }

    public var timestampMode: TimestampMode {
        get { rawValue(.timestampMode) ?? .current }
        nonmutating set { set(newValue.rawValue, for: .timestampMode) }
    }

    public var showTimestampDate: Bool {
        get { file[Key.showTimestampDate.rawValue] as? Bool ?? true }
        nonmutating set { set(newValue, for: .showTimestampDate) }
    }

    /// Whether captured audio goes through spectral subtraction. Off by default because a new
    /// installation has no measured noise profile.
    public var noiseReduction: Bool {
        get { file[Key.noiseReduction.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .noiseReduction) }
    }

    /// Whether the voice detector filters what the energy gate lets through. Off by default: it
    /// needs a model download and judges speech more strictly than the energy gate.
    public var voiceFilter: Bool {
        get { file[Key.voiceFilter.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .voiceFilter) }
    }

    /// Whether the main window floats above other apps' windows.
    public var keepWindowOnTop: Bool {
        get { file[Key.keepWindowOnTop.rawValue] as? Bool ?? true }
        nonmutating set { set(newValue, for: .keepWindowOnTop) }
    }

    /// What a click on a transcript row does. Copying by default, as it always did.
    public var lineClickAction: LineClickAction {
        get { rawValue(.lineClickAction) ?? .copy }
        nonmutating set { set(newValue.rawValue, for: .lineClickAction) }
    }

    /// Whether committed lines are translated. Off by default: the system translation has to
    /// download a language pack the first time, and most transcripts need no translation.
    public var translation: Bool {
        get { file[Key.translation.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .translation) }
    }

    /// The language every line was translated into before rules replaced it. Read only to turn
    /// it into the first rule; nil until the user picks one, when the interface language stands in.
    public var translationLanguage: AppLanguage? {
        get { rawValue(.translationLanguage) }
        nonmutating set { set(newValue?.rawValue, for: .translationLanguage) }
    }

    /// Which language lines are translated into, by the language they are in. Nil until the
    /// rules are first saved; a rule naming a language this version does not know is dropped.
    public var translationRules: [TranslationRule]? {
        get { (file[Key.translationRules.rawValue] as? [[String: String]])?.compactMap(TranslationRule.init(stored:)) }
        nonmutating set { set(newValue?.map(\.stored), for: .translationRules) }
    }

    /// Which text of a translated line is shown at full size.
    public var translationEmphasis: TranslationEmphasis {
        get { rawValue(.translationEmphasis) ?? .original }
        nonmutating set { set(newValue.rawValue, for: .translationEmphasis) }
    }

    /// Whether new translations are read aloud. Off by default: the speech plays through the
    /// speakers, where a microphone or a loopback input would pick it up again.
    public var speakTranslation: Bool {
        get { file[Key.speakTranslation.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .speakTranslation) }
    }

    /// The voice picked to read each language aloud, as `AppLanguage.code` to the system voice's
    /// identifier. A language missing here is read by its default voice.
    public var speechVoices: [String: String] {
        get { file[Key.speechVoices.rawValue] as? [String: String] ?? [:] }
        nonmutating set { set(newValue, for: .speechVoices) }
    }

    /// The OpenAI API key the summaries in History are requested with; nil until one is entered.
    /// Surrounding whitespace, as from a copied key, is dropped, and an empty key is stored as none.
    public var openAIAPIKey: String? {
        get {
            let stored = string(.openAIAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? nil : stored
        }
        nonmutating set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            set(trimmed.isEmpty ? nil : trimmed, for: .openAIAPIKey)
        }
    }

    /// Whether newly recognized lines get AI hint bubbles for obscure things and questions. Off
    /// by default: every new sentence is sent to the service, which also needs a key.
    public var aiHints: Bool {
        get { file[Key.aiHints.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .aiHints) }
    }

    /// The language AI hints are written in; nil, the default, follows the interface language.
    public var aiHintLanguage: AppLanguage? {
        get { rawValue(.aiHintLanguage) }
        nonmutating set { set(newValue?.rawValue, for: .aiHintLanguage) }
    }

    /// The OpenAI model hints are asked from; the default until a name is entered, and when
    /// the entered name is blank.
    public var aiHintModel: String {
        get { OpenAIChatCompletion.modelName(string(.aiHintModel)) }
        nonmutating set { setModelName(newValue, for: .aiHintModel) }
    }

    /// Whether the model may search the web while writing hints. Off by default: slower, dearer
    /// and only for models with the search tool.
    public var aiHintWebSearch: Bool {
        get { file[Key.aiHintWebSearch.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .aiHintWebSearch) }
    }

    /// Whether the history offers AI summaries. On by default: a summary is only ever made when
    /// asked for, and only with a key.
    public var aiSummary: Bool {
        get { file[Key.aiSummary.rawValue] as? Bool ?? true }
        nonmutating set { set(newValue, for: .aiSummary) }
    }

    /// The OpenAI model summaries are asked from, as `aiHintModel`.
    public var summaryModel: String {
        get { OpenAIChatCompletion.modelName(string(.summaryModel)) }
        nonmutating set { setModelName(newValue, for: .summaryModel) }
    }

    /// Stores a model name trimmed, and the default name as nothing, so the file only holds
    /// what the user changed.
    private func setModelName(_ name: String, for key: Key) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        set(trimmed.isEmpty || trimmed == OpenAIChatCompletion.defaultModel ? nil : trimmed, for: key)
    }

    /// Minimum frame RMS the voice detector treats as speech. Clamped to the transcriber's range.
    public var speechEnergyFloor: Float {
        get {
            guard let stored = file[Key.speechEnergyFloor.rawValue] as? Double else {
                return LiveTranscriber.defaultSpeechEnergyFloor
            }
            return Float(stored).clamped(to: LiveTranscriber.speechEnergyFloorRange)
        }
        nonmutating set { set(Double(newValue.clamped(to: LiveTranscriber.speechEnergyFloorRange)), for: .speechEnergyFloor) }
    }

    /// The engines whose models the Neural Engine has compiled on the given macOS build, as
    /// recorded by `markCompiled`. Stored as `{build: [engine]}`; the system keeps its compiled
    /// programs per build, so a record for any other build is stale and reads as empty.
    public func compiledEngines(for build: String = OSBuild.current) -> Set<RecognitionEngine> {
        let stored = file[Key.compiledModels.rawValue] as? [String: [String]] ?? [:]
        return Set((stored[build] ?? []).compactMap(RecognitionEngine.init(rawValue:)))
    }

    /// Records that `engine`'s model has been loaded, and so compiled, on `build`. Records for
    /// other builds are dropped: the compiled programs they stand for are gone.
    public func markCompiled(_ engine: RecognitionEngine, for build: String = OSBuild.current) {
        let engines = compiledEngines(for: build).union([engine]).map(\.rawValue).sorted()
        set([build: engines], for: .compiledModels)
    }

    /// Forgets every stored preference, so each reads its default again.
    public func reset() {
        file.removeAll()
    }

    /// Copies preferences stored in `UserDefaults` by versions before the settings file existed.
    /// Does nothing once the file is present, so later changes to the defaults are ignored.
    public static func importLegacyDefaults(_ defaults: UserDefaults, into fileURL: URL) {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let file = SettingsFile(url: fileURL)
        for key in Key.allCases {
            if let value = defaults.object(forKey: key.rawValue) {
                file[key.rawValue] = value
            }
        }
    }

    private func string(_ key: Key) -> String? {
        file[key.rawValue] as? String
    }

    private func rawValue<T: RawRepresentable>(_ key: Key) -> T? where T.RawValue == String {
        string(key).flatMap(T.init(rawValue:))
    }

    private func set(_ value: Any?, for key: Key) {
        file[key.rawValue] = value
    }
}

/// A JSON object of preferences. Loaded once when created; every change is written back immediately,
/// so a fresh instance always sees what earlier ones stored.
private final class SettingsFile: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var values: [String: Any]

    init(url: URL) {
        self.url = url
        values = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    subscript(key: String) -> Any? {
        get { lock.withLock { values[key] } }
        set {
            lock.withLock {
                values[key] = newValue
                save()
            }
        }
    }

    func removeAll() {
        lock.withLock {
            values = [:]
            save()
        }
    }

    private func save() {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
