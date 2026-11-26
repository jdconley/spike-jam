/// Serve-receive stacks and serving formations (spec §4.1). Every table is
/// team-local and legal for the overlap rule with room to spare, so a team
/// that has settled onto its spots is visibly legal at the serve.
public enum Formations {
    /// Where each on-court player stands to receive serve.
    public static func receive(_ lineup: Lineup, roster: Roster) -> [AthleteID: LocalSpot] {
        let spots = receiveSpots(lineup.system, rotation: lineup.rotation)
        var out: [AthleteID: LocalSpot] = [:]
        for z in Zone.allCases { out[lineup.occupant(z, isServing: false)] = spots[z.rawValue - 1] }
        return out
    }

    /// The three passers by default: the libero and both outsides (spec §4.1).
    /// Ordered by zone.
    public static func passers(_ lineup: Lineup, roster: Roster) -> [AthleteID] {
        Zone.allCases.map { lineup.occupant($0, isServing: false) }
            .filter { [.outside, .libero].contains(roster[$0].position) }
    }

    /// The receive spot of the player in zone `z`.
    static func receiveSpot(_ z: Zone, system: OffenseSystem, rotation: Int) -> LocalSpot {
        receiveSpots(system, rotation: rotation)[z.rawValue - 1]
    }

    /// Spots for zones 1–6, in that order, for 0-based `rotation`.
    static func receiveSpots(_ system: OffenseSystem, rotation: Int) -> [LocalSpot] {
        switch system {
        case .fiveOne: fiveOne[rotation]
        // In a 6-2 the setting setter is always back row and rotates 1, 6, 5,
        // then the other setter does the same: three stacks, used twice. Their
        // roles by zone match the 5-1's first three rotations, with the
        // front-row setter playing opposite.
        case .sixTwo: fiveOne[rotation % 3]
        }
    }

    private static func spots(_ z1: (Float, Float), _ z2: (Float, Float), _ z3: (Float, Float),
                              _ z4: (Float, Float), _ z5: (Float, Float), _ z6: (Float, Float)) -> [LocalSpot] {
        [z1, z2, z3, z4, z5, z6].map { LocalSpot(d: $0.0, l: $0.1) }
    }

    // Each table is (d, l) for zones 1, 2, 3, 4, 5, 6. The setter target is
    // at d 0.8, l 1.5. Passers stand at d 5.5–6.4 in three lanes.
    // 6-2 rotations 1–3 and 4–6 use tables R1–R3, with S2/S1 as the front-row
    // "opposite" and the other setter setting.
    static let fiveOne: [[LocalSpot]] = [
        // R1, 5-1 (6-2 R1, R4): setter in 1 hides right behind the right-front
        // OH, who passes the right lane; OPP and MB stack left-centre at the
        // net. The longest penetration: the rule keeps the setter behind the
        // zone-2 passer.
        spots((5.8, 1.0), (5.5, 3.0), (1.0, 0.4), (1.5, -0.6), (6.3, -3.0), (6.4, -0.1)),
        // R2, 5-1 (6-2 R2, R5): setter in 6 hides behind the OPP at the net;
        // the front-row OH (in 4) passes left, L middle, back-row OH right.
        spots((6.0, 3.2), (1.0, 1.2), (1.0, 0.0), (5.5, -3.2), (6.3, -0.3), (2.0, 0.3)),
        // R3, 5-1 (6-2 R3, R6): setter in 5 hides behind the MB, who tucks in
        // at the left sideline; the front-row OH (in 3) passes left, the
        // back-row OH middle, L right.
        spots((6.0, 3.0), (1.0, 3.0), (5.5, -3.0), (1.0, -4.1), (1.8, -0.6), (6.3, 0.0)),
        // R4, 5-1: setter front-left at the net, MB beside it; the front-row OH
        // (in 2) passes right; OPP hides deep behind the 2.
        spots((7.0, 4.0), (5.5, 3.0), (1.0, 0.6), (0.8, -0.4), (6.2, -3.2), (6.4, 0.0)),
        // R5, 5-1: setter front-middle at the net, MB to its right; the
        // front-row OH (in 4) passes left; OPP hides behind the setter, out
        // of the passing lanes.
        spots((6.0, 3.2), (1.0, 1.6), (0.8, 0.3), (5.5, -3.2), (6.3, -0.2), (2.5, 1.2)),
        // R6, 5-1: setter front-right at the net; the front-row OH (in 3)
        // passes left, MB tucks in at the left sideline with the OPP hiding
        // right behind it; back-row OH middle, L right.
        spots((6.0, 3.2), (0.8, 1.2), (5.5, -3.0), (1.0, -4.1), (2.2, -4.2), (6.3, 0.0)),
    ]
}
