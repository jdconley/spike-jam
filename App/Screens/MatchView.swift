import RealityKit
import SpikeCore
import SwiftUI

/// What kind of match is on.
enum MatchMode: Equatable {
    /// You against the AI, from the start screen. You're the home side.
    case solo(MatchSettings)
    /// Bots against bots, one match after another: `-demo autoplay`.
    case autoplay

    /// The local human's team, if anyone is playing.
    var localSide: TeamSide? {
        if case .solo = self { return .home }
        return nil
    }
}

/// A match on screen: the court, a score line (the real HUD is Task 4), a way back to the menu,
/// and the result when a solo match ends.
struct MatchView: View {
    let exit: () -> Void
    @State private var host: MatchHost
    @State private var score = ScoreLine()
    @State private var winner: TeamSide?
    @Environment(\.scenePhase) private var scenePhase

    init(mode: MatchMode, exit: @escaping () -> Void) {
        self.exit = exit
        _host = State(initialValue: MatchHost(mode: mode))
    }

    var body: some View {
        ZStack(alignment: .top) {
            MatchARView(host: host)
            Text(score.text(autoplay: host.mode == .autoplay))
                .font(.system(size: 15, weight: .black)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
            HStack {
                Button(action: leave) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Menu")
                Spacer()
            }
            .padding(.top, 10).padding(.horizontal, 16)
            if let winner {
                MatchOverCard(winner: winner, score: score, again: {
                    self.winner = nil
                    host.playAgain()
                }, menu: leave)
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .onAppear {
            host.onScore = { score = $0 }
            host.onMatchOver = { winner = $0 }
        }
        .onDisappear { host.stop() }
        // A solo match pauses in the background and picks up without a burst of steps.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { host.loop?.resume() } else { host.loop?.pause() }
        }
    }

    private func leave() {
        host.stop()
        exit()
    }
}

/// The score readout until the HUD (Task 4).
struct ScoreLine: Equatable {
    var home = 0
    var away = 0

    func text(autoplay: Bool) -> String {
        autoplay ? "DEMO · AUTOPLAY    HOME \(home) – \(away) AWAY" : "HOME \(home) – \(away) AWAY"
    }
}

private struct MatchOverCard: View {
    let winner: TeamSide
    let score: ScoreLine
    let again: () -> Void
    let menu: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(winner == .home ? "YOU WIN" : "THEY WIN")
                .font(.system(size: 40, weight: .black).italic())
                .foregroundStyle(.white)
            Text("\(score.home) – \(score.away)")
                .font(.system(size: 22, weight: .black)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 12) {
                Button(action: again) {
                    Text("PLAY AGAIN")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Color(red: 1, green: 0.85, blue: 0.3), in: Capsule())
                }
                Button(action: menu) {
                    Text("MENU")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(28)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Owns a match's scene, loop and presentation: each frame it runs the client loop's states
/// through the slow-motion clock, draws them, moves the camera, and plays the haptics and sound.
@MainActor
final class MatchHost {
    let mode: MatchMode
    let ownership: SideOwnership
    let director: CameraDirector
    let presentation = Presentation()
    private(set) var scene: CourtScene?
    private(set) var loop: GameLoop?
    var onScore: ((ScoreLine) -> Void)?
    var onMatchOver: ((TeamSide) -> Void)?

    private weak var arView: ARView?
    private var haptics: Haptics?
    private let sounds = Sounds()
    private var settings: MatchSettings
    private var shown = ScoreLine()
    private var overSince: Double?
    private var reportedOver = false

    init(mode: MatchMode) {
        self.mode = mode
        ownership = SideOwnership(localSide: mode.localSide)
        director = CameraDirector(ownership: ownership)
        switch mode {
        case .solo(let s): settings = s
        case .autoplay: settings = MatchSettings()
        }
    }

    static func client(_ settings: MatchSettings) -> LocalClientLoop {
        LocalClientLoop(state: GameState(settings: settings))
    }

    func attach(to arView: ARView) {
        guard scene == nil else { return }
        self.arView = arView
        let scene = CourtScene(arView: arView)
        let client = Self.client(settings)
        let loop = GameLoop(client: client)
        loop.onFrame = { [weak self] client, events in self?.frame(client, events) }
        self.scene = scene
        self.loop = loop
        director.reset(to: client.current)
        scene.apply(director.current)
        if mode.localSide != nil { haptics = Haptics() }
        sounds.start()
        loop.start()
    }

    func stop() {
        loop?.stop()
        sounds.stop()
    }

    /// A fresh match with the same settings and a new seed.
    func playAgain() {
        settings.seed &+= 1
        replace()
    }

    private func replace() {
        overSince = nil
        reportedOver = false
        let client = Self.client(settings)
        presentation.reset()
        director.reset(to: client.current)
        loop?.replace(client: client)
    }

    private func frame(_ client: any ClientLoop, _ events: [GameEvent]) {
        guard let scene else { return }
        let f = presentation.frame(prev: client.previous, cur: client.current, alpha: client.alpha, events: events)
        scene.update(prev: f.prev, cur: f.cur, alpha: f.alpha)
        if let v = arView, v.bounds.height > 0 { director.aspect = Float(v.bounds.width / v.bounds.height) }
        scene.apply(director.frame(for: f.cur, events: f.events.map(\.event), dt: f.dt))
        haptics?.play(Haptics.pulses(for: f.events, ownership: ownership, in: f.cur))
        sounds.play(Sounds.cues(for: f.events))

        // The score changes when the point is drawn, not before.
        let s = f.cur
        let line = ScoreLine(home: s.score.points(.home), away: s.score.points(.away))
        if line != shown {
            shown = line
            onScore?(line)
        }
        guard s.phase == .matchOver else {
            overSince = nil
            return
        }
        switch mode {
        case .solo:
            if !reportedOver, let w = s.score.winner {
                reportedOver = true
                onMatchOver?(w)
            }
        case .autoplay:
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

/// The `ARView` in non-AR mode, as the spike proved.
struct MatchARView: UIViewRepresentable {
    let host: MatchHost

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        host.attach(to: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}
}
