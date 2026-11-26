import Foundation
import Testing
@testable import SpikeCore

/// A fresh match with `side` receiving in `rotation` (1...6).
private func receiving(_ rotation: Int, system: OffenseSystem = .fiveOne, game: GameType = .mens,
                       seed: UInt64 = 3) -> (GameState, TeamSide) {
    var settings = MatchSettings()
    settings.gameType = game
    settings.seed = seed
    settings.firstServer = .away
    settings.teams = [TeamSettings(system: system, startingRotation: rotation), TeamSettings()]
    return (GameState(settings: settings), .home)
}

/// Parks the defending front row at net zones (attacker's view), on the net.
private func park(_ s: inout GameState, defending: TeamSide, zones: [Float]) {
    let lineup = s.lineups[defending.rawValue]
    let front = [Zone.z4, .z3, .z2].map { lineup.occupant($0, isServing: s.isServing(defending)) }
    for (id, zone) in zip(front, zones) {
        // Attacker's l mirrors to the defender's own frame.
        let l = -PlayBook.zoneCenter(zone)
        s.motion[id] = Motion(pos: LocalFrame.toWorld(LocalSpot(d: 0.5, l: l), team: defending))
    }
}

@Test func badPassNoQuicks() {                                  // Review Focus 1
    for rotation in 1...6 {
        for system in [OffenseSystem.fiveOne, .sixTwo] {
            for game in GameType.allCases {
                var (s, team) = receiving(rotation, system: system, game: game)
                let live = liveCalls(s, team: team, passQuality: 0.3)
                #expect(!live.isEmpty)
                #expect(live.allSatisfy { !PlayBook.spec($0.1).needsGoodPass }, "\(live)")
                // Out of system: high balls only, and never a quick.
                #expect(live.allSatisfy { PlayBook.spec($0.1).tempo == .high || $0.1 == .pipe }, "\(live)")
                for _ in 0..<1000 {
                    let (_, call) = SetterAI.choose(&s, team: team, passQuality: 0.3)
                    #expect(!PlayBook.spec(call).needsGoodPass)
                }
            }
        }
    }
}

@Test func mediumPassFallsBack() {
    // Below the good-pass line the quicks aren't live: the outside's Hut
    // becomes a 4 and the middle's quick is dropped.
    var (s, team) = receiving(1)
    let lineup = s.lineups[team.rawValue]
    let oh = lineup.attackers(isServing: false).first { s.rosters[team.rawValue][$0].position == .outside }!
    let mb = lineup.attackers(isServing: false).first { s.rosters[team.rawValue][$0].position == .middle }!
    s.calls[team.rawValue].byAthlete[oh] = .hut
    let good = Dictionary(liveCalls(s, team: team, passQuality: 0.9), uniquingKeysWith: { a, _ in a })
    #expect(good[oh] == .hut && good[mb] == .one)
    let bad = Dictionary(liveCalls(s, team: team, passQuality: 0.5), uniquingKeysWith: { a, _ in a })
    #expect(bad[oh] == .four && bad[mb] == nil)
}

@Test func dumpOnlyFrontRow() {                                 // Review Focus 2
    for rotation in 1...6 {
        var (s, team) = receiving(rotation)
        let setter = s.lineups[team.rawValue].settingSetter(isServing: false)
        let live = liveCalls(s, team: team, passQuality: 0.9)
        let front = s.lineups[team.rawValue].zone(of: setter)!.isFrontRow
        #expect(front == (rotation >= 4))
        #expect(live.contains { $0.1 == .dump } == front, "rotation \(rotation): \(live)")
        #expect(live.allSatisfy { ($0.0 == setter) == ($0.1 == .dump) })
        var dumps = 0
        for _ in 0..<1000 {
            let (who, call) = SetterAI.choose(&s, team: team, passQuality: 0.9)
            #expect((who == setter) == (call == .dump))
            if call == .dump { dumps += 1 }
        }
        if front { #expect(dumps > 0 && dumps < 200) } else { #expect(dumps == 0) }
        // Two front-row hitters when the setter is front row, three otherwise.
        #expect(live.filter { !PlayBook.spec($0.1).lane.isBackRow && $0.1 != .dump }.count == (front ? 2 : 3))
    }
    // A 6-2 always sets from the back row: never a dump.
    for rotation in 1...6 {
        let (s, team) = receiving(rotation, system: .sixTwo)
        #expect(!liveCalls(s, team: team, passQuality: 1).contains { $0.1 == .dump })
    }
}

@Test func prefersOpenHitter() {
    var (s, team) = receiving(1)
    park(&s, defending: team.other, zones: [1, 1, 9])
    var four = 0, right = 0
    for _ in 0..<1000 {
        switch SetterAI.choose(&s, team: team, passQuality: 0.5).1 {
        case .four: four += 1
        case .five, .red: right += 1
        default: break
        }
    }
    #expect(right > four, "4: \(four), 5/Red: \(right)")
    // And the other way round.
    park(&s, defending: team.other, zones: [9, 9, 1])
    four = 0; right = 0
    for _ in 0..<1000 {
        switch SetterAI.choose(&s, team: team, passQuality: 0.5).1 {
        case .four: four += 1
        case .five, .red: right += 1
        default: break
        }
    }
    #expect(four > right, "4: \(four), 5/Red: \(right)")
}

@Test func fewerBlockersOnFasterSets() {
    var (s, team) = receiving(1)
    park(&s, defending: team.other, zones: [2, 5, 8])
    // The quick in front of the setter beats the block to the spot more
    // often than the high ball to the same side does.
    #expect(SetterAI.expectedBlockers(s, attacking: team, call: .one) < SetterAI.expectedBlockers(s, attacking: team, call: .five))
    #expect(SetterAI.expectedBlockers(s, attacking: team, call: .red) < SetterAI.expectedBlockers(s, attacking: team, call: .five))
    // Farther from the blockers, fewer of them.
    park(&s, defending: team.other, zones: [1, 1, 2])
    #expect(SetterAI.expectedBlockers(s, attacking: team, call: .five) < SetterAI.expectedBlockers(s, attacking: team, call: .four))
}

@Test func notAlwaysBest() {
    for rotation in 1...6 {
        var (s, team) = receiving(rotation)
        park(&s, defending: team.other, zones: [3, 5, 7])
        var counts: [AthleteID: Int] = [:]
        for _ in 0..<1000 { counts[SetterAI.choose(&s, team: team, passQuality: 0.85).0, default: 0] += 1 }
        #expect(counts.values.max()! < 800, "rotation \(rotation): \(counts.values.sorted())")
        #expect(counts.count >= 3)
    }
}

@Test func repetitionSpreadsTheSets() {
    var (s, team) = receiving(2)
    park(&s, defending: team.other, zones: [3, 5, 7])
    var fresh: [AthleteID: Int] = [:]
    for _ in 0..<2000 {
        s.notes.recentHitters[team.rawValue] = []
        fresh[SetterAI.choose(&s, team: team, passQuality: 0.85).0, default: 0] += 1
    }
    let favourite = fresh.max { $0.value < $1.value }!.key
    var repeated = 0
    for _ in 0..<2000 {
        s.notes.recentHitters[team.rawValue] = [favourite, favourite]
        if SetterAI.choose(&s, team: team, passQuality: 0.85).0 == favourite { repeated += 1 }
    }
    #expect(repeated < fresh[favourite]! * 3 / 4)
}

@Test func betterSettersPickBetter() {
    // A sharper setter (lower temperature) picks the best-scored option more
    // often, and the options' scores don't depend on the setter's touch.
    func bestShare(_ setTrait: Float) -> (Float, [Float]) {
        var (s, team) = receiving(1)
        park(&s, defending: team.other, zones: [1, 1, 9])
        let setter = s.lineups[team.rawValue].settingSetter(isServing: false)
        s.rosters[team.rawValue].athletes[setter.index].traits.set = setTrait
        let opts = SetterAI.options(s, team: team, passQuality: 0.85, setter: setter)
        let best = opts.max { $0.score < $1.score }!
        return (best.chance, opts.map(\.score))
    }
    let sharp = bestShare(0.95), loose = bestShare(0.5)
    #expect(sharp.1 == loose.1)
    #expect(sharp.0 > loose.0 + 0.05)
}

@Test func botTeamsMixTheirCalls() {
    var (s, team) = receiving(1, game: .womens)
    let lineup = s.lineups[team.rawValue]
    let middle = lineup.attackers(isServing: false).first { s.rosters[team.rawValue][$0].position == .middle }!
    var seen: [PlayCall: Int] = [:]
    for _ in 0..<500 {
        SetterAI.huddle(&s, team: team)
        if let c = s.calls[team.rawValue].byAthlete[middle] { seen[c, default: 0] += 1 }
        // Every call is one the hitter can run from where they are.
        for (id, c) in s.calls[team.rawValue].byAthlete {
            let z = lineup.zone(of: id, isServing: false)!
            #expect(TeamCalls.canRun(c, s.rosters[team.rawValue][id].position, frontRow: z.isFrontRow, system: .fiveOne))
        }
    }
    #expect(seen.count == 4)
    #expect(seen.max { $0.value < $1.value }!.key == .slide)
}

@Test func teamCallsDefaults() {
    for rotation in 1...6 {
        for game in GameType.allCases {
            let (s, team) = receiving(rotation, game: game)
            let lineup = s.lineups[team.rawValue], roster = s.rosters[team.rawValue]
            let calls = TeamCalls.defaults(lineup: lineup, roster: roster, game: game)
            for id in lineup.attackers(isServing: false) {
                let p = roster[id].position
                #expect(calls.byAthlete[id] == PlayBook.defaults(game)[p == .setter ? .opposite : p])
            }
            #expect(calls.byAthlete[lineup.libero] == nil)
            #expect(s.calls[team.rawValue] == calls)
        }
    }
}

@Test func combosApply() {
    var (s, team) = receiving(1)
    s.calls[team.rawValue].apply(.slideRed, lineup: s.lineups[team.rawValue], roster: s.rosters[team.rawValue], isServing: false)
    let live = Dictionary(liveCalls(s, team: team, passQuality: 0.9), uniquingKeysWith: { a, _ in a })
    let roster = s.rosters[team.rawValue]
    for (id, call) in live where !PlayBook.spec(call).lane.isBackRow {
        switch roster[id].position {
        case .middle: #expect(call == .slide)
        case .opposite: #expect(call == .red)
        default: break
        }
    }
    s.calls[team.rawValue].apply(.tandem, lineup: s.lineups[team.rawValue], roster: roster, isServing: false)
    let tandem = Dictionary(liveCalls(s, team: team, passQuality: 0.9), uniquingKeysWith: { a, _ in a })
    #expect(tandem.values.contains(.one) && tandem.values.contains(.thirtyTwo))
}

@Test func callsCodeByteStable() throws {
    let (a, team) = receiving(2)
    var b = a
    var rebuilt: [AthleteID: PlayCall] = [:]
    rebuilt.reserveCapacity(100)
    for (k, v) in a.calls[team.rawValue].byAthlete.sorted(by: { $0.key.index > $1.key.index }) { rebuilt[k] = v }
    b.calls[team.rawValue].byAthlete = rebuilt
    #expect(a == b)
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    #expect(try e.encode(a) == e.encode(b))
    #expect(try JSONDecoder().decode(GameState.self, from: e.encode(a)) == a)
}

@Test func setsFollowTheGame() {                                 // womensUsesSlide
    // The 500-match runs of the rate tests (at least the plan's 200).
    func middleSets(_ game: GameType) -> [PlayCall] {
        let stats = bandRuns[game]!
        let middle: Set<PlayCall> = [.one, .thirtyOne, .backOne, .slide]
        return stats.setCalls.filter { middle.contains($0.key) }.sorted { $0.value > $1.value }.map(\.key)
    }
    let women = middleSets(.womens), men = middleSets(.mens)
    print("middle sets, women: \(women), men: \(men)")
    #expect(women.prefix(2).contains(.slide))
    #expect(men.prefix(2).contains(.one))
}
