import Foundation
import simd
import SpikeArt
import SpikeCore

/// The pure part of drawing: how SpikeCore's state maps onto SpikeArt's rigs, poses and court.
/// Everything here is a plain function of state, so it is tested without a renderer.
///
/// It reads as little of `GameState` as it can, and never switches exhaustively over a SpikeCore
/// enum without a `default`: SpikeCore keeps growing underneath the app.
enum SceneMapping {
    // MARK: Size, team and facing

    /// A rig's uniform scale: SpikeArt builds the figure at 1.9 m.
    static func rigScale(heightM: Float) -> Float { PlayerRig.scale(forHeight: heightM) }

    static func artTeam(_ side: TeamSide) -> ArtTeam { side == .home ? .home : .away }

    /// The turn about y that faces a rig (built facing +z) along `direction` on the floor.
    static func yaw(facing direction: Vec2) -> Float { atan2f(direction.x, direction.z) }

    /// Facing the net: home looks along +x (+π/2), away along −x (−π/2).
    static func netYaw(_ side: TeamSide) -> Float { yaw(facing: Vec2(x: side.dir, z: 0)) }

    /// Where a player looks: along their run when running, approaching or diving fast enough,
    /// else at the net (ready position, shuffles and backpedals face the play).
    static func facingYaw(team: TeamSide, gait: Gait, velocity: Vec2) -> Float {
        let speed = velocity.length
        switch gait {
        case .run, .approach, .dive:
            return speed > 0.6 ? yaw(facing: velocity) : netYaw(team)
        default:
            return netYaw(team)
        }
    }

    /// The net height for the match's game type.
    static func netHeight(_ settings: MatchSettings) -> Float { settings.gameType.netHeight }

    // MARK: Poses

    /// What a player is about to do with the ball, if anything: the pending contact's kind when
    /// it is theirs, else nil. `rawValue` so plan 3's `block` (and anything later) needs no case.
    struct Contact: Equatable {
        var kind: String
        /// Seconds until the contact (negative once it's past).
        var secondsToGo: Double
    }

    /// The contact the pending touch gives `id`, if any.
    static func contact(for id: AthleteID, in s: GameState) -> Contact? {
        guard let p = s.pending, p.athlete == id, let kind = p.kind else { return nil }
        return Contact(kind: kind.rawValue, secondsToGo: Double(p.tick - s.tick) * Tuning.dt)
    }

    /// How close to a contact the touch pose starts.
    static let contactLead: Double = 0.45

    /// A pose and its phase. `cycles` poses (run, shuffle) take their phase from the scene's
    /// stride clock instead of `phase`.
    struct PoseChoice: Equatable {
        var pose: Pose
        var phase: Float
        var cycles: Bool { pose == .run || pose == .shuffle }
    }

    /// Maps a player's motion to a SpikeArt pose.
    /// - `tick`: the state's tick; `inRally`: the ball is live (players wait in a ready stance).
    /// - `nearNet`: within reach of the net, so a jump without an attack is a block.
    /// - `arriveByTick`: when an approach reaches its takeoff, for the arm swing's progress.
    static func pose(gait: Gait, velocity: Vec2, jump: Jump?, tick: Int, contact: Contact?,
                     inRally: Bool, nearNet: Bool, arriveByTick: Int? = nil) -> PoseChoice {
        if let j = jump, j.isAirborne(atTick: tick), j.durationTicks > 0 {
            let u = Float(tick - j.startTick) / Float(j.durationTicks)
            if contact?.kind == TouchKind.attack.rawValue {
                // Cocked on the way up, contact at the peak, follow-through on the way down.
                return PoseChoice(pose: .spikeSwing, phase: u)
            }
            if contact?.kind == "block" || nearNet {
                return PoseChoice(pose: .block, phase: min(1, 2 * u))
            }
            return PoseChoice(pose: .jump, phase: min(1, 2 * u))
        }
        if let c = contact, c.secondsToGo <= contactLead {
            let p = Float(1 - max(c.secondsToGo, 0) / contactLead)
            switch c.kind {
            case TouchKind.receive.rawValue, TouchKind.dig.rawValue:
                return PoseChoice(pose: .passPlatform, phase: p)
            case TouchKind.set.rawValue:
                return PoseChoice(pose: .setHands, phase: p)
            default:
                break
            }
        }
        let speed = velocity.length
        let moving = speed > 0.3
        switch gait {
        case .run:
            return moving ? PoseChoice(pose: .run, phase: 0) : ready(inRally)
        case .shuffle, .backpedal:
            return moving ? PoseChoice(pose: .shuffle, phase: 0) : ready(inRally)
        case .approach:
            // Arms swing from back to forward over the last approachTime before takeoff.
            guard let by = arriveByTick else { return PoseChoice(pose: .approach, phase: moving ? min(1, speed / 5) : 0) }
            let left = Double(by - tick) * Tuning.dt / Tuning.approachTime
            return PoseChoice(pose: .approach, phase: Float(1 - min(max(left, 0), 1)))
        case .dive:
            // Lunging while still sliding, laid out once stopped.
            return PoseChoice(pose: .dive, phase: 1 - min(1, speed / 6))
        default:
            // Standing, and any gait SpikeCore adds later.
            return ready(inRally)
        }
    }

    /// Standing still: the athletic ready stance during a rally (a still shuffle), else upright.
    static func ready(_ inRally: Bool) -> PoseChoice {
        inRally ? PoseChoice(pose: .shuffle, phase: 0) : PoseChoice(pose: .stand, phase: 0)
    }

    /// Meters of travel per run or shuffle cycle at the reference height.
    static func strideLength(_ pose: Pose) -> Float { pose == .run ? 2.4 : 1.1 }

    // MARK: Looks

    /// A deterministic look for an athlete. Skin tone, number and the libero's jersey come from
    /// SpikeCore; hair, gear, shoes and build vary by roster slot so no two teammates match.
    static func look(for a: Athlete, gameType: GameType) -> PlayerLook {
        let i = a.id.index
        let t = a.id.team.rawValue
        let styles: [PlayerLook.HairStyle] = gameType == .womens
            ? [.ponytail, .bun, .locs, .crop, .afro, .ponytail, .bun]
            : [.crop, .buzz, .afro, .locs, .crop, .buzz, .afro]
        let gears: [PlayerLook.Gear] = [[.kneePads], [.headband], [.kneePads, .armSleeves], [], [.kneePads, .darkGear],
                                        [.headband, .darkGear], [.kneePads]]
        let build: PlayerLook.Build = switch a.position {
        case .middle, .opposite: .broad
        case .libero, .setter: .lean
        default: .average
        }
        return PlayerLook(
            skinTone: min(max(a.skinTone, 0), Palette.skin.count - 1),
            number: a.number,
            team: artTeam(a.id.team),
            isLibero: a.position == .libero,
            hair: styles[(i + 3 * t) % styles.count],
            hairColor: (i * 2 + t) % Palette.hair.count,
            gear: gears[(i + t) % gears.count],
            shoeColor: (i + 2 * t) % Palette.shoes.count,
            build: build
        )
    }

    // MARK: Interpolation

    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    static func lerp(_ a: Vec2, _ b: Vec2, _ t: Float) -> Vec2 {
        Vec2(x: lerp(a.x, b.x, t), z: lerp(a.z, b.z, t))
    }

    /// The shortest-way blend between two turns.
    static func lerpAngle(_ a: Float, _ b: Float, _ t: Float) -> Float {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
        return a + d * t
    }

    /// The match time drawn this frame: `alpha` of the way from `prev` to `cur`.
    static func renderTime(prev: GameState, cur: GameState, alpha: Double) -> Double {
        prev.time + (cur.time - prev.time) * min(max(alpha, 0), 1)
    }

    /// Where the ball is drawn at `time`: on its flight, held at the landing once the flight is
    /// over; nil when there is no ball in play.
    static func ballPosition(_ flight: Flight?, at time: Double) -> SIMD3<Float>? {
        guard let f = flight else { return nil }
        let p = f.position(at: min(max(time, f.startTime), f.endTime))
        return [p.x, max(p.y, ballRadius), p.z]
    }

    /// Drawn a little over the real 0.105 m so it reads at phone size.
    static let ballRadius: Float = 0.14

    // MARK: On fire

    /// Who is on fire, if this `GameState` knows about fire at all. Plan 4 adds
    /// `fire: [AthleteID: FireState]` with an `onFire` flag; until then there is no such field and
    /// this is empty. Read by reflection so the app builds against SpikeCore before and after.
    static func onFire(in s: GameState) -> Set<AthleteID> {
        guard let field = Mirror(reflecting: s).descendant("fire") else { return [] }
        guard let table = field as? [AthleteID: Any] else { return [] }
        var lit: Set<AthleteID> = []
        for (id, value) in table {
            if let on = value as? Bool {
                if on { lit.insert(id) }
            } else if let on = Mirror(reflecting: value).descendant("onFire") as? Bool {
                if on { lit.insert(id) }
            }
        }
        return lit
    }
}
