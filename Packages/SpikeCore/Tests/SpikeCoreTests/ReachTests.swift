import Testing
@testable import SpikeCore

/// Ticks `advance` takes to bring `m` within `arriveRadius` of its goal.
private func ticksToArrive(_ m: Motion, speedTrait: Float) -> Int {
    var m = m
    for t in 1...600 {
        Steering.advance(&m, team: .home, speedTrait: speedTrait, dt: Tuning.dt)
        if (m.pos - m.goal).length <= Tuning.arriveRadius { return t }
    }
    return 600
}

@Test func etaMatchesSteering() {
    var rng = SeededRNG(seed: 99)
    var worst = 0.0
    for i in 0..<400 {
        let start = Vec2(x: -rng.float(in: 0.5...8.5), z: rng.float(in: -4.4...4.4))
        let goal = Vec2(x: -rng.float(in: 0.5...8.5), z: rng.float(in: -4.4...4.4))
        // Half start still, half already moving in some direction.
        let vel = i % 2 == 0 ? Vec2.zero : Vec2(x: rng.float(in: -4...4), z: rng.float(in: -4...4))
        let gait: Gait = [.run, .shuffle, .approach, .backpedal][i % 4]
        let trait = rng.unit()
        var m = Motion(pos: start, vel: vel, goal: goal, gait: gait)
        let cap = Steering.cap(gait, speedTrait: trait)
        if m.vel.length > cap { m.vel = m.vel * (cap / m.vel.length) }
        let predicted = Steering.eta(m, to: goal, cap: cap)
        let actual = Double(ticksToArrive(m, speedTrait: trait)) * Tuning.dt
        worst = max(worst, abs(predicted - actual))
        #expect(abs(predicted - actual) <= 0.1, "case \(i): eta \(predicted) s, took \(actual) s")
    }
    print("eta worst error: \(worst) s")
}

/// A state with the rally on and the serve in the air.
private func midRally() -> GameState {
    var s = GameState(settings: MatchSettings())
    while !step(&s, inputs: []).contains(where: { if case .served = $0 { true } else { false } }) {}
    return s
}

@Test(arguments: [TouchKind.receive, .dig])
func unreachableBallDrops(kind: TouchKind) {
    var s = midRally()
    let defending = TeamSide.away
    let attacking = defending.other
    // Everyone on the defending side huddles in the far corner.
    let lineup = s.lineups[defending.rawValue]
    for z in Zone.allCases {
        let id = lineup.occupant(z, isServing: s.isServing(defending))
        s.motion[id] = Motion(pos: LocalFrame.toWorld(LocalSpot(d: 8.5, l: 4.2), team: defending))
    }
    // 8 m and more from all of them, with 0.3 s to get there.
    let spot = LocalFrame.toWorld(LocalSpot(d: 1.0, l: -3.5), team: defending)
    let from = LocalFrame.toWorld(LocalSpot(d: 1.0, l: 0), team: attacking).atHeight(3.2)
    var events: [GameEvent] = []
    let before = s.score.points(attacking)
    let reason: PointReason = kind == .receive ? .ace : .kill
    PlaceholderRally.incoming(kind, to: defending, spot: spot, from: from, duration: 0.3, dropReason: reason, &s, &events)
    #expect(events.contains(.outOfReach(kind, team: defending)))
    #expect(s.pending?.kind == nil && s.pending?.team == attacking && s.pending?.reason == reason)
    for _ in 0..<120 { events += step(&s, inputs: []) }
    #expect(s.score.points(attacking) == before + 1)
    #expect(events.contains(.point(attacking, reason)))
}

@Test func reachableBallIsPlayedByTheQuickest() {
    var s = midRally()
    let defending = TeamSide.away
    let lineup = s.lineups[defending.rawValue]
    let ids = Zone.allCases.map { lineup.occupant($0, isServing: s.isServing(defending)) }
    let setter = lineup.settingSetter(isServing: s.isServing(defending))
    // One defender stands 1.5 m from the spot, the rest far away.
    let near = ids.first { $0 != setter && $0 != lineup.libero }!
    for id in ids { s.motion[id] = Motion(pos: LocalFrame.toWorld(LocalSpot(d: 8.5, l: 4.2), team: defending)) }
    s.motion[near] = Motion(pos: LocalFrame.toWorld(LocalSpot(d: 5.0, l: -1.5), team: defending))
    let spot = LocalFrame.toWorld(LocalSpot(d: 5.0, l: -3.0), team: defending)
    let from = LocalFrame.toWorld(LocalSpot(d: 1.0, l: 0), team: defending.other).atHeight(3.2)
    var events: [GameEvent] = []
    PlaceholderRally.incoming(.dig, to: defending, spot: spot, from: from, duration: 0.6, dropReason: .kill, &s, &events)
    #expect(events.isEmpty)
    #expect(s.pending?.kind == .dig && s.pending?.athlete == near)
}

@Test func liberoDoesNotChaseBallsInFrontOfTheLine() {
    var s = midRally()
    let defending = TeamSide.away
    let lineup = s.lineups[defending.rawValue]
    guard s.motion[lineup.libero] != nil else { Issue.record("libero off court"); return }
    let ids = Zone.allCases.map { lineup.occupant($0, isServing: s.isServing(defending)) }
    for id in ids { s.motion[id] = Motion(pos: LocalFrame.toWorld(LocalSpot(d: 8.5, l: 4.2), team: defending)) }
    // Only the libero is near a short ball, so nobody plays it.
    s.motion[lineup.libero] = Motion(pos: LocalFrame.toWorld(LocalSpot(d: 3.2, l: -2.0), team: defending))
    let spot = LocalFrame.toWorld(LocalSpot(d: 1.5, l: -2.0), team: defending)
    let from = LocalFrame.toWorld(LocalSpot(d: 1.0, l: 0), team: defending.other).atHeight(3.2)
    var events: [GameEvent] = []
    PlaceholderRally.incoming(.dig, to: defending, spot: spot, from: from, duration: 0.6, dropReason: .kill, &s, &events)
    #expect(events.contains(.outOfReach(.dig, team: defending)))
}

@Test func badPassesScatter() {
    // Passes land around the target, some of them metres away, and setters
    // still get to them (or the engine says nobody could).
    var settings = MatchSettings()
    settings.seed = 5
    var s = GameState(settings: settings)
    let target = Court.setterTarget(team: .home).xz
    var far = 0, passes = 0
    for _ in 0..<(60 * 60 * 30) where s.phase != .matchOver {
        let events = step(&s, inputs: [])
        if let c = s.pending, c.kind == .set, events.contains(where: { if case .touched(.receive, _, _) = $0 { true } else if case .touched(.dig, _, _) = $0 { true } else { false } }) {
            passes += 1
            let end = s.ball!.position(at: s.ball!.endTime).xz
            let mine = c.team == .home ? end : Vec2(x: -end.x, z: -end.z)
            if (mine - target).length > 1.5 { far += 1 }
        }
    }
    #expect(passes > 20)
    #expect(far > 0)
}

@Test func statsReportMovement() {
    var settings = MatchSettings()
    settings.teams = [TeamSettings(system: .sixTwo, startingRotation: 3), TeamSettings(system: .fiveOne, startingRotation: 5)]
    let stats = runMatches(settings, count: 50)
    #expect(stats.matches == 50 && stats.unfinished == 0)
    #expect(stats.invariantFailures == 0)
    #expect(stats.overlapViolations == 0)
    #expect(stats.droppedForReach > 0)          // reach matters
    #expect(stats.droppedForReach < stats.rallies)
    #expect(stats.lateSetters < stats.rallies)
    #expect(stats.aces + stats.serviceErrors + stats.kills + stats.attackErrors + stats.handlingErrors == stats.rallies)
}

@Test func etaIsZeroWhenThere() {
    let m = Motion(pos: Vec2(x: -3, z: 1))
    #expect(Steering.eta(m, to: Vec2(x: -3.05, z: 1), cap: 7) == 0)
}
