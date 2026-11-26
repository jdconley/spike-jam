/// Sets every on-court player's goal, gait, arrival tick and jump each step
/// from the rally situation (spec §4.1): serve receive and release, the
/// serving team's switch, approaches, coverage, blocking, perimeter defense
/// and transition. It keeps no state of its own; everything comes from the
/// game state, so it predicts and replays like the rest of `step`.
///
/// The libero never gets a goal in front of the 3 m line or a jump.
public enum Choreographer {
    public static func update(_ s: inout GameState) {
        switch s.phase {
        case .preServe, .deadBall:
            for side in TeamSide.allCases { toFormation(&s, TeamView(s, side)) }
        case .matchOver:
            for side in TeamSide.allCases {
                let t = TeamView(s, side)
                for (_, id) in t.court { stop(&s, t, id) }
            }
        case .rally:
            guard let c = s.pending else { break }
            let us = TeamView(s, c.team), them = TeamView(s, c.team.other)
            switch c.kind {
            case .receive?:
                receive(&s, us, c)
                switchToDefense(&s, them, against: .left)
            case .set?:
                beforeTheSet(&s, us, c)
                baseDefense(&s, them)
            case .attack?:
                attack(&s, us, c)
                defend(&s, them, c)
            case .dig?:
                dig(&s, us, c)
                baseDefense(&s, them)
            case .serve?, .block?:
                break
            case nil:
                ballDropping(&s, c)
            }
        }
        tidyJumps(&s)
    }

    // MARK: Formations

    /// Each on-court player's spot before the serve.
    static func formationSpot(_ t: TeamView, _ z: Zone) -> LocalSpot {
        t.serving ? Formations.servingSpot(z)
            : Formations.receiveSpot(z, system: t.lineup.system, rotation: t.lineup.rotation)
    }

    static func toFormation(_ s: inout GameState, _ t: TeamView) {
        for (z, id) in t.court { go(&s, t, id, formationSpot(t, z), .run) }
    }

    /// Everyone is close to their spot and both line-ups are legal where
    /// the players actually stand.
    static func formationReady(_ s: GameState) -> Bool {
        for side in TeamSide.allCases {
            let t = TeamView(s, side)
            var spots: [Zone: LocalSpot] = [:]
            for (z, id) in t.court {
                let pos = s.motion[id]!.pos
                if (pos - t.world(formationSpot(t, z))).length > Tuning.formationTolerance { return false }
                spots[z] = t.local(pos)
            }
            if !Overlap.violations(spots, isServing: t.serving).isEmpty { return false }
        }
        return true
    }

    static func snapToFormation(_ s: inout GameState) {
        for side in TeamSide.allCases {
            let t = TeamView(s, side)
            for (z, id) in t.court {
                s.motion[id]!.pos = t.world(formationSpot(t, z))
                s.motion[id]!.vel = .zero
            }
        }
    }

    // MARK: Serve receive

    /// The serve is in the air toward `t`: the passer goes to the ball, the
    /// other passers shade toward it, the setter releases to the target and
    /// the hitters release to their approach spots.
    static func receive(_ s: inout GameState, _ t: TeamView, _ c: PendingContact) {
        let landing = t.local(ballEnd(s).xz)
        let passers = Formations.passers(t.lineup, roster: t.roster)
        let target = t.local(Court.setterTarget(team: t.side).xz)
        let live = t.live(s)
        for (z, id) in t.court {
            if id == c.athlete {
                go(&s, t, id, reach(t.local(s.motion[id]!.pos), landing, Tuning.passReach), .run)
            } else if id == t.setter {
                go(&s, t, id, target, .run)
            } else if passers.contains(id) {
                let spot = formationSpot(t, z)
                var shade = LocalSpot(d: (landing.d - spot.d) * Tuning.passShade, l: (landing.l - spot.l) * Tuning.passShade)
                let len = (shade.d * shade.d + shade.l * shade.l).squareRoot()
                if len > Tuning.passShadeMax { shade = LocalSpot(d: shade.d * Tuning.passShadeMax / len, l: shade.l * Tuning.passShadeMax / len) }
                go(&s, t, id, LocalSpot(d: spot.d + shade.d, l: spot.l + shade.l), .shuffle)
            } else {
                go(&s, t, id, t.approachStart(id, live), .run)
            }
        }
    }

    // MARK: Offense

    /// A pass or dig is in the air toward `c.athlete`, who will set: the
    /// setter goes to where the ball will be, and every hitter with a live
    /// call (front row and back) gets to that play's approach spot and times
    /// the approach for its set. Calls the pass took away aren't run.
    static func beforeTheSet(_ s: inout GameState, _ t: TeamView, _ c: PendingContact) {
        let contact = t.local(ballEnd(s).xz)
        if let setter = c.athlete { go(&s, t, setter, contact, .run) }
        for (h, call) in t.live(s) where h != c.athlete && call != .dump {
            let attackTick = c.tick + ticks(PlayBook.spec(call).setDuration * s.settings.tempo.flightScale)
            approach(&s, t, h, PlayBook.approachStart(call), t.takeoff(call, s), attackTick: attackTick)
        }
    }

    /// The set is in the air to `c.athlete`: they approach and jump to meet
    /// it, the other front-row hitters fake their approaches, and everyone
    /// else covers the hitter.
    static func attack(_ s: inout GameState, _ t: TeamView, _ c: PendingContact) {
        guard let hitter = c.athlete, let ball = s.ball else { return }
        let live = t.live(s)
        let play = s.notes.play ?? live.first { $0.0 == hitter }?.1 ?? .four
        let takeoff = BaseSpots.takeoff(PlayBook.spec(play).lane, setPoint: ballEnd(s), team: t.side)
        approach(&s, t, hitter, PlayBook.approachStart(play), takeoff, attackTick: c.tick)
        // The jump peaks on the contact; a set quicker than half a jump
        // shortens it rather than moving the peak.
        let setTick = Int((ball.startTime * Double(Tuning.stepsPerSecond)).rounded())
        let start = max(setTick, c.tick - Tuning.attackJumpTicks / 2)
        s.motion[hitter]!.jump = Jump(startTick: start, durationTicks: 2 * (c.tick - start), height: Tuning.attackJumpHeight)

        let setter = s.lastTouch
        let runs = live.filter { $0.0 != hitter && $0.0 != setter && $0.1 != .dump }
        let decoys = runs.map(\.0)
        for (d, call) in runs {
            approach(&s, t, d, PlayBook.approachStart(call), t.takeoff(call, s), attackTick: c.tick)
        }
        // Coverage: an arc behind the takeoff, matched left to right.
        let covering = t.court.map(\.id).filter { $0 != hitter && !decoys.contains($0) }
            .sorted { t.local(s.motion[$0]!.pos).l < t.local(s.motion[$1]!.pos).l }
        let n = covering.count
        for (i, id) in covering.enumerated() {
            let spread: Float = 1.2            // radians either side of straight back
            let angle = n == 1 ? 0 : -spread + 2 * spread * Float(i) / Float(n - 1)
            let r = Tuning.coverageRadius
            var spot = LocalSpot(d: takeoff.d + r * cosine(angle), l: takeoff.l + r * sine(angle))
            spot.d = max(spot.d, 0.6)
            spot.l = min(max(spot.l, -4.8), 4.8)
            go(&s, t, id, spot, .run)
        }
    }

    /// A hitter waits on their approach spot, then approaches so they reach
    /// the takeoff with half a jump to go before `attackTick`.
    static func approach(_ s: inout GameState, _ t: TeamView, _ id: AthleteID, _ start: LocalSpot,
                         _ takeoff: LocalSpot, attackTick: Int) {
        let takeoffTick = attackTick - Tuning.attackJumpTicks / 2
        if Double(takeoffTick - s.tick) * Tuning.dt <= Tuning.approachTime {
            go(&s, t, id, takeoff, .approach, arriveBy: takeoffTick)
        } else {
            go(&s, t, id, start, transitionGait(t.local(s.motion[id]!.pos), start))
        }
    }

    // MARK: Defense

    /// The serving team switches into its defensive roles as the serve is
    /// struck: setter or opposite right, middles in the middle, outsides
    /// left, the libero in left back.
    static func switchToDefense(_ s: inout GameState, _ t: TeamView, against lane: AttackLane) {
        let p = BaseSpots.perimeter(against: lane)
        for (id, role) in t.roles { go(&s, t, id, p[role], .run) }
    }

    /// Before the other team sets: blockers spread on the net, the back row
    /// in base, both leaning toward the hitter the team reads.
    static func baseDefense(_ s: inout GameState, _ t: TeamView) {
        let read = DefenseAI.readTarget(s, defending: t.side)
        let defense = read == nil ? 0 : DefenseAI.averageDefense(s, t.side)
        let base = read.map { DefenseAI.shift(BaseSpots.base, toward: $0, defense: defense) } ?? BaseSpots.base
        for (id, role) in t.roles where !airborne(s, id) {
            var spot = base[role]
            if role.isFront, let l = read { spot = DefenseAI.lean(spot, toward: l, defense: defense) }
            go(&s, t, id, spot, role.isFront ? transitionGait(t.local(s.motion[id]!.pos), spot) : .run)
        }
    }

    /// The other team's set is in the air: perimeter defense against the
    /// hitter's lane, with the blockers shuffling along the net to the ball
    /// and jumping to peak on the attack.
    static func defend(_ s: inout GameState, _ t: TeamView, _ c: PendingContact) {
        guard let hitter = c.athlete else { return }
        let attacker = TeamView(s, c.team)
        let lane = s.notes.play.map { PlayBook.spec($0).lane } ?? attacker.lane(hitter)
        // The back row shifts toward the read, right or wrong.
        var p = BaseSpots.perimeter(against: lane)
        if let l = DefenseAI.readTarget(s, defending: t.side) {
            p = DefenseAI.shift(p, toward: l, defense: DefenseAI.averageDefense(s, t.side))
        }
        let blockRoles = BaseSpots.blockers(against: lane)
        let block = BaseSpots.blockSpot(against: ballEnd(s), defending: t.side)
        for (id, role) in t.roles {
            guard let k = blockRoles.firstIndex(of: role) else {
                go(&s, t, id, p[role], .run)
                continue
            }
            // The first blocker lines up on the ball; the second closes
            // beside them on the inside.
            var spot = block
            if k > 0 { spot.l -= (block.l >= 0 ? 1 : -1) * 0.8 }
            let pos = t.local(s.motion[id]!.pos)
            go(&s, t, id, spot, abs(pos.l - spot.l) > 2 ? .run : .shuffle)
            // A human's blocker jumps when they tap, not before.
            if s.notes.block?.athlete == id { continue }
            let start = c.tick - Tuning.blockJumpTicks / 2
            s.motion[id]!.jump = Jump(startTick: start, durationTicks: Tuning.blockJumpTicks, height: Tuning.blockJumpHeight)
        }
    }

    /// The other team's attack is coming down on `t`: the digger goes to the
    /// ball, the setter releases to the target, and the front row transitions
    /// off the net to their approach spots once they've landed.
    static func dig(_ s: inout GameState, _ t: TeamView, _ c: PendingContact) {
        let landing = t.local(ballEnd(s).xz)
        let target = t.local(Court.setterTarget(team: t.side).xz)
        let live = t.live(s)
        for (z, id) in t.court {
            if id == c.athlete {
                go(&s, t, id, reach(t.local(s.motion[id]!.pos), landing, Tuning.digReach), .run)
            } else if id == t.setter {
                go(&s, t, id, target, .run)
            } else if z.isFrontRow && !airborne(s, id) {
                let start = t.approachStart(id, live)
                go(&s, t, id, start, transitionGait(t.local(s.motion[id]!.pos), start))
            }
        }
    }

    /// The ball will land or die: the nearest player on the side it lands
    /// lunges for it; everyone else holds.
    static func ballDropping(_ s: inout GameState, _ c: PendingContact) {
        guard s.ball != nil else { return }
        let end = ballEnd(s)
        guard end.y < 0.5 else { return }                      // a net ball or a shank in the air
        for side in TeamSide.allCases {
            let t = TeamView(s, side)
            let landing = t.local(end.xz)
            guard (0.3...9).contains(landing.d) && abs(landing.l) <= 4.5 else { continue }
            let eligible = t.court.map(\.id).filter { $0 != t.libero || landing.d >= 3 }
            guard let nearest = eligible.min(by: {
                (s.motion[$0]!.pos - end.xz).length < (s.motion[$1]!.pos - end.xz).length
            }) else { continue }
            if (s.motion[nearest]!.pos - end.xz).length < 3 {
                go(&s, t, nearest, reach(t.local(s.motion[nearest]!.pos), landing, Tuning.digReach), .dive)
            }
        }
    }

    // MARK: Helpers

    /// Sets a goal. The libero's goal never comes in front of the 3 m line.
    static func go(_ s: inout GameState, _ t: TeamView, _ id: AthleteID, _ spot: LocalSpot, _ gait: Gait,
                   arriveBy: Int? = nil) {
        var spot = spot
        if id == t.libero { spot.d = max(spot.d, liberoMinDepth) }
        s.motion[id]!.retarget(t.world(spot), gait, arriveBy)
    }

    /// The libero stays behind the 3 m line.
    static let liberoMinDepth: Float = 3.0

    /// Stands still where they are (a libero in front of the 3 m line walks
    /// back behind it).
    static func stop(_ s: inout GameState, _ t: TeamView, _ id: AthleteID) {
        go(&s, t, id, t.local(s.motion[id]!.pos), .stand)
    }

    /// The spot `reach` metres short of `target` along the way from `from`
    /// (or `from` itself when already that close).
    static func reach(_ from: LocalSpot, _ target: LocalSpot, _ reach: Float) -> LocalSpot {
        let dd = target.d - from.d, dl = target.l - from.l
        let dist = (dd * dd + dl * dl).squareRoot()
        guard dist > reach else { return from }
        let k = (dist - reach) / dist
        return LocalSpot(d: from.d + dd * k, l: from.l + dl * k)
    }

    /// Backpedal for a short move away from the net, run otherwise.
    static func transitionGait(_ from: LocalSpot, _ to: LocalSpot) -> Gait {
        let dd = to.d - from.d, dl = to.l - from.l
        let dist = (dd * dd + dl * dl).squareRoot()
        return dd > 0.5 && dd > abs(dl) && dist < 4 ? .backpedal : .run
    }

    static func airborne(_ s: GameState, _ id: AthleteID) -> Bool {
        s.motion[id]?.jump?.isAirborne(atTick: s.tick) ?? false
    }

    /// The current flight's end point.
    static func ballEnd(_ s: GameState) -> Vec3 {
        guard let b = s.ball else { return .zero }
        return b.position(at: b.endTime)
    }

    /// Finished jumps are cleared; the libero never jumps.
    static func tidyJumps(_ s: inout GameState) {
        for id in s.motion.keys {
            if let j = s.motion[id]!.jump, j.endTick < s.tick { s.motion[id]!.jump = nil }
        }
        for side in TeamSide.allCases {
            let libero = s.lineups[side.rawValue].libero
            if s.motion[libero]?.jump != nil { s.motion[libero]!.jump = nil }
        }
    }

    static func sine(_ x: Float) -> Float {
        // Taylor series, plenty for |x| ≤ 1.6 and free of Foundation.
        let x2 = x * x
        return x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72))))
    }

    static func cosine(_ x: Float) -> Float {
        let x2 = x * x
        return 1 - x2 / 2 * (1 - x2 / 12 * (1 - x2 / 30 * (1 - x2 / 56)))
    }
}

/// One team as the choreographer sees it.
struct TeamView {
    let side: TeamSide
    let lineup: Lineup
    let roster: Roster
    let serving: Bool
    /// The six on court, by zone.
    let court: [(zone: Zone, id: AthleteID)]
    /// The pass quality this team's live calls are judged off: the pass it
    /// is setting from, or 1 while the ball is on its way.
    let passQuality: Float

    init(_ s: GameState, _ side: TeamSide) {
        self.side = side
        lineup = s.lineups[side.rawValue]
        roster = s.rosters[side.rawValue]
        serving = s.isServing(side)
        let l = s.lineups[side.rawValue], serves = s.isServing(side)
        court = Zone.allCases.map { ($0, l.occupant($0, isServing: serves)) }
        let setting = s.pending.map { $0.team == side && ($0.kind == .set || $0.kind == .attack) } ?? false
        passQuality = setting ? s.notes.passQuality : 1
    }

    var libero: AthleteID { lineup.libero }
    var setter: AthleteID { lineup.settingSetter(isServing: serving) }

    func zone(_ id: AthleteID) -> Zone? { court.first { $0.id == id }?.zone }

    /// The lane `id` attacks from by default, from where they are in the rotation.
    func lane(_ id: AthleteID) -> AttackLane {
        BaseSpots.defaultLane(for: roster[id].position, frontRow: zone(id)?.isFrontRow ?? false)
    }

    /// Where `id` starts an approach: for their live call if they have one,
    /// else for their default lane.
    func approachStart(_ id: AthleteID, _ live: [(AthleteID, PlayCall)]) -> LocalSpot {
        if let call = live.first(where: { $0.0 == id && $0.1 != .dump })?.1 { return PlayBook.approachStart(call) }
        return BaseSpots.approachStart(lane(id))
    }

    /// Who runs which play now: the live calls off `passQuality`.
    func live(_ s: GameState) -> [(AthleteID, PlayCall)] {
        liveCalls(s, team: side, passQuality: passQuality)
    }

    /// Where a hitter takes off for `call`'s set.
    func takeoff(_ call: PlayCall, _ s: GameState) -> LocalSpot {
        BaseSpots.takeoff(PlayBook.spec(call).lane, setPoint: PlayBook.setPoint(call, team: side, net: s.settings.gameType.netHeight),
                          team: side)
    }

    func world(_ spot: LocalSpot) -> Vec2 { LocalFrame.toWorld(spot, team: side) }
    func local(_ v: Vec2) -> LocalSpot { LocalFrame.toLocal(v, team: side) }

    /// Each player's perimeter role: by row, outsides left, middles middle,
    /// setter or opposite right; in the back row the libero takes left back
    /// and the outside plays middle back (left back when the libero is off).
    var roles: [(id: AthleteID, role: PerimeterRole)] {
        let liberoOn = court.contains { $0.id == libero }
        return court.map { z, id in
            let role: PerimeterRole
            switch (z.isFrontRow, roster[id].position) {
            case (true, .outside): role = .leftFront
            case (true, .middle): role = .middleFront
            case (true, _): role = .rightFront
            case (false, .libero): role = .leftBack
            case (false, .outside): role = liberoOn ? .middleBack : .leftBack
            case (false, .middle): role = .middleBack
            case (false, _): role = .rightBack
            }
            return (id, role)
        }
    }
}

extension Motion {
    /// A new goal in one write, so the choreographer touches each player's
    /// motion once per step.
    mutating func retarget(_ goal: Vec2, _ gait: Gait, _ arriveBy: Int?) {
        self.goal = goal
        self.gait = gait
        arriveByTick = arriveBy
    }
}

extension PerimeterRole {
    var isFront: Bool { self == .leftFront || self == .middleFront || self == .rightFront }
}
