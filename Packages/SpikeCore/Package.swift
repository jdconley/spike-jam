// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpikeCore",
    platforms: [.iOS("26.0"), .tvOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "SpikeCore", targets: ["SpikeCore"]),
        .executable(name: "spikesim", targets: ["spikesim"]),
    ],
    targets: [
        .target(
            name: "SpikeCore",
            // Float.squareRoot() lowers to libm's sqrtf on Linux; without
            // Foundation nothing else links libm.
            linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]
        ),
        .executableTarget(name: "spikesim", dependencies: ["SpikeCore"]),
        .testTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore"]),
    ]
)
