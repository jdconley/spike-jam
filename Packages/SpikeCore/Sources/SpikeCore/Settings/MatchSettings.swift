/// Men's or women's game (spec §4.7). Both teams play the same type.
public enum GameType: String, Codable, Sendable, CaseIterable {
    case mens, womens

    /// Real net heights in metres.
    public var netHeight: Float {
        switch self {
        case .mens: 2.43
        case .womens: 2.24
        }
    }

    /// Multiplies serve and attack flight durations. The women's game is a
    /// little slower so rallies run longer (Claude's call; plan 3 tunes it).
    public var paceScale: Double {
        switch self {
        case .mens: 1.0
        case .womens: 1.2
        }
    }
}

/// The three speed settings carried over from the spike (spec §4.1).
public enum Tempo: String, Codable, Sendable, CaseIterable {
    case fast, faster, stupidFast

    /// Multiplies every flight duration.
    public var flightScale: Double {
        switch self {
        case .fast: 1.2
        case .faster: 1.0
        case .stupidFast: 0.82
        }
    }
}

public enum OffenseSystem: String, Codable, Sendable {
    case fiveOne, sixTwo
}

public struct TeamSettings: Codable, Equatable, Sendable {
    public var system: OffenseSystem
    /// 1...6. Rotation 1 has the (first) setter in zone 1.
    public var startingRotation: Int
    /// This team's AI level, overriding `MatchSettings.difficulty(for:)`.
    /// nil (the default) follows the match. Bot-vs-bot tests use it to pit
    /// levels against each other.
    public var difficulty: Difficulty?

    public init(system: OffenseSystem = .fiveOne, startingRotation: Int = 1, difficulty: Difficulty? = nil) {
        self.system = system
        self.startingRotation = startingRotation
        self.difficulty = difficulty
    }
}

public struct MatchSettings: Codable, Equatable, Sendable {
    public var gameType: GameType = .mens
    public var tempo: Tempo = .faster
    public var pointsToWin = 15
    public var winBy = 2
    /// Indexed by `TeamSide.rawValue`.
    public var teams: [TeamSettings] = [TeamSettings(), TeamSettings()]
    public var firstServer: TeamSide = .home
    /// Hidden catch-up against the AI (spec §4.9). It applies when exactly
    /// one side has humans.
    public var catchUp = true
    public var seed: UInt64 = 1
    /// The AI's level in solo games.
    public var difficulty: Difficulty = .medium
    /// The sides with at least one human player. Empty is bot against bot.
    public var humanSides: Set<TeamSide> = []
    /// "Keep it close": with humans on both sides, the catch-up nudges each
    /// side's bots (spec §4.9). Off by default.
    public var keepItClose = false

    public init() {}

    public func team(_ side: TeamSide) -> TeamSettings {
        teams[side.rawValue]
    }

    /// The level `side`'s bots play at: the team's own override if it has
    /// one, medium for a human's AI teammates (so their mistakes stay fewer
    /// than the opponents' at easier levels), and `difficulty` otherwise.
    public func difficulty(for side: TeamSide) -> Difficulty {
        if let d = team(side).difficulty { return d }
        return humanSides.contains(side) ? .medium : difficulty
    }

    /// Human-readable problems; empty when the settings are playable.
    public func validate() -> [String] {
        var problems: [String] = []
        if teams.count != 2 {
            problems.append("teams must have 2 entries, has \(teams.count)")
        }
        for (i, t) in teams.enumerated() where !(1...6).contains(t.startingRotation) {
            problems.append("team \(i) startingRotation \(t.startingRotation) is outside 1...6")
        }
        if pointsToWin < 1 { problems.append("pointsToWin must be at least 1") }
        if winBy < 1 { problems.append("winBy must be at least 1") }
        return problems
    }
}

// MARK: - Byte-stable coding

/// `humanSides` would encode in hash order as a `Set`, and the settings are
/// part of the shared state, so it is written as a sorted list. Every other
/// field is coded as the synthesized conformance would.
extension MatchSettings {
    enum CodingKeys: String, CodingKey {
        case gameType, tempo, pointsToWin, winBy, teams, firstServer, catchUp, seed
        case difficulty, humanSides, keepItClose
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameType = try c.decode(GameType.self, forKey: .gameType)
        tempo = try c.decode(Tempo.self, forKey: .tempo)
        pointsToWin = try c.decode(Int.self, forKey: .pointsToWin)
        winBy = try c.decode(Int.self, forKey: .winBy)
        teams = try c.decode([TeamSettings].self, forKey: .teams)
        firstServer = try c.decode(TeamSide.self, forKey: .firstServer)
        catchUp = try c.decode(Bool.self, forKey: .catchUp)
        seed = try c.decode(UInt64.self, forKey: .seed)
        difficulty = try c.decode(Difficulty.self, forKey: .difficulty)
        humanSides = Set(try c.decode([TeamSide].self, forKey: .humanSides))
        keepItClose = try c.decode(Bool.self, forKey: .keepItClose)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gameType, forKey: .gameType)
        try c.encode(tempo, forKey: .tempo)
        try c.encode(pointsToWin, forKey: .pointsToWin)
        try c.encode(winBy, forKey: .winBy)
        try c.encode(teams, forKey: .teams)
        try c.encode(firstServer, forKey: .firstServer)
        try c.encode(catchUp, forKey: .catchUp)
        try c.encode(seed, forKey: .seed)
        try c.encode(difficulty, forKey: .difficulty)
        try c.encode(humanSides.sorted { $0.rawValue < $1.rawValue }, forKey: .humanSides)
        try c.encode(keepItClose, forKey: .keepItClose)
    }
}
