// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Thoth",
    platforms: [.macOS(.v14)], // @Observable
    targets: [
        .executableTarget(
            name: "Thoth",
            path: "Sources/Thoth"
        ),
        .testTarget(
            name: "ThothTests",
            dependencies: ["Thoth"],
            path: "Tests/ThothTests",
            // Synthetic JSONL transcripts for the log format compatibility tests.
            resources: [.copy("Fixtures")]
        )
    ],
    // Swift 6 strict concurrency is not adopted yet; keep the Swift 5 language mode.
    swiftLanguageModes: [.v5]
)
