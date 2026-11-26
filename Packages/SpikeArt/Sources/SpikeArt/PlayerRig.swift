import Foundation
import RealityKit
import simd

/// An original low-poly volleyball player built from cel-shaded meshes.
///
/// Built at the 1.9 m reference height and scaled uniformly by `heightM / 1.9`. The figure faces
/// +z with its left side toward +x; turn `entity` about y to face elsewhere (home faces +x, a
/// quarter turn of +π/2). Every pose keeps the lowest point of the body on y = 0, so the app
/// places `entity` on the floor and adds jump height itself.
@MainActor
public final class PlayerRig {
    public nonisolated static let referenceHeight: Float = 1.9

    /// The uniform scale for an athlete of `heightM`.
    public nonisolated static func scale(forHeight heightM: Float) -> Float { heightM / referenceHeight }

    /// The root to add to a scene. Position and turn it; don't scale it.
    public let entity: Entity
    public let look: PlayerLook
    public let heightM: Float
    public let style: ArtStyle
    public var scale: Float { Self.scale(forHeight: heightM) }
    public private(set) var currentPose: Pose = .stand
    public private(set) var currentPhase: Float = 0
    public var isOnFire: Bool { fire != nil }

    // Joints. `body` carries the grounding offset; `pelvis` the whole-body tilt (dives).
    let body = Entity()
    let pelvis = Entity()
    let spine = Entity()
    let neck = Entity()
    let shoulder: [Entity] = [Entity(), Entity()] // 0 left (+x), 1 right
    let elbow: [Entity] = [Entity(), Entity()]
    let hip: [Entity] = [Entity(), Entity()]
    let knee: [Entity] = [Entity(), Entity()]
    let ankle: [Entity] = [Entity(), Entity()]
    var probes: [Entity] = []
    var fire: Entity?

    // Proportions at the reference height, in meters.
    enum Dim {
        static let hipY: Float = 0.98
        static let thigh: Float = 0.44
        static let shin: Float = 0.46
        static let shoeH: Float = 0.08
        static let upperArm: Float = 0.3
        static let forearm: Float = 0.28
        static let torsoH: Float = 0.56
        static let spineY: Float = 0.1
        static let shoulderY: Float = 0.5
        static let headR = SIMD3<Float>(0.115, 0.135, 0.125)
    }

    public init(look: PlayerLook, heightM: Float, style: ArtStyle = .placeholder) {
        self.look = look
        self.heightM = heightM
        self.style = style
        entity = Entity()
        entity.name = "PlayerRig #\(look.number)"
        entity.scale = SIMD3(repeating: Self.scale(forHeight: heightM))
        build()
        pose(.stand, phase: 0)
    }

    // MARK: Building

    private func part(_ mesh: LowPolyMesh, _ color: SIMD3<Float>, texture: TextureResource? = nil,
                      outline: Bool = true, name: String) -> ModelEntity {
        ToonModel.make(mesh, color: color, texture: texture, outlineWidth: outline ? style.outlineWidth : 0,
                       style: style, name: name)
    }

    private func probe(_ at: SIMD3<Float>, on parent: Entity) {
        let p = Entity()
        p.position = at
        parent.addChild(p)
        probes.append(p)
    }

    private func build() {
        let w = look.build.widthScale
        let skin = Palette.skin[min(max(look.skinTone, 0), Palette.skin.count - 1)]
        let hairColor = Palette.hair[min(max(look.hairColor, 0), Palette.hair.count - 1)]
        let shoe = Palette.shoes[min(max(look.shoeColor, 0), Palette.shoes.count - 1)]
        let gear = look.gear.contains(.darkGear) ? Palette.gearDark : Palette.gearLight
        let jerseyTex = try? JerseyTexture.texture(team: look.team, number: look.number, libero: look.isLibero)
        let jersey = Palette.jersey(look.team, libero: look.isLibero)
        let shorts = Palette.shorts(look.team, libero: look.isLibero)
        let white: SIMD3<Float> = [1, 1, 1]
        let texColor = { (fallback: SIMD3<Float>) in jerseyTex == nil ? fallback : white }

        entity.addChild(body)
        body.addChild(pelvis)
        pelvis.position.y = Dim.hipY

        // Shorts.
        let shortsMesh = LowPolyMesh.box([0.37 * w, 0.26, 0.23 * w], center: [0, 0.02, 0]) { face in
            face == .front ? JerseyTexture.Region.shortsFront : JerseyTexture.Region.shortsSolid
        }
        pelvis.addChild(part(shortsMesh, texColor(shorts), texture: jerseyTex, name: "shorts"))
        probe([0, -0.11, 0], on: pelvis)

        // Torso with the jersey atlas: front and back numbers.
        pelvis.addChild(spine)
        spine.position.y = Dim.spineY
        let torsoMesh = LowPolyMesh.box([0.46 * w, Dim.torsoH, 0.25 * w], center: [0, Dim.torsoH / 2 - 0.04, 0]) { face in
            switch face {
            case .front: JerseyTexture.Region.front
            case .back: JerseyTexture.Region.back
            default: JerseyTexture.Region.jerseySolid
            }
        }
        spine.addChild(part(torsoMesh, texColor(jersey), texture: jerseyTex, name: "torso"))
        for x: Float in [-0.2, 0.2] {
            for y: Float in [0, Dim.torsoH - 0.06] { probe([x * w, y, 0.13 * w], on: spine) }
        }

        // Neck and head.
        spine.addChild(neck)
        neck.position.y = Dim.torsoH - 0.05
        neck.addChild(part(.limb(length: 0.1, topRadius: 0.05, bottomRadius: 0.055).translated([0, 0.1, 0]),
                           skin, name: "neck"))
        let headC = SIMD3<Float>(0, 0.2, 0.01)
        neck.addChild(part(.sphere(radii: Dim.headR, center: headC, segments: 10, rings: 7), skin, name: "head"))
        for x: Float in [-0.045, 0.045] {
            let eye = part(.box([0.024, 0.034, 0.012], center: headC + [x, 0.01, Dim.headR.z - 0.004]),
                           [0.05, 0.04, 0.08], outline: false, name: "eye")
            neck.addChild(eye)
        }
        probe(headC + [0, -Dim.headR.y, 0], on: neck)
        probe(headC + [0, Dim.headR.y, 0], on: neck)
        probe(headC + [0, 0, Dim.headR.z], on: neck)
        buildHair(center: headC, color: hairColor)
        if look.gear.contains(.headband) {
            let band = LowPolyMesh.frustum(y0: -0.025, y1: 0.025, r0: Dim.headR.x + 0.012, r1: Dim.headR.x + 0.008,
                                           sides: 10, depthScale: Dim.headR.z / Dim.headR.x)
                .translated(headC + [0, 0.065, 0])
            neck.addChild(part(band, gear, name: "headband"))
        }

        // Arms.
        let armSkin = look.gear.contains(.armSleeves) ? gear : skin
        for side in 0..<2 {
            let sx: Float = side == 0 ? 1 : -1
            let s = shoulder[side]
            s.position = [sx * 0.27 * w, Dim.shoulderY, 0]
            spine.addChild(s)
            s.addChild(part(.limb(length: Dim.upperArm, topRadius: 0.06 * w, bottomRadius: 0.048), armSkin, name: "upperArm"))
            // A short jersey sleeve over the shoulder.
            s.addChild(part(.limb(length: 0.13, topRadius: 0.078 * w, bottomRadius: 0.068 * w, uv: JerseyTexture.Region.jerseySolid)
                .translated([0, 0.03, 0]), texColor(jersey), texture: jerseyTex, name: "sleeve"))
            let e = elbow[side]
            e.position.y = -Dim.upperArm
            s.addChild(e)
            e.addChild(part(.limb(length: Dim.forearm, topRadius: 0.047, bottomRadius: 0.038), armSkin, name: "forearm"))
            e.addChild(part(.sphere(radii: [0.045, 0.055, 0.04], center: [0, -Dim.forearm - 0.04, 0], segments: 6, rings: 4),
                            skin, name: "hand"))
            probe([0, -Dim.forearm - 0.09, 0], on: e)
        }

        // Legs.
        for side in 0..<2 {
            let sx: Float = side == 0 ? 1 : -1
            let h = hip[side]
            h.position = [sx * 0.1 * w, -0.02, 0]
            pelvis.addChild(h)
            h.addChild(part(.limb(length: Dim.thigh, topRadius: 0.092 * w, bottomRadius: 0.068), skin, name: "thigh"))
            // Shorts legs over the top of the thigh.
            h.addChild(part(.limb(length: 0.17, topRadius: 0.105 * w, bottomRadius: 0.095 * w, uv: JerseyTexture.Region.shortsSolid)
                .translated([0, 0.04, 0]), texColor(shorts), texture: jerseyTex, name: "shortsLeg"))
            let k = knee[side]
            k.position.y = -Dim.thigh
            h.addChild(k)
            k.addChild(part(.limb(length: Dim.shin, topRadius: 0.064, bottomRadius: 0.048), skin, name: "shin"))
            if look.gear.contains(.kneePads) {
                k.addChild(part(.limb(length: 0.12, topRadius: 0.082, bottomRadius: 0.078).translated([0, 0.05, 0.008]),
                                gear, name: "kneePad"))
            }
            // A white sock, then the shoe.
            k.addChild(part(.limb(length: 0.09, topRadius: 0.052, bottomRadius: 0.05).translated([0, -Dim.shin + 0.09, 0]),
                            [0.95, 0.95, 0.95], outline: false, name: "sock"))
            probe([0, 0, 0.07], on: k)
            let a = ankle[side]
            a.position.y = -Dim.shin
            k.addChild(a)
            a.addChild(part(.box([0.11, Dim.shoeH, 0.27], center: [0, -Dim.shoeH / 2, 0.045]), shoe, name: "shoe"))
            probe([0, -Dim.shoeH, 0.17], on: a)
            probe([0, -Dim.shoeH, -0.08], on: a)
        }
    }

    private func buildHair(center c: SIMD3<Float>, color: SIMD3<Float>) {
        let r = Dim.headR
        var meshes: [LowPolyMesh] = []
        switch look.hair {
        case .buzz:
            meshes.append(.sphere(radii: r * 1.04, center: c + [0, 0.004, -0.004], segments: 10, rings: 4, yMin: 0.2))
        case .crop:
            meshes.append(.sphere(radii: r * [1.1, 1.08, 1.1], center: c + [0, 0.012, -0.012], segments: 10, rings: 5, yMin: 0.05))
            // A fringe swept to one side.
            meshes.append(.box([0.16, 0.04, 0.05], center: c + [0.02, 0.095, 0.095])
                .transformed(simd_float4x4(simd_quatf(angle: 0.25, axis: [0, 0, 1]))))
        case .afro:
            meshes.append(.sphere(radii: [0.185, 0.17, 0.18], center: c + [0, 0.06, -0.025], segments: 12, rings: 8, yMin: -0.25))
        case .ponytail:
            meshes.append(.sphere(radii: r * 1.08, center: c + [0, 0.008, -0.01], segments: 10, rings: 5, yMin: 0))
            let tail = LowPolyMesh.limb(length: 0.24, topRadius: 0.045, bottomRadius: 0.02, sides: 6)
                .transformed(simd_float4x4(simd_quatf(angle: 0.45, axis: [1, 0, 0])))
                .translated(c + [0, 0.06, -0.13])
            meshes.append(tail)
        case .bun:
            meshes.append(.sphere(radii: r * 1.07, center: c + [0, 0.006, -0.008], segments: 10, rings: 5, yMin: 0))
            meshes.append(.sphere(radii: [0.06, 0.055, 0.06], center: c + [0, 0.13, -0.07], segments: 8, rings: 5))
        case .locs:
            meshes.append(.sphere(radii: r * 1.1, center: c + [0, 0.01, -0.01], segments: 10, rings: 5, yMin: 0))
            for i in 0..<7 {
                let a = Float(i) / 6 * 2.6 - 1.3 // around the back and sides
                let lx = sinf(a) * 0.12, lz = -cosf(a) * 0.11
                meshes.append(LowPolyMesh.limb(length: 0.2, topRadius: 0.022, bottomRadius: 0.018, sides: 5)
                    .translated(c + [lx, 0.04, lz]))
            }
        }
        var hair = LowPolyMesh()
        for m in meshes { hair.append(m) }
        neck.addChild(part(hair, color, name: "hair"))
    }

    // MARK: Fire

    /// Adds or removes the on-fire flame emitter.
    public func setOnFire(_ on: Bool) {
        if on, fire == nil {
            let fx = Entity()
            fx.name = "fire"
            fx.position.y = 1.2
            fx.components.set(Self.flameEmitter())
            body.addChild(fx)
            fire = fx
        } else if !on, let fx = fire {
            fx.removeFromParent()
            fire = nil
        }
    }

    static func flameEmitter() -> ParticleEmitterComponent {
        var pe = ParticleEmitterComponent()
        pe.emitterShape = .sphere
        pe.emitterShapeSize = [0.32, 0.6, 0.32]
        pe.mainEmitter.birthRate = 280
        pe.mainEmitter.lifeSpan = 0.5
        pe.mainEmitter.size = 0.12
        pe.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.1
        pe.mainEmitter.acceleration = [0, 4, 0]
        pe.mainEmitter.blendMode = .additive
        pe.mainEmitter.color = .evolving(start: .single(Palette.color([1, 0.85, 0.2])),
                                         end: .single(Palette.color([1, 0.15, 0])))
        pe.speed = 0.6
        pe.isEmitting = true
        return pe
    }

    // MARK: Posing

    /// Sets a procedural pose. `phase` 0...1 is a cycle for `run` and `shuffle`, progress otherwise.
    public func pose(_ p: Pose, phase: Float) {
        currentPose = p
        currentPhase = phase
        apply(PoseLibrary.spec(p, phase: phase))
    }

    func apply(_ s: PoseSpec) {
        body.position = .zero
        pelvis.position = [0, Dim.hipY, s.forward]
        pelvis.orientation = simd_quatf(angle: s.pelvisPitch, axis: [1, 0, 0])
        spine.orientation = simd_quatf(angle: s.spineTwist, axis: [0, 1, 0])
            * simd_quatf(angle: s.spineLean, axis: [1, 0, 0])
        neck.orientation = simd_quatf(angle: -s.headPitch, axis: [1, 0, 0])
        for side in 0..<2 {
            let arm = side == 0 ? s.armL : s.armR
            let leg = side == 0 ? s.legL : s.legR
            let su = Self.aim(arm.upper)
            shoulder[side].orientation = su
            elbow[side].orientation = su.inverse * Self.aim(arm.lower)
            let hu = Self.aim(leg.upper)
            let kq = Self.aim(leg.lower)
            hip[side].orientation = hu
            knee[side].orientation = hu.inverse * kq
            // Feet stay level with the pelvis, toes tipped by `toePoint`.
            ankle[side].orientation = kq.inverse * simd_quatf(angle: s.toePoint, axis: [1, 0, 0])
        }
        // Ground the lowest point.
        let minY = probes.map { $0.position(relativeTo: entity).y }.min() ?? 0
        body.position.y = -minY
    }

    /// The rotation taking a hanging segment (pointing −y) to point along `d`.
    static func aim(_ d: SIMD3<Float>) -> simd_quatf {
        let n = simd_normalize(d)
        let down = SIMD3<Float>(0, -1, 0)
        if simd_dot(n, down) < -0.9999 { return simd_quatf(angle: .pi, axis: [1, 0, 0]) }
        return simd_quatf(from: down, to: n)
    }
}
