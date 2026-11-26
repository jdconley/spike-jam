extension Formations {
    /// Where the server stands: behind the end line in the zone-1 lane.
    public static let serverSpot = LocalSpot(d: 9.6, l: 3.0)

    /// Where each on-court player of the serving team stands before the serve.
    /// The server goes behind the end line; everyone else takes the perimeter
    /// base against an attack from the opponent's left, by zone rather than
    /// by role so the line-up is legal. They switch to their own roles when
    /// the serve is struck.
    public static func serving(_ lineup: Lineup, roster: Roster) -> [AthleteID: LocalSpot] {
        var out: [AthleteID: LocalSpot] = [:]
        for z in Zone.allCases { out[lineup.occupant(z, isServing: true)] = servingSpot(z) }
        return out
    }

    /// The serving-team spot for the player in zone `z`.
    static func servingSpot(_ z: Zone) -> LocalSpot {
        let base = BaseSpots.perimeter(against: .left)
        return switch z {
        case .z1: serverSpot
        case .z2: base.rightFront
        case .z3: base.middleFront
        case .z4: base.leftFront
        case .z5: base.leftBack
        case .z6: base.middleBack
        }
    }
}
