import Testing
@testable import SpikeCore

@Test(arguments: [GameType.mens, .womens], [OffenseSystem.fiveOne, .sixTwo])
func rosterShape(game: GameType, system: OffenseSystem) {
    var rng = SeededRNG(seed: 11)
    let r = RosterGenerator.make(team: .home, gameType: game, system: system, rng: &rng)
    #expect(r.athletes.count == 7)
    #expect(Set(r.athletes.map(\.number)).count == 7)
    #expect(r.athletes.allSatisfy { (1...99).contains($0.number) })
    #expect(Set(r.athletes.map(\.skinTone)).count == 7)          // no two alike
    #expect(r.athletes.allSatisfy { (0..<10).contains($0.skinTone) })
    let range: ClosedRange<Float> = game == .mens ? 1.78...2.08 : 1.68...1.93
    #expect(r.athletes.allSatisfy { range.contains($0.heightM) })
    let tallest = r.ids(.middle).map { r[$0].heightM }.min()!
    #expect(tallest > r[r.ids(.libero)[0]].heightM)
    #expect(r.ids(.setter).count == (system == .fiveOne ? 1 : 2))
    #expect(r.ids(.opposite).count == (system == .fiveOne ? 1 : 0))
    #expect(r.athletes[6].position == .libero)
    #expect(r.athletes.allSatisfy { $0.id.team == .home })
}

@Test func rostersAreSeeded() {
    var a = SeededRNG(seed: 3), b = SeededRNG(seed: 3)
    #expect(RosterGenerator.make(team: .away, gameType: .mens, system: .fiveOne, rng: &a)
         == RosterGenerator.make(team: .away, gameType: .mens, system: .fiveOne, rng: &b))
}

@Test func indexOrderAndTags() {
    var rng = SeededRNG(seed: 2)
    let five = RosterGenerator.make(team: .away, gameType: .womens, system: .fiveOne, rng: &rng)
    #expect(five.athletes.map(\.position.tag) == ["S", "OH", "MB", "OPP", "OH", "MB", "L"])
    let six = RosterGenerator.make(team: .away, gameType: .womens, system: .sixTwo, rng: &rng)
    #expect(six.athletes.map(\.position.tag) == ["S", "OH", "MB", "S", "OH", "MB", "L"])
    #expect(six.athletes.enumerated().allSatisfy { $0.element.id == AthleteID(team: .away, index: $0.offset) })
    #expect(six.athletes.allSatisfy { !$0.name.isEmpty })
    let t = six.athletes.map(\.traits)
    #expect(t.allSatisfy { [$0.serve, $0.pass, $0.set, $0.attack, $0.block, $0.defense, $0.speed].allSatisfy { (0...1).contains($0) } })
}
