/// A stand-in for a human's timing, for tuning and tests (`spikesim
/// --human`): it claims touches nobody owns and gives their timing grade
/// directly, without inputs. Real humans play through `PlayerInput`s and
/// `HumanTouch`; the AI makes every touch nobody plays.
public protocol TouchSource: Sendable {
    /// The human's timing grade for this touch, 0...1, or nil when it isn't a
    /// human's touch (the AI plays it).
    func quality(for c: PendingContact, _ s: GameState, rng: inout SeededRNG) -> Float?
}

/// How a block touch comes out.
public enum BlockOutcome: String, Codable, Sendable {
    /// Straight back down on the hitter's side: a point to the blockers.
    case stuff
    /// Up off the hands on the blockers' side, for a dig.
    case soft
    /// Off the hands and out: a point to the hitter.
    case tool
}

/// The rally engine (spec §4.3, §4.9). Every touch is rolled by `TouchModel`
/// from the toucher's traits or a human's timing, the ball coming in, the
/// situation and the RNG; the setter and the defense read decide like
/// people; the choreographer moves everyone around it.
enum Rally {
    // MARK: Serve

    /// The line-ups are ready: a bot serves at once; a human's server waits
    /// for the toss (`Tuning.serveClock` at most).
    static func beginServe(_ s: inout GameState, _ events: inout [GameEvent], _ src: (any TouchSource)?) {
        let team = s.score.serving
        let server = s.lineups[team.rawValue].server()
        guard Ownership.owner(for: server, kind: .serve, s) != nil else {
            serve(&s, &events, src)
            return
        }
        s.phase = .rally
        s.pending = PendingContact(kind: .serve, team: team, athlete: server, tick: s.tick + ticks(Tuning.serveClock))
    }

    static func serve(_ s: inout GameState, _ events: inout [GameEvent], _ src: (any TouchSource)?, play: HumanPlay? = nil) {
        let team = s.score.serving
        // Bot teams call their plays; a human's team keeps its calls.
        for side in TeamSide.allCases where !s.settings.humanSides.contains(side) { SetterAI.huddle(&s, team: side) }
        let server = s.lineups[team.rawValue].server()
        // Struck from where the server stands, behind the end line: a jump
        // serve higher than a float.
        let height: Float = s.settings.gameType == .mens ? 3.0 : 2.6
        let from = s.motion[server]!.pos.atHeight(height)
        s.phase = .rally
        s.touchesThisSide = 0
        s.serveTick = s.tick
        s.lastTouch = server
        s.notes.passQuality = 1
        s.notes.play = nil
        s.notes.reads = [nil, nil]
        s.notes.humanReads = [nil, nil]
        s.notes.afterBlock = nil
        events.append(.served(server))

        let r = touch(.serve, server, &s, src, quality: 1, power: 0, slack: 1, blockers: 0, play: play)
        let duration = Tuning.serveDuration * s.settings.tempo.flightScale * s.settings.gameType.paceScale
            * Double(1.2 - 0.4 * r.power)
        if let e = r.error {
            events.append(.erred(.serve, server, e))
            if e == .net {
                launchNetError(&s, from: from, team: team, duration: duration, winner: team.other, reason: .serviceError)
            } else {
                launchCrossing(&s, from: from, to: outSpot(&s, attacking: team), duration: duration)
                s.pending = landing(&s, winner: team.other, reason: .serviceError)
            }
            return
        }
        incoming(.receive, to: team.other, spot: r.target!.xz, from: from, duration: duration, dropReason: .ace,
                 quality: 1 - r.quality, power: r.power, &s, &events)
    }

    // MARK: Touches

    /// Whether contact `c` is played on this step: on its tick, but an owned
    /// one waits for its owner's input, up to `graceWindow` late. A serve is
    /// struck the moment it's released, or missed when the toss comes down
    /// (or never goes up). A block's timing was its jump, so it never waits.
    static func due(_ c: PendingContact, _ s: GameState) -> Bool {
        guard c.owner != nil, let kind = c.kind, kind != .block else { return s.tick >= c.tick }
        let mine = s.inputs(for: c)
        if HumanTouch.striking(c, inputs: mine) != nil { return kind == .serve || s.tick >= c.tick }
        if kind == .serve && HumanTouch.press(mine) == nil { return s.tick >= c.tick }
        return s.tick >= c.tick + nearestTicks(Tuning.graceWindow)
    }

    static func resolve(_ c: PendingContact, _ s: inout GameState, _ events: inout [GameEvent], _ src: (any TouchSource)? = nil) {
        guard let kind = c.kind else {
            endRally(winner: c.team, reason: c.reason ?? .kill, &s, &events)
            return
        }
        var play: HumanPlay?
        if c.owner != nil && kind != .block {
            let p = HumanTouch.play(for: c, inputs: s.inputs(for: c))
            if !p.float { events.append(.judged(c.id, p.grade)) }
            play = p
        }
        switch kind {
        case .receive, .dig: pass(kind, c, &s, &events, src, play)
        case .set: set(c, &s, &events, src, play)
        case .attack: attack(c.athlete!, c.team, call: s.notes.play, setQuality: c.quality, &s, &events, src, play)
        case .block: block(c, &s, &events, src)
        case .serve: serve(&s, &events, src, play: play)
        }
    }

    /// Rolls `id`'s touch. A human's comes from their `play` (or `src`) and is
    /// never nudged; the AI's gets its side's catch-up level.
    static func touch(_ kind: TouchKind, _ id: AthleteID, _ s: inout GameState, _ src: (any TouchSource)?,
                      quality: Float, power: Float, slack: Double, blockers: Int, play: HumanPlay? = nil) -> TouchResult {
        if let play {
            let c = context(kind, id, s, timing: play.timing, quality: quality, power: power, slack: slack, blockers: blockers)
            return HumanTouch.result(play, c, rng: &s.rng, settings: s.settings)
        }
        return roll(kind, id, &s, timing: humanTiming(kind, id, &s, src), quality: quality, power: power, slack: slack,
                    blockers: blockers)
    }

    /// Rolls `id`'s touch with a human's `timing`, or the AI's when nil.
    static func roll(_ kind: TouchKind, _ id: AthleteID, _ s: inout GameState, timing: Float?,
                     quality: Float, power: Float, slack: Double, blockers: Int) -> TouchResult {
        let c = context(kind, id, s, timing: timing, quality: quality, power: power, slack: slack, blockers: blockers)
        return TouchModel.resolve(c, rng: &s.rng, settings: s.settings)
    }

    /// The touch model's view of `id`'s touch, asking `src` whether a human
    /// makes it.
    static func context(_ kind: TouchKind, _ id: AthleteID, _ s: inout GameState, _ src: (any TouchSource)?,
                        quality: Float, power: Float, slack: Double, blockers: Int) -> TouchContext {
        let timing = humanTiming(kind, id, &s, src)
        return context(kind, id, s, timing: timing, quality: quality, power: power, slack: slack, blockers: blockers)
    }

    /// The catch-up nudges a bot's touch and never a human's.
    static func context(_ kind: TouchKind, _ id: AthleteID, _ s: GameState, timing: Float?,
                        quality: Float, power: Float, slack: Double, blockers: Int) -> TouchContext {
        TouchContext(kind: kind, toucher: s.rosters[id.team.rawValue][id], incomingQuality: quality,
                     incomingPower: power, reachSlack: slack, blockersAligned: blockers,
                     catchUp: timing == nil ? nudge(s, id.team) : 0, timing: timing)
    }

    /// The catch-up level of `team`'s bots.
    static func nudge(_ s: GameState, _ team: TeamSide) -> Float {
        CatchUp.level(s)[team] ?? 0
    }

    /// The human's timing for this touch, if a human makes it.
    static func humanTiming(_ kind: TouchKind, _ id: AthleteID, _ s: inout GameState, _ src: (any TouchSource)?) -> Float? {
        guard let src else { return nil }
        var rng = s.rng
        let t = src.quality(for: PendingContact(kind: kind, team: id.team, athlete: id, tick: s.tick), s, rng: &rng)
        s.rng = rng
        return t.map { min(max($0, 0), 1) }
    }

    /// A serve receive or a dig.
    static func pass(_ kind: TouchKind, _ c: PendingContact, _ s: inout GameState, _ events: inout [GameEvent],
                     _ src: (any TouchSource)?, _ play: HumanPlay? = nil) {
        let athlete = c.athlete!, team = c.team
        s.touchesThisSide = 1
        s.lastTouch = athlete
        let from = s.ball!.position(at: s.time)
        let r = touch(kind, athlete, &s, src, quality: c.quality, power: c.power, slack: c.slack, blockers: 0, play: play)
        if let e = r.error {
            events.append(.touched(kind, athlete, quality: 0))
            events.append(.erred(kind, athlete, e))
            if e == .overpass {
                overpass(&s, from: from, team: team, &events)
            } else {
                // A shanked serve is the server's ace; a shanked dig, the
                // hitter's kill.
                shank(&s, from: from, team: team, reason: kind == .receive ? .ace : .kill)
            }
            return
        }
        let q = r.quality
        events.append(.touched(kind, athlete, quality: q))
        let duration = clamp((Tuning.passDurationBase + Tuning.passDurationSpread * Double(1 - q)) * s.settings.tempo.flightScale)
        let to = passTarget(&s, team: team, quality: q)
        let flight = Flight.make(from: from, to: to, duration: duration, startTime: s.time)
        let tick = contactTick(s, flight)
        guard let setter = whoSets(s, team, passer: athlete, at: to.xz, contactTick: tick) else {
            // Nobody can get to the pass in time: it falls to the floor.
            events.append(.outOfReach(.set, team: team))
            launch(&s, Flight.make(from: from, to: to.xz.atHeight(0), duration: duration, startTime: s.time))
            s.pending = landing(&s, winner: team.other, reason: .handlingError)
            return
        }
        launch(&s, flight)
        // A teammate bailing out the setter can only put up a high ball.
        let setting = s.lineups[team.rawValue].settingSetter(isServing: s.isServing(team))
        s.notes.passQuality = setter == setting ? q : min(q, Tuning.bailOutPassQuality)
        let slack = Double(tick - s.tick - (reachTicks(s, setter, to.xz) ?? 0)) * Tuning.dt
        s.pending = PendingContact(kind: .set, team: team, athlete: setter, tick: tick, quality: q, slack: slack)
        // The other side reads where the set is going: a human's read if they
        // made one this rally, else the AI's (unnudged for a human's team).
        let readNudge = s.settings.humanSides.contains(team.other) ? 0 : nudge(s, team.other)
        s.notes.reads[team.other.rawValue] = DefenseAI.read(&s, defending: team.other, nudge: readNudge)
    }

    /// Where a pass of quality `q` goes: the setter target for a perfect
    /// pass, up to `passScatter` metres off it for the worst, kept on the
    /// passing team's court.
    static func passTarget(_ s: inout GameState, team: TeamSide, quality q: Float) -> Vec3 {
        let target = Court.setterTarget(team: team)
        let miss = Tuning.passScatter * max(0, 1 - q)
        var spot = LocalFrame.toLocal(target.xz, team: team)
        spot.d = min(max(spot.d + miss * s.rng.float(in: -1...1), 0.4), 7.0)
        spot.l = min(max(spot.l + miss * s.rng.float(in: -1...1), -4.2), 4.2)
        return LocalFrame.toWorld(spot, team: team).atHeight(target.y)
    }

    /// Who plays the second ball at `point` on `contactTick`: the setting
    /// setter if they can get there, otherwise the quickest teammate who can
    /// (never the libero, nor the passer, who can't touch it twice). Nil if
    /// nobody can.
    static func whoSets(_ s: GameState, _ team: TeamSide, passer: AthleteID, at point: Vec2, contactTick: Int) -> AthleteID? {
        let lineup = s.lineups[team.rawValue]
        let setter = lineup.settingSetter(isServing: s.isServing(team))
        if setter != passer, let eta = reachTicks(s, setter, point), eta <= contactTick - s.tick + reachGraceTicks {
            return setter
        }
        let others = Zone.allCases.map { lineup.occupant($0, isServing: s.isServing(team)) }
            .filter { $0 != setter && $0 != passer && $0 != lineup.libero }
        return quickest(s, others, to: point, contactTick: contactTick)
    }

    static func set(_ c: PendingContact, _ s: inout GameState, _ events: inout [GameEvent], _ src: (any TouchSource)?,
                    _ play: HumanPlay? = nil) {
        let setter = c.athlete!, team = c.team
        s.touchesThisSide = 2
        s.lastTouch = setter
        let from = s.ball!.position(at: s.time)
        let setting = s.lineups[team.rawValue].settingSetter(isServing: s.isServing(team))
        // A human setter's swipe picks the hitter, if that hitter has a live
        // play; otherwise (and for a tap) the AI's choice, never nudged for a
        // human.
        let timing = play?.timing ?? humanTiming(.set, setter, &s, src)
        let level: Float = timing == nil ? nudge(s, team) : 0
        let chosen = play?.hitter.flatMap { h in
            SetterAI.options(s, team: team, passQuality: s.notes.passQuality, setter: setter).first { $0.hitter == h }
        }
        let (hitter, call) = chosen.map { ($0.hitter, $0.call) }
            ?? SetterAI.choose(&s, team: team, passQuality: s.notes.passQuality, setter: setter, nudge: level)
        remember(&s, team: team, hitter: hitter)
        if call == .dump {
            events.append(.setCall(setter, .dump))
            attack(setter, team, call: .dump, setQuality: c.quality, &s, &events, src, play)
            return
        }
        let r = play.map { touch(.set, setter, &s, nil, quality: c.quality, power: 0, slack: c.slack, blockers: 0, play: $0) }
            ?? roll(.set, setter, &s, timing: timing, quality: c.quality, power: 0, slack: c.slack, blockers: 0)
        if let e = r.error {
            events.append(.touched(.set, setter, quality: 0))
            events.append(.erred(.set, setter, e))
            // The whistle goes; the ball drops at the setter's feet.
            let to = Vec3(x: from.x, y: 0, z: from.z)
            launch(&s, Flight.make(from: from, to: to, duration: clamp(Tuning.errorDuration * 0.5), startTime: s.time))
            s.pending = landing(&s, winner: team.other, reason: .handlingError)
            return
        }
        // A teammate bailing out a late setter sets a worse ball.
        let q = setter == setting ? r.quality : min(r.quality, Tuning.backupSetQuality)
        events.append(.touched(.set, setter, quality: q))
        events.append(.setCall(hitter, call))
        s.notes.play = call
        let duration = PlayBook.spec(call).setDuration * s.settings.tempo.flightScale
        let to = setSpot(&s, call, team: team, quality: q)
        launch(&s, Flight.make(from: from, to: to, duration: clamp(duration), startTime: s.time))
        s.pending = PendingContact(kind: .attack, team: team, athlete: hitter, tick: contactTick(s), quality: q)
    }

    /// The set point of `call`, drifted tight to or off the net and along it
    /// by the set's quality.
    static func setSpot(_ s: inout GameState, _ call: PlayCall, team: TeamSide, quality q: Float) -> Vec3 {
        let point = PlayBook.setPoint(call, team: team, net: s.settings.gameType.netHeight)
        var spot = LocalFrame.toLocal(point.xz, team: team)
        let drift = Tuning.setDrift * (1 - q)
        spot.d = max(spot.d + drift * s.rng.float(in: -0.5...1), 0.3)
        spot.l = min(max(spot.l + 0.7 * drift * s.rng.float(in: -1...1), -4.4), 4.4)
        return LocalFrame.toWorld(spot, team: team).atHeight(point.y)
    }

    /// Keeps the team's last two hitters for the setter's repetition penalty.
    static func remember(_ s: inout GameState, team: TeamSide, hitter: AthleteID) {
        var recent = s.notes.recentHitters[team.rawValue]
        recent.append(hitter)
        if recent.count > 2 { recent.removeFirst(recent.count - 2) }
        s.notes.recentHitters[team.rawValue] = recent
    }

    /// `hitter` attacks the ball where it is now: a spike or a tip off a set,
    /// or the setter's dump off the pass.
    static func attack(_ hitter: AthleteID, _ team: TeamSide, call: PlayCall?, setQuality: Float,
                       _ s: inout GameState, _ events: inout [GameEvent], _ src: (any TouchSource)?,
                       _ play: HumanPlay? = nil) {
        s.touchesThisSide = 0
        s.lastTouch = hitter
        s.notes.play = nil
        s.notes.passQuality = 1
        s.notes.reads = [nil, nil]
        let from = s.ball!.position(at: s.time)
        let defending = team.other
        let aligned = blockersAligned(s, at: from, defending: defending)
        let r = touch(.attack, hitter, &s, src, quality: setQuality, power: 0, slack: 1, blockers: aligned, play: play)
        events.append(.touched(.attack, hitter, quality: r.quality))
        let soft = r.tip || call == .dump
        let power = call == .dump ? Tuning.tipPower : r.power
        let flight = soft ? Tuning.tipDuration : Tuning.attackDuration * Double(1.25 - 0.5 * power)
        let duration = flight * s.settings.tempo.flightScale * s.settings.gameType.paceScale
        if let e = r.error {
            events.append(.erred(.attack, hitter, e))
            if e == .net {
                launchNetError(&s, from: from, team: team, duration: duration, winner: defending, reason: .attackError)
            } else {
                launchCrossing(&s, from: from, to: outSpot(&s, attacking: team), duration: duration)
                s.pending = landing(&s, winner: defending, reason: .attackError)
            }
            return
        }
        if r.tip && call != .dump { events.append(.tipped(hitter)) }
        // A human aims it; the AI hits where the defense isn't.
        let spot = r.target?.xz ?? attackTarget(&s, hitter: hitter, from: from, quality: r.quality, soft: soft)
        let playable = 1 - r.quality
        let (ball, after) = aim(.dig, to: defending, spot: spot, from: from, duration: duration, dropReason: .kill,
                                quality: playable, power: power, &s)
        launch(&s, ball)
        if let cross = crossingTick(s, ball), cross < after.tick {
            // The block gets its chance as the ball crosses the net.
            s.notes.afterBlock = after
            let blocker = nearestBlocker(s, to: from, defending: defending)
            s.pending = PendingContact(kind: .block, team: defending, athlete: blocker, tick: cross, quality: playable,
                                       power: power)
        } else {
            s.pending = after
            if after.kind == nil { events.append(.outOfReach(.dig, team: defending)) }
        }
    }

    /// Where an attack goes (team-local to the defense, then world): the
    /// hitter picks among a few spots the biggest gap in the defense, more
    /// often the better the swing, and the aim wanders with a weaker one. A
    /// tip or dump goes short, behind the block.
    static func attackTarget(_ s: inout GameState, hitter: AthleteID, from: Vec3, quality q: Float, soft: Bool) -> Vec2 {
        let defending = hitter.team.other
        let origin = LocalFrame.toLocal(from.xz, team: defending)
        let lineup = s.lineups[defending.rawValue]
        let defenders = Zone.allCases.compactMap { s.motion[lineup.occupant($0, isServing: s.isServing(defending))] }
            .map { LocalFrame.toLocal($0.pos, team: defending) }
        var candidates: [LocalSpot] = []
        for _ in 0..<5 {
            let spot = soft
                ? LocalSpot(d: s.rng.float(in: 0.8...3.0), l: min(max(origin.l + s.rng.float(in: -2.5...2.5), -4.1), 4.1))
                : LocalSpot(d: s.rng.float(in: 1.5...8.4), l: s.rng.float(in: -4.1...4.1))
            candidates.append(spot)
        }
        func gap(_ spot: LocalSpot) -> Float { defenders.map { $0.distance(to: spot) }.min() ?? 9 }
        var aim = candidates[0]
        if s.rng.unit() < Tuning.aimSmart * q { aim = candidates.max { gap($0) < gap($1) }! }
        let wander = Tuning.aimNoise * (1 - q) * (soft ? 0.5 : 1)
        aim.d = min(max(aim.d + wander * s.rng.float(in: -1...1), 0.5), 8.6)
        aim.l = min(max(aim.l + wander * s.rng.float(in: -1...1), -4.3), 4.3)
        return LocalFrame.toWorld(aim, team: defending)
    }

    /// Front-row defenders on the net within reach of the ball along it.
    static func blockersAligned(_ s: GameState, at ball: Vec3, defending: TeamSide) -> Int {
        let l = LocalFrame.toLocal(ball.xz, team: defending).l
        let lineup = s.lineups[defending.rawValue]
        return [Zone.z4, .z3, .z2].filter { z in
            guard let m = s.motion[lineup.occupant(z, isServing: s.isServing(defending))] else { return false }
            let p = LocalFrame.toLocal(m.pos, team: defending)
            return p.d <= 1.2 && abs(p.l - l) <= 0.9
        }.count
    }

    static func nearestBlocker(_ s: GameState, to ball: Vec3, defending: TeamSide) -> AthleteID {
        let lineup = s.lineups[defending.rawValue]
        let front = [Zone.z4, .z3, .z2].map { lineup.occupant($0, isServing: s.isServing(defending)) }
        return front.min { (s.motion[$0]!.pos - ball.xz).length < (s.motion[$1]!.pos - ball.xz).length }!
    }

    // MARK: Blocks

    /// The attack crosses the net: the front row's hands are there or not.
    static func block(_ c: PendingContact, _ s: inout GameState, _ events: inout [GameEvent], _ src: (any TouchSource)?) {
        guard let after = s.notes.afterBlock, let ball = s.ball, let hitter = s.lastTouch else { return }
        s.notes.afterBlock = nil
        let defending = c.team
        let at = ball.position(at: s.time)
        let atL = LocalFrame.toLocal(at.xz, team: defending).l
        let lineup = s.lineups[defending.rawValue]
        var covers: [(id: AthleteID, cover: Float)] = []
        for z in [Zone.z4, .z3, .z2] {
            let id = lineup.occupant(z, isServing: s.isServing(defending))
            guard let m = s.motion[id] else { continue }
            let p = LocalFrame.toLocal(m.pos, team: defending)
            guard p.d <= 1.2 else { continue }
            let jump = min(m.height(atTick: s.tick) / Tuning.blockJumpHeight, 1)
            let cover = blockCover(s.rosters[defending.rawValue][id], ballHeight: at.y, lateral: abs(p.l - atL), jump: jump,
                                   game: s.settings.gameType)
            if cover > 0 { covers.append((id, cover)) }
        }
        let chance = touchChance(covers.map(\.cover), attackQuality: 1 - c.quality, tip: c.power < 0.3)
        guard let primary = covers.max(by: { $0.cover < $1.cover }), s.rng.unit() < chance else {
            s.pending = after
            if after.kind == nil { events.append(.outOfReach(.dig, team: defending)) }
            return
        }
        let aligned = covers.filter { $0.cover >= 0.3 }.count
        // The human's blocker blocks with their jump's timing; anyone else
        // on the block is the AI's.
        var play: HumanPlay?
        if let w = s.notes.block, w.id == c.id, w.athlete == primary.id { play = HumanPlay(grade: w.grade ?? .miss) }
        let r = touch(.block, primary.id, &s, play == nil ? src : nil, quality: c.quality, power: c.power, slack: 1,
                      blockers: aligned, play: play)
        events.append(.touched(.block, primary.id, quality: r.quality))
        applyBlock(outcome(of: r), blocker: primary.id, hitter: hitter, &s, &events)
    }

    /// A human's block jump, at once: it peaks half a block jump later, and
    /// that peak is judged against the attack.
    static func jump(_ input: PlayerInput, _ s: inout GameState, _ events: inout [GameEvent]) {
        guard var w = s.notes.block, s.motion[w.athlete] != nil else { return }
        s.motion[w.athlete]!.jump = Jump(startTick: input.tick, durationTicks: Tuning.blockJumpTicks, height: Tuning.blockJumpHeight)
        let peak = input.time + Double(Tuning.blockJumpTicks / 2) * Tuning.dt
        let grade = TimingJudge.grade(inputTime: peak, contactTime: Double(w.attackTick) * Tuning.dt)
        w.grade = grade
        s.notes.block = w
        events.append(.judged(w.id, grade))
    }

    /// Standing reach (height × 1.33) plus 0.75 of the block jump.
    static func blockReach(_ a: Athlete, game: GameType) -> Float {
        a.heightM * Tuning.standingReach + Tuning.blockJumpShare * blockJump(a, game: game)
    }

    /// The block jump in metres, from the game and the block trait.
    static func blockJump(_ a: Athlete, game: GameType) -> Float {
        Tuning.blockJump(game) * (0.75 + 0.5 * a.traits.block)
    }

    /// How much of the ball a blocker's hands cover, 0...1: how far their
    /// reach (at `jump`, the share of the jump they're at) is above the ball
    /// at the net, times how close along the net they are.
    static func blockCover(_ a: Athlete, ballHeight: Float, lateral: Float, jump: Float, game: GameType) -> Float {
        let reach = a.heightM * Tuning.standingReach + Tuning.blockJumpShare * blockJump(a, game: game) * jump
        let high = min(max((reach - ballHeight) / Tuning.blockCoverSpan, 0), 1)
        let along = min(max(1 - (lateral - Tuning.blockHands) / Tuning.blockFade, 0), 1)
        return high * along
    }

    /// The chance the block touches the ball: each blocker's cover, less a
    /// better swing (hitting around and off the block), much less for a tip.
    static func touchChance(_ covers: [Float], attackQuality: Float, tip: Bool) -> Float {
        let miss = covers.reduce(Float(1)) { $0 * (1 - Tuning.blockTouch * $1) }
        return (1 - miss) * (1.4 - 0.8 * attackQuality) * (tip ? Tuning.blockTipShare : 1)
    }

    static func outcome(of r: TouchResult) -> BlockOutcome {
        if r.error == .tooled { return .tool }
        return r.quality >= Tuning.stuffQuality ? .stuff : .soft
    }

    /// One blocker against an attack, for tests and tuning: nil when the
    /// block doesn't touch it.
    static func rollBlock(_ blocker: Athlete, ballHeight: Float, lateral: Float, jump: Float, attackQuality: Float,
                          attackPower: Float, tip: Bool, rng: inout SeededRNG, settings: MatchSettings) -> BlockOutcome? {
        let cover = blockCover(blocker, ballHeight: ballHeight, lateral: lateral, jump: jump, game: settings.gameType)
        guard rng.unit() < touchChance([cover], attackQuality: attackQuality, tip: tip) else { return nil }
        let c = TouchContext(kind: .block, toucher: blocker, incomingQuality: 1 - attackQuality, incomingPower: attackPower,
                             reachSlack: 1, blockersAligned: 1, catchUp: 0)
        return outcome(of: TouchModel.resolve(c, rng: &rng, settings: settings))
    }

    /// What the ball does off the block.
    static func applyBlock(_ outcome: BlockOutcome, blocker: AthleteID, hitter: AthleteID,
                           _ s: inout GameState, _ events: inout [GameEvent]) {
        let defending = blocker.team, attacking = hitter.team
        let from = s.ball?.position(at: s.time) ?? Vec3(x: 0, y: s.settings.gameType.netHeight + 0.4, z: 0)
        s.lastTouch = blocker
        // A block touch isn't one of the blocking team's three.
        s.touchesThisSide = 0
        s.notes.afterBlock = nil
        switch outcome {
        case .tool:
            events.append(.erred(.block, blocker, .tooled))
            let wide = s.rng.unit() < 0.5
            let side: Float = s.rng.unit() < 0.5 ? -1 : 1
            let out = wide ? LocalSpot(d: s.rng.float(in: 1...8), l: side * s.rng.float(in: 5.2...6.8))
                : LocalSpot(d: s.rng.float(in: 9.6...11), l: s.rng.float(in: -4...4))
            launchCrossing(&s, from: from, to: LocalFrame.toWorld(out, team: defending).atHeight(0),
                           duration: 0.7 * s.settings.tempo.flightScale)
            s.pending = landing(&s, winner: attacking, reason: .kill)
        case .stuff:
            events.append(.erred(.attack, hitter, .blockedStuff))
            let fromL = LocalFrame.toLocal(from.xz, team: attacking)
            let down = LocalSpot(d: s.rng.float(in: 0.4...2.5), l: min(max(fromL.l + s.rng.float(in: -1...1), -4.3), 4.3))
            launch(&s, Flight.make(from: from, to: LocalFrame.toWorld(down, team: attacking).atHeight(0),
                                   duration: clamp(0.35 * s.settings.tempo.flightScale), startTime: s.time))
            s.pending = landing(&s, winner: defending, reason: .block)
        case .soft:
            let up = LocalSpot(d: s.rng.float(in: 1.5...5), l: s.rng.float(in: -3.5...3.5))
            incoming(.dig, to: defending, spot: LocalFrame.toWorld(up, team: defending), from: from,
                     duration: Tuning.softBlockDuration * s.settings.tempo.flightScale, dropReason: .kill,
                     quality: 0.75, power: 0.15, &s, &events)
        }
    }

    // MARK: Balls coming down

    /// A serve, attack or free ball coming down at `spot` on `team`'s court.
    /// Whoever on `team` can get there soonest plays it; if nobody can get
    /// there in time, it drops for `dropReason`.
    static func incoming(_ kind: TouchKind, to team: TeamSide, spot: Vec2, from: Vec3, duration: Double,
                         dropReason: PointReason, quality: Float = 0.5, power: Float = 0.5,
                         _ s: inout GameState, _ events: inout [GameEvent]) {
        let (ball, next) = aim(kind, to: team, spot: spot, from: from, duration: duration, dropReason: dropReason,
                               quality: quality, power: power, &s)
        launch(&s, ball)
        s.pending = next
        if next.kind == nil { events.append(.outOfReach(kind, team: team)) }
    }

    /// The flight down to `spot` and what happens at its end: `kind` by
    /// whoever can reach it, or the ball landing for `dropReason`. Two
    /// passers who'd get there together sometimes leave it to each other.
    static func aim(_ kind: TouchKind, to team: TeamSide, spot: Vec2, from: Vec3, duration: Double, dropReason: PointReason,
                    quality: Float, power: Float, _ s: inout GameState) -> (Flight, PendingContact) {
        let clearance = s.settings.gameType.netHeight + Tuning.netClearanceMargin
        let reachable = Flight.makeClearing(from: from, to: spot.atHeight(Tuning.passContactHeight), duration: clamp(duration),
                                            startTime: s.time, netClearance: clearance)
        let tick = contactTick(s, reachable)
        let reach = kind == .receive ? Tuning.passReach : Tuning.digReach
        let reaction = ticks(kind == .receive ? Tuning.receiveReaction : Tuning.digReaction)
        if let (who, eta, runnerUp) = quickestToBall(s, team, spot, reach: reach, contactTick: tick - reaction) {
            let confused = kind == .receive && runnerUp.map { $0 - eta <= ticks(Tuning.confusionWindow) } == true
                && s.rng.unit() < Tuning.confusionChance
            if !confused {
                let slack = Double(tick - reaction - s.tick - eta) * Tuning.dt
                return (reachable, PendingContact(kind: kind, team: team, athlete: who, tick: tick, quality: quality,
                                                  power: power, slack: slack))
            }
        }
        let drop = Flight.makeClearing(from: from, to: spot.atHeight(0), duration: clamp(duration), startTime: s.time,
                                       netClearance: clearance)
        return (drop, PendingContact(kind: nil, team: team.other, athlete: nil, tick: contactTick(s, drop), reason: dropReason))
    }

    /// The on-court player of `team` who can get within `reach` of `spot`
    /// soonest, if they make it by `contactTick` (with `reachGraceTicks` to
    /// spare), with their arrival in ticks from now and the next quickest's.
    /// Never the setting setter, who saves themselves for the second ball,
    /// and never the libero in front of the 3 m line.
    static func quickestToBall(_ s: GameState, _ team: TeamSide, _ spot: Vec2, reach: Float,
                               contactTick: Int) -> (AthleteID, Int, Int?)? {
        let lineup = s.lineups[team.rawValue]
        let serving = s.isServing(team)
        let setter = lineup.settingSetter(isServing: serving)
        let target = LocalFrame.toLocal(spot, team: team)
        var best: (AthleteID, Int)?
        var second: Int?
        for z in Zone.allCases {
            let id = lineup.occupant(z, isServing: serving)
            guard id != setter, let m = s.motion[id] else { continue }
            let point = Choreographer.reach(LocalFrame.toLocal(m.pos, team: team), target, reach)
            if id == lineup.libero && point.d < Choreographer.liberoMinDepth { continue }
            guard let eta = reachTicks(s, id, LocalFrame.toWorld(point, team: team)) else { continue }
            if best == nil || eta < best!.1 {
                second = best?.1
                best = (id, eta)
            } else if second == nil || eta < second! {
                second = eta
            }
        }
        guard let (id, eta) = best, eta <= contactTick - s.tick + reachGraceTicks else { return nil }
        return (id, eta, second)
    }

    /// Of `ids`, the one who gets to `point` soonest, if they make it by
    /// `contactTick` (with `reachGraceTicks` to spare). Ties go to the first.
    static func quickest(_ s: GameState, _ ids: [AthleteID], to point: Vec2, contactTick: Int) -> AthleteID? {
        var best: (AthleteID, Int)?
        for id in ids {
            guard let eta = reachTicks(s, id, point) else { continue }
            if best == nil || eta < best!.1 { best = (id, eta) }
        }
        guard let (id, eta) = best, eta <= contactTick - s.tick + reachGraceTicks else { return nil }
        return id
    }

    /// Steps for `id` to run to `point` from how they're moving now.
    static func reachTicks(_ s: GameState, _ id: AthleteID, _ point: Vec2) -> Int? {
        guard let m = s.motion[id] else { return nil }
        let cap = Steering.cap(.run, speedTrait: s.rosters[id.team.rawValue][id].traits.speed)
        return Int((Steering.eta(m, to: point, cap: cap) * Double(Tuning.stepsPerSecond)).rounded())
    }

    /// A player this late (0.1 s) still makes the play.
    static var reachGraceTicks: Int { ticks(Tuning.reachGrace) }

    /// The tick a flight crosses the net, if it does after now.
    static func crossingTick(_ s: GameState, _ f: Flight) -> Int? {
        guard abs(f.v0.x) > 1e-6 else { return nil }
        let t = -f.p0.x / f.v0.x
        guard t > 0, Double(t) < f.duration else { return nil }
        return max(s.tick + 1, Int(((f.startTime + Double(t)) * Double(Tuning.stepsPerSecond) - 1e-9).rounded(.up)))
    }

    // MARK: Rally end

    static func endRally(winner: TeamSide, reason: PointReason, _ s: inout GameState, _ events: inout [GameEvent]) {
        s.ball = nil
        s.pending = nil
        s.touchesThisSide = 0
        s.lastTouch = nil
        s.rallyCount += 1
        events.append(.point(winner, reason))
        let result = awardRally(to: winner, score: &s.score, lineups: &s.lineups, settings: s.settings)
        if result.sideOut {
            events.append(.sideOut(winner, rotation: s.lineups[winner.rawValue].rotation))
        }
        events += s.refreshPositions()
        if result.matchWon {
            s.phase = .matchOver
            events.append(.matchWon(winner))
        } else {
            s.phase = .deadBall(untilTick: s.tick + ticks(Tuning.deadBall))
        }
    }

    // MARK: Flights

    static func clamp(_ duration: Double) -> Double { max(duration, Tuning.dt) }

    static func launch(_ s: inout GameState, _ f: Flight, netError: Bool = false) {
        s.ball = f
        s.lastFlightWasNetError = netError
    }

    /// A serve or attack that must clear the net with `netClearanceMargin`.
    static func launchCrossing(_ s: inout GameState, from: Vec3, to: Vec3, duration: Double) {
        let clearance = s.settings.gameType.netHeight + Tuning.netClearanceMargin
        launch(&s, Flight.makeClearing(from: from, to: to, duration: clamp(duration), startTime: s.time, netClearance: clearance))
    }

    /// Into the net on the hitter's own side; the other team wins the point.
    static func launchNetError(_ s: inout GameState, from: Vec3, team: TeamSide, duration: Double,
                               winner: TeamSide, reason: PointReason) {
        let to = Vec3(x: 0.05 * -team.dir, y: 1.2, z: from.z)
        launch(&s, Flight.make(from: from, to: to, duration: clamp(duration), startTime: s.time), netError: true)
        s.pending = landing(&s, winner: winner, reason: reason)
    }

    /// A shanked pass or dig: the ball flies off the court on the handling
    /// team's side, and the other team wins the point for `reason`.
    static func shank(_ s: inout GameState, from: Vec3, team: TeamSide, reason: PointReason) {
        let to = Vec3(x: -team.dir * s.rng.float(in: 3...9), y: 0, z: (s.rng.unit() < 0.5 ? 1 : -1) * s.rng.float(in: 4.8...6.5))
        launch(&s, Flight.make(from: from, to: to, duration: clamp(Tuning.errorDuration * s.settings.tempo.flightScale), startTime: s.time))
        s.pending = landing(&s, winner: team.other, reason: reason)
    }

    /// A pass or dig that floats over the net: a free ball for the other side.
    static func overpass(_ s: inout GameState, from: Vec3, team: TeamSide, _ events: inout [GameEvent]) {
        s.touchesThisSide = 0
        let other = team.other
        let spot = LocalFrame.toWorld(LocalSpot(d: s.rng.float(in: 2...7), l: s.rng.float(in: -3.5...3.5)), team: other)
        incoming(.dig, to: other, spot: spot, from: from, duration: Tuning.freeBallDuration * s.settings.tempo.flightScale,
                 dropReason: .kill, quality: 0.85, power: 0.1, &s, &events)
    }

    // MARK: Helpers

    /// The first step at or after the current flight's end.
    static func contactTick(_ s: GameState) -> Int {
        contactTick(s, s.ball!)
    }

    static func contactTick(_ s: GameState, _ f: Flight) -> Int {
        let end = f.endTime * Double(Tuning.stepsPerSecond)
        return max(s.tick + 1, Int((end - 1e-9).rounded(.up)))
    }

    static func landing(_ s: inout GameState, winner: TeamSide, reason: PointReason) -> PendingContact {
        PendingContact(kind: nil, team: winner, athlete: nil, tick: contactTick(s), reason: reason)
    }

    /// Long or wide of the court `attacking` hits into.
    static func outSpot(_ s: inout GameState, attacking: TeamSide) -> Vec3 {
        let other = attacking.other
        if s.rng.unit() < 0.65 {
            return LocalFrame.toWorld(LocalSpot(d: s.rng.float(in: 9.3...10.5), l: s.rng.float(in: -4.2...4.2)), team: other)
                .atHeight(0)
        }
        let side: Float = s.rng.unit() < 0.5 ? -1 : 1
        return LocalFrame.toWorld(LocalSpot(d: s.rng.float(in: 2...8.5), l: side * s.rng.float(in: 4.8...6)), team: other)
            .atHeight(0)
    }
}
