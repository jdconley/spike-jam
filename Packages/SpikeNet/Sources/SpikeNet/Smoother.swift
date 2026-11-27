import SpikeCore

/// Eases what's drawn from an old prediction into a corrected one (spec §5.3), so a correction
/// is never a jump: the drawn ball and players carry the difference as an offset that falls to
/// nothing over `duration`, easing out. A correction during another adds to what's left of it.
///
/// The offsets move a step at a time, but the app draws between steps, so the drawn ball's flight
/// carries the offset's rate too, and the drawn players, which the app interpolates, get the
/// offset as of each state's own time: either way it changes smoothly from frame to frame.
///
/// It only changes what's drawn, never the prediction itself.
public struct Smoother: Sendable {
    /// Seconds (spec: 100–200 ms).
    public static let duration: Double = 0.150
    /// The fastest an offset may close, in metres a second, so a correction adds little to the
    /// drawn ball's own speed; one of more than about 0.75 m takes a little longer than
    /// `duration`.
    public static let maxSpeed: Float = 10

    struct Offset: Sendable {
        /// At the correction.
        var start: Vec3
        /// As of `time`, and as of the step before (`lastTime`).
        var now: Vec3
        var time: Double
        var last: Vec3
        var lastTime: Double

        init(_ o: Vec3, at t: Double) {
            start = o
            now = o
            time = t
            last = o
            lastTime = t
        }

        /// Metres a second, over the latest step.
        var rate: Vec3 { time > lastTime ? (now - last) * Float(1 / (time - lastTime)) : .zero }

        /// As of `t`, near `time`.
        func at(_ t: Double) -> Vec3 {
            t >= time ? now : (t <= lastTime ? last : now + rate * Float(t - time))
        }

        /// Moves on to `t`, `since` the correction: eased out, at most `maxSpeed`.
        mutating func advance(to t: Double, since: Double) {
            guard t > time else { return }
            let u = min(max((t - since) / Smoother.duration, 0), 1)
            let k = Float(1 - u)
            let eased = start * (k * k)
            let d = eased - now
            let most = Smoother.maxSpeed * Float(t - time)
            last = now
            lastTime = time
            now = d.length > most ? now + d * (most / d.length) : eased
            time = t
        }

        var spent: Bool { now.length <= 1e-4 && last.length <= 1e-4 }
    }

    var ball: Offset?
    var players: [AthleteID: Offset] = [:]
    /// When the latest correction was, in match seconds.
    var since: Double = -.infinity

    public init() {}

    /// Whether anything is still easing.
    public var isActive: Bool { ball != nil || !players.isEmpty }

    /// The prediction was `old` and is now `new` at the same tick: the drawn positions start from
    /// where `old` had them.
    public mutating func correct(from old: GameState, to new: GameState) {
        let t = new.time
        let leftBall = ball?.at(t) ?? .zero
        ball = nil
        if let a = old.ball, let b = new.ball {
            let o = leftBall + (a.position(at: t) - b.position(at: t))
            if o.length > 1e-5 { ball = Offset(o, at: t) }
        }
        var next: [AthleteID: Offset] = [:]
        for (id, m) in new.motion {
            let left = players[id]?.at(t) ?? .zero
            let o = left + ((old.motion[id]?.pos).map { ($0 - m.pos).atHeight(0) } ?? .zero)
            if o.length > 1e-5 { next[id] = Offset(o, at: t) }
        }
        players = next
        since = t
    }

    /// Moves the offsets on to match time `t`; they're dropped once spent.
    public mutating func advance(to t: Double) {
        guard isActive else { return }
        ball?.advance(to: t, since: since)
        if ball?.spent == true { ball = nil }
        for id in players.keys {
            players[id]!.advance(to: t, since: since)
            if players[id]!.spent { players[id] = nil }
        }
    }

    /// `s` as drawn: its ball and players moved by what's left of the corrections.
    public func draw(_ s: GameState) -> GameState {
        guard isActive else { return s }
        var d = s
        let t = s.time
        if let b = ball, let f = d.ball {
            // The drawn flight is the flight plus the offset, moving at its rate: at time t' it
            // is off by at(t) + rate × (t' − t).
            let rate = b.rate
            let p0 = f.p0 + b.at(t) - rate * Float(t - f.startTime)
            d.ball = Flight(p0: p0, v0: f.v0 + rate, startTime: f.startTime, duration: f.duration)
        }
        for (id, o) in players where d.motion[id] != nil {
            d.motion[id]!.pos = d.motion[id]!.pos + o.at(t).xz
        }
        return d
    }
}
