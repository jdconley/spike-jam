import Testing
@testable import SpikeCore

private func baseLayout(_ team: TeamSide) -> [Zone: LocalSpot] {
    Dictionary(uniqueKeysWithValues: Zone.allCases.map { ($0, LocalFrame.toLocal(Court.zoneSpot($0, team: team), team: team)) })
}

@Test func roundTrip() {
    for team in TeamSide.allCases {
        for s in [LocalSpot(d: 2, l: -3), LocalSpot(d: 8.7, l: 4.1), LocalSpot(d: 0.2, l: 0)] {
            #expect(LocalFrame.toLocal(LocalFrame.toWorld(s, team: team), team: team) == s)
        }
    }
    #expect(LocalFrame.toWorld(LocalSpot(d: 2, l: -3), team: .home) == Vec2(x: -2, z: -3))
    #expect(LocalFrame.toWorld(LocalSpot(d: 2, l: -3), team: .away) == Vec2(x: 2, z: 3))
}

@Test func baseZonesLegal() {
    for team in TeamSide.allCases {
        #expect(Overlap.violations(baseLayout(team), isServing: false).isEmpty)
        #expect(Overlap.violations(baseLayout(team), isServing: true).isEmpty)
    }
}

@Test func frontBehindBack() {
    var spots = baseLayout(.home)
    spots[.z4] = LocalSpot(d: 7, l: -3)
    spots[.z5] = LocalSpot(d: 6, l: -3)
    #expect(Overlap.violations(spots, isServing: false) == ["z4 not ahead of z5"])
}

@Test func lateralOrder() {
    var spots = baseLayout(.home)
    spots[.z3] = LocalSpot(d: 2, l: -3.5)
    #expect(Overlap.violations(spots, isServing: false) == ["z4 not left of z3"])
    spots = baseLayout(.home)
    spots[.z6] = LocalSpot(d: 6.5, l: 3.5)
    #expect(Overlap.violations(spots, isServing: false) == ["z6 not left of z1"])
}

@Test func serverExempt() {
    var spots = baseLayout(.home)
    spots[.z1] = LocalSpot(d: 6.5, l: -4)
    #expect(Overlap.violations(spots, isServing: true).isEmpty)
    // The rule compares neighbours only, so zone 1 is checked against 6
    // (and 2), not against 5.
    #expect(Overlap.violations(spots, isServing: false) == ["z6 not left of z1"])
    // Behind the end line is fine for the server, and only the server.
    spots = baseLayout(.home)
    spots[.z1] = LocalSpot(d: 9.6, l: 3)
    spots[.z2] = LocalSpot(d: 9.7, l: 3)
    #expect(Overlap.violations(spots, isServing: true).isEmpty)
    #expect(Overlap.violations(spots, isServing: false) == ["z2 not ahead of z1"])
}

@Test func marginEnforced() {
    var spots = baseLayout(.home)
    spots[.z3] = LocalSpot(d: 5.0, l: 0)
    spots[.z6] = LocalSpot(d: 5.05, l: 0)
    #expect(Overlap.violations(spots, isServing: false) == ["z3 not ahead of z6"])
    spots[.z6] = LocalSpot(d: 5.15, l: 0)
    #expect(Overlap.violations(spots, isServing: false).isEmpty)
    // Lateral too.
    spots = baseLayout(.home)
    spots[.z3] = LocalSpot(d: 2, l: 2.95)
    #expect(Overlap.violations(spots, isServing: false) == ["z3 not left of z2"])
}

@Test func zoneIncludesLibero() {
    var rng = SeededRNG(seed: 1)
    let roster = RosterGenerator.make(team: .home, gameType: .mens, system: .fiveOne, rng: &rng)
    let lineup = Lineup(roster: roster, settings: TeamSettings(system: .fiveOne, startingRotation: 3))
    let mb1 = roster.athletes[2].id, libero = roster.athletes[6].id
    // Rotation 3: MB1 is in zone 1 and serves; the libero is off.
    #expect(lineup.zone(of: mb1) == .z1)
    #expect(lineup.zone(of: mb1, isServing: true) == .z1)
    #expect(lineup.zone(of: libero, isServing: true) == nil)
    // Receiving, the libero takes zone 1 and MB1 is off court.
    #expect(lineup.zone(of: libero, isServing: false) == .z1)
    #expect(lineup.zone(of: mb1, isServing: false) == nil)
    #expect(lineup.zone(of: libero) == nil)
    for z in Zone.allCases {
        let id = lineup.onCourt(isServing: false)[z]!
        #expect(lineup.zone(of: id, isServing: false) == z)
    }
}
