import Foundation
import SpikeCore
@testable import SpikeNet

/// A `SimHuman` behind a reference, for the client loop's input source.
final class SimBox {
    var sim: SimHuman
    init(_ sim: SimHuman) { self.sim = sim }
}

/// A host and its guests on a `SimNetwork`, all on one virtual clock, stepped a display frame at
/// a time (120 Hz). Each guest is a `PredictingClientLoop` played by a `SimHuman`; the hosting
/// phone's own player is a guest on a link with no delay.
final class Rig {
    final class Guest {
        let end: SimTransport
        let human: HumanID
        let team: TeamSide
        var loop: PredictingClientLoop?
        let sim: SimBox?
        /// The guest's clock runs `clockRate` times as fast as the network's.
        var clockRate = 1.0
        var silent = false
        var welcome: Message? {
            get { welcomeBox.withLock { $0 } }
            set { welcomeBox.withLock { $0 = newValue } }
        }
        let welcomeBox = LockedBox<Message?>(nil)
        /// What each `advance` returned, with the predicted tick it returned at.
        var events: [(tick: Int, event: GameEvent)] = []
        var onFrame: ((Guest) -> Void)?
        var onFrameDebug: ((Guest) -> Void)?

        init(end: SimTransport, human: HumanID, team: TeamSide, sim: SimBox?) {
            self.end = end
            self.human = human
            self.team = team
            self.sim = sim
        }
    }

    let net: SimNetwork
    let serverEnd: SimTransport
    let server: ServerLoop
    var guests: [Guest] = []
    var now: Double = 0
    static let frame = 1.0 / 120
    /// The newest grade the host gave each contact (a rewind can change it).
    var hostGrades: [ContactID: Grade] = [:]
    /// The host's final events (rewound steps replaced), by tick.
    var hostEvents: [Int: [GameEvent]] = [:]

    init(settings: MatchSettings, seed: UInt64 = 1) {
        net = SimNetwork(seed: seed)
        serverEnd = net.endpoint()
        server = ServerLoop(settings: settings, transport: serverEnd)
        server.onStep = { [unowned self] tick, events, _ in
            hostEvents[tick] = events
            for e in events { if case .judged(let id, let g) = e { hostGrades[id] = g } }
        }
    }

    /// A guest on `team` with `link` to the host both ways.
    @discardableResult
    func join(team: TeamSide, link: SimNetwork.Link, skill: Float? = 0.8, pick: Pick = .ball, seed: UInt64 = 1) -> Guest {
        let end = net.endpoint()
        net.setLink(link, between: end.id, and: serverEnd.id)
        let h = server.admit(end.id, team: team)
        let sim = skill.map { SimBox(SimHuman(id: h, team: team, skill: $0, pick: pick, seed: seed)) }
        let g = Guest(end: end, human: h, team: team, sim: sim)
        let box = g.welcomeBox
        end.onReceive = { d, _ in
            if let m = try? Wire.decode(d), case .welcome = m { box.withLock { $0 = m } }
        }
        guests.append(g)
        return g
    }

    /// One display frame.
    func frame() {
        now += Self.frame
        net.advance(to: now)
        server.tick(now: now)
        for g in guests where !g.silent {
            if g.loop == nil, let w = g.welcome {
                let loop = PredictingClientLoop(welcome: w, transport: g.end, server: serverEnd.id)!
                if let sim = g.sim { loop.inputSource = { s in sim.sim.inputs(for: s) } }
                g.loop = loop
            }
            guard let loop = g.loop else { continue }
            for e in loop.advance(to: now * g.clockRate) { g.events.append((loop.predicted.tick, e)) }
            g.onFrame?(g)
            g.onFrameDebug?(g)
        }
    }

    func run(seconds: Double) {
        for _ in 0..<Int((seconds / Self.frame).rounded()) { frame() }
    }

    /// Plays until the host's match is over, then a second more so everything confirms.
    func runMatch(maxSeconds: Double = 60 * 20) {
        var t = 0.0
        while server.state.phase != .matchOver && t < maxSeconds {
            frame()
            t += Self.frame
        }
        run(seconds: 1)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ v: Value) { value = v }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
