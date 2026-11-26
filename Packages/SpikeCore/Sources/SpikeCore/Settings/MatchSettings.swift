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
        case .womens: 1.08
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

    public init(system: OffenseSystem = .fiveOne, startingRotation: Int = 1) {
        self.system = system
        self.startingRotation = startingRotation
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
    /// Hidden catch-up against the AI. Unused until plan 3.
    public var catchUp = true
    public var seed: UInt64 = 1

    public init() {}

    public func team(_ side: TeamSide) -> TeamSettings {
        teams[side.rawValue]
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
