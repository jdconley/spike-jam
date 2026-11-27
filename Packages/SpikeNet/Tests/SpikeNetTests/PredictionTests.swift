import Dispatch
import Foundation
import SpikeCore
import Testing
@testable import SpikeNet

/// What one networked match showed, for the guest across the network.
struct MatchReport: Sendable {
    /// The guest's own touches it judged, and the host's final grade for each.
    var ownJudged = 0
    var overruled = 0
    /// Own judged events shown later than the step that played them.
    var shownLate = 0
    /// Touch inputs the guest sent and the host took.
    var touchSent = 0
    var touchTaken = 0
    /// The biggest frame-to-frame move of the drawn ball, and of a drawn player.
    var maxBallJump: Float = 0
    var maxPlayerJump: Float = 0
    var corrections = 0
    var replayed = 0
    var converged = false
    var ticks = 0
    var biggestSnapshot = 0
}

/// One match: the hosting phone's own player on home (no delay), the guest on `guestTeam` over
/// `link`, both played by simulated humans; bots fill the other ten spots.
func playMatch(seed: UInt64, link: SimNetwork.Link, guestTeam: TeamSide = .away, pointsToWin: Int = 15, hostSkill: Float = 0.85,
               configure: ((Rig, Rig.Guest, Rig.Guest) -> Void)? = nil) -> (MatchReport, Rig) {
    var settings = MatchSettings()
    settings.seed = seed
    settings.pointsToWin = pointsToWin
    let rig = Rig(settings: settings, seed: seed)
    let local = rig.join(team: .home, link: .perfect, skill: hostSkill, seed: seed)
    let guest = rig.join(team: guestTeam, link: link, skill: 0.85, seed: seed + 1000)
    configure?(rig, local, guest)
    var report = MatchReport()
    // The guest's own touches: when each window opened and the inputs for it.
    var contactTick: [ContactID: Int] = [:]
    var lastInput: [ContactID: Int] = [:]
    var lastBall: Vec3?
    var lastPlayers: [AthleteID: Vec2] = [:]
    var lastJumps = 0
    var lastCorrections = 0
    var lastFlight: Double?
    var lastTime = 0.0
    var predictedTick: [ContactID: Int] = [:]
    guest.onFrame = { g in
        guard let loop = g.loop else { return }
        // The tick the prediction has for each of its own contacts (a correction can move it).
        for c in [loop.predicted.pending, loop.predicted.notes.afterBlock].compactMap({ $0 }) where c.owner == guest.human {
            predictedTick[c.id] = c.tick
        }
        if loop.onInputSent == nil {
            loop.onInputSent = { i in
                guard let c = i.contact else { return }
                report.touchSent += 1
                lastInput[c] = max(lastInput[c] ?? .min, i.tick)
            }
        }
        // The drawn ball and players, as the app draws them.
        let t = loop.previous.time + (loop.current.time - loop.previous.time) * loop.alpha
        let ball = loop.current.ball.map { $0.position(at: min(max(t, $0.startTime), $0.endTime)) }
        var players: [AthleteID: Vec2] = [:]
        for (id, m) in loop.current.motion {
            let a = loop.previous.motion[id]?.pos ?? m.pos
            players[id] = a + (m.pos - a) * Float(loop.alpha)
        }
        // Skip the opening (the clock settling) and any clock jump. A touch made since the last
        // frame can start the ball somewhere else (SpikeCore's flights, solo too), so those frames
        // don't count; a correction to a flight already under way does.
        let corrected = loop.corrections != lastCorrections
        let flight = loop.predicted.ball?.startTime
        let settled = rig.now > 2 && loop.clockJumps == lastJumps
        let touchedSince = flight.map { $0 > lastTime } ?? true
        if settled, let a = lastBall, let b = ball, flight == lastFlight || (corrected && !touchedSince) {
            report.maxBallJump = max(report.maxBallJump, (b - a).length)
        }
        lastTime = t
        if settled {
            for (id, p) in players { if let q = lastPlayers[id] { report.maxPlayerJump = max(report.maxPlayerJump, (p - q).length) } }
        }
        lastJumps = loop.clockJumps
        lastCorrections = loop.corrections
        lastFlight = flight
        lastBall = ball
        lastPlayers = players
    }
    rig.runMatch()
    let loop = guest.loop!
    var judged: Set<ContactID> = []
    var windows: [ContactID: [(Int, Int)]] = [:]
    for (tick, e) in guest.events {
        switch e {
        // A correction can renumber the contacts after it, so a contact is the guest's if the
        // newest window for it was.
        case .window(let id, _, let owner, let at):
            if owner == guest.human {
                contactTick[id] = at
                windows[id, default: []].append((tick, at))
            } else {
                contactTick[id] = nil
            }
        case .judged(let id, let grade) where contactTick[id] != nil:
            // The first judgment is the one the guest saw at once; a correction may judge again.
            guard judged.insert(id).inserted else {
                continue
            }
            report.ownJudged += 1
            if rig.hostGrades[id] != grade {
                report.overruled += 1
            }
            // Shown on the step that played it: the contact's, the input's if that came later,
            // or for a miss the end of the grace window. Two steps of leeway, for a contact a
            // correction moved between frames; waiting for the host would be a round trip and the
            // buffer, 8 steps or more.
            let grace = Int((Tuning.graceWindow * Double(Tuning.stepsPerSecond)).rounded())
            let at = predictedTick[id] ?? contactTick[id]!
            let due = max(at + (grade == .miss ? grace : 0), (lastInput[id] ?? .min) + 1)
            if tick > due + 2 {
                report.shownLate += 1
                print("late judged seed \(seed) team \(guestTeam) \(id.raw) \(grade): shown at \(tick), windows \(windows[id]!), input \(lastInput[id] ?? -1)")
            }
        default:
            break
        }
    }
    report.touchTaken = rig.server.stats[guest.human]?.touchInputs ?? 0
    report.corrections = loop.corrections
    report.replayed = loop.replayedSteps
    report.ticks = rig.server.state.tick
    if let mine = loop.state(at: rig.server.state.tick) { report.converged = mine == rig.server.state }
    return (report, rig)
}

/// Matches across the cores.
func playMatches(_ count: Int, seed: UInt64, link: SimNetwork.Link, pointsToWin: Int = 15) -> [MatchReport] {
    let out = LockedBox<[MatchReport]>(Array(repeating: MatchReport(), count: count))
    DispatchQueue.concurrentPerform(iterations: count) { i in
        let r = playMatch(seed: seed + UInt64(i) * 7, link: link, guestTeam: i % 2 == 0 ? .away : .home,
                          pointsToWin: pointsToWin).0
        out.withLock { $0[i] = r }
    }
    return out.withLock { $0 }
}

/// 100 ms round trip, 10 ms jitter, 2% loss (plan 6, Task 4): played once, read by the tests.
let lanMatches = playMatches(20, seed: 900, link: .init(oneWayDelay: 0.050, jitter: 0.010, loss: 0.02))

@Suite struct PredictionTests {
    /// Review Focus 1: the guest's own touch plays at once and the host almost never overrules it.
    @Test func ownTouchInstant() {
        let judged = lanMatches.map(\.ownJudged).reduce(0, +)
        let overruled = lanMatches.map(\.overruled).reduce(0, +)
        let late = lanMatches.map(\.shownLate).reduce(0, +)
        print("own touches: \(judged), overruled \(overruled) (\(Double(overruled) / Double(max(judged, 1)) * 100)%), shown late \(late)")
        #expect(judged > 20 * 40)
        #expect(Double(overruled) < 0.02 * Double(judged))
        #expect(late == 0)
    }

    @Test func smoothBounded() {
        let ball = lanMatches.map(\.maxBallJump).max()!
        let player = lanMatches.map(\.maxPlayerJump).max()!
        let corrections = lanMatches.map(\.corrections).reduce(0, +)
        print("drawn jumps per frame: ball \(ball) m, player \(player) m; corrections \(corrections)")
        #expect(corrections > 0)
        #expect(ball <= 0.5)
    }

    @Test func converges() {
        #expect(lanMatches.allSatisfy { $0.converged })
    }
}
