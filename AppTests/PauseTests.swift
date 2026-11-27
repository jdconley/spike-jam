import Foundation
import SpikeCore
import SpikeNet
import Testing
@testable import SpikeJam

/// Review Focus 5: the hosting phone leaves the screen (iOS doesn't let a host run in the
/// background). The match stops on both phones, the guest shows "Host paused", and both pick up
/// from the same tick.
@MainActor
@Suite(.serialized) struct PauseTests {
    @Test func hostBackgroundPauses() async throws {
        var settings = MatchSettings()
        settings.seed = 8
        let rig = try await NetRig(settings: settings, guestTeam: .away)
        defer { rig.close() }
        #expect(await rig.lobby())
        let hostLoop = try #require(rig.start())
        await rig.run(seconds: 8)
        let client = try #require(rig.guestClient)
        #expect(!rig.guest.hostPaused)

        // The host's scene goes to the background: its game loop pauses the client loop.
        hostLoop.pause()
        rig.hostPaused = true
        let hostTick = rig.server.state.tick
        #expect(await rig.run(until: 0.5) { rig.guest.hostPaused })
        let guestTick = client.predicted.tick
        await rig.run(seconds: 2)
        #expect(rig.guest.hostPaused)
        #expect(client.predicted.tick == guestTick)
        #expect(rig.server.state.tick == hostTick)
        #expect(guestTick - hostTick <= 8)

        // Back: on from the tick it stopped at, with nobody dropped and no reconnecting.
        rig.hostPaused = false
        hostLoop.resume(at: rig.now)
        #expect(await rig.run(until: 0.5) { !rig.guest.hostPaused })
        #expect(rig.server.state.tick <= hostTick + 40)
        #expect(client.predicted.tick <= guestTick + 40)
        await rig.run(seconds: 5)
        #expect(rig.guestClient === client)
        #expect(rig.guest.reconnects == 0)
        #expect(rig.host.drops == 0)
        #expect(rig.server.connected.count == 2)
        #expect(abs((client.snapshotTick ?? 0) - rig.server.state.tick) <= 6)
    }

    /// A long pause: the guest connects again in case the host's sockets went while it was
    /// away, and rejoins the same slot when the host is back.
    @Test func longHostPauseRejoins() async throws {
        var settings = MatchSettings()
        settings.seed = 9
        let rig = try await NetRig(settings: settings, guestTeam: .home)
        defer { rig.close() }
        #expect(await rig.lobby())
        let hostLoop = try #require(rig.start())
        await rig.run(seconds: 6)
        let h = try #require(rig.guestClient?.human)

        hostLoop.pause()
        rig.hostPaused = true
        await rig.run(seconds: 8)
        #expect(rig.guest.hostPaused)
        #expect(rig.guest.reconnects >= 1)

        rig.hostPaused = false
        hostLoop.resume(at: rig.now)
        #expect(await rig.run(until: 3) { !rig.guest.hostPaused && rig.guestClient?.snapshotTick != nil && rig.server.connected.count == 2 })
        #expect(rig.guestClient?.human == h)
        #expect(rig.server.state.human(h)?.team == .home)
        await rig.run(seconds: 3)
        #expect(rig.server.connected.count == 2)
    }
}
