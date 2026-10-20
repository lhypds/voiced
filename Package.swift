// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Voiced",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voiced", targets: ["Voiced"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "Voiced",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .executableTarget(
            name: "VoicedSimulate",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        .testTarget(
            name: "VoicedTests",
            dependencies: [
                "Voiced",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
