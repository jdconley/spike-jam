/// The AI defense's read (spec §4.3): while the other team passes and sets,
/// it guesses the hitter. The block leans and the back row shifts that way,
/// so a right read gets more hands and diggers to the ball and a wrong one
/// opens a gap.
public enum DefenseAI {
    /// The defending team's guess at the next hitter, for the set pending
    /// now. It weighs the options the way the setter will (so a bad pass,
    /// which leaves only a high ball or two, is easy to read and a perfect
    /// one isn't) and goes with the likeliest more often the better the
    /// team's average `defense`. Nil when no set is coming.
    public static func read(_ s: inout GameState, defending: TeamSide) -> AthleteID? {
        read(&s, defending: defending, nudge: 0)
    }

    /// `nudge` is the defending side's catch-up level: a side held back
    /// reads a little worse.
    static func read(_ s: inout GameState, defending: TeamSide, nudge: Float) -> AthleteID? {
        // A human's read for the side overrides the AI's for the rally.
        if let human = s.notes.humanReads[defending.rawValue] { return human }
        let attacking = defending.other
        guard let c = s.pending, c.kind == .set, c.team == attacking, let setter = c.athlete else { return nil }
        let options = SetterAI.options(s, team: attacking, passQuality: s.notes.passQuality, setter: setter)
        guard let likeliest = options.max(by: { $0.chance < $1.chance }) else { return nil }
        let sharp = min(max(Tuning.readBase + Tuning.readSkill * averageDefense(s, defending)
                            + Tuning.catchUpRead * nudge, 0.05), 0.95)
        if s.rng.unit() < sharp { return likeliest.hitter }
        // A half-read: a guess weighted by what the setter tends to do.
        var r = s.rng.unit()
        for o in options {
            r -= o.chance
            if r < 0 { return o.hitter }
        }
        return options.last!.hitter
    }

    /// The mean `defense` trait of the six on court.
    static func averageDefense(_ s: GameState, _ side: TeamSide) -> Float {
        let lineup = s.lineups[side.rawValue], roster = s.rosters[side.rawValue]
        let six = Zone.allCases.map { roster[lineup.occupant($0, isServing: s.isServing(side))].traits.defense }
        return six.reduce(0, +) / Float(six.count)
    }

    /// How far the defense leans toward its read: 0.5 m, up to 1.0 m for a
    /// team of perfect defenders.
    static func lean(defense: Float) -> Float {
        0.5 + 0.5 * min(max(defense, 0), 1)
    }

    /// The perimeter with its back row shifted along the net toward a read
    /// hitter whose set goes to team-local `l`: the whole back row moves
    /// together, `lean(defense:)` metres, or less if it's already that close,
    /// and never off the court.
    public static func shift(_ p: PerimeterSpots, toward l: Float, defense: Float) -> PerimeterSpots {
        let back: [PerimeterRole] = [.leftBack, .middleBack, .rightBack]
        let centre = back.map { p[$0].l }.reduce(0, +) / 3
        let by = min(max(l - centre, -lean(defense: defense)), lean(defense: defense))
        func moved(_ s: LocalSpot) -> LocalSpot { LocalSpot(d: s.d, l: min(max(s.l + by, -4.3), 4.3)) }
        return PerimeterSpots(leftFront: p.leftFront, middleFront: p.middleFront, rightFront: p.rightFront,
                              leftBack: moved(p.leftBack), middleBack: moved(p.middleBack), rightBack: moved(p.rightBack))
    }

    /// A blocker's spot leaned toward the read: up to `lean` metres along the
    /// net toward `l`.
    static func lean(_ spot: LocalSpot, toward l: Float, defense: Float) -> LocalSpot {
        let by = min(max(l - spot.l, -lean(defense: defense)), lean(defense: defense))
        return LocalSpot(d: spot.d, l: spot.l + by)
    }

    /// Where the read hitter's set goes, in the defending team's frame; nil
    /// without a read.
    static func readTarget(_ s: GameState, defending: TeamSide) -> Float? {
        guard let hitter = s.notes.reads[defending.rawValue] else { return nil }
        let attacking = defending.other
        let call = liveCalls(s, team: attacking, passQuality: s.notes.passQuality).first { $0.0 == hitter }?.1
            ?? (hitter == s.lineups[attacking.rawValue].settingSetter(isServing: s.isServing(attacking)) ? .dump : nil)
        guard let call else { return nil }
        let point = PlayBook.setPoint(call, team: attacking, net: s.settings.gameType.netHeight)
        return LocalFrame.toLocal(point.xz, team: defending).l
    }
}
