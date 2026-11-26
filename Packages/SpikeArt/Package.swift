// swift-tools-version: 6.0
import PackageDescription

// Placeholder rendering kit: cel-shaded court and players drawn with RealityKit.
// It deliberately does not depend on SpikeCore. The app maps SpikeCore's state onto it.
let package = Package(
    name: "SpikeArt",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "SpikeArt", targets: ["SpikeArt"]),
    ],
    targets: [
        .target(name: "SpikeArt"),
        .testTarget(name: "SpikeArtTests", dependencies: ["SpikeArt"]),
    ]
)
