/// Everything the touch model needs to roll one touch.
public struct TouchContext: Sendable {
    public var kind: TouchKind
    public var toucher: Athlete
    /// How playable the ball coming in is, 0...1 (1 is an easy, perfect
    /// ball): the pass for a set, the set for an attack, and one minus the
    /// serve's or attack's toughness for a pass, dig or block.
    public var incomingQuality: Float
    /// How hard the ball comes in, 0...1: a jump serve or a spike near 1, a
    /// tip or a free ball near 0.
    public var incomingPower: Float
    /// Seconds the toucher had to spare getting to the ball; negative when
    /// they only just made it.
    public var reachSlack: Double
    /// Blockers lined up against an attack.
    public var blockersAligned: Int
    /// The catch-up level for this touch, −1...1 (positive plays better).
    /// Ignored for a human.
    public var catchUp: Float
    /// A human's timing grade for the touch, 0...1; nil for the AI.
    public var timing: Float?
    /// The toucher is on fire (spec §4.4).
    public var onFire: Bool

    public init(kind: TouchKind, toucher: Athlete, incomingQuality: Float, incomingPower: Float, reachSlack: Double,
                blockersAligned: Int, catchUp: Float, timing: Float? = nil, onFire: Bool = false) {
        self.kind = kind
        self.toucher = toucher
        self.incomingQuality = incomingQuality
        self.incomingPower = incomingPower
        self.reachSlack = reachSlack
        self.blockersAligned = blockersAligned
        self.catchUp = catchUp
        self.timing = timing
        self.onFire = onFire
    }

    public var isHuman: Bool { timing != nil }
}

/// Every way a touch goes wrong, so each can have its own animation.
public enum TouchError: String, Codable, Sendable {
    /// A serve or attack into the net.
    case net
    /// A serve or attack long or wide.
    case out
    /// A pass or dig off the court.
    case shank
    /// A pass or dig over the net.
    case overpass
    /// A set lifted or double-touched.
    case doubleContact
    /// The attack was stuffed by the block (the hitter's error).
    case blockedStuff
    /// The attack went off the block and out (the blocker's error).
    case tooled
}

/// How a touch came out.
public struct TouchResult: Equatable, Sendable {
    /// 0...1: how good the touch is (a serve's toughness, a pass's or set's
    /// accuracy, an attack's power and placement, a block's solidity). 0
    /// with an error.
    public var quality: Float
    public var error: TouchError?
    /// How hard the ball leaves, 0...1 (serves and attacks).
    public var power: Float
    /// Where a serve is aimed, in world coordinates on the floor; nil for
    /// other touches (the rally aims attacks from where the defense stands).
    public var target: Vec3?
    /// An attack played as a tip or roll shot.
    public var tip: Bool

    public init(quality: Float, error: TouchError?, power: Float, target: Vec3?, tip: Bool) {
        self.quality = quality
        self.error = error
        self.power = power
        self.target = target
        self.tip = tip
    }
}

/// Rolls every touch (spec §4.9). Quality is drawn around the toucher's
/// trait, shifted by the difficulty and the catch-up, spread by about 0.15
/// and clipped to 0...1. The chance of an error comes from the trait and the
/// difficulty, and rises with a harder or worse ball, less time to get there
/// and more blockers. A human's touch is drawn around the athlete's trait
/// moved by their timing (`Tuning.timingWeight` per point above or below
/// `Tuning.timingPar`), and neither the difficulty nor the catch-up ever
/// touches it.
public enum TouchModel {
    public static func resolve(_ c: TouchContext, rng: inout SeededRNG, settings: MatchSettings) -> TouchResult {
        let game = settings.gameType
        let skill: Float, errorScale: Float
        if let timing = c.timing {
            // The athlete's trait still matters (a human passing as the
            // libero passes better than as a middle); timing above par plays
            // above it, below par below it.
            skill = trait(c.toucher.traits, c.kind) + Tuning.timingWeight * (timing - Tuning.timingPar)
            errorScale = 1
        } else {
            let level = settings.difficulty(for: c.toucher.id.team)
            skill = trait(c.toucher.traits, c.kind) + level.traitShift + Tuning.catchUpQuality * c.catchUp
            errorScale = level.errorScale * (1 - Tuning.catchUpError * c.catchUp)
        }
        let k = Tuning.touchCoefficients(c.kind)
        let late = Float(max(0, Tuning.comfortableSlack - c.reachSlack) / Tuning.comfortableSlack)
        let bad = 1 - min(max(c.incomingQuality, 0), 1)

        var pError = Tuning.baseError(c.kind, game) * skillFactor(skill) * errorScale
        pError *= 1 + k.powerError * c.incomingPower
        pError *= 1 + k.badBallError * bad
        pError *= 1 + Tuning.lateError * min(late, 1.5)
        pError *= 1 + Tuning.blockerError * Float(c.blockersAligned)
        pError = min(pError, Tuning.maxError)

        let erred = rng.unit() < pError
        let noise = (rng.unit() + rng.unit() + rng.unit() - 1.5) * 2 * Tuning.qualitySpread
        var q = skill - k.badBallQuality * bad - k.powerQuality * c.incomingPower
        q -= Tuning.lateQuality * min(late, 1.5) + Tuning.blockerQuality * Float(c.blockersAligned)
        q = min(max(q + noise, 0), 1)

        var power: Float = 0
        var target: Vec3?
        var tip = false
        switch c.kind {
        case .serve:
            power = min(max(Tuning.servePower(game) + 0.3 * (q - 0.5), 0), 1)
            target = serveTarget(quality: q, receiving: c.toucher.id.team.other, rng: &rng)
        case .attack:
            let pTip = Tuning.tipChance(game) + Tuning.tipPerBlocker * Float(c.blockersAligned) + Tuning.tipOffBadSet * bad
            tip = rng.unit() < pTip
            power = tip ? Tuning.tipPower : attackPower(quality: q, game: game, onFire: c.onFire)
        case .receive, .dig:
            // An on-fire libero passes perfectly.
            if c.onFire && c.toucher.position == .libero { q = max(q, Tuning.fireLiberoPass) }
        default:
            break
        }
        guard erred else { return TouchResult(quality: q, error: nil, power: power, target: target, tip: tip) }
        return TouchResult(quality: 0, error: errorType(c.kind, rng: &rng), power: power, target: nil, tip: tip)
    }

    /// A swing's power off a hit of quality `q`; an on-fire hitter's is
    /// harder.
    static func attackPower(quality q: Float, game: GameType, onFire: Bool) -> Float {
        min(max(Tuning.attackPower(game) * (0.75 + 0.25 * q) + (onFire ? Tuning.firePower : 0), 0), 1)
    }

    /// The trait each touch is rolled around.
    static func trait(_ t: Traits, _ kind: TouchKind) -> Float {
        switch kind {
        case .serve: t.serve
        case .receive: t.pass
        case .dig: t.defense
        case .set: t.set
        case .attack: t.attack
        case .block: t.block
        }
    }

    /// Multiplies the base error chance: 1 at a 0.6 trait, 0.4 at 0.9, and
    /// never below 0.45, so even the best still err.
    static func skillFactor(_ skill: Float) -> Float {
        min(max(2.2 - 2 * skill, 0.45), 2)
    }

    static func errorType(_ kind: TouchKind, rng: inout SeededRNG) -> TouchError {
        switch kind {
        case .serve: rng.unit() < Tuning.serveNetShare ? .net : .out
        case .receive, .dig: rng.unit() < Tuning.overpassShare ? .overpass : .shank
        case .set: .doubleContact
        case .attack: rng.unit() < Tuning.attackNetShare ? .net : .out
        case .block: .tooled
        }
    }

    /// Where a serve of toughness `q` is aimed on the receiving court: a
    /// tough serve goes for the seams between passers, the deep corners or
    /// short; an easy one anywhere in the middle of the court. The aim
    /// wanders more on a weaker serve.
    static func serveTarget(quality q: Float, receiving: TeamSide, rng: inout SeededRNG) -> Vec3 {
        let spots: [LocalSpot] = [
            LocalSpot(d: 6.8, l: -1.6), LocalSpot(d: 6.8, l: 1.6),    // seams between the passers
            LocalSpot(d: 8.4, l: -3.9), LocalSpot(d: 8.4, l: 3.9),    // deep corners
            LocalSpot(d: 2.4, l: -2.5), LocalSpot(d: 2.4, l: 2.5),    // short
            LocalSpot(d: 8.5, l: 0),
        ]
        var aim: LocalSpot
        if rng.unit() < q {
            aim = spots[rng.int(in: 0..<spots.count)]
        } else {
            aim = LocalSpot(d: rng.float(in: 4...7.5), l: rng.float(in: -3...3))
        }
        let wander = Tuning.serveAimNoise * (1.2 - q)
        aim.d = min(max(aim.d + wander * rng.float(in: -1...1), 1.5), 8.6)
        aim.l = min(max(aim.l + wander * rng.float(in: -1...1), -4.2), 4.2)
        return LocalFrame.toWorld(aim, team: receiving).atHeight(0)
    }
}
