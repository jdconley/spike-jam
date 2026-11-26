import Testing
@testable import SpikeCore

private let allGaits: [Gait] = [.stand, .run, .shuffle, .backpedal, .approach, .dive]

@Test func reachesGoal() {
    var m = Motion(pos: Vec2(x: -6, z: 0))
    m.goal = Vec2(x: -2, z: 3)
    m.gait = .run
    var arrivedAt: Int?
    for t in 1...120 {
        Steering.advance(&m, team: .home, speedTrait: 0.5, dt: Tuning.dt)
        if arrivedAt == nil && (m.pos - m.goal).length <= Tuning.arriveRadius { arrivedAt = t }
    }
    #expect(arrivedAt != nil)
    #expect((m.pos - m.goal).length <= Tuning.arriveRadius)
    #expect(m.vel.length < 0.1)
}

@Test(arguments: allGaits)
func neverExceedsCap(gait: Gait) {
    for trait: Float in [0, 1] {
        let cap = Steering.cap(gait, speedTrait: trait)
        var m = Motion(pos: Vec2(x: -8, z: -4))
        m.gait = gait
        for t in 0..<600 {
            // A goal that keeps jumping around, so the player keeps turning.
            if t % 40 == 0 {
                m.goal = Vec2(x: -Float((t / 40) % 7 + 1), z: Float((t / 40) % 5) * 2 - 4)
            }
            Steering.advance(&m, team: .home, speedTrait: trait, dt: Tuning.dt)
            #expect(m.vel.length <= cap + 1e-4)
        }
    }
    // Slowing to a slower gait mid-run still never exceeds the new cap.
    var m = Motion(pos: Vec2(x: -8, z: 0))
    m.goal = Vec2(x: -1, z: 0)
    m.gait = .run
    for _ in 0..<20 { Steering.advance(&m, team: .home, speedTrait: 1, dt: Tuning.dt) }
    m.gait = .shuffle
    Steering.advance(&m, team: .home, speedTrait: 1, dt: Tuning.dt)
    #expect(m.vel.length <= Steering.cap(.shuffle, speedTrait: 1) + 1e-4)
}

@Test func capFormula() {
    #expect(abs(Steering.cap(.run, speedTrait: 0) - 6.0 * 1.25 * 0.85) < 1e-5)
    #expect(abs(Steering.cap(.approach, speedTrait: 1) - 5.0 * 1.25 * 1.15) < 1e-5)
}

@Test func goalAcrossNetClamped() {                            // Review Focus 3
    for team in TeamSide.allCases {
        var m = Motion(pos: LocalFrame.toWorld(LocalSpot(d: 3, l: 0), team: team))
        m.goal = LocalFrame.toWorld(LocalSpot(d: -3, l: 0), team: team)
        m.gait = .run
        for _ in 0..<240 {
            Steering.advance(&m, team: team, speedTrait: 1, dt: Tuning.dt)
            #expect(LocalFrame.toLocal(m.pos, team: team).d >= 0.2 - 1e-5)
            #expect(LocalFrame.toLocal(m.goal, team: team).d >= 0.2 - 1e-5)
        }
        #expect(abs(LocalFrame.toLocal(m.pos, team: team).d - 0.2) < 0.01)
    }
    var m = Motion(pos: Vec2(x: -3, z: 0))
    m.goal = Vec2(x: 3, z: 0)
    m.gait = .run
    for _ in 0..<240 {
        Steering.advance(&m, team: .home, speedTrait: 1, dt: Tuning.dt)
        #expect(m.pos.x <= -0.2 + 1e-5)
    }
}

@Test func freeZoneClamped() {
    var m = Motion(pos: Vec2(x: -6, z: 0))
    m.goal = Vec2(x: -20, z: 10)
    m.gait = .run
    for _ in 0..<600 {
        Steering.advance(&m, team: .home, speedTrait: 1, dt: Tuning.dt)
        let local = LocalFrame.toLocal(m.pos, team: .home)
        #expect(local.d <= 12 + 1e-5 && abs(local.l) <= 7.5 + 1e-5)
    }
    let end = LocalFrame.toLocal(m.pos, team: .home)
    #expect(abs(end.d - 12) < 0.01 && abs(end.l - 7.5) < 0.01)
    #expect(m.goal == Vec2(x: -12, z: 7.5))
}

@Test func arrivesByTheTick() {
    // An approach paced to arrive on a tick doesn't get there early.
    var m = Motion(pos: Vec2(x: -4.5, z: -4.6))
    m.goal = Vec2(x: -1.7, z: -3.3)
    m.gait = .approach
    m.arriveByTick = 100
    var arrivedAt: Int?
    for tick in 1...140 {
        Steering.advance(&m, team: .home, speedTrait: 0.5, dt: Tuning.dt, tick: tick)
        if arrivedAt == nil && (m.pos - m.goal).length <= 0.01 { arrivedAt = tick }
    }
    #expect(arrivedAt != nil)
    #expect(abs(arrivedAt! - 100) <= 3, "arrived at \(arrivedAt!)")
}

@Test func jumpCurve() {
    let j = Jump(startTick: 10, durationTicks: 48, height: 0.9)
    #expect(j.height(atTick: 9) == 0)
    #expect(j.height(atTick: 10) == 0)
    #expect(j.height(atTick: 58) == 0)
    #expect(j.height(atTick: 59) == 0)
    #expect(abs(j.height(atTick: 34) - 0.9) < 1e-3)
    #expect(j.peakTick == 34)
    for k in 0...24 {
        #expect(abs(j.height(atTick: 34 - k) - j.height(atTick: 34 + k)) < 1e-5)
    }
    #expect(j.height(atTick: 20) > 0 && j.height(atTick: 20) < 0.9)
}
