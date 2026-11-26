import CoreGraphics
import Foundation
import RealityKit
import simd

/// The 18×9 m court, lines, net, antennas, posts and a simple arena, cel-shaded.
///
/// Same frame as SpikeCore: the net on x = 0, home at negative x, sidelines at z = ±4.5, y up.
@MainActor
public final class CourtModel {
    public static let length: Float = 18
    public static let width: Float = 9
    /// Net heights: men 2.43 m, women 2.24 m.
    public static let menNetHeight: Float = 2.43
    public static let womenNetHeight: Float = 2.24
    public static let lineWidth: Float = 0.05
    /// The attack ("3 m") lines, measured from the center line.
    public static let attackLineDistance: Float = 3

    public let entity = Entity()
    public let style: ArtStyle
    /// Moves the net, tapes and antennas; the posts follow.
    public var netHeight: Float {
        didSet { if netHeight != oldValue { buildNet() } }
    }
    public private(set) var net = Entity()

    public init(netHeight: Float = CourtModel.menNetHeight, style: ArtStyle = .placeholder) {
        self.netHeight = netHeight
        self.style = style
        entity.name = "CourtModel"
        buildFloor()
        buildLines()
        buildArena()
        buildLights()
        buildNet()
    }

    @discardableResult
    private func slab(_ size: SIMD3<Float>, top: Float, color: SIMD3<Float>, at: SIMD3<Float> = .zero,
                      outline: Float = 0, name: String) -> ModelEntity {
        let m = ToonModel.make(.box(size, center: [0, top - size.y / 2, 0]), color: color, outlineWidth: outline,
                               style: style, name: name)
        m.position = at
        entity.addChild(m)
        return m
    }

    private func buildFloor() {
        slab([44, 0.1, 30], top: -0.012, color: style.arenaFloorColor, name: "arena")
        slab([26, 0.02, 15], top: -0.006, color: style.freeZoneColor, name: "freeZone")
        slab([Self.length, 0.02, Self.width], top: 0, color: style.courtColor, name: "court")
    }

    private func line(_ w: Float, _ d: Float, _ x: Float, _ z: Float) {
        let l = ModelEntity(mesh: .generatePlane(width: w, depth: d), materials: [ToonMaterial.flat(style.lineColor)])
        l.position = [x, 0.003, z]
        l.name = "line"
        entity.addChild(l)
    }

    private func buildLines() {
        let lw = Self.lineWidth
        let hl = Self.length / 2, hw = Self.width / 2
        // Lines lie inside the court they bound.
        line(Self.length, lw, 0, hw - lw / 2)
        line(Self.length, lw, 0, -(hw - lw / 2))
        line(lw, Self.width, hl - lw / 2, 0)
        line(lw, Self.width, -(hl - lw / 2), 0)
        line(lw, Self.width, 0, 0) // center line, under the net
        for sx: Float in [-1, 1] {
            let x = sx * (Self.attackLineDistance - lw / 2)
            line(lw, Self.width, x, 0)
            // Dashed extensions beyond the sidelines: five 15 cm dashes, 20 cm apart.
            for sz: Float in [-1, 1] {
                for i in 0..<5 { line(lw, 0.15, x, sz * (hw + 0.2 + 0.075 + Float(i) * 0.35)) }
            }
        }
    }

    private func buildArena() {
        // Stepped stands on three sides, in muted blocks so the court stays the brightest thing.
        let crowd: [SIMD3<Float>] = [[0.3, 0.2, 0.45], [0.22, 0.25, 0.5], [0.42, 0.22, 0.35], [0.2, 0.32, 0.42]]
        for row in 0..<3 {
            let h = 0.9 + Float(row) * 0.9
            let depth: Float = 1.6
            let off = 12.5 + Float(row) * depth
            for i in 0..<10 {
                let x = -16.2 + Float(i) * 3.6
                slab([3.5, h, depth], top: h, color: crowd[(i + row) % crowd.count], at: [x, 0, -off],
                     outline: style.propOutlineWidth, name: "stand")
            }
            for sx: Float in [-1, 1] {
                for i in 0..<5 {
                    let z = -9 + Float(i) * 3.6
                    slab([depth, h, 3.5], top: h, color: crowd[(i + row + 1) % crowd.count],
                         at: [sx * (17 + Float(row) * depth), 0, z], outline: style.propOutlineWidth, name: "stand")
                }
            }
        }
        // A scorer's table on the near sideline.
        slab([3, 0.8, 0.7], top: 0.8, color: [0.85, 0.85, 0.9], at: [0, 0, 7.6], outline: style.propOutlineWidth,
             name: "scorersTable")
    }

    private func buildLights() {
        // The toon shader lights itself from `ArtStyle.lightDirection`; these keep anything PBR
        // (and the fallback's neighbors) consistent with it.
        let sun = DirectionalLight()
        sun.light.intensity = 3000
        let l = simd_normalize(style.lightDirection)
        sun.look(at: .zero, from: l * 20, relativeTo: nil)
        sun.name = "keyLight"
        entity.addChild(sun)
        let fill = PointLight()
        fill.light.intensity = 60000
        fill.light.attenuationRadius = 40
        fill.position = [0, 10, 8]
        fill.name = "fillLight"
        entity.addChild(fill)
    }

    private func buildNet() {
        net.removeFromParent()
        net = Entity()
        net.name = "net"
        entity.addChild(net)
        let top = netHeight
        let netLength: Float = 9.8
        // The mesh: a grid texture on a two-sided plane, 1 m tall.
        var mesh = UnlitMaterial()
        if let tex = try? Self.netTexture() {
            mesh.color = .init(tint: .white, texture: .init(tex))
            mesh.blending = .transparent(opacity: .init(floatLiteral: 1))
            mesh.opacityThreshold = 0.1
        } else {
            mesh = ToonMaterial.flat(style.netColor, alpha: 0.55)
        }
        mesh.faceCulling = .none
        let plane = ModelEntity(mesh: .generatePlane(width: netLength, height: 1), materials: [mesh])
        plane.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        plane.position = [0, top - 0.5, 0]
        net.addChild(plane)
        // Tapes.
        let tape = ToonModel.make(.box([0.03, 0.07, netLength]), color: [1, 1, 1], outlineWidth: 0.01, style: style, name: "topTape")
        tape.position = [0, top - 0.035, 0]
        net.addChild(tape)
        let bottom = ToonModel.make(.box([0.02, 0.05, netLength]), color: [0.95, 0.95, 0.95], outlineWidth: 0, style: style, name: "bottomTape")
        bottom.position = [0, top - 0.975, 0]
        net.addChild(bottom)
        // Posts 1 m outside the sidelines, and the antennas on the sidelines: 1.8 m, 0.8 m above
        // the tape, in 10 cm red and white bands (drawn thicker than the real 10 mm to read on a phone).
        for sz: Float in [-1, 1] {
            let post = ToonModel.make(.frustum(y0: 0, y1: top + 0.1, r0: 0.06, r1: 0.06, sides: 8), color: [0.75, 0.78, 0.85],
                                      outlineWidth: style.propOutlineWidth, style: style, name: "post")
            post.position = [0, 0, sz * (Self.width / 2 + 1)]
            net.addChild(post)
            let pad = ToonModel.make(.frustum(y0: 0, y1: 1.8, r0: 0.13, r1: 0.13, sides: 8), color: [0.2, 0.25, 0.6],
                                     outlineWidth: style.propOutlineWidth, style: style, name: "postPad")
            pad.position = post.position
            net.addChild(pad)
            let antenna = Entity()
            antenna.name = "antenna"
            antenna.position = [0, top - 1, sz * Self.width / 2]
            for i in 0..<18 {
                let red = i % 2 == 0
                let seg = ToonModel.make(.frustum(y0: Float(i) * 0.1, y1: Float(i + 1) * 0.1, r0: 0.018, r1: 0.018, sides: 6),
                                         color: red ? [0.92, 0.12, 0.12] : [1, 1, 1],
                                         outlineWidth: 0.008, style: style, name: "antennaBand")
                antenna.addChild(seg)
            }
            net.addChild(antenna)
        }
    }

    /// A dark 10 cm mesh with alpha, drawn by Core Graphics.
    static func netTexture() throws -> TextureResource {
        let w = 980, h = 100 // 1 px per cm
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 0.9))
        for x in stride(from: 0, to: w, by: 10) { ctx.fill(CGRect(x: x, y: 0, width: 2, height: h)) }
        for y in stride(from: 0, to: h, by: 10) { ctx.fill(CGRect(x: 0, y: y, width: w, height: 2)) }
        return try TextureResource(image: ctx.makeImage()!, options: .init(semantic: .color))
    }
}
