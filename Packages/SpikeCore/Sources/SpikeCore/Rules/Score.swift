/// Rally scoring: every rally is a point, one set to `pointsToWin`, win by
/// `winBy` (spec §4.1).
public struct Score: Codable, Equatable, Sendable {
    /// Indexed by `TeamSide.rawValue`.
    public var points: [Int]
    public var serving: TeamSide
    public var winner: TeamSide?

    public init(settings: MatchSettings) {
        points = [0, 0]
        serving = settings.firstServer
        winner = nil
    }

    public func points(_ side: TeamSide) -> Int { points[side.rawValue] }
}

public struct RallyResult: Equatable, Sendable {
    public var sideOut: Bool
    public var matchWon: Bool

    public init(sideOut: Bool, matchWon: Bool) {
        self.sideOut = sideOut
        self.matchWon = matchWon
    }
}

/// Gives `winner` the rally's point. A receiving team that wins sides out:
/// it rotates and takes the serve. The serving team never rotates before its
/// first serve, and the losing team never rotates.
public func awardRally(to winner: TeamSide, score: inout Score, lineups: inout [Lineup], settings: MatchSettings) -> RallyResult {
    precondition(score.winner == nil, "awardRally after the match is over")
    score.points[winner.rawValue] += 1
    let sideOut = score.serving != winner
    if sideOut {
        lineups[winner.rawValue].rotate()
        score.serving = winner
    }
    let w = score.points(winner), l = score.points(winner.other)
    if w >= settings.pointsToWin && w - l >= settings.winBy {
        score.winner = winner
    }
    return RallyResult(sideOut: sideOut, matchWon: score.winner != nil)
}
