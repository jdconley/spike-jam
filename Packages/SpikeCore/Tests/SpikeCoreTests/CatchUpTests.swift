import Testing
@testable import SpikeCore

/// A simulated human: every touch on `side` is theirs, all with the same
/// timing grade.
struct FixedTiming: TouchSource {
    let side: TeamSide
    let timing: Float

    func quality(for c: PendingContact, _ s: GameState, rng: inout SeededRNG) -> Float? {
        c.team == side ? timing : nil
    }
}

/// A human who plays only the listed athletes.
struct Plays: TouchSource {
    let athletes: Set<AthleteID>

    func quality(for c: PendingContact, _ s: GameState, rng: inout SeededRNG) -> Float? {
        c.athlete.map { athletes.contains($0) } == true ? 0.7 : nil
    }
}

private func solo(_ human: TeamSide = .home, catchUp: Bool = true) -> MatchSettings {
    var settings = MatchSettings()
    settings.humanSides = [human]
    settings.catchUp = catchUp
    return settings
}

private func state(_ settings: MatchSettings, home: Int, away: Int) -> GameState {
    var s = GameState(settings: settings)
    s.score.points = [home, away]
    return s
}

@Test func zeroWhenClose() {
    for (home, away) in [(7, 7), (8, 7), (7, 8), (0, 0), (14, 13)] {
        let level = CatchUp.level(state(solo(), home: home, away: away))
        #expect(level[.home] == 0 && level[.away] == 0, "\(home)–\(away)")
    }
    // It starts at a 2-point margin and grows with the gap.
    let two = CatchUp.level(state(solo(), home: 5, away: 7))
    #expect(two[.home]! > 0 && two[.away]! < 0)
    let four = CatchUp.level(state(solo(), home: 5, away: 9))
    #expect(four[.home]! > two[.home]!)
    #expect(abs(two[.home]! - 0.2) < 1e-6 && abs(four[.home]! - 0.6) < 1e-6)
}

@Test func boundedAtMatchPoint() {                               // Review Focus 3
    // The human (home) leads 14–8: the AI trails and gets its biggest boost,
    // exactly what it gets at 10–4.
    let matchPoint = CatchUp.level(state(solo(), home: 14, away: 8))
    let early = CatchUp.level(state(solo(), home: 10, away: 4))
    #expect(matchPoint[.away] == 1 && early[.away] == 1)
    #expect(matchPoint == early)
    // Never more than 1, however big the gap.
    for gap in 0...15 {
        for (h, a) in [(gap, 0), (0, gap)] {
            let l = CatchUp.level(state(solo(), home: h, away: a))
            #expect(abs(l[.home]!) <= 1 && abs(l[.away]!) <= 1)
            #expect(l[.home]! == -l[.away]!)
        }
    }
    // The human leading 14–13: no nudge at all.
    #expect(CatchUp.level(state(solo(), home: 14, away: 13))[.away] == 0)
    // And no game-point bonus anywhere else: the AI's touch at 14–8 rolls
    // exactly as at 10–4.
    var a = state(solo(), home: 14, away: 8), b = state(solo(), home: 10, away: 4)
    b.rng = a.rng
    let server = a.lineups[TeamSide.away.rawValue].server()
    for kind in [TouchKind.serve, .receive, .set, .attack, .dig, .block] {
        let ra = Rally.touch(kind, server, &a, nil, quality: 0.6, power: 0.6, slack: 0.2, blockers: 1)
        let rb = Rally.touch(kind, server, &b, nil, quality: 0.6, power: 0.6, slack: 0.2, blockers: 1)
        #expect(ra == rb)
    }
}

@Test func humansUntouched() {                                   // Review Focus 4
    let human = Athlete(id: AthleteID(team: .home, index: 2), name: "Test Human", number: 9, position: .outside, heightM: 1.9,
                        skinTone: 1, traits: Traits(serve: 0.5, pass: 0.5, set: 0.5, attack: 0.5, block: 0.5, defense: 0.5, speed: 0.5))
    for kind in [TouchKind.serve, .receive, .set, .attack, .dig, .block] {
        for timing: Float in [0, 0.45, 0.75, 1] {
            var results: [TouchResult] = []
            for level: Float in [-1, 0, 1] {
                var rng = SeededRNG(seed: 31)
                let c = TouchContext(kind: kind, toucher: human, incomingQuality: 0.6, incomingPower: 0.7, reachSlack: 0.1,
                                     blockersAligned: 2, catchUp: level, timing: timing)
                results.append(contentsOf: (0..<50).map { _ in TouchModel.resolve(c, rng: &rng, settings: solo()) })
            }
            #expect(Array(results[0..<50]) == Array(results[50..<100]) && Array(results[50..<100]) == Array(results[100..<150]))
        }
    }
    // Through the rally too: a human's touch at any score rolls the same.
    let source = FixedTiming(side: .home, timing: 0.8)
    let base = state(solo(), home: 0, away: 0)
    let id = base.lineups[TeamSide.home.rawValue].server()
    var outcomes: [TouchResult] = []
    for (h, a) in [(0, 0), (2, 9), (9, 2), (14, 8)] {
        var s = base
        s.score.points = [h, a]
        outcomes.append(Rally.touch(.attack, id, &s, source, quality: 0.6, power: 0, slack: 1, blockers: 1))
    }
    #expect(Set(outcomes.map(\.quality)).count == 1 && Set(outcomes.map(\.tip)).count == 1)
    #expect(outcomes.allSatisfy { $0 == outcomes[0] })
}

@Test func keepItCloseBotsOnly() {
    var settings = MatchSettings()
    settings.humanSides = [.home, .away]
    // Off by default with humans on both sides.
    #expect(CatchUp.level(state(settings, home: 3, away: 11)) == [.home: 0, .away: 0])
    settings.keepItClose = true
    var s = state(settings, home: 3, away: 11)
    let level = CatchUp.level(s)
    #expect(level[.home] == 1 && level[.away] == -1)
    // Each side has one human; everyone else is a bot.
    let homeHuman = s.lineups[0].server(), awayHuman = s.lineups[1].server()
    let source = Plays(athletes: [homeHuman, awayHuman])
    for side in TeamSide.allCases {
        for z in Zone.allCases {
            let id = s.lineups[side.rawValue].occupant(z, isServing: s.isServing(side))
            let c = Rally.context(.dig, id, &s, source, quality: 0.5, power: 0.5, slack: 0.3, blockers: 0)
            if id == homeHuman || id == awayHuman {
                #expect(c.isHuman && c.catchUp == 0)
            } else {
                #expect(!c.isHuman && c.catchUp == level[side]!)
            }
        }
    }
    // Bot against bot, never.
    #expect(CatchUp.level(state(MatchSettings(), home: 0, away: 12)) == [.home: 0, .away: 0])
    // And off when the solo player turns it off.
    #expect(CatchUp.level(state(solo(catchUp: false), home: 0, away: 12)) == [.home: 0, .away: 0])
}

/// Matches with a simulated human of `skill` playing every home touch
/// through real inputs (`SimHuman`, "ball"), against medium AI. Plan 4
/// replaced plan 3's stand-in (a fixed timing grade on every touch, no
/// inputs) with it. The skills stand where the stand-in's 0.7, 0.85 and 0.6
/// did (a human a little better than the AI, a strong one and a weak one);
/// the assertions are plan 3's.
private func humanRuns(_ skill: Float, catchUp: Bool, count: Int, seed: UInt64) -> MatchStats {
    var settings = solo(catchUp: catchUp)
    settings.seed = seed
    return runParallel(settings, count: count, humans: [SimHuman(id: HumanID(raw: 1), team: .home, skill: skill)])
}

private let closeOn = humanRuns(0.8, catchUp: true, count: 300, seed: 7000)
private let closeOff = humanRuns(0.8, catchUp: false, count: 300, seed: 7000)
private let goodHuman = humanRuns(0.9, catchUp: true, count: 200, seed: 8000)
private let poorHuman = humanRuns(0.3, catchUp: true, count: 200, seed: 8000)

@Test func closesTheGap() {                                         // catchUpThroughInputs
    print("0.8 human: catch-up off margin \(closeOff.avgMargin), home wins \(closeOff.homeWinRate); "
          + "on margin \(closeOn.avgMargin), home wins \(closeOn.homeWinRate)")
    #expect(closeOn.unfinished == 0 && closeOff.unfinished == 0)
    #expect(closeOn.invariantFailures == 0)
    #expect(closeOn.avgMargin < closeOff.avgMargin)
    // Win by 2 floors every margin at 2, so the gap the catch-up can close is
    // the margin beyond it: that is at least 30% smaller. (The whole mean
    // margin 30% smaller would put nearly every match at 2, which a bounded
    // catch-up that never flips a match can't do.)
    #expect(closeOn.avgMargin - 2 <= 0.7 * (closeOff.avgMargin - 2))
}

@Test func skillStillWins() {
    print("with catch-up: 0.9 human wins \(goodHuman.homeWinRate), 0.3 human wins \(poorHuman.homeWinRate)")
    #expect(goodHuman.homeWinRate >= poorHuman.homeWinRate + 0.2)
}

@Test func skillMatters() {
    // Through real inputs: the better human times far more touches PERFECT
    // and wins more against medium AI.
    let good = goodHuman.gradeRate(.perfect), poor = poorHuman.gradeRate(.perfect)
    print("PERFECT: 0.9 human \(good), 0.3 human \(poor); misses \(goodHuman.gradeRate(.miss)), \(poorHuman.gradeRate(.miss))")
    #expect(good >= poor + 0.25)
    #expect(goodHuman.homeWinRate > poorHuman.homeWinRate)
    #expect(goodHuman.unfinished == 0 && poorHuman.unfinished == 0)
    #expect(goodHuman.invariantFailures == 0 && poorHuman.invariantFailures == 0)
    #expect(goodHuman.overlapViolations == 0 && poorHuman.overlapViolations == 0)
}

@Test func neverFlips() {                                           // catchUpThroughInputs
    // Of the matches the human led by 6 or more at some point, they win at
    // least 85%, catch-up and all.
    let runs = [closeOn, goodHuman, poorHuman]
    let leads = runs.map { $0.bigLeads[TeamSide.home.rawValue] }.reduce(0, +)
    let lost = runs.map { $0.bigLeadsLost[TeamSide.home.rawValue] }.reduce(0, +)
    print("human 6-point leads: \(leads), lost: \(lost)")
    #expect(leads > 50)
    #expect(Double(lost) <= 0.15 * Double(leads))
}
