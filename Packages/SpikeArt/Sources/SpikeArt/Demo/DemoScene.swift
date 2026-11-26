import Foundation
import RealityKit
import simd

/// Twelve players in varied looks and every pose, on the court: the kit at a glance.
@MainActor
public final class DemoScene {
    public struct Player: Sendable {
        public var look: PlayerLook
        public var heightM: Float
        public var pose: Pose
        public var phase: Float
        /// Floor position (x, z) and extra height (jumps).
        public var position: SIMD3<Float>
        /// Turn about y; home faces +x at +π/2.
        public var yaw: Float
        public var onFire: Bool
    }

    public let root = Entity()
    public let court: CourtModel
    public private(set) var rigs: [PlayerRig] = []
    public let players: [Player]
    public let camera = PerspectiveCamera()
    private var time: Float = 0
    public var animates = true

    /// The broadcast-ish three-quarter view: behind the home end, high on the near side.
    public static let cameraPosition: SIMD3<Float> = [-11.2, 5.0, 7.6]
    public static let cameraTarget: SIMD3<Float> = [0.4, 0.9, 0.2]

    public init(style: ArtStyle = .placeholder, players: [Player] = DemoScene.lineup) {
        self.players = players
        court = CourtModel(netHeight: CourtModel.menNetHeight, style: style)
        root.name = "SpikeArtDemo"
        root.addChild(court.entity)
        for p in players {
            let rig = PlayerRig(look: p.look, heightM: p.heightM, style: style)
            rig.pose(p.pose, phase: p.phase)
            rig.entity.position = p.position
            rig.entity.orientation = simd_quatf(angle: p.yaw, axis: [0, 1, 0])
            rig.setOnFire(p.onFire)
            root.addChild(rig.entity)
            rigs.append(rig)
        }
        camera.camera.fieldOfViewInDegrees = 40
        camera.look(at: Self.cameraTarget, from: Self.cameraPosition, relativeTo: nil)
        root.addChild(camera)
    }

    /// Advances the cycling poses (run, shuffle, celebrate) by `dt` seconds.
    public func step(_ dt: Float) {
        guard animates else { return }
        time += dt
        for (rig, p) in zip(rigs, players) where p.pose == .run || p.pose == .shuffle || p.pose == .celebrate {
            let rate: Float = p.pose == .run ? 1.4 : 1.0
            rig.pose(p.pose, phase: (p.phase + time * rate).truncatingRemainder(dividingBy: 1))
        }
    }

    /// Six a side: every pose, a libero each, skin tones across the range, heights 1.70–2.07 m.
    public static let lineup: [Player] = {
        let home: Float = .pi / 2, away: Float = -.pi / 2
        return [
            // Home (red), seen from behind: back numbers.
            Player(look: .init(skinTone: 1, number: 7, team: .home, hair: .crop, hairColor: 3, gear: [.kneePads], shoeColor: 0),
                   heightM: 1.98, pose: .spikeSwing, phase: 0.15, position: [-1.6, 0.85, -3.1], yaw: home + 0.2, onFire: true),
            Player(look: .init(skinTone: 8, number: 17, team: .home, hair: .buzz, gear: [.headband], shoeColor: 1, build: .broad),
                   heightM: 2.05, pose: .block, phase: 0.6, position: [-0.55, 0.45, -0.6], yaw: home, onFire: false),
            Player(look: .init(skinTone: 4, number: 3, team: .home, hair: .ponytail, hairColor: 1, gear: [.armSleeves, .darkGear], shoeColor: 2, build: .lean),
                   heightM: 1.84, pose: .setHands, phase: 0.5, position: [-2.6, 0, 3.0], yaw: home - 0.3, onFire: false),
            Player(look: .init(skinTone: 6, number: 12, team: .home, isLibero: true, hair: .bun, hairColor: 0, gear: [.kneePads, .darkGear], shoeColor: 3, build: .lean),
                   heightM: 1.72, pose: .passPlatform, phase: 0.4, position: [-6.6, 0, 0.6], yaw: home + 0.15, onFire: false),
            Player(look: .init(skinTone: 9, number: 21, team: .home, hair: .locs, gear: [.kneePads], shoeColor: 4),
                   heightM: 1.93, pose: .dive, phase: 1, position: [-5.4, 0, 3.2], yaw: home - 0.6, onFire: false),
            Player(look: .init(skinTone: 2, number: 9, team: .home, hair: .afro, hairColor: 4, gear: [.headband, .darkGear], shoeColor: 0, build: .average),
                   heightM: 1.88, pose: .shuffle, phase: 0.2, position: [-6.0, 0, -2.0], yaw: home + 0.3, onFire: false),
            // Away (teal), facing the camera: front numbers.
            Player(look: .init(skinTone: 0, number: 14, team: .away, hair: .buzz, hairColor: 2, gear: [], shoeColor: 1, build: .broad),
                   heightM: 2.07, pose: .block, phase: 0.8, position: [0.55, 0.4, -2.2], yaw: away, onFire: false),
            Player(look: .init(skinTone: 7, number: 5, team: .away, hair: .afro, hairColor: 0, gear: [.kneePads], shoeColor: 2),
                   heightM: 1.96, pose: .jump, phase: 0.8, position: [0.6, 0.5, 1.5], yaw: away, onFire: false),
            Player(look: .init(skinTone: 3, number: 1, team: .away, isLibero: true, hair: .ponytail, hairColor: 3, gear: [.kneePads], shoeColor: 0, build: .lean),
                   heightM: 1.70, pose: .stand, phase: 0, position: [7.6, 0, 2.6], yaw: away - 0.2, onFire: false),
            Player(look: .init(skinTone: 5, number: 10, team: .away, hair: .crop, hairColor: 1, gear: [.headband, .armSleeves], shoeColor: 3),
                   heightM: 1.86, pose: .approach, phase: 0.3, position: [2.8, 0, 3.9], yaw: away + 0.4, onFire: false),
            Player(look: .init(skinTone: 8, number: 22, team: .away, hair: .bun, hairColor: 0, gear: [.darkGear, .kneePads], shoeColor: 4, build: .average),
                   heightM: 1.81, pose: .run, phase: 0.1, position: [7.8, 0, -3.8], yaw: away - 0.5, onFire: false),
            Player(look: .init(skinTone: 1, number: 8, team: .away, hair: .locs, hairColor: 5, gear: [.headband], shoeColor: 1),
                   heightM: 1.9, pose: .celebrate, phase: 0.3, position: [4.0, 0, 0.8], yaw: away + 0.35, onFire: false),
        ]
    }()
}
