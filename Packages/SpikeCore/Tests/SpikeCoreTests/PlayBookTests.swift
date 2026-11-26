import Testing
@testable import SpikeCore

private let positions: [Position] = [.outside, .middle, .opposite, .setter, .libero]
private let systems: [OffenseSystem] = [.fiveOne, .sixTwo]

@Test func catalogComplete() {
    #expect(PlayCall.allCases.count == 15)
    for c in PlayCall.allCases {
        #expect(PlayBook.spec(c).call == c)
        #expect(!c.meaning.isEmpty)
        #expect(c.meaning.hasPrefix(c.display.uppercased() + ":") || c.meaning.hasPrefix(c.display + ":"))
    }
    #expect(Set(PlayCall.allCases.map(\.display)).count == PlayCall.allCases.count)
    #expect(PlayCall.allCases.map(\.display) == ["4", "GO", "HUT", "32", "1", "31", "BACK 1", "SLIDE", "5", "RED",
                                                  "DUMP", "PIPE", "BIC", "D", "A"])
    #expect(PlayCall.thirtyOne.meaning == "31: quick in the gap, zone 3")
}

@Test func outsideCalls() {
    for system in systems {
        #expect(PlayBook.calls(for: .outside, frontRow: true, system: system) == [.four, .go, .hut, .thirtyTwo])
        #expect(PlayBook.calls(for: .middle, frontRow: true, system: system) == [.one, .thirtyOne, .backOne, .slide])
        #expect(PlayBook.calls(for: .opposite, frontRow: true, system: system) == [.five, .red])
    }
    // A 5-1 setter in the front row can dump; a 6-2's front-row setter
    // plays opposite.
    #expect(PlayBook.calls(for: .setter, frontRow: true, system: .fiveOne) == [.dump])
    #expect(PlayBook.calls(for: .setter, frontRow: true, system: .sixTwo) == [.five, .red])
}

@Test func backRowOnlyBackCalls() {
    let back: Set<PlayCall> = [.pipe, .bic, .d, .a]
    for p in positions {
        for system in systems {
            let calls = PlayBook.calls(for: p, frontRow: false, system: system)
            #expect(Set(calls).isSubset(of: back), "\(p) \(system): \(calls)")
            for c in calls { #expect(PlayBook.spec(c).lane.isBackRow) }
        }
        #expect(PlayBook.calls(for: .libero, frontRow: true, system: .fiveOne).isEmpty)
        #expect(PlayBook.calls(for: .libero, frontRow: false, system: .fiveOne).isEmpty)
    }
    #expect(PlayBook.calls(for: .outside, frontRow: false, system: .fiveOne).contains(.pipe))
    #expect(PlayBook.calls(for: .opposite, frontRow: false, system: .fiveOne) == [.d])
    // Front-row calls are never back-row attacks.
    for p in positions {
        for c in PlayBook.calls(for: p, frontRow: true, system: .fiveOne) { #expect(!PlayBook.spec(c).lane.isBackRow) }
    }
}

@Test func firstTempoNeedsPass() {
    let needs = Set(PlayCall.allCases.filter { PlayBook.spec($0).needsGoodPass })
    #expect(needs == [.one, .thirtyOne, .backOne, .hut, .bic])
    for c in needs { #expect(PlayBook.spec(c).tempo == .first) }
}

@Test func tempoOrdering() {
    let specs = PlayCall.allCases.map(PlayBook.spec)
    func durations(_ t: SetTempo) -> [Double] { specs.filter { $0.tempo == t }.map(\.setDuration) }
    func apexes(_ t: SetTempo) -> [Float] { specs.filter { $0.tempo == t }.map(\.apex) }
    #expect(durations(.first).max()! < durations(.second).min()!)
    #expect(durations(.second).max()! < durations(.high).min()!)
    #expect(apexes(.first).max()! < apexes(.second).min()!)
    #expect(apexes(.second).max()! < apexes(.high).min()!)
    #expect(durations(.first).allSatisfy { (0.38...0.45).contains($0) })
    #expect(durations(.second).allSatisfy { (0.55...0.65).contains($0) })
    #expect(durations(.high).allSatisfy { (0.85...0.95).contains($0) })
    #expect(apexes(.first).allSatisfy { $0 == 0.5 } && apexes(.second).allSatisfy { $0 == 1.2 } && apexes(.high).allSatisfy { $0 == 2.6 })
    #expect(SetTempo.first.rawValue == 1 && SetTempo.high.rawValue == 3)
}

@Test func playDefaults() {
    let men = PlayBook.defaults(.mens), menBack = PlayBook.defaults(.mens, frontRow: false)
    #expect(men[.outside] == .four && men[.middle] == .one && men[.opposite] == .five)
    #expect(menBack[.outside] == .pipe)
    let women = PlayBook.defaults(.womens), womenBack = PlayBook.defaults(.womens, frontRow: false)
    #expect(women[.outside] == .go && women[.middle] == .slide && women[.opposite] == .red)
    #expect(womenBack[.outside] == .pipe)
    #expect(men[.libero] == nil && menBack[.libero] == nil)
    // Every default is a call that position can make.
    for game in GameType.allCases {
        for front in [true, false] {
            for (p, c) in PlayBook.defaults(game, frontRow: front) {
                #expect(PlayBook.calls(for: p, frontRow: front, system: .fiveOne).contains(c), "\(game) \(p) \(c)")
            }
        }
    }
}

@Test(arguments: TeamSide.allCases, GameType.allCases)
func setPointsOnTheNet(team: TeamSide, game: GameType) {
    for c in PlayCall.allCases {
        let p = PlayBook.setPoint(c, team: team, net: game.netHeight)
        #expect(p.y > game.netHeight, "\(c)")
        #expect(abs(p.z) <= 4.5, "\(c)")
        let local = LocalFrame.toLocal(p.xz, team: team)
        #expect(local.d > 0, "\(c) is on the wrong side")
        if PlayBook.spec(c).lane.isBackRow {
            #expect(BaseSpots.takeoff(PlayBook.spec(c).lane, setPoint: p, team: team).d >= 3.0)
        } else {
            #expect(abs(p.x) <= 1.2, "\(c)")
        }
        // The zone's centre, 1 at the left antenna from the attacking team's view.
        #expect(abs(local.l - PlayBook.zoneCenter(PlayBook.spec(c).netZone)) < 1e-5, "\(c)")
    }
}

@Test func netZones() {
    #expect(PlayBook.zoneCenter(1) == -4.0)
    #expect(PlayBook.zoneCenter(5) == 0)
    #expect(PlayBook.zoneCenter(9) == 4.0)
    func zone(_ c: PlayCall) -> Float { PlayBook.spec(c).netZone }
    #expect(zone(.four) == 1 && zone(.go) == 1 && zone(.hut) == 1)
    #expect(zone(.thirtyOne) == 3 && zone(.thirtyTwo) == 3)       // zone then height
    #expect(zone(.backOne) == 7 && zone(.slide) == 8.5 && zone(.five) == 9 && zone(.red) == 9)
    #expect(zone(.pipe) == 5 && zone(.bic) == 5 && zone(.d) == 8 && zone(.a) == 2)
    // The 1 is right in front of the setter, the Back 1 just behind, and the
    // setter's target sits two-thirds of the way along the net.
    let setter = LocalFrame.toLocal(Court.setterTarget(team: .home).xz, team: .home).l
    let one = PlayBook.zoneCenter(zone(.one)), back = PlayBook.zoneCenter(zone(.backOne))
    #expect(one < setter && setter - one <= 1.0)
    #expect(back > setter && back - setter <= 1.0)
    for c in PlayCall.allCases where c != .dump {
        #expect(PlayBook.spec(c).behindSetter == (PlayBook.zoneCenter(zone(c)) > setter), "\(c)")
    }
    #expect(PlayBook.spec(.slide).oneFoot && PlayCall.allCases.filter { PlayBook.spec($0).oneFoot } == [.slide])
}

@Test func approachesStartBehindTheTakeoff() {
    for c in PlayCall.allCases where c != .dump {
        let spec = PlayBook.spec(c)
        let start = PlayBook.approachStart(c)
        let takeoff = BaseSpots.takeoff(spec.lane, setPoint: PlayBook.setPoint(c, team: .home, net: 2.43), team: .home)
        #expect(start.d > takeoff.d, "\(c)")
        #expect(start.distance(to: takeoff) <= 5.0, "\(c)")
        #expect(abs(start.l) <= 4.8, "\(c)")
    }
}

@Test func combos() {
    #expect(Combo.allCases == [.x, .tandem, .slideRed])
    #expect(Combo.calls(.x) == [.middle: .one, .outside: .thirtyTwo])
    #expect(Combo.calls(.tandem) == [.middle: .one, .opposite: .thirtyTwo])
    #expect(Combo.calls(.slideRed) == [.middle: .slide, .opposite: .red])
    // Tandem: the second hitter's ball is at second tempo, in the 31's spot.
    #expect(PlayBook.spec(.thirtyTwo).tempo == .second)
    #expect(PlayBook.spec(.thirtyTwo).netZone == PlayBook.spec(.thirtyOne).netZone)
}
