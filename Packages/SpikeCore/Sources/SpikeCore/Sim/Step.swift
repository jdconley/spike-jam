/// Advances the match by exactly one fixed step (1/60 s) and returns what
/// happened on it. Pure: everything it reads and writes is in `s`.
///
/// Each step first takes the inputs, then moves every on-court player toward
/// the goal the choreographer gave them, then applies the rules at those
/// positions (so a serve is judged where everyone stands when it is struck),
/// then sets new goals for what just happened.
///
/// `inputs` are the humans' inputs that happened since the last step, in the
/// order they arrived; an input stamped with tick n belongs in the step from
/// n to n + 1. A touch input counts only for the contact it names, and only
/// from that contact's owner; it waits in `inputBuffer` until the contact is
/// played. An owned contact is played on its tick if its input is in, else
/// as soon as the input comes, up to `Tuning.graceWindow` late, and then as
/// a miss.
///
/// `touches` is a stand-in for human timing, for tuning and tests: it plays
/// the touches nobody owns that it claims, with the timing it gives. Without
/// it the AI makes every touch no human owns.
public func step(_ s: inout GameState, inputs: [PlayerInput], touches: (any TouchSource)? = nil) -> [GameEvent] {
    s.tick += 1
    var events: [GameEvent] = []
    let before = s.pending?.id
    for input in inputs { apply(input, &s, &events) }
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
                Rally.beginServe(&s, &events, touches)
            }
        }
    case .rally:
        if let c = s.pending, Rally.due(c, s) {
            s.pending = nil
            Rally.resolve(c, &s, &events, touches)
        }
    case .deadBall(let until):
        if s.tick >= until {
            s.phase = .preServe(untilTick: s.tick + ticks(Tuning.serveDelay))
        }
    case .matchOver:
        break
    }
    Ownership.claim(&s, &events, before: before)
    Choreographer.update(&s)
    s.pruneInputs()
    return events
}

/// Takes one input: a touch input waits for its contact, a block jumps at
/// once, and the rest act on the huddle, the switch or the read.
func apply(_ input: PlayerInput, _ s: inout GameState, _ events: inout [GameEvent]) {
    // Never from the future, and only from someone playing.
    guard input.tick < s.tick, let slot = s.human(input.human) else { return }
    guard let id = input.contact else { return }
    _ = slot
    if let w = s.notes.block, w.id == id {
        guard w.owner == input.human, w.grade == nil else { return }
        switch input.action {
        case .block, .tap, .press: Rally.jump(input, &s, &events)
        default: break
        }
        return
    }
    let open = [s.pending, s.notes.afterBlock].compactMap { $0 }.first { $0.id == id && $0.owner == input.human }
    guard let c = open else { return }
    if c.kind == .serve, case .press = input.action, HumanTouch.press(s.inputs(for: c)) == nil, s.pending?.id == id {
        // The toss goes up: the serve is now judged against its top.
        let apex = HumanTouch.apexTime(pressTime: input.time)
        let tick = max(s.tick, Int((apex * Double(Tuning.stepsPerSecond) - 1e-9).rounded(.up)))
        s.pending!.tick = tick
        events.append(.window(id, .serve, owner: input.human, contactTick: tick))
    }
    s.inputBuffer.append(input)
}

extension GameState {
    /// Drops buffered inputs for contacts that are no longer coming.
    mutating func pruneInputs() {
        guard !inputBuffer.isEmpty else { return }
        let open = [pending?.id, notes.afterBlock?.id, notes.block?.id].compactMap { $0 }
        inputBuffer.removeAll { input in !open.contains { $0 == input.contact } }
    }

    mutating func takeContactID() -> ContactID {
        let id = nextContactID
        nextContactID = ContactID(raw: id.raw + 1)
        return id
    }
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

/// The nearest whole number of steps to `seconds`.
func nearestTicks(_ seconds: Double) -> Int {
    Int((seconds * Double(Tuning.stepsPerSecond)).rounded())
}
