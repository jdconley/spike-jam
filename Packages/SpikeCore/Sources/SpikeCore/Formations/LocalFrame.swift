/// A spot in a team's own frame: `d` metres from the net into its own court
/// (positive), `l` metres left to right as the team faces the net (negative
/// is left).
public struct LocalSpot: Codable, Hashable, Sendable {
    public var d: Float
    public var l: Float

    public init(d: Float, l: Float) {
        self.d = d
        self.l = l
    }

    public func distance(to o: LocalSpot) -> Float {
        let dd = d - o.d, dl = l - o.l
        return (dd * dd + dl * dl).squareRoot()
    }
}

/// Converts between world ground points and team-local spots. Home stands at
/// negative x facing +x, so `d = -x` and `l = z`; away mirrors both, so
/// `d = x` and `l = -z`.
public enum LocalFrame {
    public static func toWorld(_ s: LocalSpot, team: TeamSide) -> Vec2 {
        Vec2(x: -team.dir * s.d, z: team.dir * s.l)
    }

    public static func toLocal(_ v: Vec2, team: TeamSide) -> LocalSpot {
        LocalSpot(d: -team.dir * v.x, l: team.dir * v.z)
    }
}
