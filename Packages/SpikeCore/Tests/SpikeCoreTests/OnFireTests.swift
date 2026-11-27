import Testing
@testable import SpikeCore

/// Feeds `e` to the streaks and returns the fire events it made.
private func record(_ e: GameEvent, _ s: inout GameState) -> [GameEvent] {
    var events: [GameEvent] = []
    OnFire.record(e, &s, &events)
    return events
}

/// A kill by `hitter`: their attack, then the point.
private func kill(_ hitter: AthleteID, _ s: inout GameState) -> [GameEvent] {
    record(.touched(.attack, hitter, quality: 0.8), &s) + record(.point(hitter.team, .kill), &s)
}

@Test func threeKillsIgnites() {
    var s = GameState(settings: MatchSettings())
    let roster = s.rosters[TeamSide.home.rawValue]
    let oh1 = roster.ids(.outside)[0], oh2 = roster.ids(.outside)[1]
    #expect(kill(oh1, &s).isEmpty && kill(oh1, &s).isEmpty)
    #expect(kill(oh1, &s) == [.fire(oh1, on: true)])
    #expect(OnFire.isOnFire(oh1, s))
    // Still on fire with the next kill; nothing new to say.
    #expect(kill(oh1, &s).isEmpty)

    // A kill by someone else in between resets the streak.
    var t = GameState(settings: MatchSettings())
    _ = kill(oh1, &t)
    _ = kill(oh1, &t)
    _ = kill(oh2, &t)
    #expect(kill(oh1, &t).isEmpty && kill(oh1, &t).isEmpty)
    #expect(t.fire[oh1]?.killStreak == 2 && !OnFire.isOnFire(oh1, t))
    // A point to the other team doesn't (that only puts a fire out), but
    // OH1's own attack error does; a kill without this side's attack (a
    // free ball dropping) credits nobody.
    _ = record(.point(.away, .ace), &t)
    #expect(t.fire[oh1]?.killStreak == 2)
    _ = record(.touched(.attack, oh1, quality: 0.3), &t)
    _ = record(.point(.away, .attackError), &t)
    #expect(t.fire[oh1] == nil)
    _ = record(.touched(.attack, AthleteID(team: .away, index: 0), quality: 0.5), &t)
    _ = record(.point(.home, .kill), &t)
    #expect(t.fire.isEmpty)
}

@Test func liberoPerfects() {
    var s = GameState(settings: MatchSettings())
    let libero = s.lineups[TeamSide.home.rawValue].libero
    let oh = s.rosters[TeamSide.home.rawValue].ids(.outside)[0]
    // Not perfect breaks it; anyone else's perfect passes don't count.
    _ = record(.touched(.receive, libero, quality: 1), &s)
    _ = record(.touched(.dig, libero, quality: 0.97), &s)
    for _ in 0..<5 { _ = record(.touched(.receive, oh, quality: 1), &s) }
    #expect(s.fire[libero] == nil && s.fire[oh] == nil)
    #expect(record(.touched(.receive, libero, quality: 1), &s).isEmpty)
    #expect(record(.touched(.dig, libero, quality: 0.995), &s).isEmpty)
    #expect(record(.touched(.receive, libero, quality: 0.99), &s) == [.fire(libero, on: true)])
}

@Test func opponentPointEndsFire() {
    var s = GameState(settings: MatchSettings())
    let home = s.rosters[TeamSide.home.rawValue]
    let oh1 = home.ids(.outside)[0], libero = s.lineups[0].libero
    let away = s.rosters[TeamSide.away.rawValue].ids(.outside)[0]
    s.fire = [oh1: FireState(killStreak: 3, onFire: true), libero: FireState(perfectStreak: 4, onFire: true),
              away: FireState(killStreak: 3, onFire: true)]
    // Home scoring leaves its own fire alone and puts out away's.
    #expect(record(.point(.home, .serviceError), &s) == [.fire(away, on: false)])
    let out = record(.point(.away, .ace), &s)
    #expect(Set(out.map { "\($0)" }) == Set([GameEvent.fire(oh1, on: false), .fire(libero, on: false)].map { "\($0)" }))
    #expect(out.count == 2 && s.fire.isEmpty)
}

@Test func fireEffects() {
    let s = GameState(settings: MatchSettings())
    let roster = s.rosters[TeamSide.home.rawValue]
    let libero = roster[s.lineups[0].libero], hitter = roster[roster.ids(.outside)[0]]
    var passCold: Float = 0, passHot: Float = 0, powerCold: Float = 0, powerHot: Float = 0
    var a = SeededRNG(seed: 3), b = SeededRNG(seed: 3)
    for _ in 0..<300 {
        for (fire, pass) in [(false, false), (true, true)] {
            var rng = fire ? b : a
            let c = TouchContext(kind: .receive, toucher: libero, incomingQuality: 0.4, incomingPower: 0.9, reachSlack: 0.1,
                                 blockersAligned: 0, catchUp: 0, onFire: fire)
            let r = TouchModel.resolve(c, rng: &rng, settings: s.settings)
            if r.error == nil {
                if pass { #expect(r.quality >= 0.9); passHot += r.quality } else { passCold += r.quality }
            }
            let h = TouchContext(kind: .attack, toucher: hitter, incomingQuality: 0.8, incomingPower: 0, reachSlack: 1,
                                 blockersAligned: 1, catchUp: 0, onFire: fire)
            let ra = TouchModel.resolve(h, rng: &rng, settings: s.settings)
            if !ra.tip { if fire { powerHot += ra.power } else { powerCold += ra.power } }
            if fire { b = rng } else { a = rng }
        }
    }
    #expect(passHot > passCold && powerHot > powerCold)
}

@Test func botsCatchFire() {
    // Bots catch fire too (the plan's 200 matches cut to 8 for CI time;
    // hitters ignite many times a match).
    var settings = MatchSettings()
    settings.seed = 300
    let stats = runMatches(settings, count: 8)
    print("bot fires in 8 matches: \(stats.fires)")
    #expect(stats.fires >= 1)
    #expect(stats.unfinished == 0 && stats.invariantFailures == 0)
}
