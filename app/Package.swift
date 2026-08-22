// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcribe",
    platforms: [.macOS(.v26)],
    targets: [
        // Shared native core (design §1): dictation/file lanes, locale assets,
        // sessions, settings. Strict-concurrency Swift 6 mode by default.
        .target(
            name: "TranscribeCore",
            path: "Sources/TranscribeCore"
        ),
        .executableTarget(
            name: "Transcribe",
            dependencies: [.target(name: "TranscribeCore")],
            path: "Sources/Transcribe",
            // Tools 6.2 defaults new packages to the Swift 6 language mode;
            // the app is still written in Swift 5 semantics. Native modules
            // land with strict concurrency in the W2 waves.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscribeCoreTests",
            dependencies: ["TranscribeCore"],
            path: "Tests/TranscribeCoreTests"
        )
    ]
)
