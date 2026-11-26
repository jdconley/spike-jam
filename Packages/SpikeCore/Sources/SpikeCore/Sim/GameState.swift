public enum Phase: Codable, Equatable, Sendable {
    case preServe(untilTick: Int)
    case rally
    case deadBall(untilTick: Int)
    case matchOver
}

public enum TouchKind: String, Codable, Sendable {
    case serve, receive, set, attack, dig, block
}

/// The next thing that happens to the ball, on `tick`.
public struct PendingContact: Codable, Equatable, Sendable {
    /// nil means the ball lands (or is dead) and the rally ends.
    public var kind: TouchKind?
    /// The touching team; for a landing, the team that wins the point.
    public var team: TeamSide
    public var athlete: AthleteID?
    public var tick: Int
    /// For a landing: why the point is won. The rally decides the outcome
    /// of a ball nobody can reach when it's hit, so it is known in advance.
    public var reason: PointReason?
    /// How playable the ball coming in is (`TouchContext.incomingQuality`).
    public var quality: Float
    /// How hard it comes in (`TouchContext.incomingPower`).
    public var power: Float
    /// Seconds the toucher has to spare getting there (`TouchContext.reachSlack`).
    public var slack: Double
    /// Numbered as the flight toward it starts (`ContactID.none` until then).
    public var id: ContactID
    /// The human who plays this touch, decided once as the flight toward it
    /// starts (spec §5.3); nil when the AI plays it.
    public var owner: HumanID?

    public init(kind: TouchKind?, team: TeamSide, athlete: AthleteID?, tick: Int, reason: PointReason? = nil,
                quality: Float = 1, power: Float = 0, slack: Double = 1, id: ContactID = .none, owner: HumanID? = nil) {
        self.kind = kind
        self.team = team
        self.athlete = athlete
        self.tick = tick
        self.reason = reason
        self.quality = quality
        self.power = power
        self.slack = slack
        self.id = id
        self.owner = owner
    }
}

public enum PointReason: String, Codable, Sendable {
    /// `kill` includes tools off the block; `block` is a stuff block.
    case ace, serviceError, kill, attackError, handlingError, block
}

public enum GameEvent: Equatable, Sendable {
    case served(AthleteID)
    case touched(TouchKind, AthleteID, quality: Float)
    case point(TeamSide, PointReason)
    case sideOut(TeamSide, rotation: Int)
    case liberoIn(AthleteID, for: AthleteID)
    /// Nobody on `team` could get to the ball for this touch in time, so it
    /// drops (a serve or attack) or is fumbled (a set).
    case outOfReach(TouchKind, team: TeamSide)
    case matchWon(TeamSide)
    /// The set is away to `hitter` for `call` (the set labels show it).
    case setCall(AthleteID, PlayCall)
    /// A touch went wrong this way (each has its own animation). It follows
    /// the touch's `touched` event, or the attack's for a stuff block.
    case erred(TouchKind, AthleteID, TouchError)
    /// The hitter tips or rolls the attack instead of swinging. It follows
    /// the attack's `touched` event.
    case tipped(AthleteID)
}

/// What the rally remembers between touches that the AI and the
/// choreographer read. Reset at each serve.
public struct RallyNotes: Codable, Equatable, Sendable {
    /// The quality of the pass or dig the team in possession is setting
    /// from, which decides its live calls. 1 while the ball is on its way
    /// to them, so hitters head for their called plays.
    public var passQuality: Float
    /// The call of the set in the air, if any.
    public var play: PlayCall?
    /// Each team's last two hitters, oldest first. Indexed by
    /// `TeamSide.rawValue`.
    public var recentHitters: [[AthleteID]]
    /// Each team's read of the other's next hitter (`DefenseAI.read`), by
    /// `TeamSide.rawValue`.
    public var reads: [AthleteID?]
    /// What happens to an attack if the block doesn't touch it: the dig or
    /// the ball landing. Set while a block is pending.
    public var afterBlock: PendingContact?

    public init() {
        passQuality = 1
        play = nil
        recentHitters = [[], []]
        reads = [nil, nil]
        afterBlock = nil
    }
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
    /// The players on court and how they move (spec §5.2).
    public var motion: [AthleteID: Motion]
    /// The tick of the latest serve contact; -1 before the first serve.
    public var serveTick: Int
    /// Who made the latest touch (the serve included); nil between rallies.
    public var lastTouch: AthleteID?
    public var touchesThisSide: Int
    /// Rallies completed.
    public var rallyCount: Int
    /// Whether the newest ball flight is an intended net error. For tests of
    /// net clearance; it costs one Bool, so it is kept in every build so the
    /// state's shape never differs between debug and release.
    public var lastFlightWasNetError: Bool
    /// Each team's play calls, indexed by `TeamSide.rawValue`.
    public var calls: [TeamCalls]
    public var notes: RallyNotes
    /// The humans playing, in the order they joined. Empty is bot against bot.
    public var humans: [HumanSlot]
    /// The number the next contact gets.
    public var nextContactID: ContactID

    /// A match. With `humans`, their sides count as human sides
    /// (`MatchSettings.humanSides`).
    public init(settings: MatchSettings, humans: [HumanSlot] = []) {
        var settings = settings
        settings.humanSides.formUnion(humans.map(\.team))
        self.settings = settings
        self.humans = humans
        nextContactID = ContactID(raw: 1)
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
        motion = [:]
        serveTick = -1
        lastTouch = nil
        touchesThisSide = 0
        rallyCount = 0
        lastFlightWasNetError = false
        let lineups = self.lineups
        calls = TeamSide.allCases.map { side in
            TeamCalls.defaults(lineup: lineups[side.rawValue], roster: rosters[side.rawValue], game: settings.gameType)
        }
        notes = RallyNotes()
        _ = refreshPositions()
    }

    /// Match time in seconds at the current tick.
    public var time: Double { Double(tick) * Tuning.dt }

    public func isServing(_ side: TeamSide) -> Bool { score.serving == side }

    /// The players on court and where they stand.
    public var positions: [AthleteID: Vec2] {
        get { motion.mapValues(\.pos) }
        set {
            for id in motion.keys where newValue[id] == nil { motion[id] = nil }
            for (id, p) in newValue {
                if motion[id] != nil { motion[id]!.pos = p } else { motion[id] = Motion(pos: p) }
            }
        }
    }

    /// Brings `motion` in line with the on-court six after a rotation or a
    /// libero swap. A player coming on takes over the spot and momentum of the
    /// one going off; at the start everyone stands on their formation spot.
    /// Returns a `liberoIn` event for each team whose libero now replaces a
    /// different middle than before.
    mutating func refreshPositions() -> [GameEvent] {
        var events: [GameEvent] = []
        for side in TeamSide.allCases {
            let lineup = lineups[side.rawValue]
            let before = liberoReplacing(side, in: motion)
            let serving = isServing(side)
            let court = Zone.allCases.map { ($0, lineup.occupant($0, isServing: serving)) }
            let onCourt = Set(court.map(\.1))
            let leaving = motion.keys.filter { $0.team == side && !onCourt.contains($0) }.sorted { $0.index < $1.index }
            var handOver = leaving.map { motion.removeValue(forKey: $0)! }
            for (z, id) in court where motion[id] == nil {
                if !handOver.isEmpty {
                    let from = handOver.removeFirst()
                    motion[id] = Motion(pos: from.pos, vel: from.vel)
                } else {
                    let spot = serving ? Formations.servingSpot(z)
                        : Formations.receiveSpot(z, system: lineup.system, rotation: lineup.rotation)
                    motion[id] = Motion(pos: LocalFrame.toWorld(spot, team: side))
                }
            }
            if let now = liberoReplacing(side, in: motion), now != before {
                events.append(.liberoIn(lineup.libero, for: now))
            }
        }
        return events
    }

    /// The middle the libero stands in for, if the libero is on.
    func liberoReplacing(_ side: TeamSide, in motion: [AthleteID: Motion]) -> AthleteID? {
        let lineup = lineups[side.rawValue]
        guard motion[lineup.libero] != nil else { return nil }
        return rosters[side.rawValue].ids(.middle).first { motion[$0] == nil }
    }
}

// MARK: - Byte-stable coding

/// `[AthleteID: Motion]` would encode in hash-seeded iteration order, so equal
/// states gave different bytes in different processes. `motion` is written
/// as a list sorted by athlete instead; every other field is coded as the
/// synthesized conformance would.
extension GameState {
    enum CodingKeys: String, CodingKey {
        case tick, settings, rosters, lineups, score, rng, phase, ball, pending, motion, serveTick, lastTouch
        case touchesThisSide, rallyCount, lastFlightWasNetError, calls, notes, humans, nextContactID
    }

    struct MovingAthlete: Codable {
        var id: AthleteID
        var motion: Motion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tick = try c.decode(Int.self, forKey: .tick)
        settings = try c.decode(MatchSettings.self, forKey: .settings)
        rosters = try c.decode([Roster].self, forKey: .rosters)
        lineups = try c.decode([Lineup].self, forKey: .lineups)
        score = try c.decode(Score.self, forKey: .score)
        rng = try c.decode(SeededRNG.self, forKey: .rng)
        phase = try c.decode(Phase.self, forKey: .phase)
        ball = try c.decodeIfPresent(Flight.self, forKey: .ball)
        pending = try c.decodeIfPresent(PendingContact.self, forKey: .pending)
        let moving = try c.decode([MovingAthlete].self, forKey: .motion)
        motion = Dictionary(moving.map { ($0.id, $0.motion) }, uniquingKeysWith: { _, last in last })
        serveTick = try c.decode(Int.self, forKey: .serveTick)
        lastTouch = try c.decodeIfPresent(AthleteID.self, forKey: .lastTouch)
        touchesThisSide = try c.decode(Int.self, forKey: .touchesThisSide)
        rallyCount = try c.decode(Int.self, forKey: .rallyCount)
        lastFlightWasNetError = try c.decode(Bool.self, forKey: .lastFlightWasNetError)
        calls = try c.decode([TeamCalls].self, forKey: .calls)
        notes = try c.decode(RallyNotes.self, forKey: .notes)
        humans = try c.decode([HumanSlot].self, forKey: .humans)
        nextContactID = try c.decode(ContactID.self, forKey: .nextContactID)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tick, forKey: .tick)
        try c.encode(settings, forKey: .settings)
        try c.encode(rosters, forKey: .rosters)
        try c.encode(lineups, forKey: .lineups)
        try c.encode(score, forKey: .score)
        try c.encode(rng, forKey: .rng)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(ball, forKey: .ball)
        try c.encodeIfPresent(pending, forKey: .pending)
        let moving = motion
            .sorted { ($0.key.team.rawValue, $0.key.index) < ($1.key.team.rawValue, $1.key.index) }
            .map { MovingAthlete(id: $0.key, motion: $0.value) }
        try c.encode(moving, forKey: .motion)
        try c.encode(serveTick, forKey: .serveTick)
        try c.encodeIfPresent(lastTouch, forKey: .lastTouch)
        try c.encode(touchesThisSide, forKey: .touchesThisSide)
        try c.encode(rallyCount, forKey: .rallyCount)
        try c.encode(lastFlightWasNetError, forKey: .lastFlightWasNetError)
        try c.encode(calls, forKey: .calls)
        try c.encode(notes, forKey: .notes)
        try c.encode(humans, forKey: .humans)
        try c.encode(nextContactID, forKey: .nextContactID)
    }
}
