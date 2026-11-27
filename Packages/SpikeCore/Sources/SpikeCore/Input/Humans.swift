/// One human in the match (spec §4.1): their team, their huddle pick, and
/// the switch they made since the huddle, if any.
public struct HumanSlot: Codable, Equatable, Sendable {
    public var id: HumanID
    public var team: TeamSide
    /// The huddle pick. It sticks from rally to rally until changed.
    public var pick: Pick
    /// The mid-rally override from the switch strip; the next huddle clears it.
    public var switched: Pick?
    /// Done in the huddle.
    public var ready: Bool

    public init(id: HumanID, team: TeamSide, pick: Pick = .ball, switched: Pick? = nil, ready: Bool = false) {
        self.id = id
        self.team = team
        self.pick = pick
        self.switched = switched
        self.ready = ready
    }

    /// What they play right now: the switch if they made one, else the pick.
    public var current: Pick { switched ?? pick }
}

extension GameState {
    /// The slot of human `h`.
    public func human(_ h: HumanID) -> HumanSlot? {
        humans.first { $0.id == h }
    }
}

/// The athlete human `h` controls right now, who the white arrow is over
/// (spec §4.1). The pick follows the person: a picked middle the libero has
/// replaced is played as the libero, and a picked libero who is off (their
/// middle serving) as that middle, so it is always someone on court. With
/// "ball", it is whoever on their side `h` plays the next touch with (their
/// blocker while the other side's set is up), and nil while they have no
/// touch coming.
public func controlled(by h: HumanID, _ s: GameState) -> AthleteID? {
    guard let slot = s.human(h) else { return nil }
    switch slot.current {
    case .athlete(let a):
        return onCourt(as: a, s)
    case .ball:
        if let c = s.pending, c.kind != nil, c.team == slot.team, c.owner == h { return c.athlete }
        // Their block against the other side's set.
        if let w = s.notes.block, w.owner == h { return w.athlete }
        return nil
    }
}

/// Who plays for `a` on court: `a`, the libero standing in for them, or the
/// middle standing in for the libero. Nil only for someone not in the lineup.
func onCourt(as a: AthleteID, _ s: GameState) -> AthleteID? {
    if s.motion[a] != nil { return a }
    let side = a.team
    let lineup = s.lineups[side.rawValue]
    if a == lineup.libero {
        // The libero is off while their middle serves from zone 1.
        return s.rosters[side.rawValue].ids(.middle).first { s.motion[$0] != nil && lineup.zone(of: $0)?.isFrontRow == false }
    }
    if s.motion[lineup.libero] != nil, s.liberoReplacing(side, in: s.motion) == a { return lineup.libero }
    return nil
}
