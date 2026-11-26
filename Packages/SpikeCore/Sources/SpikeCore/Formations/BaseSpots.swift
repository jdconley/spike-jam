/// Where an attack comes from, from the attacking team's own view: front
/// row zones 4, 3 and 2, and the back-row lanes behind the 3 m line in zones
/// 5 ("A"), 6 ("Pipe" and "Bic") and 1 ("D").
public enum AttackLane: String, Codable, Sendable, CaseIterable {
    case left, middle, right, backLeft, backMiddle, backRight

    public var zone: Zone {
        switch self {
        case .left: .z4
        case .middle: .z3
        case .right: .z2
        case .backLeft: .z5
        case .backMiddle: .z6
        case .backRight: .z1
        }
    }

    public var isBackRow: Bool { !zone.isFrontRow }
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

/// A role in the perimeter defense, by spot rather than by player.
public enum PerimeterRole: String, Codable, Sendable, CaseIterable {
    case leftFront, middleFront, rightFront, leftBack, middleBack, rightBack
}

extension PerimeterSpots {
    public subscript(_ role: PerimeterRole) -> LocalSpot {
        switch role {
        case .leftFront: leftFront
        case .middleFront: middleFront
        case .rightFront: rightFront
        case .leftBack: leftBack
        case .middleBack: middleBack
        case .rightBack: rightBack
        }
    }

    /// Left and right swapped, as seen across the court's centre line.
    var mirrored: PerimeterSpots {
        func m(_ s: LocalSpot) -> LocalSpot { LocalSpot(d: s.d, l: -s.l) }
        return PerimeterSpots(leftFront: m(rightFront), middleFront: m(middleFront), rightFront: m(leftFront),
                              leftBack: m(rightBack), middleBack: m(middleBack), rightBack: m(leftBack))
    }
}

/// Team-local spots for attacking, blocking and defending (spec §4.1).
public enum BaseSpots {
    /// Back-row takeoffs stay at least this deep: behind the 3 m line, with a
    /// margin for a player settling onto the spot.
    public static let backRowTakeoffDepth: Float = 3.1

    /// Where a hitter in `lane` starts the approach: outside the sideline for
    /// the pins, a few steps off the net for the middle, deep for back row.
    public static func approachStart(_ lane: AttackLane) -> LocalSpot {
        switch lane {
        case .left: LocalSpot(d: 4.3, l: -4.6)
        case .middle: LocalSpot(d: 3.8, l: 0.4)
        case .right: LocalSpot(d: 4.3, l: 4.6)
        case .backLeft: LocalSpot(d: 7.2, l: -3.4)
        case .backMiddle: LocalSpot(d: 7.2, l: -0.6)
        case .backRight: LocalSpot(d: 7.2, l: 3.4)
        }
    }

    /// The default set for `lane`, in world coordinates: the spike's set
    /// points for the front row (`Court.attackPoint`), and d 3.8 at the lane
    /// centre for the back row.
    public static func defaultSetPoint(_ lane: AttackLane, team: TeamSide) -> Vec3 {
        switch lane {
        case .left, .middle, .right:
            return Court.attackPoint(lane.zone, team: team)
        case .backLeft, .backMiddle, .backRight:
            let l: Float = lane == .backLeft ? -3.0 : lane == .backRight ? 3.0 : 0
            return LocalFrame.toWorld(LocalSpot(d: 3.8, l: l), team: team).atHeight(3.0)
        }
    }

    /// Where a hitter in `lane` leaves the floor for a set at `setPoint`
    /// (world): 0.6 m behind it and 0.2 m inside it. Back-row takeoffs are
    /// kept behind the 3 m line however tight the set is.
    public static func takeoff(_ lane: AttackLane, setPoint: Vec3, team: TeamSide) -> LocalSpot {
        let set = LocalFrame.toLocal(setPoint.xz, team: team)
        var t = LocalSpot(d: set.d + 0.6, l: set.l)
        if abs(t.l) > 0.2 { t.l -= t.l > 0 ? 0.2 : -0.2 } else { t.l = 0 }
        t.d = max(t.d, lane.isBackRow ? backRowTakeoffDepth : 0.5)
        return t
    }

    /// Where a blocker stands against a set at `setPoint`: on the net, lined
    /// up with the ball.
    public static func blockSpot(against setPoint: Vec3, defending: TeamSide) -> LocalSpot {
        let l = LocalFrame.toLocal(setPoint.xz, team: defending).l
        return LocalSpot(d: 0.45, l: min(max(l, -4.2), 4.2))
    }

    /// Perimeter defense against an attack from the attacker's `lane`. Their
    /// left comes down our right. The libero always takes left back.
    public static func perimeter(against lane: AttackLane) -> PerimeterSpots {
        switch lane {
        case .left, .backLeft: againstLeft
        // Mirrored, the line digger lands in left back: the libero's spot.
        case .right, .backRight: againstLeft.mirrored
        case .middle, .backMiddle: againstMiddle
        }
    }

    /// Who goes up to block against `lane`, by perimeter role.
    public static func blockers(against lane: AttackLane) -> [PerimeterRole] {
        switch lane {
        case .left, .backLeft: [.rightFront, .middleFront]
        case .right, .backRight: [.leftFront, .middleFront]
        case .middle, .backMiddle: [.middleFront]
        }
    }

    /// The lane a player attacks from by default.
    public static func defaultLane(for position: Position, frontRow: Bool) -> AttackLane {
        switch position {
        case .outside: frontRow ? .left : .backMiddle
        case .middle: frontRow ? .middle : .backMiddle
        case .opposite, .setter: frontRow ? .right : .backRight
        case .libero: .backMiddle    // never used: the libero doesn't attack
        }
    }

    /// Base defense before the other team sets: the front row spread on the
    /// net ready to block, the back row in perimeter base.
    public static let base = PerimeterSpots(
        leftFront: LocalSpot(d: 0.6, l: -3.0), middleFront: LocalSpot(d: 0.6, l: 0.0),
        rightFront: LocalSpot(d: 0.6, l: 3.0), leftBack: LocalSpot(d: 6.5, l: -3.3),
        middleBack: LocalSpot(d: 8.0, l: 0.0), rightBack: LocalSpot(d: 6.5, l: 3.3))

    // Against their left: our right-front sets the block on the line with the
    // middle closing; the left-front pulls off to about 3 m for tips; the
    // right back covers the line and tips behind the block; the middle back
    // plays deep in the seam; the libero digs cross-court in left back.
    static let againstLeft = PerimeterSpots(
        leftFront: LocalSpot(d: 3.0, l: -2.2), middleFront: LocalSpot(d: 0.45, l: 2.5),
        rightFront: LocalSpot(d: 0.45, l: 3.3), leftBack: LocalSpot(d: 6.8, l: -3.6),
        middleBack: LocalSpot(d: 8.3, l: 0.6), rightBack: LocalSpot(d: 5.8, l: 3.9))

    // Against the middle: the middle blocks alone, the pins pull off, and the
    // back row spreads wide and deep.
    static let againstMiddle = PerimeterSpots(
        leftFront: LocalSpot(d: 2.5, l: -3.2), middleFront: LocalSpot(d: 0.45, l: 0.0),
        rightFront: LocalSpot(d: 2.5, l: 3.2), leftBack: LocalSpot(d: 6.6, l: -3.0),
        middleBack: LocalSpot(d: 8.2, l: 0.0), rightBack: LocalSpot(d: 6.6, l: 3.0))
}
