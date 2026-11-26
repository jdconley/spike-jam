public enum Phase: Codable, Equatable, Sendable {
    case preServe(untilTick: Int)
    case rally
    case deadBall(untilTick: Int)
    case matchOver
}

/// Block arrives in plan 3.
public enum TouchKind: String, Codable, Sendable {
    case serve, receive, set, attack, dig
}

/// The next thing that happens to the ball, on `tick`.
public struct PendingContact: Codable, Equatable, Sendable {
    /// nil means the ball lands (or is dead) and the rally ends.
    public var kind: TouchKind?
    /// The touching team; for a landing, the team that wins the point.
    public var team: TeamSide
    public var athlete: AthleteID?
    public var tick: Int
    /// For a landing: why the point is won. The placeholder engine decides
    /// the outcome when the ball is hit, so it is known in advance.
    public var reason: PointReason?

    public init(kind: TouchKind?, team: TeamSide, athlete: AthleteID?, tick: Int, reason: PointReason? = nil) {
        self.kind = kind
        self.team = team
        self.athlete = athlete
        self.tick = tick
        self.reason = reason
    }
}

public enum PointReason: String, Codable, Sendable {
    case ace, serviceError, kill, attackError, handlingError
}

public enum GameEvent: Equatable, Sendable {
    case served(AthleteID)
    case touched(TouchKind, AthleteID, quality: Float)
    case point(TeamSide, PointReason)
    case sideOut(TeamSide, rotation: Int)
    case liberoIn(AthleteID, for: AthleteID)
    case matchWon(TeamSide)
}

/// Empty until plan 4, so `step`'s signature is stable.
public struct PlayerInput: Codable, Equatable, Sendable {
    public init() {}
}

/// The whole match as one value (spec §5.2).
public struct GameState: Codable, Equatable, Sendable {
    public var tick: Int
    public var settings: MatchSettings
    /// Indexed by `TeamSide.rawValue`, as are `lineups`.
    public var rosters: [Roster]
    public var lineups: [Lineup]
    public var score: Score
    public var rng: SeededRNG
    public var phase: Phase
    public var ball: Flight?
    public var pending: PendingContact?
    /// The players on court and where they stand.
    public var positions: [AthleteID: Vec2]
    public var touchesThisSide: Int
    /// Rallies completed.
    public var rallyCount: Int
    /// Whether the newest ball flight is an intended net error. For tests of
    /// net clearance; it costs one Bool, so it is kept in every build so the
    /// state's shape never differs between debug and release.
    public var lastFlightWasNetError: Bool

    public init(settings: MatchSettings) {
        self.settings = settings
        var rng = SeededRNG(seed: settings.seed)
        let rosters = TeamSide.allCases.map { side in
            RosterGenerator.make(team: side, gameType: settings.gameType, system: settings.team(side).system, rng: &rng)
        }
        self.rosters = rosters
        lineups = TeamSide.allCases.map { side in
            Lineup(roster: rosters[side.rawValue], settings: settings.team(side))
        }
        self.rng = rng
        score = Score(settings: settings)
        tick = 0
        phase = .preServe(untilTick: Int(Tuning.serveDelay * Double(Tuning.stepsPerSecond)))
        ball = nil
        pending = nil
        positions = [:]
        touchesThisSide = 0
        rallyCount = 0
        lastFlightWasNetError = false
        _ = refreshPositions()
    }

    /// Match time in seconds at the current tick.
    public var time: Double { Double(tick) * Tuning.dt }

    public func isServing(_ side: TeamSide) -> Bool { score.serving == side }

    /// Re-places every on-court player on their zone spot. Returns a
    /// `liberoIn` event for each team whose libero now replaces a different
    /// middle than before.
    mutating func refreshPositions() -> [GameEvent] {
        var events: [GameEvent] = []
        var next: [AthleteID: Vec2] = [:]
        for side in TeamSide.allCases {
            let lineup = lineups[side.rawValue]
            let before = liberoReplacing(side, in: positions)
            for (z, id) in lineup.onCourt(isServing: isServing(side)) {
                next[id] = Court.zoneSpot(z, team: side)
            }
            if let now = liberoReplacing(side, in: next), now != before {
                events.append(.liberoIn(lineup.libero, for: now))
            }
        }
        positions = next
        return events
    }

    /// The middle the libero stands in for in `positions`, if the libero is on.
    func liberoReplacing(_ side: TeamSide, in positions: [AthleteID: Vec2]) -> AthleteID? {
        let lineup = lineups[side.rawValue]
        guard positions[lineup.libero] != nil else { return nil }
        return rosters[side.rawValue].ids(.middle).first { positions[$0] == nil }
    }
}
