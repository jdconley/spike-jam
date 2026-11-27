import Foundation
import Observation
import SpikeCore
import SpikeNet
import Synchronization

/// A match hosted on this phone, on the same Wi-Fi (plan 6, spec §5.4).
///
/// - **Lobby:** the phone listens and advertises itself under its nickname. Guests that find it
///   send `join` with their side; the room goes back to each of them four times a second.
/// - **Match:** `start` makes the `ServerLoop` (in charge of the match, as the online server will
///   be) and admits the host's own player and every guest. The host's own `PredictingClientLoop`
///   talks to the server over an in-process `SimNetwork` link with no delay, so the hosting phone
///   plays through exactly the code a guest does. `loop` is the `ClientLoop` the game loop drives:
///   each frame it takes the lobby's packets, runs the server, then the host's own client.
/// - **Joining late, dropping and rejoining:** a guest's `hello` that the server hasn't admitted
///   comes to `hello`: a phone that played this match before (by its token) rejoins its old slot
///   on its old team, with a fresh pick (Review Focus 4); a new one joins on the side it asked for.
/// - **Pausing:** the hosting phone can't run in the background on iOS, so `loop.pause()` stops
///   the server and tells the guests, which show "Host paused" (Review Focus 5).
///
/// Main thread only; the transport delivers to queues the main thread drains.
@MainActor
@Observable
final class HostSession {
    struct Guest: Equatable {
        var peer: PeerID
        var nickname: String
        var token: UInt64
        var team: TeamSide
        /// When their latest `join` came.
        var heard: Double
        /// In the match, once admitted.
        var human: HumanID?
    }

    enum Phase: Equatable {
        case lobby, playing, closed
    }

    /// Guests in a room at most (spec §4.1: six a side, the host is one of them).
    static let maxGuests = 11
    /// A lobby guest silent this long has left.
    static let lobbySilence: Double = 3
    static let roomEvery: Double = 0.25

    let identity: NetIdentity
    /// The match's settings: the host's men's or women's, tempo and level.
    private(set) var settings: MatchSettings
    /// The host's own side.
    var hostTeam: TeamSide = .home
    private(set) var phase: Phase = .lobby
    /// Everyone who joined, in the order they did.
    private(set) var guests: [Guest] = []
    private(set) var transportState: LocalTransport.State = .starting
    /// The match, once started.
    private(set) var server: ServerLoop?
    private(set) var loop: HostClientLoop?
    private(set) var hostHuman: HumanID?
    /// Guests the AI took over from, by nickname, for the host's banner.
    private(set) var dropped: [String] = []
    /// Times a guest was dropped this match.
    private(set) var drops = 0

    @ObservationIgnored let local: LocalTransport
    @ObservationIgnored private let lobbyInbox: PacketQueue<PeerID>
    @ObservationIgnored private let route: Route
    @ObservationIgnored private var match: HostLink?
    @ObservationIgnored private var lastRoom = -Double.infinity
    @ObservationIgnored private var lastSweep = -Double.infinity

    /// Hosts with `settings`. `advertise` false skips Bonjour (tests connect to `port`).
    init(identity: NetIdentity, settings: MatchSettings, advertise: Bool = true, port: UInt16 = 0) {
        self.identity = identity
        var s = settings
        s.humanSides = []
        self.settings = s
        local = LocalTransport(hosting: advertise ? identity.nickname : nil, port: port)
        let lobbyInbox = PacketQueue<PeerID>(), route = Route()
        self.lobbyInbox = lobbyInbox
        self.route = route
        local.onReceive = { d, peer in
            if d.first == LobbyMessage.format {
                lobbyInbox.put(d, peer)
            } else {
                route.link?.deliver(d, from: peer)
            }
        }
        local.onState = { [weak self] st in
            Task { @MainActor in self?.transportState = st }
        }
    }

    /// The port it listens on, once it does.
    var port: UInt16? { local.port }

    /// The room as the host sees it, the host first.
    var players: [Room.Player] { room(for: nil).players }

    /// Guests in the room now (heard lately, or playing).
    var present: [Guest] { guests.filter { isPresent($0) } }

    /// The host's settings for the lobby's next match; only in the lobby.
    func update(_ s: MatchSettings) {
        guard phase == .lobby else { return }
        var s = s
        s.humanSides = []
        settings = s
    }

    // MARK: - Each frame (or, in the lobby, a few times a second)

    /// Takes what came in for the lobby, and sends the room.
    func pump(now: Double) {
        for (d, peer) in lobbyInbox.take() {
            guard let m = LobbyMessage.decode(d) else { continue }
            switch m {
            case .join(let nickname, let token, let team, let version):
                join(peer, nickname: nickname, token: token, team: team, version: version, now: now)
            case .leave:
                if phase == .lobby { guests.removeAll { $0.peer == peer } }
            case .room:
                break
            }
        }
        if phase == .lobby { guests.removeAll { now - $0.heard > Self.lobbySilence } }
        if now - lastRoom >= Self.roomEvery {
            lastRoom = now
            sendRooms()
        }
        if now - lastSweep >= 2 {
            lastSweep = now
            sweep(now)
        }
    }

    /// One frame of a match: the lobby, the server, and the host's own client's packets.
    func step(now: Double) {
        pump(now: now)
        guard let match, let server else { return }
        match.net.advance(to: now)
        server.tick(now: now)
        match.net.advance(to: now)
    }

    private func join(_ peer: PeerID, nickname: String, token: UInt64, team: TeamSide, version: Int, now: Double) {
        guard version == Wire.version else {
            refuse(peer, "That phone has another version of Spike Jam. Update both from TestFlight.")
            return
        }
        guard Nicknames.all.contains(nickname) else { return }
        if let i = guests.firstIndex(where: { $0.token == token }) {
            guests[i].heard = now
            guests[i].peer = peer
            if phase == .lobby {
                guests[i].team = team
                guests[i].nickname = nickname
            }
        } else {
            guard guests.count < Self.maxGuests else {
                refuse(peer, "This match is full.")
                return
            }
            guests.append(Guest(peer: peer, nickname: nickname, token: token, team: team, heard: now))
        }
    }

    private func refuse(_ peer: PeerID, _ why: String) {
        var r = room(for: nil)
        r.refused = why
        local.send(LobbyMessage.room(r).encoded(), to: peer)
    }

    private func isPresent(_ g: Guest) -> Bool {
        if let server, let h = g.human { return server.connected.values.contains(h) }
        return phase == .lobby && g.human == nil
    }

    /// The room as `token`'s phone sees it (nil: the host's).
    func room(for token: UInt64?) -> Room {
        var players = [Room.Player(nickname: identity.nickname, team: hostTeam, isHost: true, isYou: token == nil, connected: true)]
        for g in guests where isPresent(g) || g.human != nil {
            players.append(Room.Player(nickname: g.nickname, team: g.team, isHost: false, isYou: g.token == token, connected: isPresent(g)))
        }
        return Room(host: identity.nickname, gameType: settings.gameType, tempo: settings.tempo, difficulty: settings.difficulty,
                    players: players, started: phase == .playing)
    }

    private func sendRooms() {
        let playing = server.map { Set($0.connected.keys) } ?? []
        for g in guests where !playing.contains(g.peer) {
            local.send(LobbyMessage.room(room(for: g.token)).encoded(), to: g.peer)
        }
    }

    /// Forgets connections nobody uses: a guest that came back on a new one leaves the old.
    private func sweep(_ now: Double) {
        let playing = server.map { Set($0.connected.keys) } ?? []
        let lobby = Set(guests.filter { now - $0.heard < 5 }.map(\.peer))
        for p in local.peers where !playing.contains(p) && !lobby.contains(p) {
            local.forget(p)
        }
    }

    // MARK: - The match

    /// Starts the match with everyone in the room, from `now`. Returns the host's own client loop.
    @discardableResult
    func start(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) -> HostClientLoop? {
        guard phase == .lobby else { return loop }
        guests = guests.filter { isPresent($0) }
        settings.seed = seed
        return begin()
    }

    /// A new match with the same phones and settings and a new seed (Play again).
    @discardableResult
    func rematch() -> HostClientLoop? {
        guard phase == .playing, let server else { return nil }
        let connected = Set(server.connected.keys)
        guests = guests.filter { connected.contains($0.peer) }
        for i in guests.indices { guests[i].human = nil }
        settings.seed &+= 1
        return begin()
    }

    private func begin() -> HostClientLoop {
        // A fresh simulated link each match, so nothing of the last one is in flight.
        let net = SimNetwork(seed: settings.seed)
        let serverEnd = net.endpoint(), ownEnd = net.endpoint()
        let link = HostLink(local: local, net: net, serverEnd: serverEnd, ownEnd: ownEnd)
        route.link = link
        match = link
        let server = ServerLoop(settings: settings, transport: link)
        let me = server.admit(ownEnd.id, team: hostTeam)
        for i in guests.indices {
            guests[i].human = server.admit(guests[i].peer, team: guests[i].team)
        }
        server.onHello = { [weak self] peer, nickname, version in self?.hello(peer, nickname: nickname, version: version) }
        server.onDrop = { [weak self] h in self?.drop(h) }
        let own = PredictingClientLoop(transport: ownEnd, server: serverEnd.id, human: me,
                                       settings: server.state.settings, startTick: server.state.tick)
        own.ignoresHostPause = true
        self.server = server
        hostHuman = me
        dropped = []
        drops = 0
        phase = .playing
        let loop = HostClientLoop(session: self, own: own)
        self.loop = loop
        return loop
    }

    /// A guest the server doesn't have said hello: a rejoin, or a phone joining mid-match. Its
    /// `join` (with its token) comes first, on the same connection.
    private func hello(_ peer: PeerID, nickname: String, version: Int) {
        guard let server, version == Wire.version, let i = guests.firstIndex(where: { $0.peer == peer }) else { return }
        if let h = guests[i].human {
            if server.rejoin(peer, as: h) { dropped.removeAll { $0 == guests[i].nickname } }
        } else {
            guests[i].human = server.admit(peer, team: guests[i].team)
        }
    }

    private func drop(_ h: HumanID) {
        drops += 1
        guard let g = guests.first(where: { $0.human == h }) else { return }
        if !dropped.contains(g.nickname) { dropped.append(g.nickname) }
    }

    /// Ends the match or the lobby: every guest hears `bye`.
    func close() {
        guard phase != .closed else { return }
        if let bye = try? Wire.encode(.bye) {
            for p in local.peers {
                for _ in 0..<3 { local.send(bye, to: p) }
            }
        }
        route.link = nil
        phase = .closed
        local.close()
    }

    func pause() {
        server?.pause()
    }

    func resume(now: Double) {
        server?.resume(now: now)
    }
}

/// Where the network's match packets go: the current match's link, read on the transport's queue.
final class Route: Sendable {
    private let current = Mutex<HostLink?>(nil)

    var link: HostLink? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

/// The server's transport on a hosting phone: guests over the local network, and the host's own
/// client over the in-process link.
final class HostLink: Transport, @unchecked Sendable {
    let local: LocalTransport
    let net: SimNetwork
    let serverEnd: SimTransport
    let ownEnd: SimTransport
    private let receiver = Receiver()

    init(local: LocalTransport, net: SimNetwork, serverEnd: SimTransport, ownEnd: SimTransport) {
        self.local = local
        self.net = net
        self.serverEnd = serverEnd
        self.ownEnd = ownEnd
        serverEnd.onReceive = { [weak self] d, from in self?.deliver(d, from: from) }
    }

    var onReceive: (@Sendable (Data, PeerID) -> Void)? {
        get { receiver.handler }
        set { receiver.handler = newValue }
    }

    func send(_ d: Data, to peer: PeerID) {
        if peer == ownEnd.id {
            // The simulated network is the main thread's, as the server is.
            serverEnd.send(d, to: peer)
        } else {
            local.send(d, to: peer)
        }
    }

    func deliver(_ d: Data, from peer: PeerID) {
        receiver.handler?(d, peer)
    }
}

/// The hosting phone's `ClientLoop`: each frame runs the host's session and server, then the
/// host's own predicting client, which is what's drawn.
@MainActor
final class HostClientLoop: ClientLoop {
    private weak var session: HostSession?
    let own: PredictingClientLoop

    init(session: HostSession, own: PredictingClientLoop) {
        self.session = session
        self.own = own
    }

    var human: HumanID { own.human }
    var previous: GameState { own.previous }
    var current: GameState { own.current }
    var alpha: Double { own.alpha }

    func send(_ input: PlayerInput, at time: Double) {
        own.send(input, at: time)
    }

    func advance(to now: Double) -> [GameEvent] {
        if let session, session.loop === self { session.step(now: now) }
        return own.advance(to: now)
    }

    /// The app left the screen: the match stops for everyone.
    func pause() {
        if let session, session.loop === self { session.pause() }
        own.pause()
    }

    func resume(at now: Double) {
        if let session, session.loop === self { session.resume(now: now) }
        own.resume(at: now)
    }
}
