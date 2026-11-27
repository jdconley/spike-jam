/// Every input a match took, with the step each arrived on (spec §5.2). The
/// same settings, humans and log play the same match again exactly: picks,
/// switches, reads and every touch.
public struct InputLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The tick of the state the step started from.
        public var step: Int
        public var input: PlayerInput

        public init(step: Int, input: PlayerInput) {
            self.step = step
            self.input = input
        }
    }

    /// In arrival order.
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Records `inputs` as given to the step from `s`.
    public mutating func record(_ inputs: [PlayerInput], before s: GameState) {
        for i in inputs { entries.append(Entry(step: s.tick, input: i)) }
    }
}

/// Plays a recorded match again from its start, for at most `maxTicks` steps
/// or to the end of the match. Returns the final state and every event.
public func replay(_ settings: MatchSettings, humans: [HumanSlot], log: InputLog,
                   maxTicks: Int = 60 * 60 * 30) -> (state: GameState, events: [GameEvent]) {
    var s = GameState(settings: settings, humans: humans)
    var events: [GameEvent] = []
    var next = 0
    for _ in 0..<maxTicks where s.phase != .matchOver {
        var inputs: [PlayerInput] = []
        while next < log.entries.count && log.entries[next].step <= s.tick {
            if log.entries[next].step == s.tick { inputs.append(log.entries[next].input) }
            next += 1
        }
        events += step(&s, inputs: inputs)
    }
    return (s, events)
}
