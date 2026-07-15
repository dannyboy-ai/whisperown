// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "wo-fluid",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(name: "wo-fluid",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Swifter", package: "swifter")
            ],
            path: "Sources/wo-fluid")
    ]
)
