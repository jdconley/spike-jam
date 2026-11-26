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
        let base = servingBase
        return switch z {
        case .z1: serverSpot
        case .z2: base.rightFront
        case .z3: base.middleFront
        case .z4: base.leftFront
        case .z5: base.leftBack
        case .z6: base.middleBack
        }
    }

    static let servingBase = PerimeterSpots(
        leftFront: LocalSpot(d: 3.0, l: -2.2), middleFront: LocalSpot(d: 0.45, l: 2.5),
        rightFront: LocalSpot(d: 0.45, l: 3.3), leftBack: LocalSpot(d: 6.8, l: -3.6),
        middleBack: LocalSpot(d: 8.3, l: 0.6), rightBack: LocalSpot(d: 5.8, l: 3.9))
}

/// A defending team's six spots, by role in its own frame (spec §4.1:
/// perimeter defense, the libero in left back).
public struct PerimeterSpots: Codable, Equatable, Sendable {
    public var leftFront: LocalSpot
    public var middleFront: LocalSpot
    public var rightFront: LocalSpot
    public var leftBack: LocalSpot
    public var middleBack: LocalSpot
    public var rightBack: LocalSpot

    public init(leftFront: LocalSpot, middleFront: LocalSpot, rightFront: LocalSpot,
                leftBack: LocalSpot, middleBack: LocalSpot, rightBack: LocalSpot) {
        self.leftFront = leftFront
        self.middleFront = middleFront
        self.rightFront = rightFront
        self.leftBack = leftBack
        self.middleBack = middleBack
        self.rightBack = rightBack
    }
}
