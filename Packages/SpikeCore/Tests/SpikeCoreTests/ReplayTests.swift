import Foundation
import Testing
@testable import SpikeCore

@Test func replayIdentical() throws {                               // Review Focus 5
    // A "ball" human on home and a human on away who picked an outside and
    // switches now and then, both playing through inputs: picks, switches,
    // reads and every touch go into the log.
    var settings = MatchSettings()
    settings.seed = 21
    let awayOH = GameState(settings: settings).rosters[TeamSide.away.rawValue].ids(.outside)[0]
    var sims = [SimHuman(id: h1, team: .home, skill: 0.7, seed: 5),
                SimHuman(id: h2, team: .away, skill: 0.5, pick: .athlete(awayOH), seed: 6)]
    let slots = [HumanSlot(id: h1, team: .home), HumanSlot(id: h2, team: .away)]
    var s = GameState(settings: settings, humans: slots)
    var log = InputLog()
    var events: [GameEvent] = []
    var switches = 0
    for _ in 0..<(60 * 60 * 30) where s.phase != .matchOver {
        var inputs: [PlayerInput] = []
        for k in sims.indices { inputs += sims[k].inputs(for: s) }
        if s.phase == .rally && s.tick % 97 == 0 {
            inputs.append(PlayerInput(human: h2, tick: s.tick, offset: 0.003,
                                      action: .switchTo(switches % 2 == 0 ? .ball : .athlete(awayOH))))
            switches += 1
        }
        log.record(inputs, before: s)
        events += step(&s, inputs: inputs)
    }
    #expect(s.phase == .matchOver)
    #expect(switches > 5)
    let kinds = Set(log.entries.map { entry -> String in
        switch entry.input.action {
        case .pick: "pick"
        case .read: "read"
        case .switchTo: "switch"
        default: "touch"
        }
    })
    #expect(kinds == ["pick", "read", "switch", "touch"])
    #expect(events.contains { if case .judged = $0 { true } else { false } })

    // Through JSON and back, then played again from the start.
    let stored = try JSONDecoder().decode(InputLog.self, from: try JSONEncoder().encode(log))
    #expect(stored == log)
    let again = replay(settings, humans: slots, log: stored)
    #expect(again.state == s)
    #expect(again.events == events)
}
