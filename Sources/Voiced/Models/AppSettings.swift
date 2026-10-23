import Foundation

/// User preferences persisted as a flat JSON object in `~/.voiced/settings.json`.
///
/// Every property reads and writes the file-backed store directly, so there is no cached state to keep in sync.
/// The keys are stable: changing them would silently reset existing users' preferences.
struct AppSettings {
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
        case translation
        case translationLanguage
        case translationEmphasis
        case speakTranslation
        case speechVoices
        case translationRules
        case openAIAPIKey
    }

    private let file: SettingsFile

    init(fileURL: URL = VoicedDirectory.settingsFile) {
        file = SettingsFile(url: fileURL)
    }

    var fileURL: URL { file.url }

    var appLanguage: AppLanguage {
        get { rawValue(.appLanguage) ?? AppLanguage.systemDefault }
        nonmutating set { set(newValue.rawValue, for: .appLanguage) }
    }

    var recognitionLanguage: RecognitionLanguage {
        get { RecognitionLanguage.choice(id: string(.recognitionLanguage)) }
        nonmutating set { set(newValue.id, for: .recognitionLanguage) }
    }

    /// Whisper codes of the languages automatic detection may pick, in the order listed in
    /// Settings. Empty, the default, leaves every language to Whisper, as does a list naming
    /// every one of `RecognitionLanguage.detectable`; unknown and repeated codes are dropped.
    var detectionLanguages: [String] {
        get {
            let all = RecognitionLanguage.detectable.compactMap(\.code)
            var seen = Set<String>()
            let stored = (file[Key.detectionLanguages.rawValue] as? [String] ?? [])
                .filter { all.contains($0) && seen.insert($0).inserted }
            return stored.count == all.count ? [] : stored
        }
        nonmutating set { set(newValue.isEmpty ? nil : newValue, for: .detectionLanguages) }
    }

    var recognitionEngine: RecognitionEngine {
        get { rawValue(.recognitionEngine) ?? .turbo }
        nonmutating set { set(newValue.rawValue, for: .recognitionEngine) }
    }

    var timestampMode: TimestampMode {
        get { rawValue(.timestampMode) ?? .current }
        nonmutating set { set(newValue.rawValue, for: .timestampMode) }
    }

    var showTimestampDate: Bool {
        get { file[Key.showTimestampDate.rawValue] as? Bool ?? true }
        nonmutating set { set(newValue, for: .showTimestampDate) }
    }

    /// Whether captured audio goes through spectral subtraction. Off by default because a new
    /// installation has no measured noise profile.
    var noiseReduction: Bool {
        get { file[Key.noiseReduction.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .noiseReduction) }
    }

    /// Whether the voice detector filters what the energy gate lets through. Off by default: it
    /// needs a model download and judges speech more strictly than the energy gate.
    var voiceFilter: Bool {
        get { file[Key.voiceFilter.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .voiceFilter) }
    }

    /// Whether the main window floats above other apps' windows.
    var keepWindowOnTop: Bool {
        get { file[Key.keepWindowOnTop.rawValue] as? Bool ?? true }
        nonmutating set { set(newValue, for: .keepWindowOnTop) }
    }

    /// Whether committed lines are translated. Off by default: the system translation has to
    /// download a language pack the first time, and most transcripts need no translation.
    var translation: Bool {
        get { file[Key.translation.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .translation) }
    }

    /// The language every line was translated into before rules replaced it. Read only to turn
    /// it into the first rule; nil until the user picks one, when the interface language stands in.
    var translationLanguage: AppLanguage? {
        get { rawValue(.translationLanguage) }
        nonmutating set { set(newValue?.rawValue, for: .translationLanguage) }
    }

    /// Which language lines are translated into, by the language they are in. Nil until the
    /// rules are first saved; a rule naming a language this version does not know is dropped.
    var translationRules: [TranslationRule]? {
        get { (file[Key.translationRules.rawValue] as? [[String: String]])?.compactMap(TranslationRule.init(stored:)) }
        nonmutating set { set(newValue?.map(\.stored), for: .translationRules) }
    }

    /// Which text of a translated line is shown at full size.
    var translationEmphasis: TranslationEmphasis {
        get { rawValue(.translationEmphasis) ?? .original }
        nonmutating set { set(newValue.rawValue, for: .translationEmphasis) }
    }

    /// Whether new translations are read aloud. Off by default: the speech plays through the
    /// speakers, where a microphone or a loopback input would pick it up again.
    var speakTranslation: Bool {
        get { file[Key.speakTranslation.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .speakTranslation) }
    }

    /// The voice picked to read each language aloud, as `AppLanguage.code` to the system voice's
    /// identifier. A language missing here is read by its default voice.
    var speechVoices: [String: String] {
        get { file[Key.speechVoices.rawValue] as? [String: String] ?? [:] }
        nonmutating set { set(newValue, for: .speechVoices) }
    }

    /// The OpenAI API key the summaries in History are requested with; nil until one is entered.
    /// Surrounding whitespace, as from a copied key, is dropped, and an empty key is stored as none.
    var openAIAPIKey: String? {
        get {
            let stored = string(.openAIAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? nil : stored
        }
        nonmutating set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            set(trimmed.isEmpty ? nil : trimmed, for: .openAIAPIKey)
        }
    }

    /// Minimum frame RMS the voice detector treats as speech. Clamped to the transcriber's range.
    var speechEnergyFloor: Float {
        get {
            guard let stored = file[Key.speechEnergyFloor.rawValue] as? Double else {
                return LiveTranscriber.defaultSpeechEnergyFloor
            }
            return Float(stored).clamped(to: LiveTranscriber.speechEnergyFloorRange)
        }
        nonmutating set { set(Double(newValue.clamped(to: LiveTranscriber.speechEnergyFloorRange)), for: .speechEnergyFloor) }
    }

    /// Forgets every stored preference, so each reads its default again.
    func reset() {
        file.removeAll()
    }

    /// Copies preferences stored in `UserDefaults` by versions before the settings file existed.
    /// Does nothing once the file is present, so later changes to the defaults are ignored.
    static func importLegacyDefaults(_ defaults: UserDefaults, into fileURL: URL) {
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
