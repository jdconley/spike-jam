import Testing
@testable import SpikeCore

/// Who `h` should control when they picked `a`: `a` on court, else the libero
/// standing in for them.
private func expectFollows(_ h: HumanID, picked a: AthleteID, _ s: GameState, _ note: String) {
    let lineup = s.lineups[a.team.rawValue]
    let now = controlled(by: h, s)
    #expect(now != nil && s.motion[now!] != nil, "\(note): controls someone off court")
    if s.motion[a] != nil {
        #expect(now == a, "\(note)")
    } else {
        #expect(now == lineup.libero && s.liberoReplacing(a.team, in: s.motion) == a, "\(note)")
    }
}

@Test func pickFollowsPersonThroughLibero() {                       // Review Focus 2
    var s = GameState(settings: MatchSettings(), humans: [HumanSlot(id: h1, team: .home)])
    let mb2 = s.rosters[TeamSide.home.rawValue].ids(.middle)[1]
    s.humans[0].pick = .athlete(mb2)
    // Every rotation, serving and receiving.
    var sawLibero = false, sawMiddle = false
    for r in 0..<6 {
        for serving in [TeamSide.home, .away] {
            var t = s
            for _ in 0..<r { t.lineups[0].rotate() }
            t.score.serving = serving
            t.motion = [:]
            _ = t.refreshPositions()
            expectFollows(h1, picked: mb2, t, "rotation \(r + 1), \(serving) serving")
            if t.motion[mb2] == nil { sawLibero = true } else { sawMiddle = true }
        }
    }
    #expect(sawLibero && sawMiddle)
    // And on every tick of a match, through side-outs and libero swaps.
    var ticks = 0
    var swaps = 0
    for _ in 0..<(60 * 60 * 30) where s.phase != .matchOver {
        let events = step(&s, inputs: perfectInputs(h1, s))
        swaps += events.filter { if case .liberoIn = $0 { true } else { false } }.count
        expectFollows(h1, picked: mb2, s, "tick \(s.tick)")
        ticks += 1
    }
    #expect(swaps > 2 && ticks > 1000)
}

@Test func switchDoesNotStealInFlight() {                          // Review Focus 3
    var found = false
    for seed in UInt64(1)...6 where !found {
        var s = homeHuman(seed: seed)
        let roster = s.rosters[TeamSide.home.rawValue]
        let oh1 = roster.ids(.outside)[0]
        s.humans[0].pick = .athlete(oh1)
        // To the set flying to OH1, theirs.
        play(&s, inputs: { perfectInputs(h1, $0) }) { s, _ in
            s.pending?.kind == .attack && s.pending?.athlete == oh1 && s.pending?.owner == h1
        }
        guard let attack = s.pending, attack.kind == .attack, attack.athlete == oh1 else { continue }
        found = true
        // H1 switches to the middle on court.
        let mb = roster.ids(.middle).first { s.motion[$0] != nil }!
        _ = step(&s, inputs: [PlayerInput(human: h1, tick: s.tick, action: .switchTo(.athlete(mb)))])
        #expect(s.humans[0].switched == .athlete(mb) && controlled(by: h1, s) == mb)
        #expect(s.pending?.id == attack.id && s.pending?.owner == h1)
        // The attack is still H1's: played on time it's judged.
        let events = play(&s, inputs: { perfectInputs(h1, $0) }) { s, _ in s.pending?.id != attack.id }
        #expect(events.contains { if case .judged(attack.id, _) = $0 { true } else { false } })
        // From the next touch on, OH1 is the AI's and the middle is H1's, until
        // the huddle.
        var checked = 0
        play(&s, inputs: { perfectInputs(h1, $0) }) { s, _ in
            if let c = s.pending, c.team == .home, c.kind != nil, c.kind != .block {
                if c.athlete == oh1 { #expect(c.owner == nil); checked += 1 }
                if c.athlete == onCourt(as: mb, s) { #expect(c.owner == h1); checked += 1 }
            }
            if case .huddle = s.phase { return true }
            return false
        }
        // The huddle restores the pick.                               (switchRevertsAtHuddle)
        #expect(s.humans[0].switched == nil && s.humans[0].pick == .athlete(oh1))
        #expect(controlled(by: h1, s) == oh1)
        _ = checked
    }
    #expect(found)
}

@Test func switchRevertsAtHuddle() {
    var s = homeHuman(seed: 2)
    let setter = s.rosters[TeamSide.home.rawValue].ids(.setter)[0]
    // Into the first rally, then a switch to the setter.
    play(&s) { s, _ in s.phase == .rally }
    _ = step(&s, inputs: [PlayerInput(human: h1, tick: s.tick, action: .switchTo(.athlete(setter)))])
    #expect(controlled(by: h1, s) == setter)
    play(&s) { s, _ in if case .huddle = s.phase { true } else { false } }
    #expect(s.humans[0].current == .ball && s.humans[0].switched == nil)
    // No switching inside the huddle: that's a pick.
    _ = step(&s, inputs: [PlayerInput(human: h1, tick: s.tick, action: .switchTo(.athlete(setter)))])
    #expect(s.humans[0].switched == nil)
}

@Test func ballHumansAlternate() {                                  // Review Focus 4
    var rallies = 0, blockThenDig = 0, homeWindows = 0
    var seed: UInt64 = 1
    while rallies < 100 {
        var settings = MatchSettings()
        settings.seed = seed
        seed += 1
        var s = GameState(settings: settings, humans: [HumanSlot(id: h1, team: .home), HumanSlot(id: h2, team: .home)])
        var last: (HumanID, TouchKind)?
        var lastID: ContactID?
        for _ in 0..<(60 * 60 * 30) where s.phase != .matchOver {
            let events = step(&s, inputs: perfectInputs(h1, s) + perfectInputs(h2, s))
            for e in events {
                if case .point = e { rallies += 1 }
                // A serve's window comes again as it's tossed: one touch.
                guard case .window(let id, let kind, let owner, _) = e, owner == h1 || owner == h2, id != lastID else { continue }
                lastID = id
                homeWindows += 1
                if let (prev, prevKind) = last {
                    #expect(prev != owner, "tick \(s.tick): \(prevKind) then \(kind) both \(owner)")
                    if prevKind == .block && kind == .dig { blockThenDig += 1 }
                }
                last = (owner, kind)
            }
        }
    }
    #expect(homeWindows > 300)
    #expect(blockThenDig > 0)
}

@Test func noDuplicatePicks() {
    let humans = [HumanSlot(id: h1, team: .home), HumanSlot(id: h2, team: .home), HumanSlot(id: HumanID(raw: 3), team: .away)]
    var s = GameState(settings: MatchSettings(), humans: humans)
    guard case .huddle = s.phase else { Issue.record("no opening huddle"); return }
    let roster = s.rosters[TeamSide.home.rawValue]
    let oh1 = roster.ids(.outside)[0], oh2 = roster.ids(.outside)[1]
    #expect(Huddle.apply(.pick(.athlete(oh1)), from: h1, &s))
    #expect(!Huddle.apply(.pick(.athlete(oh1)), from: h2, &s))
    #expect(s.humans[1].pick == .ball)
    // Through step too, and the switch strip follows the same rule.
    _ = step(&s, inputs: [PlayerInput(human: h2, tick: s.tick, action: .pick(.athlete(oh1)))])
    #expect(s.humans[1].pick == .ball)
    #expect(Huddle.apply(.pick(.athlete(oh2)), from: h2, &s))
    // Nobody picks the other team's players; both can pick "ball".
    #expect(!Huddle.apply(.pick(.athlete(AthleteID(team: .away, index: 0))), from: h1, &s))
    #expect(Huddle.apply(.pick(.ball), from: h1, &s) && Huddle.apply(.pick(.ball), from: h2, &s))
    #expect(Huddle.apply(.pick(.athlete(oh1)), from: HumanID(raw: 3), &s) == false)
    // Calls: either human, the last change wins.
    let mb = roster.ids(.middle).first { s.lineups[0].zone(of: $0)?.isFrontRow == true }!
    #expect(Huddle.apply(.call(mb, .slide), from: h1, &s))
    #expect(Huddle.apply(.call(mb, .thirtyOne), from: h2, &s))
    #expect(s.calls[0].byAthlete[mb] == .thirtyOne)
    #expect(!Huddle.apply(.call(mb, .pipe), from: h1, &s))
}

@Test func huddleNeverPauses() {
    // However much the humans do, each huddle is exactly huddleSeconds long.
    var s = GameState(settings: MatchSettings(), humans: [HumanSlot(id: h1, team: .home), HumanSlot(id: h2, team: .away)])
    let oh = s.rosters[TeamSide.home.rawValue].ids(.outside)[0]
    var lengths: [Int] = []
    var start: Int? = 0
    for _ in 0..<(60 * 60 * 30) where s.phase != .matchOver && lengths.count < 4 {
        var inputs = perfectInputs(h1, s) + perfectInputs(h2, s)
        inputs += [PlayerInput(human: h1, tick: s.tick, action: .ready), PlayerInput(human: h1, tick: s.tick, action: .pick(.athlete(oh))),
                   PlayerInput(human: h2, tick: s.tick, action: .ready)]
        _ = step(&s, inputs: inputs)
        if case .huddle = s.phase {
            if start == nil { start = s.tick }
        } else if let st = start {
            lengths.append(s.tick - st)
            start = nil
        }
    }
    #expect(lengths.count == 4)
    #expect(lengths.allSatisfy { $0 == Int(Tuning.huddleSeconds * 60) }, "\(lengths)")
}

@Test func readShiftsDefense() {
    // Away is about to set; home (a human side) reads away's front-row middle.
    for seed in UInt64(1)...10 {
        var s = homeHuman(seed: seed)
        play(&s, inputs: { perfectInputs(h1, $0) }) { s, _ in s.pending?.kind == .set && s.pending?.team == .away }
        guard s.pending?.kind == .set else { continue }
        let live = liveCalls(s, team: .away, passQuality: s.notes.passQuality)
        guard let mb = live.first(where: { s.rosters[1][$0.0].position == .middle })?.0 else { continue }
        var none = s
        none.notes.reads[0] = nil
        _ = step(&none, inputs: [])
        var read = s
        read.notes.reads[0] = nil
        _ = step(&read, inputs: [PlayerInput(human: h1, tick: s.tick, action: .read(hitter: mb))])
        #expect(read.notes.reads[0] == mb && read.notes.humanReads[0] == mb)
        guard let target = DefenseAI.readTarget(read, defending: .home) else { Issue.record("no read target"); return }
        let t = TeamView(read, .home)
        var best: Float = 0
        for (id, role) in t.roles where role.isFront {
            let before = abs(LocalFrame.toLocal(none.motion[id]!.goal, team: .home).l - target)
            let after = abs(LocalFrame.toLocal(read.motion[id]!.goal, team: .home).l - target)
            #expect(after <= before + 1e-4)
            best = max(best, before - after)
        }
        #expect(best >= 0.5, "best shift \(best)")
        // The AI doesn't overrule it at the next pass: the read is the human's
        // for the rally.
        var again = read
        #expect(DefenseAI.read(&again, defending: .home) == mb)
        return
    }
    Issue.record("never found away setting with a live middle")
}
