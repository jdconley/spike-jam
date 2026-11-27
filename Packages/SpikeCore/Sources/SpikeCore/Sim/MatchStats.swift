/// Totals over a batch of headless matches.
public struct MatchStats: Equatable, Sendable {
    public var matches = 0
    public var rallies = 0
    /// Serves plus every touch, blocks included.
    public var touches = 0
    public var sideOuts = 0
    public var aces = 0
    public var serviceErrors = 0
    /// Attacks that won the point outright: the ball landed, the dig was
    /// shanked, or it went off the block and out.
    public var kills = 0
    /// Attacks into the net or out (not blocked).
    public var attackErrors = 0
    public var handlingErrors = 0
    /// Stuff blocks: points to the blockers.
    public var blocks = 0
    public var serves = 0
    /// Attack attempts, the setter's dumps included.
    public var attacks = 0
    /// Attacks played as tips or roll shots, and dumps.
    public var tips = 0
    public var digs = 0
    /// Block touches of every kind (stuffs, soft blocks and tools).
    public var blockTouches = 0
    /// Matches in which `checkInvariants` reported a problem.
    public var invariantFailures = 0
    /// Matches that didn't finish within the tick limit.
    public var unfinished = 0
    /// Sum of winner's points minus loser's points.
    public var marginTotal = 0
    /// Matches the home side won.
    public var homeWins = 0
    /// By `TeamSide.rawValue`: matches in which that side led by 6 or more
    /// at some point, and how many of those it went on to lose.
    public var bigLeads = [0, 0]
    public var bigLeadsLost = [0, 0]
    /// Serves at which a team's line-up, where its players actually stood,
    /// broke the overlap rule. Must be 0: the AI always lines up legally.
    public var overlapViolations = 0
    /// Second balls the setting setter couldn't get to: a teammate set
    /// instead, or nobody could and it dropped.
    public var lateSetters = 0
    /// Serves, attacks and passes that dropped because nobody could get to
    /// them in time.
    public var droppedForReach = 0
    /// Sets by call, the Dump included.
    public var setCalls: [PlayCall: Int] = [:]
    /// `droppedForReach` by the touch nobody got to.
    public var drops: [TouchKind: Int] = [:]
    /// Every `erred` event, by kind of touch and error.
    public var errors: [TouchKind: [TouchError: Int]] = [:]
    /// Every human touch's timing grade (`judged` events).
    public var grades: [Grade: Int] = [:]
    /// Times anyone caught fire.
    public var fires = 0

    /// The share of human touches graded `g`.
    public func gradeRate(_ g: Grade) -> Double {
        let total = grades.values.reduce(0, +)
        return total == 0 ? 0 : Double(grades[g] ?? 0) / Double(total)
    }

    public init() {}

    public var avgTouchesPerRally: Double { rallies == 0 ? 0 : Double(touches) / Double(rallies) }
    public var sideOutRate: Double { rallies == 0 ? 0 : Double(sideOuts) / Double(rallies) }
    public var avgMargin: Double { matches == 0 ? 0 : Double(marginTotal) / Double(matches) }
    /// Serve errors per serve.
    public var serveErrorRate: Double { serves == 0 ? 0 : Double(serviceErrors) / Double(serves) }
    public var aceRate: Double { serves == 0 ? 0 : Double(aces) / Double(serves) }
    /// Kills per attack attempt.
    public var killRate: Double { attacks == 0 ? 0 : Double(kills) / Double(attacks) }
    /// Attack errors per attempt, counting a stuffed attack as an error as
    /// the real game's stats do.
    public var attackErrorRate: Double { attacks == 0 ? 0 : Double(attackErrors + blocks) / Double(attacks) }
    public var tipRate: Double { attacks == 0 ? 0 : Double(tips) / Double(attacks) }
    public var homeWinRate: Double { matches == 0 ? 0 : Double(homeWins) / Double(matches) }

    /// The totals of two batches together.
    public func adding(_ o: MatchStats) -> MatchStats {
        var t = self
        t.matches += o.matches
        t.rallies += o.rallies
        t.touches += o.touches
        t.sideOuts += o.sideOuts
        t.aces += o.aces
        t.serviceErrors += o.serviceErrors
        t.kills += o.kills
        t.attackErrors += o.attackErrors
        t.handlingErrors += o.handlingErrors
        t.blocks += o.blocks
        t.serves += o.serves
        t.attacks += o.attacks
        t.tips += o.tips
        t.digs += o.digs
        t.blockTouches += o.blockTouches
        t.invariantFailures += o.invariantFailures
        t.unfinished += o.unfinished
        t.marginTotal += o.marginTotal
        t.homeWins += o.homeWins
        t.bigLeads = zip(t.bigLeads, o.bigLeads).map(+)
        t.bigLeadsLost = zip(t.bigLeadsLost, o.bigLeadsLost).map(+)
        t.overlapViolations += o.overlapViolations
        t.lateSetters += o.lateSetters
        t.droppedForReach += o.droppedForReach
        t.setCalls.merge(o.setCalls, uniquingKeysWith: +)
        t.drops.merge(o.drops, uniquingKeysWith: +)
        t.errors.merge(o.errors) { a, b in a.merging(b, uniquingKeysWith: +) }
        t.grades.merge(o.grades, uniquingKeysWith: +)
        t.fires += o.fires
        return t
    }
}

/// Plays `count` matches; match i uses seed `settings.seed + i`. `humans`
/// play through real inputs (each match reseeds them with its own seed);
/// `touches` is the timing stand-in (see `step`); without either every touch
/// is the AI's. Invariants are checked after every step.
public func runMatches(_ settings: MatchSettings, count: Int, maxTicks: Int = 60 * 60 * 30,
                       touches: (any TouchSource)? = nil, humans: [SimHuman] = []) -> MatchStats {
    var stats = MatchStats()
    for i in 0..<count {
        var match = settings
        match.seed = settings.seed &+ UInt64(i)
        var sims = humans.map { SimHuman(id: $0.id, team: $0.team, skill: $0.skill, pick: $0.pick, seed: match.seed) }
        var s = GameState(settings: match, humans: sims.map(\.slot))
        var broken = false
        var led = [false, false]
        for _ in 0..<maxTicks where s.phase != .matchOver {
            var inputs: [PlayerInput] = []
            for k in sims.indices { inputs += sims[k].inputs(for: s) }
            for e in step(&s, inputs: inputs, touches: touches) {
                switch e {
                case .served:
                    stats.touches += 1
                    stats.serves += 1
                case .touched(let kind, _, _):
                    stats.touches += 1
                    switch kind {
                    case .attack: stats.attacks += 1
                    case .dig: stats.digs += 1
                    case .block: stats.blockTouches += 1
                    default: break
                    }
                case .sideOut: stats.sideOuts += 1
                case .point(_, let reason):
                    stats.rallies += 1
                    switch reason {
                    case .ace: stats.aces += 1
                    case .serviceError: stats.serviceErrors += 1
                    case .kill: stats.kills += 1
                    case .attackError: stats.attackErrors += 1
                    case .handlingError: stats.handlingErrors += 1
                    case .block: stats.blocks += 1
                    }
                    for side in TeamSide.allCases where s.score.points(side) - s.score.points(side.other) >= 6 {
                        led[side.rawValue] = true
                    }
                case .outOfReach(let kind, _):
                    stats.droppedForReach += 1
                    stats.drops[kind, default: 0] += 1
                    if kind == .set { stats.lateSetters += 1 }
                case .setCall(_, let call):
                    stats.setCalls[call, default: 0] += 1
                    if call == .dump { stats.tips += 1 }
                case .tipped: stats.tips += 1
                case .erred(let kind, _, let error): stats.errors[kind, default: [:]][error, default: 0] += 1
                case .judged(_, let grade): stats.grades[grade, default: 0] += 1
                case .fire(_, let on): if on { stats.fires += 1 }
                case .liberoIn, .matchWon, .window: break
                }
                if case .touched(.set, let who, _) = e,
                   who != s.lineups[who.team.rawValue].settingSetter(isServing: s.isServing(who.team)) {
                    stats.lateSetters += 1
                }
            }
            if s.serveTick == s.tick {
                for side in TeamSide.allCases where !overlapAtServe(s, side).isEmpty { stats.overlapViolations += 1 }
            }
            if !broken && !checkInvariants(s).isEmpty {
                broken = true
                stats.invariantFailures += 1
            }
        }
        stats.matches += 1
        if let w = s.score.winner {
            stats.marginTotal += s.score.points(w) - s.score.points(w.other)
            if w == .home { stats.homeWins += 1 }
            for side in TeamSide.allCases where led[side.rawValue] {
                stats.bigLeads[side.rawValue] += 1
                if w != side { stats.bigLeadsLost[side.rawValue] += 1 }
            }
        } else {
            stats.unfinished += 1
        }
    }
    return stats
}

/// The overlap problems of `side`'s line-up where its players stand now.
public func overlapAtServe(_ s: GameState, _ side: TeamSide) -> [String] {
    let lineup = s.lineups[side.rawValue]
    let serving = s.isServing(side)
    var spots: [Zone: LocalSpot] = [:]
    for z in Zone.allCases {
        guard let m = s.motion[lineup.occupant(z, isServing: serving)] else { return ["zone \(z.rawValue) is empty"] }
        spots[z] = LocalFrame.toLocal(m.pos, team: side)
    }
    return Overlap.violations(spots, isServing: serving)
}
