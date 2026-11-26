/// Fixed court geometry. 18 m × 9 m, net at x = 0. Home stands at negative x;
/// away mirrors both x and z, so each team's left is −z from its own view.
public enum Court {
    public static let halfLength: Float = 9
    public static let halfWidth: Float = 4.5

    /// Mirrors a home-side point for `team`.
    static func mirror(_ v: Vec2, _ team: TeamSide) -> Vec2 {
        team == .home ? v : Vec2(x: -v.x, z: -v.z)
    }

    static func mirror(_ v: Vec3, _ team: TeamSide) -> Vec3 {
        team == .home ? v : Vec3(x: -v.x, y: v.y, z: -v.z)
    }

    /// Where each zone's player stands in this plan (plan 2 adds formations).
    public static func zoneSpot(_ z: Zone, team: TeamSide) -> Vec2 {
        let home: Vec2 = switch z {
        case .z4: Vec2(x: -2, z: -3)
        case .z3: Vec2(x: -2, z: 0)
        case .z2: Vec2(x: -2, z: 3)
        case .z5: Vec2(x: -6.5, z: -3)
        case .z6: Vec2(x: -6.5, z: 0)
        case .z1: Vec2(x: -6.5, z: 3)
        }
        return mirror(home, team)
    }

    /// Where passes and digs go, for the setter.
    public static func setterTarget(team: TeamSide) -> Vec3 {
        mirror(Vec3(x: -0.8, y: 2.55, z: 0.5), team)
    }

    /// Where a hitter in zone `z` contacts the set. Front row from the
    /// spike's `setOptions`; back row behind the 3 m line (unused until plan 3).
    public static func attackPoint(_ z: Zone, team: TeamSide) -> Vec3 {
        let home: Vec3 = switch z {
        case .z4: Vec3(x: -1.1, y: 3.15, z: -3.5)
        case .z3: Vec3(x: -0.6, y: 3.0, z: -0.3)
        case .z2: Vec3(x: -1.1, y: 3.15, z: 3.5)
        case .z5: Vec3(x: -3.6, y: 3.0, z: -3.0)
        case .z6: Vec3(x: -3.6, y: 3.0, z: 0)
        case .z1: Vec3(x: -3.6, y: 3.0, z: 3.0)
        }
        return mirror(home, team)
    }
}
