import CoreGraphics
import Foundation
import SpikeCore

/// A robot finger for `-demo assist` and the app tests: it plays the local human's touches
/// through the real `TouchTranslator`, at screen points from the drawn camera, timed a little off
/// the perfect moment, so the whole path from finger to SpikeCore runs without a person.
@MainActor
final class DemoFinger {
    /// Where a step of the gesture goes on screen.
    enum Target: Equatable {
        /// A floor spot (the aim).
        case floor(Vec2)
        /// Where an athlete stands.
        case athlete(AthleteID)
        /// From where the finger is, `by` points toward an athlete (a swipe).
        case toward(AthleteID, by: CGFloat)
        /// Where the finger is.
        case here
    }

    enum Phase: Equatable { case down, move, up }

    struct Step: Equatable {
        var time: Double
        var phase: Phase
        var target: Target
    }

    let translator: TouchTranslator
    let ownership: HumanOwnership
    /// The timing error's spread, in seconds.
    var spread: Double
    private var rng: SeededRNG
    private var handled: Set<ContactID> = []
    private var tossHandled: Set<ContactID> = []
    private(set) var queue: [Step] = []
    private var finger: CGPoint?
    static let touchKey = -2

    init(translator: TouchTranslator, ownership: HumanOwnership, spread: Double = 0.04, seed: UInt64 = 7) {
        self.translator = translator
        self.ownership = ownership
        self.spread = spread
        rng = SeededRNG(seed: seed)
    }

    /// Once a frame, with the live state, the live match time, the touch clock's now and the
    /// drawn camera.
    func frame(_ s: GameState, time: Double, clock: Double, view: ScreenProjector?) {
        if let w = ownership.next { plan(w, s, time) }
        guard let view else { return }
        while let step = queue.first, step.time <= time {
            queue.removeFirst()
            let t = clock - (time - step.time)
            guard let p = point(step.target, s, view) else { continue }
            finger = p
            switch step.phase {
            case .down: translator.began(p, t: t, touch: Self.touchKey)
            case .move: translator.moved(p, t: t, touch: Self.touchKey)
            case .up: translator.ended(p, t: t, touch: Self.touchKey)
            }
        }
    }

    private func plan(_ w: OwnedWindow, _ s: GameState, _ time: Double) {
        guard let side = ownership.localSide else { return }
        let act = w.actTime + error()
        if w.kind == .serve {
            if !handled.contains(w.id) {
                handled.insert(w.id)
                let aim = LocalFrame.toWorld(LocalSpot(d: Float.random(in: 4...8, using: &rng), l: Float.random(in: -3...3, using: &rng)),
                                             team: side.other)
                queue.append(Step(time: max(time, w.openedTime) + 0.7, phase: .down, target: .floor(aim)))
            } else if w.tossed, !tossHandled.contains(w.id) {
                tossHandled.insert(w.id)
                queue.append(Step(time: max(act, time), phase: .up, target: .here))
            }
            return
        }
        guard !handled.contains(w.id) else { return }
        handled.insert(w.id)
        switch w.kind {
        case .receive, .dig, .block:
            queue.append(Step(time: act, phase: .down, target: .here))
            queue.append(Step(time: act + 0.05, phase: .up, target: .here))
        case .set:
            let hitters = liveCalls(s, team: side, passQuality: s.notes.passQuality).map(\.0)
            guard let setter = w.athlete, !hitters.isEmpty else {
                queue.append(Step(time: act, phase: .down, target: .here))
                queue.append(Step(time: act + 0.05, phase: .up, target: .here))
                break
            }
            let hitter = hitters[Int.random(in: 0..<hitters.count, using: &rng)]
            queue.append(Step(time: act, phase: .down, target: .athlete(setter)))
            queue.append(Step(time: act + 0.03, phase: .move, target: .toward(hitter, by: 50)))
            queue.append(Step(time: act + 0.06, phase: .up, target: .here))
        case .attack:
            let deep = rng.chance(0.85)
            let spot = deep ? LocalSpot(d: Float.random(in: 4...8, using: &rng), l: Float.random(in: -3.5...3.5, using: &rng))
                : LocalSpot(d: 1.4, l: Float.random(in: -3...3, using: &rng))
            let aim = LocalFrame.toWorld(spot, team: side.other)
            queue.append(Step(time: max(time, act - 0.45), phase: .down, target: .floor(aim)))
            queue.append(Step(time: max(time, act - 0.2), phase: .move, target: .floor(aim)))
            queue.append(Step(time: act, phase: .up, target: .floor(aim)))
        case .serve:
            break
        }
        queue.sort { $0.time < $1.time }
    }

    /// A normal-ish timing error.
    private func error() -> Double {
        let z = (rng.unit() + rng.unit() + rng.unit() - 1.5) * 2
        return Double(z) * spread
    }

    private func point(_ target: Target, _ s: GameState, _ view: ScreenProjector) -> CGPoint? {
        switch target {
        case .floor(let v):
            return view.point(v, height: 0)
        case .athlete(let id):
            return s.motion[id].flatMap { view.point($0.pos, height: 0) }
        case .toward(let id, let by):
            guard let from = finger, let to = s.motion[id].flatMap({ view.point($0.pos, height: 0) }) else { return nil }
            let d = hypot(to.x - from.x, to.y - from.y)
            guard d > 1 else { return CGPoint(x: from.x + by, y: from.y) }
            return CGPoint(x: from.x + (to.x - from.x) / d * by, y: from.y + (to.y - from.y) / d * by)
        case .here:
            return finger ?? CGPoint(x: view.size.width / 2, y: view.size.height / 2)
        }
    }
}
