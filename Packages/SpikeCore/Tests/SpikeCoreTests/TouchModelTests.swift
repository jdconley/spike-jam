import Testing
@testable import SpikeCore

/// An athlete with every trait at `t` (attack and block too, even a libero's).
private func athlete(_ t: Float, position: Position = .outside, height: Float = 1.95, team: TeamSide = .home) -> Athlete {
    Athlete(id: AthleteID(team: team, index: 1), name: "Test Player", number: 7, position: position, heightM: height,
            skinTone: 0, traits: Traits(serve: t, pass: t, set: t, attack: t, block: t, defense: t, speed: t))
}

private func context(_ kind: TouchKind, _ a: Athlete, quality: Float = 0.8, power: Float = 0.5, slack: Double = 0.4,
                     blockers: Int = 0, catchUp: Float = 0, timing: Float? = nil) -> TouchContext {
    TouchContext(kind: kind, toucher: a, incomingQuality: quality, incomingPower: power, reachSlack: slack,
                 blockersAligned: blockers, catchUp: catchUp, timing: timing)
}

private func rolls(_ c: TouchContext, _ n: Int = 5000, settings: MatchSettings = MatchSettings(),
                   seed: UInt64 = 1) -> (mean: Float, errors: Float) {
    var rng = SeededRNG(seed: seed)
    var sum: Float = 0, errors = 0
    for _ in 0..<n {
        let r = TouchModel.resolve(c, rng: &rng, settings: settings)
        if r.error != nil { errors += 1 } else { sum += r.quality }
        #expect((0...1).contains(r.quality))
    }
    return (sum / Float(n - errors), Float(errors) / Float(n))
}

@Test func betterTraitBetterTouch() {
    for kind in [TouchKind.receive, .dig, .set, .attack] {
        let good = rolls(context(kind, athlete(0.9))), poor = rolls(context(kind, athlete(0.5)))
        #expect(good.mean >= poor.mean + 0.15, "\(kind): \(good.mean) vs \(poor.mean)")
        #expect(good.errors < poor.errors, "\(kind): \(good.errors) vs \(poor.errors)")
    }
}

@Test func notPerfect() {
    var settings = MatchSettings()
    settings.difficulty = .hard
    for game in GameType.allCases {
        settings.gameType = game
        let serve = rolls(context(.serve, athlete(1.0), quality: 1, power: 0, slack: 1), settings: settings)
        #expect(serve.errors >= 0.03, "\(game): \(serve.errors)")
        // Hard AI still shanks passes and hits out.
        #expect(rolls(context(.receive, athlete(1.0)), settings: settings).errors > 0.005)
        #expect(rolls(context(.attack, athlete(1.0)), settings: settings).errors > 0.01)
    }
}

@Test func errorsHaveRealTypes() {
    var rng = SeededRNG(seed: 4)
    var seen: [TouchKind: Set<TouchError>] = [:]
    for kind in [TouchKind.serve, .receive, .dig, .set, .attack, .block] {
        for _ in 0..<20_000 {
            let r = TouchModel.resolve(context(kind, athlete(0.3), quality: 0.3, power: 1, slack: 0), rng: &rng,
                                       settings: MatchSettings())
            if let e = r.error { seen[kind, default: []].insert(e) }
        }
    }
    #expect(seen[.serve] == [.net, .out])
    #expect(seen[.receive] == [.shank, .overpass])
    #expect(seen[.dig] == [.shank, .overpass])
    #expect(seen[.set] == [.doubleContact])
    #expect(seen[.attack] == [.net, .out])
    #expect(seen[.block] == [.tooled])
}

@Test func harderBallsAreHarder() {
    let a = athlete(0.7)
    let soft = rolls(context(.dig, a, quality: 0.8, power: 0.2)), hard = rolls(context(.dig, a, quality: 0.3, power: 1))
    #expect(hard.errors > soft.errors * 1.5)
    #expect(hard.mean < soft.mean)
    let early = rolls(context(.receive, a, slack: 0.5)), late = rolls(context(.receive, a, slack: -0.05))
    #expect(late.errors > early.errors)
    #expect(late.mean < early.mean)
    let open = rolls(context(.attack, a, blockers: 0)), crowded = rolls(context(.attack, a, blockers: 3))
    #expect(crowded.errors > open.errors && crowded.mean < open.mean)
    let goodSet = rolls(context(.attack, a, quality: 0.9)), badSet = rolls(context(.attack, a, quality: 0.2))
    #expect(badSet.mean < goodSet.mean && badSet.errors > goodSet.errors)
}

@Test func difficultyMovesTheAverage() {
    var easy = MatchSettings(), hard = MatchSettings()
    easy.difficulty = .easy
    hard.difficulty = .hard
    let a = athlete(0.65)
    let e = rolls(context(.receive, a), settings: easy), h = rolls(context(.receive, a), settings: hard)
    #expect(h.mean > e.mean + 0.1)
    #expect(h.errors < e.errors)
    // Easy still makes good plays.
    var rng = SeededRNG(seed: 9)
    var great = 0
    for _ in 0..<2000 where TouchModel.resolve(context(.receive, a), rng: &rng, settings: easy).quality >= PlayBook.goodPass {
        great += 1
    }
    #expect(great > 100)
}

@Test func tipsAreSometimes() {
    for game in GameType.allCases {
        var settings = MatchSettings()
        settings.gameType = game
        var rng = SeededRNG(seed: 2)
        var tips = 0, attacks = 0
        for _ in 0..<5000 {
            let r = TouchModel.resolve(context(.attack, athlete(0.7), quality: 0.7, blockers: 1), rng: &rng, settings: settings)
            if r.error == nil { attacks += 1; if r.tip { tips += 1 } }
        }
        let share = Float(tips) / Float(attacks)
        #expect((0.05...0.13).contains(share), "\(game): \(share)")
    }
}

@Test func blockReachUsesHeight() {
    let tall = athlete(0.7, position: .middle, height: 2.05), short = athlete(0.7, position: .outside, height: 1.80)
    #expect(Rally.blockReach(tall, game: .mens) > Rally.blockReach(short, game: .mens) + 0.3)
    #expect(abs(Rally.blockReach(tall, game: .mens) - (2.05 * 1.33 + 0.75 * Rally.blockJump(tall, game: .mens))) < 1e-5)
    // Real reaches: a tall men's middle about 3.3–3.5 m, a women's about 3.0–3.2 m.
    #expect((3.25...3.55).contains(Rally.blockReach(tall, game: .mens)))
    #expect((2.95...3.25).contains(Rally.blockReach(athlete(0.7, position: .middle, height: 1.90), game: .womens)))
    // Against the same low attack, the taller blocker stuffs more often.
    func stuffs(_ blocker: Athlete) -> Int {
        var rng = SeededRNG(seed: 8)
        var n = 0
        for _ in 0..<4000 {
            if Rally.rollBlock(blocker, ballHeight: 2.85, lateral: 0.2, jump: 1, attackQuality: 0.6, attackPower: 0.8,
                               tip: false, rng: &rng, settings: MatchSettings()) == .stuff { n += 1 }
        }
        return n
    }
    print("stuffs: 2.05 m \(stuffs(tall)), 1.80 m \(stuffs(short)) of 4000")
    #expect(Double(stuffs(tall)) > 1.5 * Double(stuffs(short)))
    #expect(stuffs(tall) > stuffs(short) + 30)
}

@Test func toolGoesToAttacker() {                                // Review Focus 5
    var s = attackInTheAir()
    let attacker = s.pending!.team
    let hitter = s.pending!.athlete!
    let defending = attacker.other
    // Run to the attack, then force a tool off the block on the crossing.
    var events: [GameEvent] = []
    while s.pending?.kind == .attack { events += step(&s, inputs: []) }
    let blocker = s.lineups[defending.rawValue].occupant(.z3, isServing: s.isServing(defending))
    let before = s.score.points(attacker)
    events = []
    Rally.applyBlock(.tool, blocker: blocker, hitter: hitter, &s, &events)
    #expect(events.contains(.erred(.block, blocker, .tooled)))
    // The ball goes off the block and out of bounds on the blocking side.
    let end = s.ball!.position(at: s.ball!.endTime)
    let local = LocalFrame.toLocal(end.xz, team: defending)
    #expect(end.y == 0 && local.d > 0 && (local.d > 9 || abs(local.l) > 4.5), "\(local)")
    for _ in 0..<200 where s.pending != nil { events += step(&s, inputs: []) }
    #expect(events.contains(.point(attacker, .kill)))
    #expect(s.score.points(attacker) == before + 1)
}

@Test func stuffGoesToBlocker() {
    var s = attackInTheAir()
    let attacker = s.pending!.team, hitter = s.pending!.athlete!
    while s.pending?.kind == .attack { _ = step(&s, inputs: []) }
    let blocker = s.lineups[attacker.other.rawValue].occupant(.z3, isServing: s.isServing(attacker.other))
    var events: [GameEvent] = []
    Rally.applyBlock(.stuff, blocker: blocker, hitter: hitter, &s, &events)
    #expect(events.contains(.erred(.attack, hitter, .blockedStuff)))
    let end = s.ball!.position(at: s.ball!.endTime)
    #expect(LocalFrame.toLocal(end.xz, team: attacker).d > 0)   // down on the hitter's side
    for _ in 0..<200 where s.pending != nil { events += step(&s, inputs: []) }
    #expect(events.contains(.point(attacker.other, .block)))
}

@Test func softBlockIsDug() {
    var s = attackInTheAir()
    let attacker = s.pending!.team, hitter = s.pending!.athlete!
    while s.pending?.kind == .attack { _ = step(&s, inputs: []) }
    let blocker = s.lineups[attacker.other.rawValue].occupant(.z3, isServing: s.isServing(attacker.other))
    var events: [GameEvent] = []
    Rally.applyBlock(.soft, blocker: blocker, hitter: hitter, &s, &events)
    // It comes back up on the blocking side for a dig, or drops there.
    #expect(s.pending?.kind == .dig || s.pending?.kind == nil)
    if s.pending?.kind == .dig { #expect(s.pending?.team == attacker.other) }
    #expect(LocalFrame.toLocal(s.ball!.position(at: s.ball!.endTime).xz, team: attacker.other).d > 0)
}

/// A match stepped until a set is in the air to a front-row hitter.
private func attackInTheAir(seed: UInt64 = 21) -> GameState {
    var settings = MatchSettings()
    settings.seed = seed
    var s = GameState(settings: settings)
    for _ in 0..<(60 * 60 * 30) {
        _ = step(&s, inputs: [])
        if let c = s.pending, c.kind == .attack, let id = c.athlete,
           s.lineups[c.team.rawValue].zone(of: id, isServing: s.isServing(c.team))?.isFrontRow == true { return s }
    }
    Issue.record("no attack")
    return s
}

@Test func defenseReadsBadPassesBetter() {
    // Off a bad pass the set is predictable, so the read is right more often.
    // Averaged over passes in twelve matches (different rosters and
    // rotations).
    func accuracy(_ pass: Float) -> Float {
        var right = 0, reads = 0
        for seed in UInt64(1)...12 {
            var settings = MatchSettings()
            settings.seed = seed
            settings.teams = [TeamSettings(startingRotation: Int(seed % 6) + 1), TeamSettings(startingRotation: Int(seed / 2 % 6) + 1)]
            var s = GameState(settings: settings)
            while !(step(&s, inputs: []).contains { if case .touched(.receive, _, _) = $0 { true } else { false } }
                    && s.pending?.kind == .set) {}
            let team = s.pending!.team, setter = s.pending!.athlete!
            s.notes.passQuality = pass
            for _ in 0..<500 {
                let read = DefenseAI.read(&s, defending: team.other)
                var probe = s
                let (hitter, _) = SetterAI.choose(&probe, team: team, passQuality: pass, setter: setter, nudge: 0)
                s.rng = probe.rng
                reads += 1
                if read == hitter { right += 1 }
            }
        }
        return Float(right) / Float(reads)
    }
    let good = accuracy(0.95), bad = accuracy(0.3)
    print("read accuracy: good pass \(good), bad pass \(bad)")
    #expect(bad > good + 0.1)
    #expect(good > 0.15)
    #expect(bad < 0.97)                                       // still not a sure thing
}

@Test func readShiftsTheDefense() {
    // The defense leans 0.5–1.0 m toward the hitter it reads.
    let p = BaseSpots.perimeter(against: .left)
    for defense: Float in [0, 0.5, 1] {
        let shifted = DefenseAI.shift(p, toward: 4.0, defense: defense)
        for role in PerimeterRole.allCases where !role.isFront {
            let moved = shifted[role].distance(to: p[role])
            #expect(moved >= 0.5 - 1e-4 && moved <= 1.0 + 1e-4 || abs(shifted[role].l) >= 4.2, "\(role) \(moved)")
            #expect(shifted[role].l >= p[role].l)
        }
    }
}

// MARK: - Rates over many matches

/// 500 bot-vs-bot matches per game type at medium, shared by the rate and
/// habit tests.
let bandRuns: [GameType: MatchStats] = {
    var out: [GameType: MatchStats] = [:]
    for game in GameType.allCases {
        var settings = MatchSettings()
        settings.gameType = game
        settings.seed = 2026
        out[game] = runParallel(settings, count: 500)
    }
    return out
}()

/// The plan's target bands (Claude's reading of typical high-level rates).
struct RateBand: Sendable {
    var name: String
    var rate: @Sendable (MatchStats) -> Double
    var mens: ClosedRange<Double>
    var womens: ClosedRange<Double>
}

let rateBandTable: [RateBand] = [
    RateBand(name: "serve error", rate: { $0.serveErrorRate }, mens: 0.12...0.22, womens: 0.07...0.15),
    RateBand(name: "ace", rate: { $0.aceRate }, mens: 0.04...0.10, womens: 0.04...0.10),
    RateBand(name: "attack kill", rate: { $0.killRate }, mens: 0.40...0.55, womens: 0.30...0.45),
    RateBand(name: "attack error", rate: { $0.attackErrorRate }, mens: 0.08...0.18, womens: 0.08...0.18),
    RateBand(name: "side-out", rate: { $0.sideOutRate }, mens: 0.60...0.72, womens: 0.55...0.68),
]

@Test(arguments: GameType.allCases)
func rateBands(game: GameType) {
    let stats = bandRuns[game]!
    #expect(stats.matches == 500 && stats.unfinished == 0)
    #expect(stats.invariantFailures == 0 && stats.overlapViolations == 0)
    #expect(stats.aces + stats.serviceErrors + stats.kills + stats.attackErrors + stats.handlingErrors + stats.blocks == stats.rallies)
    for band in rateBandTable {
        let r = band.rate(stats), want = game == .mens ? band.mens : band.womens
        print("\(game) \(band.name): \((r * 1000).rounded() / 10)% (band \(want.lowerBound * 100)–\(want.upperBound * 100)%)")
        #expect(want.contains(r), "\(game) \(band.name) \(r) outside \(want)")
    }
    // Hitters tip 6–10% of the time (dumps included), more in the women's game.
    print("\(game) tips: \((stats.tipRate * 1000).rounded() / 10)%")
    #expect((0.05...0.11).contains(stats.tipRate))
    // Blocks happen, and every error type shows up.
    #expect(stats.blocks > 0 && stats.blockTouches > stats.blocks)
    let expected: [(TouchKind, [TouchError])] = [
        (.serve, [.net, .out]), (.receive, [.shank, .overpass]), (.dig, [.shank, .overpass]),
        (.set, [.doubleContact]), (.attack, [.net, .out, .blockedStuff]), (.block, [.tooled]),
    ]
    for (kind, kinds) in expected {
        for e in kinds { #expect((stats.errors[kind]?[e] ?? 0) > 0, "\(game): no \(kind) \(e)") }
    }
}

@Test func womensDigMore() {
    // Longer rallies and more digs in the women's game (spec §4.7).
    let men = bandRuns[.mens]!, women = bandRuns[.womens]!
    #expect(women.avgTouchesPerRally > men.avgTouchesPerRally)
    #expect(Double(women.digs) / Double(women.rallies) > Double(men.digs) / Double(men.rallies))
    #expect(women.tipRate > men.tipRate)
}

@Test func difficultyOrders() {
    var settings = MatchSettings()
    settings.seed = 4000
    settings.teams = [TeamSettings(difficulty: .easy), TeamSettings(difficulty: .hard)]
    let stats = runParallel(settings, count: 200)
    print("easy home wins \(stats.homeWins) of \(stats.matches)")
    #expect(stats.matches - stats.homeWins >= 140)
}
