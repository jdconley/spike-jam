#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SpikeCore

/// The host, in charge of the match (spec §5.3). It runs SpikeCore at 60 steps a second, takes
/// each guest's inputs, judges their touches in the toucher's favour, and sends everyone
/// snapshots. The same loop runs in-process on a hosting phone and, later, on the match server.
///
/// - Inputs: each guest runs ahead so its inputs arrive 1–2 steps before they're needed, kept
///   there by `timeHint`s. An input that arrives after its step but within `rewindCap` of it is
///   played as if it had come on time: the host rewinds to that step from its ring of the last
///   60 states, adds the input and steps back to now. Later than that, it counts from now, which
///   for a touch is a miss.
/// - Snapshots go every `snapshotEvery` steps. Celebrations and the score in them are confirmed
///   only once they are older than the rewind cap, so a late touch never takes one back.
/// - Reliable actions (the huddle's) are applied in order and acked.
/// - A guest silent for `dropAfter` is dropped: the AI takes over their athlete, and their slot is
///   kept for `rejoin`.
///
/// Not thread-safe: call it from one thread. The transport may deliver on any.
public final class ServerLoop {
    public static let rewindCap: Double = 0.150
    /// `rewindCap` in steps.
    public static let capTicks = Int((rewindCap * Double(Tuning.stepsPerSecond)).rounded())
    public static let snapshotEvery = 2
    public static let ringSize = 60
    public static let dropAfter: Double = 1.0
    /// The slack the time hints aim for: how many steps before it's needed a guest's newest input
    /// arrives, measured when the host takes the packet. 1.5 keeps the whole steps of input
    /// waiting beyond the host's tick (`buffer(of:)`) at 1–2.
    public static let targetSlack: Double = 1.5
    /// The biggest speed change a hint asks for. A real clock drifts by tens of parts per million,
    /// but a guest's display link can run a percent or two off, so this is ±2.5%.
    public static let maxHintPPM = 25_000
    public static let hintEvery = 6
    public static let celebrationsPerSnapshot = 8
    /// The most steps one `tick` takes; a longer stall is skipped, not caught up.
    public static let maxStepsPerTick = 30

    public struct Stats: Equatable, Sendable {
        /// Unreliable inputs taken, each once however many copies came.
        public var inputs = 0
        public var touchInputs = 0
        /// Touch inputs that came after their step but within the cap.
        public var rewound = 0
        /// Touch inputs that came beyond the cap.
        public var tooLate = 0
        public var reliable = 0
    }

    struct Peer {
        var human: HumanID
        var lastHeard: Double
        /// Got the welcome: it has sent inputs.
        var welcomed = false
        var lastWelcome: Double = -.infinity
        var inputSeq: UInt32 = 0
        var reliableSeq: UInt32 = 0
        var heldReliable: [UInt32: InputAction] = [:]
        var packetTick = -1
        var slack: Double?
        var integral: Double = 0
        var hintPPM = 0
    }

    /// One step taken: the state it started from, the inputs it took, and what happened.
    struct Frame {
        var before: GameState
        var inputs: [PlayerInput]
        var events: [GameEvent]
        var score: Score
    }

    public private(set) var state: GameState
    public private(set) var stats: [HumanID: Stats] = [:]
    /// Each step as it's taken, and again if a rewind takes it again (`replayed`).
    public var onStep: ((_ tick: Int, _ events: [GameEvent], _ replayed: Bool) -> Void)?
    /// A guest that isn't playing said hello: the host's session decides whether to admit them.
    public var onHello: ((_ peer: PeerID, _ nickname: String, _ version: Int) -> Void)?
    /// A guest went silent and the AI took over.
    public var onDrop: ((HumanID) -> Void)?

    private let transport: any Transport
    private let inbox = Inbox()
    private var peers: [PeerID: Peer] = [:]
    /// The slots of dropped humans, kept for a rejoin.
    private var dropped: [HumanID: HumanSlot] = [:]
    private var nextHuman: UInt8 = 1
    private var startTime: Double?
    private var now: Double = 0
    private var ring: [Frame] = []
    /// Inputs not played yet, in arrival order (`Placement`).
    private var pending: [NetInput] = []
    private var lastSnapshot = Int.min
    private var lastHint = Int.min
    /// Steps through this tick are final.
    private var finalTick: Int
    private var finalScore: Score
    private var celebrations: [Celebration] = []
    private var nextCelebration: UInt32 = 1

    public init(settings: MatchSettings, transport: any Transport) {
        state = GameState(settings: settings)
        finalTick = state.tick
        finalScore = state.score
        self.transport = transport
        let inbox = inbox
        transport.onReceive = { d, peer in inbox.put(d, from: peer) }
    }

    /// The score as confirmed for good (what the guests draw).
    public var confirmedPoints: [Int] { finalScore.points }

    /// The humans playing now, by peer.
    public var connected: [PeerID: HumanID] { peers.mapValues(\.human) }

    /// A guest joins `team`. Before the first `tick` this sets up the match's humans; after it,
    /// they join the match in progress.
    @discardableResult
    public func admit(_ peer: PeerID, team: TeamSide) -> HumanID {
        let h = HumanID(raw: nextHuman)
        nextHuman &+= 1
        let slot = HumanSlot(id: h, team: team)
        if startTime == nil {
            state = GameState(settings: state.settings, humans: state.humans + [slot])
            finalScore = state.score
        } else {
            commitRing()
            state.humans.append(slot)
            state.settings.humanSides.insert(team)
        }
        peers[peer] = Peer(human: h, lastHeard: now)
        stats[h] = Stats()
        if startTime != nil { welcome(peer) }
        return h
    }

    /// A dropped guest (or one reconnecting before the drop) comes back as `human`, on the same
    /// team. Their pick starts again as "ball" until they pick in a huddle (spec §5.3). False if
    /// `human` never played here.
    @discardableResult
    public func rejoin(_ peer: PeerID, as human: HumanID) -> Bool {
        if let old = peers.first(where: { $0.value.human == human }) {
            // Still connected under another address: move them over, starting their numbering
            // again, since it's a new client.
            peers[old.key] = nil
        } else if var slot = dropped.removeValue(forKey: human) {
            commitRing()
            slot.pick = .ball
            slot.switched = nil
            slot.ready = false
            state.humans.append(slot)
        } else {
            return false
        }
        peers[peer] = Peer(human: human, lastHeard: now)
        if startTime != nil { welcome(peer) }
        return true
    }

    /// The host's tick for the clock's `now`, with the fraction since it.
    func clockTick(_ now: Double) -> Double {
        guard let startTime else { return Double(state.tick) }
        return (now - startTime) / Tuning.dt
    }

    /// Takes what arrived, steps the match up to `now` (seconds on any steady clock), and sends.
    public func tick(now: Double) {
        self.now = now
        if startTime == nil {
            startTime = now - Double(state.tick) * Tuning.dt
            for p in peers.keys { welcome(p) }
            for k in peers.keys { peers[k]!.lastHeard = now }
        }
        receive()
        let target = Int((clockTick(now) + 1e-9).rounded(.down))
        var steps = 0
        while state.tick < target && steps < Self.maxStepsPerTick {
            stepOnce()
            steps += 1
        }
        if state.tick < target { startTime = now - Double(state.tick) * Tuning.dt }
        dropSilent()
        if state.tick >= lastSnapshot + Self.snapshotEvery {
            lastSnapshot = state.tick
            sendSnapshot()
        }
        if state.tick >= lastHint + Self.hintEvery {
            lastHint = state.tick
            sendHints()
        }
        for (p, peer) in peers where !peer.welcomed && now - peer.lastWelcome >= 0.25 { welcome(p) }
    }

    /// How many whole steps of `human`'s input the host holds beyond its current tick: 1–2 when
    /// the time hints are doing their job.
    public func buffer(of human: HumanID) -> Int? {
        guard let p = peers.values.first(where: { $0.human == human }), p.packetTick >= 0 else { return nil }
        return p.packetTick - state.tick
    }

    /// The smoothed slack of `human`'s inputs (`targetSlack`).
    public func slack(of human: HumanID) -> Double? {
        peers.values.first { $0.human == human }?.slack
    }

    /// The state at `tick` if the ring still has it.
    public func state(at tick: Int) -> GameState? {
        if tick == state.tick { return state }
        return ring.first { $0.before.tick == tick }?.before
    }

    // MARK: - Receiving

    func receive() {
        var rewindFrom: Int?
        for (data, from) in inbox.take() {
            guard let m = try? Wire.decode(data) else { continue }
            switch m {
            case .hello(let nickname, let version):
                if peers[from] == nil {
                    onHello?(from, nickname, version)
                } else {
                    welcome(from)
                }
            case .inputs(let tick, _, let first, let items):
                guard var p = peers[from] else { continue }
                p.lastHeard = now
                p.welcomed = true
                if tick > p.packetTick {
                    p.packetTick = tick
                    let slack = Double(tick) - clockTick(now)
                    p.slack = p.slack.map { $0 + 0.1 * (slack - $0) } ?? slack
                }
                for (i, item) in items.enumerated() {
                    let seq = first &+ UInt32(i)
                    guard seq > p.inputSeq else { continue }
                    p.inputSeq = seq
                    var item = item
                    item.input.human = p.human
                    if let t = take(item), rewindFrom.map({ t < $0 }) ?? true { rewindFrom = t }
                }
                peers[from] = p
            case .reliable(let seq, let action):
                guard var p = peers[from] else { continue }
                p.lastHeard = now
                if seq > p.reliableSeq { p.heldReliable[seq] = action }
                while let a = p.heldReliable.removeValue(forKey: p.reliableSeq &+ 1) {
                    p.reliableSeq &+= 1
                    pending.append(NetInput(PlayerInput(human: p.human, tick: state.tick, action: a)))
                    stats[p.human, default: Stats()].reliable += 1
                }
                peers[from] = p
                send(.ack(seq: p.reliableSeq), to: from)
            case .bye:
                if let p = peers[from] { drop(from, p.human) }
            case .welcome, .snapshot, .timeHint, .ack:
                break
            }
        }
        if let t = rewindFrom { rewind(from: t) }
    }

    /// Takes one new input. A touch for a step already taken, within the cap, goes into that step
    /// (placed by `Placement`) and returns its tick to rewind from; the rest wait for their step.
    func take(_ item: NetInput) -> Int? {
        let input = item.input
        var s = stats[input.human, default: Stats()]
        defer { stats[input.human] = s }
        s.inputs += 1
        // Far-future ticks are a broken clock.
        guard input.tick <= state.tick + 60 * 10 else { return nil }
        guard input.contact != nil else {
            pending.append(item)
            return nil
        }
        s.touchInputs += 1
        // Placed against the contact as it was at the input's own step, which may be over now.
        let then = input.tick < state.tick ? ring.first(where: { $0.before.tick == input.tick })?.before : nil
        // On time, or its contact isn't open yet: it waits.
        guard let placed = Placement.placed(item, then ?? state), placed.tick < state.tick else {
            pending.append(item)
            return nil
        }
        if state.tick - placed.tick <= Self.capTicks, let i = ring.firstIndex(where: { $0.before.tick == placed.tick }) {
            s.rewound += 1
            ring[i].inputs.append(placed)
            return placed.tick
        }
        // Beyond the cap it counts from now: for a touch, a miss.
        s.tooLate += 1
        pending.append(item)
        return nil
    }

    // MARK: - Stepping

    func stepOnce() {
        let due = Placement.takeDue(&pending, state)
        let before = state
        let events = step(&state, inputs: due)
        ring.append(Frame(before: before, inputs: due, events: events, score: state.score))
        if ring.count > Self.ringSize { ring.removeFirst(ring.count - Self.ringSize) }
        onStep?(state.tick, events, false)
        finalize(through: state.tick - Self.capTicks)
    }

    /// Steps again from `tick` to now, with the inputs added since.
    func rewind(from tick: Int) {
        guard let i = ring.firstIndex(where: { $0.before.tick == tick }) else { return }
        var s = ring[i].before
        for j in i..<ring.count {
            ring[j].before = s
            let events = step(&s, inputs: ring[j].inputs)
            ring[j].events = events
            ring[j].score = s.score
            onStep?(s.tick, events, true)
        }
        state = s
    }

    /// Confirms the steps through `tick`: their celebrations go out, and nothing rewinds them.
    func finalize(through tick: Int) {
        guard tick > finalTick else { return }
        for f in ring where f.before.tick + 1 > finalTick && f.before.tick + 1 <= tick {
            for e in f.events {
                guard let kind = Celebration.kind(of: e) else { continue }
                celebrations.append(Celebration(seq: nextCelebration, tick: f.before.tick + 1, kind: kind))
                nextCelebration += 1
            }
            finalScore = f.score
        }
        if celebrations.count > Self.celebrationsPerSnapshot { celebrations.removeFirst(celebrations.count - Self.celebrationsPerSnapshot) }
        finalTick = tick
    }

    /// Before changing the state outside a step (a human joins or leaves), confirms everything:
    /// a rewind can't reach back past the change.
    func commitRing() {
        finalize(through: state.tick)
        ring.removeAll()
    }

    // MARK: - Drops

    func dropSilent() {
        for (p, peer) in peers where now - peer.lastHeard > Self.dropAfter {
            drop(p, peer.human)
        }
    }

    func drop(_ peer: PeerID, _ h: HumanID) {
        peers[peer] = nil
        guard let i = state.humans.firstIndex(where: { $0.id == h }) else { return }
        commitRing()
        dropped[h] = state.humans.remove(at: i)
        pending.removeAll { $0.input.human == h }
        onDrop?(h)
    }

    // MARK: - Sending

    func send(_ m: Message, to peer: PeerID) {
        guard let d = try? Wire.encode(m) else { return }
        transport.send(d, to: peer)
    }

    func welcome(_ peer: PeerID) {
        guard let p = peers[peer] else { return }
        peers[peer]!.lastWelcome = now
        send(.welcome(human: p.human, settings: state.settings, startTick: state.tick), to: peer)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            tick: state.tick, dynamic: state.dynamic(), pending: pending,
            confirmedThrough: peers.values.sorted { $0.human.raw < $1.human.raw }.map {
                Confirmation(human: $0.human, input: $0.inputSeq, reliable: $0.reliableSeq, packetTick: $0.packetTick)
            },
            confirmed: Confirmed(tick: finalTick, points: finalScore.points, winner: finalScore.winner, celebrations: celebrations))
    }

    func sendSnapshot() {
        guard !peers.isEmpty else { return }
        var snap = snapshot()
        var data = try? Wire.encode(.snapshot(snap))
        // Never past a packet: the oldest celebrations go first (they went out several times).
        // Then the newest inputs waiting (the guests predict a little worse without them).
        while let d = data, d.count > Wire.maxPacket, !snap.confirmed.celebrations.isEmpty || !snap.pending.isEmpty {
            if snap.confirmed.celebrations.isEmpty { snap.pending.removeLast() } else { snap.confirmed.celebrations.removeFirst() }
            data = try? Wire.encode(.snapshot(snap))
        }
        guard let data else { return }
        for p in peers.keys { transport.send(data, to: p) }
    }

    /// Asks each guest to run a little faster or slower so its inputs keep arriving
    /// `targetSlack` steps early: a proportional-integral controller on the measured slack.
    func sendHints() {
        let dt = Double(Self.hintEvery) * Tuning.dt
        for (id, var p) in peers {
            guard let slack = p.slack else { continue }
            let e = slack - Self.targetSlack
            // Far off, the guest jumps its clock itself; integrating that would only wind up.
            if abs(e) < 2 { p.integral = min(max(p.integral + e * dt, -2.5), 2.5) }
            let ppm = -(Self.kp * e + Self.ki * p.integral)
            p.hintPPM = Int(min(max(ppm, -Double(Self.maxHintPPM)), Double(Self.maxHintPPM)))
            peers[id] = p
            send(.timeHint(adjustPPM: Int16(p.hintPPM)), to: id)
        }
    }

    /// Parts per million per step of slack, and per step-second of it.
    static let kp: Double = 20_000
    static let ki: Double = 10_000
}
