import Foundation
import Network
import SpikeNet
import Synchronization

/// SpikeNet's packets on the local network (plan 6): UDP datagrams through Network.framework.
///
/// - Hosting, it listens on a UDP port, advertised with Bonjour as `_spikejam._udp` under the
///   host's nickname. Each guest that sends to it is an `NWConnection` of its own, and a peer.
/// - As a guest, it is one `NWConnection` to the host's service, which is the peer `hostPeer`.
///
/// Packets are delivered to `onReceive` on the transport's own queue, as `Transport` allows. A
/// listener that fails (iOS can reclaim a suspended app's sockets) starts again on the same port,
/// so guests' connections to it keep working. It never retries a guest's connection itself: a
/// guest that loses the host makes a new transport (`GuestSession`), which the host sees as a new
/// peer and rejoins.
final class LocalTransport: Transport, @unchecked Sendable {
    static let serviceType = "_spikejam._udp"
    /// The host, as a guest's transport names it.
    static let hostPeer = PeerID(raw: 0)
    /// A host numbers its guests from here, clear of the in-process `SimNetwork`'s endpoints.
    static let firstPeer: UInt64 = 1 << 32

    enum State: Equatable, Sendable {
        case starting
        /// Listening (on `port`) or connected.
        case ready
        /// Not there yet, with why: no network, or local network access not allowed.
        case waiting(String)
        case failed(String)
        case closed
    }

    private struct Shared {
        var onReceive: (@Sendable (Data, PeerID) -> Void)?
        var onState: (@Sendable (State) -> Void)?
        var state: State = .starting
        var listener: NWListener?
        var connections: [PeerID: NWConnection] = [:]
        var nextPeer = LocalTransport.firstPeer
        var port: NWEndpoint.Port?
        var closed = false
        var received = 0
    }

    let isHost: Bool
    private let serviceName: String?
    private let shared = Mutex(Shared())
    private let queue = DispatchQueue(label: "spikejam.local-transport", qos: .userInteractive)

    var onReceive: (@Sendable (Data, PeerID) -> Void)? {
        get { shared.withLock { $0.onReceive } }
        set { shared.withLock { $0.onReceive = newValue } }
    }

    /// Called on the transport's queue when `state` changes.
    var onState: (@Sendable (State) -> Void)? {
        get { shared.withLock { $0.onState } }
        set { shared.withLock { $0.onState = newValue } }
    }

    var state: State { shared.withLock { $0.state } }
    /// The port a host listens on, once it does.
    var port: UInt16? { shared.withLock { $0.port?.rawValue } }
    /// The peers there are connections for.
    var peers: [PeerID] { shared.withLock { Array($0.connections.keys) } }
    /// Packets received so far.
    var received: Int { shared.withLock { $0.received } }

    /// Hosts on `port` (0: any), advertised under `name` (nil: not advertised, for tests).
    init(hosting name: String?, port: UInt16 = 0) {
        isHost = true
        serviceName = name
        startListener(on: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    /// Connects to a host: its Bonjour service from `LocalBrowser`, or an address and port.
    init(connectingTo endpoint: NWEndpoint) {
        isHost = false
        serviceName = nil
        let c = NWConnection(to: endpoint, using: Self.parameters())
        shared.withLock { $0.connections[Self.hostPeer] = c }
        watch(c, as: Self.hostPeer, reportsState: true)
        c.start(queue: queue)
    }

    deinit {
        close()
    }

    static func parameters() -> NWParameters {
        let p = NWParameters.udp
        p.allowLocalEndpointReuse = true
        // The same Wi-Fi only (the plan): no AWDL to phones that aren't on it.
        p.includePeerToPeer = false
        p.serviceClass = .interactiveVoice
        return p
    }

    // MARK: - Sending

    func send(_ d: Data, to peer: PeerID) {
        guard let c = shared.withLock({ $0.closed ? nil : $0.connections[peer] }) else { return }
        c.send(content: d, completion: .idempotent)
    }

    /// Drops the connection to `peer` (a guest that went away or came back on another one).
    func forget(_ peer: PeerID) {
        let c = shared.withLock { $0.connections.removeValue(forKey: peer) }
        c?.cancel()
    }

    /// Stops everything. Packets already handed to the network still go.
    func close() {
        let (listener, connections) = shared.withLock { s -> (NWListener?, [NWConnection]) in
            guard !s.closed else { return (nil, []) }
            s.closed = true
            let out = (s.listener, Array(s.connections.values))
            s.listener = nil
            s.connections = [:]
            return out
        }
        // Let what was just sent (a bye) leave before the sockets close.
        queue.asyncAfter(deadline: .now() + 0.15) {
            listener?.cancel()
            for c in connections { c.cancel() }
        }
        setState(.closed)
    }

    // MARK: - Hosting

    private func startListener(on port: NWEndpoint.Port) {
        let listener: NWListener
        do {
            listener = try NWListener(using: Self.parameters(), on: port)
        } catch {
            setState(.failed("\(error)"))
            retryListener()
            return
        }
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] st in
            guard let self, let listener else { return }
            switch st {
            case .ready:
                self.shared.withLock { $0.port = listener.port }
                self.setState(.ready)
            case .waiting(let e):
                self.setState(.waiting(Self.describe(e)))
            case .failed(let e):
                self.setState(.failed(Self.describe(e)))
                listener.cancel()
                self.retryListener()
            case .cancelled, .setup:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ok = shared.withLock { s -> Bool in
            guard !s.closed else { return false }
            s.listener = listener
            return true
        }
        guard ok else { return }
        listener.start(queue: queue)
    }

    /// Listens again on the same port, so guests already talking to it carry on.
    private func retryListener() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let port = self.shared.withLock { s -> NWEndpoint.Port? in
                guard !s.closed else { return nil }
                s.listener = nil
                return s.port ?? .any
            }
            guard let port else { return }
            self.startListener(on: port)
        }
    }

    private func accept(_ c: NWConnection) {
        let id = shared.withLock { s -> PeerID? in
            guard !s.closed else { return nil }
            let id = PeerID(raw: s.nextPeer)
            s.nextPeer += 1
            s.connections[id] = c
            return id
        }
        guard let id else {
            c.cancel()
            return
        }
        watch(c, as: id, reportsState: false)
        c.start(queue: queue)
    }

    // MARK: - Connections

    private func watch(_ c: NWConnection, as id: PeerID, reportsState: Bool) {
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c else { return }
            switch st {
            case .ready:
                if reportsState { self.setState(.ready) }
                self.receive(on: c, as: id)
            case .waiting(let e):
                if reportsState { self.setState(.waiting(Self.describe(e))) }
            case .failed(let e):
                if reportsState { self.setState(.failed(Self.describe(e))) }
                self.remove(c, id)
                c.cancel()
            case .cancelled:
                self.remove(c, id)
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
    }

    private func remove(_ c: NWConnection, _ id: PeerID) {
        shared.withLock { s in
            if s.connections[id] === c { s.connections[id] = nil }
        }
    }

    private func receive(on c: NWConnection, as id: PeerID) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            guard let self, let c else { return }
            if let data, !data.isEmpty, data.count <= Wire.maxPacket * 2 {
                let handler = self.shared.withLock { s -> (@Sendable (Data, PeerID) -> Void)? in
                    s.received += 1
                    return s.closed ? nil : s.onReceive
                }
                handler?(data, id)
            }
            switch c.state {
            case .failed, .cancelled:
                return
            default:
                // A UDP error (the host's port unreachable for a moment) isn't the end.
                if error == nil {
                    self.receive(on: c, as: id)
                } else {
                    self.queue.asyncAfter(deadline: .now() + 0.05) { self.receive(on: c, as: id) }
                }
            }
        }
    }

    private func setState(_ st: State) {
        let handler = shared.withLock { s -> (@Sendable (State) -> Void)? in
            guard s.state != st, s.state != .closed else { return nil }
            s.state = st
            return s.onState
        }
        handler?(st)
    }

    static func describe(_ e: NWError) -> String {
        switch e {
        case .dns(let code) where code == -65570: "Local network access is off for Spike Jam in Settings."
        default: e.debugDescription
        }
    }
}

/// A transport's `onReceive`, set on one thread and called on another.
///
/// The closure sits in a struct, not straight in the `Mutex`: a `Mutex` of a function type
/// reabstracts the closure on every `withLock` (an `inout` of a generic value writes it back
/// wrapped in two more thunks), so after a few thousand packets calling it overflowed the
/// network thread's stack.
final class Receiver: Sendable {
    typealias Handler = @Sendable (Data, PeerID) -> Void

    private struct Box {
        var handler: Handler?
    }

    private let box = Mutex(Box())

    var handler: Handler? {
        get { box.withLock { $0.handler } }
        set { box.withLock { $0.handler = newValue } }
    }
}

/// Packets that arrived on another thread, for the main thread to take.
final class PacketQueue<Tag: Sendable>: Sendable {
    private let packets = Mutex<[(Data, Tag)]>([])

    func put(_ d: Data, _ tag: Tag) {
        packets.withLock { $0.append((d, tag)) }
    }

    func take() -> [(Data, Tag)] {
        packets.withLock { p in
            defer { p.removeAll(keepingCapacity: true) }
            return p
        }
    }
}
