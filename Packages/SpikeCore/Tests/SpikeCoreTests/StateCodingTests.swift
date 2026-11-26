import Foundation
import Testing
@testable import SpikeCore

/// The same state must always encode to the same bytes, whatever order its
/// dictionaries were built in, so snapshot hashes and replay diffs are stable.
@Test func encodingIsByteStable() throws {
    var settings = MatchSettings()
    settings.seed = 12
    var a = GameState(settings: settings)
    for _ in 0..<2_000 { _ = step(&a, inputs: []) }

    // Same contents, different insertion order and capacity, so a different
    // internal layout and iteration order.
    var b = a
    var rebuilt: [AthleteID: Vec2] = [:]
    rebuilt.reserveCapacity(512)
    for (id, spot) in a.positions.sorted(by: { ($0.key.team.rawValue, $0.key.index) > ($1.key.team.rawValue, $1.key.index) }) {
        rebuilt[id] = spot
    }
    b.positions = rebuilt
    #expect(a == b)

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let bytesA = try encoder.encode(a), bytesB = try encoder.encode(b)
    #expect(bytesA == bytesB)
    #expect(try JSONDecoder().decode(GameState.self, from: bytesA) == a)
}
