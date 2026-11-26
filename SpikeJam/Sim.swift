// THROWAWAY SPIKE. The rally simulation: one ball, two teams of six, one human on the home side
// who plays every home touch. Pure Swift, no rendering.

import Foundation
import simd

typealias V3 = SIMD3<Float>
typealias V2 = SIMD2<Float>

let gravity: Float = -9.8 * 1.7          // arcade gravity: snappier arcs
let halfLength: Float = 9
let halfWidth: Float = 4.5
let netHeight: Float = 2.43

enum Team: Int {
    case home = 0, away = 1
    var other: Team { self == .home ? .away : .home }
    /// Direction this team attacks along x. Home stands at negative x.
    var dir: Float { self == .home ? 1 : -1 }
}

enum Role: Int, CaseIterable {
    case outside, middle, opposite, setter, libero, outside2
    var short: String {
        switch self {
        case .outside: "OH"; case .middle: "MB"; case .opposite: "OPP"
        case .setter: "S"; case .libero: "L"; case .outside2: "OH2"
        }
    }
}

struct Player {
    let id: Int
    let team: Team
    let role: Role
    var pos: V3
    var target: V2
    var speed: Float = 7.5
    var jumpStart: Double = -10
    var jumpDur: Double = 0.8
    var jumpHeight: Float = 1.0
    var celebrateStart: Double = -10
    var celebrateUntil: Double = -10
    var killStreak = 0
    var digStreak = 0
    var onFire = false
    var xz: V2 { V2(pos.x, pos.z) }
}

enum Kind { case serve, receive, dig, set, attack, block, land }

struct Flight {
    var p0: V3
    var v0: V3
    var t0: Double
    var dur: Double
    var hot = false            // on-fire spike: flame trail

    func pos(_ t: Double) -> V3 {
        let s = Float(t - t0)
        return p0 + v0 * s + 0.5 * V3(0, gravity, 0) * s * s
    }

    static func make(_ from: V3, _ to: V3, dur: Double, t0: Double) -> Flight {
        let d = Float(dur)
        let v = (to - from - 0.5 * V3(0, gravity, 0) * d * d) / d
        return Flight(p0: from, v0: v, t0: t0, dur: dur)
    }

    /// Time (absolute) when the ball, on its way down, passes height y. nil if it never does.
    func timeDescending(through y: Float) -> Double? {
        let a = 0.5 * gravity, b = v0.y, c = p0.y - y
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return nil }
        let r = sqrt(disc)
        let s = max((-b - r) / (2 * a), (-b + r) / (2 * a))
        return s > 0 ? t0 + Double(s) : nil
    }

    /// Time when the ball crosses x = 0, if it does.
    func timeCrossingNet() -> Double? {
        guard abs(v0.x) > 0.01 else { return nil }
        let s = -p0.x / v0.x
        return s > 0 ? t0 + Double(s) : nil
    }
}

/// The next thing that will happen to the ball.
struct Contact {
    var team: Team
    var player: Int         // -1 for a landing
    var kind: Kind
    var time: Double
    var point: V3
    var incoming: Float = 0.5   // quality of the touch before
    var attacker: Int = -1      // for blocks/digs/landings: who hit it
    var power: Float = 0
}

enum Gesture {
    case press(Double)                       // finger down
    case tap(Double)                         // quick release, no movement (time of the press)
    case swipe(Double, dir: V2, power: Float) // ground direction (x, z), 0...1 power
    case aim(Double, target: V2)              // finger lifted over this spot on the court (time of release)
    var time: Double {
        switch self { case .press(let t), .tap(let t): t; case .swipe(let t, _, _): t; case .aim(let t, _): t }
    }
}

enum SimEvent {
    case touch(Kind, team: Team, player: Int, quality: Float, power: Float)
    case judged(String, at: V3, good: Bool)
    case point(Team, reason: String, by: Int)
    case banner(String, hot: Bool, small: Bool = false)
    case fire(Int, on: Bool)
    case bounce(V3)
    case net(V3)
}

struct SetOption {
    let role: Role
    let player: Int
    let point: V3
    let dur: Double
    var available: Bool
}

final class Sim {
    var players: [Player] = []
    var score = [0, 0]
    var now: Double = 0
    var timeScale: Double = 1
    var speedFactor: Double = 1      // >1 slower, <1 faster (flight durations)
    var server: Team = .home
    var flight: Flight?
    var restBall: V3 = .zero
    var pending: Contact?
    var lastToucher: Team = .home
    var events: [SimEvent] = []
    var matchOver = false

    enum Phase { case serveWait(since: Double), rally, dead(until: Double) }
    var phase: Phase = .serveWait(since: 0)

    // Human input state
    var gesture: Gesture?
    var blockGesture: Gesture?
    var tossTime: Double = -10
    var grace: (contact: Contact, deadline: Double)?
    var celebrating: Int = -1
    var winTarget = 15

    init() {
        for team in [Team.home, .away] {
            for role in Role.allCases {
                let id = players.count
                let p = Player(id: id, team: team, role: role, pos: .zero, target: .zero)
                players.append(p)
            }
        }
        startServe(.home)
    }

    func idOf(_ team: Team, _ role: Role) -> Int { team.rawValue * 6 + role.rawValue }
    func teamPlayers(_ t: Team) -> [Int] { (0..<6).map { t.rawValue * 6 + $0 } }

    // MARK: Formations (written for home; mirrored for away)

    enum Formation { case receive, offense, defense, serving }

    /// Outside on the left (-z for home, facing +x), opposite on the right (+z).
    func spot(_ role: Role, _ f: Formation) -> V2 {
        if f == .serving && role == .outside2 { return V2(-9.9, 2.4) }
        let s = rawSpot(role, f)
        return V2(s.x, -s.y)
    }

    func rawSpot(_ role: Role, _ f: Formation) -> V2 {
        switch (f, role) {
        case (.receive, .outside): V2(-4.6, 3.0)
        case (.receive, .middle): V2(-1.4, 0.3)
        case (.receive, .opposite): V2(-2.2, -3.4)
        case (.receive, .setter): V2(-1.2, -1.6)
        case (.receive, .libero): V2(-6.4, -0.6)
        case (.receive, .outside2): V2(-6.2, 2.6)

        case (.offense, .outside): V2(-4.2, 3.6)
        case (.offense, .middle): V2(-2.6, 0.4)
        case (.offense, .opposite): V2(-4.0, -3.6)
        case (.offense, .setter): V2(-0.8, -0.6)
        case (.offense, .libero): V2(-6.5, -0.4)
        case (.offense, .outside2): V2(-6.6, 1.2)

        case (.defense, .outside): V2(-0.7, 3.0)
        case (.defense, .middle): V2(-0.7, 0.0)
        case (.defense, .opposite): V2(-0.7, -3.0)
        case (.defense, .setter): V2(-6.0, -3.0)
        case (.defense, .libero): V2(-7.0, -0.2)
        case (.defense, .outside2): V2(-6.4, 3.0)

        case (.serving, .outside2): V2(-9.9, 2.4)
        case (.serving, let r): rawSpot(r, .defense) * V2(1, 1) + (r == .outside || r == .middle || r == .opposite ? V2(-1.2, 0) : .zero)
        }
    }

    func mirror(_ v: V2, _ t: Team) -> V2 { t == .home ? v : V2(-v.x, -v.y) }
    func mirror(_ v: V3, _ t: Team) -> V3 { t == .home ? v : V3(-v.x, v.y, -v.z) }

    func formation(_ t: Team, _ f: Formation, except: Set<Int> = []) {
        for id in teamPlayers(t) where !except.contains(id) {
            players[id].target = mirror(spot(players[id].role, f), t)
        }
    }

    // MARK: Serve

    func startServe(_ team: Team) {
        server = team
        flight = nil
        pending = nil
        grace = nil
        gesture = nil
        celebrating = -1
        formation(team, .serving)
        formation(team.other, .receive)
        for i in players.indices {
            players[i].pos = V3(players[i].target.x, 0, players[i].target.y)
            players[i].celebrateUntil = -10
        }
        let s = idOf(team, .outside2)
        restBall = players[s].pos + V3(0.3 * team.dir, 1.2, 0)
        phase = .serveWait(since: now)
    }

    var serverID: Int { idOf(server, .outside2) }

    func toss() {
        guard case .serveWait = phase else { return }
        let s = serverID
        let p = players[s]
        let hand = p.pos + V3(0.3 * server.dir, 1.2, 0)
        let tc = now + 0.8 * speedFactor
        let contact = V3(p.pos.x + 0.9 * server.dir, 3.15, p.pos.z)
        flight = Flight.make(hand, contact, dur: tc - now, t0: now)
        players[s].target = V2(contact.x, contact.z)
        players[s].jumpStart = tc - 0.38
        players[s].jumpDur = 0.76
        players[s].jumpHeight = 0.85
        pending = Contact(team: server, player: s, kind: .serve, time: tc, point: contact)
        phase = .rally
        tossTime = now
        gesture = nil
    }

    // MARK: Tick

    func tick(_ realDt: Double) {
        events.removeAll(keepingCapacity: true)
        // Slow-mo on the last moments of a kill.
        var target = 1.0
        if let p = pending, p.kind == .land, p.attacker >= 0, p.time - now < 0.4, p.time - now > -0.2 {
            target = 0.3
        }
        timeScale += (target - timeScale) * min(1, realDt * 14)
        let dt = realDt * timeScale
        now += dt

        switch phase {
        case .serveWait(let since):
            if server == .away && now - since > 1.2 { toss() }
        case .dead(let until):
            if now >= until && !matchOver { startServe(server) }
        case .rally:
            if let g = grace, now > g.deadline { grace = nil }
            while let p = pending, now >= p.time {
                pending = nil
                resolve(p, origin: p.point, at: p.time)
            }
        }
        movePlayers(dt)
    }

    func movePlayers(_ dt: Double) {
        for i in players.indices {
            var p = players[i]
            let d = p.target - p.xz
            let dist = simd_length(d)
            let step = p.speed * (p.onFire && p.role == .libero ? 1.5 : 1) * Float(dt)
            var xz = p.xz
            if dist > 0.001 { xz += d / dist * min(dist, step) }
            var y: Float = 0
            let s = (now - p.jumpStart) / p.jumpDur
            if s >= 0 && s <= 1 { y = Float(4 * s * (1 - s)) * p.jumpHeight }
            if now < p.celebrateUntil {
                let c = now - p.celebrateStart
                y = max(y, Float(abs(sin(c * 7))) * 0.7)
            }
            p.pos = V3(xz.x, y, xz.y)
            players[i] = p
        }
    }

    var ballPos: V3 {
        if let f = flight { return f.pos(min(now, f.t0 + f.dur + 2)) }
        return restBall
    }

    // MARK: Human windows

    /// The home touch the human is about to play, if any.
    var humanContact: Contact? {
        guard let p = pending, p.team == .home, p.kind != .land else { return nil }
        return p
    }

    struct Window { var kind: Kind; var time: Double; var point: V3; var player: Int; var opened: Double }

    /// What the HUD should prompt right now.
    var window: Window? {
        guard let p = pending else { return nil }
        if p.team == .home && p.kind != .land && p.kind != .block {
            return Window(kind: p.kind, time: p.time, point: p.point, player: p.player, opened: windowOpened)
        }
        if p.team == .away && p.kind == .attack && blockerFor >= 0 && players[blockerFor].team == .home {
            let b = players[blockerFor]
            return Window(kind: .block, time: p.time - 0.31, point: V3(b.pos.x, 3.0, b.pos.z), player: blockerFor, opened: windowOpened)
        }
        return nil
    }
    var windowOpened: Double = 0

    func isTapKind(_ k: Kind) -> Bool { k == .receive || k == .dig || k == .block }

    func input(_ g: Gesture) {
        if case .serveWait = phase, server == .home {
            if case .press = g { toss() }
            return
        }
        // Late, within grace: replay the touch with this input.
        if let gr = grace {
            let accept: Bool
            switch g {
            case .press: accept = isTapKind(gr.contact.kind)
            case .tap, .swipe, .aim: accept = !isTapKind(gr.contact.kind)
            }
            if accept {
                grace = nil
                gesture = g
                pending = nil
                resolve(gr.contact, origin: ballPos, at: now, replay: true)
                return
            }
        }
        // Blocking their attack: jump while their set is in the air.
        if case .press = g, let p = pending, p.team == .away, p.kind == .attack,
           blockerFor >= 0, players[blockerFor].team == .home {
            if blockGesture == nil { blockGesture = g; blockJump(blockerFor, at: now) }
            return
        }
        guard let c = humanContact else { return }
        if c.kind == .serve, case .tap(let t) = g, t < tossTime + 0.05 { return }
        let lead = c.kind == .set || c.kind == .attack || c.kind == .serve ? 3.0 : 0.65
        guard g.time >= c.time - lead else { return }
        switch g {
        case .press:
            if isTapKind(c.kind) {
                if gesture == nil { gesture = g }
                if c.kind == .block { blockJump(c.player, at: now) }
            }
        case .tap, .swipe, .aim:
            if !isTapKind(c.kind) { gesture = g }
        }
    }

    /// Keep an aimed spot inside the other team's court.
    func clampAim(_ team: Team, _ v: V2) -> V2 {
        let d = team.dir
        var t = v
        t.x = d > 0 ? min(max(t.x, 0.8), 8.7) : max(min(t.x, -0.8), -8.7)
        t.y = min(max(t.y, -4.3), 4.3)
        return t
    }

    /// Aiming this close to the net is a tip.
    func isTipAim(_ v: V2) -> Bool { abs(v.x) < 2.4 }

    func blockJump(_ id: Int, at t: Double) {
        guard now - players[id].jumpStart > players[id].jumpDur else { return }
        players[id].jumpStart = t
        players[id].jumpDur = 0.72
        players[id].jumpHeight = 0.95
    }

    func timingQuality(_ g: Gesture?, _ c: Contact) -> (Float, String) {
        guard let g else { return (0.2, "MISS") }
        let e = g.time - c.time
        let a = abs(e)
        if a <= 0.06 { return (1.0, "PERFECT") }
        if a <= 0.13 { return (0.75, "GOOD") }
        if a <= 0.25 { return (0.45, e < 0 ? "EARLY" : "LATE") }
        return (0.2, e < 0 ? "WAY EARLY" : "WAY LATE")
    }

    // MARK: Resolve

    func dur(_ d: Double) -> Double { d * speedFactor }

    func resolve(_ c: Contact, origin: V3, at t: Double, replay: Bool = false) {
        let human = c.team == .home && c.kind != .land
        var g = human ? gesture : nil
        if human && c.kind == .block { g = blockGesture; blockGesture = nil }
        if human { gesture = nil }
        if human && g == nil && !replay && c.kind != .block {
            grace = (c, t + 0.1)
        }
        switch c.kind {
        case .serve: doServe(c, g, origin, t, human)
        case .receive, .dig: doPass(c, g, origin, t, human)
        case .set: doSet(c, g, origin, t, human)
        case .attack: doAttack(c, g, origin, t, human)
        case .block: doBlock(c, g, t, human)
        case .land: doLand(c)
        }
    }

    func judge(_ q: (Float, String), _ at: V3) {
        events.append(.judged(q.1, at: at, good: q.0 >= 0.75))
    }

    func doServe(_ c: Contact, _ g: Gesture?, _ origin: V3, _ t: Double, _ human: Bool) {
        lastToucher = c.team
        lastTouchKind = .serve
        let d = c.team.dir
        var target: V2
        var fd: Double
        var q: Float
        var power: Float
        if human {
            let tq = timingQuality(g, c)
            q = tq.0
            if g != nil { judge(tq, origin) }
            switch g {
            case .swipe(_, let dir, let pw)?:
                var dv = dir
                if dv.x * d < 0.3 { dv.x = 0.3 * d }
                dv = simd_normalize(dv)
                let far = origin.x + dv.x * (12 + 4 * pw)
                target = V2(far, origin.z + dv.y * (12 + 4 * pw))
                target.x = d > 0 ? min(max(target.x, 1.5), 8.6) : max(min(target.x, -1.5), -8.6)
                target.y = min(max(target.y, -4.2), 4.2)
                power = pw
                fd = dur(0.95 - 0.35 * Double(pw))
            case .aim(_, let spot)?:
                target = clampAim(c.team, spot)
                target.x = d > 0 ? max(target.x, 1.5) : min(target.x, -1.5)
                power = 0.75
                fd = dur(0.95 - 0.35 * 0.75)
            default:
                target = V2(5.5 * d, Float.random(in: -2...2))
                power = 0.2
                fd = dur(1.15)
                q = max(q, 0.45)
            }
        } else {
            target = V2(Float.random(in: 3...8.4) * d, Float.random(in: -4...4))
            power = Float.random(in: 0.2...0.9)
            fd = dur(1.0 - 0.35 * Double(power))
            q = Float.random(in: 0.5...1)
        }
        // Error: poor quality wanders, can go out or into the net.
        target += V2(Float.random(in: -1...1), Float.random(in: -1...1)) * (1 - q) * 2.6
        var to = V3(target.x, 0, target.y)
        if q <= 0.2 && Float.random(in: 0...1) < 0.35 {
            to = V3(0.05 * -d, 1.2, origin.z)   // into the net
            fd = dur(0.45)
            events.append(.banner("NET!", hot: false))
        }
        flight = Flight.make(origin, to, dur: fd, t0: t)
        events.append(.touch(.serve, team: c.team, player: c.player, quality: q, power: power))
        formation(c.team, .defense)
        planIncoming(defender: c.team.other, kind: .receive, attacker: c.player, power: power)
    }

    /// Ball is flying toward `defender`'s side. Decide who plays it, or that it lands.
    func planIncoming(defender: Team, kind: Kind, attacker: Int, power: Float) {
        guard let f = flight else { return }
        guard let tLand = f.timeDescending(through: 0) else { return }
        let land = f.pos(tLand)
        let onSide = defender == .home ? land.x <= 0.05 : land.x >= -0.05
        let inBounds = abs(land.x) <= halfLength + 0.1 && abs(land.z) <= halfWidth + 0.1
        if !onSide || !inBounds || (land.y > 0.5) {
            pending = Contact(team: defender, player: -1, kind: .land, time: tLand, point: land, attacker: attacker, power: power)
            return
        }
        let contactY: Float = kind == .receive ? 0.85 : 0.55
        let tc = f.timeDescending(through: contactY) ?? tLand
        let cp = f.pos(tc)
        // Who can get there first?
        var best = -1
        var bestETA = Double.infinity
        for id in teamPlayers(defender) {
            let p = players[id]
            if kind == .receive && (p.role == .setter || p.role == .middle) { continue }
            if kind == .dig && now - p.jumpStart < p.jumpDur + 0.1 { continue }   // a blocker in the air
            let reach: Float = p.onFire && p.role == .libero ? 2.6 : 1.4
            let dist = max(0, simd_length(V2(cp.x, cp.z) - p.xz) - reach)
            var eta = Double(dist / (p.speed * (p.onFire && p.role == .libero ? 1.5 : 1)))
            if p.role == .libero { eta -= 0.25 }
            if eta < bestETA { bestETA = eta; best = id }
        }
        let canReach = best >= 0 && bestETA <= (tc - now) + 0.05
        // The AI doesn't dig everything.
        var aiDigs = true
        if defender == .away && kind == .dig {
            let hot = attacker >= 0 && players[attacker].onFire
            let chance = 0.62 - Double(power) * 0.35 - (hot ? 0.25 : 0)
            aiDigs = Double.random(in: 0...1) < chance
        }
        if defender == .away && kind == .receive {
            aiDigs = Double.random(in: 0...1) < 0.93 - Double(power) * 0.15
        }
        if canReach && aiDigs {
            players[best].target = V2(cp.x, cp.z)
            pending = Contact(team: defender, player: best, kind: kind, time: tc, point: cp, attacker: attacker, power: power)
        } else {
            if best >= 0 {   // chase anyway, for drama
                players[best].target = V2(cp.x, cp.z)
            }
            pending = Contact(team: defender, player: -1, kind: .land, time: tLand, point: land, attacker: attacker, power: power)
        }
    }

    func setterSpot(_ t: Team) -> V3 { mirror(V3(-0.8, 2.55, 0.5), t) }

    func doPass(_ c: Contact, _ g: Gesture?, _ origin: V3, _ t: Double, _ human: Bool) {
        var q: Float
        let p = players[c.player]
        let liberoFire = p.role == .libero && p.onFire
        if human {
            let tq = timingQuality(g, c)
            q = tq.0
            if g == nil && !liberoFire {
                if c.kind == .dig {
                    // Whiff: the ball keeps going. (Grace may still save it.)
                    pending = Contact(team: c.team, player: -1, kind: .land,
                                      time: flight?.timeDescending(through: 0) ?? t,
                                      point: flight.map { $0.pos($0.timeDescending(through: 0) ?? t) } ?? origin,
                                      attacker: c.attacker, power: c.power)
                    return
                }
                q = 0.25
            } else if g != nil {
                judge(tq, origin)
            }
            if liberoFire { q = max(q, 0.9) }
        } else {
            q = Float.random(in: c.kind == .receive ? 0.45...1 : 0.3...0.95)
        }
        lastToucher = c.team
        lastTouchKind = c.kind
        // Libero streak
        if p.role == .libero {
            if q >= 0.99 || (!human && q > 0.9) {
                players[c.player].digStreak += 1
                if players[c.player].digStreak == 3 && !players[c.player].onFire { ignite(c.player) }
            } else if !liberoFire { players[c.player].digStreak = 0 }
        }
        if c.kind == .dig && q >= 0.75 {
            events.append(.banner(["PANCAKE!", "DUG IT!", "NOPE!", "SAVED!"].randomElement()!, hot: liberoFire, small: true))
        }
        var target = setterSpot(c.team)
        let err = (1 - q) * 3.2
        target += V3(Float.random(in: -1...0.3) * err, 0, Float.random(in: -1...1) * err)
        // keep it on our side
        if c.team == .home { target.x = min(target.x, -0.4) } else { target.x = max(target.x, 0.4) }
        target.z = min(max(target.z, -4.2), 4.2)
        let fd = dur(0.85 + Double(1 - q) * 0.35)
        // The pass goes up then down to set height.
        flight = Flight.make(origin, target, dur: fd, t0: t)
        events.append(.touch(c.kind, team: c.team, player: c.player, quality: q, power: 0))

        var setter = idOf(c.team, .setter)
        if setter == c.player { setter = idOf(c.team, .opposite) }
        formation(c.team, .offense, except: [c.player])
        players[setter].target = V2(target.x, target.z)
        formation(c.team.other, .defense)
        pending = Contact(team: c.team, player: setter, kind: .set, time: t + fd, point: target, incoming: q)
    }

    func setOptions(_ team: Team, incoming: Float) -> [SetOption] {
        func o(_ r: Role, _ x: Float, _ y: Float, _ z: Float, _ d: Double, _ ok: Bool = true) -> SetOption {
            SetOption(role: r, player: idOf(team, r), point: mirror(V3(x, y, z), team), dur: d, available: ok)
        }
        return [
            o(.outside, -1.1, 3.15, -3.5, 0.78),
            o(.middle, -0.6, 3.0, -0.3, 0.42, incoming >= 0.45),
            o(.opposite, -1.1, 3.15, 3.5, 0.72),
            o(.outside2, -3.4, 3.2, -1.0, 0.68),
        ]
    }

    func setDir(_ r: Role, _ t: Team) -> V2 {
        let v: V2
        switch r {
        case .outside: v = V2(0, -1)
        case .opposite: v = V2(0, 1)
        case .middle: v = V2(1, 0)
        default: v = V2(-1, 0)
        }
        return mirror(v, t)
    }

    func doSet(_ c: Contact, _ g: Gesture?, _ origin: V3, _ t: Double, _ human: Bool) {
        lastToucher = c.team
        lastTouchKind = .set
        let opts = setOptions(c.team, incoming: c.incoming).filter { $0.available && $0.player != c.player }
        var pick = opts[0]
        var tq: (Float, String) = (0.45, "")
        if human {
            tq = timingQuality(g, c)
            if case .swipe(_, let dir, _)? = g {
                // A compass around the setter: toward the net = quick to the middle, along the net = pins, away = pipe.
                pick = opts.max { simd_dot(setDir($0.role, c.team), dir) < simd_dot(setDir($1.role, c.team), dir) }!
            }
            if g == nil { tq.0 = 0.45 } else { judge(tq, origin) }
        } else {
            // AI feeds the hot hand.
            let weights = opts.map { players[$0.player].onFire ? 4.0 : ($0.role == .outside ? 1.6 : 1.0) }
            var r = Double.random(in: 0..<weights.reduce(0, +))
            for (i, w) in weights.enumerated() { if r < w { pick = opts[i]; break }; r -= w }
            tq.0 = Float.random(in: 0.5...1)
        }
        let q = 0.5 * c.incoming + 0.5 * tq.0
        var point = pick.point
        point += V3(Float.random(in: -1...1), 0, Float.random(in: -1...1)) * (1 - q) * 0.9
        let fd = dur(pick.dur)
        flight = Flight.make(origin, point, dur: fd, t0: t)
        events.append(.touch(.set, team: c.team, player: c.player, quality: q, power: 0))
        let h = pick.player
        let tc = t + fd
        players[h].target = V2(point.x - 0.25 * c.team.dir, point.z)
        players[h].jumpStart = tc - 0.42
        players[h].jumpDur = 0.84
        players[h].jumpHeight = 1.15
        // The other side shifts its nearest front-row blocker over.
        let def = c.team.other
        let blockers = [idOf(def, .outside), idOf(def, .middle), idOf(def, .opposite)]
        let b = blockers.min { abs(players[$0].pos.z - point.z) < abs(players[$1].pos.z - point.z) }!
        players[b].target = V2(0.55 * -c.team.dir, point.z)
        blockerFor = b
        pending = Contact(team: c.team, player: h, kind: .attack, time: tc, point: point, incoming: q)
    }

    var blockerFor = -1

    func doAttack(_ c: Contact, _ g: Gesture?, _ origin: V3, _ t: Double, _ human: Bool) {
        lastToucher = c.team
        lastTouchKind = .attack
        let d = c.team.dir
        let hitter = players[c.player]
        var target: V2
        var fd: Double
        var power: Float
        var q: Float
        var tip = false
        if human {
            let tq = timingQuality(g, c)
            q = 0.4 * c.incoming + 0.6 * tq.0
            switch g {
            case .swipe(_, let dir, let pw)?:
                var dv = dir
                if dv.x * d < 0.25 { dv.x = 0.25 * d }
                dv = simd_normalize(dv)
                let reach = 6.5 + 2.5 * pw
                target = V2(origin.x + dv.x * reach, origin.z + dv.y * reach)
                power = 0.35 + 0.65 * pw
                fd = 0.62 - 0.28 * Double(pw)
                judge(tq, origin)
            case .aim(_, let spot)?:
                target = clampAim(c.team, spot)
                if isTipAim(target) {
                    tip = true
                    power = 0.1
                    fd = 0.72
                    judge((tq.0, tq.0 >= 0.75 ? "TIP" : tq.1), origin)
                } else {
                    power = 0.85
                    fd = 0.62 - 0.28 * 0.85
                    judge(tq, origin)
                }
            case .tap?:
                tip = true
                target = V2(1.6 * d, origin.z + Float.random(in: -1.5...1.5))
                power = 0.1
                fd = 0.72
                judge((tq.0, "TIP"), origin)
            default:
                target = V2(Float.random(in: 5...7.5) * d, Float.random(in: -3...3))
                power = 0.15
                fd = 0.95
                q = 0.5
            }
        } else {
            power = hitter.onFire ? 1 : Float.random(in: 0.35...1)
            q = 0.4 * c.incoming + 0.6 * Float.random(in: 0.45...1)
            if Float.random(in: 0...1) < 0.12 {
                tip = true
                target = V2(1.6 * d, origin.z + Float.random(in: -1.5...1.5))
                fd = 0.72
                power = 0.1
            } else {
                target = V2(Float.random(in: 3.5...8.4) * d, Float.random(in: -4.2...4.2))
                fd = 0.62 - 0.28 * Double(power)
            }
        }
        if hitter.onFire { fd *= 0.75; power = min(1, power + 0.2) }
        // Clamp to the court, then let poor quality wander (maybe out).
        target.x = d > 0 ? min(max(target.x, 0.8), 8.7) : max(min(target.x, -0.8), -8.7)
        target.y = min(max(target.y, -4.3), 4.3)
        target += V2(Float.random(in: -1...1), Float.random(in: -1...1)) * (1 - q) * 2.4
        var to = V3(target.x, 0, target.y)
        var fdur = dur(fd)
        if !tip && q < 0.3 && Float.random(in: 0...1) < 0.3 {
            to = V3(0.05 * -d, 1.5, origin.z)   // into the net
            fdur = dur(0.3)
            events.append(.banner("NET!", hot: false))
        }
        var f = Flight.make(origin, to, dur: fdur, t0: t)
        f.hot = hitter.onFire
        flight = f
        events.append(.touch(.attack, team: c.team, player: c.player, quality: q, power: tip ? 0 : power))
        formation(c.team, .defense, except: [c.player])

        // Block at the net?
        let def = c.team.other
        if let tn = f.timeCrossingNet(), blockerFor >= 0, tn < t + fdur {
            let b = blockerFor
            if def == .away {
                // AI blocker jumps on time.
                players[b].jumpStart = tn - 0.36
                players[b].jumpDur = 0.72
                players[b].jumpHeight = 0.95
            }
            pending = Contact(team: def, player: b, kind: .block, time: tn, point: f.pos(tn), attacker: c.player, power: power)
        } else {
            planIncoming(defender: def, kind: .dig, attacker: c.player, power: power)
        }
    }

    func doBlock(_ c: Contact, _ g: Gesture?, _ t: Double, _ human: Bool) {
        guard let f = flight else { return }
        let b = players[c.player]
        let atNet = f.pos(t)
        let inAir = now - b.jumpStart < b.jumpDur
        let reach = netHeight + 0.35 + (inAir ? b.pos.y : 0)
        let lined = abs(atNet.z - b.pos.z) < 0.95
        let blockable = lined && atNet.y < reach && atNet.y > netHeight - 0.2
        let hot = c.attacker >= 0 && players[c.attacker].onFire
        var stuff = false, deflect = false
        if human {
            let tq = timingQuality(g, Contact(team: c.team, player: c.player, kind: .block, time: t - 0.36, point: atNet))
            if g != nil { judge(tq, atNet) }
            if blockable && tq.0 >= 0.75 && Float.random(in: 0...1) < (hot ? 0.25 : 0.5) { stuff = true }
            else if blockable && tq.0 >= 0.75 { deflect = true }
        } else if blockable {
            let r = Float.random(in: 0...1)
            if r < (hot ? 0.05 : 0.14) { stuff = true } else if r < 0.3 { deflect = true }
        }
        let def = c.team
        let att = def.other
        if stuff {
            lastToucher = def
            lastTouchKind = .block
            // Ball goes straight back down on the attacker's side.
            let back = V3(-att.dir * Float.random(in: 0.8...2.5), 0, atNet.z + Float.random(in: -1...1))
            flight = Flight.make(atNet, back, dur: dur(0.42), t0: t)
            events.append(.touch(.block, team: def, player: c.player, quality: 1, power: 1))
            pending = Contact(team: att, player: -1, kind: .land, time: t + dur(0.42), point: back, attacker: c.player, power: 1)
            stuffBlocker = c.player
        } else if deflect {
            lastToucher = def
            lastTouchKind = .block
            let to = V3(def == .home ? Float.random(in: -7 ... -3) : Float.random(in: 3...7), 0, Float.random(in: -3.5...3.5))
            flight = Flight.make(atNet + V3(0, 0.2, 0), to, dur: dur(1.0), t0: t)
            events.append(.touch(.block, team: def, player: c.player, quality: 0.5, power: 0.3))
            events.append(.banner("SOFT BLOCK", hot: false, small: true))
            planIncoming(defender: def, kind: .dig, attacker: c.attacker, power: 0.2)
        } else {
            planIncoming(defender: def, kind: .dig, attacker: c.attacker, power: c.power)
        }
    }

    var stuffBlocker = -1

    func doLand(_ c: Contact) {
        let land = c.point
        events.append(.bounce(land))
        // Little bounce.
        flight = Flight.make(land + V3(0, 0.12, 0), land + V3(Float.random(in: -1.5...1.5), 0.12, Float.random(in: -1.5...1.5)), dur: 0.55, t0: now)
        let inBounds = abs(land.x) <= halfLength + 0.1 && abs(land.z) <= halfWidth + 0.1 && land.y < 0.5
        let sideHome = land.x < 0
        var winner: Team
        var reason: String
        var by = -1
        if land.y >= 0.5 {
            winner = lastToucher.other; reason = "NET!"
        } else if inBounds {
            winner = sideHome ? .away : .home
            if stuffBlocker >= 0 {
                reason = ["ROOF!", "STUFFED!", "DENIED!", "GET THAT OUTTA HERE!"].randomElement()!
                by = stuffBlocker
            } else if c.attacker >= 0 && players[c.attacker].team == winner {
                let a = players[c.attacker]
                if lastTouchKind == .serve && a.id == serverID {
                    reason = "ACE!"
                } else {
                    reason = ["KILL!", "HAMMERED!", "BOOM!", "TOP SHELF!", "CRUSHED IT!"].randomElement()!
                }
                by = c.attacker
            } else {
                reason = "DROPPED IT!"
            }
        } else {
            winner = lastToucher.other
            reason = "OUT!"
        }
        stuffBlocker = -1
        awardPoint(winner, reason: reason, by: by, killer: c.power > 0.3)
    }

    var lastTouchKind: Kind = .serve

    func awardPoint(_ winner: Team, reason: String, by: Int, killer: Bool) {
        score[winner.rawValue] += 1
        // Streaks: the winner's scorer heats up; the loser cools off.
        for id in teamPlayers(winner.other) {
            if players[id].onFire { events.append(.fire(id, on: false)) }
            players[id].onFire = false
            players[id].killStreak = 0
            players[id].digStreak = 0
        }
        var hot = false
        if by >= 0 && players[by].team == winner {
            players[by].killStreak += 1
            if players[by].killStreak == 2 && !players[by].onFire {
                events.append(.banner("HEATING UP…", hot: true, small: true))
            }
            if players[by].killStreak >= 3 && !players[by].onFire { ignite(by) }
            hot = players[by].onFire
            players[by].celebrateStart = now
            players[by].celebrateUntil = now + 1.8
            celebrating = by
            // Teammates mob him.
            for id in teamPlayers(winner) where id != by {
                let off = V2(Float.random(in: -1.2...1.2), Float.random(in: -1.2...1.2))
                players[id].target = players[by].xz + off
            }
        } else {
            celebrating = -1
        }
        events.append(.point(winner, reason: reason, by: by))
        events.append(.banner(reason, hot: hot))
        let a = score[0], b = score[1]
        if (a >= winTarget || b >= winTarget) && abs(a - b) >= 2 {
            matchOver = true
            events.append(.banner(winner == .home ? "YOU WIN!" : "THEY WIN", hot: winner == .home))
        }
        server = winner
        pending = nil
        grace = nil
        phase = .dead(until: now + 2.4)
    }

    func ignite(_ id: Int) {
        players[id].onFire = true
        events.append(.fire(id, on: true))
        events.append(.banner(players[id].role == .libero ? "LIBERO'S ON FIRE!" : "ON FIRE!", hot: true))
    }

    func rematch() {
        score = [0, 0]
        matchOver = false
        for i in players.indices {
            players[i].onFire = false; players[i].killStreak = 0; players[i].digStreak = 0
        }
        startServe(.home)
    }
}
