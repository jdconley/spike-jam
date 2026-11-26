/// Every rule the state must always obey. Empty when the state is valid.
public func checkInvariants(_ s: GameState) -> [String] {
    var problems: [String] = []
    let settings = s.settings

    for side in TeamSide.allCases {
        let lineup = s.lineups[side.rawValue]
        let serving = s.isServing(side)
        let court = lineup.onCourt(isServing: serving)
        let name = "\(side)"

        if !(0..<6).contains(lineup.rotation) {
            problems.append("\(name): rotation \(lineup.rotation) outside 0..<6")
            continue
        }
        if court.count != 6 || Set(court.values).count != 6 {
            problems.append("\(name): \(Set(court.values).count) distinct athletes on court, not 6")
        }
        let placed = Set(s.motion.keys.filter { $0.team == side })
        if placed != Set(court.values) {
            problems.append("\(name): motion holds \(placed.count) athletes that don't match the on-court six")
        }
        for id in placed {
            let m = s.motion[id]!
            for (what, v) in [("position", m.pos), ("goal", m.goal)] {
                let p = LocalFrame.toLocal(v, team: side)
                if p.d < Tuning.minDepth - 1e-3 || p.d > Tuning.maxDepth + 1e-3 || abs(p.l) > Tuning.maxLateral + 1e-3 {
                    problems.append("\(name): athlete \(id.index) \(what) d \(p.d) l \(p.l) is off its side or out of the free zone")
                }
            }
        }
        // The libero never takes a front-row approach, block or attack spot.
        if let m = s.motion[lineup.libero] {
            let goal = LocalFrame.toLocal(m.goal, team: side)
            if goal.d < Choreographer.liberoMinDepth - 1e-3 {
                problems.append("\(name): libero goal d \(goal.d) is in front of the 3 m line")
            }
            if let j = m.jump, j.height > 0.3 {
                problems.append("\(name): libero jumps \(j.height) m")
            }
        }
        // The overlap rule, where everyone actually stands as the serve is struck.
        if s.serveTick == s.tick {
            for v in overlapAtServe(s, side) { problems.append("\(name): overlap at the serve: \(v)") }
        }
        for (z, id) in court where id == lineup.libero && z.isFrontRow {
            problems.append("\(name): libero in front-row zone \(z.rawValue)")
        }
        if lineup.server() == lineup.libero {
            problems.append("\(name): libero is the server")
        }
        if serving {
            let server = lineup.server()
            if court[.z1] != server || s.motion[server] == nil {
                problems.append("\(name): the server is not the zone-1 base occupant on court")
            }
        }
        if lineup.system == .sixTwo {
            let setter = lineup.settingSetter(isServing: serving)
            if lineup.zone(of: setter)?.isFrontRow ?? true {
                problems.append("\(name): 6-2 setting setter is not in the back row")
            }
        }
    }

    // Points: nobody passes the score at which the match must have ended,
    // and the winner is set exactly when the win rule is met.
    let p = s.score.points
    if p.count != 2 {
        problems.append("score has \(p.count) entries, not 2")
    } else {
        for side in TeamSide.allCases {
            let mine = p[side.rawValue], theirs = p[side.other.rawValue]
            if mine > max(settings.pointsToWin, theirs + settings.winBy) {
                problems.append("\(side) has \(mine) points; the match should have ended")
            }
            let won = mine >= settings.pointsToWin && mine - theirs >= settings.winBy
            if won != (s.score.winner == side) {
                problems.append("\(side) at \(mine)–\(theirs): winner is \(String(describing: s.score.winner))")
            }
        }
    }

    if (s.phase == .matchOver) != (s.score.winner != nil) {
        problems.append("phase \(s.phase) but winner \(String(describing: s.score.winner))")
    }
    return problems
}
