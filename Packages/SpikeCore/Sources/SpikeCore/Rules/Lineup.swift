/// Court zones, numbered the standard way from the team's own view:
/// 1 right back (the server), 2 right front, 3 middle front, 4 left front,
/// 5 left back, 6 middle back.
public enum Zone: Int, Codable, Sendable, CaseIterable {
    case z1 = 1, z2, z3, z4, z5, z6

    public var isFrontRow: Bool { self == .z2 || self == .z3 || self == .z4 }
}

/// One team's six-player rotation plus its libero (spec §4.1).
public struct Lineup: Codable, Equatable, Sendable {
    /// 0-based: 0 is "rotation 1", with the (first) setter in zone 1.
    public private(set) var rotation: Int
    public let system: OffenseSystem
    /// The serving order: roster indices 0–5, in zones 1–6 at rotation 0.
    public let order: [AthleteID]
    /// The position of each entry in `order`.
    let positions: [Position]
    public let libero: AthleteID

    public init(roster: Roster, settings: TeamSettings) {
        let six = Array(roster.athletes.prefix(6))
        order = six.map(\.id)
        positions = six.map(\.position)
        libero = roster.ids(.libero)[0]
        system = settings.system
        rotation = settings.startingRotation - 1
    }

    /// Who stands in `z` before any libero swap. Each clockwise rotation
    /// moves the zone-2 player to zone 1, so zone z holds serving slot
    /// (z − 1 + rotation) mod 6.
    public func baseOccupant(_ z: Zone) -> AthleteID {
        order[slot(z)]
    }

    func slot(_ z: Zone) -> Int {
        (z.rawValue - 1 + rotation) % 6
    }

    public func zone(of id: AthleteID) -> Zone? {
        Zone.allCases.first { baseOccupant($0) == id }
    }

    /// The six on court after the libero swap: the libero replaces the
    /// back-row middle, except the middle in zone 1 while their team serves.
    public func onCourt(isServing: Bool) -> [Zone: AthleteID] {
        var court: [Zone: AthleteID] = [:]
        for z in Zone.allCases {
            court[z] = baseOccupant(z)
            if !z.isFrontRow && positions[slot(z)] == .middle && !(isServing && z == .z1) {
                court[z] = libero
            }
        }
        return court
    }

    /// The zone-1 base occupant. Never the libero.
    public func server() -> AthleteID {
        baseOccupant(.z1)
    }

    /// The setter who sets: the only setter in a 5-1, the back-row setter in
    /// a 6-2. Setters are never replaced by the libero, so serving doesn't
    /// change it.
    public func settingSetter(isServing: Bool) -> AthleteID {
        let setters = Zone.allCases.filter { positions[slot($0)] == .setter }
        switch system {
        case .fiveOne:
            return baseOccupant(setters[0])
        case .sixTwo:
            return baseOccupant(setters.first { !$0.isFrontRow }!)
        }
    }

    /// The front-row players other than the setting setter.
    public func attackers(isServing: Bool) -> [AthleteID] {
        let court = onCourt(isServing: isServing)
        let setter = settingSetter(isServing: isServing)
        return [Zone.z4, .z3, .z2].compactMap { court[$0] }.filter { $0 != setter }
    }

    /// One clockwise rotation, after a side-out.
    public mutating func rotate() {
        rotation = (rotation + 1) % 6
    }
}
