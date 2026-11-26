/// Advances the match by exactly one fixed step (1/60 s) and returns what
/// happened on it. Pure: everything it reads and writes is in `s`.
public func step(_ s: inout GameState, inputs: [PlayerInput]) -> [GameEvent] {
    s.tick += 1
    var events: [GameEvent] = []
    switch s.phase {
    case .preServe(let until):
        if s.tick >= until {
            PlaceholderRally.serve(&s, &events)
        }
    case .rally:
        if let c = s.pending, s.tick >= c.tick {
            s.pending = nil
            PlaceholderRally.resolve(c, &s, &events)
        }
    case .deadBall(let until):
        if s.tick >= until {
            s.phase = .preServe(untilTick: s.tick + ticks(Tuning.serveDelay))
        }
    case .matchOver:
        break
    }
    return events
}

/// Whole steps covering `seconds`.
func ticks(_ seconds: Double) -> Int {
    Int((seconds * Double(Tuning.stepsPerSecond)).rounded(.up))
}
