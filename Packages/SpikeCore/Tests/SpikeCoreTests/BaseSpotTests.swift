import Testing
@testable import SpikeCore

private let backLanes: [AttackLane] = [.backLeft, .backMiddle, .backRight]
private let frontLanes: [AttackLane] = [.left, .middle, .right]

private func inCourt(_ s: LocalSpot) -> Bool { (0...9).contains(s.d) && abs(s.l) <= 4.5 }

@Test(arguments: TeamSide.allCases)                           // Review Focus 5
func backRowTakeoffBehindLine(team: TeamSide) {
    for lane in backLanes {
        let center = LocalFrame.toLocal(BaseSpots.defaultSetPoint(lane, team: team).xz, team: team)
        for d in stride(from: Float(0.5), through: 4.0, by: 0.25) {
            for dl: Float in [-1.5, 0, 1.5] {
                let set = LocalFrame.toWorld(LocalSpot(d: d, l: center.l + dl), team: team).atHeight(3.0)
                #expect(BaseSpots.takeoff(lane, setPoint: set, team: team).d >= 3.0, "\(lane) set at d \(d)")
            }
        }
    }
}

@Test(arguments: TeamSide.allCases)
func frontTakeoffNearSet(team: TeamSide) {
    for lane in frontLanes {
        let set = BaseSpots.defaultSetPoint(lane, team: team)
        let t = BaseSpots.takeoff(lane, setPoint: set, team: team)
        let setLocal = LocalFrame.toLocal(set.xz, team: team)
        #expect(t.distance(to: setLocal) <= 1.0)
        #expect(t.d > setLocal.d)                               // behind the ball
        #expect(abs(t.l) <= abs(setLocal.l) + 1e-5)             // and inside it
    }
}

@Test func defaultSetPointsMatchTheCourt() {
    #expect(BaseSpots.defaultSetPoint(.left, team: .home) == Court.attackPoint(.z4, team: .home))
    #expect(BaseSpots.defaultSetPoint(.right, team: .away) == Court.attackPoint(.z2, team: .away))
    let pipe = LocalFrame.toLocal(BaseSpots.defaultSetPoint(.backMiddle, team: .away).xz, team: .away)
    #expect(abs(pipe.d - 3.8) < 1e-5 && abs(pipe.l) < 1e-5)
}

@Test func perimeterShape() {
    let p = BaseSpots.perimeter(against: .left)
    let all = PerimeterRole.allCases.map { p[$0] }
    for s in all { #expect(inCourt(s)) }
    // An attack from their left comes down our right: two blockers there.
    let blockers = all.filter { $0.d <= 0.6 }
    #expect(blockers.count == 2)
    for b in blockers { #expect(b.l > 1.5) }
    #expect(Set(BaseSpots.blockers(against: .left)) == [.rightFront, .middleFront])
    // The off blocker pulls off the net for tips and short shots.
    #expect((2.5...3.5).contains(p.leftFront.d))
    // The libero's left back is the deepest spot on the left.
    let left = all.filter { $0.l < 0 }
    #expect(left.max { $0.d < $1.d } == p.leftBack)

    // Mirror: an attack from their right comes down our left, and the
    // libero still plays left back, now on the line.
    let r = BaseSpots.perimeter(against: .right)
    for s in PerimeterRole.allCases.map({ r[$0] }) { #expect(inCourt(s)) }
    #expect(r.leftFront.d <= 0.6 && r.middleFront.d <= 0.6 && r.leftFront.l < -1.5)
    #expect((2.5...3.5).contains(r.rightFront.d))
    #expect(Set(BaseSpots.blockers(against: .right)) == [.leftFront, .middleFront])

    // A middle attack: the middle blocks, the pins pull off.
    let m = BaseSpots.perimeter(against: .middle)
    #expect(m.middleFront.d <= 0.6 && abs(m.middleFront.l) < 1)
    #expect(m.leftFront.d > 1.5 && m.rightFront.d > 1.5)
    for lane in AttackLane.allCases {
        let q = BaseSpots.perimeter(against: lane)
        for role in PerimeterRole.allCases { #expect(inCourt(q[role])) }
        #expect(q.leftBack.d >= 3.0)                            // the libero's spot
    }
}

@Test func blockSpotAlignsWithTheSet() {
    for team in TeamSide.allCases {
        // The other team sets its left: it arrives on our right.
        let set = Court.attackPoint(.z4, team: team.other)
        let b = BaseSpots.blockSpot(against: set, defending: team)
        #expect(abs(b.d - 0.45) < 1e-5)
        #expect(abs(b.l - 3.5) < 1e-4)
        let w = LocalFrame.toWorld(b, team: team)
        #expect(abs(w.z - set.z) < 1e-4)
    }
}

@Test func approachStartsBehindTakeoff() {
    for lane in AttackLane.allCases {
        let set = BaseSpots.defaultSetPoint(lane, team: .home)
        let t = BaseSpots.takeoff(lane, setPoint: set, team: .home)
        let s = BaseSpots.approachStart(lane)
        #expect((2.5...4.0).contains(s.distance(to: t)), "\(lane)")
        #expect(s.d > t.d)                                      // approaching toward the net
        #expect(s.d > 0 && s.d <= 9)                            // on our own court's length
        if abs(t.l) > 1 { #expect((s.l > 0) == (t.l > 0)) }      // the same side of the court
    }
}

@Test func defaultLanes() {
    #expect(BaseSpots.defaultLane(for: .outside, frontRow: true) == .left)
    #expect(BaseSpots.defaultLane(for: .middle, frontRow: true) == .middle)
    #expect(BaseSpots.defaultLane(for: .opposite, frontRow: true) == .right)
    #expect(BaseSpots.defaultLane(for: .setter, frontRow: true) == .right)
    #expect(BaseSpots.defaultLane(for: .outside, frontRow: false) == .backMiddle)
    #expect(BaseSpots.defaultLane(for: .opposite, frontRow: false) == .backRight)
    #expect(AttackLane.left.zone == .z4 && AttackLane.backRight.zone == .z1)
}
