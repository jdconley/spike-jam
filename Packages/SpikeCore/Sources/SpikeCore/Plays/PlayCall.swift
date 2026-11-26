/// The play calls, by the names US teams use (spec §4.8). One meaning per
/// name, everywhere.
public enum PlayCall: String, Codable, Sendable, CaseIterable {
    case four, go, hut, thirtyTwo, one, thirtyOne, backOne, slide, five, red, dump, pipe, bic, d, a

    /// The label on the court and in the huddle.
    public var display: String {
        switch self {
        case .four: "4"
        case .go: "GO"
        case .hut: "HUT"
        case .thirtyTwo: "32"
        case .one: "1"
        case .thirtyOne: "31"
        case .backOne: "BACK 1"
        case .slide: "SLIDE"
        case .five: "5"
        case .red: "RED"
        case .dump: "DUMP"
        case .pipe: "PIPE"
        case .bic: "BIC"
        case .d: "D"
        case .a: "A"
        }
    }

    /// The one-line meaning a long press shows.
    public var meaning: String {
        switch self {
        case .four: "4: high ball to the left antenna"
        case .go: "GO: faster outside set to the antenna"
        case .hut: "HUT: fastest outside set, low and flat"
        case .thirtyTwo: "32: a quicker ball inside the antenna, zone 3"
        case .one: "1: quick right in front of the setter"
        case .thirtyOne: "31: quick in the gap, zone 3"
        case .backOne: "BACK 1: quick just behind the setter"
        case .slide: "SLIDE: one-foot approach behind the setter"
        case .five: "5: high back set to the right antenna"
        case .red: "RED: fast back set to the right side"
        case .dump: "DUMP: the setter attacks the second ball"
        case .pipe: "PIPE: back-row attack through the middle"
        case .bic: "BIC: a faster, lower pipe off a good pass"
        case .d: "D: back-row attack from right back"
        case .a: "A: back-row attack from left back"
        }
    }
}

/// How fast a set is: first tempo (a quick), second, or a high ball. Named
/// to stay clear of the match's `Tempo` speed setting.
public enum SetTempo: Int, Codable, Sendable {
    case first = 1, second, high
}

/// Everything a call fixes about the set and the approach.
public struct PlaySpec: Equatable, Sendable {
    public var call: PlayCall
    /// Where the ball is attacked, as the defense sees it: the coarse lane
    /// that picks the block and the perimeter.
    public var lane: AttackLane
    /// The net zone of the set, 1 (left antenna) to 9, from the attacking
    /// team's view. Fractional zones sit between two.
    public var netZone: Float
    public var tempo: SetTempo
    /// Seconds from the setter's hands to the hitter's, before the match's
    /// `Tempo` scale.
    public var setDuration: Double
    /// The arc's nominal peak above the net, for drawing the play.
    public var apex: Float
    public var oneFoot: Bool
    /// First-tempo calls aren't live off a pass below `PlayBook.goodPass`.
    public var needsGoodPass: Bool
    /// The set goes behind the setter.
    public var behindSetter: Bool

    public init(call: PlayCall, lane: AttackLane, netZone: Float, tempo: SetTempo, setDuration: Double, apex: Float,
                oneFoot: Bool, needsGoodPass: Bool, behindSetter: Bool) {
        self.call = call
        self.lane = lane
        self.netZone = netZone
        self.tempo = tempo
        self.setDuration = setDuration
        self.apex = apex
        self.oneFoot = oneFoot
        self.needsGoodPass = needsGoodPass
        self.behindSetter = behindSetter
    }
}

/// Team calls that set several hitters at once (spec §4.8).
public enum Combo: String, Codable, Sendable, CaseIterable {
    case x, tandem, slideRed

    /// The call each hitter runs.
    /// - X: the middle runs a 1 and the outside crosses behind for a 32.
    /// - Tandem: the middle runs a 1 and the opposite follows with a
    ///   second-tempo ball in the 31's spot (the 32).
    /// - Slide-Red: the middle slides while the opposite runs Red.
    public static func calls(_ combo: Combo) -> [Position: PlayCall] {
        switch combo {
        case .x: [.middle: .one, .outside: .thirtyTwo]
        case .tandem: [.middle: .one, .opposite: .thirtyTwo]
        case .slideRed: [.middle: .slide, .opposite: .red]
        }
    }
}
