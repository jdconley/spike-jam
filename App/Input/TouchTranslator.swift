import CoreGraphics
import Foundation
import SpikeCore

/// Turns fingers on the court into SpikeCore actions for the local human's open window
/// (spec §4.2), one gesture per touch:
/// - serve: `press` on down (the toss), `release` on up with the aim under the finger if it is on
///   their court; let go within `Tuning.floatTap` and it's a float, `release` with no aim;
/// - pass and dig: `tap` on down; block: `block` on down (the jump starts at once);
/// - set: a swipe sends `setTo` the hitter the compass points at, a tap on a set label `setTo`
///   that hitter, any other tap `tap` (the AI's choice), timed from the finger going down;
/// - attack: `press` on down, `release` on up with the aim (a spot near the net is a tip);
/// - read: with no window of their own while the other side passes and sets, a swipe or a tap
///   toward one of their hitters sends `read`.
///
/// A touch acts only on the window open when it went down. A finger still down when a new
/// window opens never fires it (Review Focus 1): the new window needs a fresh touch. Touches that
/// start inside `excludedRects` (the switch strip, the huddle chips) are never translated
/// (Review Focus 2).
///
/// Times are seconds on the touch clock (`UITouch.timestamp`, the client loop's clock).
@MainActor
final class TouchTranslator {
    /// What a touch is doing.
    struct Touch: Equatable {
        var start: CGPoint
        var startTime: Double
        var last: CGPoint
        /// The window open when it went down, if any; the only one it can act on.
        var window: OwnedWindow?
        /// A read touch (no window, the other side has the ball).
        var reading: Bool
        var swiped = false
        /// Its one action is out.
        var done = false
    }

    /// The aim the HUD draws: a serve or attack touch's spot on their court.
    struct Aim: Equatable {
        var contact: ContactID
        var kind: TouchKind
        var point: CGPoint
        /// Where on their court, nil while the finger is off it.
        var floor: Vec2?
    }

    /// How far a finger moves before it's a swipe, in points.
    static let swipeDistance: CGFloat = 28

    let human: HumanID
    let ownership: HumanOwnership
    /// Sends an action that happened at a touch time.
    var send: (InputAction, Double) -> Void
    /// The switch strip and huddle chips, in this view's coordinates.
    var excludedRects: [CGRect] = []
    /// The camera as drawn, for aiming and the compass.
    var projector: ScreenProjector?
    /// The set labels' tap areas, from the HUD.
    var labelTargets: [(AthleteID, CGRect)] = []

    private(set) var touches: [Int: Touch] = [:]
    /// The newest live state.
    private(set) var state: GameState?
    /// Contacts this human has already acted on.
    private var acted: Set<ContactID> = []

    init(human: HumanID, ownership: HumanOwnership, send: @escaping (InputAction, Double) -> Void) {
        self.human = human
        self.ownership = ownership
        self.send = send
    }

    private var side: TeamSide? { ownership.localSide }

    /// The aim being dragged, if any (the newest aiming touch).
    var aim: Aim? {
        for t in touches.values where !t.done {
            guard let w = t.window, w.kind == .serve || w.kind == .attack, ownership.isOpen(w.id) else { continue }
            return Aim(contact: w.id, kind: w.kind, point: t.last, floor: aimSpot(t.last))
        }
        return nil
    }

    /// Takes the newest live state, after `ownership` observed its events. A set touch still
    /// deciding between a swipe and a tap is sent as a tap before its contact would be missed.
    func update(_ s: GameState) {
        state = s
        acted = acted.filter { ownership.window($0) != nil }
        for (key, t) in touches where !t.done {
            guard let w = t.window, w.kind == .set, ownership.isOpen(w.id) else { continue }
            // SpikeCore waits `graceWindow` past the contact for the input; leave two steps.
            let deadline = w.contactTick + Int((Tuning.graceWindow * Double(Tuning.stepsPerSecond)).rounded()) - 2
            if s.tick >= deadline { finishSet(key, at: t.start, swipe: nil) }
        }
    }

    func began(_ p: CGPoint, t: Double, touch key: Int = 0) {
        guard !excludedRects.contains(where: { $0.contains(p) }) else { return }
        let window = ownership.next.flatMap { acted.contains($0.id) ? nil : $0 }
        var touch = Touch(start: p, startTime: t, last: p, window: window, reading: window == nil && canRead)
        touches[key] = touch
        guard let w = window else { return }
        switch w.kind {
        case .serve, .attack:
            act(w, .press(contact: w.id), at: t, final: false)
        case .receive, .dig:
            act(w, .tap(contact: w.id), at: t)
            touch.done = true
        case .block:
            act(w, .block(contact: w.id), at: t)
            touch.done = true
        case .set:
            if let hitter = labelHit(p) {
                act(w, .setTo(contact: w.id, hitter: hitter), at: t)
                touch.done = true
            }
        }
        touches[key] = touch
    }

    func moved(_ p: CGPoint, t: Double, touch key: Int = 0) {
        guard var touch = touches[key] else { return }
        touch.last = p
        touches[key] = touch
        guard !touch.done, !touch.swiped, hypot(p.x - touch.start.x, p.y - touch.start.y) >= Self.swipeDistance else { return }
        if let w = touch.window, w.kind == .set {
            touches[key]?.swiped = true
            finishSet(key, at: touch.start, swipe: p)
        } else if touch.reading {
            touches[key]?.swiped = true
            touches[key]?.done = true
            readSwipe(from: touch.start, to: p, at: t)
        }
    }

    func ended(_ p: CGPoint, t: Double, touch key: Int = 0) {
        guard var touch = touches.removeValue(forKey: key), !touch.done else { return }
        touch.last = p
        if let w = touch.window {
            // Only the window this touch began on, and only while it's still open.
            guard ownership.isOpen(w.id) else { return }
            switch w.kind {
            case .serve:
                let quick = t - touch.startTime < Tuning.floatTap
                act(w, .release(contact: w.id, aim: quick ? nil : aimSpot(p)), at: t)
            case .attack:
                act(w, .release(contact: w.id, aim: aimSpot(p)), at: t)
            case .set:
                touches[key] = touch
                finishSet(key, at: touch.start, swipe: nil)
                touches[key] = nil
            default:
                break
            }
        } else if touch.reading, !touch.swiped, let hitter = readHitters().nearestTo(touch.start) {
            sendRead(hitter, at: touch.startTime)
        }
    }

    func cancelled(touch key: Int = 0) {
        touches[key] = nil
    }

    // MARK: Pieces

    private func act(_ w: OwnedWindow, _ a: InputAction, at t: Double, final: Bool = true) {
        send(a, t)
        if final { acted.insert(w.id) }
    }

    /// A set touch's one action: the hitter the swipe points at, else a label under the finger,
    /// else a tap (the AI's choice of hitter). Timed from the finger going down.
    private func finishSet(_ key: Int, at start: CGPoint, swipe end: CGPoint?) {
        guard let touch = touches[key], !touch.done, let w = touch.window, ownership.isOpen(w.id) else { return }
        touches[key]?.done = true
        var hitter: AthleteID?
        if let end, let setter = w.athlete, let origin = screen(setter) {
            hitter = SetCompass.pick(swipeFrom: touch.start, to: end, origin: origin, hitters: setHitters(w))
        } else if end == nil {
            hitter = labelHit(touch.last) ?? labelHit(start)
        }
        let action: InputAction = hitter.map { .setTo(contact: w.id, hitter: $0) } ?? .tap(contact: w.id)
        act(w, action, at: touch.startTime)
    }

    /// The aim under screen point `p`, if it's on the other team's court.
    func aimSpot(_ p: CGPoint) -> Vec2? {
        guard let projector, let side, let v = FloorPicker.floorHit(p, projector),
              FloorPicker.isOnCourt(v, side: side.other) else { return nil }
        return v
    }

    private func labelHit(_ p: CGPoint) -> AthleteID? {
        labelTargets.first { $0.1.contains(p) }?.0
    }

    /// The local team's hitters for a set, where they stand on screen.
    private func setHitters(_ w: OwnedWindow) -> [(AthleteID, CGPoint)] {
        guard let s = state, let side else { return [] }
        return liveCalls(s, team: side, passQuality: s.notes.passQuality).compactMap { id, _ in
            screen(id).map { (id, $0) }
        }
    }

    private func screen(_ id: AthleteID) -> CGPoint? {
        guard let s = state, let m = s.motion[id] else { return nil }
        return projector?.point(m.pos, height: 0)
    }

    // MARK: The defensive read

    /// The other side is passing or setting: a read can still move the block.
    private var canRead: Bool {
        guard let s = state, let side, s.phase == .rally, let c = s.pending, c.team == side.other else { return false }
        return c.kind == .receive || c.kind == .dig || c.kind == .set
    }

    private func readHitters() -> [(AthleteID, CGPoint)] {
        guard let s = state, let side else { return [] }
        let them = side.other
        return liveCalls(s, team: them, passQuality: max(s.notes.passQuality, PlayBook.goodPass)).compactMap { id, _ in
            screen(id).map { (id, $0) }
        }
    }

    private func readSwipe(from a: CGPoint, to b: CGPoint, at t: Double) {
        guard let s = state, let side else { return }
        let them = side.other
        let setter = s.lineups[them.rawValue].settingSetter(isServing: s.isServing(them))
        guard let origin = screen(setter),
              let hitter = SetCompass.pick(swipeFrom: a, to: b, origin: origin, hitters: readHitters()) else { return }
        sendRead(hitter, at: t)
    }

    private func sendRead(_ hitter: AthleteID, at t: Double) {
        send(.read(hitter: hitter), t)
    }
}

private extension Array where Element == (AthleteID, CGPoint) {
    func nearestTo(_ p: CGPoint) -> AthleteID? { SetCompass.nearest(p, hitters: self) }
}
