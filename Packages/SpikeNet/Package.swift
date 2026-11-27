// swift-tools-version: 6.0
import PackageDescription

// The protocol, the server loop and the client's prediction (spec §5.1, §5.3). No Apple-only
// frameworks, so the match server can build it for Linux.
let package = Package(
    name: "SpikeNet",
    platforms: [.iOS("26.0"), .tvOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "SpikeNet", targets: ["SpikeNet"]),
    ],
    dependencies: [
        .package(path: "../SpikeCore"),
    ],
    targets: [
        .target(name: "SpikeNet", dependencies: [.product(name: "SpikeCore", package: "SpikeCore")]),
        .testTarget(name: "SpikeNetTests", dependencies: ["SpikeNet"]),
    ]
)
