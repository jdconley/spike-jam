import Testing
@testable import SpikeCore

private func fixture(_ system: OffenseSystem, _ rotation: Int, team: TeamSide = .home) -> (Lineup, Roster) {
    var rng = SeededRNG(seed: 1)
    let roster = RosterGenerator.make(team: team, gameType: .mens, system: system, rng: &rng)
    return (Lineup(roster: roster, settings: TeamSettings(system: system, startingRotation: rotation)), roster)
}

private func zoneMap(_ spots: [AthleteID: LocalSpot], _ lineup: Lineup, isServing: Bool) -> [Zone: LocalSpot] {
    var out: [Zone: LocalSpot] = [:]
    for (id, spot) in spots { out[lineup.zone(of: id, isServing: isServing)!] = spot }
    return out
}

private let setterTargetLocal = LocalFrame.toLocal(Court.setterTarget(team: .home).xz, team: .home)

private func distance(_ a: LocalSpot, _ b: LocalSpot) -> Float { a.distance(to: b) }

private func insideCourt(_ s: LocalSpot) -> Bool { (0...9).contains(s.d) && abs(s.l) <= 4.5 }

@Test(arguments: [OffenseSystem.fiveOne, .sixTwo], 1...6)    // Review Focus 1
func receiveIsLegal(system: OffenseSystem, rotation: Int) {
    let (lineup, roster) = fixture(system, rotation)
    let spots = Formations.receive(lineup, roster: roster)
    #expect(spots.count == 6)
    #expect(Set(spots.keys) == Set(lineup.onCourt(isServing: false).values))
    let byZone = zoneMap(spots, lineup, isServing: false)
    #expect(Overlap.violations(byZone, isServing: false).isEmpty)
    // Visibly legal, with room for players still settling onto their spots.
    #expect(Overlap.violations(byZone, isServing: false, margin: 0.25).isEmpty)
    // Everyone but the server must be inside the court at the serve.
    for (_, s) in spots { #expect(insideCourt(s)) }

    let passers = Formations.passers(lineup, roster: roster)
    #expect(passers.count == 3)
    #expect(Set(passers.map { roster[$0].position }) == [.outside, .libero])
    for p in passers { #expect((5.5...7.0).contains(spots[p]!.d)) }
    // A passing line across the court: one lane each, left, middle, right.
    let lanes = passers.map { spots[$0]!.l }.sorted()
    #expect(abs(lanes[0] + 3.2) <= 0.6 && abs(lanes[1]) <= 0.6 && abs(lanes[2] - 3.2) <= 0.6)

    // The setter hides as close to the target as the overlap rule allows.
    // In zone 1 the setter must stand behind the zone-2 passer, so at least
    // 4.8 m from the target; there it hides right behind that passer.
    let setter = lineup.settingSetter(isServing: false)
    if lineup.zone(of: setter, isServing: false) == .z1 {
        #expect(distance(spots[setter]!, setterTargetLocal) <= 5.25)
        #expect(spots[setter]!.d - byZone[.z2]!.d <= 0.4)
    } else {
        #expect(distance(spots[setter]!, setterTargetLocal) <= 4.5)
    }

    // Front-row non-passers wait near the net, ready to release.
    for z in [Zone.z4, .z3, .z2] {
        let id = lineup.occupant(z, isServing: false)
        if !passers.contains(id) { #expect((0.8...2.5).contains(spots[id]!.d)) }
    }
}

@Test(arguments: [OffenseSystem.fiveOne, .sixTwo], 1...6)
func servingIsLegal(system: OffenseSystem, rotation: Int) {
    let (lineup, roster) = fixture(system, rotation)
    let spots = Formations.serving(lineup, roster: roster)
    #expect(spots.count == 6)
    #expect(Set(spots.keys) == Set(lineup.onCourt(isServing: true).values))
    let byZone = zoneMap(spots, lineup, isServing: true)
    #expect(Overlap.violations(byZone, isServing: true).isEmpty)
    #expect(Overlap.violations(byZone, isServing: true, margin: 0.25).isEmpty)
    #expect(spots[lineup.server()]!.d >= 9.5)
    // The server serves from their own zone-1 lane.
    #expect(spots[lineup.server()]!.l > 0 && spots[lineup.server()]!.l < 4.5)
    for (id, s) in spots where id != lineup.server() { #expect(insideCourt(s)) }
    // The libero stays behind the 3 m line.
    if let l = spots[lineup.libero] { #expect(l.d >= 3.0) }
}

@Test func formationsAreTheSameForAway() {
    // Tables are team-local, so the away team uses the same spots.
    let (home, homeRoster) = fixture(.fiveOne, 4, team: .home)
    let (away, awayRoster) = fixture(.fiveOne, 4, team: .away)
    let h = zoneMap(Formations.receive(home, roster: homeRoster), home, isServing: false)
    let a = zoneMap(Formations.receive(away, roster: awayRoster), away, isServing: false)
    #expect(h == a)
}
