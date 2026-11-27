import Foundation
import simd
import SpikeCore

/// Where the camera is, what it looks at, and how wide it sees.
struct CameraShot: Equatable, Sendable {
    var position: SIMD3<Float>
    var target: SIMD3<Float>
    /// The vertical field of view, in degrees.
    var fov: Float

    /// The camera's right, up and forward axes, with world up as up (as `Entity.look(at:from:)`).
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        return (right, simd_cross(right, forward), forward)
    }

    /// Where `p` lands on screen in normalized device coordinates, −1...1 across and up the view,
    /// for a viewport `aspect` (width / height). Nil when `p` is behind the camera.
    func project(_ p: SIMD3<Float>, aspect: Float) -> SIMD2<Float>? {
        let b = basis
        let d = p - position
        let z = simd_dot(d, b.forward)
        guard z > 1e-3 else { return nil }
        let t = tanf(fov * .pi / 360)
        return [simd_dot(d, b.right) / (z * t * aspect), simd_dot(d, b.up) / (z * t)]
    }

    /// `self` blended `t` of the way to `o`.
    func mixed(_ o: CameraShot, _ t: Float) -> CameraShot {
        CameraShot(position: simd_mix(position, o.position, SIMD3(repeating: t)),
                   target: simd_mix(target, o.target, SIMD3(repeating: t)),
                   fov: fov + (o.fov - fov) * t)
    }

    /// This shot with its field of view widened, if needed, so every point in `points` lands
    /// within `edge` of the view's sides, below `top` and above `-bottom` (the bottom keeps room
    /// for the switch strip). Capped at `maxFov`.
    func fitting(_ points: [SIMD3<Float>], aspect: Float, edge: Float = 0.92, top: Float? = nil, bottom: Float = 0.78,
                 maxFov: Float = 75) -> CameraShot {
        let top = top ?? edge
        let b = basis
        var need = tanf(fov * .pi / 360)
        for p in points {
            let d = p - position
            let z = simd_dot(d, b.forward)
            guard z > 1e-3 else { continue }
            let x = simd_dot(d, b.right), y = simd_dot(d, b.up)
            need = max(need, abs(x) / (z * aspect * edge), y >= 0 ? y / (z * top) : -y / (z * bottom))
        }
        var out = self
        out.fov = max(fov, min(2 * atanf(need) * 180 / .pi, maxFov))
        return out
    }
}

/// Picks and moves the camera (spec §4.4): behind the server for the serve, swooping on attacks,
/// a wide sideline shot otherwise, and a punch-in on the last moments of a kill or a stuff.
/// During the local player's aimed touches (`LocalOwnership.aimWindow`) the other team's court
/// stays in view, because that's where you aim.
///
/// `shot(for:events:)` is the shot a state calls for; `frame(for:events:dt:)` eases the camera
/// toward it, cuts to the serve, and shakes it on kills. The slow motion itself is the
/// presentation clock's (`Presentation`): this only ever sees the state being drawn.
@MainActor
final class CameraDirector {
    enum Kind: Equatable, Sendable {
        case wide, serve, swoop, killFinish
    }

    /// The whole court from high on the near sideline, home on the left.
    static let wideSideline = CameraShot(position: [0, 11.5, 15], target: [0, 0.2, 0.9], fov: 36)

    var ownership: any LocalOwnership
    /// The viewport's width over height. Landscape phones run from 1.78 (SE) to 2.17 (17 Pro).
    var aspect: Float = 2.17
    /// Where the HUD leaves the court clear during the local player's aimed touches, as the
    /// highest and lowest NDC y their court may reach (Review Focus 5). `HUDLayout` sets them for
    /// the view's size.
    var aimBands = AimBands()

    struct AimBands: Equatable, Sendable {
        var top: Float = 0.92
        var bottom: Float = 0.78
    }
    /// The shot drawn last frame.
    private(set) var current: CameraShot = CameraDirector.wideSideline
    private(set) var kind: Kind = .wide
    /// The kill or stuff close-up, held through the dead ball after it.
    private var finish: CameraShot?
    private var shakeLeft: Double = 0
    private var clock: Double = 0

    /// How long and how hard the camera shakes on a kill or a stuff.
    static let shakeDuration = 0.35
    static let shakeAmplitude: Float = 0.1

    init(ownership: any LocalOwnership = HumanOwnership.nobody) {
        self.ownership = ownership
    }

    // MARK: The shot a state calls for

    /// The shot for `s`. `events` are the ones that just happened.
    func shot(for s: GameState, events: [GameEvent]) -> CameraShot {
        pick(s, events).shot
    }

    /// The kind of shot `s` calls for, and the shot.
    func pick(_ s: GameState, _ events: [GameEvent]) -> (kind: Kind, shot: CameraShot) {
        switch s.phase {
        case .preServe:
            finish = nil
            return (.serve, serveShot(s))
        case .rally:
            if let p = s.pending, p.kind == nil, let reason = p.reason, reason == .kill || reason == .block,
               let landing = landingSpot(s) {
                // The attacker is the winner for a kill, the stuffed hitter's team for a block.
                let attacking = reason == .kill ? p.team : p.team.other
                let shot = finishShot(attacking: attacking, landing: landing)
                finish = shot
                return (.killFinish, shot)
            }
            finish = nil
            if let p = s.pending, p.kind == .serve {
                // A human's serve clock: the line-ups are set and the server waits for the toss.
                return (.serve, serveShot(s))
            }
            if let p = s.pending, p.kind == .attack {
                return (.swoop, swoopShot(attacking: p.team, contact: landingSpot(s) ?? contactGuess(p, s),
                                          aiming: ownership.aimWindow(in: s) == .attack))
            }
            if let hitter = s.lastTouch, isAttackInFlight(s), let from = s.ball?.p0 {
                // The block and the dig, still from behind the hitter.
                return (.swoop, swoopShot(attacking: hitter.team, contact: [from.x, from.y, from.z]))
            }
            if isServeApproaching(s) {
                return (.serve, serveShot(s))
            }
            return (.wide, Self.wideSideline)
        case .deadBall:
            if let finish { return (.killFinish, finish) }
            return (.wide, Self.wideSideline)
        default:
            finish = nil
            return (.wide, Self.wideSideline)
        }
    }

    /// Behind the server and a little above, over their shoulder, at the other court.
    func serveShot(_ s: GameState) -> CameraShot {
        let side = s.score.serving
        let server = s.lineups[side.rawValue].server()
        let p = s.motion[server]?.pos ?? LocalFrame.toWorld(Formations.serverSpot, team: side)
        let dir = side.dir
        // High enough that their court opens up over the net, where you aim.
        let shot = CameraShot(position: [p.x - dir * 4.2, 6.4, p.z * 0.55],
                              target: [dir * 3.2, 0, p.z * 0.1], fov: 40)
        return fit(shot, Self.courtCorners(side.other), aiming: ownership.aimWindow(in: s) == .serve)
    }

    /// Low behind the hitter on their side, toward the near sideline, looking over the net at the
    /// court they hit into, with the contact point in view.
    func swoopShot(attacking side: TeamSide, contact: SIMD3<Float>, aiming: Bool = false) -> CameraShot {
        let dir = side.dir
        let shot = CameraShot(position: [contact.x - dir * 7.0, 4.6, contact.z * 0.45 + 3.2],
                              target: [dir * 3.8, 0.8, contact.z * 0.25], fov: 44)
        return fit(shot, Self.courtCorners(side.other) + [contact], aiming: aiming)
    }

    /// `shot` widened to show `points`; while the local player aims, clear of the HUD's bands.
    private func fit(_ shot: CameraShot, _ points: [SIMD3<Float>], aiming: Bool) -> CameraShot {
        guard aiming else { return shot.fitting(points, aspect: aspect) }
        return shot.fitting(points, aspect: aspect, top: min(aimBands.top, 0.92), bottom: min(aimBands.bottom, 0.78))
    }

    /// The punch-in on where a kill or a stuff comes down, from the hitter's side.
    func finishShot(attacking side: TeamSide, landing: SIMD3<Float>) -> CameraShot {
        let dir = side.dir
        return CameraShot(position: [-dir * 6.5, 3.6, landing.z * 0.4 + 3.6],
                          target: [landing.x, 0.4, landing.z], fov: 30)
    }

    /// The four corners of `side`'s court, on the floor.
    static func courtCorners(_ side: TeamSide) -> [SIMD3<Float>] {
        let far = side.dir * -Court.halfLength
        return [[0, 0, -Court.halfWidth], [0, 0, Court.halfWidth], [far, 0, -Court.halfWidth], [far, 0, Court.halfWidth]]
    }

    /// Where the ball in the air comes down (or reaches its contact).
    private func landingSpot(_ s: GameState) -> SIMD3<Float>? {
        guard let f = s.ball else { return nil }
        let p = f.position(at: f.endTime)
        return [p.x, p.y, p.z]
    }

    /// The hitter's spot at the net, when there's no set in the air to read the contact from.
    private func contactGuess(_ p: PendingContact, _ s: GameState) -> SIMD3<Float> {
        let at = p.athlete.flatMap { s.motion[$0]?.pos } ?? Vec2(x: -p.team.dir, z: 0)
        return [at.x, 3, at.z]
    }

    /// The ball in the air is an attack, on its way to the block or the dig.
    private func isAttackInFlight(_ s: GameState) -> Bool {
        guard let p = s.pending, p.kind == .block || p.kind == .dig, s.touchesThisSide == 0,
              let hitter = s.lastTouch, p.team == hitter.team.other else { return false }
        return !isServeFlight(s)
    }

    /// The serve is in the air and hasn't crossed the net yet.
    private func isServeApproaching(_ s: GameState) -> Bool {
        guard isServeFlight(s), let f = s.ball else { return false }
        return f.position(at: s.time).x * s.score.serving.dir < 0
    }

    private func isServeFlight(_ s: GameState) -> Bool {
        guard let f = s.ball, s.serveTick >= 0 else { return false }
        return abs(f.startTime - Double(s.serveTick) * Tuning.dt) < Tuning.dt / 2
    }

    // MARK: Moving the camera

    /// The camera for this frame: eased toward `shot(for:events:)` by `dt` seconds of
    /// presentation time (so slow motion slows it too), cut straight to the serve, and shaken on
    /// a kill or a stuff.
    func frame(for s: GameState, events: [GameEvent], dt: Double) -> CameraShot {
        clock += dt
        for e in events {
            if case .point(_, let reason) = e, reason == .kill || reason == .block {
                shakeLeft = Self.shakeDuration
            }
        }
        let (next, want) = pick(s, events)
        if next == .serve && kind != .serve {
            current = want
        } else {
            let rate: Double = switch next {
            case .swoop: 4.5
            case .killFinish: 5
            case .serve: 4
            case .wide: 2.4
            }
            current = current.mixed(want, Float(1 - exp(-rate * max(dt, 0))))
        }
        kind = next
        guard shakeLeft > 0 else { return current }
        shakeLeft = max(0, shakeLeft - dt)
        let k = Self.shakeAmplitude * Float(shakeLeft / Self.shakeDuration)
        let jolt = SIMD3<Float>(sinf(Float(clock) * 53), sinf(Float(clock) * 71 + 1), sinf(Float(clock) * 37 + 2)) * k
        var shaken = current
        shaken.position += jolt
        shaken.target += jolt * 0.5
        return shaken
    }

    /// Jumps straight to the shot for `s`, as at the start of a match.
    func reset(to s: GameState) {
        finish = nil
        shakeLeft = 0
        let (k, shot) = pick(s, [])
        kind = k
        current = shot
    }
}
