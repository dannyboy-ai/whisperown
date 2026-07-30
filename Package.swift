// swift-tools-version:6.0
import PackageDescription

// A plain SwiftPM executable — the standard way to build a multi-file Swift app
// without Xcode. `swift build` compiles everything in Sources/ into the WhisperOwn
// binary (which build.sh then wraps in a .app bundle and code-signs). System
// frameworks (AppKit, AVFoundation, Carbon) link automatically from their imports.
let package = Package(
    name: "WhisperOwn",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperOwn",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources"
        ),
        .testTarget(
            name: "WhisperOwnTests",
            dependencies: ["WhisperOwn"],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
