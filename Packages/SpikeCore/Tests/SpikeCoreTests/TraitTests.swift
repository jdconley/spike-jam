import Foundation
import Testing
@testable import SpikeCore

/// 50 rosters of each kind, seeded.
private func rosters() -> [Roster] {
    var rng = SeededRNG(seed: 77)
    var out: [Roster] = []
    for i in 0..<50 {
        let game: GameType = i % 2 == 0 ? .mens : .womens
        let system: OffenseSystem = (i / 2) % 2 == 0 ? .fiveOne : .sixTwo
        out.append(RosterGenerator.make(team: i % 3 == 0 ? .home : .away, gameType: game, system: system, rng: &rng))
    }
    return out
}

private func all(_ t: Traits) -> [Float] { [t.serve, t.pass, t.set, t.attack, t.block, t.defense, t.speed] }

@Test func liberoTraits() {
    for r in rosters() {
        let libero = r[r.ids(.libero)[0]]
        #expect(libero.traits.attack == 0 && libero.traits.block == 0)
        let average = r.athletes.map(\.traits.pass).reduce(0, +) / Float(r.athletes.count)
        #expect(libero.traits.pass > average)
    }
}

@Test func setterSets() {
    for r in rosters() {
        let best = r.athletes.filter { $0.position != .setter }.map(\.traits.set).max()!
        for id in r.ids(.setter) { #expect(r[id].traits.set > best) }
    }
}

@Test func middlesBlock() {
    for r in rosters() {
        func mean(_ p: Position) -> Float { r.ids(p).map { r[$0].traits.block }.reduce(0, +) / Float(r.ids(p).count) }
        #expect(mean(.middle) > mean(.outside))
    }
}

@Test func outsidesPassAndOppositesHit() {
    // Averaged over many rosters, each position's shape shows.
    let rs = rosters()
    func mean(_ p: Position, _ k: KeyPath<Traits, Float>) -> Float {
        let v = rs.flatMap { r in r.ids(p).map { r[$0].traits[keyPath: k] } }
        return v.reduce(0, +) / Float(v.count)
    }
    #expect(mean(.outside, \.pass) > mean(.middle, \.pass) + 0.2)
    #expect(mean(.outside, \.pass) > mean(.opposite, \.pass))
    #expect(mean(.opposite, \.attack) > mean(.setter, \.attack) + 0.2)
    #expect(mean(.opposite, \.block) > mean(.outside, \.block))
    #expect(mean(.middle, \.pass) < 0.5)
}

@Test func variety() {
    for r in rosters() {
        let traits = r.athletes.map(\.traits)
        for i in traits.indices {
            for j in traits.indices where j > i { #expect(traits[i] != traits[j]) }
        }
        #expect(r.athletes.allSatisfy { all($0.traits).allSatisfy { (0...1).contains($0) } })
    }
    // Two athletes of the same position on different rosters differ too.
    let outsides = rosters().map { $0[$0.ids(.outside)[0]].traits }
    #expect(Set(outsides.map(\.attack)).count > 40)
}

@Test func difficultyShifts() {
    #expect(Difficulty.allCases == [.easy, .medium, .hard])
    #expect(Difficulty.easy.traitShift == -0.12 && Difficulty.medium.traitShift == 0 && Difficulty.hard.traitShift == 0.08)
    #expect(Difficulty.easy.errorScale == 1.3 && Difficulty.medium.errorScale == 1.0 && Difficulty.hard.errorScale == 0.8)
}

@Test func settingsRoundTrip() throws {
    let d = MatchSettings()
    #expect(d.difficulty == .medium)
    #expect(d.humanSides.isEmpty)
    #expect(d.keepItClose == false)
    #expect(d.team(.home).difficulty == nil)

    var s = MatchSettings()
    s.difficulty = .hard
    s.humanSides = [.away, .home]
    s.keepItClose = true
    s.teams[1].difficulty = .easy
    let data = try JSONEncoder().encode(s)
    #expect(try JSONDecoder().decode(MatchSettings.self, from: data) == s)
}

@Test func humanSidesEncodeInOrder() throws {
    // A Set would encode in hash order; the settings are part of the shared
    // state, so they must encode the same bytes everywhere.
    var a = MatchSettings(), b = MatchSettings()
    a.humanSides = [.home, .away]
    var set = Set<TeamSide>(minimumCapacity: 64)
    set.insert(.away)
    set.insert(.home)
    b.humanSides = set
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(a) == encoder.encode(b))
    let text = String(decoding: try encoder.encode(a), as: UTF8.self)
    #expect(text.contains("\"humanSides\":[\"home\",\"away\"]") || text.contains("\"humanSides\":[0,1]"))
}

@Test func whoPlaysAtWhichLevel() {
    var s = MatchSettings()
    s.difficulty = .easy
    // No humans: both sides play at the match's level.
    #expect(s.difficulty(for: .home) == .easy && s.difficulty(for: .away) == .easy)
    // A human's AI teammates play at medium, so their mistakes stay fewer
    // than the easy opponents' (spec §4.9).
    s.humanSides = [.home]
    #expect(s.difficulty(for: .home) == .medium && s.difficulty(for: .away) == .easy)
    // A team setting overrides both.
    s.teams[0].difficulty = .hard
    #expect(s.difficulty(for: .home) == .hard)
}
