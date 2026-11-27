import QuartzCore
import RealityKit
import SpikeCore
import SwiftUI

/// What kind of match is on.
enum MatchMode: Equatable {
    /// You against the AI, from the start screen. You're the home side.
    case solo(MatchSettings)
    /// Bots against bots, one match after another: `-demo autoplay`.
    case autoplay
    /// A solo match whose touches a robot finger plays through the real touch path:
    /// `-demo assist`, for screenshots and checks without a person.
    case assist(MatchSettings)
    /// A match on the same Wi-Fi, hosted here or joined (plan 6).
    case network(NetMatch)

    /// The local human's team, if anyone is playing.
    var localSide: TeamSide? {
        switch self {
        case .solo, .assist: .home
        case .autoplay: nil
        case .network(let n): n.side
        }
    }

    var settings: MatchSettings {
        switch self {
        case .solo(let s), .assist(let s): s
        case .autoplay: MatchSettings()
        case .network(let n): n.settings
        }
    }

    var network: NetMatch? {
        if case .network(let n) = self { return n }
        return nil
    }

    /// The robot finger plays the local human's touches.
    var robotPlays: Bool {
        switch self {
        case .assist: true
        case .network(let n): n.robot
        case .solo, .autoplay: false
        }
    }
}

/// A match on screen: the court, the HUD, the switch strip and the huddle over it, and the result
/// when a solo match ends.
struct MatchView: View {
    let exit: () -> Void
    @State private var host: MatchHost
    @State private var winner: TeamSide?
    @Environment(\.scenePhase) private var scenePhase

    init(mode: MatchMode, exit: @escaping () -> Void) {
        self.exit = exit
        _host = State(initialValue: MatchHost(mode: mode))
    }

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .onChange(of: geo.size, initial: true) { _, size in host.viewSize = size }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .animation(.easeOut(duration: 0.2), value: host.hud.huddle == nil)
        .onAppear {
            host.onMatchOver = { winner = $0 }
            // A guest's next match (the host played again) clears the result.
            host.onNewMatch = { winner = nil }
        }
        .onDisappear { host.stop() }
        // A solo match pauses in the background and picks up without a burst of steps.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { host.loop?.resume() } else { host.loop?.pause() }
        }
    }

    /// The court with everything over it, in the full screen's coordinates (the HUD keeps to the
    /// safe area itself, through `HUDLayout`).
    private var content: some View {
        let hud = host.hud
        let layout = hud.layout
        return ZStack(alignment: .topLeading) {
            MatchARView(host: host)
            HUDView(model: hud, layout: layout, autoplay: host.mode == .autoplay, menu: leave)
            if !hud.strip.isEmpty {
                SwitchStrip(chips: hud.strip, tap: hud.tapStrip)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MatchView.space)) } action: { host.stripFrame = $0 }
                    .onDisappear { host.stripFrame = nil }
                    .position(x: layout.stripRect.midX, y: layout.stripRect.midY)
            }
            if let huddle = hud.huddle, !huddle.ready {
                HuddleView(huddle: huddle, pick: hud.tapPick, cycle: hud.tapCall, explain: hud.showMeaning, ready: hud.tapReady)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MatchView.space)) } action: { host.huddleFrame = $0 }
                    .onDisappear { host.huddleFrame = nil }
                    .position(x: layout.leading + HuddleView.width / 2,
                              y: HUDLayout.topBand + (layout.size.height - HUDLayout.topBand) / 2)
                    .transition(.opacity)
            }
            if let banner = host.net.state.banner {
                NetBanner(text: banner)
                    .position(x: layout.size.width / 2, y: HUDLayout.topBand + 34)
                    .allowsHitTesting(false)
            }
            if host.net.state.over {
                HostLeftCard(menu: leave)
                    .frame(width: layout.size.width, height: layout.size.height)
            } else if let winner {
                MatchOverCard(won: winner == host.mode.localSide, score: hud.score,
                              again: host.canPlayAgain ? {
                                  self.winner = nil
                                  host.playAgain()
                              } : nil,
                              waiting: host.mode.network.map { !$0.isHost } ?? false, menu: leave)
                .frame(width: layout.size.width, height: layout.size.height)
            }
        }
        .coordinateSpace(.named(MatchView.space))
    }

    nonisolated static let space = "match"

    private func leave() {
        host.stop()
        exit()
    }
}

private struct MatchOverCard: View {
    let won: Bool
    let score: ScoreLine
    /// Nil on a guest's phone: the host plays again.
    let again: (() -> Void)?
    var waiting = false
    let menu: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(won ? "YOU WIN" : "THEY WIN")
                .font(.system(size: 40, weight: .black).italic())
                .foregroundStyle(.white)
            Text("\(score.home) – \(score.away)")
                .font(.system(size: 22, weight: .black)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
            if waiting {
                Text("Waiting for the host to play again…")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 12) {
                if let again {
                    Button(action: again) {
                        Text("PLAY AGAIN")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22).frame(minHeight: 50)
                            .background(HUDStyle.gold, in: Capsule())
                    }
                }
                Button(action: menu) {
                    Text("MENU")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(minHeight: 50)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(28)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// A line over the court for a match on the same Wi-Fi: "Host paused", a guest dropped.
private struct NetBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(HUDStyle.font(15)).italic()
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(HUDStyle.ink, in: Capsule())
            .accessibilityIdentifier("netBanner")
    }
}

/// The host ended the match (or went away for good): back to the menu.
private struct HostLeftCard: View {
    let menu: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("THE HOST LEFT")
                .font(.system(size: 34, weight: .black).italic())
                .foregroundStyle(.white)
            Button(action: menu) {
                Text("MENU")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22).frame(minHeight: 50)
                    .background(HUDStyle.gold, in: Capsule())
            }
        }
        .padding(28)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Owns a match: its client loop, scene, camera, ownership, touches, HUD, haptics and sound.
/// Each frame it runs the client loop's states through the slow-motion clock, draws them, moves
/// the camera, and derives the HUD.
///
/// Plan 6 hands it a networked `ClientLoop` through `makeClient`; nothing else here changes.
@MainActor
final class MatchHost {
    /// Makes the client loop for a match: its settings and the humans in it.
    typealias ClientFactory = @MainActor (MatchSettings, [HumanSlot]) -> any ClientLoop

    /// The solo human (spec §4.6): one person, on home.
    static let soloHuman = HumanID(raw: 1)

    let mode: MatchMode
    /// The local human: `soloHuman` in a solo match, nobody in autoplay.
    let human: HumanID?
    let ownership: HumanOwnership
    let director: CameraDirector
    let hud: HUDModel
    /// Fingers on the court to SpikeCore actions; nil when nobody plays.
    let translator: TouchTranslator?
    let presentation = Presentation()
    private(set) var scene: CourtScene?
    private(set) var loop: GameLoop?
    private(set) var controller: ControllerInput?
    private(set) var demo: DemoFinger?
    var onMatchOver: ((TeamSide) -> Void)?
    /// A new match started without this view asking (the host played again, on a guest's phone).
    var onNewMatch: (() -> Void)?
    /// The network banner, for a match on the same Wi-Fi.
    let net = NetStatus()

    /// The view's size and the HUD's frames, from SwiftUI: the strip and the huddle never take
    /// timing taps.
    var viewSize: CGSize = .zero { didSet { relayout() } }
    var stripFrame: CGRect? { didSet { excludeRects() } }
    var huddleFrame: CGRect? { didSet { excludeRects() } }

    private let makeClient: ClientFactory
    private weak var arView: ARView?
    private var haptics: Haptics?
    private let sounds = Sounds()
    private var settings: MatchSettings
    private var overSince: Double?
    private var reportedOver = false
    private var lastFrame: Double?
    private var guestMatch = 0

    init(mode: MatchMode, makeClient: @escaping ClientFactory = MatchHost.localClient) {
        self.mode = mode
        if let n = mode.network {
            // The session made the loop (and makes the next one, on Play again).
            self.makeClient = { _, _ in n.client }
            human = n.human
        } else {
            self.makeClient = makeClient
            human = mode.localSide == nil ? nil : Self.soloHuman
        }
        settings = mode.settings
        ownership = HumanOwnership(human: human, side: mode.localSide)
        director = CameraDirector(ownership: ownership)
        hud = HUDModel(human: human, ownership: ownership)
        if let human {
            translator = TouchTranslator(human: human, ownership: ownership) { _, _ in }
        } else {
            translator = nil
        }
        translator?.send = { [weak self] action, time in self?.send(action, at: time) }
        hud.send = { [weak self] action in self?.send(action, at: CACurrentMediaTime()) }
    }

    /// The solo client: SpikeCore stepped right here.
    static func localClient(_ settings: MatchSettings, _ humans: [HumanSlot]) -> any ClientLoop {
        LocalClientLoop(state: GameState(settings: settings, humans: humans))
    }

    /// The humans a match starts with: the solo human on home, following the ball.
    var humans: [HumanSlot] {
        guard let human, let side = mode.localSide else { return [] }
        return [HumanSlot(id: human, team: side, pick: .ball)]
    }

    /// An action from the local human, at touch time `time`.
    func send(_ action: InputAction, at time: Double) {
        guard let human, let client = loop?.client else { return }
        client.send(PlayerInput(human: human, tick: 0, action: action), at: time)
    }

    func attach(to arView: CourtARView) {
        guard scene == nil else { return }
        self.arView = arView
        let scene = CourtScene(arView: arView)
        let client = makeClient(settings, humans)
        let loop = GameLoop(client: client)
        loop.onFrame = { [weak self] client, events in self?.frame(client, events) }
        loop.touches = translator
        arView.onTouch = { [weak loop] phase, p, t, key in loop?.touch(phase, p, t: t, key: key) }
        self.scene = scene
        self.loop = loop
        director.reset(to: client.current)
        scene.apply(director.current)
        if let translator {
            haptics = Haptics()
            let controller = ControllerInput(translator: translator, strip: { [weak self] in self?.hud.strip ?? [] },
                                             switchTo: { [weak self] in self?.hud.tapStrip($0) })
            controller.start()
            self.controller = controller
            if mode.robotPlays { demo = DemoFinger(translator: translator, ownership: ownership) }
        }
        sounds.start()
        loop.start()
    }

    func stop() {
        loop?.stop()
        controller?.stop()
        sounds.stop()
    }

    /// Whether this phone can start the next match: not a guest's (the host does).
    var canPlayAgain: Bool { mode.network.map(\.isHost) ?? true }

    /// A fresh match with the same settings and a new seed. On the same Wi-Fi, the host's
    /// session starts it for every phone.
    func playAgain() {
        if let n = mode.network {
            guard n.rematch() else { return }
        } else {
            settings.seed &+= 1
        }
        replace()
    }

    /// The guest's loop moved on to a new match by itself: start the drawing over.
    private func startedOver(_ client: any ClientLoop) {
        overSince = nil
        reportedOver = false
        presentation.reset()
        ownership.reset()
        director.reset(to: client.current)
        onNewMatch?()
    }

    private func replace() {
        overSince = nil
        reportedOver = false
        let client = makeClient(settings, humans)
        presentation.reset()
        ownership.reset()
        director.reset(to: client.current)
        loop?.replace(client: client)
        if let translator, mode.robotPlays { demo = DemoFinger(translator: translator, ownership: ownership) }
    }

    private func relayout() {
        guard viewSize.width > 0 else { return }
        // The window's: the court view itself runs under the Dynamic Island and the home indicator.
        let insets = arView?.window?.safeAreaInsets ?? arView?.safeAreaInsets ?? .zero
        let layout = HUDLayout(size: viewSize, insets: EdgeInsets(top: insets.top, leading: insets.left,
                                                                    bottom: insets.bottom, trailing: insets.right))
        if hud.layout != layout { hud.layout = layout }
        director.aimBands = layout.aimBands
        excludeRects()
    }

    private func excludeRects() {
        let layout = hud.layout
        // Only what's on screen: a huddle that closed takes no taps.
        let strip = hud.strip.isEmpty ? nil : stripFrame
        let huddle = hud.huddle.map { $0.ready } == false ? huddleFrame : nil
        let rects = [strip, huddle, layout.menuRect].compactMap { $0 }.map { $0.insetBy(dx: -4, dy: -4) }
        if translator?.excludedRects != rects { translator?.excludedRects = rects }
    }

    private func frame(_ client: any ClientLoop, _ events: [GameEvent]) {
        guard let scene else { return }
        if let n = mode.network {
            net.set(n.status(now: CACurrentMediaTime()))
            // The host played again: a guest's loop has the new match.
            if let g = client as? GuestClientLoop, g.matchNumber != guestMatch {
                let first = guestMatch == 0
                guestMatch = g.matchNumber
                if !first { startedOver(client) }
            }
        }
        let live = client.current
        ownership.observe(events, in: live)
        translator?.update(live)

        let f = presentation.frame(prev: client.previous, cur: live, alpha: client.alpha, events: events)
        scene.update(prev: f.prev, cur: f.cur, alpha: f.alpha)
        if let v = arView, v.bounds.height > 0 {
            director.aspect = Float(v.bounds.width / v.bounds.height)
            if v.bounds.size != viewSize || hud.layout.insets == EdgeInsets() && v.window != nil { viewSize = v.bounds.size }
        }
        let shot = director.frame(for: f.cur, events: f.events.map(\.event), dt: f.dt)
        scene.apply(shot)
        let view = ScreenProjector(shot: shot, size: viewSize)
        translator?.projector = view

        // The live match time: the clock touches are stamped and judged on.
        let now = live.time + client.alpha * Tuning.dt
        let clock = CACurrentMediaTime()
        let wallDt = min(max(clock - (lastFrame ?? clock), 0), 0.1)
        lastFrame = clock
        controller?.frame(dt: wallDt, view: view, ownership: ownership, state: live)
        demo?.frame(live, time: now, clock: clock, view: view)

        var frame = HUDModel.Frame(live: live, events: events, time: now, view: view, aim: translator?.aim)
        frame.drawnPrev = f.prev
        frame.drawn = f.cur
        frame.alpha = f.alpha
        frame.shownEvents = f.events.map(\.event)
        hud.update(frame)
        excludeRects()
        translator?.labelTargets = hud.setLabels.map { ($0.id, CGRect(x: $0.at.x - 50, y: $0.at.y - 26, width: 100, height: 52)) }

        haptics?.play(Haptics.pulses(for: f.events, ownership: ownership, in: f.cur))
        sounds.play(Sounds.cues(for: f.events, ownership: ownership))

        let s = f.cur
        guard s.phase == .matchOver else {
            overSince = nil
            return
        }
        switch mode {
        case .solo, .network:
            if !reportedOver, let w = s.score.winner {
                reportedOver = true
                onMatchOver?(w)
            }
        case .autoplay, .assist:
            // Three seconds after match point, the next match.
            let since = overSince ?? s.time
            overSince = since
            if s.time - since > 3 {
                settings.seed &+= 1
                replace()
            }
        }
    }
}

/// The court's `ARView` (non-AR, as the spike proved), passing its touches on with their own
/// timestamps.
final class CourtARView: ARView {
    var onTouch: ((TouchPhase, CGPoint, Double, Int) -> Void)?

    enum TouchPhase { case began, moved, ended, cancelled }

    private func forward(_ touches: Set<UITouch>, _ phase: TouchPhase) {
        for t in touches {
            onTouch?(phase, t.location(in: self), t.timestamp, ObjectIdentifier(t).hashValue)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .cancelled) }
}

struct MatchARView: UIViewRepresentable {
    let host: MatchHost

    func makeUIView(context: Context) -> CourtARView {
        let view = CourtARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.isMultipleTouchEnabled = true
        host.attach(to: view)
        return view
    }

    func updateUIView(_ view: CourtARView, context: Context) {}
}
