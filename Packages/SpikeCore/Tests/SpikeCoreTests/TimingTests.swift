import Testing
@testable import SpikeCore

let h1 = HumanID(raw: 1)
let h2 = HumanID(raw: 2)

/// Steps until `stop` holds after a step (or `limit` steps), giving each step
/// the inputs `inputs` returns for the state before it.
@discardableResult
func play(_ s: inout GameState, limit: Int = 60 * 60 * 30, inputs: (GameState) -> [PlayerInput] = { _ in [] },
          until stop: (GameState, [GameEvent]) -> Bool) -> [GameEvent] {
    var all: [GameEvent] = []
    for _ in 0..<limit {
        let events = step(&s, inputs: inputs(s))
        all += events
        if stop(s, events) || s.phase == .matchOver { break }
    }
    return all
}

/// The windows in `events`.
func windows(_ events: [GameEvent]) -> [(id: ContactID, kind: TouchKind, owner: HumanID, tick: Int)] {
    events.compactMap { if case .window(let id, let k, let o, let t) = $0 { (id, k, o, t) } else { nil } }
}

/// A match with one "ball" human on home; away serves first.
func homeHuman(seed: UInt64 = 1, pick: Pick = .ball) -> GameState {
    var settings = MatchSettings()
    settings.seed = seed
    settings.firstServer = .away
    return GameState(settings: settings, humans: [HumanSlot(id: h1, team: .home, pick: pick)])
}

@Test func gradeBoundaries() {
    let contact = 600.0 * Tuning.dt
    func at(_ ms: Double) -> Grade {
        // Stamped the way the app stamps them: a tick and an offset into it.
        let t = contact + ms / 1000
        let tick = Int((t / Tuning.dt).rounded(.down))
        let input = PlayerInput(human: h1, tick: tick, offset: Float(t - Double(tick) * Tuning.dt), action: .tap(contact: .none))
        return TimingJudge.grade(inputTime: input.time, contactTime: contact)
    }
    #expect(at(0) == .perfect)
    for sign in [-1.0, 1.0] {
        let early = sign < 0
        #expect(at(sign * 60) == .perfect)
        #expect(at(sign * 61) == .good)
        #expect(at(sign * 130) == .good)
        #expect(at(sign * 131) == (early ? .early : .late))
        #expect(at(sign * 250) == (early ? .early : .late))
        #expect(at(sign * 251) == (early ? .wayEarly : .wayLate))
    }
    #expect(TimingJudge.grade(inputTime: nil, contactTime: contact) == .miss)
    #expect(Grade.perfect.quality == 1 && Grade.good.quality == 0.75 && Grade.early.quality == 0.45)
    #expect(Grade.wayLate.quality == 0.2 && Grade.miss.quality == 0.2)
}

@Test func missErrs() {
    var s = homeHuman()
    var found = false
    for _ in 0..<8 where !found {
        let events = play(&s) { _, e in e.contains { if case .point = $0 { true } else { false } } }
        guard let w = windows(events).first(where: { $0.kind == .receive }) else { continue }
        found = true
        #expect(events.contains(.judged(w.id, .miss)))
        let receiver = events.compactMap { if case .erred(.receive, let a, let e) = $0 { (a, e) } else { nil } }.first
        #expect(receiver?.1 == .shank && receiver?.0.team == .home)
        #expect(events.last == .point(.away, .ace) || events.contains(.point(.away, .ace)))
    }
    #expect(found)
}

@Test func inputKeyedByContact() {                                 // Review Focus 1
    // Home passes the serve on time; then, with the set's window open, a
    // stale tap for the pass arrives. It counts for nothing.
    var s = homeHuman(seed: 3)
    var receive: (id: ContactID, tick: Int)?
    var setWindow: ContactID?
    play(&s, inputs: { s in
        guard let r = receive, s.tick == r.tick else { return [] }
        return [PlayerInput(human: h1, tick: s.tick, offset: 0.004, action: .tap(contact: r.id))]
    }, until: { _, events in
        for w in windows(events) {
            if w.kind == .receive { receive = (w.id, w.tick) }
            if w.kind == .set { setWindow = w.id }
        }
        return setWindow != nil
    })
    guard let r = receive, let set = setWindow else { Issue.record("no pass and set"); return }
    #expect(set > r.id)
    #expect(s.pending?.id == set)
    var stale = s, clean = s
    let late = PlayerInput(human: h1, tick: s.tick, offset: 0, action: .tap(contact: r.id))
    let a = step(&stale, inputs: [late]), b = step(&clean, inputs: [])
    #expect(a == b && stale == clean)
    #expect(stale.inputBuffer.isEmpty)
    // The set still waits for its own input and is a miss without one.
    let rest = play(&stale) { s, _ in s.pending?.id != set }
    #expect(rest.contains(.judged(set, .miss)))
}

/// A human's attack context for an athlete of `team`.
private func attackContext(_ s: GameState, team: TeamSide = .home) -> TouchContext {
    let hitter = s.rosters[team.rawValue].ids(.outside)[0]
    return Rally.context(.attack, hitter, s, timing: 1, quality: 0.8, power: 0, slack: 1, blockers: 1)
}

@Test func tipNearNet() {
    let s = homeHuman()
    var rng = SeededRNG(seed: 5)
    var tips = 0, swings = 0
    for i in 0..<100 {
        let l = Float(i % 9) - 4
        let near = LocalFrame.toWorld(LocalSpot(d: 1.4, l: l), team: .away)
        let deep = LocalFrame.toWorld(LocalSpot(d: 6.5, l: l), team: .away)
        let t = HumanTouch.result(HumanPlay(grade: .perfect, aim: near), attackContext(s), rng: &rng, settings: s.settings)
        let d = HumanTouch.result(HumanPlay(grade: .perfect, aim: deep), attackContext(s), rng: &rng, settings: s.settings)
        #expect(t.tip && !d.tip)
        #expect(abs(near.x) < 2.4)
        if t.error == nil { tips += 1; #expect(t.power == Tuning.tipPower) }
        if d.error == nil { swings += 1; #expect(d.power > Tuning.tipPower) }
        // The ball goes about where it was aimed.
        if let target = d.target { #expect((target.xz - deep).length < 1.5) }
    }
    #expect(tips > 80 && swings > 80)
}

@Test func floatOnQuickTap() {
    let s = homeHuman()
    let server = s.lineups[TeamSide.home.rawValue].server()
    let c = PendingContact(kind: .serve, team: .home, athlete: server, tick: 1000, id: ContactID(raw: 9), owner: h1)
    func input(_ tick: Int, _ a: InputAction) -> PlayerInput { PlayerInput(human: h1, tick: tick, offset: 0.002, action: a) }
    // A press and a release 0.1 s later: a float.
    let quick = HumanTouch.play(for: c, inputs: [input(700, .press(contact: c.id)), input(706, .release(contact: c.id, aim: nil))])
    #expect(quick.float && quick.timing >= 0.45)
    // Held to the top of the toss: a timed serve.
    let apexTick = 700 + Int(Tuning.tossSeconds * 60)
    let timed = HumanTouch.play(for: c, inputs: [input(700, .press(contact: c.id)), input(apexTick, .release(contact: c.id, aim: nil))])
    #expect(!timed.float && timed.grade == .perfect)
    #expect(HumanTouch.play(for: c, inputs: [input(700, .tap(contact: c.id))]).float)
    let context = Rally.context(.serve, server, s, timing: 0, quality: 1, power: 0, slack: 1, blockers: 0)
    var rng = SeededRNG(seed: 8)
    var floatPower: Float = 0, timedPower: Float = 0
    for _ in 0..<200 {
        let f = HumanTouch.result(quick, context, rng: &rng, settings: s.settings)
        #expect(f.error == nil && f.quality >= 0.45 && f.target != nil)
        floatPower += f.power
        timedPower += HumanTouch.result(timed, context, rng: &rng, settings: s.settings).power
    }
    #expect(floatPower < timedPower)
}

@Test func catchUpIgnoresHumans() {
    var settings = MatchSettings()
    settings.humanSides = [.home]
    var behind = GameState(settings: settings, humans: [HumanSlot(id: h1, team: .home)])
    behind.score.points = [2, 9]
    var ahead = behind
    ahead.score.points = [9, 2]
    #expect(CatchUp.level(behind)[.home] == 1 && CatchUp.level(ahead)[.home] == -1)
    let roster = behind.rosters[TeamSide.home.rawValue]
    for kind in [TouchKind.serve, .receive, .set, .attack, .dig] {
        let athlete = kind == .set ? roster.ids(.setter)[0] : roster.ids(.outside)[0]
        let id = ContactID(raw: 40)
        let c = PendingContact(kind: kind, team: .home, athlete: athlete, tick: 500, quality: 0.6, power: 0.6, slack: 0.2,
                               id: id, owner: h1)
        for tap in [480, 497, 500, 503] {
            let action: InputAction = switch kind {
            case .serve: .tap(contact: id)
            case .attack: .release(contact: id, aim: Vec2(x: 6, z: 1))
            case .set: .setTo(contact: id, hitter: roster.ids(.outside)[1])
            default: .tap(contact: id)
            }
            let inputs = [PlayerInput(human: h1, tick: tap, action: action)]
            var a = behind, b = ahead
            for _ in 0..<20 {
                #expect(HumanTouch.resolve(c, inputs: inputs, &a) == HumanTouch.resolve(c, inputs: inputs, &b))
            }
        }
    }
}

@Test func serveTossAndRelease() {
    // Home serves: the window opens as the line-ups are ready, the press
    // tosses (the window comes again with the toss's top), and the release
    // at the top strikes a perfect serve.
    var settings = MatchSettings()
    settings.firstServer = .home
    var s = GameState(settings: settings, humans: [HumanSlot(id: h1, team: .home)])
    var serve: (id: ContactID, tick: Int)?
    var pressed = false
    let events = play(&s, inputs: { s in
        guard let w = serve else { return [] }
        if !pressed { return [PlayerInput(human: h1, tick: s.tick, action: .press(contact: w.id))] }
        guard s.tick == w.tick else { return [] }
        return [PlayerInput(human: h1, tick: s.tick, action: .release(contact: w.id, aim: Vec2(x: 6, z: 2)))]
    }, until: { _, events in
        for w in windows(events) where w.kind == .serve {
            if serve != nil { pressed = true }
            serve = (w.id, w.tick)
        }
        return events.contains { if case .served = $0 { true } else { false } }
    })
    let ws = windows(events).filter { $0.kind == .serve }
    #expect(ws.count == 2 && ws[0].id == ws[1].id)
    guard ws.count == 2 else { return }
    #expect(ws[1].tick - ws[0].tick < 60)
    #expect(events.contains(.judged(ws[0].id, .perfect)))
    #expect(s.serveTick == ws[1].tick + 1)
}

@Test func serveClockRunsOut() {
    var settings = MatchSettings()
    settings.firstServer = .home
    var s = GameState(settings: settings, humans: [HumanSlot(id: h1, team: .home)])
    let events = play(&s) { _, e in e.contains { if case .point = $0 { true } else { false } } }
    guard let w = windows(events).first else { Issue.record("no window"); return }
    #expect(w.kind == .serve)
    #expect(events.contains(.judged(w.id, .miss)))
    #expect(events.contains(.point(.away, .serviceError)))
}
