/// What a human's inputs for one contact add up to (spec §4.2).
public struct HumanPlay: Equatable, Sendable {
    public var grade: Grade
    /// The timing the touch plays with (`TouchContext.timing`).
    public var timing: Float
    /// Where a serve or attack is aimed: a world point on the other court's
    /// floor.
    public var aim: Vec2?
    /// The hitter a set goes to; nil leaves the choice to the AI setter.
    public var hitter: AthleteID?
    /// A quick tap of a serve: a safe float, never an error.
    public var float: Bool

    public init(grade: Grade, timing: Float? = nil, aim: Vec2? = nil, hitter: AthleteID? = nil, float: Bool = false) {
        self.grade = grade
        self.timing = timing ?? grade.quality
        self.aim = aim
        self.hitter = hitter
        self.float = float
    }
}

/// A human's touch (spec §4.2): their inputs graded by `TimingJudge`, then
/// rolled by the touch model with that timing (`TouchContext.timing`), so the
/// athlete's traits still count but the difficulty and the catch-up never do.
/// Each kind reads its own gesture:
/// - serve: the press starts the toss; the release is judged against the
///   toss's apex and aims the serve. A release within `floatTap` of the
///   press (or a tap) is a safe float.
/// - pass and dig: the tap.
/// - set: the `setTo` hitter (or a tap, for the AI's choice) and its timing.
/// - attack: the release's timing and aim; an aim within `tipZone` of the
///   net is a tip.
/// - block: the jump starts at the input and its peak is judged against
///   the attack (`Rally` does this as the input arrives).
/// A miss (no input in time) always errs.
public enum HumanTouch {
    /// The input that strikes the ball for contact `c`, if there is one yet.
    /// `inputs` are the owner's inputs for `c`.
    public static func striking(_ c: PendingContact, inputs: [PlayerInput]) -> PlayerInput? {
        switch c.kind {
        case .serve?:
            if let tap = inputs.first(where: { if case .tap = $0.action { true } else { false } }) { return tap }
            guard let press = press(inputs) else { return nil }
            return inputs.first { if case .release = $0.action { $0.time >= press.time } else { false } }
        case .receive?, .dig?:
            return inputs.first {
                switch $0.action {
                case .tap, .press: true
                default: false
                }
            }
        case .set?:
            return inputs.first {
                switch $0.action {
                case .setTo, .tap: true
                default: false
                }
            }
        case .attack?:
            return inputs.first {
                switch $0.action {
                case .release, .tap: true
                default: false
                }
            }
        case .block?, nil:
            return nil
        }
    }

    /// The serve toss's first press.
    static func press(_ inputs: [PlayerInput]) -> PlayerInput? {
        inputs.first { if case .press = $0.action { true } else { false } }
    }

    /// When the serve toss peaks for a press at `pressTime`.
    public static func apexTime(pressTime: Double) -> Double {
        pressTime + Tuning.tossSeconds
    }

    /// The moment contact `c` is judged against: the toss's apex for a
    /// tossed serve, else the contact tick.
    public static func contactTime(_ c: PendingContact, inputs: [PlayerInput]) -> Double {
        if c.kind == .serve, let p = press(inputs) { return apexTime(pressTime: p.time) }
        return Double(c.tick) * Tuning.dt
    }

    /// The play `inputs` make of contact `c`: a miss without a striking input.
    public static func play(for c: PendingContact, inputs: [PlayerInput]) -> HumanPlay {
        guard let hit = striking(c, inputs: inputs) else { return HumanPlay(grade: .miss) }
        if c.kind == .serve {
            let quick: Bool
            if case .tap = hit.action { quick = true } else { quick = hit.time - (press(inputs)?.time ?? hit.time) < Tuning.floatTap }
            if quick {
                var aim: Vec2?
                if case .release(_, let a) = hit.action { aim = a }
                return HumanPlay(grade: .good, timing: Tuning.floatMinQuality, aim: aim, float: true)
            }
        }
        let grade = TimingJudge.grade(inputTime: hit.time, contactTime: contactTime(c, inputs: inputs))
        switch hit.action {
        case .release(_, let aim): return HumanPlay(grade: grade, aim: aim)
        case .setTo(_, let hitter): return HumanPlay(grade: grade, hitter: hitter)
        default: return HumanPlay(grade: grade)
        }
    }

    /// Rolls a human's touch: the touch model with the play's timing, then
    /// the gesture's own rules (a miss errs, a float is safe, the aim and
    /// the tip are the human's).
    public static func result(_ play: HumanPlay, _ c: TouchContext, rng: inout SeededRNG, settings: MatchSettings) -> TouchResult {
        var context = c
        context.timing = play.timing
        context.catchUp = 0
        var r = TouchModel.resolve(context, rng: &rng, settings: settings)
        let game = settings.gameType
        if play.grade == .miss {
            // No touch at all: a pass or dig comes off the arms anywhere.
            let error: TouchError = c.kind == .receive || c.kind == .dig ? .shank : TouchModel.errorType(c.kind, rng: &rng)
            return TouchResult(quality: 0, error: error, power: r.power, target: nil, tip: false)
        }
        let team = c.toucher.id.team
        switch c.kind {
        case .serve:
            if play.float {
                r.error = nil
                r.quality = max(r.quality, Tuning.floatMinQuality)
                r.power = Tuning.floatServePower
            }
            guard r.error == nil else { return r }
            if let aim = play.aim {
                r.target = aimed(aim, at: team.other, quality: r.quality, noise: Tuning.serveAimNoise * (1.2 - r.quality),
                                 depth: 1.5...8.6, width: 4.2, rng: &rng).atHeight(0)
            } else if r.target == nil {
                r.target = TouchModel.serveTarget(quality: r.quality, receiving: team.other, rng: &rng)
            }
        case .attack:
            guard let aim = play.aim else {
                // Struck without an aim (a tap): a swing, never a tip.
                r.tip = false
                if r.error == nil { r.power = min(max(Tuning.attackPower(game) * (0.75 + 0.25 * r.quality), 0), 1) }
                return r
            }
            let defending = team.other
            r.tip = LocalFrame.toLocal(aim, team: defending).d < Tuning.tipZone
            r.power = r.tip ? Tuning.tipPower : min(max(Tuning.attackPower(game) * (0.75 + 0.25 * r.quality), 0), 1)
            guard r.error == nil else { return r }
            r.target = aimed(aim, at: defending, quality: r.quality, noise: Tuning.aimNoise * (1 - r.quality) * (r.tip ? 0.5 : 1),
                             depth: 0.5...8.6, width: 4.3, rng: &rng).atHeight(0)
        default:
            break
        }
        return r
    }

    /// `aim` kept on `team`'s court and wandering up to `noise` metres.
    static func aimed(_ aim: Vec2, at team: TeamSide, quality: Float, noise: Float, depth: ClosedRange<Float>, width: Float,
                      rng: inout SeededRNG) -> Vec2 {
        var spot = LocalFrame.toLocal(aim, team: team)
        spot.d += max(noise, 0) * rng.float(in: -1...1)
        spot.l += max(noise, 0) * rng.float(in: -1...1)
        spot.d = min(max(spot.d, depth.lowerBound), depth.upperBound)
        spot.l = min(max(spot.l, -width), width)
        return LocalFrame.toWorld(spot, team: team)
    }

    /// Contact `c` rolled as its owner's touch from `inputs`, as the rally
    /// rolls it: the ball coming in is the contact's, and an attack counts
    /// the blockers lined up where the ball is now.
    public static func resolve(_ c: PendingContact, inputs: [PlayerInput], _ s: inout GameState) -> TouchResult {
        guard let kind = c.kind, let athlete = c.athlete else {
            return TouchResult(quality: 0, error: nil, power: 0, target: nil, tip: false)
        }
        let play = play(for: c, inputs: inputs)
        var blockers = 0
        if kind == .attack, let ball = s.ball { blockers = Rally.blockersAligned(s, at: ball.position(at: s.time), defending: c.team.other) }
        let context = Rally.context(kind, athlete, s, timing: play.timing, quality: c.quality, power: c.power,
                                    slack: c.slack, blockers: blockers)
        return result(play, context, rng: &s.rng, settings: s.settings)
    }
}
