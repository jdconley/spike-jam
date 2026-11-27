import CoreGraphics
import Foundation
import SpikeCore
@testable import SpikeJam

let soloHuman = HumanID(raw: 1)

/// Landscape iPhones: an SE (667×375, no insets) and a 17 Pro (874×402, the Dynamic Island and
/// the home indicator in landscape).
let phoneLayouts: [HUDLayout] = [
    HUDLayout(size: CGSize(width: 667, height: 375)),
    HUDLayout(size: CGSize(width: 874, height: 402), insets: .init(top: 0, leading: 62, bottom: 21, trailing: 62)),
]

/// A match with one human on `local`, played by a `SimHuman` (following the ball, so every touch
/// on their side is theirs), watched by a `HumanOwnership`. Hands every state and its events to
/// `visit`.
@MainActor
func playSolo(local: TeamSide = .home, seed: UInt64, seconds: Double, skill: Float = 0.8,
              _ visit: (GameState, [GameEvent], HumanOwnership) -> Void) {
    var settings = MatchSettings()
    settings.seed = seed
    var sim = SimHuman(id: soloHuman, team: local, skill: skill, seed: seed)
    var s = GameState(settings: settings, humans: [sim.slot])
    let ownership = HumanOwnership(human: soloHuman, side: local)
    for _ in 0..<Int(seconds * Double(Tuning.stepsPerSecond)) {
        let events = step(&s, inputs: sim.inputs(for: s))
        ownership.observe(events, in: s)
        visit(s, events, ownership)
        if s.phase == .matchOver { break }
    }
}

/// Collects what a translator or the HUD sends.
@MainActor
final class Sink {
    var sent: [(action: InputAction, time: Double)] = []
    var actions: [InputAction] { sent.map(\.action) }

    func send(_ a: InputAction, _ t: Double) { sent.append((a, t)) }
}

/// A hand-built rally for the translator and HUD tests: a solo match with windows opened by hand.
@MainActor
final class WindowRig {
    var s: GameState
    let ownership = HumanOwnership(human: soloHuman, side: .home)
    let sink = Sink()
    let translator: TouchTranslator
    let view = ScreenProjector(shot: CameraDirector.wideSideline, size: CGSize(width: 874, height: 402))

    init(pick: Pick = .ball) {
        s = GameState(settings: MatchSettings(), humans: [HumanSlot(id: soloHuman, team: .home, pick: pick)])
        s.phase = .rally
        s.tick = 600
        translator = TouchTranslator(human: soloHuman, ownership: ownership) { _, _ in }
        translator.send = { [sink] a, t in sink.send(a, t) }
        translator.projector = view
    }

    /// The home athlete in `zone`.
    func home(_ zone: Zone) -> AthleteID {
        s.lineups[0].occupant(zone, isServing: s.isServing(.home))
    }

    /// Opens `kind`'s window for `athlete` as contact `id`, `inTicks` from now.
    @discardableResult
    func open(_ kind: TouchKind, _ id: UInt32, athlete: AthleteID, inTicks: Int = 40) -> OwnedWindow {
        let c = ContactID(raw: id)
        s.pending = PendingContact(kind: kind, team: athlete.team, athlete: athlete, tick: s.tick + inTicks, id: c, owner: soloHuman)
        ownership.observe([.window(c, kind, owner: soloHuman, contactTick: s.tick + inTicks)], in: s)
        translator.update(s)
        return ownership.window(c)!
    }

    /// The pending contact goes away (it was played, or the rally ended).
    func closeAll() {
        s.pending = nil
        ownership.observe([], in: s)
        translator.update(s)
    }

    /// Steps the clock on by `ticks` with nothing happening.
    func wait(_ ticks: Int) {
        s.tick += ticks
        ownership.observe([], in: s)
        translator.update(s)
    }

    /// A screen point over a spot on the away court.
    func onTheirCourt(d: Float = 5, l: Float = 0) -> CGPoint {
        view.point(LocalFrame.toWorld(LocalSpot(d: d, l: l), team: .away), height: 0)!
    }

    func contacts() -> [ContactID] {
        sink.actions.compactMap { PlayerInput(human: soloHuman, tick: 0, action: $0).contact }
    }
}
