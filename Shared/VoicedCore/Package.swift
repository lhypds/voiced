// swift-tools-version: 6.2

import PackageDescription

// This package is the only Swift package the iOS project imports. Desktop executables
// remain in the repository's macOS-only root package, outside the mobile dependency graph.
let package = Package(
    name: "VoicedCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VoicedCore", targets: ["VoicedCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "VoicedCore",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ],
    swiftLanguageModes: [.v5]
)
