// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceStudioCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "VoiceStudioCore", targets: ["VoiceStudioCore"])],
    targets: [
        .target(name: "VoiceStudioCore"),
        .testTarget(name: "VoiceStudioCoreTests", dependencies: ["VoiceStudioCore"]),
    ]
)