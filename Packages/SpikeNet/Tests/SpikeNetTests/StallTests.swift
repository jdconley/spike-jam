import Foundation
import SpikeCore
import Testing
@testable import SpikeNet

/// A phone's main thread stalls (the match view loading its scene took a second and a half on a
/// simulator): the host skips what it can't catch up, a client catches up all of it and finds
/// itself far ahead, or behind. It jumps its clock once or twice and carries on, and nobody is
/// dropped.
@Suite struct StallTests {
    @Test func stallRecovers() {
        var settings = MatchSettings()
        settings.seed = 12
        let rig = Rig(settings: settings)
        // The hosting phone's own client: no delay, and it stalls with the host.
        let own = rig.join(team: .home, link: .perfect, skill: 0.85)
        let guest = rig.join(team: .away, link: .init(oneWayDelay: 0.015, jitter: 0.005), skill: 0.85, seed: 2)
        var dropped: [HumanID] = []
        rig.server.onDrop = { dropped.append($0) }
        rig.run(seconds: 0.05)
        var jumps = [0, 0]
        func check(_ what: String) {
            #expect(dropped.isEmpty, "\(what)")
            for (i, g) in [own, guest].enumerated() {
                guard let loop = g.loop else {
                    Issue.record("\(what): no loop")
                    continue
                }
                #expect(loop.clockJumps - jumps[i] <= 3, "\(what): \(loop.clockJumps - jumps[i]) jumps")
                jumps[i] = loop.clockJumps
                let buffer = rig.server.buffer(of: g.human) ?? -99
                #expect((0...4).contains(buffer), "\(what): buffer \(buffer)")
                #expect(abs(loop.predicted.tick - rig.server.state.tick) <= 8, "\(what)")
            }
        }
        // The hosting phone stalls; the guest's phone carries on.
        for stall in [1.6, 0.8, 2.5] {
            let end = rig.now + stall
            while rig.now < end {
                rig.now += Rig.frame
                rig.net.advance(to: rig.now)
                if let loop = guest.loop { _ = loop.advance(to: rig.now) }
            }
            rig.run(seconds: 4)
            check("host stall \(stall)")
        }
        // The guest's phone stalls, not long enough to be dropped.
        guest.silent = true
        rig.run(seconds: 0.8)
        guest.silent = false
        rig.run(seconds: 4)
        check("guest stall")
    }
}
