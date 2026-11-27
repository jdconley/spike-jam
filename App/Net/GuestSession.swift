import Foundation
import Network
import Observation
import SpikeCore
import SpikeNet
import Synchronization

/// This phone joining a match hosted on the same Wi-Fi (plan 6).
///
/// - **Lobby:** it sends `join` (its nickname, its private token and the side it picked) four
///   times a second, and shows the room the host sends back.
/// - **Match:** the host's `welcome` makes a `PredictingClientLoop`, which `loop` (the
///   `ClientLoop` the game loop drives) plays and draws.
/// - **Losing the host:** if nothing comes for a while (Wi-Fi dropped, or this phone slept and
///   the host's AI took over), it connects again on a new connection, which the host sees as a
///   new peer and rejoins to the same slot (Review Focus 4). The old prediction stays on screen
///   until the new one has the host's first snapshot.
/// - **Host paused:** the loop stops with the host and `hostPaused` says so (Review Focus 5).
///   A long pause also reconnects, in case iOS closed the host's sockets while it was away.
///
/// Main thread only.
@MainActor
@Observable
final class GuestSession {
    enum Phase: Equatable {
        /// Looking for the host.
        case connecting
        /// In the room.
        case lobby
        case playing
        /// The host ended the match, or went away for good.
        case hostLeft
        /// The host won't take this phone.
        case refused(String)
    }

    static let joinEvery: Double = 0.25
    /// Silence before connecting again, in a match.
    static let silenceInMatch: Double = 1.2
    /// The same while the host said it paused.
    static let silencePaused: Double = 3
    /// The same in the lobby.
    static let silenceInLobby: Double = 4
    static let reconnectEvery: Double = 3
    /// Nothing for this long and the host is gone.
    static let gone: Double = 45

    let identity: NetIdentity
    let host: NearbyHost
    /// This phone's side, picked in the lobby (teammates or opponents of the host).
    var team: TeamSide
    private(set) var phase: Phase = .connecting
    private(set) var room: Room?
    /// What the game loop drives.
    let loop: GuestClientLoop
    /// Times it connected again.
    private(set) var reconnects = 0
    /// Each new predicting client, as it's made (tests give it a simulated human).
    @ObservationIgnored var onLoop: ((PredictingClientLoop) -> Void)?

    /// One connection to the host. A new one each time it connects again.
    final class Connection: Sendable {
        let transport: LocalTransport
        let link: GuestLink
        let generation: Int

        init(transport: LocalTransport, generation: Int, inbox: PacketQueue<Int>) {
            self.transport = transport
            self.generation = generation
            link = GuestLink(transport: transport)
            transport.onReceive = { d, _ in inbox.put(d, generation) }
        }
    }

    @ObservationIgnored private let inbox: PacketQueue<Int>
    @ObservationIgnored private var connection: Connection
    @ObservationIgnored private var generation = 1
    /// The connection the current predicting client is on.
    @ObservationIgnored private var loopGeneration: Int?
    @ObservationIgnored private var lastHeard: Double
    @ObservationIgnored private var lastJoin = -Double.infinity
    @ObservationIgnored private var lastReconnect: Double
    /// Taken off the network on purpose (`disconnect`), until `reconnect`.
    @ObservationIgnored private var offline = false
    /// Reconnected in a match: say hello until welcomed.
    @ObservationIgnored private var rejoining = false

    /// Joins `host` (from `LocalBrowser`, or an address for tests) on `team`, from `now`.
    init(identity: NetIdentity, host: NearbyHost, team: TeamSide = .away, now: Double) {
        self.identity = identity
        self.host = host
        self.team = team
        lastHeard = now
        lastReconnect = now
        loop = GuestClientLoop()
        let inbox = PacketQueue<Int>()
        self.inbox = inbox
        connection = Connection(transport: LocalTransport(connectingTo: host.endpoint), generation: 1, inbox: inbox)
        loop.session = self
    }

    /// Joins a host the browser found (the plan's `join(_:)`).
    static func join(_ host: NearbyHost, as identity: NetIdentity, team: TeamSide, now: Double) -> GuestSession {
        GuestSession(identity: identity, host: host, team: team, now: now)
    }

    /// The host said it paused, and isn't back yet.
    var hostPaused: Bool { loop.inner?.hostPaused == true }

    /// Nothing from the host for a while, in a match: the banner says so.
    func waiting(now: Double) -> Bool {
        phase == .playing && now - lastHeard > 0.5
    }

    // MARK: - Each frame (or, in the lobby, a few times a second)

    func pump(now: Double) {
        for (d, gen) in inbox.take() where gen == connection.generation {
            lastHeard = now
            if let m = LobbyMessage.decode(d) {
                if case .room(let r) = m { take(r) }
                continue
            }
            if let m = try? Wire.decode(d) {
                switch m {
                case .welcome(let h, let settings, let startTick):
                    welcome(h, settings, startTick)
                case .bye:
                    if case .refused = phase {} else { phase = .hostLeft }
                default:
                    break
                }
            }
            connection.link.deliver(d)
        }
        guard !offline, phase != .hostLeft else { return }
        if case .refused = phase { return }
        let silent = now - lastHeard
        if silent > Self.gone {
            phase = .hostLeft
            return
        }
        switch phase {
        case .connecting, .lobby:
            if silent > Self.silenceInLobby, now - lastReconnect > Self.reconnectEvery { reconnect(now: now) }
            if now - lastJoin >= Self.joinEvery {
                lastJoin = now
                sendJoin()
                // Started without this phone: ask to join it.
                if room?.started == true { sendHello() }
            }
        case .playing:
            if loop.inner?.hostLeft == true {
                phase = .hostLeft
                return
            }
            let limit = hostPaused ? Self.silencePaused : Self.silenceInMatch
            if silent > limit, now - lastReconnect > Self.reconnectEvery { reconnect(now: now) }
            if rejoining, now - lastJoin >= Self.joinEvery {
                lastJoin = now
                sendJoin()
                sendHello()
            }
        case .hostLeft, .refused:
            break
        }
    }

    private func take(_ r: Room) {
        room = r
        if let why = r.refused {
            phase = .refused(why)
        } else if phase == .connecting {
            phase = .lobby
        }
    }

    private func welcome(_ h: HumanID, _ settings: MatchSettings, _ startTick: Int) {
        // A copy of the welcome for the client already on this connection, unless it's a new
        // match (Play again).
        if loopGeneration == connection.generation, let inner = loop.inner, inner.human == h,
           inner.predicted.settings.seed == settings.seed {
            return
        }
        let client = PredictingClientLoop(transport: connection.link, server: LocalTransport.hostPeer, human: h,
                                          settings: settings, startTick: startTick)
        onLoop?(client)
        let sameMatch = loop.inner.map { $0.predicted.settings.seed == settings.seed } ?? false
        loop.install(client, sameMatch: sameMatch)
        loopGeneration = connection.generation
        rejoining = false
        phase = .playing
    }

    private func sendJoin() {
        let m = LobbyMessage.join(nickname: identity.nickname, token: identity.token, team: team, version: Wire.version)
        connection.transport.send(m.encoded(), to: LocalTransport.hostPeer)
    }

    private func sendHello() {
        guard let d = try? Wire.encode(.hello(nickname: identity.nickname, version: Wire.version)) else { return }
        connection.transport.send(d, to: LocalTransport.hostPeer)
    }

    /// Picks a side in the lobby.
    func pick(_ side: TeamSide, now: Double) {
        team = side
        if phase == .lobby || phase == .connecting {
            lastJoin = now
            sendJoin()
        }
    }

    // MARK: - Connecting again

    /// A new connection to the host: the host sees a new peer, and a guest in a match rejoins.
    func reconnect(now: Double) {
        offline = false
        connection.transport.close()
        generation += 1
        connection = Connection(transport: LocalTransport(connectingTo: host.endpoint), generation: generation, inbox: inbox)
        reconnects += 1
        lastReconnect = now
        lastJoin = -.infinity
        if phase == .playing { rejoining = true }
    }

    /// Off the network until `reconnect` (tests: the Wi-Fi drops).
    func disconnect() {
        offline = true
        connection.transport.close()
    }

    /// Leaves for good: the host's AI takes over at once.
    func leave() {
        loop.inner?.leave()
        connection.transport.send(LobbyMessage.leave.encoded(), to: LocalTransport.hostPeer)
        offline = true
        connection.transport.close()
        phase = .hostLeft
    }

    /// The game loop paused this phone (it left the screen) for `seconds`: away long enough for
    /// the host to have dropped it, it connects again.
    func cameBack(after seconds: Double, now: Double) {
        guard phase == .playing, seconds > 0.5 else { return }
        reconnect(now: now)
    }
}

/// A predicting client's transport: one connection to the host, with the packets the session
/// passes on, on the main thread.
final class GuestLink: Transport, @unchecked Sendable {
    private let transport: LocalTransport
    private let receiver = Receiver()

    init(transport: LocalTransport) {
        self.transport = transport
    }

    var onReceive: (@Sendable (Data, PeerID) -> Void)? {
        get { receiver.handler }
        set { receiver.handler = newValue }
    }

    func send(_ d: Data, to peer: PeerID) {
        transport.send(d, to: peer)
    }

    func deliver(_ d: Data) {
        receiver.handler?(d, LocalTransport.hostPeer)
    }
}

/// A guest phone's `ClientLoop`: the current predicting client, through rejoins and rematches.
/// Until the first one has a snapshot it draws an empty court; after a rejoin, the old one stays
/// on screen until the new one has its first snapshot.
@MainActor
final class GuestClientLoop: ClientLoop {
    weak var session: GuestSession?
    /// The newest client, which inputs go to.
    private(set) var inner: PredictingClientLoop?
    /// The one drawn.
    private var shown: PredictingClientLoop?
    /// Bumped when a new match starts (not on a rejoin), so the view can start over.
    private(set) var matchNumber = 0
    private var blank = GameState(settings: MatchSettings())
    private var isPaused = false
    private var lastNow: Double?

    var human: HumanID? { inner?.human }
    var previous: GameState { shown?.previous ?? blank }
    var current: GameState { shown?.current ?? blank }
    var alpha: Double { shown?.alpha ?? 0 }

    func install(_ client: PredictingClientLoop, sameMatch: Bool) {
        inner = client
        if !sameMatch {
            matchNumber += 1
            shown = nil
            blank = client.current
        }
        if isPaused { client.pause() }
    }

    func send(_ input: PlayerInput, at time: Double) {
        inner?.send(input, at: time)
    }

    func advance(to now: Double) -> [GameEvent] {
        lastNow = now
        session?.pump(now: now)
        guard !isPaused, let inner else { return [] }
        let events = inner.advance(to: now)
        // The old client (before a rejoin) stays still on screen until the new one has a snapshot.
        if inner.snapshotTick != nil { shown = inner }
        return shown === inner ? events : []
    }

    func pause() {
        isPaused = true
        inner?.pause()
    }

    func resume(at now: Double) {
        isPaused = false
        inner?.resume(at: now)
        if let last = lastNow { session?.cameBack(after: now - last, now: now) }
    }
}
