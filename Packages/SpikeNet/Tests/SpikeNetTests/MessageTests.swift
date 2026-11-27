import Foundation
import SpikeCore
import Testing
@testable import SpikeNet

/// A state with everything going: two humans, a rally in progress with the ball in the air.
func busyState(seed: UInt64 = 7) -> GameState {
    var settings = MatchSettings()
    settings.seed = seed
    var humans = [SimHuman(id: HumanID(raw: 1), team: .home, skill: 0.8, seed: seed),
                  SimHuman(id: HumanID(raw: 2), team: .away, skill: 0.8, seed: seed + 1)]
    var s = GameState(settings: settings, humans: humans.map(\.slot))
    for _ in 0..<(60 * 20) {
        let inputs = humans.indices.flatMap { humans[$0].inputs(for: s) }
        _ = step(&s, inputs: inputs)
        if s.tick > 60 * 12, s.ball != nil, s.phase == .rally, !s.inputBuffer.isEmpty || s.notes.block != nil { break }
    }
    return s
}

@Suite struct MessageTests {
    @Test func roundTripAll() throws {
        let s = busyState()
        let h = HumanID(raw: 3)
        let snap = Snapshot(
            tick: s.tick, dynamic: s.dynamic(),
            confirmedThrough: [Confirmation(human: h, input: 9, reliable: 2, packetTick: s.tick + 2)],
            confirmed: Confirmed(tick: s.tick - 9, points: [3, 4], winner: nil,
                                 celebrations: [Celebration(seq: 1, tick: 40, kind: .point(.home, .kill)),
                                                Celebration(seq: 2, tick: 41, kind: .sideOut(.home, rotation: 2)),
                                                Celebration(seq: 3, tick: 41, kind: .fire(AthleteID(team: .home, index: 2), on: true)),
                                                Celebration(seq: 4, tick: 99, kind: .matchWon(.away))]))
        let c = ContactID(raw: 77)
        let a = AthleteID(team: .away, index: 3)
        let actions: [InputAction] = [
            .press(contact: c), .release(contact: c, aim: Vec2(x: -4, z: 1.5)), .release(contact: c, aim: nil),
            .tap(contact: c), .setTo(contact: c, hitter: a), .block(contact: c), .read(hitter: a),
            .pick(.ball), .pick(.athlete(a)), .call(a, .slide), .combo(.x), .switchTo(.athlete(a)), .ready,
            .teamSettings(TeamSettings(system: .sixTwo, startingRotation: 4, difficulty: .hard)),
        ]
        var messages: [Message] = [
            .hello(nickname: "Pancake Pete", version: Wire.version),
            .welcome(human: h, settings: s.settings, startTick: 1234),
            .inputs(tick: 99, ack: 97, first: 12,
                    items: actions.enumerated().map { NetInput(PlayerInput(human: h, tick: 90 + $0.offset, offset: 0.004, action: $0.element), seen: $0.offset % 2 == 0 ? 95 : nil) }),
            .inputs(tick: -1, ack: -1, first: 0, items: []),
            .snapshot(snap),
            .timeHint(adjustPPM: -1000),
            .timeHint(adjustPPM: Int16.max),
            .ack(seq: 41),
            .bye,
            .paused(tick: 4321),
        ]
        messages += actions.map { .reliable(seq: 5, $0) }
        for m in messages {
            do {
                let d = try Wire.encode(m)
                #expect(try Wire.decode(d) == m, "\(m)")
                #expect(d.count <= Wire.maxPacket)
            } catch {
                Issue.record("\(String(describing: m).prefix(80)): \(error)")
            }
        }
        // A snapshot carries the whole changing state, unchanged.
        guard case .snapshot(let back) = try Wire.decode(try Wire.encode(.snapshot(snap))) else {
            Issue.record("not a snapshot")
            return
        }
        #expect(GameState(settings: s.settings, rosters: s.rosters, dynamic: back.dynamic) == s)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try Wire.decode(Data([1, 2, 3])) }
        #expect(throws: (any Error).self) { try Wire.decode(Data([Wire.format, 200, 7])) }
        #expect(throws: (any Error).self) { try Wire.decode(Data()) }
        // A truncated snapshot.
        let d = try! Wire.encode(.snapshot(Snapshot(tick: 1, dynamic: busyState().dynamic(), confirmedThrough: [],
                                                    confirmed: Confirmed(tick: 0, points: [0, 0], winner: nil, celebrations: []))))
        #expect(throws: (any Error).self) { try Wire.decode(d.prefix(d.count - 3)) }
    }

    /// The busiest snapshot of 50 matches, two simulated humans each, fits a packet.
    @Test func snapshotFits() throws {
        var biggest = 0
        var at = ""
        for m in 0..<50 {
            var settings = MatchSettings()
            settings.seed = UInt64(100 + m)
            var humans = [SimHuman(id: HumanID(raw: 1), team: .home, skill: 0.7, seed: settings.seed),
                          SimHuman(id: HumanID(raw: 2), team: .away, skill: 0.7, seed: settings.seed + 1)]
            var s = GameState(settings: settings, humans: humans.map(\.slot))
            while s.phase != .matchOver && s.tick < 60 * 60 * 20 {
                let inputs = humans.indices.flatMap { humans[$0].inputs(for: s) }
                _ = step(&s, inputs: inputs)
                // Sampled when everything is in play: the ball in the air and all twelve moving.
                guard s.tick % 7 == 0, s.ball != nil, s.motion.values.filter({ $0.vel != .zero }).count == 12 else { continue }
                let snap = Snapshot(tick: s.tick, dynamic: s.dynamic(),
                                    confirmedThrough: humans.map { Confirmation(human: $0.id, input: 99_999, reliable: 999, packetTick: s.tick + 3) },
                                    confirmed: Confirmed(tick: s.tick - 9, points: s.score.points, winner: nil,
                                                         celebrations: (0..<ServerLoop.celebrationsPerSnapshot).map {
                                                             Celebration(seq: UInt32(1000 + $0), tick: s.tick - 30, kind: .fire(AthleteID(team: .home, index: 5), on: true))
                                                         }))
                let n = try Wire.encode(.snapshot(snap)).count
                if n > biggest {
                    biggest = n
                    at = "match \(m) tick \(s.tick)"
                }
            }
        }
        print("biggest snapshot: \(biggest) bytes (\(at))")
        #expect(biggest > 0 && biggest <= Wire.maxPacket)
    }

    @Test func applyRestores() {
        let s1 = busyState(seed: 3)
        var s2 = GameState(settings: s1.settings)
        #expect(s2 != s1)
        s2.apply(s1.dynamic())
        #expect(s2 == s1)
        // A team's system changed in the first huddle: the rosters follow the settings.
        var settings = s1.settings
        settings.teams[1].system = .sixTwo
        let s3 = GameState(settings: settings, humans: s1.humans)
        var s4 = GameState(settings: s1.settings, humans: s1.humans)
        s4.apply(s3.dynamic())
        #expect(s4 == s3)
    }
}
