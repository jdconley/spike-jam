/// The AI setter (spec §4.3): it picks among the live calls from the pass,
/// the hitters, where the blockers stand and the game's habits, the way a
/// good setter does, and like a real one it doesn't always pick the best.
public enum SetterAI {
    /// One live option and the chance the setter picks it.
    public struct Option: Equatable, Sendable {
        public var hitter: AthleteID
        public var call: PlayCall
        public var score: Float
        public var chance: Float
    }

    /// The setting setter's choice off a pass of `passQuality`, as a bot:
    /// the catch-up level of its side applies.
    public static func choose(_ s: inout GameState, team: TeamSide, passQuality: Float) -> (AthleteID, PlayCall) {
        let setter = s.lineups[team.rawValue].settingSetter(isServing: s.isServing(team))
        return choose(&s, team: team, passQuality: passQuality, setter: setter, nudge: CatchUp.level(s)[team] ?? 0)
    }

    /// `setter`'s choice. A teammate bailing out the setter can't dump and
    /// can't set themselves. `nudge` is the catch-up level of the setter's
    /// side (0 for a human): a side held back sets less sharply.
    static func choose(_ s: inout GameState, team: TeamSide, passQuality: Float, setter: AthleteID,
                       nudge: Float) -> (AthleteID, PlayCall) {
        let opts = options(s, team: team, passQuality: passQuality, setter: setter, nudge: nudge)
        var r = s.rng.unit()
        for o in opts {
            r -= o.chance
            if r < 0 { return (o.hitter, o.call) }
        }
        return (opts.last!.hitter, opts.last!.call)
    }

    /// Every live option with its score and the chance of being picked: a
    /// softmax over the scores at a temperature that falls as the setter's
    /// `set` trait rises. Never empty: the outside's 4 or the right side's 5
    /// is always live.
    public static func options(_ s: GameState, team: TeamSide, passQuality: Float, setter: AthleteID,
                               nudge: Float = 0) -> [Option] {
        let roster = s.rosters[team.rawValue]
        let setting = s.lineups[team.rawValue].settingSetter(isServing: s.isServing(team))
        let recent = s.notes.recentHitters[team.rawValue]
        var opts: [Option] = []
        for (id, call) in liveCalls(s, team: team, passQuality: passQuality) {
            if id == setter && !(call == .dump && setter == setting) { continue }
            if call == .dump && setter != setting { continue }
            let spec = PlayBook.spec(call)
            var score = Tuning.setterAttackWeight * roster[id].traits.attack
            score -= Tuning.setterBlockerWeight * expectedBlockers(s, attacking: team, call: call)
            score += habit(s.settings.gameType, call)
            if spec.tempo == .first && call != .dump {
                score += Tuning.setterQuickBonus * max(0, passQuality - PlayBook.goodPass) / (1 - PlayBook.goodPass)
            }
            // Off a poor pass the safe ball is the high one to a pin; a
            // back-row attack needs a better set.
            let poor = max(0, PlayBook.goodPass - passQuality) / PlayBook.goodPass
            if call == .four || call == .five { score += Tuning.setterSafeBonus * poor }
            if spec.lane.isBackRow { score -= Tuning.setterBackRowPenalty * poor }
            score -= Tuning.setterRepeatPenalty * Float(recent.filter { $0 == id }.count)
            opts.append(Option(hitter: id, call: call, score: score, chance: 0))
        }
        if opts.isEmpty {
            // Nobody else left (a bail-out with every hitter gone): put a 4 up
            // to whoever is left in the front row.
            let lineup = s.lineups[team.rawValue]
            let anyone = lineup.attackers(isServing: s.isServing(team)).first { $0 != setter }
                ?? Zone.allCases.map { lineup.occupant($0, isServing: s.isServing(team)) }.first { $0 != setter && $0 != lineup.libero }!
            return [Option(hitter: anyone, call: .four, score: 0, chance: 1)]
        }
        let setTrait = roster[setter].traits.set
        let temperature = Tuning.setterTemperature * (1.6 - setTrait) + Tuning.catchUpTemperature * max(0, -nudge)
        let top = opts.map(\.score).max()!
        let weights = opts.map { exponential(($0.score - top) / temperature) }
        let total = weights.reduce(0, +)
        for i in opts.indices { opts[i].chance = weights[i] / total }
        return opts
    }

    /// About how many of the defending front row get to the set in time: for
    /// each blocker, how far they must shuffle along the net against how far
    /// they can in the set's flight, less a reaction time. Faster sets and
    /// sets far from the blockers draw fewer.
    public static func expectedBlockers(_ s: GameState, attacking: TeamSide, call: PlayCall) -> Float {
        let defending = attacking.other
        let spec = PlayBook.spec(call)
        // The defense sees the attacker's left as its right.
        let l = -PlayBook.zoneCenter(spec.netZone)
        let flight = call == .dump ? 0 : spec.setDuration * s.settings.tempo.flightScale
        let time = Float(max(0, flight - Tuning.blockerReaction))
        let lineup = s.lineups[defending.rawValue]
        var total: Float = 0
        for z in [Zone.z4, .z3, .z2] {
            let id = lineup.occupant(z, isServing: s.isServing(defending))
            guard let m = s.motion[id] else { continue }
            let pos = LocalFrame.toLocal(m.pos, team: defending)
            let speed = Steering.cap(.shuffle, speedTrait: s.rosters[defending.rawValue][id].traits.speed)
            let reach = speed * time + Tuning.blockerArmReach
            let dist = abs(pos.l - l)
            total += min(max((reach - dist) / 0.8 + 0.5, 0), 1)
        }
        return total
    }

    /// The AI's huddle before a serve: a bot team mixes its calls so the
    /// other side's read pays off without being a sure thing (spec §4.3).
    /// Each on-court hitter's call is drawn from the game's habits, and now
    /// and then the team runs a combination.
    public static func huddle(_ s: inout GameState, team: TeamSide) {
        let lineup = s.lineups[team.rawValue], roster = s.rosters[team.rawValue]
        let serving = s.isServing(team), game = s.settings.gameType
        var calls = TeamCalls()
        for z in Zone.allCases {
            let id = lineup.occupant(z, isServing: serving)
            let options = PlayBook.calls(for: roster[id].position, frontRow: z.isFrontRow, system: lineup.system)
            guard !options.isEmpty else { continue }
            let weights = options.map { callWeight(game, $0) }
            var r = s.rng.unit() * weights.reduce(0, +)
            var pick = options.last!
            for (c, w) in zip(options, weights) {
                r -= w
                if r < 0 { pick = c; break }
            }
            calls.byAthlete[id] = pick
        }
        if s.rng.chance(Tuning.comboChance) {
            let combo = Combo.allCases[s.rng.int(in: 0..<Combo.allCases.count)]
            calls.apply(combo, lineup: lineup, roster: roster, isServing: serving)
        }
        s.calls[team.rawValue] = calls
    }

    /// How often a bot team calls each play, relative to the others its
    /// hitter could run (Claude's numbers, from §4.7's habits).
    static func callWeight(_ game: GameType, _ call: PlayCall) -> Float {
        switch (game, call) {
        case (.mens, .four): 0.5
        case (.mens, .go): 0.2
        case (.mens, .hut): 0.1
        case (.mens, .thirtyTwo): 0.2
        case (.mens, .one): 0.5
        case (.mens, .thirtyOne): 0.25
        case (.mens, .backOne): 0.15
        case (.mens, .slide): 0.1
        case (.mens, .five): 0.65
        case (.mens, .red): 0.35
        case (.mens, .pipe): 0.6
        case (.mens, .bic): 0.3
        case (.womens, .four): 0.25
        case (.womens, .go): 0.45
        case (.womens, .hut): 0.15
        case (.womens, .thirtyTwo): 0.15
        case (.womens, .one): 0.2
        case (.womens, .thirtyOne): 0.15
        case (.womens, .backOne): 0.15
        case (.womens, .slide): 0.5
        case (.womens, .five): 0.4
        case (.womens, .red): 0.6
        case (.womens, .pipe): 0.75
        case (.womens, .bic): 0.15
        case (_, .a): 0.1
        case (_, .d), (_, .dump): 1
        }
    }

    /// The game's habits (spec §4.7): the men's game leans on the 1 and 31,
    /// the Pipe and Bic and big swings on the 4 and 5; the women's on the
    /// Slide, Go and Hut tempo outside, and Red. Setters dump rarely.
    static func habit(_ game: GameType, _ call: PlayCall) -> Float {
        switch (game, call) {
        case (_, .dump): -1.2
        case (.mens, .one): 0.15
        case (.mens, .thirtyOne): 0.05
        case (.mens, .pipe): 0.1
        case (.mens, .bic): 0.05
        case (.mens, .four), (.mens, .five): 0.1
        case (.womens, .slide): 0.2
        case (.womens, .go): 0.15
        case (.womens, .hut): 0.05
        case (.womens, .red): 0.15
        case (_, .a): -0.4
        default: 0
        }
    }
}

/// e^x for x ≤ 0, without Foundation: e^x = (e^(x/2^k))^(2^k) with a short
/// Taylor series for the small part.
func exponential(_ x: Float) -> Float {
    if x < -30 { return 0 }
    var y = x / 64
    y = 1 + y * (1 + y / 2 * (1 + y / 3 * (1 + y / 4)))
    for _ in 0..<6 { y *= y }
    return y
}
