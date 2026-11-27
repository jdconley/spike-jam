#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization

/// Who a packet goes to or came from, as the transport names them.
public struct PeerID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }

    public var description: String { "peer \(raw)" }
}

/// Unreliable datagrams to and from peers (plan 6). The loops never assume more: packets can be
/// lost, late, duplicated or out of order. `onReceive` may be called on any thread.
public protocol Transport: AnyObject, Sendable {
    func send(_ d: Data, to peer: PeerID)
    var onReceive: (@Sendable (Data, PeerID) -> Void)? { get set }
}

/// Packets that arrived, for the loop to take on its own thread.
final class Inbox: Sendable {
    private let packets = Mutex<[(Data, PeerID)]>([])

    func put(_ d: Data, from peer: PeerID) {
        packets.withLock { $0.append((d, peer)) }
    }

    func take() -> [(Data, PeerID)] {
        packets.withLock { p in
            defer { p.removeAll(keepingCapacity: true) }
            return p
        }
    }
}
