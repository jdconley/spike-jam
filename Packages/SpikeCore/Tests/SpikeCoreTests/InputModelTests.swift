import Foundation
import Testing
@testable import SpikeCore

@Test func contactIDsIncrease() {
    var settings = MatchSettings()
    settings.seed = 4
    var s = GameState(settings: settings)
    var last = ContactID.none
    var seen = 0
    for _ in 0..<(60 * 60 * 30) where s.phase != .matchOver {
        _ = step(&s, inputs: [])
        for c in [s.pending, s.notes.afterBlock].compactMap({ $0 }) {
            #expect(c.id != .none, "tick \(s.tick): an unnumbered contact")
            if c.id > last {
                last = c.id
                seen += 1
            } else {
                // The same contact as before, or the dig held back for a block.
                #expect(c.id == last || c.id == s.notes.afterBlock?.id || c.id == s.pending?.id)
            }
        }
    }
    #expect(seen > 100)
    #expect(s.nextContactID.raw == last.raw + 1)
}

@Test func noHumansUnchanged() {
    // A bot match is the same value with or without the new parameter, and
    // plays plan 3's game exactly: the point winners of seed 17 (the
    // determinism test's) as they were before humans existed.
    var settings = MatchSettings()
    settings.seed = 17
    #expect(GameState(settings: settings) == GameState(settings: settings, humans: []))
    var s = GameState(settings: settings, humans: [])
    var winners = ""
    for _ in 0..<(60 * 60 * 30) where s.phase != .matchOver {
        for case .point(let w, _) in step(&s, inputs: []) { winners += w == .home ? "H" : "A" }
    }
    #expect(s.humans.isEmpty && s.settings.humanSides.isEmpty)
    #expect(winners == noHumansSeed17, "\(winners)")
}

/// Who won each point of seed 17 before plan 4 (`GameState(settings:)` on
/// commit ea3391e).
private let noHumansSeed17 = "AHHHHHAHHHAHAHHAHAHAHAH"

@Test func controlledFollowsPick() {
    let h1 = HumanID(raw: 1)
    var s = GameState(settings: MatchSettings(), humans: [HumanSlot(id: h1, team: .home)])
    let roster = s.rosters[TeamSide.home.rawValue]
    let oh1 = roster.ids(.outside)[0]
    let mb = roster.ids(.middle)
    // The middle on court (the other one is off for the libero, or serving).
    let mbOn = mb.first { s.motion[$0] != nil }!
    s.humans[0].pick = .athlete(oh1)
    #expect(controlled(by: h1, s) == oh1)
    s.humans[0].switched = .athlete(mbOn)
    #expect(controlled(by: h1, s) == mbOn)
    s.humans[0].switched = nil
    #expect(controlled(by: h1, s) == oh1)
    // Nobody else is controlled by a human who isn't there.
    #expect(controlled(by: HumanID(raw: 9), s) == nil)
    // With "ball" and no touch coming, nobody.
    s.humans[0].pick = .ball
    #expect(controlled(by: h1, s) == nil)
}

@Test func inputsRoundTrip() throws {
    let c = ContactID(raw: 7)
    let a = AthleteID(team: .away, index: 3)
    let actions: [InputAction] = [
        .press(contact: c), .release(contact: c, aim: Vec2(x: 4.5, z: -1.25)), .release(contact: c, aim: nil),
        .tap(contact: c), .setTo(contact: c, hitter: a), .block(contact: c), .read(hitter: a),
        .pick(.ball), .pick(.athlete(a)), .call(a, .slide), .combo(.slideRed), .switchTo(.athlete(a)), .switchTo(.ball),
        .ready, .teamSettings(TeamSettings(system: .sixTwo, startingRotation: 4)),
    ]
    for (i, action) in actions.enumerated() {
        let input = PlayerInput(human: HumanID(raw: 2), tick: 1000 + i, offset: 0.004, action: action)
        let back = try JSONDecoder().decode(PlayerInput.self, from: try JSONEncoder().encode(input))
        #expect(back == input)
    }
    let slot = HumanSlot(id: HumanID(raw: 3), team: .away, pick: .athlete(a), switched: .ball, ready: true)
    #expect(try JSONDecoder().decode(HumanSlot.self, from: try JSONEncoder().encode(slot)) == slot)
}
