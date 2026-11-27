#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SpikeCore

/// A guest's match (spec §5.3): it runs ahead of the host by about half a round trip plus the
/// host's input buffer, so its own inputs reach the host just in time, and it predicts every
/// step itself, so its own touches play at once.
///
/// - Each snapshot is checked against what it predicted for that tick. If they differ, it
///   restores the snapshot and replays the inputs the host hadn't played yet (its own and the
///   other humans' it has heard of), and the `Smoother` eases the drawn ball and players from
///   the old prediction to the new. Inputs are placed as the host places them (`Placement`).
/// - Another human's touch it hasn't heard of yet is guessed as on time, so the ball goes where
///   it most likely will until the host says otherwise.
/// - Events play at once, except celebrations (points, the score, kill banners, fire), which
///   wait for the host's confirmation: a predicted kill that the host turns into a stuff shows
///   only as the stuff. The drawn score is the confirmed one.
/// - When the host says it paused, the clock stops and nothing more is predicted (`hostPaused`)
///   until a snapshot from after the pause, then it runs on from where it stopped.
///
/// It is the app's `ClientLoop` (`previous`, `current`, `alpha`, `send(_:at:)`, `advance(to:)`,
/// `pause()`, `resume(at:)`); the app's conformance is one line. Times are seconds on the app's
/// clock. Not thread-safe: call it from one thread (the main one, in the app).
public final class PredictingClientLoop {
    public static let ringSize = 60
    /// The most steps one `advance` takes; a longer gap is caught up over the next frames.
    public static let maxStepsPerAdvance = 30
    /// How far ahead of the snapshot's tick to start before the host has measured anything.
    public static let initialLead = 4.0
    /// Inputs per packet: each goes again in every packet until confirmed, oldest first.
    public static let maxItemsPerPacket = 32
    public static let reliableResend: Double = 0.1
    /// Celebrations: shown only once confirmed.
    public static func isCelebration(_ e: GameEvent) -> Bool { Celebration.kind(of: e) != nil }

    public let human: HumanID
    /// Drawn: the state before the newest step, and the newest, with corrections eased and the
    /// confirmed score.
    public private(set) var previous: GameState
    public private(set) var current: GameState
    /// How far the clock is from `previous` to `current`, 0..<1.
    public private(set) var alpha: Double = 0
    /// The prediction itself, undrawn.
    public private(set) var predicted: GameState
    private var predictedBefore: GameState
    /// Every celebration the host confirmed this match, in order.
    public private(set) var confirmedEvents: [GameEvent] = []
    /// The newest snapshot's tick; nil before the first.
    public private(set) var snapshotTick: Int?
    /// The host said bye.
    public private(set) var hostLeft = false
    public private(set) var isPaused = false
    /// The host said it paused, and no snapshot since says it's back: the clock is stopped and
    /// nothing is predicted (the app shows "Host paused").
    public private(set) var hostPaused = false
    /// The hosting phone's own client: it pauses with the host directly, so it doesn't stop for
    /// the host's `paused`.
    public var ignoresHostPause = false
    /// Snapshots that disagreed with the prediction, and the steps replayed for them.
    public private(set) var corrections = 0
    public private(set) var replayedSteps = 0
    /// Times the clock jumped to get back in step with the host.
    public private(set) var clockJumps = 0
    /// Called before each new step (not replays) for inputs stamped with ticks, such as a
    /// `SimHuman`'s; they go in as `enqueue` would put them.
    public var inputSource: ((GameState) -> [PlayerInput])?
    /// Each predicted celebration, held back until confirmed (for tests and logs).
    public var onPredictedCelebration: ((GameEvent, Int) -> Void)?
    /// Each input the first time it's sent to the host (for tests and logs).
    public var onInputSent: ((PlayerInput) -> Void)?

    private let transport: any Transport
    private let server: PeerID
    private let inbox = Inbox()

    // The clock: the tick `anchorTick` was at `anchorTime`, running at `rate`.
    private var anchorTime: Double?
    private var anchorTick: Double = 0
    private var rate: Double = 1
    /// The clock jumped to this tick: don't jump again until the host has a packet sent since
    /// (one from before has a tick below it, or, after a jump back, above the clock).
    private var jumpedAt: Int?
    /// While the host is paused: the tick the clock stopped at.
    private var frozenTick: Double?
    /// The newest tick the host said it paused at.
    private var pausedTick: Int?

    struct Own {
        var seq: UInt32
        var input: NetInput
    }

    /// Own inputs the host hasn't confirmed, for sending.
    private var own: [Own] = []
    private var nextSeq: UInt32 = 1
    private var confirmedSeq: UInt32 = 0
    /// Inputs the prediction hasn't played yet, as the host would hold them (`Placement`).
    private var waiting: [NetInput] = []

    struct Reliable {
        var seq: UInt32
        var action: InputAction
        var sent: Double
    }

    private var reliable: [Reliable] = []
    private var nextReliable: UInt32 = 1
    private var reliableIncluded: UInt32 = 0

    /// A predicted state and the inputs still waiting as it was reached.
    struct Entry {
        var state: GameState
        var waiting: [NetInput]
    }

    /// One per tick, oldest first.
    private var ring: [Entry] = []
    private var smoother = Smoother()
    /// Events already shown, by tick, so a replay doesn't show them twice.
    private var shown: [(tick: Int, event: GameEvent)] = []
    private var lastCelebration: UInt32 = 0
    private var points: [Int]
    private var winner: TeamSide?
    private var pendingEvents: [GameEvent] = []

    /// A guest of the host at `server`, as `human`, from the welcome. It shows nothing until
    /// the first snapshot.
    public init(transport: any Transport, server: PeerID, human: HumanID, settings: MatchSettings, startTick: Int) {
        self.transport = transport
        self.server = server
        self.human = human
        var s = GameState(settings: settings)
        s.tick = startTick
        previous = s
        current = s
        predicted = s
        predictedBefore = s
        points = s.score.points
        let inbox = inbox
        transport.onReceive = { d, peer in inbox.put(d, from: peer) }
    }

    /// From a welcome message, else nil.
    public convenience init?(welcome: Message, transport: any Transport, server: PeerID) {
        guard case .welcome(let h, let settings, let startTick) = welcome else { return nil }
        self.init(transport: transport, server: server, human: h, settings: settings, startTick: startTick)
    }

    // MARK: - The clock

    /// The tick the clock is at, with the fraction into it.
    public func clockTick(_ now: Double) -> Double {
        if let frozenTick { return frozenTick }
        guard let anchorTime else { return Double(predicted.tick) }
        return anchorTick + (now - anchorTime) / Tuning.dt * rate
    }

    /// The tick an input at `time` belongs to, and how far into it.
    public func stamp(at time: Double) -> (tick: Int, offset: Double) {
        let t = clockTick(time)
        let tick = Int((t + 1e-7).rounded(.down))
        let offset = (t - Double(tick)) * Tuning.dt
        return (tick, min(max(offset, 0), Tuning.dt.nextDown))
    }

    func reanchor(_ now: Double) {
        anchorTick = clockTick(now)
        anchorTime = now
    }

    /// Stops the clock where it is for the host's pause, or starts it again from there.
    func setHostPaused(_ paused: Bool, _ now: Double) {
        guard paused != hostPaused else { return }
        hostPaused = paused
        if paused {
            frozenTick = clockTick(now)
        } else if let f = frozenTick {
            frozenTick = nil
            if anchorTime != nil {
                anchorTick = f
                anchorTime = now
            }
        }
    }

    // MARK: - Inputs

    /// Queues an input that happened at `time` (the app's `ClientLoop.send`). Huddle actions go
    /// reliably; the rest are stamped with the tick and offset of `time`.
    public func send(_ input: PlayerInput, at time: Double) {
        var input = input
        input.human = human
        switch input.action {
        case .pick, .call, .combo, .ready, .teamSettings:
            reliable.append(Reliable(seq: nextReliable, action: input.action, sent: -.infinity))
            nextReliable += 1
            input.tick = predicted.tick
            input.offset = 0
            waiting.append(NetInput(input))
            sendReliable(now: time)
        default:
            let st = stamp(at: time)
            input.tick = st.tick
            input.offset = Float(st.offset)
            enqueue(input)
        }
    }

    /// Queues an input already stamped with its tick and offset. A touch is sent with the
    /// contact's tick as predicted now, which the host judges it against. One for a step already
    /// taken is played from that step: the prediction rewinds to it, as the host will.
    public func enqueue(_ input: PlayerInput) {
        var input = input
        input.human = human
        let item = NetInput(input, seen: input.contact.flatMap { Placement.contactTick($0, predicted) })
        own.append(Own(seq: nextSeq, input: item))
        nextSeq += 1
        onInputSent?(input)
        if input.tick < predicted.tick, input.tick >= (snapshotTick ?? .min), let i = ring.lastIndex(where: { $0.state.tick == input.tick }) {
            let old = predicted
            var start = ring[i]
            // What came in since that step waits there too.
            start.waiting += waiting.filter { !start.waiting.contains($0) }
            start.waiting.append(item)
            replay(from: start, to: predicted.tick)
            smoother.correct(from: old, to: predicted)
        } else {
            waiting.append(item)
        }
    }

    /// What another human's touch most likely is until the host says: on time, with the AI's
    /// choices. Their serves and blocks aren't guessed.
    func guesses(_ s: GameState, _ waiting: [NetInput]) -> [PlayerInput] {
        guard let c = s.pending, let owner = c.owner, owner != human, let kind = c.kind, c.tick == s.tick + 1,
              !s.inputBuffer.contains(where: { $0.human == owner && $0.contact == c.id }),
              !waiting.contains(where: { $0.input.human == owner && $0.input.contact == c.id }) else { return [] }
        let action: InputAction
        switch kind {
        case .receive, .dig, .set: action = .tap(contact: c.id)
        case .attack: action = .release(contact: c.id, aim: nil)
        case .serve, .block: return []
        }
        return [PlayerInput(human: owner, tick: s.tick, offset: Float(Tuning.dt).nextDown, action: action)]
    }

    // MARK: - Stepping

    /// Runs the prediction up to `now` and returns the events of its steps, with the celebrations
    /// the host confirmed since the last call.
    public func advance(to now: Double) -> [GameEvent] {
        guard !isPaused else { return [] }
        receive(now)
        var events = pendingEvents
        pendingEvents = []
        guard snapshotTick != nil else { return events }
        let target = clockTick(now)
        let goal = Int((target + 1e-9).rounded(.down))
        var steps = 0
        while predicted.tick < goal && steps < Self.maxStepsPerAdvance {
            events += stepLive()
            steps += 1
        }
        events += pendingEvents
        pendingEvents = []
        alpha = predicted.tick == goal ? min(max(target - Double(goal), 0), 1) : (predicted.tick < goal ? 1 : 0)
        if steps > 0 { sendInputs() }
        sendReliable(now: now)
        smoother.advance(to: predicted.time)
        draw()
        return events
    }

    /// One new step at the front of the prediction.
    func stepLive() -> [GameEvent] {
        if let source = inputSource {
            for i in source(predicted) { enqueue(i) }
        }
        predictedBefore = predicted
        let raw = stepOnce(&predicted, &waiting)
        remember(predicted, waiting)
        return show(raw, at: predicted.tick)
    }

    /// One step of a prediction: the inputs due, then the guesses.
    func stepOnce(_ s: inout GameState, _ waiting: inout [NetInput]) -> [GameEvent] {
        var inputs = Placement.takeDue(&waiting, s)
        inputs += guesses(s, waiting)
        return step(&s, inputs: inputs)
    }

    /// Predicts again from `start` to `tick` with what it knows now.
    func replay(from start: Entry, to tick: Int) {
        var s = start.state
        var w = start.waiting
        ring.removeAll { $0.state.tick >= s.tick }
        remember(s, w)
        var before = s
        while s.tick < tick {
            before = s
            let raw = stepOnce(&s, &w)
            replayedSteps += 1
            remember(s, w)
            pendingEvents += show(raw, at: s.tick)
        }
        predictedBefore = s.tick > start.state.tick ? before : (state(at: s.tick - 1) ?? s)
        predicted = s
        waiting = w
    }

    func remember(_ s: GameState, _ w: [NetInput]) {
        if let last = ring.last, last.state.tick >= s.tick { ring.removeAll { $0.state.tick >= s.tick } }
        ring.append(Entry(state: s, waiting: w))
        if ring.count > Self.ringSize { ring.removeFirst(ring.count - Self.ringSize) }
    }

    /// The events of one step that haven't been shown: celebrations are held for the host, and a
    /// replay's repeats of what was already shown are dropped.
    func show(_ raw: [GameEvent], at tick: Int) -> [GameEvent] {
        var out: [GameEvent] = []
        for e in raw {
            if Self.isCelebration(e) {
                onPredictedCelebration?(e, tick)
                continue
            }
            let key = Self.key(e)
            if shown.contains(where: { abs($0.tick - tick) <= 12 && $0.event == key }) { continue }
            shown.append((tick, key))
            out.append(e)
        }
        if shown.count > 256 { shown.removeFirst(shown.count - 256) }
        return out
    }

    /// An event as compared for repeats: a touch's quality can shift a little in a replay. (A
    /// judgment the host overrules does show again, with the host's grade.)
    static func key(_ e: GameEvent) -> GameEvent {
        if case .touched(let kind, let id, _) = e { return .touched(kind, id, quality: 0) }
        return e
    }

    /// The states the app draws.
    func draw() {
        func shown(_ s: GameState) -> GameState {
            var d = smoother.draw(s)
            d.score.points = points
            d.score.winner = winner
            return d
        }
        previous = shown(predictedBefore)
        current = shown(predicted)
    }

    /// The predicted state at `tick`, if the ring still has it.
    public func state(at tick: Int) -> GameState? {
        ring.last { $0.state.tick == tick }?.state
    }

    // MARK: - Receiving

    func receive(_ now: Double) {
        var newest: Snapshot?
        for (data, from) in inbox.take() where from == server {
            guard let m = try? Wire.decode(data) else { continue }
            switch m {
            case .snapshot(let s):
                if s.tick > (newest?.tick ?? snapshotTick ?? Int.min) { newest = s }
            case .timeHint(let ppm):
                if anchorTime != nil { reanchor(now) }
                rate = 1 + Double(ppm) / 1_000_000
            case .ack(let seq):
                reliable.removeAll { $0.seq <= seq }
            case .bye:
                hostLeft = true
            case .paused(let tick):
                // One that comes after a later snapshot is old news: the host is back.
                if !ignoresHostPause, tick >= (snapshotTick ?? .min) { pausedTick = max(pausedTick ?? tick, tick) }
            case .welcome, .hello, .inputs, .reliable:
                break
            }
        }
        // A snapshot after the pause's tick means the host is back.
        if let p = pausedTick, let newest, newest.tick > p { pausedTick = nil }
        setHostPaused(pausedTick != nil, now)
        if let newest { take(newest, now) }
    }

    func take(_ snap: Snapshot, _ now: Double) {
        let firstOne = snapshotTick == nil
        snapshotTick = snap.tick
        var packetTick: Int?
        if let c = snap.confirmedThrough.first(where: { $0.human == human }) {
            confirmedSeq = max(confirmedSeq, c.input)
            reliableIncluded = max(reliableIncluded, c.reliable)
            reliable.removeAll { $0.seq <= c.reliable }
            if c.packetTick >= 0 { packetTick = c.packetTick }
        }
        own.removeAll { $0.seq <= confirmedSeq }
        for c in snap.confirmed.celebrations.sorted(by: { $0.seq < $1.seq }) where c.seq > lastCelebration {
            lastCelebration = c.seq
            confirmedEvents.append(c.event)
            pendingEvents.append(c.event)
        }
        points = snap.confirmed.points
        winner = snap.confirmed.winner

        var host = predicted
        host.apply(snap.dynamic)
        // What the host has yet to play: what it holds, then what it hasn't heard yet (own inputs
        // and huddle actions), as it will get them.
        let waitingNow = snap.pending + own.map(\.input) + reliable.filter { $0.seq > reliableIncluded }.map {
            NetInput(PlayerInput(human: human, tick: snap.tick, action: $0.action))
        }
        if firstOne {
            ring = []
            waiting = waitingNow
            remember(host, waiting)
            predicted = host
            predictedBefore = host
            anchorTick = Double(snap.tick) + Self.initialLead
            anchorTime = now
            draw()
            return
        }
        let target = Int((clockTick(now) + 1e-9).rounded(.down))
        let to = max(snap.tick, min(predicted.tick, target))
        if to == predicted.tick, let mine = ring.last(where: { $0.state.tick == snap.tick }),
           mine.state == host, Self.same(mine.waiting, waitingNow) {
            syncClock(snap, packetTick, now)
            return
        }
        corrections += 1
        let old = predicted
        replay(from: Entry(state: host, waiting: waitingNow), to: to)
        if old.tick == predicted.tick { smoother.correct(from: old, to: predicted) }
        syncClock(snap, packetTick, now)
    }

    /// The same inputs, whatever the order they came in.
    static func same(_ a: [NetInput], _ b: [NetInput]) -> Bool {
        a.count == b.count && a.allSatisfy { x in b.contains(x) } && b.allSatisfy { x in a.contains(x) }
    }

    /// The coarse clock: the time hints keep the lead right, but far off (at the start, or after
    /// a stall) the clock jumps so the host gets inputs about two steps early.
    func syncClock(_ snap: Snapshot, _ packetTick: Int?, _ now: Double) {
        guard let p = packetTick else { return }
        if let j = jumpedAt {
            guard p >= j, Double(p) <= clockTick(now) + 2 else { return }
            jumpedAt = nil
        }
        let early = Double(p - snap.tick)
        guard early < 0 || early > 5 else { return }
        reanchor(now)
        anchorTick += ServerLoop.targetSlack + 0.5 - early
        jumpedAt = Int(anchorTick.rounded(.down))
        clockJumps += 1
    }

    // MARK: - Sending

    func send(_ m: Message) {
        guard let d = try? Wire.encode(m) else { return }
        transport.send(d, to: server)
    }

    func sendInputs() {
        let unconfirmed = own.prefix(Self.maxItemsPerPacket)
        send(.inputs(tick: predicted.tick, ack: snapshotTick ?? -1, first: unconfirmed.first?.seq ?? nextSeq,
                     items: unconfirmed.map(\.input)))
    }

    func sendReliable(now: Double) {
        for i in reliable.indices where now - reliable[i].sent >= Self.reliableResend {
            reliable[i].sent = now
            send(.reliable(seq: reliable[i].seq, reliable[i].action))
        }
    }

    // MARK: - Pausing

    /// Stops the clock; `advance` does nothing until `resume`.
    public func pause() {
        isPaused = true
    }

    /// Starts the clock again from `now` where it stopped; the host's time hints and the next
    /// snapshot bring it back to the host's time.
    public func resume(at now: Double) {
        isPaused = false
        if anchorTime != nil, frozenTick == nil {
            anchorTick = Double(predicted.tick) + alpha
            anchorTime = now
        }
    }

    /// Tells the host this guest is leaving.
    public func leave() {
        send(.bye)
    }
}
