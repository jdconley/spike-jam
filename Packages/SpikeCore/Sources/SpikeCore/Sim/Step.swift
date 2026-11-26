/// Advances the match by exactly one fixed step (1/60 s) and returns what
/// happened on it. Pure: everything it reads and writes is in `s`.
///
/// Each step first moves every on-court player toward the goal the
/// choreographer gave them, then applies the rules at those positions (so
/// a serve is judged where everyone stands when it is struck), then sets
/// new goals for what just happened.
public func step(_ s: inout GameState, inputs: [PlayerInput]) -> [GameEvent] {
    s.tick += 1
    var events: [GameEvent] = []
    moveEveryone(&s)
    switch s.phase {
    case .preServe(let until):
        if s.tick >= until {
            // Wait for everyone to reach their spot, but not for ever: after
            // `formationWait` anyone still off it snaps there, so the
            // formation at the serve is always legal.
            let timedOut = s.tick >= until + ticks(Tuning.formationWait)
            if timedOut { Choreographer.snapToFormation(&s) }
            if timedOut || Choreographer.formationReady(s) {
                PlaceholderRally.serve(&s, &events)
            }
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
    Choreographer.update(&s)
    return events
}

/// One steering step for all twelve players on court.
func moveEveryone(_ s: inout GameState) {
    let tick = s.tick
    for id in s.motion.keys {
        let speed = s.rosters[id.team.rawValue][id].traits.speed
        Steering.advance(&s.motion[id]!, team: id.team, speedTrait: speed, dt: Tuning.dt, tick: tick)
    }
}

/// Whole steps covering `seconds`.
func ticks(_ seconds: Double) -> Int {
    Int((seconds * Double(Tuning.stepsPerSecond)).rounded(.up))
}
