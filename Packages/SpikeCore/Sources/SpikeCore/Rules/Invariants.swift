/// Every rule the state must always obey. Empty when the state is valid.
public func checkInvariants(_ s: GameState) -> [String] {
    var problems: [String] = []
    let settings = s.settings

    for side in TeamSide.allCases {
        let lineup = s.lineups[side.rawValue]
        let serving = s.isServing(side)
        // Checked every step in the soaks, so it avoids reflection and sets.
        let name = side == .home ? "home" : "away"

        if !(0..<6).contains(lineup.rotation) {
            problems.append("\(name): rotation \(lineup.rotation) outside 0..<6")
            continue
        }
        var six: [AthleteID] = []
        six.reserveCapacity(6)
        for z in Zone.allCases { six.append(lineup.occupant(z, isServing: serving)) }
        var distinct = true, allPlaced = true
        for i in 0..<6 {
            if s.motion[six[i]] == nil { allPlaced = false }
            for j in (i + 1)..<6 where six[i] == six[j] { distinct = false }
        }
        if !distinct {
            problems.append("\(name): \(Set(six).count) distinct athletes on court, not 6")
        }
        let placed = s.motion.keys.filter { $0.team == side }
        if placed.count != 6 || !allPlaced {
            problems.append("\(name): motion holds \(placed.count) athletes that don't match the on-court six")
        }
        func offSide(_ v: Vec2) -> LocalSpot? {
            let p = LocalFrame.toLocal(v, team: side)
            let off = p.d < Tuning.minDepth - 1e-3 || p.d > Tuning.maxDepth + 1e-3 || abs(p.l) > Tuning.maxLateral + 1e-3
            return off ? p : nil
        }
        for id in placed {
            let m = s.motion[id]!
            if let p = offSide(m.pos) {
                problems.append("\(name): athlete \(id.index) position d \(p.d) l \(p.l) is off its side or out of the free zone")
            }
            if let p = offSide(m.goal) {
                problems.append("\(name): athlete \(id.index) goal d \(p.d) l \(p.l) is off its side or out of the free zone")
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
        for (z, id) in zip(Zone.allCases, six) where id == lineup.libero && z.isFrontRow {
            problems.append("\(name): libero in front-row zone \(z.rawValue)")
        }
        if lineup.server() == lineup.libero {
            problems.append("\(name): libero is the server")
        }
        if serving {
            let server = lineup.server()
            if six[0] != server || s.motion[server] == nil {
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
