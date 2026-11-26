// spikesim: plays headless bot-vs-bot matches and prints their stats.
//   spikesim [--matches N] [--seed S] [--game mens|womens] [--system 51|62]
//            [--tempo fast|faster|stupidfast]
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
    print("usage: spikesim [--matches N] [--seed S] [--game mens|womens] [--system 51|62] [--tempo fast|faster|stupidfast]")
    exit(2)
}

var count = 100
var settings = MatchSettings()
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
    default:
        fail("unknown flag \(flag)")
    }
}

let stats = runMatches(settings, count: count)
func fmt(_ x: Double) -> String {
    let scaled = (x * 1000).rounded() / 1000
    return "\(scaled)"
}
print("game: \(settings.gameType.rawValue)")
print("system: \(settings.team(.home).system.rawValue)")
print("tempo: \(settings.tempo.rawValue)")
print("seed: \(settings.seed)")
print("matches: \(stats.matches)")
print("rallies: \(stats.rallies)")
print("touches: \(stats.touches)")
print("sideOuts: \(stats.sideOuts)")
print("aces: \(stats.aces)")
print("serviceErrors: \(stats.serviceErrors)")
print("kills: \(stats.kills)")
print("attackErrors: \(stats.attackErrors)")
print("handlingErrors: \(stats.handlingErrors)")
print("unfinished: \(stats.unfinished)")
print("invariantFailures: \(stats.invariantFailures)")
print("overlapViolations: \(stats.overlapViolations)")
print("lateSetters: \(stats.lateSetters)")
print("droppedForReach: \(stats.droppedForReach)")
print("avgTouchesPerRally: \(fmt(stats.avgTouchesPerRally))")
print("sideOutRate: \(fmt(stats.sideOutRate))")
print("avgMargin: \(fmt(stats.avgMargin))")
exit(stats.invariantFailures > 0 || stats.unfinished > 0 || stats.overlapViolations > 0 ? 1 : 0)
