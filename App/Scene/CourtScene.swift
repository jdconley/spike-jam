import Foundation
import RealityKit
import simd
import SpikeArt
import SpikeCore
import UIKit

/// Draws a `GameState` with SpikeArt: the court and net for the match's game type, a cel-shaded
/// rig per athlete and the ball. It only reads state; `SceneMapping` holds the mapping rules.
///
/// Positions are interpolated between the client loop's previous and current states, so the
/// 60 Hz simulation draws smoothly at the display's rate.
@MainActor
final class CourtScene {
    /// The camera shots. Only the wide sideline view exists so far; Task 5 adds the moving camera.
    enum Shot {
        /// The whole court from high on the near sideline, home on the left.
        case wideSideline
    }

    let root = Entity()
    let court: CourtModel
    let camera = PerspectiveCamera()
    let style: ArtStyle
    private(set) var rigs: [AthleteID: PlayerRig] = [:]

    private let ball: ModelEntity
    private let ballShadow: ModelEntity
    private let ballTrail = Entity()
    private var builtRosters: [Roster] = []
    private var yaws: [AthleteID: Float] = [:]
    private var strides: [AthleteID: Float] = [:]
    /// A pass or set pose held a moment after the contact, so the touch reads.
    private var holds: [AthleteID: (choice: SceneMapping.PoseChoice, until: Double)] = [:]
    private var lastRenderTime: Double?
    private var lastBall: SIMD3<Float>?
    private var fireTick = -1
    private var onFire: Set<AthleteID> = []

    init(arView: ARView, style: ArtStyle = .placeholder) {
        self.style = style
        court = CourtModel(netHeight: CourtModel.menNetHeight, style: style)
        root.name = "CourtScene"
        root.addChild(court.entity)

        ball = ToonModel.make(.sphere(radii: SIMD3(repeating: SceneMapping.ballRadius), segments: 14, rings: 9),
                              color: [1, 0.93, 0.6], outlineWidth: 0.012, style: style, name: "ball")
        ball.isEnabled = false
        root.addChild(ball)
        ballTrail.name = "ballTrail"
        ballTrail.components.set(Self.trailEmitter())
        ball.addChild(ballTrail)
        ballShadow = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.2),
                                 materials: [UnlitMaterial(color: UIColor(white: 0, alpha: 0.4))])
        ballShadow.name = "ballShadow"
        ballShadow.isEnabled = false
        root.addChild(ballShadow)

        root.addChild(camera)
        setShot(.wideSideline)

        arView.environment.background = .color(Palette.color(style.background))
        arView.renderOptions.insert(.disableMotionBlur)
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(root)
        arView.scene.addAnchor(anchor)
    }

    func setShot(_ shot: Shot) {
        switch shot {
        case .wideSideline:
            camera.camera.fieldOfViewInDegrees = 36
            camera.look(at: [0, 0.2, 0.9], from: [0, 11.5, 15], relativeTo: nil)
        }
    }

    /// Draws the match `alpha` of the way from `prev` to `cur`.
    func update(prev: GameState, cur: GameState, alpha: Double) {
        if cur.rosters != builtRosters { buildRigs(cur) }
        let netHeight = SceneMapping.netHeight(cur.settings)
        if court.netHeight != netHeight { court.netHeight = netHeight }

        let t = SceneMapping.renderTime(prev: prev, cur: cur, alpha: alpha)
        let frameDt = Float(min(max(t - (lastRenderTime ?? t), 0), 0.1))
        lastRenderTime = t
        let a = Float(min(max(alpha, 0), 1))
        if cur.tick != fireTick {
            onFire = SceneMapping.onFire(in: cur)
            fireTick = cur.tick
        }
        let inRally = cur.phase == .rally

        for (id, rig) in rigs {
            guard let m = cur.motion[id] else {
                rig.entity.isEnabled = false
                continue
            }
            rig.entity.isEnabled = true
            let before = prev.motion[id] ?? m
            let pos = SceneMapping.lerp(before.pos, m.pos, a)
            let lift = SceneMapping.lerp(before.height(atTick: prev.tick), m.height(atTick: cur.tick), a)
            rig.entity.position = [pos.x, lift, pos.z]

            let target = SceneMapping.facingYaw(team: id.team, gait: m.gait, velocity: m.vel)
            let yaw = SceneMapping.lerpAngle(yaws[id] ?? target, target, min(1, frameDt * 12))
            yaws[id] = yaw
            rig.entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])

            var choice = SceneMapping.pose(
                gait: m.gait, velocity: m.vel, jump: m.jump, tick: cur.tick,
                contact: SceneMapping.contact(for: id, in: cur), inRally: inRally,
                nearNet: abs(m.pos.x) < 1.4, arriveByTick: m.arriveByTick)
            if choice.pose == .passPlatform || choice.pose == .setHands {
                holds[id] = (choice, t + 0.25)
            } else if let h = holds[id], t < h.until, !(m.jump?.isAirborne(atTick: cur.tick) ?? false) {
                choice = h.choice
            } else {
                holds[id] = nil
            }
            if choice.cycles {
                // The cycle advances with distance covered, so feet don't skate.
                let speed = SceneMapping.lerp(before.vel, m.vel, a).length
                let run = SceneMapping.strideLength(choice.pose) * rig.scale
                let phase = ((strides[id] ?? 0) + speed * frameDt / run).truncatingRemainder(dividingBy: 1)
                strides[id] = phase
                choice.phase = phase
            }
            if rig.currentPose != choice.pose || rig.currentPhase != choice.phase {
                rig.pose(choice.pose, phase: choice.phase)
            }
            if rig.isOnFire != onFire.contains(id) { rig.setOnFire(onFire.contains(id)) }
        }
        drawBall(cur, at: t)
    }

    private func drawBall(_ cur: GameState, at t: Double) {
        var p: SIMD3<Float>?
        var flying = false
        if case .preServe = cur.phase {
            // In the server's hand, waiting.
            let server = cur.lineups[cur.score.serving.rawValue].server()
            if let rig = rigs[server], rig.entity.isEnabled {
                let fwd = simd_quatf(angle: yaws[server] ?? 0, axis: [0, 1, 0]).act([0, 0, 1])
                p = rig.entity.position + fwd * 0.32 * rig.scale + [0, 1.05 * rig.scale, 0]
            }
        } else if let flight = cur.ball, let at = SceneMapping.ballPosition(flight, at: t) {
            p = at
            flying = t < flight.endTime
        } else if let last = lastBall {
            // Dead ball: it lies where it came down.
            p = [last.x, SceneMapping.ballRadius, last.z]
        }
        lastBall = p
        guard let p else {
            ball.isEnabled = false
            ballShadow.isEnabled = false
            return
        }
        ball.isEnabled = true
        ball.position = p
        ballShadow.isEnabled = true
        ballShadow.position = [p.x, 0.004, p.z]
        let s = max(0.3, 1 - p.y / 8)
        ballShadow.scale = [s, 1, s]
        // A flaming trail off an on-fire hitter's touch.
        let hot = flying && (cur.lastTouch.map(onFire.contains) ?? false)
        if ballTrail.components[ParticleEmitterComponent.self]?.isEmitting != hot {
            ballTrail.components[ParticleEmitterComponent.self]?.isEmitting = hot
        }
    }

    private func buildRigs(_ s: GameState) {
        for rig in rigs.values { rig.entity.removeFromParent() }
        rigs = [:]
        yaws = [:]
        strides = [:]
        holds = [:]
        lastBall = nil
        lastRenderTime = nil
        for roster in s.rosters {
            for a in roster.athletes {
                let rig = PlayerRig(look: SceneMapping.look(for: a, gameType: s.settings.gameType),
                                    heightM: a.heightM, style: style)
                rig.entity.isEnabled = false
                root.addChild(rig.entity)
                rigs[a.id] = rig
            }
        }
        builtRosters = s.rosters
    }

    private static func trailEmitter() -> ParticleEmitterComponent {
        var pe = ParticleEmitterComponent()
        pe.emitterShape = .point
        pe.mainEmitter.birthRate = 500
        pe.mainEmitter.lifeSpan = 0.35
        pe.mainEmitter.size = 0.2
        pe.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.05
        pe.mainEmitter.blendMode = .additive
        pe.mainEmitter.color = .evolving(start: .single(Palette.color([1, 0.9, 0.3])),
                                         end: .single(Palette.color([1, 0.1, 0])))
        pe.speed = 0.05
        pe.isEmitting = false
        return pe
    }
}
