import Foundation
import simd
import SpikeCore
import Testing
@testable import SpikeJamDev

/// Landscape viewports: an iPad (4:3), an iPhone SE (667×375) and an iPhone 17 Pro (874×402).
private let aspects: [Float] = [4.0 / 3.0, 667.0 / 375.0, 874.0 / 402.0]

/// Steps a solo match (`local` is the human side) and hands every state and its events to `visit`.
private func play(local: TeamSide, seed: UInt64, seconds: Double, _ visit: (GameState, [GameEvent]) -> Void) {
    var settings = MatchSettings()
    settings.seed = seed
    settings.humanSides = [local]
    var s = GameState(settings: settings)
    for _ in 0..<Int(seconds * Double(Tuning.stepsPerSecond)) {
        let events = step(&s, inputs: [])
        visit(s, events)
        if s.phase == .matchOver { break }
    }
}

@MainActor
@Suite struct CameraDirectorTests {
    /// Spec §4.4: during an owned serve or attack window, every corner of the opponent court
    /// projects inside the viewport, on every screen shape.
    @Test func aimKeepsOpponentCourtVisible() {
        for local in TeamSide.allCases {
            let ownership = SideOwnership(localSide: local)
            let director = CameraDirector(ownership: ownership)
            var seen: [AimWindow: Int] = [:]
            play(local: local, seed: 7, seconds: 150) { s, events in
                guard let window = ownership.aimWindow(in: s) else { return }
                seen[window, default: 0] += 1
                for aspect in aspects {
                    director.aspect = aspect
                    let shot = director.shot(for: s, events: events)
                    for corner in CameraDirector.courtCorners(local.other) {
                        guard let p = shot.project(corner, aspect: aspect) else {
                            Issue.record("\(window) corner \(corner) is behind the camera")
                            return
                        }
                        #expect(abs(p.x) <= 1 && abs(p.y) <= 1, "\(window) at \(aspect): corner \(corner) at \(p)")
                    }
                }
            }
            #expect(seen[.serve, default: 0] > 0)
            #expect(seen[.attack, default: 0] > 0)
        }
    }

    /// Spec §4.4: during `.preServe` the camera stands behind the server, from the serving team's
    /// side, whichever team serves.
    @Test func serveCamBehindServer() {
        let director = CameraDirector(ownership: SideOwnership(localSide: .home))
        var served: Set<TeamSide> = []
        play(local: .home, seed: 3, seconds: 150) { s, events in
            guard case .preServe = s.phase else { return }
            let side = s.score.serving
            served.insert(side)
            let server = s.lineups[side.rawValue].server()
            guard let pos = s.motion[server]?.pos else {
                Issue.record("no server on court")
                return
            }
            let shot = director.shot(for: s, events: events)
            // Further from the net than the server, on the serving team's side.
            #expect((shot.position.x - pos.x) * side.dir < -1, "camera x \(shot.position.x), server x \(pos.x)")
            // Looking over the net at the other court.
            #expect(shot.target.x * side.dir > 0)
        }
        #expect(served == Set(TeamSide.allCases))
    }

    /// Off the aimed touches the camera goes wide, and a kill gets the punch-in on its landing.
    @Test func shotKinds() {
        let director = CameraDirector(ownership: SideOwnership(localSide: .home))
        var kinds: Set<String> = []
        play(local: .home, seed: 11, seconds: 150) { s, events in
            let pick = director.pick(s, events)
            kinds.insert("\(pick.kind)")
            if pick.kind == .killFinish, case .rally = s.phase, let f = s.ball {
                let landing = f.position(at: f.endTime)
                #expect(simd_distance(pick.shot.target, [landing.x, 0.4, landing.z]) < 1e-4)
            }
        }
        #expect(kinds == ["wide", "serve", "swoop", "killFinish"])
    }

    /// The eased camera cuts to the serve and otherwise moves smoothly: no frame jumps far.
    @Test func cameraEasesBetweenShots() {
        let director = CameraDirector(ownership: SideOwnership(localSide: .home))
        var last: CameraShot?
        var lastKind = CameraDirector.Kind.wide
        play(local: .home, seed: 5, seconds: 60) { s, events in
            let shot = director.frame(for: s, events: events, dt: Tuning.dt)
            if let last, !(director.kind == .serve && lastKind != .serve) {
                #expect(simd_distance(last.position, shot.position) < 2.5)
                #expect(abs(last.fov - shot.fov) < 6)
            }
            last = shot
            lastKind = director.kind
        }
    }

    @Test func projectionMatchesTheView() {
        let shot = CameraShot(position: [0, 0, 10], target: [0, 0, 0], fov: 90)
        // Straight ahead is the center; 45° up at the top edge; 45°·aspect across at the side.
        #expect(simd_distance(shot.project([0, 0, 0], aspect: 2)!, [0, 0]) < 1e-5)
        #expect(abs(shot.project([0, 10, 0], aspect: 2)!.y - 1) < 1e-4)
        #expect(abs(shot.project([20, 0, 0], aspect: 2)!.x - 1) < 1e-4)
        #expect(shot.project([0, 0, 20], aspect: 2) == nil)
        // Fitting widens the view until a far-off point is inside it, and never narrows it.
        let narrow = CameraShot(position: [0, 0, 10], target: [0, 0, 0], fov: 40)
        let wide = narrow.fitting([[15, 0, 0]], aspect: 2, edge: 1, bottom: 1)
        #expect(wide.fov > 40 && wide.fov <= 75)
        #expect(abs(wide.project([15, 0, 0], aspect: 2)!.x - 1) < 1e-3)
        #expect(narrow.fitting([[1, 0, 0]], aspect: 2).fov == 40)
        // Below the view, the bottom margin keeps room for the switch strip.
        let low = narrow.fitting([[0, -5, 0]], aspect: 2, bottom: 0.78)
        #expect(abs(low.project([0, -5, 0], aspect: 2)!.y + 0.78) < 1e-3)
    }
}

@MainActor
@Suite struct PresentationTests {
    @Test func slowRateDipsAndRecovers() {
        #expect(Presentation.slowRate(0) == 1)
        #expect(abs(Presentation.slowRate(0.5) - Presentation.slowFloor) < 1e-9)
        #expect(Presentation.slowRate(1) == 1)
        #expect(Presentation.slowRate(0.25) < 1 && Presentation.slowRate(0.25) > Presentation.slowFloor)
    }

    /// Visual only: the match steps at full rate while the drawn moment falls behind on a kill,
    /// then catches up during the dead ball. Every event still comes out, in order.
    @Test func slowMotionOnKillsIsVisualOnly() {
        let p = Presentation()
        var prev: GameState?
        var sawSlow = false, maxLag = 0.0
        var sent: [GameEvent] = [], released: [GameEvent] = []
        var kills = 0
        play(local: .home, seed: 9, seconds: 120) { s, events in
            let before = prev ?? s
            prev = s
            sent += events
            let f = p.frame(prev: before, cur: s, alpha: 0, events: events)
            released += f.events.map(\.event)
            if p.isSlow { sawSlow = true }
            maxLag = max(maxLag, p.lag)
            #expect(f.time <= s.time + 1e-9)
            #expect(f.cur.tick <= s.tick)
            for e in events {
                if case .point(_, .kill) = e { kills += 1 }
            }
            // Live again by the next serve.
            if case .preServe = s.phase, s.tick % 30 == 0 { #expect(p.lag == 0) }
        }
        #expect(kills > 0)
        #expect(sawSlow)
        #expect(maxLag > 0.15 && maxLag < Presentation.maxLag)
        // All but the last moment's events are out, in the order they happened.
        #expect(Array(sent.prefix(released.count)) == released)
        #expect(sent.count - released.count < 4)
    }
}

@MainActor
@Suite struct FeelTests {
    @Test func hapticsScaleWithPowerAndGrade() {
        let soft = Haptics.pulse(kind: .dig, power: 0.1, grade: .good)
        let hard = Haptics.pulse(kind: .dig, power: 0.9, grade: .good)
        #expect(hard.intensity > soft.intensity)
        #expect(Haptics.pulse(kind: .attack, power: 0.5, grade: .perfect).style == .rigid)
        #expect(Haptics.pulse(kind: .attack, power: 0.5, grade: .poor).style == .light)
        #expect(Haptics.pulse(kind: .attack, power: 1, grade: .perfect).intensity <= 1)
    }

    @Test func hapticsOnlyForYourTouchesAndHeavyForKills() {
        let s = GameState(settings: MatchSettings())
        let mine = s.lineups[0].server(), theirs = s.lineups[1].server()
        let events = [
            FeltEvent(event: .touched(.receive, mine, quality: 0.9)),
            FeltEvent(event: .touched(.receive, theirs, quality: 0.9)),
            FeltEvent(event: .point(.home, .kill)),
            FeltEvent(event: .point(.away, .block)),
        ]
        let pulses = Haptics.pulses(for: events, ownership: SideOwnership(localSide: .home), in: s)
        #expect(pulses.count == 3)
        #expect(pulses[1] == Haptics.Pulse(style: .heavy, intensity: 1))
        #expect(pulses[2].style == .heavy && pulses[2].intensity < 1)
        // Nobody playing, no haptics.
        #expect(Haptics.pulses(for: events, ownership: SideOwnership(localSide: nil), in: s).isEmpty)
    }

    @Test func soundCues() {
        let s = GameState(settings: MatchSettings())
        let id = s.lineups[0].server()
        let cues = Sounds.cues(for: [
            FeltEvent(event: .touched(.set, id, quality: 1)),
            FeltEvent(event: .erred(.attack, id, .net)),
            FeltEvent(event: .point(.away, .attackError)),
            FeltEvent(event: .point(.home, .kill)),
        ])
        #expect(cues == [.set, .net, .floor, .crowd(level: 0.45), .floor, .crowd(level: 1)])
        // The synthesized buffers build without trouble.
        _ = Sounds()
    }

    @Test func startChoicesMakeTheSettings() {
        let c = StartChoices(gameType: .womens, tempo: .stupidFast, difficulty: .hard, system: .sixTwo, startingRotation: 4)
        let s = c.matchSettings(seed: 42)
        #expect(s.gameType == .womens)
        #expect(s.tempo == .stupidFast)
        #expect(s.difficulty == .hard)
        #expect(s.seed == 42)
        #expect(s.humanSides == [.home])
        #expect(s.team(.home) == TeamSettings(system: .sixTwo, startingRotation: 4))
        #expect(s.team(.away) == TeamSettings())
        #expect(s.validate().isEmpty)
        // The defaults are the spec's: men's, Faster, medium, a 5-1 from rotation 1.
        let d = StartChoices().matchSettings(seed: 1)
        #expect(d.gameType == .mens && d.tempo == .faster && d.difficulty == .medium)
        #expect(d.team(.home) == TeamSettings())
        // A match runs from them.
        var g = GameState(settings: s)
        for _ in 0..<600 { _ = step(&g, inputs: []) }
        #expect(g.tick == 600)
    }
}
