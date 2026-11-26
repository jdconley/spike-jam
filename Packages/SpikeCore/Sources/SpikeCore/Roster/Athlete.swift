public enum Position: String, Codable, Sendable {
    case outside, middle, opposite, setter, libero

    /// The role tag shown over the player (spec §4.1).
    public var tag: String {
        switch self {
        case .outside: "OH"
        case .middle: "MB"
        case .opposite: "OPP"
        case .setter: "S"
        case .libero: "L"
        }
    }
}

public struct AthleteID: Codable, Hashable, Sendable {
    public let team: TeamSide
    /// Index into the team's `Roster.athletes`.
    public let index: Int

    public init(team: TeamSide, index: Int) {
        self.team = team
        self.index = index
    }
}

/// Each in 0...1. Plan 3's AI reads them.
public struct Traits: Codable, Equatable, Sendable {
    public var serve: Float
    public var pass: Float
    public var set: Float
    public var attack: Float
    public var block: Float
    public var defense: Float
    public var speed: Float

    public init(serve: Float, pass: Float, set: Float, attack: Float, block: Float, defense: Float, speed: Float) {
        self.serve = serve
        self.pass = pass
        self.set = set
        self.attack = attack
        self.block = block
        self.defense = defense
        self.speed = speed
    }
}

public struct Athlete: Codable, Equatable, Sendable {
    public var id: AthleteID
    public var name: String
    public var number: Int
    public var position: Position
    public var heightM: Float
    /// Index into 10 skin-tone stops, 0..<10.
    public var skinTone: Int
    public var traits: Traits

    public init(id: AthleteID, name: String, number: Int, position: Position, heightM: Float, skinTone: Int, traits: Traits) {
        self.id = id
        self.name = name
        self.number = number
        self.position = position
        self.heightM = heightM
        self.skinTone = skinTone
        self.traits = traits
    }
}

public struct Roster: Codable, Equatable, Sendable {
    public var athletes: [Athlete]

    public init(athletes: [Athlete]) {
        self.athletes = athletes
    }

    public subscript(_ id: AthleteID) -> Athlete {
        athletes[id.index]
    }

    public func ids(_ p: Position) -> [AthleteID] {
        athletes.filter { $0.position == p }.map(\.id)
    }
}
