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

    /// Set durations by the attacker's zone.
    public static func setDuration(_ z: Zone) -> Double {
        switch z {
        case .z4: 0.78
        case .z3: 0.42
        case .z2: 0.72
        default: 0.8          // back-row sets; unused until plan 3
        }
    }

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
