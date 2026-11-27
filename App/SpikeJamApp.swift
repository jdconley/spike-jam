import SpikeCore
import SwiftUI

/// Spike Jam: an arcade volleyball game on SpikeCore (the rules) and SpikeArt (the look).
@main
struct SpikeJamApp: App {
    let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView(launch: options)
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// What the launch arguments ask for. `-demo autoplay` opens straight into an all-bot match,
/// `-demo solo` straight into a solo match with the default picks, skipping the start screen, and
/// `-demo assist` into a solo match a robot finger plays through the touch path.
struct LaunchOptions: Equatable {
    enum Demo: String { case autoplay, solo, assist }

    var demo: Demo?

    init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "-demo"), i + 1 < arguments.count {
            demo = Demo(rawValue: arguments[i + 1])
        }
    }
}

/// The start screen, or a match.
struct RootView: View {
    private struct Match: Equatable {
        var mode: MatchMode
        /// A new id makes a new match view, and so a new match.
        var id = UUID()
    }

    @State private var match: Match?

    init(launch: LaunchOptions) {
        let mode: MatchMode? = switch launch.demo {
        case .autoplay: .autoplay
        case .solo: .solo(StartChoices().matchSettings(seed: 1))
        case .assist: .assist(StartChoices().matchSettings(seed: 1))
        case nil: nil
        }
        _match = State(initialValue: mode.map { Match(mode: $0) })
    }

    var body: some View {
        if let match {
            MatchView(mode: match.mode) { self.match = nil }
                .id(match.id)
        } else {
            StartScreen(play: { match = Match(mode: .solo($0)) }, watch: { match = Match(mode: .autoplay) })
        }
    }
}
