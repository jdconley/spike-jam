import Testing
@testable import SpikeCore

private func settings(_ i: Int) -> MatchSettings {
    var s = MatchSettings()
    s.seed = UInt64(i)
    s.gameType = i % 2 == 0 ? .mens : .womens
    s.tempo = Tempo.allCases[i % 3]
    let homeSystem: OffenseSystem = (i / 2) % 2 == 0 ? .fiveOne : .sixTwo
    let awaySystem: OffenseSystem = homeSystem == .fiveOne ? .sixTwo : .fiveOne
    s.teams = [TeamSettings(system: homeSystem, startingRotation: i % 6 + 1),
               TeamSettings(system: awaySystem, startingRotation: (i / 6) % 6 + 1)]
    s.firstServer = (i / 4) % 2 == 0 ? .home : .away
    return s
}

private let maxTicks = 60 * 60 * 30

@Test func soak() {
    var failures = 0, unfinished = 0
    for i in 1...200 {
        var s = GameState(settings: settings(i))
        #expect(checkInvariants(s).isEmpty)
        for _ in 0..<maxTicks {
            _ = step(&s, inputs: [])
            let problems = checkInvariants(s)
            if !problems.isEmpty {
                failures += 1
                Issue.record("match \(i) tick \(s.tick): \(problems)")
                break
            }
            if s.phase == .matchOver { break }
        }
        if s.phase != .matchOver { unfinished += 1 }
    }
    #expect(failures == 0)
    #expect(unfinished == 0)
}

@Test func deterministic() {
    func play(_ settings: MatchSettings) -> (GameState, [GameEvent]) {
        var s = GameState(settings: settings)
        var events: [GameEvent] = []
        for _ in 0..<maxTicks where s.phase != .matchOver { events += step(&s, inputs: []) }
        return (s, events)
    }
    let a = play(settings(17)), b = play(settings(17))
    #expect(a.0.phase == .matchOver)
    #expect(a.0 == b.0)
    #expect(a.1 == b.1)
}

@Test func differentSeedsDiffer() {
    func play(_ seed: UInt64) -> GameState {
        var settings = MatchSettings()
        settings.seed = seed
        var s = GameState(settings: settings)
        for _ in 0..<maxTicks where s.phase != .matchOver { _ = step(&s, inputs: []) }
        return s
    }
    let a = play(1), b = play(2)
    #expect(a.score.points != b.score.points || a.rallyCount != b.rallyCount)
}

@Test func invariantsCatchBrokenStates() {
    let good = GameState(settings: settings(3))
    #expect(checkInvariants(good).isEmpty)

    var overWithoutWinner = good
    overWithoutWinner.phase = .matchOver
    #expect(!checkInvariants(overWithoutWinner).isEmpty)

    var winnerStillPlaying = good
    winnerStillPlaying.score.points = [15, 3]
    winnerStillPlaying.score.winner = .home
    #expect(!checkInvariants(winnerStillPlaying).isEmpty)

    var tooManyPoints = good
    tooManyPoints.score.points = [17, 14]
    tooManyPoints.score.winner = .home
    tooManyPoints.phase = .matchOver
    #expect(!checkInvariants(tooManyPoints).isEmpty)

    var shouldHaveEnded = good
    shouldHaveEnded.score.points = [15, 10]
    #expect(!checkInvariants(shouldHaveEnded).isEmpty)

    var liberoServing = good
    let side = liberoServing.score.serving
    let libero = liberoServing.lineups[side.rawValue].libero
    let z1 = liberoServing.lineups[side.rawValue].onCourt(isServing: true)[.z1]!
    liberoServing.positions[libero] = Court.zoneSpot(.z1, team: side)
    liberoServing.positions[z1] = nil
    #expect(!checkInvariants(liberoServing).isEmpty)

    var duplicate = good
    let anyone = duplicate.positions.keys.first { $0.team == .home }!
    duplicate.positions[anyone] = nil
    #expect(!checkInvariants(duplicate).isEmpty)
}
