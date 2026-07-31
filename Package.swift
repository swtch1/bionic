// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bionic",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "bionic",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
