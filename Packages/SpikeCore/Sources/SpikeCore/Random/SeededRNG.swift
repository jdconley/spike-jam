/// SplitMix64: a tiny, fast, seedable generator whose whole state is one
/// `UInt64`, so it copies and serializes with the game state.
public struct SeededRNG: RandomNumberGenerator, Codable, Hashable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A float in [0, 1), from the top 24 bits.
    public mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    public mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    /// A uniform integer in `range`, by multiply-high (no modulo).
    public mutating func int(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty, "int(in:) needs a non-empty range")
        let span = UInt64(range.upperBound - range.lowerBound)
        return range.lowerBound + Int(span.multipliedFullWidth(by: next()).high)
    }

    public mutating func chance(_ p: Float) -> Bool {
        unit() < p
    }
}
