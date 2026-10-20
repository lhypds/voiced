import Foundation

/// User preferences persisted in `UserDefaults`.
///
/// Every property reads and writes the store directly, so there is no cached state to keep in sync.
/// The keys are stable: changing them would silently reset existing users' preferences.
struct AppSettings {
    private enum Key: String {
        case appLanguage
        case recognitionLanguage
        case timestampMode
        case showTimestampDate
        case recognitionEngine
        case speechEnergyFloor
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
        get { defaults.bool(forKey: Key.showTimestampDate.rawValue) }
        nonmutating set { set(newValue, for: .showTimestampDate) }
    }

    /// Minimum frame RMS the voice detector treats as speech. Clamped to the transcriber's range.
    var speechEnergyFloor: Float {
        get {
            guard let stored = defaults.object(forKey: Key.speechEnergyFloor.rawValue) as? Double else {
                return LiveTranscriber.defaultSpeechEnergyFloor
            }
            return Float(stored).clamped(to: LiveTranscriber.speechEnergyFloorRange)
        }
        nonmutating set { set(Double(newValue.clamped(to: LiveTranscriber.speechEnergyFloorRange)), for: .speechEnergyFloor) }
    }

    private func string(_ key: Key) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    private func rawValue<T: RawRepresentable>(_ key: Key) -> T? where T.RawValue == String {
        string(key).flatMap(T.init(rawValue:))
    }

    private func set(_ value: Any?, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
