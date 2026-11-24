// swift-tools-version: 6.2

import PackageDescription

// The phone input service: a background process, separate from the app, that types what the
// iPhone app sends at the Mac's cursor. It needs nothing from WhisperKit, so it is its own
// package and builds in seconds.
let package = Package(
    name: "VoicedInput",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoicedInput", targets: ["VoicedInput"])
    ],
    targets: [
        .executableTarget(
            name: "VoicedInput",
            // The service ships as a single binary rather than an app bundle, so its Info.plist
            // (identifier, name) is embedded in it; the identifier names its preferences domain.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
