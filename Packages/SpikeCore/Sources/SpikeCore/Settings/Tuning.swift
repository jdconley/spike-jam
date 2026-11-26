/// Every placeholder number in one place, so plan 3 can replace them.
public enum Tuning {
    /// Arcade gravity from the spike, m/s².
    public static let gravity: Float = -9.8 * 1.7
    public static let stepsPerSecond = 60
    public static let dt: Double = 1.0 / 60.0
    /// Seconds between the end of the dead ball and the serve.
    public static let serveDelay: Double = 0.8
    /// Seconds the ball stays dead after a point.
    public static let deadBall: Double = 1.5
}

// MARK: - Placeholder rally odds and timings (Claude's placeholders; plan 3
// replaces them with traits and real touches).
extension Tuning {
    public static let serveError: Float = 0.12
    /// Share of serve errors that go into the net; the rest go long.
    public static let serveErrorNetShare: Float = 0.5
    public static let ace: Float = 0.07
    /// A shanked pass or dig: `handlingError` for the passing side.
    public static let passError: Float = 0.06
    public static let setError: Float = 0.03
    public static let attackError: Float = 0.10
    /// Share of attack errors that go into the net; the rest go long.
    public static let attackErrorNetShare: Float = 0.5
    /// Chance the defending team digs an attack that stays in; otherwise a kill.
    public static let digSuccess: Float = 0.45
    public static let passQuality: ClosedRange<Float> = 0.3...1

    /// Serves and attacks must cross the net this far above the tape.
    public static let netClearanceMargin: Float = 0.15

    public static let serveDuration: Double = 0.95
    /// Receive and dig: base + spread × (1 − quality) seconds to the setter.
    public static let passDurationBase: Double = 0.85
    public static let passDurationSpread: Double = 0.35
    public static let attackDuration: Double = 0.4
    /// A shank, a set error or a net ball falling to the floor.
    public static let errorDuration: Double = 0.6

    /// Height of a pass or dig contact above the floor.
    public static let passContactHeight: Float = 0.8
}

// MARK: - Footwork (Claude's starting numbers; the builder tunes them on
// device). Footwork may run faster than real life so the game stays FAST.
extension Tuning {
    /// Multiplies every gait's speed cap.
    public static let footworkScale: Float = 1.25
    /// Gait speed caps in m/s, before `footworkScale` and the speed trait.
    public static func gaitSpeed(_ g: Gait) -> Float {
        switch g {
        case .stand: 2.0          // small adjustments while "standing"
        case .run: 6.0
        case .shuffle: 3.5
        case .backpedal: 3.5
        case .approach: 5.0
        case .dive: 4.0
        }
    }
    /// m/s², speeding up and slowing down alike.
    public static let accel: Float = 16
    /// Within this many metres of the goal a player has arrived.
    public static let arriveRadius: Float = 0.08

    /// Players stay on their own side and inside the free zone (team-local).
    public static let minDepth: Float = 0.2
    public static let maxDepth: Float = 12
    public static let maxLateral: Float = 7.5
}

// MARK: - Choreography (Claude's starting numbers).
extension Tuning {
    /// The serve waits for everyone to be this close to their formation spot…
    public static let formationTolerance: Float = 0.3
    /// …for at most this many seconds; then stragglers snap onto it.
    public static let formationWait: Double = 3.0

    /// An attack jump: the peak meets the ball, so takeoff is half of it
    /// (0.25 s) before the attack contact.
    public static let attackJumpTicks = 30
    public static let attackJumpHeight: Float = 0.9
    /// A block jump starts 0.3 s before the attack contact and peaks on it.
    public static let blockJumpTicks = 36
    public static let blockJumpHeight: Float = 0.7
    /// Hitters start the approach from their approach spot this long before
    /// takeoff.
    public static let approachTime: Double = 0.75
    /// Coverage players crouch this far around the hitter's takeoff.
    public static let coverageRadius: Float = 2.0

    /// How close a passer or digger must get to the ball's floor point to
    /// play it: arm's length for a pass, a lunge for a dig.
    public static let passReach: Float = 0.5
    public static let digReach: Float = 0.8
    /// The passers who aren't taking the serve shade this share of the way
    /// toward it, at most `passShadeMax` metres.
    public static let passShade: Float = 0.35
    public static let passShadeMax: Float = 1.2

    /// A player who gets to the ball this many seconds after it arrives
    /// still plays it.
    public static let reachGrace: Double = 0.1
    /// The best set a teammate bailing out a late setter can make.
    public static let backupSetQuality: Float = 0.4
    /// The pass a bail-out set counts as, so only high balls are live.
    public static let bailOutPassQuality: Float = 0.3
    /// How far off the setter target the worst pass lands, along each axis.
    public static let passScatter: Float = 3.0
}

// MARK: - The AI setter (Claude's starting numbers).
extension Tuning {
    /// Score per point of the hitter's attack trait.
    public static let setterAttackWeight: Float = 2.0
    /// Score lost per blocker expected at the set.
    public static let setterBlockerWeight: Float = 0.8
    /// Extra score for a quick off a perfect pass, scaled down to 0 at a
    /// just-good-enough one.
    public static let setterQuickBonus: Float = 0.3
    /// Score lost for each of the last two sets that went to this hitter.
    public static let setterRepeatPenalty: Float = 0.3
    /// Softmax temperature per point of (1.6 − set trait).
    public static let setterTemperature: Float = 0.35
    /// Added to the temperature of a side the catch-up holds back, at full
    /// level: it sets less sharply.
    public static let catchUpTemperature: Float = 0.3
    /// How often a bot team's huddle calls a combination.
    public static let comboChance: Float = 0.12
    /// Seconds a blocker takes to read the set before moving.
    public static let blockerReaction: Double = 0.15
    /// How far a blocker's hands reach to the side, in metres.
    public static let blockerArmReach: Float = 0.4
}
