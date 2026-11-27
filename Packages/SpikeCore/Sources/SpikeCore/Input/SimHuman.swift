/// A simulated human for tests, tuning and autoplay: it plays its touches
/// through real `PlayerInput`s, exactly as a person's would arrive. It
/// watches for the touches it owns (each `window`, from the state) and plans
/// the right gesture for each, mistimed by a normal-ish error whose spread
/// falls with `skill` (`spread(skill:)`). It aims serves and attacks at
/// random legal spots, sometimes tips, sets a hitter the way the setter's
/// odds lean, sometimes makes the defensive read, and picks `pick` in the
/// huddle. Its randomness is its own, never the game's.
public struct SimHuman: Sendable {
    public var id: HumanID
    public var team: TeamSide
    /// 0...1.
    public var skill: Float
    public var pick: Pick
    var rng: SeededRNG
    /// Inputs waiting for their tick.
    var planned: [PlayerInput] = []
    /// The contacts already planned for (the newest few).
    var handled: [ContactID] = []
    /// The huddle it last picked in, by its end tick.
    var pickedIn: Int?
    /// The set it last thought about reading.
    var readFor: ContactID?

    public init(id: HumanID, team: TeamSide, skill: Float, pick: Pick = .ball, seed: UInt64 = 1) {
        self.id = id
        self.team = team
        self.skill = min(max(skill, 0), 1)
        self.pick = pick
        rng = SeededRNG(seed: seed ^ (0x5157_4D48_554D_414E &+ UInt64(id.raw)))
    }

    /// The slot to start a match with.
    public var slot: HumanSlot { HumanSlot(id: id, team: team, pick: pick) }

    /// The timing error's standard deviation in seconds: 160 ms at skill 0,
    /// 35 ms at 1.
    public static func spread(skill: Float) -> Double {
        0.160 - 0.125 * Double(min(max(skill, 0), 1))
    }

    /// The inputs for the step from `s.tick` to the next.
    public mutating func inputs(for s: GameState) -> [PlayerInput] {
        if case .huddle(let until) = s.phase, pickedIn != until {
            pickedIn = until
            if s.human(id)?.pick != pick { planned.append(input(s.tick, .pick(pick))) }
        }
        if let w = s.notes.block, w.owner == id, !handled.contains(w.id) {
            handle(w.id)
            // The jump peaks half a block jump after the tap.
            let peak = Double(w.attackTick) * Tuning.dt + error()
            planned.append(at(peak - Double(Tuning.blockJumpTicks / 2) * Tuning.dt, .block(contact: w.id), s))
        }
        if let c = s.pending, c.owner == id, let kind = c.kind, !handled.contains(c.id) {
            handle(c.id)
            plan(c, kind, s)
        }
        if let c = s.pending, c.kind == .set, c.team == team.other, readFor != c.id {
            readFor = c.id
            if let setter = c.athlete, rng.chance(0.5) {
                let options = SetterAI.options(s, team: c.team, passQuality: s.notes.passQuality, setter: setter)
                planned.append(input(s.tick, .read(hitter: options[rng.int(in: 0..<options.count)].hitter)))
            }
        }
        let due = planned.filter { $0.tick <= s.tick }
        planned.removeAll { $0.tick <= s.tick }
        return due
    }

    mutating func plan(_ c: PendingContact, _ kind: TouchKind, _ s: GameState) {
        let contact = Double(c.tick) * Tuning.dt
        switch kind {
        case .serve:
            // A beat to settle, the toss, and the release at its top.
            let press = s.time + Double(rng.float(in: 0.2...0.7))
            planned.append(at(press, .press(contact: c.id), s))
            let release = HumanTouch.apexTime(pressTime: press) + error()
            planned.append(at(max(release, press + Tuning.floatTap + 0.01), .release(contact: c.id, aim: aim(tip: false)), s))
        case .receive, .dig:
            planned.append(at(contact + error(), .tap(contact: c.id), s))
        case .set:
            var hitter: AthleteID?
            if let setter = c.athlete {
                let options = SetterAI.options(s, team: team, passQuality: s.notes.passQuality, setter: setter)
                var r = rng.unit()
                for o in options where hitter == nil {
                    r -= o.chance
                    if r < 0 { hitter = o.hitter }
                }
                hitter = hitter ?? options.last?.hitter
            }
            let action: InputAction = hitter.map { .setTo(contact: c.id, hitter: $0) } ?? .tap(contact: c.id)
            planned.append(at(contact + error(), action, s))
        case .attack:
            planned.append(at(contact + error(), .release(contact: c.id, aim: aim(tip: rng.chance(0.08))), s))
        case .block:
            break
        }
    }

    mutating func handle(_ id: ContactID) {
        handled.append(id)
        if handled.count > 8 { handled.removeFirst() }
    }

    /// A normal-ish timing error (the sum of three uniforms, so never beyond
    /// three spreads).
    mutating func error() -> Double {
        let z = (rng.unit() + rng.unit() + rng.unit() - 1.5) * 2
        return Double(z) * SimHuman.spread(skill: skill)
    }

    /// A random legal spot on the other court: short for a tip, else deep
    /// enough to swing.
    mutating func aim(tip: Bool) -> Vec2 {
        let spot = tip ? LocalSpot(d: rng.float(in: 0.8...2.2), l: rng.float(in: -3.8...3.8))
            : LocalSpot(d: rng.float(in: 3...8.2), l: rng.float(in: -3.8...3.8))
        return LocalFrame.toWorld(spot, team: team.other)
    }

    func input(_ tick: Int, _ a: InputAction) -> PlayerInput {
        PlayerInput(human: id, tick: tick, offset: 0, action: a)
    }

    /// An input at match time `t`, or now if that has passed.
    func at(_ t: Double, _ a: InputAction, _ s: GameState) -> PlayerInput {
        let tick = Int((t / Tuning.dt).rounded(.down))
        guard tick >= s.tick else { return input(s.tick, a) }
        let offset = Float(t - Double(tick) * Tuning.dt)
        return PlayerInput(human: id, tick: tick, offset: min(max(offset, 0), Float(Tuning.dt).nextDown), action: a)
    }
}
