// swift-tools-version: 6.0
import PackageDescription

// Runs the app's two listening stages on a Mac, against synthetic speech.
// The app's own source files are linked into Sources/check.
let package = Package(
    name: "transcribe-check",
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0")],
    targets: [
        .executableTarget(
            name: "check",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ])
    ]
)
