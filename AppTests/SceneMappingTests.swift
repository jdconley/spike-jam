import Foundation
import RealityKit
import simd
import SpikeArt
import SpikeCore
import Testing
@testable import SpikeJam

@MainActor
@Suite struct SceneMappingTests {
    @Test func heightScaling() {
        #expect(abs(SceneMapping.rigScale(heightM: 2.05) - 2.05 / 1.9) < 1e-4)
        // And the rig the scene builds really is that size.
        let s = GameState(settings: MatchSettings())
        let athlete = s.rosters[0].athletes[2]
        let rig = PlayerRig(look: SceneMapping.look(for: athlete, gameType: .mens), heightM: athlete.heightM)
        #expect(abs(rig.entity.scale.x - athlete.heightM / 1.9) < 1e-4)
    }

    /// Rigs are built facing +z: home turns to face +x (the net from its side), away −x.
    @Test func teamFacing() {
        func facing(_ yaw: Float) -> SIMD3<Float> { simd_quatf(angle: yaw, axis: [0, 1, 0]).act([0, 0, 1]) }
        let home = facing(SceneMapping.netYaw(.home))
        let away = facing(SceneMapping.netYaw(.away))
        #expect(simd_distance(home, [1, 0, 0]) < 1e-5)
        #expect(simd_distance(away, [-1, 0, 0]) < 1e-5)
        #expect(abs(SceneMapping.netYaw(.home) - .pi / 2) < 1e-5)
        // Running faces the run; a shuffle keeps facing the net.
        let run = facing(SceneMapping.facingYaw(team: .home, gait: .run, velocity: Vec2(x: 0, z: -4)))
        #expect(simd_distance(run, [0, 0, -1]) < 1e-5)
        let shuffle = facing(SceneMapping.facingYaw(team: .away, gait: .shuffle, velocity: Vec2(x: 0, z: 3)))
        #expect(simd_distance(shuffle, [-1, 0, 0]) < 1e-5)
    }

    @Test func gaitToPose() {
        func pose(_ g: Gait, speed: Float = 3, rally: Bool = true) -> Pose {
            SceneMapping.pose(gait: g, velocity: Vec2(x: speed, z: 0), jump: nil, tick: 100, contact: nil,
                              inRally: rally, nearNet: false).pose
        }
        #expect(pose(.stand, speed: 0, rally: false) == .stand)
        #expect(pose(.stand, speed: 0) == .shuffle) // the ready stance in a rally
        #expect(pose(.run) == .run)
        #expect(pose(.run, speed: 0, rally: false) == .stand)
        #expect(pose(.shuffle) == .shuffle)
        #expect(pose(.backpedal) == .shuffle)
        #expect(pose(.approach) == .approach)
        #expect(pose(.dive) == .dive)
        // Every gait maps to something, including any SpikeCore adds later (the default case).
        for g in Gait.allCases { _ = pose(g) }
    }

    @Test func jumpsAndContacts() {
        let jump = Jump(startTick: 100, durationTicks: 30, height: 0.9)
        func pose(tick: Int, contact: SceneMapping.Contact?, nearNet: Bool) -> SceneMapping.PoseChoice {
            SceneMapping.pose(gait: .approach, velocity: .zero, jump: jump, tick: tick, contact: contact,
                              inRally: true, nearNet: nearNet)
        }
        let attack = SceneMapping.Contact(kind: TouchKind.attack.rawValue, secondsToGo: 0.1)
        let swing = pose(tick: 115, contact: attack, nearNet: true)
        #expect(swing.pose == .spikeSwing)
        #expect(abs(swing.phase - 0.5) < 1e-5) // contact at the peak
        #expect(pose(tick: 110, contact: nil, nearNet: true).pose == .block)
        #expect(pose(tick: 110, contact: SceneMapping.Contact(kind: "block", secondsToGo: 0.1), nearNet: false).pose == .block)
        #expect(pose(tick: 110, contact: nil, nearNet: false).pose == .jump)
        // On the floor before and after the jump.
        #expect(pose(tick: 100, contact: nil, nearNet: true).pose == .approach)
        #expect(pose(tick: 130, contact: nil, nearNet: true).pose == .approach)

        func touch(_ kind: TouchKind, in seconds: Double) -> Pose {
            SceneMapping.pose(gait: .run, velocity: .zero, jump: nil, tick: 0,
                              contact: SceneMapping.Contact(kind: kind.rawValue, secondsToGo: seconds),
                              inRally: true, nearNet: false).pose
        }
        #expect(touch(.receive, in: 0.2) == .passPlatform)
        #expect(touch(.dig, in: 0.1) == .passPlatform)
        #expect(touch(.set, in: 0.2) == .setHands)
        #expect(touch(.receive, in: 2) == .shuffle) // too early for the platform
    }

    @Test func netHeightFollowsGameType() {
        var settings = MatchSettings()
        settings.gameType = .mens
        #expect(SceneMapping.netHeight(settings) == CourtModel.menNetHeight)
        settings.gameType = .womens
        #expect(SceneMapping.netHeight(settings) == CourtModel.womenNetHeight)
    }

    @Test func looksMatchTheRoster() {
        let s = GameState(settings: MatchSettings())
        for roster in s.rosters {
            let looks = roster.athletes.map { SceneMapping.look(for: $0, gameType: .mens) }
            for (a, look) in zip(roster.athletes, looks) {
                #expect(look.number == a.number)
                #expect(look.skinTone == a.skinTone)
                #expect(look.isLibero == (a.position == .libero))
                #expect(look.team == SceneMapping.artTeam(a.id.team))
            }
            #expect(Set(looks).count == looks.count) // no two teammates alike
        }
    }

    @Test func ballFollowsFlight() {
        let f = Flight.make(from: Vec3(x: -8, y: 2, z: 0), to: Vec3(x: 6, y: 0, z: 1), duration: 1, startTime: 10)
        let mid = SceneMapping.ballPosition(f, at: 10.5)!
        let expected = f.position(at: 10.5)
        #expect(simd_distance(mid, [expected.x, expected.y, expected.z]) < 1e-5)
        // Held at the landing after the flight, never under the floor.
        let after = SceneMapping.ballPosition(f, at: 12)!
        #expect(abs(after.x - 6) < 1e-4 && after.y >= SceneMapping.ballRadius)
        #expect(SceneMapping.ballPosition(nil, at: 10) == nil)
    }

    @Test func onFireReadsTheState() {
        var s = GameState(settings: MatchSettings())
        #expect(SceneMapping.onFire(in: s).isEmpty)
        let id = s.lineups[0].server()
        s.fire[id] = FireState(killStreak: 3, onFire: true)
        s.fire[s.lineups[1].server()] = FireState(killStreak: 2)
        #expect(SceneMapping.onFire(in: s) == [id])
    }

    @Test func interpolationMeetsTheStates() {
        var cur = GameState(settings: MatchSettings())
        let prev = cur
        _ = step(&cur, inputs: [])
        #expect(SceneMapping.renderTime(prev: prev, cur: cur, alpha: 0) == prev.time)
        #expect(abs(SceneMapping.renderTime(prev: prev, cur: cur, alpha: 1) - cur.time) < 1e-12)
        #expect(abs(SceneMapping.lerpAngle(3, -3, 0.5) - .pi) < 0.01) // the short way, through π
    }

    /// The scene draws a stepped match without trouble: every on-court player has a visible rig.
    @Test func sceneDrawsAMatch() {
        let view = ARView(frame: CGRect(x: 0, y: 0, width: 400, height: 200), cameraMode: .nonAR,
                          automaticallyConfigureSession: false)
        let scene = CourtScene(arView: view)
        var cur = GameState(settings: MatchSettings())
        var prev = cur
        for _ in 0..<240 {
            prev = cur
            _ = step(&cur, inputs: [])
            scene.update(prev: prev, cur: cur, alpha: 0.5)
        }
        let visible = scene.rigs.filter { $0.value.entity.isEnabled }.map(\.key)
        #expect(Set(visible) == Set(cur.motion.keys))
        #expect(visible.count == 12)
        #expect(scene.court.netHeight == cur.settings.gameType.netHeight)
    }
}
