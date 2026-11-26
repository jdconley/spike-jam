import Testing
@testable import SpikeCore

private func near(_ a: Vec3, _ b: Vec3, _ tol: Float = 1e-4) -> Bool {
    (a - b).length < tol
}

@Test func hitsEndpoints() {
    let from = Vec3(x: -7, y: 2.6, z: 3), to = Vec3(x: 4, y: 0.2, z: -1.5)
    let f = Flight.make(from: from, to: to, duration: 0.95, startTime: 3.25)
    #expect(f.endTime == 3.25 + 0.95)
    #expect(near(f.position(at: f.startTime), from))
    #expect(near(f.position(at: f.endTime), to))
}

@Test func apexBetween() {
    let f = Flight.make(from: Vec3(x: 0, y: 1, z: 0), to: Vec3(x: 4, y: 1, z: 0), duration: 1, startTime: 0)
    let mid = f.position(at: 0.5)
    #expect(abs(mid.y - 1 - (-Tuning.gravity * 0.125)) < 1e-3)
}

@Test func heightAtNet() {
    let f = Flight.make(from: Vec3(x: -6, y: 1, z: 0), to: Vec3(x: 6, y: 0, z: 0), duration: 1, startTime: 2)
    // Crosses x = 0 at s = 0.5: y = 1 + v0y·0.5 + ½g·0.25 with v0y = −1 − ½g.
    let expected: Float = 0.5 - 0.125 * Tuning.gravity
    #expect(abs(f.heightAtNet()! - expected) < 1e-3)
    let short = Flight.make(from: Vec3(x: -6, y: 1, z: 0), to: Vec3(x: -1, y: 0, z: 0), duration: 1, startTime: 0)
    #expect(short.heightAtNet() == nil)
    let along = Flight.make(from: Vec3(x: -3, y: 1, z: -2), to: Vec3(x: -3, y: 1, z: 2), duration: 1, startTime: 0)
    #expect(along.heightAtNet() == nil)
}

@Test func descendingThrough() {
    let f = Flight.make(from: Vec3(x: -4, y: 0, z: 0), to: Vec3(x: 4, y: 0, z: 0), duration: 1, startTime: 10)
    let t = f.timeDescending(through: 0.5)!
    #expect(t > 10.5 && t < 11)
    #expect(abs(f.position(at: t).y - 0.5) < 1e-3)
    #expect(f.timeDescending(through: 100) == nil)
}

@Test func clearingRaisesArcKeepingEndpoints() {
    // A flat attack from near the net into the short court would hit the tape.
    let from = Vec3(x: -1.1, y: 3.15, z: 0), to = Vec3(x: 0.9, y: 0, z: 0)
    let low = Flight.make(from: from, to: to, duration: 0.3, startTime: 1)
    #expect(low.heightAtNet()! < 2.58)
    let f = Flight.makeClearing(from: from, to: to, duration: 0.3, startTime: 1, netClearance: 2.58)
    #expect(f.heightAtNet()! >= 2.58 - 1e-3)
    #expect(f.duration > 0.3)
    #expect(near(f.position(at: f.startTime), from) && near(f.position(at: f.endTime), to, 1e-3))
    // A flight that already clears is left alone.
    let high = Flight.make(from: Vec3(x: -9.9, y: 2.6, z: 0), to: Vec3(x: 6, y: 0, z: 0), duration: 0.95, startTime: 0)
    #expect(Flight.makeClearing(from: high.p0, to: Vec3(x: 6, y: 0, z: 0), duration: 0.95, startTime: 0, netClearance: 2.58) == high)
}
