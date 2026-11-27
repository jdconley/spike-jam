import CoreGraphics
import Foundation
import SpikeCore
import Testing
@testable import SpikeJam

@MainActor
@Suite struct HUDModelTests {
    private func model(_ rig: WindowRig) -> (HUDModel, Sink) {
        let hud = HUDModel(human: soloHuman, ownership: rig.ownership)
        let sink = Sink()
        hud.send = { sink.send($0, 0) }
        return (hud, sink)
    }

    /// The ring is green (`perfect`) only within ±60 ms of the owned contact time.
    @Test func ringTurnsGreen() {
        let rig = WindowRig()
        let w = rig.open(.receive, 3, athlete: rig.home(.z1), inTicks: 60)
        let (hud, _) = model(rig)
        let t = w.contactTime
        for (off, perfect) in [(-0.2, false), (-0.0605, false), (-0.0595, true), (0, true), (0.059, true), (0.0605, false), (0.09, false)] {
            hud.update(.init(live: rig.s, time: t + off, view: rig.view))
            #expect(hud.ring?.perfect == perfect, "at \(off)")
        }
        // It closes toward the moment: wide early, shut on time.
        hud.update(.init(live: rig.s, time: t - 0.5, view: rig.view))
        let early = hud.ring!.progress
        hud.update(.init(live: rig.s, time: t, view: rig.view))
        #expect(early > 0.3 && hud.ring!.progress == 0)
        // A block's ring closes half a jump before the attack: the jump peaks on it.
        let block = OwnedWindow(id: ContactID(raw: 9), kind: .block, contactTick: 900, athlete: nil, openedTick: 850)
        let jumpAt = block.contactTime - Double(Tuning.blockJumpTicks / 2) * Tuning.dt
        #expect(HUDModel.ring(for: block, at: .zero, time: jumpAt).perfect)
        #expect(!HUDModel.ring(for: block, at: .zero, time: block.contactTime).perfect)
    }

    /// With your setter's window open, the labels read the live calls' names, and calls that
    /// aren't live off this pass are greyed.
    @Test func setLabelsUsePlayNames() {
        let rig = WindowRig()
        let setter = rig.s.lineups[0].settingSetter(isServing: rig.s.isServing(.home))
        rig.open(.set, 7, athlete: setter)
        let (hud, _) = model(rig)
        rig.s.notes.passQuality = 1
        hud.update(.init(live: rig.s, view: rig.view))
        let live = liveCalls(rig.s, team: .home, passQuality: 1)
        #expect(!hud.setLabels.isEmpty)
        #expect(hud.setLabels.map(\.text) == live.map(\.1.display))
        #expect(hud.setLabels.allSatisfy { $0.live })

        // Off a poor pass the quick isn't live: the middle's label is grey, the rest fall back.
        rig.s.notes.passQuality = 0.4
        hud.update(.init(live: rig.s, view: rig.view))
        let poor = liveCalls(rig.s, team: .home, passQuality: 0.4)
        let grey = hud.setLabels.filter { !$0.live }
        #expect(!grey.isEmpty)
        for label in grey {
            #expect(rig.s.rosters[0][label.id].position == .middle)
            #expect(!poor.contains { $0.0 == label.id })
        }
        for label in hud.setLabels where label.live {
            #expect(poor.first { $0.0 == label.id }?.1.display == label.text)
        }
        // Not your set, no labels.
        rig.open(.receive, 8, athlete: rig.home(.z1))
        hud.update(.init(live: rig.s, view: rig.view))
        #expect(hud.setLabels.isEmpty)
    }

    /// The strip lists the six on court with the libero swapped in, then BALL, and lights the
    /// one you control.
    @Test func stripMatchesRotation() {
        let rig = WindowRig()
        let lineup = rig.s.lineups[0]
        let court = lineup.onCourt(isServing: rig.s.isServing(.home))
        let order: [Zone] = [.z4, .z3, .z2, .z5, .z6, .z1]
        let (hud, sink) = model(rig)
        hud.update(.init(live: rig.s, view: rig.view))
        #expect(hud.strip.map(\.pick) == order.map { .athlete(court[$0]!) } + [.ball])
        // The libero is on, the middle they replace isn't.
        let onCourt = Set(court.values)
        #expect(onCourt.contains(lineup.libero) == court.values.contains(lineup.libero))
        let backMiddles = Zone.allCases.filter { !$0.isFrontRow }.map { lineup.baseOccupant($0) }
            .filter { rig.s.rosters[0][$0].position == .middle }
        for m in backMiddles where onCourt.contains(lineup.libero) { #expect(!onCourt.contains(m)) }
        let a = rig.s.rosters[0][court[.z4]!]
        #expect(hud.strip[0].text == "#\(a.number) \(a.position.tag)")
        // Following the ball with nothing coming: BALL is lit.
        #expect(hud.strip.filter(\.lit).map(\.pick) == [.ball])

        // Playing the outside: their chip is lit, as `controlled(by:)` says.
        let oh = court[.z4]!
        rig.s.humans[0].pick = .athlete(oh)
        hud.update(.init(live: rig.s, view: rig.view))
        #expect(controlled(by: soloHuman, rig.s) == oh)
        #expect(hud.strip.filter(\.lit).map(\.pick) == [.athlete(oh)])
        #expect(hud.arrowAthlete == oh)
        // A tap switches, at once on the strip.
        hud.tapStrip(.athlete(court[.z1]!))
        #expect(sink.actions == [.switchTo(.athlete(court[.z1]!))])
        #expect(hud.strip.filter(\.lit).map(\.pick) == [.athlete(court[.z1]!)])
    }

    /// Tapping the outside's call chip three times cycles 4 → GO → HUT → 32 and sends the calls.
    @Test func huddleCyclesCalls() {
        let rig = WindowRig()
        Huddle.begin(&rig.s)
        let (hud, sink) = model(rig)
        hud.update(.init(live: rig.s, view: rig.view))
        guard let huddle = hud.huddle else {
            Issue.record("no huddle")
            return
        }
        #expect(huddle.spots.count == 6)
        #expect(hud.strip.isEmpty)
        guard let oh = huddle.spots.first(where: { rig.s.rosters[0][$0.id].position == .outside && $0.zone.isFrontRow }) else {
            Issue.record("no front-row outside")
            return
        }
        #expect(oh.call == .four)
        for _ in 0..<3 { hud.tapCall(oh.id) }
        #expect(sink.actions == [.call(oh.id, .go), .call(oh.id, .hut), .call(oh.id, .thirtyTwo)])
        #expect(hud.huddle?.spots.first { $0.id == oh.id }?.call == .thirtyTwo)
        // SpikeCore takes them; the chip keeps showing the state's call.
        for a in sink.actions { #expect(Huddle.apply(a, from: soloHuman, &rig.s)) }
        hud.update(.init(live: rig.s, view: rig.view))
        #expect(hud.huddle?.spots.first { $0.id == oh.id }?.call == .thirtyTwo)
        // A long press says what it is.
        hud.showMeaning(oh.id)
        #expect(hud.huddle?.meaning == PlayCall.thirtyTwo.meaning)
        // Picks and GO.
        hud.tapPick(.athlete(oh.id))
        #expect(hud.huddle?.spots.first { $0.id == oh.id }?.picked == true)
        #expect(hud.huddle?.ballPicked == false)
        hud.tapReady()
        #expect(sink.actions.suffix(2) == [.pick(.athlete(oh.id)), .ready])
        #expect(hud.huddle?.ready == true)
    }

    /// The prompts are the playtests' words exactly.
    @Test func promptsExact() {
        let rig = WindowRig()
        let (hud, _) = model(rig)
        rig.open(.serve, 2, athlete: rig.s.lineups[0].server(), inTicks: 300)
        hud.update(.init(live: rig.s, view: rig.view))
        #expect(hud.prompt == "HOLD TO TOSS • DRAG TO AIM • LET GO TO SERVE")
        #expect(hud.ring == nil) // no ring until the toss is up
        rig.closeAll()
        let w = rig.open(.attack, 3, athlete: rig.home(.z4))
        hud.update(.init(live: rig.s, view: rig.view))
        #expect(hud.prompt == "TOUCH THEIR COURT WHERE YOU WANT IT")
        let aim = TouchTranslator.Aim(contact: w.id, kind: .attack, point: rig.onTheirCourt(), floor: Vec2(x: -4, z: 0))
        hud.update(.init(live: rig.s, view: rig.view, aim: aim))
        #expect(hud.prompt == "LET GO WHEN THE RING CLOSES • NEAR THE NET = TIP")
        #expect(hud.reticle != nil)
    }

    /// A judged touch flashes its grade; banners name the big moments.
    @Test func gradesAndBanners() {
        let rig = WindowRig()
        let (hud, _) = model(rig)
        let w = rig.open(.receive, 3, athlete: rig.home(.z1))
        rig.ownership.observe([.judged(w.id, .perfect)], in: rig.s)
        hud.update(.init(live: rig.s, events: [.judged(w.id, .perfect), .judged(ContactID(raw: 99), .miss)], view: rig.view))
        #expect(hud.flashes.map(\.text) == ["PERFECT"])
        #expect(hud.flashes[0].perfect)
        var f = HUDModel.Frame(live: rig.s, view: rig.view)
        f.shownEvents = [.point(.home, .block)]
        hud.update(f)
        #expect(hud.banner?.text == "ROOF")
        f.shownEvents = [.fire(rig.home(.z4), on: true)]
        hud.update(f)
        #expect(hud.banner?.text == "ON FIRE" && hud.banner?.hot == true)
        #expect(HUDModel.banner(for: .point(.away, .kill))?.0 == "KILL")
        #expect(HUDModel.banner(for: .point(.home, .ace))?.0 == "ACE")
        #expect(HUDModel.banner(for: .point(.home, .attackError)) == nil)
    }

    /// Every player gets a "#7 OH" tag; nobody playing means no strip and no arrow.
    @Test func tagsForAllTwelve() {
        let s = GameState(settings: MatchSettings())
        let hud = HUDModel(human: nil, ownership: .nobody)
        let view = ScreenProjector(shot: CameraDirector.wideSideline, size: CGSize(width: 874, height: 402))
        hud.update(.init(live: s, view: view))
        #expect(hud.tags.count == 12)
        #expect(Set(hud.tags.map(\.text)).count >= 8)
        #expect(hud.strip.isEmpty && hud.arrowAthlete == nil && hud.prompt == nil)
    }
}
