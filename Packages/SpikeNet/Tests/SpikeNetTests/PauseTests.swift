import Foundation
import SpikeCore
import Testing
@testable import SpikeNet

/// Review Focus 5 at the loop level: the host stops (its app left the screen), the guest stops
/// with it, and both pick up from the same tick.
@Suite struct PauseTests {
    @Test func hostPauseStopsBoth() {
        var settings = MatchSettings()
        settings.seed = 5
        settings.pointsToWin = 5
        let rig = Rig(settings: settings)
        let g = rig.join(team: .away, link: .init(oneWayDelay: 0.010, jitter: 0.004), skill: 0.85)
        var dropped: [HumanID] = []
        rig.server.onDrop = { dropped.append($0) }
        rig.run(seconds: 8)
        let loop = try! #require(g.loop)

        rig.server.pause()
        let hostTick = rig.server.state.tick
        rig.run(seconds: 0.2)
        #expect(loop.hostPaused)
        let guestTick = loop.predicted.tick
        // Five seconds in the background: nothing moves on either phone.
        rig.run(seconds: 5)
        #expect(rig.server.state.tick == hostTick)
        #expect(loop.predicted.tick == guestTick)
        #expect(guestTick - hostTick <= 8)

        rig.server.resume(now: rig.now)
        rig.run(seconds: 0.2)
        #expect(!loop.hostPaused)
        // From the same tick: the paused time isn't stepped.
        #expect(rig.server.state.tick <= hostTick + 14)
        #expect(loop.predicted.tick <= guestTick + 14)
        rig.runMatch()
        #expect(dropped.isEmpty)
        #expect(rig.server.state.phase == .matchOver)
        #expect(loop.state(at: rig.server.state.tick) == rig.server.state)
    }

    /// A `paused` that arrives after a later snapshot (the host already came back) is ignored.
    @Test func latePausedIgnored() {
        var settings = MatchSettings()
        settings.seed = 6
        let rig = Rig(settings: settings)
        let g = rig.join(team: .home, link: .init(oneWayDelay: 0.010), skill: 0.85)
        rig.run(seconds: 3)
        let loop = try! #require(g.loop)
        let old = try! Wire.encode(.paused(tick: rig.server.state.tick - 30))
        rig.serverEnd.send(old, to: g.end.id)
        rig.run(seconds: 0.3)
        #expect(!loop.hostPaused)
    }
}
