import Foundation
import SpikeCore

/// Something that happened in the match, with the ball flights around it, so the feel layer
/// (haptics and sound) can tell how hard the touch was: the ball coming in and the ball going out.
struct FeltEvent: Equatable, Sendable {
    var event: GameEvent
    var incoming: Flight?
    var outgoing: Flight?
}

/// The visual-only slow motion (spec §4.4: slow motion on the last moments of a kill).
///
/// SpikeCore always steps at full rate. This keeps the last moments of states the client loop
/// produced and draws a little in the past: on a kill or a stuff coming down, its clock eases from
/// full speed down to `slowFloor` and back over `slowDuration` of wall time, then runs at
/// `catchUpRate` until it is live again, which happens in the dead ball after the point, where
/// nothing is missed. Events are held until the drawn moment reaches them, so sound and haptics
/// stay with the picture.
@MainActor
final class Presentation {
    /// What to draw this frame.
    struct Frame {
        var prev: GameState
        var cur: GameState
        var alpha: Double
        /// The match time drawn.
        var time: Double
        /// Presentation seconds since the last frame (slow during slow motion).
        var dt: Double
        /// Events whose moment has now been drawn.
        var events: [FeltEvent]
    }

    /// Wall seconds of slow motion.
    static let slowDuration = 0.6
    /// The slowest the drawn match runs, as a share of real speed.
    static let slowFloor = 0.3
    /// How fast the drawn match runs while catching up after slow motion.
    static let catchUpRate = 1.6
    /// Slow motion starts this long (match time) before the ball comes down, so the landing is
    /// drawn at the slowest moment.
    static let leadIn = 0.17
    /// The furthest the drawn match falls behind; the history kept covers it.
    static let maxLag = 0.8
    static let history = 1.5

    /// How far the drawn match is behind the live one, in seconds.
    private(set) var lag: Double = 0
    /// Wall seconds into the current slow motion, nil when there is none.
    private(set) var slowElapsed: Double?
    private var buffer: [GameState] = []
    private var held: [(time: Double, event: FeltEvent)] = []
    private var lastLive: Double?
    private var lastShown: Double?
    private var triggeredTick: Int?

    var isSlow: Bool { slowElapsed != nil }

    /// The presentation clock's rate `u` of the way through slow motion: an eased dip from full
    /// speed to `slowFloor` and back.
    static func slowRate(_ u: Double) -> Double {
        guard u >= 0 && u < 1 else { return 1 }
        return 1 - (1 - slowFloor) * sin(.pi * u)
    }

    /// The ball in the air is a kill or a stuff block coming down.
    static func isKillFinish(_ s: GameState) -> Bool {
        guard let p = s.pending, p.kind == nil, let r = p.reason else { return false }
        return r == .kill || r == .block
    }

    /// Takes the client loop's frame (`prev`, `cur`, `alpha` and the events of its steps) and
    /// returns what to draw.
    func frame(prev: GameState, cur: GameState, alpha: Double, events: [GameEvent]) -> Frame {
        let live = SceneMapping.renderTime(prev: prev, cur: cur, alpha: alpha)
        // A new match starts the clock over.
        if let last = lastLive, live < last - 1 { reset() }
        let wallDt = min(max(live - (lastLive ?? live), 0), 0.1)
        lastLive = live
        remember(prev)
        remember(cur)
        buffer.removeAll { $0.time < live - Self.history }
        for e in events {
            held.append((cur.time, FeltEvent(event: e, incoming: prev.ball, outgoing: cur.ball)))
        }

        if slowElapsed == nil, let p = cur.pending, Self.isKillFinish(cur), triggeredTick != p.tick,
           Double(p.tick - cur.tick) * Tuning.dt <= Self.leadIn {
            triggeredTick = p.tick
            slowElapsed = 0
        }
        var rate = 1.0
        if let e = slowElapsed {
            rate = Self.slowRate(e / Self.slowDuration)
            slowElapsed = e + wallDt >= Self.slowDuration ? nil : e + wallDt
        } else if lag > 0 {
            rate = Self.catchUpRate
        }
        lag = min(max(lag + (1 - rate) * wallDt, 0), Self.maxLag)

        let shown = live - lag
        let dt = max(0, shown - (lastShown ?? shown))
        lastShown = shown
        // An event belongs to the step that made it, which is drawn from one step before.
        let due = held.filter { $0.time <= shown + Tuning.dt + 1e-9 }.map(\.event)
        held.removeAll { $0.time <= shown + Tuning.dt + 1e-9 }
        guard lag > 0 else {
            return Frame(prev: prev, cur: cur, alpha: alpha, time: live, dt: dt, events: due)
        }
        let (a, b) = bracket(shown)
        let span = b.time - a.time
        let t = span > 0 ? min(max((shown - a.time) / span, 0), 1) : 1
        return Frame(prev: a, cur: b, alpha: t, time: shown, dt: dt, events: due)
    }

    func reset() {
        lag = 0
        slowElapsed = nil
        buffer = []
        held = []
        lastLive = nil
        lastShown = nil
        triggeredTick = nil
    }

    private func remember(_ s: GameState) {
        if let last = buffer.last, last.tick >= s.tick { return }
        buffer.append(s)
    }

    /// The two kept states either side of `time`.
    private func bracket(_ time: Double) -> (GameState, GameState) {
        guard let first = buffer.first else { fatalError("bracket before any frame") }
        guard let i = buffer.lastIndex(where: { $0.time <= time }) else { return (first, first) }
        return (buffer[i], i + 1 < buffer.count ? buffer[i + 1] : buffer[i])
    }
}
