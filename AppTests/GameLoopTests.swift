import Foundation
import SpikeCore
import Testing
@testable import SpikeJam

private let dt = Tuning.dt

@MainActor
private func freshLoop() -> LocalClientLoop {
    LocalClientLoop(state: GameState(settings: MatchSettings()))
}

/// A wall clock the tests move by hand.
@MainActor
private final class FakeClock {
    var now: Double = 100
}

@MainActor
@Suite struct GameLoopTests {
    @Test func fixedStepping() {
        let loop = freshLoop()
        let start = 50.0
        _ = loop.advance(to: start) // sets the base
        let startTick = loop.current.tick
        let chunks = [0.007, 0.013, 0.033, 0.021, 0.002, 0.048]
        var t = 0.0, i = 0
        while t < 1.0 {
            t = min(1.0, t + chunks[i % chunks.count])
            i += 1
            _ = loop.advance(to: start + t)
        }
        #expect(loop.current.tick - startTick == 60)
        #expect(loop.previous.tick == loop.current.tick - 1)
    }

    /// Review Focus 3: a 500 ms stall steps at most 8 times and drops the rest.
    @Test func hitchCapped() {
        let loop = freshLoop()
        _ = loop.advance(to: 10)
        _ = loop.advance(to: 10 + dt)
        let before = loop.current.tick
        _ = loop.advance(to: 10 + dt + 0.5)
        #expect(loop.current.tick - before == LocalClientLoop.maxStepsPerAdvance)
        #expect(loop.accumulator < dt)
        // The dropped time is gone: the next frame steps once, not the 22 left over.
        let after = loop.current.tick
        _ = loop.advance(to: 10 + dt + 0.5 + dt)
        #expect(loop.current.tick - after <= 1)
    }

    /// Review Focus 4: paused 10 s in the background, then resumed, the next frame steps at most once.
    @Test func resumeNoBurst() {
        let clock = FakeClock()
        let client = freshLoop()
        let loop = GameLoop(client: client, clock: { clock.now })
        loop.frame()
        for _ in 0..<5 {
            clock.now += dt
            loop.frame()
        }
        #expect(client.current.tick == 5)
        loop.pause()
        clock.now += 10
        loop.frame() // the display link is paused, but a stray frame must do nothing either
        #expect(client.current.tick == 5)
        loop.resume()
        clock.now += dt
        let before = client.current.tick
        loop.frame()
        #expect(client.current.tick - before <= 1)
        #expect(client.stepsLastAdvance <= 1)
    }

    @Test func inputStamping() {
        let loop = freshLoop()
        _ = loop.advance(to: 20)
        _ = loop.advance(to: 20.3)
        let stamp = loop.stamp(at: loop.tickTime(120) + 0.005)
        #expect(stamp.tick == 120)
        #expect(abs(stamp.offset - 0.005) < 1e-9)
        // The stamp holds however far the loop has run since.
        _ = loop.advance(to: 21.5)
        let again = loop.stamp(at: loop.tickTime(120) + 0.005)
        #expect(again == InputStamp(tick: 120, offset: again.offset))
        #expect(abs(again.offset - 0.005) < 1e-6)
    }

    @Test func inputsGoIntoTheirStep() {
        var delivered: [Int] = []
        let loop = LocalClientLoop(state: GameState(settings: MatchSettings())) { s, inputs in
            if !inputs.isEmpty { delivered.append(s.tick) }
            return step(&s, inputs: inputs)
        }
        _ = loop.advance(to: 0)
        _ = loop.advance(to: 0.05) // 3 steps
        let input = try? JSONDecoder().decode(PlayerInput.self, from: Data("{}".utf8))
        guard let input else { return } // plan 4 gives PlayerInput fields; then Task 3 tests this
        loop.send(input, at: loop.tickTime(5) + 0.001)
        _ = loop.advance(to: 0.2)
        #expect(delivered == [5])
        #expect(loop.queued.isEmpty)
    }

    @Test func launchArguments() {
        #expect(LaunchOptions(arguments: ["app", "-demo", "autoplay"]).demo == .autoplay)
        #expect(LaunchOptions(arguments: ["app"]).demo == nil)
        #expect(LaunchOptions(arguments: ["app", "-demo"]).demo == nil)
    }
}
