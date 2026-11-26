/// Every tunable number in one place.
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

// MARK: - Flights (Claude's numbers).
extension Tuning {
    /// Serves and attacks must cross the net this far above the tape.
    public static let netClearanceMargin: Float = 0.15

    /// A serve's flight at power 0.5; harder serves are quicker.
    public static let serveDuration: Double = 0.95
    /// Receive and dig: base + spread × (1 − quality) seconds to the setter.
    public static let passDurationBase: Double = 0.85
    public static let passDurationSpread: Double = 0.35
    /// A spike's flight at power 0.5; harder spikes are quicker.
    public static let attackDuration: Double = 0.4
    /// A tip or roll shot, and a setter's dump.
    public static let tipDuration: Double = 0.75
    /// A shank, a set error or a net ball falling to the floor.
    public static let errorDuration: Double = 0.6
    /// An overpass or a free ball floating over.
    public static let freeBallDuration: Double = 1.1
    /// A soft block popping up on the blockers' side.
    public static let softBlockDuration: Double = 0.85

    /// Height of a pass or dig contact above the floor.
    public static let passContactHeight: Float = 0.8
}

// MARK: - The touch model (Claude's numbers, tuned with spikesim against the
// plan's rate bands).
extension Tuning {
    /// The error chance of a touch by a 0.6-trait AI at medium, before the
    /// ball's power and quality, lateness and blockers.
    public static func baseError(_ kind: TouchKind, _ game: GameType) -> Float {
        switch (kind, game) {
        // Everyone jump serves in the men's game, so more misses.
        case (.serve, .mens): 0.165
        case (.serve, .womens): 0.1
        case (.receive, .mens): 0.022
        // Float serves move, so the women's game shanks a few more.
        case (.receive, .womens): 0.034
        case (.dig, .mens): 0.09
        case (.dig, .womens): 0.065
        case (.set, _): 0.012
        case (.attack, _): 0.075
        // A block touch that goes off the hands and out.
        case (.block, _): 0.12
        }
    }

    /// How each touch reacts to the ball coming in.
    public struct TouchCoefficients: Sendable {
        /// Error chance × (1 + powerError × power).
        public var powerError: Float
        /// Error chance × (1 + badBallError × (1 − incoming quality)).
        public var badBallError: Float
        /// Quality − powerQuality × power.
        public var powerQuality: Float
        /// Quality − badBallQuality × (1 − incoming quality).
        public var badBallQuality: Float
    }

    public static func touchCoefficients(_ kind: TouchKind) -> TouchCoefficients {
        switch kind {
        case .serve: TouchCoefficients(powerError: 0, badBallError: 0, powerQuality: 0, badBallQuality: 0)
        case .receive: TouchCoefficients(powerError: 1.2, badBallError: 1.0, powerQuality: 0.12, badBallQuality: 0.3)
        case .dig: TouchCoefficients(powerError: 1.6, badBallError: 1.0, powerQuality: 0.2, badBallQuality: 0.25)
        case .set: TouchCoefficients(powerError: 0, badBallError: 1.5, powerQuality: 0, badBallQuality: 0.35)
        case .attack: TouchCoefficients(powerError: 0, badBallError: 1.0, powerQuality: 0, badBallQuality: 0.3)
        case .block: TouchCoefficients(powerError: 0.8, badBallError: 1.0, powerQuality: 0.1, badBallQuality: 0.3)
        }
    }

    /// About one standard deviation of a touch's quality.
    public static let qualitySpread: Float = 0.15
    public static let maxError: Float = 0.9
    /// A toucher with this many seconds to spare is never rushed.
    public static let comfortableSlack: Double = 0.25
    /// Error chance × (1 + lateError × lateness), lateness 1 at no slack.
    public static let lateError: Float = 0.8
    public static let lateQuality: Float = 0.12
    /// Per blocker lined up against an attack.
    public static let blockerError: Float = 0.12
    public static let blockerQuality: Float = 0.05

    /// Shares of each error that go into the net (serves, attacks) or over it
    /// (passes and digs).
    public static let serveNetShare: Float = 0.45
    public static let attackNetShare: Float = 0.4
    public static let overpassShare: Float = 0.12

    /// A serve's power at toughness 0.5: jump serves in the men's game,
    /// floats in the women's.
    public static func servePower(_ game: GameType) -> Float { game == .mens ? 0.75 : 0.52 }
    /// How far a serve's aim wanders, in metres, at toughness 0.2.
    public static let serveAimNoise: Float = 1.2
    public static func attackPower(_ game: GameType) -> Float { game == .mens ? 0.92 : 0.76 }
    /// AI hitters tip 6–10% of the time, more in the women's game, against a
    /// bigger block and off a bad set.
    public static func tipChance(_ game: GameType) -> Float { game == .mens ? 0.05 : 0.07 }
    public static let tipPerBlocker: Float = 0.01
    public static let tipOffBadSet: Float = 0.06
    public static let tipPower: Float = 0.15

    /// How a set of quality q drifts off its spot: up to this far tight or
    /// off the net and along it at quality 0.
    public static let setDrift: Float = 1.4
    /// A hitter with the best placement aims for the biggest gap this often
    /// (scaled down with quality); otherwise somewhere random.
    public static let aimSmart: Float = 0.5
    /// How far an attack's aim wanders at quality 0, in metres.
    public static let aimNoise: Float = 1.4
    /// Seconds a digger or passer takes to read the ball before moving.
    public static let digReaction: Double = 0.05
    public static let receiveReaction: Double = 0.1
    /// Two passers this close in time to a serve sometimes leave it to each
    /// other.
    public static let confusionWindow: Double = 0.05
    public static let confusionChance: Float = 0.12
}

// MARK: - Catch-up bounds (spec §4.9; Claude's starting numbers).
extension Tuning {
    /// At catch-up level ±1, an AI touch's quality moves by ±this…
    public static let catchUpQuality: Float = 0.07
    /// …and its error chance is × (1 ∓ this).
    public static let catchUpError: Float = 0.35
}

// MARK: - Blocking (Claude's numbers).
extension Tuning {
    /// Standing reach is height × this.
    public static let standingReach: Float = 1.33
    /// A block jump at block trait 0.5, in metres; the jump is
    /// × (0.75 + 0.5 × block trait).
    public static func blockJump(_ game: GameType) -> Float { game == .mens ? 0.85 : 0.68 }
    /// Block reach is standing reach + this share of the jump: the hands
    /// meet the ball a little before or after the peak.
    public static let blockJumpShare: Float = 0.75
    /// The block covers the ball fully when its reach is this far above the
    /// ball at the net, and not at all at the ball's height.
    public static let blockCoverSpan: Float = 0.5
    /// Hands within this far of the ball along the net cover it fully…
    public static let blockHands: Float = 0.25
    /// …fading to nothing this much farther out.
    public static let blockFade: Float = 0.55
    /// Chance a fully covering blocker touches the ball.
    public static let blockTouch: Float = 0.5
    /// A tip mostly goes over or around the block.
    public static let blockTipShare: Float = 0.3
    /// A touched ball is stuffed when the block's quality is above this.
    public static let stuffQuality: Float = 0.6
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
    public static let digReach: Float = 1.0
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
    public static let setterAttackWeight: Float = 1.2
    /// Score lost per blocker expected at the set.
    public static let setterBlockerWeight: Float = 0.5
    /// Extra score for a quick off a perfect pass, scaled down to 0 at a
    /// just-good-enough one.
    public static let setterQuickBonus: Float = 0.15
    /// Off the worst pass, extra score for the high ball to a pin, and less
    /// for a back-row attack (scaled to 0 at a good pass).
    public static let setterSafeBonus: Float = 0.9
    public static let setterBackRowPenalty: Float = 0.5
    /// Score lost for each of the last two sets that went to this hitter.
    public static let setterRepeatPenalty: Float = 0.3
    /// Softmax temperature per point of (1.6 − set trait).
    public static let setterTemperature: Float = 0.6
    /// Added to the temperature of a side the catch-up holds back, at full
    /// level: it sets less sharply.
    public static let catchUpTemperature: Float = 0.3
    /// The defense goes with its likeliest read this often, plus `readSkill`
    /// per point of its average defense trait; otherwise it half-guesses.
    public static let readBase: Float = 0.3
    public static let readSkill: Float = 0.6
    /// At catch-up level ±1, the read goes with the likeliest ±this more often.
    public static let catchUpRead: Float = 0.1
    /// How often a bot team's huddle calls a combination.
    public static let comboChance: Float = 0.12
    /// Seconds a blocker takes to read the set before moving.
    public static let blockerReaction: Double = 0.15
    /// How far a blocker's hands reach to the side, in metres.
    public static let blockerArmReach: Float = 0.4
}
