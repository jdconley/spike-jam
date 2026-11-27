import SpikeCore
import SwiftUI

/// Spike Jam: an arcade volleyball game on SpikeCore (the rules) and SpikeArt (the look).
@main
struct SpikeJamApp: App {
    let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView(launch: options)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// What the launch arguments ask for. `-demo autoplay` opens straight into an all-bot match,
/// `-demo solo` straight into a solo match with the default picks, skipping the start screen, and
/// `-demo assist` into a solo match a robot finger plays through the touch path.
///
/// For two-phone checks on simulators: `-together host` or `-together join` opens "Play together"
/// on that tab; with `-auto` the host opens the room and starts a few seconds after a guest is in,
/// and the guest joins the first host it finds; `-robot` lets the robot finger play this phone's
/// touches in the match. `-port <n>` makes the host listen on port n, and a guest that found a
/// host with Bonjour connect to 127.0.0.1 on port n instead: two simulators on one Mac whose
/// firewall turns away UDP to the Mac's own network address.
struct LaunchOptions: Equatable {
    enum Demo: String { case autoplay, solo, assist }

    var demo: Demo?
    var together: PlayTogetherScreen.Tab?
    var auto = false
    var robot = false
    var port: UInt16?

    init(arguments: [String]) {
        if let i = arguments.firstIndex(of: "-port"), i + 1 < arguments.count { port = UInt16(arguments[i + 1]) }
        if let i = arguments.firstIndex(of: "-demo"), i + 1 < arguments.count {
            demo = Demo(rawValue: arguments[i + 1])
        }
        if let i = arguments.firstIndex(of: "-together"), i + 1 < arguments.count {
            together = arguments[i + 1] == "host" ? .host : .join
        }
        auto = arguments.contains("-auto")
        robot = arguments.contains("-robot")
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
    @State private var together: Bool
    private let launch: LaunchOptions

    init(launch: LaunchOptions) {
        self.launch = launch
        _together = State(initialValue: launch.together != nil)
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
            MatchView(mode: match.mode) {
                // Back to the menu: a match on the same Wi-Fi ends for this phone.
                match.mode.network?.end()
                self.match = nil
            }
            .id(match.id)
        } else if together {
            PlayTogetherScreen(back: { together = false },
                               hosted: { match = Match(mode: .network(NetMatch(host: $0, robot: launch.robot))) },
                               joined: { match = Match(mode: .network(NetMatch(guest: $0, robot: launch.robot))) },
                               startTab: launch.together, auto: launch.auto, loopbackPort: launch.port)
        } else {
            StartScreen(play: { match = Match(mode: .solo($0)) }, watch: { match = Match(mode: .autoplay) },
                        together: { together = true })
        }
    }
}
