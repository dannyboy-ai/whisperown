// swift-tools-version:5.9
import PackageDescription

// A plain SwiftPM executable — the standard way to build a multi-file Swift app
// without Xcode. `swift build` compiles everything in Sources/ into the WhisperOwn
// binary (which build.sh then wraps in a .app bundle and code-signs). System
// frameworks (AppKit, AVFoundation, Carbon) link automatically from their imports.
let package = Package(
    name: "WhisperOwn",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "WhisperOwn", path: "Sources"),
    ]
)
