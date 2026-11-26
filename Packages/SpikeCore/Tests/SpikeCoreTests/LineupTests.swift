import Testing
@testable import SpikeCore

// Named players by the roster's fixed index order (Task 4).
// 5-1: S, OH1, MB1, OPP, OH2, MB2, L.  6-2: S1, OH1, MB1, S2, OH2, MB2, L.
private func roster(_ system: OffenseSystem) -> Roster {
    var rng = SeededRNG(seed: 1)
    return RosterGenerator.make(team: .home, gameType: .mens, system: system, rng: &rng)
}
private let five = roster(.fiveOne), six = roster(.sixTwo)
private let S = five.athletes[0].id, OH1 = five.athletes[1].id, MB1 = five.athletes[2].id
private let OPP = five.athletes[3].id, OH2 = five.athletes[4].id, MB2 = five.athletes[5].id
private let L = five.athletes[6].id
private let S1 = six.athletes[0].id, S2 = six.athletes[3].id

private func lineup(_ system: OffenseSystem, start: Int) -> Lineup {
    Lineup(roster: system == .fiveOne ? five : six,
           settings: TeamSettings(system: system, startingRotation: start))
}

@Test func fiveOneRotationOne() {
    let l = lineup(.fiveOne, start: 1)
    #expect(l.baseOccupant(.z1) == S && l.baseOccupant(.z2) == OH1
         && l.baseOccupant(.z3) == MB1 && l.baseOccupant(.z4) == OPP
         && l.baseOccupant(.z5) == OH2 && l.baseOccupant(.z6) == MB2)
    #expect(l.onCourt(isServing: false)[.z6] == L)          // libero in for back-row MB2
    #expect(Set(l.attackers(isServing: false)) == [OH1, MB1, OPP])
}

@Test func fiveOneRotationFourSetterFrontRow() {
    let l = lineup(.fiveOne, start: 4)
    #expect(l.baseOccupant(.z4) == S && l.baseOccupant(.z3) == MB2
         && l.baseOccupant(.z2) == OH2 && l.baseOccupant(.z1) == OPP)
    #expect(Set(l.attackers(isServing: false)) == [MB2, OH2])  // two hitters + setter
}

@Test func setterPathThroughRotations() {
    var l = lineup(.fiveOne, start: 1)
    var zones: [Zone] = []
    for _ in 0..<6 { zones.append(Zone.allCases.first { l.baseOccupant($0) == S }!); l.rotate() }
    #expect(zones == [.z1, .z6, .z5, .z4, .z3, .z2])
    #expect(l.rotation == 0)                                    // wrapped
}

@Test func middleServesThenLiberoComesIn() {                    // Review Focus 1
    let l = lineup(.fiveOne, start: 3)                          // MB1 in zone 1
    #expect(l.server() == MB1)
    #expect(l.onCourt(isServing: true)[.z1] == MB1)
    #expect(!l.onCourt(isServing: true).values.contains(L))
    #expect(l.onCourt(isServing: false)[.z1] == L)
}

@Test func liberoNeverFrontRowNeverServes() {
    for system in [OffenseSystem.fiveOne, .sixTwo] {
        var l = lineup(system, start: 1)
        for _ in 0..<6 {
            for serving in [true, false] {
                let court = l.onCourt(isServing: serving)
                #expect(court.count == 6 && Set(court.values).count == 6)
                for (z, id) in court where id == L { #expect(!z.isFrontRow) }
            }
            #expect(l.server() != L)
            l.rotate()
        }
    }
}

@Test func sixTwoAlwaysOneBackRowSetter() {                     // Review Focus 3
    var l = lineup(.sixTwo, start: 1)
    for _ in 0..<6 {
        let setter = l.settingSetter(isServing: false)
        let zone = Zone.allCases.first { l.baseOccupant($0) == setter }!
        #expect(!zone.isFrontRow)
        let other = [S1, S2].first { $0 != setter }!
        #expect(l.attackers(isServing: false).contains(other))
        #expect(l.attackers(isServing: false).count == 3)
        l.rotate()
    }
}
