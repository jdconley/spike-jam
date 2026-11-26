import RealityKit
import SpikeCore
import SwiftUI

/// Spike Jam Dev: the real app, growing beside the spike until it is playable (plan 5).
@main
struct SpikeJamApp: App {
    let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView(startInAutoplay: options.demo == .autoplay)
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// What the launch arguments ask for. `-demo autoplay` opens straight into an all-bot match.
struct LaunchOptions: Equatable {
    enum Demo: String { case autoplay }

    var demo: Demo?

    init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "-demo"), i + 1 < arguments.count {
            demo = Demo(rawValue: arguments[i + 1])
        }
    }
}

struct RootView: View {
    @State var watching: Bool

    init(startInAutoplay: Bool) {
        _watching = State(initialValue: startInAutoplay)
    }

    var body: some View {
        if watching {
            AutoplayView()
        } else {
            PlaceholderView { watching = true }
        }
    }
}

/// Stands in for the start screen until Task 5.
struct PlaceholderView: View {
    let watch: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.04, blue: 0.1)
            VStack(spacing: 18) {
                Text("SPIKE JAM")
                    .font(.system(size: 54, weight: .black)).italic()
                    .foregroundStyle(.white)
                Text("DEV BUILD")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.6))
                Button(action: watch) {
                    Text("WATCH A BOT MATCH")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(.white, in: Capsule())
                }
            }
        }
    }
}

/// An all-bot match on the wide sideline camera, with no input: `-demo autoplay`.
struct AutoplayView: View {
    @State private var score = ScoreLine()
    @Environment(\.scenePhase) private var scenePhase
    @State private var host = AutoplayHost()

    var body: some View {
        ZStack(alignment: .top) {
            MatchARView(host: host)
            Text(score.text)
                .font(.system(size: 15, weight: .black)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
        }
        .background(Color.black)
        .onAppear { host.onScore = { score = $0 } }
        // A solo match pauses in the background and picks up without a burst of steps.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { host.loop?.resume() } else { host.loop?.pause() }
        }
    }
}

/// The score readout for the demo; the real HUD is Task 4.
struct ScoreLine: Equatable {
    var home = 0
    var away = 0
    var text: String { "DEMO · AUTOPLAY    HOME \(home) – \(away) AWAY" }
}

/// Owns the scene and the loop for an autoplay match, and starts the next match when one ends.
@MainActor
final class AutoplayHost {
    private(set) var scene: CourtScene?
    private(set) var loop: GameLoop?
    var onScore: ((ScoreLine) -> Void)?
    private var seed: UInt64 = 1
    private var overSince: Double?
    private var shown = ScoreLine()

    static func match(seed: UInt64) -> LocalClientLoop {
        var settings = MatchSettings()
        settings.seed = seed
        return LocalClientLoop(state: GameState(settings: settings))
    }

    func attach(to arView: ARView) {
        guard scene == nil else { return }
        let scene = CourtScene(arView: arView)
        let loop = GameLoop(client: Self.match(seed: seed))
        loop.onFrame = { [weak self] client, _ in self?.frame(client) }
        self.scene = scene
        self.loop = loop
        loop.start()
    }

    private func frame(_ client: any ClientLoop) {
        scene?.update(prev: client.previous, cur: client.current, alpha: client.alpha)
        let s = client.current
        let line = ScoreLine(home: s.score.points(.home), away: s.score.points(.away))
        if line != shown {
            shown = line
            onScore?(line)
        }
        // Three seconds after match point, the next match. The clock keeps ticking once it's over.
        guard s.phase == .matchOver else {
            overSince = nil
            return
        }
        let since = overSince ?? s.time
        overSince = since
        if s.time - since > 3 {
            seed += 1
            overSince = nil
            loop?.replace(client: Self.match(seed: seed))
        }
    }
}

/// The `ARView` in non-AR mode, as the spike proved.
struct MatchARView: UIViewRepresentable {
    let host: AutoplayHost

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        host.attach(to: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}
}
