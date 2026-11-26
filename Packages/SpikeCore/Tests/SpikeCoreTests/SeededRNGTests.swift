import Testing
@testable import SpikeCore

@Test func splitMix64KnownValue() {
    var r = SeededRNG(seed: 0)
    #expect(r.next() == 0xE220A8397B1DCDAF)
}

@Test func sameSeedSameSequence() {
    var a = SeededRNG(seed: 42), b = SeededRNG(seed: 42)
    for _ in 0..<1000 { #expect(a.next() == b.next()) }
}

@Test func unitAndRanges() {
    var r = SeededRNG(seed: 7)
    for _ in 0..<10_000 {
        let u = r.unit(); #expect(u >= 0 && u < 1)
        let f = r.float(in: -2...3); #expect(f >= -2 && f <= 3)
        let i = r.int(in: 3..<9); #expect(i >= 3 && i < 9)
    }
    var c = SeededRNG(seed: 9)
    let hits = (0..<20_000).filter { _ in c.chance(0.25) }.count
    #expect(abs(Float(hits) / 20_000 - 0.25) < 0.02)
}

@Test func copiesAreIndependent() {
    var a = SeededRNG(seed: 5); _ = a.next()
    var b = a
    #expect(a.next() == b.next())
}
