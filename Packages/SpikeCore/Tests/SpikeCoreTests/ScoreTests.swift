import Testing
@testable import SpikeCore

private struct Match {
    var settings = MatchSettings()
    var score: Score
    var lineups: [Lineup]

    init(homeStart: Int = 1, awayStart: Int = 1) {
        settings.teams = [TeamSettings(startingRotation: homeStart), TeamSettings(startingRotation: awayStart)]
        score = Score(settings: settings)
        var rng = SeededRNG(seed: 1)
        let s = settings
        lineups = TeamSide.allCases.map { side in
            Lineup(roster: RosterGenerator.make(team: side, gameType: .mens, system: .fiveOne, rng: &rng),
                   settings: s.team(side))
        }
    }

    @discardableResult
    mutating func rally(_ w: TeamSide) -> RallyResult {
        awardRally(to: w, score: &score, lineups: &lineups, settings: settings)
    }
}

@Test func deuce() {                                            // Review Focus 2
    var m = Match()
    for _ in 0..<14 { m.rally(.home); m.rally(.away) }
    #expect(m.score.points == [14, 14] && m.score.winner == nil)
    #expect(!m.rally(.home).matchWon)
    #expect(m.score.points == [15, 14] && m.score.winner == nil)   // 15–14 does not end it
    #expect(m.rally(.home).matchWon)
    #expect(m.score.points == [16, 14] && m.score.winner == .home)
}

@Test func longDeuce() {
    var m = Match()
    for _ in 0..<22 { m.rally(.home); m.rally(.away) }
    #expect(m.score.points == [22, 22] && m.score.winner == nil)
    #expect(!m.rally(.home).matchWon)
    #expect(m.rally(.home).matchWon)
    #expect(m.score.points == [24, 22] && m.score.winner == .home)
}

@Test func straightWin() {
    var m = Match()
    for i in 1...15 {
        let r = m.rally(.home)
        #expect(r.matchWon == (i == 15))
    }
    #expect(m.score.points == [15, 0] && m.score.winner == .home)
}

@Test func firstServerDoesNotRotateBeforeServing() {           // Review Focus 4
    var m = Match(homeStart: 4, awayStart: 2)
    #expect(m.score.serving == .home)
    #expect(m.lineups[0].rotation == 3 && m.lineups[1].rotation == 1)
    let first = m.rally(.home)
    #expect(!first.sideOut)
    #expect(m.lineups[0].rotation == 3 && m.score.serving == .home)
    let second = m.rally(.away)
    #expect(second.sideOut)
    #expect(m.lineups[1].rotation == 2 && m.score.serving == .away)
    #expect(m.lineups[0].rotation == 3)                         // the loser never rotates
}

@Test func serverStaysWhileWinning() {
    var m = Match()
    m.rally(.away)                                              // away sides out first
    let rotation = m.lineups[1].rotation
    for _ in 0..<5 { #expect(!m.rally(.away).sideOut) }
    #expect(m.lineups[1].rotation == rotation && m.score.serving == .away)
}
