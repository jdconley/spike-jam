import SpikeCore

/// Everything in a `GameState` that changes during a match (plan 6): every field except the
/// rosters, which go once at the start. The settings stay in, because a team's system or
/// starting rotation can change in the first huddle (`InputAction.teamSettings`), which rebuilds
/// the rosters; they cost a few dozen bytes.
public struct DynamicState: Codable, Equatable, Sendable {
    public var tick: Int
    public var settings: MatchSettings
    public var lineups: [Lineup]
    public var score: Score
    public var rng: SeededRNG
    public var phase: Phase
    public var ball: Flight?
    public var pending: PendingContact?
    /// `GameState.motion`, sorted by athlete so equal states give equal bytes.
    public var motion: [MovingAthlete]
    public var serveTick: Int
    public var lastTouch: AthleteID?
    public var touchesThisSide: Int
    public var rallyCount: Int
    public var lastFlightWasNetError: Bool
    public var calls: [TeamCalls]
    public var notes: RallyNotes
    public var humans: [HumanSlot]
    public var nextContactID: ContactID
    public var inputBuffer: [PlayerInput]
    public var lastToucherHuman: [HumanID?]
    /// `GameState.fire`, sorted by athlete.
    public var fire: [Streak]

    public struct MovingAthlete: Codable, Equatable, Sendable {
        public var id: AthleteID
        public var motion: Motion
    }

    public struct Streak: Codable, Equatable, Sendable {
        public var id: AthleteID
        public var fire: FireState
    }
}

func byAthlete(_ a: AthleteID, _ b: AthleteID) -> Bool {
    (a.team.rawValue, a.index) < (b.team.rawValue, b.index)
}

extension GameState {
    /// The part of the state a snapshot carries.
    public func dynamic() -> DynamicState {
        DynamicState(
            tick: tick, settings: settings, lineups: lineups, score: score, rng: rng, phase: phase, ball: ball,
            pending: pending,
            motion: motion.sorted { byAthlete($0.key, $1.key) }.map { DynamicState.MovingAthlete(id: $0.key, motion: $0.value) },
            serveTick: serveTick, lastTouch: lastTouch, touchesThisSide: touchesThisSide, rallyCount: rallyCount,
            lastFlightWasNetError: lastFlightWasNetError, calls: calls, notes: notes, humans: humans,
            nextContactID: nextContactID, inputBuffer: inputBuffer, lastToucherHuman: lastToucherHuman,
            fire: fire.sorted { byAthlete($0.key, $1.key) }.map { DynamicState.Streak(id: $0.key, fire: $0.value) })
    }

    /// Takes on `d`. The rosters stay, unless the settings changed what they are (a team's system,
    /// in the first huddle): then they are generated again from the new settings, as the match
    /// itself does.
    public mutating func apply(_ d: DynamicState) {
        if d.settings != settings {
            if d.settings.gameType != settings.gameType || d.settings.seed != settings.seed
                || d.settings.teams.map(\.system) != settings.teams.map(\.system) {
                rosters = GameState(settings: d.settings).rosters
            }
            settings = d.settings
        }
        tick = d.tick
        lineups = d.lineups
        score = d.score
        rng = d.rng
        phase = d.phase
        ball = d.ball
        pending = d.pending
        motion = Dictionary(d.motion.map { ($0.id, $0.motion) }, uniquingKeysWith: { _, last in last })
        serveTick = d.serveTick
        lastTouch = d.lastTouch
        touchesThisSide = d.touchesThisSide
        rallyCount = d.rallyCount
        lastFlightWasNetError = d.lastFlightWasNetError
        calls = d.calls
        notes = d.notes
        humans = d.humans
        nextContactID = d.nextContactID
        inputBuffer = d.inputBuffer
        lastToucherHuman = d.lastToucherHuman
        fire = Dictionary(d.fire.map { ($0.id, $0.fire) }, uniquingKeysWith: { _, last in last })
    }

    /// A state at the match start for these settings, taking on `d`: how a guest builds the
    /// host's state from a snapshot.
    public init(settings: MatchSettings, rosters: [Roster], dynamic d: DynamicState) {
        self.init(settings: settings)
        self.rosters = rosters
        apply(d)
    }
}

/// How far the host has a human's inputs (plan 6): what a guest needs to know which of its own
/// inputs a snapshot already includes.
public struct Confirmation: Codable, Equatable, Sendable {
    public var human: HumanID
    /// The newest unreliable input the host took from them (its `seq`); 0 for none.
    public var input: UInt32
    /// The newest reliable action the host took from them; 0 for none.
    public var reliable: UInt32
    /// The `tick` of the newest input packet the host has from them, -1 for none: the guest's
    /// lead over the host, as the host sees it.
    public var packetTick: Int

    public init(human: HumanID, input: UInt32, reliable: UInt32, packetTick: Int) {
        self.human = human
        self.input = input
        self.reliable = reliable
        self.packetTick = packetTick
    }
}

/// An event the guests show only once the host confirms it (spec §5.3): the score, points, kill
/// banners and fire. The host confirms an event once its tick is older than the rewind cap, so a
/// late touch can never take it back.
public struct Celebration: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case point(TeamSide, PointReason)
        case sideOut(TeamSide, rotation: Int)
        case matchWon(TeamSide)
        case fire(AthleteID, on: Bool)
    }

    /// Numbered from 1 in the order the host confirmed them.
    public var seq: UInt32
    /// The tick of the step it happened in.
    public var tick: Int
    public var kind: Kind

    public init(seq: UInt32, tick: Int, kind: Kind) {
        self.seq = seq
        self.tick = tick
        self.kind = kind
    }

    /// The celebration an event stands for, if it is one.
    public static func kind(of e: GameEvent) -> Kind? {
        switch e {
        case .point(let side, let reason): .point(side, reason)
        case .sideOut(let side, let rotation): .sideOut(side, rotation: rotation)
        case .matchWon(let side): .matchWon(side)
        case .fire(let id, let on): .fire(id, on: on)
        default: nil
        }
    }

    public var event: GameEvent {
        switch kind {
        case .point(let side, let reason): .point(side, reason)
        case .sideOut(let side, let rotation): .sideOut(side, rotation: rotation)
        case .matchWon(let side): .matchWon(side)
        case .fire(let id, let on): .fire(id, on: on)
        }
    }
}

/// What the host has confirmed for good: the score and the celebrations, as of `tick`, which is
/// the rewind cap behind the snapshot.
public struct Confirmed: Codable, Equatable, Sendable {
    public var tick: Int
    public var points: [Int]
    public var winner: TeamSide?
    /// The newest few, so a lost snapshot loses none.
    public var celebrations: [Celebration]

    public init(tick: Int, points: [Int], winner: TeamSide?, celebrations: [Celebration]) {
        self.tick = tick
        self.points = points
        self.winner = winner
        self.celebrations = celebrations
    }
}

/// The host's state after step `tick` (spec §5.3), about 30 times a second.
public struct Snapshot: Codable, Equatable, Sendable {
    public var tick: Int
    public var dynamic: DynamicState
    /// Inputs the host has that it hasn't played yet, every human's, in arrival order: early ones
    /// and touches waiting for their contact (`Placement`). A guest predicts with them too.
    public var pending: [NetInput]
    /// One for each human the host has heard from.
    public var confirmedThrough: [Confirmation]
    public var confirmed: Confirmed

    public init(tick: Int, dynamic: DynamicState, pending: [NetInput] = [], confirmedThrough: [Confirmation], confirmed: Confirmed) {
        self.tick = tick
        self.dynamic = dynamic
        self.pending = pending
        self.confirmedThrough = confirmedThrough
        self.confirmed = confirmed
    }
}
