import Testing
@testable import SpikeCore

/// What the movement soak saw, gathered once and shared by the tests below.
struct MovementReport: Sendable {
    var matches = 0
    var unfinished = 0
    var serves = 0
    var overlapProblems: [String] = []
    var sets = 0
    var setterMisses: [String] = []
    /// Sets the engine gave up on because nobody could get to the pass.
    var unreachableSets = 0
    var attacks = 0
    var lateJumps: [String] = []
    var liberoTicks = 0
    var liberoProblems: [String] = []
    var invariantProblems: [String] = []
    var maxSetterMiss: Float = 0
}

private func soakSettings(_ i: Int) -> MatchSettings {
    var s = MatchSettings()
    s.seed = UInt64(1000 + i)
    s.gameType = i % 2 == 0 ? .mens : .womens
    s.tempo = Tempo.allCases[i % 3]
    let home: OffenseSystem = (i / 2) % 2 == 0 ? .fiveOne : .sixTwo
    let away: OffenseSystem = (i / 4) % 2 == 0 ? .sixTwo : .fiveOne
    s.teams = [TeamSettings(system: home, startingRotation: i % 6 + 1),
               TeamSettings(system: away, startingRotation: (i / 6) % 6 + 1)]
    s.firstServer = (i / 3) % 2 == 0 ? .home : .away
    return s
}

/// Actual positions by zone, in the team's own frame.
func formationOnCourt(_ s: GameState, _ side: TeamSide) -> [Zone: LocalSpot] {
    let lineup = s.lineups[side.rawValue]
    var out: [Zone: LocalSpot] = [:]
    for z in Zone.allCases {
        let id = lineup.occupant(z, isServing: s.isServing(side))
        out[z] = LocalFrame.toLocal(s.motion[id]!.pos, team: side)
    }
    return out
}

private func playMovementSoak() -> MovementReport {
    var r = MovementReport()
    for i in 0..<200 {
        var s = GameState(settings: soakSettings(i))
        var finished = false
        for _ in 0..<(60 * 60 * 30) {
            let pendingBefore = s.pending
            let events = step(&s, inputs: [])
            for e in events {
                switch e {
                case .served:
                    r.serves += 1
                    for side in TeamSide.allCases {
                        let v = Overlap.violations(formationOnCourt(s, side), isServing: s.isServing(side))
                        if !v.isEmpty { r.overlapProblems.append("match \(i) tick \(s.tick) \(side): \(v)") }
                    }
                case .touched(.set, let who, _):
                    r.sets += 1
                    let contact = s.ball!.position(at: s.time).xz   // the new set starts where the pass was played
                    let miss = (s.motion[who]!.pos - contact).length
                    r.maxSetterMiss = max(r.maxSetterMiss, miss)
                    if miss > 0.6 { r.setterMisses.append("match \(i) tick \(s.tick): \(miss) m") }
                case .touched(.attack, let who, _):
                    r.attacks += 1
                    if let c = pendingBefore, c.kind == .attack, c.athlete == who {
                        let peak = s.motion[who]!.jump?.peakTick
                        if peak == nil || abs(peak! - s.tick) > 3 {
                            r.lateJumps.append("match \(i) tick \(s.tick): peak \(String(describing: peak))")
                        }
                    }
                case .outOfReach(.set, _):
                    r.unreachableSets += 1
                default:
                    break
                }
            }
            for side in TeamSide.allCases {
                let lineup = s.lineups[side.rawValue]
                guard let m = s.motion[lineup.libero] else { continue }
                r.liberoTicks += 1
                let goal = LocalFrame.toLocal(m.goal, team: side)
                if goal.d < 3.0 { r.liberoProblems.append("match \(i) tick \(s.tick): libero goal d \(goal.d)") }
                if let j = m.jump, j.height > 0.3 { r.liberoProblems.append("match \(i) tick \(s.tick): libero jump \(j.height)") }
            }
            if r.invariantProblems.count < 5 {
                let p = checkInvariants(s)
                if !p.isEmpty { r.invariantProblems.append("match \(i) tick \(s.tick): \(p)") }
            }
            if s.phase == .matchOver { finished = true; break }
        }
        r.matches += 1
        if !finished { r.unfinished += 1 }
    }
    return r
}

let movementSoak = playMovementSoak()

@Test func movementSoakRuns() {
    #expect(movementSoak.matches == 200)
    #expect(movementSoak.unfinished == 0)
    #expect(movementSoak.invariantProblems.isEmpty, "\(movementSoak.invariantProblems)")
}

@Test func serveTickAlwaysLegal() {                             // Review Focus 1
    #expect(movementSoak.serves > 5000)
    #expect(movementSoak.overlapProblems.isEmpty, "\(movementSoak.overlapProblems.prefix(5))")
}

@Test func setterGetsToBadPasses() {                            // Review Focus 2
    print("sets: \(movementSoak.sets), unreachable: \(movementSoak.unreachableSets), worst miss: \(movementSoak.maxSetterMiss) m")
    #expect(movementSoak.sets > 2000)
    #expect(movementSoak.setterMisses.isEmpty, "\(movementSoak.setterMisses.prefix(5))")
}

@Test func hittersTakeOffOnTime() {
    #expect(movementSoak.attacks > 2000)
    #expect(movementSoak.lateJumps.isEmpty, "\(movementSoak.lateJumps.prefix(5))")
}

@Test func liberoNeverAtNet() {                                 // Review Focus 4
    #expect(movementSoak.liberoTicks > 100_000)
    #expect(movementSoak.liberoProblems.isEmpty, "\(movementSoak.liberoProblems.prefix(5))")
}

@Test func playersReallyMove() {
    // After the serve, the setter releases and the hitters switch: someone
    // on each team is moving within half a second.
    var s = GameState(settings: MatchSettings())
    while !step(&s, inputs: []).contains(where: { if case .served = $0 { true } else { false } }) {}
    for _ in 0..<30 { _ = step(&s, inputs: []) }
    for side in TeamSide.allCases {
        let moving = s.motion.filter { $0.key.team == side && $0.value.vel.length > 1 }
        #expect(moving.count >= 2)
    }
    // The receiving setter heads for the target.
    let receiving = s.score.serving.other
    let setter = s.lineups[receiving.rawValue].settingSetter(isServing: false)
    let target = Court.setterTarget(team: receiving).xz
    #expect((s.motion[setter]!.goal - target).length < 0.01 || s.pending?.kind != .receive)
}

@Test func liberoGoalInvariantCatchesNetGoals() {
    var s = GameState(settings: MatchSettings())
    #expect(checkInvariants(s).isEmpty)
    let side = s.score.serving.other
    let libero = s.lineups[side.rawValue].libero
    s.motion[libero]!.goal = LocalFrame.toWorld(LocalSpot(d: 1.0, l: 0), team: side)
    #expect(!checkInvariants(s).isEmpty)
}

@Test func overlapInvariantAtTheServe() {
    var s = GameState(settings: MatchSettings())
    while !step(&s, inputs: []).contains(where: { if case .served = $0 { true } else { false } }) {}
    #expect(checkInvariants(s).isEmpty)
    // Swap two receiving front-row players' spots: now illegal at the serve.
    let side = s.score.serving.other
    let lineup = s.lineups[side.rawValue]
    let a = lineup.occupant(.z4, isServing: false), b = lineup.occupant(.z2, isServing: false)
    let pa = s.motion[a]!.pos
    s.motion[a]!.pos = s.motion[b]!.pos
    s.motion[b]!.pos = pa
    #expect(checkInvariants(s).contains { $0.contains("overlap") })
}
