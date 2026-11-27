#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SpikeCore

/// The network test rig (spec §5.5): endpoints on a virtual clock, with each link's delay, jitter
/// and loss drawn from a seeded generator, so a test plays the same way every time. Nothing
/// moves until `advance`, which delivers the due packets in time order on the caller's thread.
public final class SimNetwork: @unchecked Sendable {
    /// One direction of a link.
    public struct Link: Equatable, Sendable {
        /// Seconds.
        public var oneWayDelay: Double
        /// Up to this many extra seconds, uniformly, per packet; enough of it reorders them.
        public var jitter: Double
        /// The share of packets lost, 0...1.
        public var loss: Double

        public init(oneWayDelay: Double = 0, jitter: Double = 0, loss: Double = 0) {
            self.oneWayDelay = oneWayDelay
            self.jitter = jitter
            self.loss = loss
        }

        public static let perfect = Link()
    }

    struct Packet {
        var at: Double
        var order: Int
        var data: Data
        var from: PeerID
        var to: PeerID
    }

    /// The virtual time, in seconds.
    public private(set) var now: Double = 0
    /// Links with no conditions of their own.
    public var defaultLink: Link
    public private(set) var sent = 0
    public private(set) var lost = 0
    public private(set) var delivered = 0

    private var rng: SeededRNG
    private var links: [Pair: Link] = [:]
    private var endpoints: [PeerID: SimTransport] = [:]
    private var nextID: UInt64 = 1
    private var nextOrder = 0
    /// In flight, soonest last.
    private var inFlight: [Packet] = []

    struct Pair: Hashable {
        var from: PeerID
        var to: PeerID
    }

    public init(seed: UInt64 = 1, link: Link = .perfect) {
        rng = SeededRNG(seed: seed)
        defaultLink = link
    }

    /// A new endpoint on the network.
    public func endpoint() -> SimTransport {
        let id = PeerID(raw: nextID)
        nextID += 1
        let t = SimTransport(id: id, network: self)
        endpoints[id] = t
        return t
    }

    /// Two endpoints, each with the other's `id` to send to.
    public func connect(_ link: Link? = nil) -> (SimTransport, SimTransport) {
        let a = endpoint(), b = endpoint()
        if let link { setLink(link, between: a.id, and: b.id) }
        return (a, b)
    }

    public func link(from a: PeerID, to b: PeerID) -> Link {
        links[Pair(from: a, to: b)] ?? defaultLink
    }

    public func setLink(_ l: Link, from a: PeerID, to b: PeerID) {
        links[Pair(from: a, to: b)] = l
    }

    public func setLink(_ l: Link, between a: PeerID, and b: PeerID) {
        setLink(l, from: a, to: b)
        setLink(l, from: b, to: a)
    }

    func send(_ d: Data, from: PeerID, to: PeerID) {
        sent += 1
        let l = link(from: from, to: to)
        if l.loss > 0 && Double(rng.unit()) < l.loss {
            lost += 1
            return
        }
        let delay = l.oneWayDelay + (l.jitter > 0 ? l.jitter * Double(rng.unit()) : 0)
        let p = Packet(at: now + delay, order: nextOrder, data: d, from: from, to: to)
        nextOrder += 1
        // Keep it sorted soonest last, so delivery pops from the end.
        var lo = 0, hi = inFlight.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let q = inFlight[mid]
            if (q.at, -q.order) > (p.at, -p.order) { lo = mid + 1 } else { hi = mid }
        }
        inFlight.insert(p, at: lo)
    }

    /// Runs the clock forward `seconds`, delivering every packet due by then.
    public func advance(by seconds: Double) {
        advance(to: now + seconds)
    }

    public func advance(to time: Double) {
        while let p = inFlight.last, p.at <= time + 1e-12 {
            inFlight.removeLast()
            now = max(now, p.at)
            guard let to = endpoints[p.to] else { continue }
            delivered += 1
            to.onReceive?(p.data, p.from)
        }
        now = max(now, time)
    }
}

/// An endpoint of a `SimNetwork`.
public final class SimTransport: Transport, @unchecked Sendable {
    public let id: PeerID
    public var onReceive: (@Sendable (Data, PeerID) -> Void)?
    private weak var network: SimNetwork?

    init(id: PeerID, network: SimNetwork) {
        self.id = id
        self.network = network
    }

    public func send(_ d: Data, to peer: PeerID) {
        network?.send(d, from: id, to: peer)
    }
}
