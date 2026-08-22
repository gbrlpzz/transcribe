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
        // CLI logic library (design §9, R40/R48): linked INTO the app binary —
        // single-binary dispatch, argv[0] "transcribe" selects CLI mode (R49).
        .target(
            name: "TranscribeCLI",
            dependencies: [.target(name: "TranscribeCore")],
            path: "Sources/TranscribeCLI"
        ),
        .executableTarget(
            name: "Transcribe",
            dependencies: [.target(name: "TranscribeCore"), .target(name: "TranscribeCLI")],
            path: "Sources/Transcribe",
            // Tools 6.2 defaults new packages to the Swift 6 language mode;
            // the app is still written in Swift 5 semantics. Native modules
            // land with strict concurrency in the W2 waves.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLT-only machines have no XCTest/swift-testing runtime (verified
        // 2026-08-23); this executable IS the test target until Xcode lands.
        // Same suites, injected fakes, non-zero exit on any failure.
        .executableTarget(
            name: "TranscribeCoreTests",
            dependencies: [.target(name: "TranscribeCore"), .target(name: "TranscribeCLI")],
            path: "Tests/TranscribeCoreTests"
        )
    ]
)
