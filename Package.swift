// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bionic",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        // Obj-C shim so Swift can survive AVFoundation's NSException-raising APIs.
        // See Sources/CExceptionCatcher/include/CExceptionCatcher.h for why this exists.
        .target(name: "CExceptionCatcher"),
        .executableTarget(
            name: "bionic",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CExceptionCatcher",
            ]
        )
    ]
)
