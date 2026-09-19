// swift-tools-version: 5.9
import PackageDescription

// PitBossKit is deliberately platform-agnostic: CoreBluetooth and
// JavaScriptCore both exist on macOS, so the whole protocol layer builds and
// verifies on a Mac with no Xcode and no iOS SDK. The SwiftUI app is the only
// iOS-only part. See ../../docs/adr/0006-native-ios-app.md.
//
// The conformance checks are an executable rather than an XCTest suite on
// purpose: XCTest and swift-testing both ship inside Xcode, so a test target
// cannot run on a machine with only Command Line Tools (or in CI without a
// full Xcode image). `swift run pitboss-verify` runs anywhere.
let package = Package(
    name: "PitBossKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PitBossKit", targets: ["PitBossKit"]),
        .executable(name: "pitboss-verify", targets: ["pitboss-verify"]),
    ],
    targets: [
        .target(
            name: "PitBossKit",
            resources: [.copy("Resources/grills.json"), .copy("Resources/cooking.json")]
        ),
        .executableTarget(
            name: "pitboss-verify",
            dependencies: ["PitBossKit"],
            resources: [.copy("vectors.json"), .copy("estimate-vectors.json")]
        ),
    ]
)
