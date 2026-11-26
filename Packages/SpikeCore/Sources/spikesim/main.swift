// spikesim: plays headless matches and prints their stats. Bot against bot
// by default; --human T puts a simulated human with timing grade T (0...1)
// on every home touch, against the AI, to measure the catch-up.
//   spikesim [--matches N] [--seed S] [--game mens|womens] [--system 51|62]
//            [--tempo fast|faster|stupidfast] [--difficulty easy|medium|hard]
//            [--human T] [--catchup on|off]
import SpikeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

func fail(_ message: String) -> Never {
    print("spikesim: \(message)")
    print("usage: spikesim [--matches N] [--seed S] [--game mens|womens] [--system 51|62] [--tempo fast|faster|stupidfast]"
          + " [--difficulty easy|medium|hard] [--human T] [--catchup on|off]")
    exit(2)
}

/// A simulated human playing every touch on one side with the same timing.
struct FixedTiming: TouchSource {
    let side: TeamSide
    let timing: Float

    func quality(for c: PendingContact, _ s: GameState, rng: inout SeededRNG) -> Float? {
        c.team == side ? timing : nil
    }
}

var count = 100
var settings = MatchSettings()
var human: FixedTiming?
var args = CommandLine.arguments.dropFirst()
while let flag = args.popFirst() {
    guard let value = args.popFirst() else { fail("\(flag) needs a value") }
    switch flag {
    case "--matches":
        guard let n = Int(value), n > 0 else { fail("bad --matches \(value)") }
        count = n
    case "--seed":
        guard let n = UInt64(value) else { fail("bad --seed \(value)") }
        settings.seed = n
    case "--game":
        guard let g = GameType(rawValue: value) else { fail("bad --game \(value)") }
        settings.gameType = g
    case "--system":
        let system: OffenseSystem
        switch value {
        case "51": system = .fiveOne
        case "62": system = .sixTwo
        default: fail("bad --system \(value)")
        }
        settings.teams = settings.teams.map { TeamSettings(system: system, startingRotation: $0.startingRotation) }
    case "--tempo":
        switch value {
        case "fast": settings.tempo = .fast
        case "faster": settings.tempo = .faster
        case "stupidfast": settings.tempo = .stupidFast
        default: fail("bad --tempo \(value)")
        }
    case "--difficulty":
        guard let d = Difficulty(rawValue: value) else { fail("bad --difficulty \(value)") }
        settings.difficulty = d
    case "--human":
        guard let t = Float(value), (0...1).contains(t) else { fail("bad --human \(value)") }
        human = FixedTiming(side: .home, timing: t)
        settings.humanSides = [.home]
    case "--catchup":
        guard value == "on" || value == "off" else { fail("bad --catchup \(value)") }
        settings.catchUp = value == "on"
    default:
        fail("unknown flag \(flag)")
    }
}

let stats = runMatches(settings, count: count, touches: human)
func fmt(_ x: Double) -> String {
    let scaled = (x * 1000).rounded() / 1000
    return "\(scaled)"
}
print("game: \(settings.gameType.rawValue)")
print("system: \(settings.team(.home).system.rawValue)")
print("tempo: \(settings.tempo.rawValue)")
print("seed: \(settings.seed)")
print("difficulty: \(settings.difficulty.rawValue)")
if let human {
    print("human: home, timing \(human.timing), catch-up \(settings.catchUp ? "on" : "off")")
}
print("matches: \(stats.matches)")
print("rallies: \(stats.rallies)")
print("touches: \(stats.touches)")
print("sideOuts: \(stats.sideOuts)")
print("aces: \(stats.aces)")
print("serviceErrors: \(stats.serviceErrors)")
print("kills: \(stats.kills)")
print("attackErrors: \(stats.attackErrors)")
print("handlingErrors: \(stats.handlingErrors)")
print("blocks: \(stats.blocks)")
print("serves: \(stats.serves)")
print("attacks: \(stats.attacks)")
print("digs: \(stats.digs)")
print("blockTouches: \(stats.blockTouches)")
print("tips: \(stats.tips)")
print("unfinished: \(stats.unfinished)")
print("invariantFailures: \(stats.invariantFailures)")
print("overlapViolations: \(stats.overlapViolations)")
print("lateSetters: \(stats.lateSetters)")
print("droppedForReach: \(stats.droppedForReach)")
print("sets: " + stats.setCalls.sorted { $0.value > $1.value }.map { "\($0.key.display) \($0.value)" }.joined(separator: ", "))
print("drops: " + stats.drops.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))
print("errors: " + stats.errors.sorted { $0.key.rawValue < $1.key.rawValue }.map { kind, byError in
    "\(kind.rawValue) " + byError.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: "/")
}.joined(separator: ", "))
print("avgTouchesPerRally: \(fmt(stats.avgTouchesPerRally))")
print("serveErrorRate: \(fmt(stats.serveErrorRate))")
print("aceRate: \(fmt(stats.aceRate))")
print("killRate: \(fmt(stats.killRate))")
print("attackErrorRate: \(fmt(stats.attackErrorRate))")
print("tipRate: \(fmt(stats.tipRate))")
print("sideOutRate: \(fmt(stats.sideOutRate))")
print("avgMargin: \(fmt(stats.avgMargin))")
print("homeWinRate: \(fmt(stats.homeWinRate))")
print("bigLeads: home \(stats.bigLeads[0]) (lost \(stats.bigLeadsLost[0])), away \(stats.bigLeads[1]) (lost \(stats.bigLeadsLost[1]))")
exit(stats.invariantFailures > 0 || stats.unfinished > 0 || stats.overlapViolations > 0 ? 1 : 0)
