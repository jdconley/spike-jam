/// A stand-in rally engine with fixed odds from `Tuning`. Players stand on
/// their zone spots and every touch is a dice roll. Plans 2–4 replace it with
/// movement, AI traits and human input on the same state and `step`.
enum PlaceholderRally {
    // MARK: Serve

    static func serve(_ s: inout GameState, _ events: inout [GameEvent]) {
        let team = s.score.serving
        let lineup = s.lineups[team.rawValue]
        let server = lineup.server()
        let spotZ = Court.zoneSpot(.z1, team: team).z
        let from = Vec3(x: -9.9 * team.dir, y: 2.6, z: spotZ)
        s.phase = .rally
        s.touchesThisSide = 0
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
            launchCrossing(&s, from: from, to: spot.atHeight(Tuning.passContactHeight), duration: duration)
            s.pending = PendingContact(kind: .receive, team: team.other, athlete: nearestDefender(s, team.other, to: spot),
                                       tick: contactTick(s))
        }
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
        let from = s.ball!.position(at: s.time)
        if s.rng.chance(Tuning.passError) {
            events.append(.touched(kind, athlete, quality: 0))
            shank(&s, from: from, team: team)
            return
        }
        let q = s.rng.float(in: Tuning.passQuality)
        events.append(.touched(kind, athlete, quality: q))
        let duration = (Tuning.passDurationBase + Tuning.passDurationSpread * Double(1 - q)) * s.settings.tempo.flightScale
        launch(&s, Flight.make(from: from, to: Court.setterTarget(team: team), duration: clamp(duration), startTime: s.time))
        let setter = s.lineups[team.rawValue].settingSetter(isServing: s.isServing(team))
        s.pending = PendingContact(kind: .set, team: team, athlete: setter, tick: contactTick(s))
    }

    static func set(_ setter: AthleteID, _ team: TeamSide, _ s: inout GameState, _ events: inout [GameEvent]) {
        s.touchesThisSide = 2
        let from = s.ball!.position(at: s.time)
        if s.rng.chance(Tuning.setError) {
            events.append(.touched(.set, setter, quality: 0))
            shank(&s, from: from, team: team)
            return
        }
        let q = s.rng.float(in: Tuning.passQuality)
        events.append(.touched(.set, setter, quality: q))
        let lineup = s.lineups[team.rawValue]
        let hitters = lineup.attackers(isServing: s.isServing(team))
        let hitter = hitters[s.rng.int(in: 0..<hitters.count)]
        let zone = lineup.zone(of: hitter)!
        let duration = Tuning.setDuration(zone) * s.settings.tempo.flightScale
        launch(&s, Flight.make(from: from, to: Court.attackPoint(zone, team: team), duration: clamp(duration), startTime: s.time))
        s.pending = PendingContact(kind: .attack, team: team, athlete: hitter, tick: contactTick(s))
    }

    static func attack(_ hitter: AthleteID, _ team: TeamSide, _ s: inout GameState, _ events: inout [GameEvent]) {
        s.touchesThisSide = 0
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
            launchCrossing(&s, from: from, to: spot.atHeight(Tuning.passContactHeight), duration: duration)
            s.pending = PendingContact(kind: .dig, team: team.other, athlete: nearestDefender(s, team.other, to: spot),
                                       tick: contactTick(s))
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
        let end = s.ball!.endTime * Double(Tuning.stepsPerSecond)
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

    /// The on-court player of `team` nearest `spot`, never the setting setter.
    static func nearestDefender(_ s: GameState, _ team: TeamSide, to spot: Vec2) -> AthleteID {
        let setter = s.lineups[team.rawValue].settingSetter(isServing: s.isServing(team))
        let candidates = s.lineups[team.rawValue].onCourt(isServing: s.isServing(team))
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
            .filter { $0 != setter }
        return candidates.min { (s.positions[$0]! - spot).length < (s.positions[$1]! - spot).length }!
    }
}
