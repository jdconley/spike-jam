/// An analytic ball flight under constant gravity, ported from the spike's
/// `Flight` without `simd`. Times are absolute match seconds.
public struct Flight: Codable, Equatable, Sendable {
    public var p0: Vec3
    public var v0: Vec3
    public var startTime: Double
    public var duration: Double

    public init(p0: Vec3, v0: Vec3, startTime: Double, duration: Double) {
        self.p0 = p0
        self.v0 = v0
        self.startTime = startTime
        self.duration = duration
    }

    public var endTime: Double { startTime + duration }

    static let g = Vec3(x: 0, y: Tuning.gravity, z: 0)

    /// The flight that leaves `from` at `startTime` and reaches `to` after
    /// `duration` seconds.
    public static func make(from: Vec3, to: Vec3, duration: Double, startTime: Double) -> Flight {
        let d = Float(duration)
        let v = (to - from - g * (0.5 * d * d)) * (1 / d)
        return Flight(p0: from, v0: v, startTime: startTime, duration: duration)
    }

    /// Like `make`, but if the flight crosses the net below `netClearance`
    /// it is lengthened (same endpoints) until it crosses at exactly that
    /// height. With fixed gravity the endpoints and duration fix the arc, so
    /// more time is the only way to a higher peak.
    public static func makeClearing(from: Vec3, to: Vec3, duration: Double, startTime: Double, netClearance: Float) -> Flight {
        let f = make(from: from, to: to, duration: duration, startTime: startTime)
        guard let y = f.heightAtNet(), y < netClearance else { return f }
        // Crossing fraction k of the way along: y = y0 + Δy·k − ½g·d²·k(1−k).
        let k = -from.x / (to.x - from.x)
        let need = netClearance - from.y - (to.y - from.y) * k
        let d2 = need / (-0.5 * Tuning.gravity * k * (1 - k))
        return make(from: from, to: to, duration: max(duration, Double(d2.squareRoot())), startTime: startTime)
    }

    public func position(at t: Double) -> Vec3 {
        let s = Float(t - startTime)
        return p0 + v0 * s + Flight.g * (0.5 * s * s)
    }

    /// The ball's height where it crosses x = 0 during the flight, or nil if
    /// it never does.
    public func heightAtNet() -> Float? {
        guard abs(v0.x) > 1e-6 else { return nil }
        let s = -p0.x / v0.x
        guard s >= 0 && Double(s) <= duration else { return nil }
        return position(at: startTime + Double(s)).y
    }

    /// The absolute time the ball passes height `y` on its way down, or nil
    /// if it never does after the start.
    public func timeDescending(through y: Float) -> Double? {
        let a = 0.5 * Tuning.gravity, b = v0.y, c = p0.y - y
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return nil }
        let r = disc.squareRoot()
        let s = max((-b - r) / (2 * a), (-b + r) / (2 * a))
        return s > 0 ? startTime + Double(s) : nil
    }
}
