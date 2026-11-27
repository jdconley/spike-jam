import Network
import QuartzCore
import SpikeCore
import SwiftUI

/// "Play together (same Wi-Fi)" (plan 6): host a match or join one nearby, then the lobby, where
/// each phone picks Home or Away (teammates or opponents) and the host taps Start. Each phone goes
/// by a generated nickname with dice to reroll it, never a typed name (spec §5.6).
struct PlayTogetherScreen: View {
    let back: () -> Void
    /// The host tapped Start.
    let hosted: (HostSession) -> Void
    /// The host started the match this phone is in.
    let joined: (GuestSession) -> Void
    /// The tab to open on (`-together`).
    var startTab: Tab?
    /// Open the room and start, or join the first host found, without taps (`-auto`).
    var auto = false
    /// `-port`: host on this port, and join hosts found nearby over the loopback on it.
    var loopbackPort: UInt16?

    enum Tab: Hashable { case host, join }

    @State private var me = NetIdentity.load()
    @State private var tab: Tab = .join
    @State private var host: HostSession?
    @State private var guest: GuestSession?
    @State private var browser = LocalBrowser()
    @State private var autoSince: Double?
    @AppStorage("start.gameType") private var gameType: GameType = .mens
    @AppStorage("start.tempo") private var tempo: Tempo = .faster
    @AppStorage("start.difficulty") private var difficulty: Difficulty = .medium
    @AppStorage("together.team") private var team: TeamSide = .home

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 24) {
                titleColumn
                    .frame(width: geo.size.width * 0.34)
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if let host {
                            HostLobby(session: host, start: { start(host) }, leave: closeHost)
                        } else if let guest {
                            GuestLobby(session: guest, leave: leaveGuest)
                        } else {
                            chooser
                        }
                    }
                    .padding(.vertical, 20)
                    .frame(minHeight: geo.size.height, alignment: .center)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, max(geo.safeAreaInsets.leading, 24))
        }
        .background(StartBackground())
        // The lobby's packets, a few times a second (in a match, the game loop takes over).
        .task {
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                host?.pump(now: now)
                if auto { autoStep(now) }
                if let guest {
                    guest.pump(now: now)
                    if guest.phase == .playing {
                        joined(guest)
                        self.guest = nil
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        .onAppear {
            if let startTab { tab = startTab }
        }
        .onChange(of: tab, initial: true) { _, t in
            if t == .join && host == nil && guest == nil { browser.start() } else { browser.stop() }
        }
        .onDisappear { browser.stop() }
    }

    // MARK: - The left column

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: -4) {
                Text("PLAY")
                Text("TOGETHER")
            }
            .font(.system(size: 40, weight: .black).italic())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 0, x: 3, y: 3)
            Text("SAME WI-FI")
                .font(.system(size: 12, weight: .heavy)).tracking(2)
                .foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 6) {
                Text("YOU ARE")
                    .font(.system(size: 11, weight: .heavy)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 10) {
                    Text(me.nickname.uppercased())
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(HUDStyle.gold)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Button {
                        me = NetIdentity.reroll()
                    } label: {
                        Image(systemName: "dice.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .accessibilityLabel("New nickname")
                    .accessibilityIdentifier("rerollNickname")
                    .disabled(host != nil || guest != nil)
                    .opacity(host != nil || guest != nil ? 0.35 : 1)
                }
            }
            .padding(.top, 8)
            Button(action: leaveAll) {
                Label("BACK", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.vertical, 8)
            }
            .accessibilityIdentifier("togetherBack")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Host or join

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                TabPill(title: "JOIN A MATCH", picked: tab == .join) { tab = .join }
                    .accessibilityIdentifier("tabJoin")
                TabPill(title: "HOST A MATCH", picked: tab == .host) { tab = .host }
                    .accessibilityIdentifier("tabHost")
            }
            if tab == .host {
                hostSetup
            } else {
                joinList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hostSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            OptionRow(label: "GAME", options: GameType.allCases, selection: $gameType, name: StartChoices.name)
            OptionRow(label: "SPEED", options: Tempo.allCases, selection: $tempo, name: StartChoices.name)
            OptionRow(label: "LEVEL", options: Difficulty.allCases, selection: $difficulty, name: StartChoices.name)
            BigButton(title: "OPEN THE ROOM", action: openRoom)
                .accessibilityIdentifier("openRoom")
                .padding(.top, 6)
            Text("Phones on this Wi-Fi can join. Bots fill the other spots.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var joinList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if browser.hosts.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Looking for a match on this Wi-Fi…")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.vertical, 8)
                Text("On the other phone, tap HOST A MATCH, then OPEN THE ROOM.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            ForEach(browser.hosts) { h in
                Button { join(h) } label: {
                    HStack {
                        Image(systemName: "wifi")
                            .font(.system(size: 14, weight: .black))
                        Text(h.name.uppercased())
                            .font(.system(size: 16, weight: .black))
                        Spacer()
                        Text("JOIN")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(HUDStyle.gold, in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("join \(h.name)")
            }
            if let problem = browser.problem {
                Text(problem)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.5))
            }
        }
    }

    // MARK: - Actions

    /// `-auto`: the host opens the room, and starts three seconds after a guest is in (time for a
    /// screenshot of the lobby); a guest joins the first host it sees.
    private func autoStep(_ now: Double) {
        if tab == .host {
            guard let host else {
                if guest == nil { openRoom() }
                return
            }
            if host.present.isEmpty {
                autoSince = nil
            } else if let since = autoSince {
                if now - since > 3 { start(host) }
            } else {
                autoSince = now
            }
        } else if host == nil, guest == nil, let first = browser.hosts.first {
            join(first)
        }
    }

    private func openRoom() {
        var choices = StartChoices()
        choices.gameType = gameType
        choices.tempo = tempo
        choices.difficulty = difficulty
        let s = HostSession(identity: me, settings: choices.matchSettings(seed: 1), port: loopbackPort ?? 0)
        s.hostTeam = team
        browser.stop()
        host = s
    }

    private func join(_ h: NearbyHost) {
        var h = h
        if let p = loopbackPort, let port = NWEndpoint.Port(rawValue: p) { h.endpoint = .hostPort(host: "127.0.0.1", port: port) }
        browser.stop()
        guest = GuestSession.join(h, as: me, team: team, now: CACurrentMediaTime())
    }

    private func start(_ session: HostSession) {
        team = session.hostTeam
        session.start()
        hosted(session)
        host = nil
    }

    private func closeHost() {
        host?.close()
        host = nil
        if tab == .join { browser.start() }
    }

    private func leaveGuest() {
        if let g = guest { team = g.team }
        guest?.leave()
        guest = nil
        browser.start()
    }

    private func leaveAll() {
        host?.close()
        guest?.leave()
        host = nil
        guest = nil
        back()
    }
}

// MARK: - Lobbies

/// The room on the hosting phone: who's in, the host's side, and Start.
private struct HostLobby: View {
    @Bindable var session: HostSession
    let start: () -> Void
    let leave: () -> Void

    var body: some View {
        let room = session.room(for: nil)
        VStack(alignment: .leading, spacing: 14) {
            RoomHeader(room: room, waiting: room.players.count < 2 ? "Waiting for players…" : nil)
            Teams(room: room)
            SidePicker(team: Binding(get: { session.hostTeam }, set: { session.hostTeam = $0 }))
            HStack(spacing: 12) {
                BigButton(title: "START", enabled: room.players.count >= 2, action: start)
                    .accessibilityIdentifier("startMatch")
                SmallButton(title: "CLOSE ROOM", action: leave)
            }
            if case .waiting(let why) = session.transportState {
                Problem(text: why)
            } else if case .failed(let why) = session.transportState {
                Problem(text: why)
            }
        }
    }
}

/// The room on a joining phone: who's in, this phone's side, and waiting for Start.
private struct GuestLobby: View {
    @Bindable var session: GuestSession
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .connecting:
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Joining \(session.host.name.uppercased())…")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                }
            case .refused(let why):
                Problem(text: why)
            case .hostLeft:
                Problem(text: "\(session.host.name) closed the room.")
            case .lobby, .playing:
                if let room = session.room {
                    RoomHeader(room: room, waiting: room.started ? "Joining the match…" : "Waiting for \(room.host) to start…")
                    Teams(room: room)
                }
            }
            if session.phase == .lobby || session.phase == .connecting {
                SidePicker(team: Binding(get: { session.team }, set: { session.pick($0, now: CACurrentMediaTime()) }))
            }
            SmallButton(title: "LEAVE", action: leave)
        }
    }
}

private struct RoomHeader: View {
    let room: Room
    let waiting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(room.host.uppercased())'S ROOM")
                .font(.system(size: 22, weight: .black).italic())
                .foregroundStyle(.white)
            Text("\(StartChoices.name(room.gameType)) · \(StartChoices.name(room.tempo)) · \(StartChoices.name(room.difficulty))")
                .font(.system(size: 12, weight: .heavy)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
            if let waiting {
                Text(waiting)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HUDStyle.gold)
                    .padding(.top, 2)
            }
        }
    }
}

/// Home and Away, with each phone's nickname on its side, and what the phones are to each other.
private struct Teams: View {
    let room: Room

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                column(.home)
                column(.away)
            }
            if let you = room.you, let other = room.players.first(where: { !$0.isYou }), room.players.count == 2 {
                Text("YOU AND \(other.nickname.uppercased()) ARE \(Room.relation(you.team, other.team))")
                    .font(.system(size: 12, weight: .heavy)).tracking(1)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func column(_ side: TeamSide) -> some View {
        let players = room.players.filter { $0.team == side }
        return VStack(alignment: .leading, spacing: 6) {
            Text(side == .home ? "HOME" : "AWAY")
                .font(.system(size: 12, weight: .heavy)).tracking(1.5)
                .foregroundStyle(side == .home ? Color(red: 1, green: 0.55, blue: 0.3) : Color(red: 0.45, green: 0.75, blue: 1))
            ForEach(players) { p in
                // The tags under the name, so neither is cut off in a narrow column.
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.nickname)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(p.connected ? .white : .white.opacity(0.4))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    let tags = [p.isYou ? "YOU" : nil, p.isHost ? "HOST" : nil].compactMap { $0 }
                    if !tags.isEmpty { Tag(text: tags.joined(separator: " · ")).fixedSize() }
                }
            }
            if players.isEmpty {
                Text("Bots")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SidePicker: View {
    @Binding var team: TeamSide

    var body: some View {
        OptionRow(label: "YOUR SIDE", options: [TeamSide.home, .away], selection: $team, name: { $0 == .home ? "HOME" : "AWAY" })
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .black)).tracking(0.8)
            .foregroundStyle(.black)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.white.opacity(0.85), in: Capsule())
    }
}

private struct Problem: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.5))
    }
}

private struct TabPill: View {
    let title: String
    let picked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(picked ? .black : .white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(picked ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

private struct BigButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .black).italic())
                .foregroundStyle(.black)
                .padding(.horizontal, 26).padding(.vertical, 12)
                .background {
                    Capsule().fill(HUDStyle.gold)
                        .shadow(color: .black.opacity(0.45), radius: 0, x: 3, y: 3)
                }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.white.opacity(0.14), in: Capsule())
        }
    }
}
