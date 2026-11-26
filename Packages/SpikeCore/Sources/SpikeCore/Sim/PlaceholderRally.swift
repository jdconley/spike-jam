/// A stand-in rally engine with fixed odds from `Tuning`. Every touch is a
/// dice roll; the choreographer moves the players around it. Plans 3–4
/// replace it with AI traits and human input on the same state and `step`.
enum PlaceholderRally {
    // MARK: Serve

    static func serve(_ s: inout GameState, _ events: inout [GameEvent]) {
        let team = s.score.serving
        // Bot teams call their plays; a human's team keeps its calls.
        for side in TeamSide.allCases where !s.settings.humanSides.contains(side) { SetterAI.huddle(&s, team: side) }
        let lineup = s.lineups[team.rawValue]
        let server = lineup.server()
        // Struck from where the server stands, behind the end line.
        let from = s.motion[server]!.pos.atHeight(2.6)
        s.phase = .rally
        s.touchesThisSide = 0
        s.serveTick = s.tick
        s.lastTouch = server
        s.notes.passQuality = 1
        s.notes.play = nil
        events.append(.served(server))

        let duration = Tuning.serveDuration * s.settings.tempo.flightScale * s.settings.gameType.paceScale
        if s.rng.chance(Tuning.serveError) {
            if s.rng.chance(Tuning.serveErrorNetShare) {
                launchNetError(&s, from: from, team: team, duration: duration, winner: team.other, reason: .serviceError)
            } else {
                let to = longSpot(&s, attacking: team)
                launchCrossing(&s, from: from, to: to, duration: duration)
                s.pending = landing(&s, winner: team.other, reason: .serviceError)
            }
            return
        }
        let spot = courtSpot(&s, of: team.other, depth: 1.5...8.5)
        if s.rng.chance(Tuning.ace) {
            launchCrossing(&s, from: from, to: spot.atHeight(0), duration: duration)
            s.pending = landing(&s, winner: team, reason: .ace)
        } else {
            incoming(.receive, to: team.other, spot: spot, from: from, duration: duration, dropReason: .ace, &s, &events)
        }
    }

    /// A serve or attack that stays in, coming down at `spot` on `team`'s
    /// court. Whoever on `team` can get there soonest plays it; if nobody can
    /// get there in time, it drops for `dropReason`.
    static func incoming(_ kind: TouchKind, to team: TeamSide, spot: Vec2, from: Vec3, duration: Double,
                         dropReason: PointReason, _ s: inout GameState, _ events: inout [GameEvent]) {
        let clearance = s.settings.gameType.netHeight + Tuning.netClearanceMargin
        let flight = Flight.makeClearing(from: from, to: spot.atHeight(Tuning.passContactHeight), duration: clamp(duration),
                                         startTime: s.time, netClearance: clearance)
        let tick = contactTick(s, flight)
        let reach = kind == .receive ? Tuning.passReach : Tuning.digReach
        if let who = quickestToBall(s, team, spot, reach: reach, contactTick: tick) {
            launch(&s, flight)
            s.pending = PendingContact(kind: kind, team: team, athlete: who, tick: tick)
        } else {
            events.append(.outOfReach(kind, team: team))
            launchCrossing(&s, from: from, to: spot.atHeight(0), duration: duration)
            s.pending = landing(&s, winner: team.other, reason: dropReason)
        }
    }

    /// The on-court player of `team` who can get within `reach` of `spot`
    /// soonest, if they make it by `contactTick`. Never the setting setter,
    /// who saves themselves for the second ball, and never the libero in
    /// front of the 3 m line.
    static func quickestToBall(_ s: GameState, _ team: TeamSide, _ spot: Vec2, reach: Float, contactTick: Int) -> AthleteID? {
        let lineup = s.lineups[team.rawValue]
        let serving = s.isServing(team)
        let setter = lineup.settingSetter(isServing: serving)
        let target = LocalFrame.toLocal(spot, team: team)
        var best: (AthleteID, Int)?
        for z in Zone.allCases {
            let id = lineup.occupant(z, isServing: serving)
            guard id != setter, let m = s.motion[id] else { continue }
            let point = Choreographer.reach(LocalFrame.toLocal(m.pos, team: team), target, reach)
            if id == lineup.libero && point.d < Choreographer.liberoMinDepth { continue }
            guard let eta = reachTicks(s, id, LocalFrame.toWorld(point, team: team)) else { continue }
            if best == nil || eta < best!.1 { best = (id, eta) }
        }
        guard let (id, eta) = best, eta <= contactTick - s.tick + reachGraceTicks else { return nil }
        return id
    }

    // MARK: Touches

    static func resolve(_ c: PendingContact, _ s: inout GameState, _ events: inout [GameEvent]) {
        guard let kind = c.kind else {
            endRally(winner: c.team, reason: c.reason ?? .kill, &s, &events)
            return
        }
        let athlete = c.athlete!
        switch kind {
        case .receive, .dig:
            pass(kind, athlete, c.team, &s, &events)
        case .set:
            set(athlete, c.team, &s, &events)
        case .attack:
            attack(athlete, c.team, &s, &events)
        case .serve:
            serve(&s, &events)
        }
    }

    static func pass(_ kind: TouchKind, _ athlete: AthleteID, _ team: TeamSide, _ s: inout GameState, _ events: inout [GameEvent]) {
        s.touchesThisSide = 1
        s.lastTouch = athlete
        let from = s.ball!.position(at: s.time)
        if s.rng.chance(Tuning.passError) {
            events.append(.touched(kind, athlete, quality: 0))
            shank(&s, from: from, team: team)
            return
        }
        let q = s.rng.float(in: Tuning.passQuality)
        events.append(.touched(kind, athlete, quality: q))
        let duration = clamp((Tuning.passDurationBase + Tuning.passDurationSpread * Double(1 - q)) * s.settings.tempo.flightScale)
        let to = passTarget(&s, team: team, quality: q)
        let flight = Flight.make(from: from, to: to, duration: duration, startTime: s.time)
        guard let setter = whoSets(s, team, passer: athlete, at: to.xz, contactTick: contactTick(s, flight)) else {
            // Nobody can get to the pass in time: it falls to the floor.
            events.append(.outOfReach(.set, team: team))
            launch(&s, Flight.make(from: from, to: to.xz.atHeight(0), duration: duration, startTime: s.time))
            s.pending = landing(&s, winner: team.other, reason: .handlingError)
            return
        }
        launch(&s, flight)
        // A teammate bailing out the setter can only put up a high ball.
        let setting = s.lineups[team.rawValue].settingSetter(isServing: s.isServing(team))
        s.notes.passQuality = setter == setting ? q : min(q, Tuning.bailOutPassQuality)
        s.pending = PendingContact(kind: .set, team: team, athlete: setter, tick: contactTick(s))
    }

    /// Where a pass of quality `q` goes: the setter target for a perfect
    /// pass, up to `passScatter` metres off it for the worst, kept on the
    /// passing team's court.
    static func passTarget(_ s: inout GameState, team: TeamSide, quality q: Float) -> Vec3 {
        let target = Court.setterTarget(team: team)
        let worst = Tuning.passQuality.lowerBound
        let miss = Tuning.passScatter * max(0, 1 - q) / (1 - worst)
        var spot = LocalFrame.toLocal(target.xz, team: team)
        spot.d = min(max(spot.d + miss * s.rng.float(in: -1...1), 0.4), 7.0)
        spot.l = min(max(spot.l + miss * s.rng.float(in: -1...1), -4.2), 4.2)
        return LocalFrame.toWorld(spot, team: team).atHeight(target.y)
    }

    /// Who plays the second ball at `point` on `contactTick`: the setting
    /// setter if they can get there, otherwise the quickest teammate who can
    /// (never the libero, nor the passer, who can't touch it twice). Nil if
    /// nobody can.
    static func whoSets(_ s: GameState, _ team: TeamSide, passer: AthleteID, at point: Vec2, contactTick: Int) -> AthleteID? {
        let lineup = s.lineups[team.rawValue]
        let setter = lineup.settingSetter(isServing: s.isServing(team))
        if setter != passer, let eta = reachTicks(s, setter, point), eta <= contactTick - s.tick + reachGraceTicks {
            return setter
        }
        let others = Zone.allCases.map { lineup.occupant($0, isServing: s.isServing(team)) }
            .filter { $0 != setter && $0 != passer && $0 != lineup.libero }
        return quickest(s, others, to: point, contactTick: contactTick)
    }

    /// Of `ids`, the one who gets to `point` soonest, if they make it by
    /// `contactTick` (with `reachGraceTicks` to spare). Ties go to the first.
    static func quickest(_ s: GameState, _ ids: [AthleteID], to point: Vec2, contactTick: Int) -> AthleteID? {
        var best: (AthleteID, Int)?
        for id in ids {
            guard let eta = reachTicks(s, id, point) else { continue }
            if best == nil || eta < best!.1 { best = (id, eta) }
        }
        guard let (id, eta) = best, eta <= contactTick - s.tick + reachGraceTicks else { return nil }
        return id
    }

    /// Steps for `id` to run to `point` from how they're moving now.
    static func reachTicks(_ s: GameState, _ id: AthleteID, _ point: Vec2) -> Int? {
        guard let m = s.motion[id] else { return nil }
        let cap = Steering.cap(.run, speedTrait: s.rosters[id.team.rawValue][id].traits.speed)
        return Int((Steering.eta(m, to: point, cap: cap) * Double(Tuning.stepsPerSecond)).rounded())
    }

    /// A player this late (0.1 s) still makes the play.
    static var reachGraceTicks: Int { ticks(Tuning.reachGrace) }

    static func set(_ setter: AthleteID, _ team: TeamSide, _ s: inout GameState, _ events: inout [GameEvent]) {
        s.touchesThisSide = 2
        s.lastTouch = setter
        let from = s.ball!.position(at: s.time)
        if s.rng.chance(Tuning.setError) {
            events.append(.touched(.set, setter, quality: 0))
            shank(&s, from: from, team: team)
            return
        }
        var q = s.rng.float(in: Tuning.passQuality)
        let lineup = s.lineups[team.rawValue]
        // A teammate bailing out a late setter sets a worse ball.
        if setter != lineup.settingSetter(isServing: s.isServing(team)) { q = min(q, Tuning.backupSetQuality) }
        events.append(.touched(.set, setter, quality: q))
        let (hitter, call) = SetterAI.choose(&s, team: team, passQuality: s.notes.passQuality, setter: setter, nudge: 0)
        remember(&s, team: team, hitter: hitter)
        if call == .dump {
            attack(setter, team, &s, &events)
            return
        }
        events.append(.setCall(hitter, call))
        s.notes.play = call
        let duration = PlayBook.spec(call).setDuration * s.settings.tempo.flightScale
        let to = PlayBook.setPoint(call, team: team, net: s.settings.gameType.netHeight)
        launch(&s, Flight.make(from: from, to: to, duration: clamp(duration), startTime: s.time))
        s.pending = PendingContact(kind: .attack, team: team, athlete: hitter, tick: contactTick(s))
    }

    /// Keeps the team's last two hitters for the setter's repetition penalty.
    static func remember(_ s: inout GameState, team: TeamSide, hitter: AthleteID) {
        var recent = s.notes.recentHitters[team.rawValue]
        recent.append(hitter)
        if recent.count > 2 { recent.removeFirst(recent.count - 2) }
        s.notes.recentHitters[team.rawValue] = recent
    }

    static func attack(_ hitter: AthleteID, _ team: TeamSide, _ s: inout GameState, _ events: inout [GameEvent]) {
        s.touchesThisSide = 0
        s.lastTouch = hitter
        s.notes.play = nil
        s.notes.passQuality = 1
        let from = s.ball!.position(at: s.time)
        let q = s.rng.float(in: Tuning.passQuality)
        events.append(.touched(.attack, hitter, quality: q))
        let duration = Tuning.attackDuration * s.settings.tempo.flightScale * s.settings.gameType.paceScale
        if s.rng.chance(Tuning.attackError) {
            if s.rng.chance(Tuning.attackErrorNetShare) {
                launchNetError(&s, from: from, team: team, duration: duration, winner: team.other, reason: .attackError)
            } else {
                launchCrossing(&s, from: from, to: longSpot(&s, attacking: team), duration: duration)
                s.pending = landing(&s, winner: team.other, reason: .attackError)
            }
            return
        }
        let spot = courtSpot(&s, of: team.other, depth: 0.8...8.7)
        if s.rng.chance(Tuning.digSuccess) {
            incoming(.dig, to: team.other, spot: spot, from: from, duration: duration, dropReason: .kill, &s, &events)
        } else {
            launchCrossing(&s, from: from, to: spot.atHeight(0), duration: duration)
            s.pending = landing(&s, winner: team, reason: .kill)
        }
    }

    // MARK: Rally end

    static func endRally(winner: TeamSide, reason: PointReason, _ s: inout GameState, _ events: inout [GameEvent]) {
        s.ball = nil
        s.pending = nil
        s.touchesThisSide = 0
        s.lastTouch = nil
        s.rallyCount += 1
        events.append(.point(winner, reason))
        let result = awardRally(to: winner, score: &s.score, lineups: &s.lineups, settings: s.settings)
        if result.sideOut {
            events.append(.sideOut(winner, rotation: s.lineups[winner.rawValue].rotation))
        }
        events += s.refreshPositions()
        if result.matchWon {
            s.phase = .matchOver
            events.append(.matchWon(winner))
        } else {
            s.phase = .deadBall(untilTick: s.tick + ticks(Tuning.deadBall))
        }
    }

    // MARK: Flights

    static func clamp(_ duration: Double) -> Double { max(duration, Tuning.dt) }

    static func launch(_ s: inout GameState, _ f: Flight, netError: Bool = false) {
        s.ball = f
        s.lastFlightWasNetError = netError
    }

    /// A serve or attack that must clear the net with `netClearanceMargin`.
    static func launchCrossing(_ s: inout GameState, from: Vec3, to: Vec3, duration: Double) {
        let clearance = s.settings.gameType.netHeight + Tuning.netClearanceMargin
        launch(&s, Flight.makeClearing(from: from, to: to, duration: clamp(duration), startTime: s.time, netClearance: clearance))
    }

    /// Into the net on the hitter's own side; the other team wins the point.
    static func launchNetError(_ s: inout GameState, from: Vec3, team: TeamSide, duration: Double,
                               winner: TeamSide, reason: PointReason) {
        let to = Vec3(x: 0.05 * -team.dir, y: 1.2, z: from.z)
        launch(&s, Flight.make(from: from, to: to, duration: clamp(duration), startTime: s.time), netError: true)
        s.pending = landing(&s, winner: winner, reason: reason)
    }

    /// A shanked pass or bad set: the ball falls off the court on the
    /// handling team's side, and the other team wins the point.
    static func shank(_ s: inout GameState, from: Vec3, team: TeamSide) {
        let to = Vec3(x: -team.dir * s.rng.float(in: 3...9), y: 0, z: (s.rng.chance(0.5) ? 1 : -1) * s.rng.float(in: 4.8...6.5))
        launch(&s, Flight.make(from: from, to: to, duration: clamp(Tuning.errorDuration * s.settings.tempo.flightScale), startTime: s.time))
        s.pending = landing(&s, winner: team.other, reason: .handlingError)
    }

    // MARK: Helpers

    /// The first step at or after the current flight's end.
    static func contactTick(_ s: GameState) -> Int {
        contactTick(s, s.ball!)
    }

    static func contactTick(_ s: GameState, _ f: Flight) -> Int {
        let end = f.endTime * Double(Tuning.stepsPerSecond)
        return max(s.tick + 1, Int((end - 1e-9).rounded(.up)))
    }

    static func landing(_ s: inout GameState, winner: TeamSide, reason: PointReason) -> PendingContact {
        PendingContact(kind: nil, team: winner, athlete: nil, tick: contactTick(s), reason: reason)
    }

    /// A random spot in `team`'s court, `depth` metres from the net, |z| ≤ 4.2.
    static func courtSpot(_ s: inout GameState, of team: TeamSide, depth: ClosedRange<Float>) -> Vec2 {
        Vec2(x: -team.dir * s.rng.float(in: depth), z: s.rng.float(in: -4.2...4.2))
    }

    /// Beyond the end line of the court `attacking` hits into.
    static func longSpot(_ s: inout GameState, attacking: TeamSide) -> Vec3 {
        Vec3(x: attacking.dir * s.rng.float(in: 9.3...10.5), y: 0, z: s.rng.float(in: -4.2...4.2))
    }
}
