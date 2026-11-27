import Foundation
import Network
import SpikeCore
import SpikeNet
import Testing
@testable import SpikeJam

/// A `SimHuman` behind a reference, for a client loop's input source.
final class SimBox {
    var sim: SimHuman
    init(_ sim: SimHuman) { self.sim = sim }
}

/// A hosting phone and a guest phone in one process, over real `LocalTransport`s on 127.0.0.1.
/// Time is virtual, a display frame (1/120 s) at a step, with a moment of real time between
/// frames for the packets to cross the loopback; so a minute of play takes seconds.
@MainActor
final class NetRig {
    static let frame = 1.0 / 120
    var now = 1000.0
    let host: HostSession
    let guest: GuestSession
    private(set) var hostLoop: HostClientLoop?
    /// The host's game loop is paused (its app left the screen): its frames don't run.
    var hostPaused = false
    var hostSim: SimBox?
    var guestSims: [HumanID: SimBox] = [:]

    init(settings: MatchSettings, guestTeam: TeamSide, hostTeam: TeamSide = .home, guestPick: Pick = .ball) async throws {
        host = HostSession(identity: NetIdentity(nickname: "Pancake Otter", token: 1), settings: settings, advertise: false)
        host.hostTeam = hostTeam
        let deadline = Date().addingTimeInterval(5)
        while host.port == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let port = try #require(host.port.flatMap { NWEndpoint.Port(rawValue: $0) })
        guest = GuestSession(identity: NetIdentity(nickname: "Kong Koala", token: 2),
                             host: NearbyHost(name: "Pancake Otter", endpoint: .hostPort(host: "127.0.0.1", port: port)),
                             team: guestTeam, now: now)
        guest.onLoop = { [unowned self] loop in
            let sim = self.guestSims[loop.human] ?? SimBox(SimHuman(id: loop.human, team: guestTeam, skill: 0.85, pick: guestPick, seed: 7))
            self.guestSims[loop.human] = sim
            loop.inputSource = { s in sim.sim.inputs(for: s) }
        }
    }

    /// Plays the lobby until the host has the guest and the guest has the room.
    func lobby() async -> Bool {
        await run(until: 5) { self.host.present.count == 1 && self.guest.phase == .lobby }
    }

    func start(seed: UInt64 = 9, hostSkill: Float = 0.85) -> HostClientLoop? {
        guard let loop = host.start(seed: seed), let h = host.hostHuman else { return nil }
        let sim = SimBox(SimHuman(id: h, team: host.hostTeam, skill: hostSkill, seed: 3))
        hostSim = sim
        loop.own.inputSource = { s in sim.sim.inputs(for: s) }
        hostLoop = loop
        return loop
    }

    func frame() async {
        now += Self.frame
        if !hostPaused {
            if let hostLoop { _ = hostLoop.advance(to: now) } else { host.pump(now: now) }
        }
        _ = guest.loop.advance(to: now)
        try? await Task.sleep(for: .microseconds(400))
    }

    func run(seconds: Double) async {
        for _ in 0..<Int((seconds / Self.frame).rounded()) { await frame() }
    }

    /// Runs until `done` or `seconds` of virtual time; whether it got there.
    func run(until seconds: Double, _ done: () -> Bool) async -> Bool {
        var t = 0.0
        while !done() {
            if t > seconds { return false }
            await frame()
            t += Self.frame
        }
        return true
    }

    var server: ServerLoop { host.server! }
    var guestClient: PredictingClientLoop? { guest.loop.inner }

    func close() {
        guest.leave()
        host.close()
    }
}

final class Locked: @unchecked Sendable {
    private var n: Int
    private let lock = NSLock()
    init(_ n: Int) { self.n = n }
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@MainActor
@Suite(.serialized) struct LocalNetTests {
    /// Host and guest over real UDP on 127.0.0.1: the lobby, then a short match to the end, with
    /// a simulated human on each phone. No reconnects, nobody dropped, and the guest's state is
    /// the host's.
    @Test func loopbackMatch() async throws {
        var settings = MatchSettings()
        settings.pointsToWin = 2
        settings.winBy = 1
        let rig = try await NetRig(settings: settings, guestTeam: .away)
        defer { rig.close() }
        #expect(await rig.lobby())
        let room = try #require(rig.guest.room)
        #expect(room.players.map(\.nickname) == ["Pancake Otter", "Kong Koala"])
        #expect(room.you?.team == .away)
        #expect(room.host == "Pancake Otter")

        #expect(rig.start() != nil)
        #expect(await rig.run(until: 3) { rig.guest.phase == .playing && rig.guestClient?.snapshotTick != nil })
        let guestHuman = try #require(rig.guestClient?.human)
        #expect(guestHuman != rig.host.hostHuman)
        #expect(rig.server.state.human(guestHuman)?.team == .away)
        #expect(rig.server.state.settings.humanSides == [.home, .away])

        // Thirty seconds of play, then on to the end of the match.
        await rig.run(seconds: 30)
        #expect(rig.server.connected.count == 2)
        #expect(await rig.run(until: 240) { rig.server.state.phase == .matchOver })
        await rig.run(seconds: 1)
        #expect(rig.host.drops == 0)
        #expect(rig.guest.reconnects == 0)
        #expect((rig.server.stats[guestHuman]?.touchInputs ?? 0) > 0)
        let client = try #require(rig.guestClient)
        let stats = rig.server.stats[guestHuman]
        print("loopback match: \(rig.server.state.tick) ticks, score \(rig.server.state.score.points), guest touches \(stats?.touchInputs ?? 0), rewound \(stats?.rewound ?? 0), too late \(stats?.tooLate ?? 0), corrections \(client.corrections), clock jumps \(client.clockJumps)")
        #expect(client.state(at: rig.server.state.tick) == rig.server.state)
        #expect(client.confirmedEvents == rig.hostLoop?.own.confirmedEvents)
    }

    /// Review Focus 4: the guest's Wi-Fi drops for 2 s. The host's AI takes over within a second;
    /// on a new connection the guest is the same human on the same team, its pick back to the
    /// ball, and it picks again at the next huddle.
    @Test func rejoin() async throws {
        var settings = MatchSettings()
        settings.seed = 4
        let pick = Pick.athlete(AthleteID(team: .home, index: 2))
        let rig = try await NetRig(settings: settings, guestTeam: .home, guestPick: pick)
        defer { rig.close() }
        #expect(await rig.lobby())
        #expect(rig.start() != nil)
        #expect(await rig.run(until: 3) { rig.guestClient?.snapshotTick != nil })
        let h = try #require(rig.guestClient?.human)
        // Past the first huddle: the guest picked its athlete.
        #expect(await rig.run(until: 15) { rig.server.state.human(h)?.pick == pick })
        await rig.run(seconds: 3)
        let firstClient = rig.guestClient

        rig.guest.disconnect()
        await rig.run(seconds: 1.2)
        #expect(rig.host.drops == 1)
        #expect(rig.server.state.human(h) == nil)
        #expect(rig.host.dropped == ["Kong Koala"])
        await rig.run(seconds: 0.8)

        rig.guest.reconnect(now: rig.now)
        #expect(await rig.run(until: 3) { rig.guestClient !== firstClient && rig.guestClient?.snapshotTick != nil })
        #expect(rig.guestClient?.human == h)
        let slot = try #require(rig.server.state.human(h))
        #expect(slot.team == .home)
        #expect(slot.pick == .ball)
        #expect(rig.host.dropped.isEmpty)
        #expect(rig.server.connected.count == 2)
        // The next huddle, the guest picks again.
        #expect(await rig.run(until: 90) { rig.server.state.human(h)?.pick == pick })
    }

    /// A match's worth of packets through the links on a network thread (its stack is small): a
    /// handler kept in a `Mutex` of the closure itself grew a thunk per call and overflowed it.
    @Test func manyPacketsThroughTheLinks() async {
        let local = LocalTransport(hosting: nil)
        defer { local.close() }
        let guest = GuestLink(transport: local)
        let net = SimNetwork()
        let host = HostLink(local: local, net: net, serverEnd: net.endpoint(), ownEnd: net.endpoint())
        let count = Locked(0)
        guest.onReceive = { _, _ in count.add() }
        host.onReceive = { _, _ in count.add() }
        let packet = Data([Wire.format, 1, 2, 3])
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "test.network").async {
                for _ in 0..<100_000 {
                    guest.deliver(packet)
                    host.deliver(packet, from: PeerID(raw: 9))
                }
                done.resume()
            }
        }
        #expect(count.value == 200_000)
    }

    /// Nicknames come from the list (spec §5.6): nothing typed, nothing from the device.
    @Test func nicknamesNotTyped() {
        var rng = SeededRNG(seed: 42)
        var seen = Set<String>()
        for _ in 0..<2000 {
            let n = Nicknames.random(rng: &rng)
            #expect(Nicknames.all.contains(n))
            seen.insert(n)
        }
        #expect(seen.count > 300)
        #expect(Nicknames.all.count == Set(Nicknames.all).count)
        #expect(Nicknames.all.allSatisfy { $0.count <= 20 && $0.allSatisfy { $0.isLetter || $0 == " " } })
        for n in Nicknames.all.prefix(50) { #expect(Nicknames.reroll(n, rng: &rng) != n) }

        // A stored name that isn't on the list (typed somehow) is replaced.
        let defaults = try! #require(UserDefaults(suiteName: "LocalNetTests.\(UUID())"))
        defaults.set("Johnny Smith", forKey: NetIdentity.nicknameKey)
        let me = NetIdentity.load(defaults)
        #expect(Nicknames.all.contains(me.nickname))
        #expect(me.token != 0)
        #expect(NetIdentity.load(defaults) == me)
        #expect(NetIdentity.reroll(defaults).token == me.token)
    }
}
