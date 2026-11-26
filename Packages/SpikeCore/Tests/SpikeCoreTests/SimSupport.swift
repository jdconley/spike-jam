import Dispatch
import Foundation
@testable import SpikeCore

/// `runMatches` split across the machine's cores: the same matches (match i
/// uses seed `settings.seed + i`) and the same totals, sooner.
func runParallel(_ settings: MatchSettings, count: Int, touches: (any TouchSource)? = nil) -> MatchStats {
    let chunks = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount))
    let results = Locked<[MatchStats]>(Array(repeating: MatchStats(), count: chunks))
    DispatchQueue.concurrentPerform(iterations: chunks) { k in
        let lo = count * k / chunks, hi = count * (k + 1) / chunks
        var chunk = settings
        chunk.seed = settings.seed &+ UInt64(lo)
        let stats = runMatches(chunk, count: hi - lo, touches: touches)
        results.update { $0[k] = stats }
    }
    return results.value.reduce(MatchStats()) { $0.adding($1) }
}

/// A value behind a lock, for gathering results from concurrent work.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
