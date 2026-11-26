import Foundation
import ImageIO
import RealityKit
import Testing
import UniformTypeIdentifiers
@testable import SpikeArt

/// Look-dev sheets for the art pass, rendered offscreen. They only run when asked:
///
///     SPIKEART_RENDER_DIR=/tmp/spikeart swift test --package-path Packages/SpikeArt --filter LookDev
///
/// writes the demo (both shading paths), a pose sheet from two angles, and jersey atlases.
@MainActor @Suite struct LookDev {
    nonisolated static let dir = ProcessInfo.processInfo.environment["SPIKEART_RENDER_DIR"]

    static func write(_ image: CGImage, _ name: String) throws {
        guard let dir else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test(.enabled(if: dir != nil)) func demo() async throws {
        for (name, style) in [("custom", ArtStyle.placeholder), ("fallback", ArtStyle(shading: .bandedFallback))] {
            try Self.write(try await OffscreenRender.demo(style: style), "demo-\(name)")
        }
    }

    @Test(.enabled(if: dir != nil)) func poseSheet() async throws {
        for (view, yaw) in [("side", Float.pi / 2), ("front", Float(0.5))] {
            let root = Entity()
            for (i, pose) in Pose.allCases.enumerated() {
                let rig = PlayerRig(look: .init(skinTone: i % 10, number: i + 1, team: i % 2 == 0 ? .home : .away,
                                                hair: PlayerLook.HairStyle.allCases[i % 6], gear: [.kneePads]),
                                    heightM: 1.9)
                rig.pose(pose, phase: pose == .spikeSwing ? 0.1 : 0.6)
                rig.entity.position = [Float(i) * 1.3 - 6.5, 0, 0]
                rig.entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
                root.addChild(rig.entity)
            }
            root.addChild(ToonModel.make(.box([30, 0.1, 10], center: [0, -0.05, 0]), color: [0.93, 0.6, 0.3], outlineWidth: 0))
            let cam = PerspectiveCamera()
            cam.camera.fieldOfViewInDegrees = 30
            cam.look(at: [0, 0.95, 0], from: [0, 1.6, 12], relativeTo: nil)
            root.addChild(cam)
            let img = try await OffscreenRender.image(of: root, camera: cam, width: 2400, height: 560,
                                                      background: [0.05, 0.04, 0.1])
            try Self.write(img, "poses-\(view)")
        }
    }

    @Test(.enabled(if: dir != nil)) func atlases() throws {
        for key in [JerseyTexture.Key(team: .home, number: 17, libero: false),
                    .init(team: .home, number: 12, libero: true), .init(team: .away, number: 1, libero: true)] {
            try Self.write(JerseyTexture.image(for: key), "atlas-\(key.team)-\(key.number)\(key.libero ? "-libero" : "")")
        }
    }
}
