/// One team's play calls, by athlete (spec §4.3). The huddle edits them and
/// they stay as the defaults from rally to rally. A call that doesn't fit
/// the athlete's current row (they rotated) falls back to the position's
/// default, so a stale call is never run.
public struct TeamCalls: Codable, Equatable, Sendable {
    public var byAthlete: [AthleteID: PlayCall]

    public init(byAthlete: [AthleteID: PlayCall] = [:]) {
        self.byAthlete = byAthlete
    }

    /// The default calls (`PlayBook.defaults`) for the current rotation's
    /// attackers, front row and back row.
    public static func defaults(lineup: Lineup, roster: Roster, game: GameType) -> TeamCalls {
        var calls = TeamCalls()
        for z in Zone.allCases {
            let id = lineup.occupant(z, isServing: false)
            if let c = defaultCall(roster[id].position, frontRow: z.isFrontRow, system: lineup.system, game: game) {
                calls.byAthlete[id] = c
            }
        }
        return calls
    }

    /// The call `id` runs from where they are in the rotation: their own if
    /// they can run it from that row, else their position's default. nil for
    /// the libero, a back-row middle or setter, and anyone off the court.
    public func call(for id: AthleteID, lineup: Lineup, roster: Roster, game: GameType, isServing: Bool) -> PlayCall? {
        guard let zone = lineup.zone(of: id, isServing: isServing) else { return nil }
        return call(for: id, position: roster[id].position, frontRow: zone.isFrontRow, system: lineup.system, game: game)
    }

    func call(for id: AthleteID, position: Position, frontRow: Bool, system: OffenseSystem, game: GameType) -> PlayCall? {
        if let own = byAthlete[id], TeamCalls.canRun(own, position, frontRow: frontRow, system: system) { return own }
        return TeamCalls.defaultCall(position, frontRow: frontRow, system: system, game: game)
    }

    /// Sets every on-court hitter the combo names, by position.
    public mutating func apply(_ combo: Combo, lineup: Lineup, roster: Roster, isServing: Bool) {
        let calls = Combo.calls(combo)
        for z in [Zone.z4, .z3, .z2] {
            let id = lineup.occupant(z, isServing: isServing)
            var position = roster[id].position
            if position == .setter && lineup.system == .sixTwo { position = .opposite }
            if let c = calls[position] { byAthlete[id] = c }
        }
    }

    /// Whether `position` can run `call` from this row. Any front-row hitter
    /// can run any front-row hitter's call (crosses, X, Tandem); the dump is
    /// the 5-1 setter's alone; back-row calls need a back-row hitter.
    static func canRun(_ call: PlayCall, _ position: Position, frontRow: Bool, system: OffenseSystem) -> Bool {
        let own = PlayBook.calls(for: position, frontRow: frontRow, system: system)
        if own.contains(call) { return true }
        guard frontRow, !own.isEmpty, own != [.dump], call != .dump else { return false }
        return !PlayBook.spec(call).lane.isBackRow
    }

    static func defaultCall(_ position: Position, frontRow: Bool, system: OffenseSystem, game: GameType) -> PlayCall? {
        // A 6-2's front-row setter plays opposite.
        let p = position == .setter && system == .sixTwo && frontRow ? .opposite : position
        guard let c = PlayBook.defaults(game, frontRow: frontRow)[p],
              PlayBook.calls(for: position, frontRow: frontRow, system: system).contains(c) else { return nil }
        return c
    }
}

// MARK: - Byte-stable coding

/// A dictionary keyed by `AthleteID` would encode in hash order, so the calls
/// are written as a list sorted by athlete.
extension TeamCalls {
    enum CodingKeys: String, CodingKey { case byAthlete }

    struct Entry: Codable {
        var id: AthleteID
        var call: PlayCall
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.decode([Entry].self, forKey: .byAthlete)
        byAthlete = Dictionary(entries.map { ($0.id, $0.call) }, uniquingKeysWith: { _, last in last })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let entries = byAthlete.sorted { ($0.key.team.rawValue, $0.key.index) < ($1.key.team.rawValue, $1.key.index) }
            .map { Entry(id: $0.key, call: $0.value) }
        try c.encode(entries, forKey: .byAthlete)
    }
}

/// The attackers who can hit in this rotation with their called play
/// (spec §4.3, §4.8): the front-row hitters, the back-row hitters, and the
/// setter's Dump only when the setting setter is front row. The pass decides
/// what's live:
/// - below `PlayBook.goodPass`, a first-tempo call falls back to the 4 (the
///   outside), the 5 (the right side) or the Pipe (back middle), and the
///   middle's quick is dropped;
/// - below `PlayBook.outOfSystemPass` the setter can only put up a high ball:
///   second-tempo calls fall back the same way, the Slide is dropped, and so
///   is the Dump.
/// Ordered front row left to right, then back row, then the Dump.
public func liveCalls(_ s: GameState, team: TeamSide, passQuality: Float) -> [(AthleteID, PlayCall)] {
    let lineup = s.lineups[team.rawValue], roster = s.rosters[team.rawValue]
    let serving = s.isServing(team), game = s.settings.gameType
    let setter = lineup.settingSetter(isServing: serving)
    var out: [(AthleteID, PlayCall)] = []
    for z in [Zone.z4, .z3, .z2, .z5, .z6, .z1] {
        let id = lineup.occupant(z, isServing: serving)
        guard id != setter, id != lineup.libero,
              let call = s.calls[team.rawValue].call(for: id, position: roster[id].position, frontRow: z.isFrontRow,
                                                     system: lineup.system, game: game),
              let live = liveCall(call, position: roster[id].position, frontRow: z.isFrontRow, passQuality: passQuality)
        else { continue }
        out.append((id, live))
    }
    if lineup.zone(of: setter)?.isFrontRow == true && passQuality >= PlayBook.outOfSystemPass {
        out.append((setter, .dump))
    }
    return out
}

/// `call` off a pass of `passQuality`, or nil if it's dropped.
func liveCall(_ call: PlayCall, position: Position, frontRow: Bool, passQuality: Float) -> PlayCall? {
    let spec = PlayBook.spec(call)
    let tooFast = (spec.needsGoodPass && passQuality < PlayBook.goodPass)
        || (spec.tempo == .second && passQuality < PlayBook.outOfSystemPass && call != .pipe)
    guard tooFast else { return call }
    if !frontRow { return spec.lane == .backRight ? .d : .pipe }
    switch position {
    case .middle: return nil
    case .outside: return .four
    default: return .five
    }
}
