import CoreGraphics
import Foundation
import simd
import SpikeCore
import Testing
@testable import SpikeJam

@MainActor
@Suite struct TouchTranslatorTests {
    /// Review Focus 1: a finger already down when a new window opens (still holding from an aim
    /// when the next pass comes) never fires the new contact. It needs a fresh touch.
    @Test func staleFingerIgnored() {
        let rig = WindowRig()
        rig.open(.attack, 5, athlete: rig.home(.z4))
        let p = rig.onTheirCourt()
        rig.translator.began(p, t: 10, touch: 1)
        // Window A closes and window B opens while the finger is still down.
        rig.closeAll()
        rig.open(.dig, 6, athlete: rig.home(.z5))
        rig.translator.moved(CGPoint(x: p.x + 40, y: p.y), t: 10.2, touch: 1)
        rig.translator.ended(CGPoint(x: p.x + 40, y: p.y), t: 10.3, touch: 1)
        #expect(!rig.contacts().contains(ContactID(raw: 6)))
        // Only the press for A went out, at the finger going down.
        #expect(rig.sink.actions == [.press(contact: ContactID(raw: 5))])

        // A finger that went down with no window at all never fires one that opens later.
        let quiet = WindowRig()
        quiet.translator.began(CGPoint(x: 400, y: 200), t: 20, touch: 2)
        quiet.open(.receive, 9, athlete: quiet.home(.z1))
        quiet.translator.ended(CGPoint(x: 400, y: 200), t: 20.1, touch: 2)
        #expect(quiet.sink.sent.isEmpty)
        // A fresh touch does.
        quiet.translator.began(CGPoint(x: 400, y: 200), t: 20.2, touch: 3)
        #expect(quiet.sink.actions == [.tap(contact: ContactID(raw: 9))])
        #expect(quiet.sink.sent[0].time == 20.2)
    }

    /// Review Focus 2: taps on the switch strip or the huddle chips during a live window never
    /// count as timing taps.
    @Test func excludedRectsIgnored() {
        let rig = WindowRig()
        let layout = phoneLayouts[1]
        let strip = layout.stripRect
        rig.translator.excludedRects = [strip, CGRect(x: 20, y: 60, width: 360, height: 290)]
        rig.open(.receive, 3, athlete: rig.home(.z1))
        for (i, p) in [CGPoint(x: strip.midX, y: strip.midY), CGPoint(x: 100, y: 200)].enumerated() {
            rig.translator.began(p, t: 5, touch: i)
            rig.translator.ended(p, t: 5.05, touch: i)
        }
        #expect(rig.sink.sent.isEmpty)
        // Off the strip, the same tap is the pass.
        rig.translator.began(CGPoint(x: 600, y: 150), t: 5.1, touch: 9)
        #expect(rig.sink.actions == [.tap(contact: ContactID(raw: 3))])
    }

    /// A quick tap on the serve is a safe float: press and release with no aim.
    @Test func serveFloat() {
        let rig = WindowRig()
        rig.open(.serve, 2, athlete: rig.s.lineups[0].server(), inTicks: 300)
        let p = rig.onTheirCourt(d: 6)
        rig.translator.began(p, t: 30, touch: 1)
        rig.translator.ended(p, t: 30.15, touch: 1)
        #expect(rig.sink.actions == [.press(contact: ContactID(raw: 2)), .release(contact: ContactID(raw: 2), aim: nil)])
        #expect(rig.sink.sent.map(\.time) == [30, 30.15])
    }

    /// Hold, drag onto their court and let go: the serve is aimed where the finger is.
    @Test func serveAimed() {
        let rig = WindowRig()
        rig.open(.serve, 2, athlete: rig.s.lineups[0].server(), inTicks: 300)
        rig.translator.began(CGPoint(x: 100, y: 300), t: 30, touch: 1)
        let spot = LocalFrame.toWorld(LocalSpot(d: 7, l: -2), team: .away)
        let p = rig.view.point(spot, height: 0)!
        rig.translator.moved(p, t: 30.3, touch: 1)
        #expect(rig.translator.aim?.floor != nil)
        rig.translator.ended(p, t: 30.6, touch: 1)
        guard case .release(_, let aim?) = rig.sink.actions.last else {
            Issue.record("no aimed release: \(rig.sink.actions)")
            return
        }
        #expect((aim - spot).length < 0.01)
        #expect(rig.translator.aim == nil)
    }

    /// Spike: touch their court, drag, let go. Letting go off their court swings without an aim.
    @Test func attackReleasesWithAim() {
        let rig = WindowRig()
        rig.open(.attack, 4, athlete: rig.home(.z4))
        let p = rig.onTheirCourt(d: 1, l: 2)
        rig.translator.began(p, t: 8, touch: 1)
        rig.translator.ended(p, t: 8.4, touch: 1)
        #expect(rig.sink.actions.first == .press(contact: ContactID(raw: 4)))
        guard case .release(_, let aim?) = rig.sink.actions.last else {
            Issue.record("no aimed release")
            return
        }
        #expect(LocalFrame.toLocal(aim, team: .away).d < Tuning.tipZone) // near the net: a tip
    }

    /// Spec §4.2: with hitters projected left, center and right of the setter, a swipe at 170°
    /// picks the left one.
    @Test func compassPicksHitter() {
        let left = AthleteID(team: .home, index: 0), center = AthleteID(team: .home, index: 1)
        let right = AthleteID(team: .home, index: 2)
        let origin = CGPoint(x: 400, y: 250)
        let hitters = [(left, CGPoint(x: 250, y: 240)), (center, CGPoint(x: 410, y: 140)), (right, CGPoint(x: 560, y: 245))]
        #expect(SetCompass.pick(angle: 170, from: origin, hitters: hitters) == left)
        #expect(SetCompass.pick(angle: 95, from: origin, hitters: hitters) == center)
        #expect(SetCompass.pick(angle: -10, from: origin, hitters: hitters) == right)
        #expect(SetCompass.pick(angle: -170, from: origin, hitters: hitters) == left) // wraps through 180
        // A swipe up and to the left on screen is about 135°.
        #expect(abs(SetCompass.angle(from: .zero, to: CGPoint(x: -10, y: -10)) - 135) < 1e-9)
    }

    /// A swipe from the setter during your set window sends `setTo` the hitter it points at,
    /// timed from the finger going down; a tap is the AI's choice.
    @Test func setSwipeAndTap() {
        let rig = WindowRig()
        let setter = rig.s.lineups[0].settingSetter(isServing: rig.s.isServing(.home))
        rig.open(.set, 7, athlete: setter)
        let hitters = liveCalls(rig.s, team: .home, passQuality: 1).map(\.0)
        let target = hitters[0]
        let from = rig.view.point(rig.s.motion[setter]!.pos, height: 0)!
        let to = rig.view.point(rig.s.motion[target]!.pos, height: 0)!
        let d = hypot(to.x - from.x, to.y - from.y)
        let step = CGPoint(x: from.x + (to.x - from.x) / d * 40, y: from.y + (to.y - from.y) / d * 40)
        rig.translator.began(from, t: 12, touch: 1)
        rig.translator.moved(step, t: 12.05, touch: 1)
        rig.translator.ended(step, t: 12.08, touch: 1)
        #expect(rig.sink.actions == [.setTo(contact: ContactID(raw: 7), hitter: target)])
        #expect(rig.sink.sent[0].time == 12)

        let tap = WindowRig()
        tap.open(.set, 8, athlete: setter)
        tap.translator.began(CGPoint(x: 300, y: 300), t: 1, touch: 1)
        tap.translator.ended(CGPoint(x: 302, y: 300), t: 1.05, touch: 1)
        #expect(tap.sink.actions == [.tap(contact: ContactID(raw: 8))])

        // A finger held still on a set is sent as a tap before the contact would be missed.
        let held = WindowRig()
        held.open(.set, 9, athlete: setter, inTicks: 10)
        held.translator.began(CGPoint(x: 300, y: 300), t: 2, touch: 1)
        #expect(held.sink.sent.isEmpty)
        held.wait(13)
        #expect(held.sink.sent.isEmpty)
        // Four steps past the contact: two left of SpikeCore's six-step grace.
        held.wait(1)
        #expect(held.sink.actions == [.tap(contact: ContactID(raw: 9))])
        #expect(held.sink.sent.first?.time == 2)
        held.translator.ended(CGPoint(x: 300, y: 300), t: 2.3, touch: 1)
        #expect(held.sink.sent.count == 1)
    }

    /// Pass, dig and block go out as the finger touches down; one touch per window.
    @Test func tapsOnDown() {
        let rig = WindowRig()
        rig.open(.dig, 11, athlete: rig.home(.z6))
        rig.translator.began(CGPoint(x: 500, y: 200), t: 3, touch: 1)
        rig.translator.began(CGPoint(x: 520, y: 200), t: 3.02, touch: 2)
        #expect(rig.sink.actions == [.tap(contact: ContactID(raw: 11))])
        rig.closeAll()
        let c = ContactID(raw: 12)
        rig.s.notes.block = BlockWindow(id: c, owner: soloHuman, athlete: rig.home(.z3), attack: ContactID(raw: 13), attackTick: rig.s.tick + 50)
        rig.ownership.observe([.window(c, .block, owner: soloHuman, contactTick: rig.s.tick + 50)], in: rig.s)
        rig.translator.update(rig.s)
        rig.translator.began(CGPoint(x: 500, y: 200), t: 4, touch: 3)
        #expect(rig.sink.actions.last == .block(contact: c))
    }

    /// Spec §4.2: the center of the screen with a known camera hits the expected floor point
    /// within 1 cm, and a projected floor point picks back to itself.
    @Test func aimRayHitsFloor() {
        let shot = CameraShot(position: [0, 10, 10], target: [2, 0, -1], fov: 40)
        let view = ScreenProjector(shot: shot, size: CGSize(width: 800, height: 400))
        let center = FloorPicker.floorHit(CGPoint(x: 400, y: 200), view)!
        #expect(hypot(center.x - 2, center.z + 1) < 0.01)
        for spot in [Vec2(x: 3, z: -2), Vec2(x: -6, z: 4), Vec2(x: 8.5, z: 0)] {
            let p = view.point(spot, height: 0)!
            let back = FloorPicker.floorHit(p, view)!
            #expect((back - spot).length < 0.01, "\(spot) → \(p) → \(back)")
        }
        // Above the horizon there is no floor.
        #expect(FloorPicker.floorHit(CGPoint(x: 400, y: -2000), view) == nil)
        #expect(FloorPicker.isOnCourt(LocalFrame.toWorld(LocalSpot(d: 4, l: 1), team: .away), side: .away))
        #expect(!FloorPicker.isOnCourt(LocalFrame.toWorld(LocalSpot(d: 4, l: 1), team: .home), side: .away))
    }

    /// The whole path without a person: a robot finger touches the drawn screen, the translator
    /// turns it into actions, the client loop stamps them, and SpikeCore judges real touches.
    @Test func robotFingerPlaysThroughTouches() {
        var settings = StartChoices().matchSettings(seed: 21)
        settings.seed = 21
        let client = LocalClientLoop(state: GameState(settings: settings, humans: [HumanSlot(id: soloHuman, team: .home)]))
        let ownership = HumanOwnership(human: soloHuman, side: .home)
        let director = CameraDirector(ownership: ownership)
        let translator = TouchTranslator(human: soloHuman, ownership: ownership) { _, _ in }
        translator.send = { [weak client] a, t in client?.send(PlayerInput(human: soloHuman, tick: 0, action: a), at: t) }
        let finger = DemoFinger(translator: translator, ownership: ownership, spread: 0.03)
        let size = CGSize(width: 874, height: 402)
        director.aspect = Float(size.width / size.height)
        director.aimBands = phoneLayouts[1].aimBands
        director.reset(to: client.current)
        var grades: [Grade] = [], kinds: Set<TouchKind> = []
        var clock = 1000.0
        _ = client.advance(to: clock)
        for _ in 0..<(90 * 60) {
            clock += Tuning.dt
            let events = client.advance(to: clock)
            ownership.observe(events, in: client.current)
            translator.update(client.current)
            let view = ScreenProjector(shot: director.frame(for: client.current, events: events, dt: Tuning.dt), size: size)
            translator.projector = view
            finger.frame(client.current, time: client.current.time + client.alpha * Tuning.dt, clock: clock, view: view)
            for e in events {
                if case .judged(let id, let g) = e, let w = ownership.window(id) {
                    grades.append(g)
                    kinds.insert(w.kind)
                }
            }
            if client.current.phase == .matchOver { break }
        }
        #expect(grades.count > 20)
        let good = grades.filter { $0 == .perfect || $0 == .good }.count
        #expect(Double(good) / Double(max(grades.count, 1)) > 0.6, "\(grades)")
        #expect(kinds.isSuperset(of: [.serve, .receive, .set, .attack]), "\(kinds)")
    }
}
