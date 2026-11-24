import VoicedCore
import Foundation

enum AppVersion {
    /// The marketing version from the app bundle's Info.plist, which `release.sh` keeps in step
    /// with the `VERSION` file. Nil when the binary runs outside a bundle, as under `swift run`.
    static let current: String? = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty
        else { return nil }
        return version
    }()
}
