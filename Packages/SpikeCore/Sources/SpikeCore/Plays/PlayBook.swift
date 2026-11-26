/// The play catalog (spec §4.8): what each call is, who can run it, and
/// where its set goes.
///
/// Net zones are about a metre each, 1 at the left antenna to 9 at the right
/// from the attacking team's view, so zone k's centre is at team-local
/// `l = -4.5 + (k - 0.5)`. The setter's target (`Court.setterTarget`) sits at
/// l 1.5, between zones 6 and 7: the 1 goes right in front of it, the Back 1
/// just behind.
public enum PlayBook {
    /// The pass quality first-tempo calls need (Claude's call).
    public static let goodPass: Float = 0.6
    /// Below this the pass is out of system: only high balls (4, 5, Pipe, D)
    /// and the A stay live, and the setter can't dump.
    public static let outOfSystemPass: Float = 0.35

    public static func spec(_ c: PlayCall) -> PlaySpec {
        func p(_ lane: AttackLane, _ zone: Float, _ tempo: SetTempo, _ duration: Double,
               oneFoot: Bool = false, needsGoodPass: Bool = false, behind: Bool = false) -> PlaySpec {
            let apex: Float = switch tempo {
            case .first: 0.5
            case .second: 1.2
            case .high: 2.6
            }
            return PlaySpec(call: c, lane: lane, netZone: zone, tempo: tempo, setDuration: duration, apex: apex,
                            oneFoot: oneFoot, needsGoodPass: needsGoodPass, behindSetter: behind)
        }
        return switch c {
        case .four: p(.left, 1, .high, 0.9)
        case .go: p(.left, 1, .second, 0.6)
        case .hut: p(.left, 1, .first, 0.45, needsGoodPass: true)
        case .thirtyTwo: p(.middle, 3, .second, 0.58)
        case .one: p(.middle, 6, .first, 0.38, needsGoodPass: true)
        case .thirtyOne: p(.middle, 3, .first, 0.42, needsGoodPass: true)
        case .backOne: p(.middle, 7, .first, 0.4, needsGoodPass: true, behind: true)
        case .slide: p(.right, 8.5, .second, 0.55, oneFoot: true, behind: true)
        case .five: p(.right, 9, .high, 0.92, behind: true)
        case .red: p(.right, 9, .second, 0.62, behind: true)
        // The dump has no set: the setter plays the second ball over. Its
        // duration is the dump's flight.
        case .dump: p(.middle, 6.5, .first, 0.4)
        case .pipe: p(.backMiddle, 5, .second, 0.65)
        case .bic: p(.backMiddle, 5, .first, 0.45, needsGoodPass: true)
        case .d: p(.backRight, 8, .high, 0.85, behind: true)
        case .a: p(.backLeft, 2, .high, 0.88)
        }
    }

    /// The team-local `l` of net zone `k`'s centre.
    public static func zoneCenter(_ k: Float) -> Float {
        -4.5 + (k - 0.5)
    }

    /// The calls `position` can run in this row and system. Back-row players
    /// only get back-row calls, the libero none, and the setter dumps only in
    /// a 5-1 front row (a 6-2's front-row setter plays opposite).
    public static func calls(for position: Position, frontRow: Bool, system: OffenseSystem) -> [PlayCall] {
        switch (position, frontRow) {
        case (.outside, true): [.four, .go, .hut, .thirtyTwo]
        case (.outside, false): [.pipe, .bic, .a]
        case (.middle, true): [.one, .thirtyOne, .backOne, .slide]
        case (.middle, false): []
        case (.opposite, true): [.five, .red]
        case (.opposite, false): [.d]
        case (.setter, true): system == .fiveOne ? [.dump] : [.five, .red]
        case (.setter, false): []
        case (.libero, _): []
        }
    }

    /// Each position's default call (spec §4.7, §4.8): 4, 1, 5 and Pipe for
    /// the men's game; Go, Slide, Red and Pipe for the women's. Back row, the
    /// outside hits the Pipe and the opposite the D in both.
    public static func defaults(_ game: GameType, frontRow: Bool = true) -> [Position: PlayCall] {
        guard frontRow else { return [.outside: .pipe, .opposite: .d] }
        return switch game {
        case .mens: [.outside: .four, .middle: .one, .opposite: .five, .setter: .dump]
        case .womens: [.outside: .go, .middle: .slide, .opposite: .red, .setter: .dump]
        }
    }

    /// Where the set for `c` is contacted, in world coordinates: on the
    /// zone's centre, closer to the net the faster the set, at a hitter's
    /// contact height above a net of height `net`. Back-row sets go to
    /// d 3.8 (3.6 for the Bic), and the dump is played from the setter's
    /// hands.
    public static func setPoint(_ c: PlayCall, team: TeamSide, net: Float) -> Vec3 {
        let s = spec(c)
        let l = zoneCenter(s.netZone)
        let d: Float, y: Float
        if c == .dump {
            d = 0.6
            y = net + 0.35
        } else if s.lane.isBackRow {
            d = c == .bic ? 3.6 : 3.8
            y = net + 0.57
        } else {
            d = switch s.tempo {
            case .first: 0.7
            case .second: 0.9
            case .high: 1.1
            }
            y = net + 0.72
        }
        return LocalFrame.toWorld(LocalSpot(d: d, l: l), team: team).atHeight(y)
    }

    /// Where a hitter running `c` starts the approach, team-local: outside
    /// the sideline for the pins, a few steps off the net for the middle's
    /// quicks, deep for the back row. The slide starts in the middle and runs
    /// along the net.
    public static func approachStart(_ c: PlayCall) -> LocalSpot {
        switch c {
        case .four, .go, .hut: BaseSpots.approachStart(.left)
        case .thirtyTwo: LocalSpot(d: 4.0, l: -3.4)
        case .one: BaseSpots.approachStart(.middle)
        case .thirtyOne: LocalSpot(d: 3.8, l: -1.2)
        case .backOne: LocalSpot(d: 3.8, l: 1.4)
        case .slide: LocalSpot(d: 3.0, l: 0.0)
        case .five, .red: BaseSpots.approachStart(.right)
        case .dump: LocalSpot(d: 0.8, l: 1.5)
        case .pipe, .bic: BaseSpots.approachStart(.backMiddle)
        case .d: BaseSpots.approachStart(.backRight)
        case .a: BaseSpots.approachStart(.backLeft)
        }
    }
}
