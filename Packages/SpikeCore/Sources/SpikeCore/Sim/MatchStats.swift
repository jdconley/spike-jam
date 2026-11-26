/// Totals over a batch of headless matches.
public struct MatchStats: Equatable, Sendable {
    public var matches = 0
    public var rallies = 0
    /// Serves plus every touch.
    public var touches = 0
    public var sideOuts = 0
    public var aces = 0
    public var serviceErrors = 0
    public var kills = 0
    public var attackErrors = 0
    public var handlingErrors = 0
    /// Matches in which `checkInvariants` reported a problem.
    public var invariantFailures = 0
    /// Matches that didn't finish within the tick limit.
    public var unfinished = 0
    /// Sum of winner's points minus loser's points.
    public var marginTotal = 0

    public init() {}

    public var avgTouchesPerRally: Double { rallies == 0 ? 0 : Double(touches) / Double(rallies) }
    public var sideOutRate: Double { rallies == 0 ? 0 : Double(sideOuts) / Double(rallies) }
    public var avgMargin: Double { matches == 0 ? 0 : Double(marginTotal) / Double(matches) }
}

/// Plays `count` bot-vs-bot matches; match i uses seed `settings.seed + i`.
/// Invariants are checked after every step.
public func runMatches(_ settings: MatchSettings, count: Int, maxTicks: Int = 60 * 60 * 30) -> MatchStats {
    var stats = MatchStats()
    for i in 0..<count {
        var match = settings
        match.seed = settings.seed &+ UInt64(i)
        var s = GameState(settings: match)
        var broken = false
        for _ in 0..<maxTicks where s.phase != .matchOver {
            for e in step(&s, inputs: []) {
                switch e {
                case .served, .touched: stats.touches += 1
                case .sideOut: stats.sideOuts += 1
                case .point(_, let reason):
                    stats.rallies += 1
                    switch reason {
                    case .ace: stats.aces += 1
                    case .serviceError: stats.serviceErrors += 1
                    case .kill: stats.kills += 1
                    case .attackError: stats.attackErrors += 1
                    case .handlingError: stats.handlingErrors += 1
                    }
                case .liberoIn, .outOfReach, .matchWon: break
                }
            }
            if !broken && !checkInvariants(s).isEmpty {
                broken = true
                stats.invariantFailures += 1
            }
        }
        stats.matches += 1
        if let w = s.score.winner {
            stats.marginTotal += s.score.points(w) - s.score.points(w.other)
        } else {
            stats.unfinished += 1
        }
    }
    return stats
}
