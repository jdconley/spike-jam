import Dispatch
import Foundation
import SpikeCore
import Testing
@testable import SpikeNet

/// What a match showed about celebrations on the guest.
struct CelebrationReport: Sendable {
    /// Kills the guest predicted that the host made stuff blocks of.
    var killsTakenBack = 0
    /// The guest's confirmed celebrations were exactly the host's.
    var sameAsHost = false
    /// Every score the guest drew was one the host had confirmed by then, and it never went down.
    var scoreOnlyConfirmed = true
    var hostCelebrations = 0
}

/// A match where the guest attacks into the hosting phone's player: while a human block is up on
/// the host (from the guest's side's set until the attack is played out), the guest hears
/// nothing from the host, so it predicts the attack without the block.
func playBlindAttacks(seed: UInt64) -> CelebrationReport {
    var report = CelebrationReport()
    var predicted: [(tick: Int, event: GameEvent)] = []
    var confirmedScores: [[Int]] = [[0, 0]]
    var lastDrawn = [0, 0]
    var blindUntil = -1.0
    let (_, rig) = playMatch(seed: seed, link: .init(oneWayDelay: 0.050, jitter: 0.010, loss: 0.02), guestTeam: .away, hostSkill: 1) {
        rig, local, guest in
        let normal = rig.net.link(from: rig.serverEnd.id, to: guest.end.id)
        guest.onFrameDebug = { g in
            guard let loop = g.loop else { return }
            if loop.onPredictedCelebration == nil {
                loop.onPredictedCelebration = { e, tick in predicted.append((tick, e)) }
            }
            // The host's player blocks against the guest's side: the guest goes deaf until the
            // rally's over.
            let s = rig.server.state
            if let w = s.notes.block, w.owner == local.human {
                blindUntil = rig.now + 1.5
            }
            if case .rally = s.phase {} else if blindUntil > rig.now { blindUntil = min(blindUntil, rig.now + 0.3) }
            var l = normal
            if rig.now < blindUntil { l.loss = 1 }
            rig.net.setLink(l, from: rig.serverEnd.id, to: guest.end.id)
            // The score the guest draws.
            let points = rig.server.confirmedPoints
            if confirmedScores.last! != points { confirmedScores.append(points) }
            let drawn = loop.current.score.points
            if drawn != lastDrawn {
                if !confirmedScores.contains(drawn) || drawn[0] < lastDrawn[0] || drawn[1] < lastDrawn[1] { report.scoreOnlyConfirmed = false }
                lastDrawn = drawn
            }
        }
    }
    let guest = rig.guests[1]
    // The host's final celebrations, in order.
    var host: [(tick: Int, event: GameEvent)] = []
    for tick in rig.hostEvents.keys.sorted() {
        for e in rig.hostEvents[tick]! where PredictingClientLoop.isCelebration(e) { host.append((tick, e)) }
    }
    report.hostCelebrations = host.count
    report.sameAsHost = guest.loop!.confirmedEvents == host.map(\.event)
    for (tick, e) in predicted {
        guard case .point(.away, .kill) = e else { continue }
        if host.contains(where: { abs($0.tick - tick) < 90 && $0.event == .point(.home, .block) }) { report.killsTakenBack += 1 }
    }
    return report
}

@Suite struct ConfirmationTests {
    /// Review Focus 2: at 5% loss each way the host still gets nearly every touch.
    @Test func lossTolerated() {
        let reports = playMatches(4, seed: 400, link: .init(oneWayDelay: 0.050, jitter: 0.010, loss: 0.05))
        let sent = reports.map(\.touchSent).reduce(0, +)
        let taken = reports.map(\.touchTaken).reduce(0, +)
        print("at 5% loss the host took \(taken) of \(sent) touch inputs")
        #expect(sent > 4 * 40)
        #expect(Double(taken) >= 0.995 * Double(sent))
        #expect(reports.allSatisfy { $0.converged })
    }

    /// Review Focus 3: a predicted kill the host turns into a stuff never shows as a kill, and the
    /// score drawn is only ever the host's.
    @Test func noTakeBackCelebrations() {
        let out = LockedBox<[CelebrationReport]>(Array(repeating: CelebrationReport(), count: 6))
        DispatchQueue.concurrentPerform(iterations: 6) { i in
            let r = playBlindAttacks(seed: 700 + UInt64(i))
            out.withLock { $0[i] = r }
        }
        let reports = out.withLock { $0 }
        let takenBack = reports.map(\.killsTakenBack).reduce(0, +)
        print("predicted kills the host stuffed: \(takenBack); host celebrations \(reports.map(\.hostCelebrations))")
        #expect(takenBack > 0)
        #expect(reports.allSatisfy { $0.sameAsHost })
        #expect(reports.allSatisfy { $0.scoreOnlyConfirmed })
    }
}
