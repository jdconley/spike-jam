import Foundation
import SpikeCore
import Testing
@testable import SpikeNet

/// A match played locally with no network, for comparing against the host: a simulated human on
/// home, every input it made with the step it went into, and the pass it makes after `after`.
struct Reference {
    var log: [(step: Int, input: PlayerInput)] = []
    var states: [Int: GameState] = [:]
    /// The pass or dig, its contact tick, its tap and its grade.
    var contact = ContactID.none
    var contactTick = 0
    var tap: PlayerInput?
    var grade: Grade?

    init(settings: MatchSettings, after: Int, extra: Int) {
        var sim = SimHuman(id: HumanID(raw: 1), team: .home, skill: 0.95, seed: 3)
        var s = GameState(settings: settings, humans: [sim.slot])
        while tap == nil || s.tick < contactTick + extra {
            let inputs = sim.inputs(for: s)
            for i in inputs { log.append((s.tick, i)) }
            if contact != .none, tap == nil { tap = inputs.first { $0.contact == contact } }
            for e in step(&s, inputs: inputs) {
                switch e {
                case .window(let id, let kind, _, let at) where contact == .none && s.tick > after && (kind == .receive || kind == .dig):
                    contact = id
                    contactTick = at
                case .judged(let id, let g) where id == contact:
                    grade = g
                default:
                    break
                }
            }
            states[s.tick] = s
            precondition(s.tick < 60 * 600, "no pass")
        }
    }
}

/// A host and one scripted guest on a perfect link: the guest's inputs go when the test says.
final class Scripted {
    let net = SimNetwork()
    let end: SimTransport
    let server: ServerLoop
    let human: HumanID
    var now = 0.0
    var seq: UInt32 = 1
    var grades: [ContactID: Grade] = [:]

    init(settings: MatchSettings) {
        let s = net.endpoint()
        end = net.endpoint()
        server = ServerLoop(settings: settings, transport: s)
        human = server.admit(end.id, team: .home)
        serverID = s.id
        server.onStep = { [unowned self] _, events, _ in
            for e in events { if case .judged(let id, let g) = e { grades[id] = g } }
        }
    }

    let serverID: PeerID

    func send(_ i: PlayerInput, seen: Int? = nil) {
        let m = Message.inputs(tick: i.tick + 2, ack: -1, first: seq, items: [NetInput(i, seen: seen)])
        seq += 1
        end.send(try! Wire.encode(m), to: serverID)
    }

    /// One 120 Hz frame.
    func frame() {
        // Something every frame, so the host never thinks the guest has gone.
        let tick = Int(now / Tuning.dt) + 2
        end.send(try! Wire.encode(.inputs(tick: tick, ack: -1, first: seq, items: [])), to: serverID)
        now += 1.0 / 120
        net.advance(to: now)
        server.tick(now: now)
    }
}

@Suite struct ServerLoopTests {
    /// A guest whose clock runs 2% fast: after 10 s of hints its inputs keep arriving 1–2 steps
    /// early.
    @Test func bufferConverges() {
        let rig = Rig(settings: MatchSettings())
        let g = rig.join(team: .home, link: .init(oneWayDelay: 0.040, jitter: 0.004), skill: nil)
        g.clockRate = 1.02
        rig.run(seconds: 10)
        var inRange = 0, samples = 0
        for _ in 0..<(120 * 10) {
            rig.frame()
            guard let b = rig.server.buffer(of: g.human) else { continue }
            samples += 1
            if (1...2).contains(b) { inRange += 1 }
        }
        print("buffer in 1...2 for \(inRange) of \(samples) frames; slack \(rig.server.slack(of: g.human) ?? -1)")
        #expect(samples > 1000)
        #expect(Double(inRange) >= 0.95 * Double(samples))
    }

    /// Plays the reference's inputs to the host on time, except the pass's tap, which arrives
    /// `late` seconds after its contact.
    func playLate(_ late: Double) -> (Reference, Scripted) {
        let settings = MatchSettings()
        let ref = Reference(settings: settings, after: 60 * 8, extra: 40)
        let host = Scripted(settings: settings)
        #expect(host.human == HumanID(raw: 1))
        // SimHuman stamps every input with the step it goes into.
        #expect(ref.log.allSatisfy { $0.step == $0.input.tick })
        var next = 0
        var tapSent = false
        let tap = ref.tap!
        while host.server.state.tick < ref.contactTick + 40 {
            // An input stamped n goes into the step from n, so it's sent during tick n.
            let tick = Int((host.now + 1.0 / 120) / Tuning.dt)
            while next < ref.log.count, ref.log[next].input.tick <= tick {
                if ref.log[next].input != tap { host.send(ref.log[next].input) }
                next += 1
            }
            if !tapSent, host.now + 1.0 / 120 >= Double(ref.contactTick) * Tuning.dt + late {
                host.send(tap, seen: ref.contactTick)
                tapSent = true
            }
            host.frame()
        }
        return (ref, host)
    }

    /// An owned pass tap 120 ms after its contact (within the cap) is graded against its own
    /// time, and the match goes on exactly as if it had come on time.
    @Test func lateTouchRewinds() {
        let (ref, host) = playLate(0.120)
        #expect(host.server.stats[host.human]?.rewound == 1)
        #expect(host.grades[ref.contact] == ref.grade)
        #expect(ref.grade != .miss)
        let t = ref.contactTick + 40
        #expect(host.server.state(at: t) == ref.states[t])
    }

    @Test func beyondCapIsMiss() {
        let (ref, host) = playLate(0.200)
        #expect(ref.grade != .miss)
        #expect(host.grades[ref.contact] == .miss)
    }

    /// A guest silent for 1.1 s has no owner on the next contact; `rejoin` restores its slot.
    @Test func droppedGetsAI() {
        var settings = MatchSettings()
        settings.seed = 11
        let rig = Rig(settings: settings)
        let g = rig.join(team: .home, link: .init(oneWayDelay: 0.020), skill: 0.9)
        var dropped: [HumanID] = []
        rig.server.onDrop = { dropped.append($0) }
        rig.run(seconds: 12)
        #expect(rig.server.state.humans.map(\.id) == [g.human])
        // Silent: the phone sleeps.
        g.silent = true
        rig.run(seconds: 1.1)
        #expect(dropped == [g.human])
        #expect(rig.server.state.humans.isEmpty)
        // The next home contact the AI plays.
        let after = rig.server.state.nextContactID
        var checked = false
        for _ in 0..<(120 * 30) where !checked {
            rig.frame()
            if let c = rig.server.state.pending, c.id >= after, c.team == .home, c.kind != nil {
                #expect(c.owner == nil)
                checked = true
            }
        }
        #expect(checked)
        // Back, on a new address, as the same human on the same team, with a fresh pick.
        let back = rig.net.endpoint()
        #expect(rig.server.rejoin(back.id, as: g.human))
        let slot = rig.server.state.human(g.human)
        #expect(slot?.team == .home && slot?.pick == .ball)
        #expect(rig.server.connected[back.id] == g.human)
        #expect(!rig.server.rejoin(back.id, as: HumanID(raw: 99)))
    }
}
