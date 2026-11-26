/// Who owns each touch (spec §4.1, §5.3): decided once, as the flight toward
/// it starts, and stored on the contact, so a switch after that applies from
/// the next touch.
public enum Ownership {
    /// The human who plays `athlete`'s `kind` touch, in order:
    /// 1. a human who controls `athlete` by their pick or switch;
    /// 2. else the side's "ball" human; with two, the one who didn't own the
    ///    side's last human touch;
    /// 3. else nobody: the AI plays it.
    public static func owner(for athlete: AthleteID, kind: TouchKind, _ s: GameState) -> HumanID? {
        let side = athlete.team
        for h in s.humans where h.team == side {
            if case .athlete(let a) = h.current, onCourt(as: a, s) == athlete { return h.id }
        }
        return ballHuman(side, s)
    }

    /// The "ball" human for `side`'s next touch.
    static func ballHuman(_ side: TeamSide, _ s: GameState) -> HumanID? {
        let ball = s.humans.filter { $0.team == side && $0.current == .ball }
        guard ball.count > 1 else { return ball.first?.id }
        let last = s.lastToucherHuman[side.rawValue]
        return ball.first { $0.id != last }?.id
    }

    /// The human block against the set now in the air to `attack`, if a human
    /// on the defending side plays it: one who controls a front-row player
    /// (the one nearest where the set is going, if two do), else their "ball"
    /// human with the blocker who lines up on the ball.
    static func blockOwner(against attack: PendingContact, _ s: GameState) -> (HumanID, AthleteID)? {
        let defending = attack.team.other
        let t = TeamView(s, defending)
        let front = Set([Zone.z4, .z3, .z2].map { t.lineup.occupant($0, isServing: t.serving) })
        let setEnd = Choreographer.ballEnd(s).xz
        func distance(_ id: AthleteID) -> Float { (s.motion[id].map { $0.pos - setEnd } ?? Vec2(x: 99, z: 99)).length }
        var pickers: [(HumanID, AthleteID)] = []
        for h in s.humans where h.team == defending {
            if case .athlete(let a) = h.current, let on = onCourt(as: a, s), front.contains(on) { pickers.append((h.id, on)) }
        }
        if let nearest = pickers.min(by: { distance($0.1) < distance($1.1) }) { return nearest }
        guard let h = ballHuman(defending, s) else { return nil }
        let lane = s.notes.play.map { PlayBook.spec($0).lane } ?? TeamView(s, attack.team).lane(attack.athlete!)
        let role = BaseSpots.blockers(against: lane)[0]
        guard let blocker = t.roles.first(where: { $0.role == role })?.id else { return nil }
        return (h, blocker)
    }

    /// Numbers the contacts the rally just scheduled and decides their
    /// owners, opens and closes the human block, and announces each owned
    /// touch's window as it becomes the next thing to happen. `before` is the
    /// pending contact's number at the start of the step.
    static func claim(_ s: inout GameState, _ events: inout [GameEvent], before: ContactID?) {
        if var c = s.pending, c.id == .none {
            if c.kind == .block, let w = s.notes.block {
                c.id = w.id
                c.owner = w.owner
            } else {
                c.id = s.takeContactID()
                c.owner = owned(c, s)
            }
            s.pending = c
        }
        if var c = s.notes.afterBlock, c.id == .none {
            c.id = s.takeContactID()
            c.owner = owned(c, s)
            s.notes.afterBlock = c
        }
        if let c = s.pending, c.kind == .attack, c.id != before, !s.humans.isEmpty {
            close(&s, &events)
            if let (h, blocker) = blockOwner(against: c, s) {
                let w = BlockWindow(id: s.takeContactID(), owner: h, athlete: blocker, attack: c.id, attackTick: c.tick)
                s.notes.block = w
                s.lastToucherHuman[blocker.team.rawValue] = h
                events.append(.window(w.id, .block, owner: h, contactTick: c.tick))
            }
        }
        if let w = s.notes.block, s.pending?.id != w.attack && s.pending?.id != w.id { close(&s, &events) }
        // The side's turn is taken as the window opens: a dig held back for a
        // block that then touches the ball never was anyone's.
        if let c = s.pending, c.id != before, let owner = c.owner, let kind = c.kind, kind != .block {
            s.lastToucherHuman[c.team.rawValue] = owner
            events.append(.window(c.id, kind, owner: owner, contactTick: c.tick))
        }
    }

    static func owned(_ c: PendingContact, _ s: GameState) -> HumanID? {
        guard let kind = c.kind, kind != .block, let athlete = c.athlete else { return nil }
        return owner(for: athlete, kind: kind, s)
    }

    /// Ends the human block; a block never jumped is a miss.
    static func close(_ s: inout GameState, _ events: inout [GameEvent]) {
        guard let w = s.notes.block else { return }
        if w.grade == nil { events.append(.judged(w.id, .miss)) }
        s.notes.block = nil
    }
}

extension GameState {
    /// Human `owner`'s buffered inputs for contact `id`.
    func inputs(for id: ContactID, owner: HumanID?) -> [PlayerInput] {
        guard let owner else { return [] }
        return inputBuffer.filter { $0.human == owner && $0.contact == id }
    }

    func inputs(for c: PendingContact) -> [PlayerInput] {
        inputs(for: c.id, owner: c.owner)
    }
}
