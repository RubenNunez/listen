// swift-tools-version: 6.0
import PackageDescription

// Tests the app's exact configuration sources without building, starting or
// making requests from the app under concurrent performance measurement.
let package = Package(
    name: "harness-config",
    platforms: [.macOS("15.0")],
    products: [.library(name: "HarnessCore", targets: ["HarnessCore"])],
    targets: [
        .target(name: "HarnessCore"),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"],
                    swiftSettings: [.define("HARNESS_CONFIG_COMPATIBILITY")]),
    ]
)
