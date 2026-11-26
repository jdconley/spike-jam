import Testing
@testable import SpikeCore

@Test func statsAddUp() {
    let stats = runMatches(MatchSettings(), count: 20)
    #expect(stats.matches == 20)
    #expect(stats.invariantFailures == 0)
    #expect(stats.sideOutRate > 0 && stats.sideOutRate < 1)
    #expect(stats.avgTouchesPerRally >= 1)
    // Every rally ends in exactly one way.
    #expect(stats.aces + stats.serviceErrors + stats.kills + stats.attackErrors + stats.handlingErrors + stats.blocks == stats.rallies)
    #expect(stats.avgMargin >= 2)
}

@Test func statsAreSeeded() {
    var settings = MatchSettings()
    settings.seed = 40
    #expect(runMatches(settings, count: 5) == runMatches(settings, count: 5))
    settings.seed = 41
    #expect(runMatches(settings, count: 5) != runMatches(MatchSettings(), count: 5))
}
