import Observation
import SpikeCore

/// A match on the same Wi-Fi as the match view plays it: this phone's session (hosting or
/// joined), its player and its side. The view drives `client` exactly like a solo match's loop.
struct NetMatch: Equatable {
    enum Role {
        case host(HostSession)
        case guest(GuestSession)
    }

    let role: Role
    let human: HumanID
    let side: TeamSide
    let settings: MatchSettings
    /// The robot finger plays this phone's touches (`-robot`, for two-simulator checks).
    var robot = false

    @MainActor
    init(host s: HostSession, robot: Bool = false) {
        self.robot = robot
        role = .host(s)
        human = s.hostHuman ?? HumanID(raw: 1)
        side = s.hostTeam
        settings = s.server?.state.settings ?? s.settings
    }

    @MainActor
    init(guest s: GuestSession, robot: Bool = false) {
        self.robot = robot
        role = .guest(s)
        human = s.loop.human ?? HumanID(raw: 2)
        side = s.team
        settings = s.loop.inner?.predicted.settings ?? MatchSettings()
    }

    var isHost: Bool {
        if case .host = role { return true }
        return false
    }

    private var session: AnyObject {
        switch role {
        case .host(let s): s
        case .guest(let s): s
        }
    }

    static func == (a: NetMatch, b: NetMatch) -> Bool {
        a.session === b.session && a.human == b.human
    }

    /// The loop the game loop drives: the host's (server and own client), or the guest's.
    @MainActor
    var client: any ClientLoop {
        switch role {
        case .host(let s): s.loop ?? s.start()!
        case .guest(let s): s.loop
        }
    }

    /// Play again: the host starts a new match with the same phones; a guest waits for it.
    @MainActor
    func rematch() -> Bool {
        guard case .host(let s) = role else { return false }
        return s.rematch() != nil
    }

    /// This phone leaves: the host closes the room (the guests hear it), a guest leaves it (the
    /// host's AI takes over).
    @MainActor
    func end() {
        switch role {
        case .host(let s): s.close()
        case .guest(let s): s.leave()
        }
    }

    /// What to tell the player over the court, if anything.
    @MainActor
    func status(now: Double) -> NetStatus.State {
        switch role {
        case .host(let s):
            if let name = s.dropped.first { return .init(banner: "\(name.uppercased()) DROPPED · A BOT TOOK OVER") }
        case .guest(let s):
            if s.phase == .hostLeft { return .init(banner: "THE HOST LEFT", over: true) }
            if s.hostPaused { return .init(banner: "HOST PAUSED") }
            if s.waiting(now: now) { return .init(banner: "WAITING FOR THE HOST…") }
        }
        return .init()
    }
}

/// The match view's network banner, updated only when it changes.
@MainActor
@Observable
final class NetStatus {
    struct State: Equatable {
        var banner: String?
        /// The match is over for this phone (the host left).
        var over = false
    }

    private(set) var state = State()

    func set(_ s: State) {
        if s != state { state = s }
    }
}
