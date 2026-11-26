import Testing
@testable import SpikeCore

/// Ticks `advance` takes to bring `m` within `arriveRadius` of its goal.
private func ticksToArrive(_ m: Motion, speedTrait: Float) -> Int {
    var m = m
    for t in 1...600 {
        Steering.advance(&m, team: .home, speedTrait: speedTrait, dt: Tuning.dt)
        if (m.pos - m.goal).length <= Tuning.arriveRadius { return t }
    }
    return 600
}

@Test func etaMatchesSteering() {
    var rng = SeededRNG(seed: 99)
    var worst = 0.0
    for i in 0..<400 {
        let start = Vec2(x: -rng.float(in: 0.5...8.5), z: rng.float(in: -4.4...4.4))
        let goal = Vec2(x: -rng.float(in: 0.5...8.5), z: rng.float(in: -4.4...4.4))
        // Half start still, half already moving in some direction.
        let vel = i % 2 == 0 ? Vec2.zero : Vec2(x: rng.float(in: -4...4), z: rng.float(in: -4...4))
        let gait: Gait = [.run, .shuffle, .approach, .backpedal][i % 4]
        let trait = rng.unit()
        var m = Motion(pos: start, vel: vel, goal: goal, gait: gait)
        let cap = Steering.cap(gait, speedTrait: trait)
        if m.vel.length > cap { m.vel = m.vel * (cap / m.vel.length) }
        let predicted = Steering.eta(m, to: goal, cap: cap)
        let actual = Double(ticksToArrive(m, speedTrait: trait)) * Tuning.dt
        worst = max(worst, abs(predicted - actual))
        #expect(abs(predicted - actual) <= 0.1, "case \(i): eta \(predicted) s, took \(actual) s")
    }
    print("eta worst error: \(worst) s")
}

@Test func etaIsZeroWhenThere() {
    let m = Motion(pos: Vec2(x: -3, z: 1))
    #expect(Steering.eta(m, to: Vec2(x: -3.05, z: 1), cap: 7) == 0)
}
