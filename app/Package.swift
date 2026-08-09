// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcribe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Transcribe",
            path: "Sources/Transcribe"
        )
    ]
)
