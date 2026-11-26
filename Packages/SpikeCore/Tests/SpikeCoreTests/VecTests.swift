import Testing
@testable import SpikeCore

@Test func vecArithmetic() {
    let a = Vec3(x: 1, y: 2, z: 3), b = Vec3(x: 0.5, y: -1, z: 2)
    #expect(a + b == Vec3(x: 1.5, y: 1, z: 5))
    #expect(a - b == Vec3(x: 0.5, y: 3, z: 1))
    #expect(a * 2 == Vec3(x: 2, y: 4, z: 6))
    #expect(Vec2(x: 3, z: 4).length == 5)
    #expect(abs(Vec2(x: 3, z: 4).normalized.length - 1) < 1e-6)
    #expect(a.xz == Vec2(x: 1, z: 3))
}

@Test func teamSides() {
    #expect(TeamSide.home.dir == 1 && TeamSide.away.dir == -1)
    #expect(TeamSide.home.other == .away)
}
