import Testing
@testable import SpikeCore

/// Steps until `stop` returns true for an event, or `limit` ticks pass.
@discardableResult
private func run(_ s: inout GameState, limit: Int = 60 * 60 * 30, until stop: (GameEvent) -> Bool) -> [GameEvent] {
    var all: [GameEvent] = []
    for _ in 0..<limit {
        let events = step(&s, inputs: [])
        all += events
        if events.contains(where: stop) { break }
    }
    return all
}

private func isServe(_ e: GameEvent) -> Bool { if case .served = e { true } else { false } }
private func isPoint(_ e: GameEvent) -> Bool { if case .point = e { true } else { false } }
private func isWin(_ e: GameEvent) -> Bool { if case .matchWon = e { true } else { false } }

@Test func firstServeHappens() {
    var s = GameState(settings: MatchSettings())
    let events = run(&s, limit: 200, until: isServe)
    guard case .served(let server) = events.last else { Issue.record("no serve"); return }
    #expect(abs(s.tick - Int(0.8 * 60)) <= 1)
    #expect(server == s.lineups[TeamSide.home.rawValue].baseOccupant(.z1))
    #expect(s.phase == .rally && s.ball != nil && s.pending != nil)
}

@Test func rallyEndsWithOnePoint() {
    var s = GameState(settings: MatchSettings())
    run(&s, limit: 200, until: isServe)
    let events = run(&s, limit: 60 * 60, until: isPoint)
    #expect(events.filter(isPoint).count == 1)
    #expect(s.score.points.reduce(0, +) == 1)
    #expect(s.rallyCount == 1)
    guard case .deadBall = s.phase else { Issue.record("expected dead ball, got \(s.phase)"); return }
    // Nothing else scores before the next serve.
    let gap = run(&s, limit: 60 * 10, until: isServe)
    #expect(gap.filter(isPoint).isEmpty)
    #expect(s.score.points.reduce(0, +) == 1)
}

@Test(arguments: [GameType.mens, .womens])                     // Review Focus 5
func flightsClearTheNet(game: GameType) {
    var checkedNet = 0
    for seed in 1...50 {
        var settings = MatchSettings()
        settings.gameType = game
        settings.tempo = .stupidFast
        settings.seed = UInt64(seed)
        settings.teams = [TeamSettings(system: seed % 2 == 0 ? .sixTwo : .fiveOne, startingRotation: seed % 6 + 1),
                          TeamSettings(startingRotation: (seed + 3) % 6 + 1)]
        var s = GameState(settings: settings)
        for _ in 0..<(60 * 60 * 30) {
            let before = s.ball
            let events = step(&s, inputs: [])
            if let ball = s.ball, ball != before {
                #expect(ball.duration >= Tuning.dt)
                let crossing = events.contains {
                    switch $0 {
                    case .served, .touched(.attack, _, _): true
                    default: false
                    }
                }
                if crossing && !s.lastFlightWasNetError {
                    let h = ball.heightAtNet()
                    #expect(h != nil && h! > game.netHeight, "seed \(seed) tick \(s.tick): net height \(String(describing: h))")
                    checkedNet += 1
                }
            }
            if s.phase == .matchOver { break }
        }
        #expect(s.phase == .matchOver)
    }
    #expect(checkedNet > 1000)
}

@Test func fullMatchCompletes() {
    var s = GameState(settings: MatchSettings())
    let events = run(&s, until: isWin)
    #expect(s.phase == .matchOver)
    #expect(events.filter(isWin).count == 1)
    guard let w = s.score.winner else { Issue.record("no winner"); return }
    #expect(events.last == .matchWon(w))
    #expect(s.score.points(w) >= 15 && s.score.points(w) - s.score.points(w.other) >= 2)
    // The match stays over.
    for _ in 0..<120 { #expect(step(&s, inputs: []).isEmpty) }
}

@Test func positionsFollowLiberoSwaps() {
    var settings = MatchSettings()
    settings.seed = 7
    var s = GameState(settings: settings)
    var liberoIns = 0
    for _ in 0..<(60 * 60 * 30) {
        for e in step(&s, inputs: []) {
            if case .liberoIn(let l, let m) = e {
                liberoIns += 1
                #expect(s.rosters[l.team.rawValue][l].position == .libero)
                #expect(s.rosters[m.team.rawValue][m].position == .middle)
                #expect(s.positions[l] != nil && s.positions[m] == nil)
            }
        }
        for side in TeamSide.allCases {
            let court = s.lineups[side.rawValue].onCourt(isServing: s.score.serving == side)
            let onCourt = Set(s.motion.keys.filter { $0.team == side })
            #expect(onCourt == Set(court.values))
            // Players move now, but always on their own side.
            for id in court.values { #expect(LocalFrame.toLocal(s.motion[id]!.pos, team: side).d >= 0.2 - 1e-3) }
        }
        if s.phase == .matchOver { break }
    }
    #expect(liberoIns > 0)
}

@Test func courtMirrors() {
    #expect(Court.zoneSpot(.z4, team: .home) == Vec2(x: -2, z: -3))
    #expect(Court.zoneSpot(.z1, team: .away) == Vec2(x: 6.5, z: -3))
    #expect(Court.setterTarget(team: .away) == Vec3(x: 0.8, y: 2.55, z: -1.5))
    #expect(Court.attackPoint(.z2, team: .home) == Vec3(x: -1.1, y: 3.15, z: 3.5))
    #expect(Court.attackPoint(.z4, team: .away) == Vec3(x: 1.1, y: 3.15, z: 3.5))
}
