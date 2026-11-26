import SpikeCore

/// Where the app gets the match from (spec §5.1). The app never changes game state itself: it
/// sends inputs here and draws `previous` and `current`, `alpha` of the way from one to the other.
/// Plan 6 swaps `LocalClientLoop` for a networked loop without touching the UI.
///
/// Times are seconds on the `CACurrentMediaTime` clock, which is also the clock of
/// `UITouch.timestamp`, so a touch's own timestamp can be passed to `send` as is.
@MainActor
protocol ClientLoop: AnyObject {
    /// The state before the newest step.
    var previous: GameState { get }
    /// The newest state.
    var current: GameState { get }
    /// How far the wall clock is from `previous` to `current`, 0..<1, for interpolated drawing.
    var alpha: Double { get }
    /// Queues an input that happened at `time`. It is stamped with the tick and the offset into
    /// that tick at which it happened, not the tick it arrived on.
    func send(_ input: PlayerInput, at time: Double)
    /// Runs the simulation up to `now` and returns the events of the steps it took.
    func advance(to now: Double) -> [GameEvent]
    /// Stops the match clock; `advance` does nothing until `resume`.
    func pause()
    /// Restarts the match clock from `now`, so the paused time never turns into a burst of steps.
    func resume(at now: Double)
}

/// The tick an input belongs to, and how far into that tick it happened, in seconds (0..<dt).
struct InputStamp: Equatable, Sendable {
    var tick: Int
    var offset: Double
}

/// The solo client: steps SpikeCore right here at a fixed 60 Hz with an accumulator.
@MainActor
final class LocalClientLoop: ClientLoop {
    /// The most steps one `advance` takes. A longer hitch drops the rest of the backlog instead of
    /// queuing it, so a stall never spirals.
    static let maxStepsPerAdvance = 8

    /// An input waiting for its step.
    struct QueuedInput {
        var stamp: InputStamp
        var input: PlayerInput
    }

    private(set) var previous: GameState
    private(set) var current: GameState
    /// Wall-clock time not yet stepped, 0..<dt after each `advance`.
    private(set) var accumulator: Double = 0
    private(set) var isPaused = false
    /// The steps the latest `advance` took.
    private(set) var stepsLastAdvance = 0
    private(set) var queued: [QueuedInput] = []

    /// The wall time of the latest `advance`; nil until the first one, which only sets the base.
    private var lastNow: Double?
    private let stepper: (inout GameState, [PlayerInput]) -> [GameEvent]

    /// `stepper` is SpikeCore's `step`; tests may wrap it.
    init(state: GameState, stepper: @escaping (inout GameState, [PlayerInput]) -> [GameEvent] = { SpikeCore.step(&$0, inputs: $1) }) {
        previous = state
        current = state
        self.stepper = stepper
    }

    var alpha: Double { min(max(accumulator / Tuning.dt, 0), 1) }

    /// The wall time at which `tick` starts (or started), by the loop's current base.
    func tickTime(_ tick: Int) -> Double {
        currentTickTime + Double(tick - current.tick) * Tuning.dt
    }

    /// The wall time `current` stands for.
    private var currentTickTime: Double {
        guard let lastNow else { return 0 }
        return lastNow - accumulator
    }

    func stamp(at time: Double) -> InputStamp {
        guard lastNow != nil else { return InputStamp(tick: current.tick, offset: 0) }
        let since = time - currentTickTime
        // A hair of tolerance so a time built as tickTime(n) + offset lands in tick n.
        let ticks = Int((since / Tuning.dt + 1e-7).rounded(.down))
        let offset = since - Double(ticks) * Tuning.dt
        return InputStamp(tick: current.tick + ticks, offset: min(max(offset, 0), Tuning.dt.nextDown))
    }

    func send(_ input: PlayerInput, at time: Double) {
        queued.append(QueuedInput(stamp: stamp(at: time), input: input))
    }

    func advance(to now: Double) -> [GameEvent] {
        stepsLastAdvance = 0
        guard !isPaused else { return [] }
        guard let last = lastNow else {
            lastNow = now
            return []
        }
        lastNow = now
        accumulator += max(0, now - last)
        var events: [GameEvent] = []
        // The tolerance keeps float error from losing a step on an exact boundary.
        while accumulator + 1e-9 >= Tuning.dt && stepsLastAdvance < Self.maxStepsPerAdvance {
            // An input stamped tick n happened between n and n + 1: it goes into that step, or
            // the next one if it arrived late.
            let due = queued.filter { $0.stamp.tick <= current.tick }.map(\.input)
            queued.removeAll { $0.stamp.tick <= current.tick }
            previous = current
            events += stepper(&current, due)
            accumulator -= Tuning.dt
            stepsLastAdvance += 1
        }
        // Past the cap, the backlog is dropped, keeping only where we are inside the tick.
        if accumulator >= Tuning.dt { accumulator = accumulator.truncatingRemainder(dividingBy: Tuning.dt) }
        accumulator = max(accumulator, 0)
        return events
    }

    func pause() {
        isPaused = true
    }

    func resume(at now: Double) {
        isPaused = false
        lastNow = now
    }
}
