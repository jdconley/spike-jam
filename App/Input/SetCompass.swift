import CoreGraphics
import Foundation
import SpikeCore

/// The set compass (spec §4.1, §4.2): a swipe picks the hitter it points at, drawn from where the
/// hitters stand on screen when the set happens. The same compass makes the defensive read.
enum SetCompass {
    /// The direction from `a` to `b` on screen, in degrees: 0 is right, 90 is up the screen,
    /// 180 is left, −90 is down.
    static func angle(from a: CGPoint, to b: CGPoint) -> Double {
        atan2(-(b.y - a.y), b.x - a.x) * 180 / .pi
    }

    /// How far apart two directions are, 0...180 degrees.
    static func separation(_ a: Double, _ b: Double) -> Double {
        let d = (a - b).truncatingRemainder(dividingBy: 360)
        let w = d < 0 ? d + 360 : d
        return min(w, 360 - w)
    }

    /// The hitter whose screen position, seen from `origin` (the setter), is closest in angle to
    /// `angle`. Nil with no hitters.
    static func pick(angle: Double, from origin: CGPoint, hitters: [(AthleteID, CGPoint)]) -> AthleteID? {
        hitters.min { separation(Self.angle(from: origin, to: $0.1), angle) < separation(Self.angle(from: origin, to: $1.1), angle) }?.0
    }

    /// The hitter a swipe from `start` to `end` points at.
    static func pick(swipeFrom start: CGPoint, to end: CGPoint, origin: CGPoint, hitters: [(AthleteID, CGPoint)]) -> AthleteID? {
        pick(angle: angle(from: start, to: end), from: origin, hitters: hitters)
    }

    /// The hitter nearest a tap at `p`, within `radius` points.
    static func nearest(_ p: CGPoint, hitters: [(AthleteID, CGPoint)], radius: CGFloat = 90) -> AthleteID? {
        let close = hitters.map { ($0.0, hypot($0.1.x - p.x, $0.1.y - p.y)) }.filter { $0.1 <= radius }
        return close.min { $0.1 < $1.1 }?.0
    }
}
