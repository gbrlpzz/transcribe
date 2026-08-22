// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcribe",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Transcribe",
            path: "Sources/Transcribe",
            // Tools 6.2 defaults new packages to the Swift 6 language mode;
            // the app is still written in Swift 5 semantics. Native modules
            // land with strict concurrency in the W2 waves.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
