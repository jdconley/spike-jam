import CoreGraphics
import Foundation
import RealityKit
import Testing
@testable import SpikeArt

@MainActor @Suite struct PlayerRigTests {
    @Test func heightScaling() {
        let rig = PlayerRig(look: .init(skinTone: 3, number: 7, team: .home), heightM: 2.05)
        #expect(abs(rig.scale - 2.05 / 1.9) < 1e-4)
        #expect(abs(rig.entity.scale.x - 2.05 / 1.9) < 1e-4)
        #expect(abs(rig.entity.scale.y - 2.05 / 1.9) < 1e-4)
        #expect(abs(PlayerRig.scale(forHeight: 1.72) - 1.72 / 1.9) < 1e-4)
        // The visual top of the head lands near the athlete's height.
        let bounds = rig.entity.visualBounds(relativeTo: nil)
        #expect(abs(bounds.max.y - 2.05) < 0.12)
    }

    @Test(arguments: Pose.allCases) func everyPoseBuilds(_ pose: Pose) {
        for hair in PlayerLook.HairStyle.allCases {
            let look = PlayerLook(skinTone: hair.rawValue, number: 10 + hair.rawValue, team: .away,
                                  isLibero: hair == .bun, hair: hair, gear: [.kneePads, .headband, .armSleeves])
            let rig = PlayerRig(look: look, heightM: 1.85)
            for phase: Float in [0, 0.25, 0.5, 0.99, 1, -1, 2, .nan] {
                rig.pose(pose, phase: phase)
                #expect(rig.currentPose == pose)
                var all: [Entity] = [rig.entity]
                var i = 0
                while i < all.count { all.append(contentsOf: all[i].children); i += 1 }
                for e in all {
                    let m = e.transform.matrix
                    let finite = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].allSatisfy {
                        $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
                    }
                    #expect(finite, "\(pose) phase \(phase): \(e.name) has a non-finite transform")
                }
                // Grounded: the lowest probe sits on the floor.
                let lowest = rig.probes.map { $0.position(relativeTo: rig.entity).y }.min() ?? 1
                #expect(abs(lowest) < 1e-3, "\(pose) phase \(phase) floats or sinks: \(lowest)")
            }
        }
    }

    @Test func outlinesOnEveryPart() {
        let rig = PlayerRig(look: .init(skinTone: 0, number: 1, team: .home), heightM: 1.9)
        var models: [ModelEntity] = []
        var stack: [Entity] = [rig.entity]
        while let e = stack.popLast() {
            stack.append(contentsOf: e.children)
            if let m = e as? ModelEntity, m.name != "outline" { models.append(m) }
        }
        #expect(models.count > 20)
        let outlined = models.filter { $0.children.contains { $0.name == "outline" } }
        // Everything but the eyes and socks carries an ink outline.
        #expect(outlined.count == models.count - models.filter { $0.name == "eye" || $0.name == "sock" }.count)
    }

    @Test func onFireToggles() {
        let rig = PlayerRig(look: .init(skinTone: 5, number: 4, team: .away), heightM: 1.9)
        #expect(!rig.isOnFire)
        rig.setOnFire(true)
        rig.setOnFire(true)
        #expect(rig.isOnFire)
        #expect(rig.fire?.components[ParticleEmitterComponent.self] != nil)
        #expect(rig.body.children.filter { $0.name == "fire" }.count == 1)
        rig.setOnFire(false)
        #expect(!rig.isOnFire)
        #expect(rig.body.children.allSatisfy { $0.name != "fire" })
    }
}

@MainActor @Suite struct JerseyTextureTests {
    static func pixels(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return px
    }

    @Test func jerseyNumberTexture() throws {
        let seven = try JerseyTexture.texture(team: .home, number: 7, libero: false)
        let seventeen = try JerseyTexture.texture(team: .home, number: 17, libero: false)
        #expect(seven.width == 512 && seven.height == 512)
        #expect(seventeen.width == 512 && seventeen.height == 512)
        #expect(seven !== seventeen)
        let a = JerseyTexture.image(for: .init(team: .home, number: 7, libero: false))
        let b = JerseyTexture.image(for: .init(team: .home, number: 17, libero: false))
        #expect(a.width == 512 && a.height == 512)
        let pa = Self.pixels(a), pb = Self.pixels(b)
        var differing = 0
        for i in stride(from: 0, to: pa.count, by: 4) where pa[i] != pb[i] || pa[i + 1] != pb[i + 1] {
            differing += 1
        }
        #expect(differing > 2000, "the numbers should change thousands of pixels, got \(differing)")
    }

    @Test func cachedPerTeamNumberAndLibero() throws {
        let a = try JerseyTexture.texture(team: .away, number: 9, libero: false)
        let again = try JerseyTexture.texture(team: .away, number: 9, libero: false)
        let libero = try JerseyTexture.texture(team: .away, number: 9, libero: true)
        let home = try JerseyTexture.texture(team: .home, number: 9, libero: false)
        #expect(a === again)
        #expect(a !== libero && a !== home && libero !== home)
    }

    @Test func liberoContrasts() {
        let regular = Self.pixels(JerseyTexture.image(for: .init(team: .away, number: 3, libero: false)))
        let libero = Self.pixels(JerseyTexture.image(for: .init(team: .away, number: 3, libero: true)))
        // Sample the plain jersey just under the collar.
        let i = (40 * 512 + 20) * 4
        let d = (0..<3).map { abs(Int(regular[i + $0]) - Int(libero[i + $0])) }.reduce(0, +)
        #expect(d > 150)
    }
}

@Suite struct PaletteTests {
    @Test func skinPaletteDistinct() {
        #expect(Palette.skin.count == 10)
        #expect(Set(Palette.skin.map { "\($0)" }).count == 10)
        let l = Palette.skin.map(Palette.lightness)
        for i in 1..<l.count {
            #expect(l[i] < l[i - 1] - 2, "stop \(i) should be clearly darker than stop \(i - 1): \(l)")
        }
        // Across the human range: very light to very dark.
        #expect(l.first! > 85 && l.last! < 25)
    }

    @Test func teamColors() {
        #expect(Palette.homeJersey == [0.95, 0.25, 0.2])
        #expect(Palette.awayJersey == [0.1, 0.75, 0.75])
        #expect(Palette.lightness(Palette.homeLibero) > 90)
        #expect(Palette.lightness(Palette.awayLibero) < 20)
    }

    @Test func rampBands() {
        let s = ArtStyle.placeholder
        #expect(s.band(forNormal: s.lightDirection) == 0)
        #expect(s.band(forNormal: -s.lightDirection) == 2)
        let side = simd_normalize(simd_cross(s.lightDirection, [0, 0, 1]))
        #expect(s.band(forNormal: side) == 1)
        let c: SIMD3<Float> = [0.8, 0.6, 0.4]
        #expect(simd_length(s.shade(c, band: 0)) > simd_length(s.shade(c, band: 1)))
        #expect(simd_length(s.shade(c, band: 1)) > simd_length(s.shade(c, band: 2)))
    }
}

@MainActor @Suite struct MaterialAndCourtTests {
    @Test func bothShadingPathsBuild() {
        let mesh = LowPolyMesh.sphere(radii: [1, 1, 1])
        let fallback = ToonModel.make(mesh, color: [1, 0, 0], outlineWidth: 0.02,
                                      style: ArtStyle(shading: .bandedFallback))
        #expect(fallback.model?.materials.count == 3)
        #expect(fallback.model?.materials.allSatisfy { $0 is UnlitMaterial } == true)
        let auto = ToonModel.make(mesh, color: [1, 0, 0], outlineWidth: 0.02)
        print("SpikeArt toon path on this device: \(ToonMaterial.path(for: .placeholder))")
        if ToonMaterial.path(for: .placeholder) == .custom {
            #expect(auto.model?.materials.first is CustomMaterial)
        } else {
            #expect(auto.model?.materials.count == 3)
        }
        let outline = auto.children.first { $0.name == "outline" } as? ModelEntity
        #expect((outline?.model?.materials.first as? UnlitMaterial)?.faceCulling == .front)
    }

    @Test func meshesFaceOutward() {
        // Convex primitives: every face normal points away from the centroid.
        let meshes: [LowPolyMesh] = [
            .box([1, 2, 3]), .sphere(radii: [1, 1.2, 0.9]), .frustum(y0: -1, y1: 1, r0: 0.5, r1: 0.3),
            .sphere(radii: [1, 1, 1], yMin: 0),
        ]
        for m in meshes {
            let c = m.positions.reduce(.zero, +) / Float(m.positions.count)
            for t in 0..<m.triangleCount {
                let p = m.positions[Int(m.indices[t * 3])]
                #expect(simd_dot(m.faceNormal(t), p - c) > -1e-4)
            }
            let hull = m.outlineHull(width: 0.05)
            #expect(hull.positions.count == m.positions.count)
        }
    }

    @Test func courtNetHeight() {
        let court = CourtModel(netHeight: CourtModel.menNetHeight)
        func tapeTop() -> Float {
            let tape = court.net.children.first { $0.name == "topTape" }!
            return tape.position(relativeTo: court.entity).y + 0.035
        }
        #expect(abs(tapeTop() - 2.43) < 1e-4)
        court.netHeight = CourtModel.womenNetHeight
        #expect(abs(tapeTop() - 2.24) < 1e-4)
        #expect(court.entity.children.filter { $0.name == "net" }.count == 1)
        let antennas = court.net.children.filter { $0.name == "antenna" }
        #expect(antennas.count == 2)
        #expect(Set(antennas.map { abs($0.position.z) }) == [4.5])
        let court18 = court.entity.children.first { $0.name == "court" }!
        let b = court18.visualBounds(relativeTo: court.entity)
        #expect(abs((b.max.x - b.min.x) - 18) < 0.01 && abs((b.max.z - b.min.z) - 9) < 0.01)
    }

    @Test func demoHasTwelveDistinctPlayers() {
        let demo = DemoScene()
        #expect(demo.rigs.count == 12)
        #expect(Set(demo.players.map(\.look)).count == 12)
        for team in ArtTeam.allCases {
            let side = demo.players.filter { $0.look.team == team }
            #expect(side.count == 6)
            #expect(side.filter(\.look.isLibero).count == 1)
            #expect(Set(side.map(\.look.number)).count == 6)
            #expect(Set(side.map(\.look.skinTone)).count >= 5)
        }
        #expect(Set(demo.players.map(\.pose)) == Set(Pose.allCases))
        demo.step(0.5)
    }
}
