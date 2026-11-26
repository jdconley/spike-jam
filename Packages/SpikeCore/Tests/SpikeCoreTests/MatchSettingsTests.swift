import Foundation
import Testing
@testable import SpikeCore

@Test func netHeights() {
    #expect(GameType.mens.netHeight == 2.43)
    #expect(GameType.womens.netHeight == 2.24)
}

@Test func tempoScales() {
    #expect(Tempo.fast.flightScale == 1.2)
    #expect(Tempo.faster.flightScale == 1.0)
    #expect(Tempo.stupidFast.flightScale == 0.82)
}

@Test func defaults() {
    let s = MatchSettings()
    #expect(s.pointsToWin == 15 && s.winBy == 2)
    #expect(s.tempo == .faster && s.gameType == .mens)
    #expect(s.teams.count == 2)
    #expect(s.team(.home).system == .fiveOne && s.team(.away).system == .fiveOne)
    #expect(s.team(.home).startingRotation == 1)
    #expect(s.firstServer == .home)
    #expect(s.validate().isEmpty)
}

@Test func jsonRoundTrip() throws {
    var s = MatchSettings()
    s.gameType = .womens
    s.tempo = .stupidFast
    s.teams[1] = TeamSettings(system: .sixTwo, startingRotation: 4)
    s.seed = 99
    let data = try JSONEncoder().encode(s)
    #expect(try JSONDecoder().decode(MatchSettings.self, from: data) == s)
}

@Test func validateFindsProblems() {
    var s = MatchSettings()
    s.teams[0].startingRotation = 7
    s.pointsToWin = 0
    s.winBy = 0
    #expect(s.validate().count == 3)
    var t = MatchSettings()
    t.teams = [TeamSettings()]
    #expect(!t.validate().isEmpty)
}
