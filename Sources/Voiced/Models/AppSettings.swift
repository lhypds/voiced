import Foundation

/// User preferences persisted as a flat JSON object in `~/.voiced/settings.json`.
///
/// Every property reads and writes the file-backed store directly, so there is no cached state to keep in sync.
/// The keys are stable: changing them would silently reset existing users' preferences.
struct AppSettings {
    private enum Key: String, CaseIterable {
        case appLanguage
        case recognitionLanguage
        case timestampMode
        case showTimestampDate
        case recognitionEngine
        case speechEnergyFloor
        case noiseReduction
        case keepWindowOnTop
    }

    private let file: SettingsFile

    init(fileURL: URL = VoicedDirectory.settingsFile) {
        file = SettingsFile(url: fileURL)
    }

    var fileURL: URL { file.url }

    var appLanguage: AppLanguage {
        get { rawValue(.appLanguage) ?? .chinese }
        nonmutating set { set(newValue.rawValue, for: .appLanguage) }
    }

    var recognitionLanguage: RecognitionLanguage {
        get { RecognitionLanguage.choice(id: string(.recognitionLanguage)) }
        nonmutating set { set(newValue.id, for: .recognitionLanguage) }
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
        get { file[Key.showTimestampDate.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .showTimestampDate) }
    }

    /// Whether captured audio goes through spectral subtraction. Only effective once a noise profile exists.
    var noiseReduction: Bool {
        get { file[Key.noiseReduction.rawValue] as? Bool ?? true }
        nonmutating set { set(newValue, for: .noiseReduction) }
    }

    /// Whether the main window floats above other apps' windows.
    var keepWindowOnTop: Bool {
        get { file[Key.keepWindowOnTop.rawValue] as? Bool ?? false }
        nonmutating set { set(newValue, for: .keepWindowOnTop) }
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
