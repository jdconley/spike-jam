import SpikeCore
import SwiftUI

/// What the start screen lets you pick, and the `MatchSettings` it makes.
struct StartChoices: Equatable, Sendable {
    var gameType: GameType = .mens
    var tempo: Tempo = .faster
    var difficulty: Difficulty = .medium
    /// The "Team" section (spec §4.1): tucked away, with the 5-1 and rotation 1 as defaults.
    var system: OffenseSystem = .fiveOne
    var startingRotation = 1

    /// A solo match: you (and your AI teammates) on the home side against the AI. The "Team"
    /// picks are your team's; the AI's team plays the default 5-1 from rotation 1.
    func matchSettings(seed: UInt64) -> MatchSettings {
        var s = MatchSettings()
        s.gameType = gameType
        s.tempo = tempo
        s.difficulty = difficulty
        s.seed = seed
        s.humanSides = [.home]
        s.teams[TeamSide.home.rawValue] = TeamSettings(system: system, startingRotation: min(max(startingRotation, 1), 6))
        return s
    }

    static func name(_ g: GameType) -> String {
        switch g {
        case .mens: "MEN'S"
        case .womens: "WOMEN'S"
        }
    }

    static func name(_ t: Tempo) -> String {
        switch t {
        case .fast: "FAST"
        case .faster: "FASTER"
        case .stupidFast: "STUPID FAST"
        }
    }

    static func name(_ d: Difficulty) -> String {
        switch d {
        case .easy: "EASY"
        case .medium: "MEDIUM"
        case .hard: "HARD"
        }
    }

    static func name(_ s: OffenseSystem) -> String {
        switch s {
        case .fiveOne: "5-1"
        case .sixTwo: "6-2"
        }
    }
}

/// The first screen: Play solo, with the game type, speed and level, and a "Team" section for the
/// 5-1 or 6-2 and the starting rotation. The picks are remembered between launches.
struct StartScreen: View {
    /// Starts a solo match with these settings.
    let play: (MatchSettings) -> Void
    /// Opens an all-bot match to watch.
    let watch: () -> Void
    /// Opens "Play together (same Wi-Fi)".
    var together: () -> Void = {}

    @AppStorage("start.gameType") private var gameType: GameType = .mens
    @AppStorage("start.tempo") private var tempo: Tempo = .faster
    @AppStorage("start.difficulty") private var difficulty: Difficulty = .medium
    @AppStorage("start.system") private var system: OffenseSystem = .fiveOne
    @AppStorage("start.rotation") private var rotation = 1
    @State private var showTeam = false

    var choices: StartChoices {
        StartChoices(gameType: gameType, tempo: tempo, difficulty: difficulty, system: system, startingRotation: rotation)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                titleColumn
                    .frame(width: geo.size.width * 0.4)
                ScrollView(.vertical, showsIndicators: false) {
                    options
                        .padding(.vertical, 20)
                        .frame(minHeight: geo.size.height)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, max(geo.safeAreaInsets.leading, 24))
        }
        .background(StartBackground())
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: -6) {
                Text("SPIKE")
                Text("JAM")
            }
            .font(.system(size: 64, weight: .black).italic())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 0, x: 4, y: 4)
            Text("ARCADE VOLLEYBALL")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.5))
            Button {
                play(choices.matchSettings(seed: UInt64.random(in: 1...UInt64.max)))
            } label: {
                Text("PLAY SOLO")
                    .font(.system(size: 22, weight: .black).italic())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 30).padding(.vertical, 14)
                    .background {
                        Capsule().fill(Color(red: 1, green: 0.85, blue: 0.3))
                            .shadow(color: .black.opacity(0.45), radius: 0, x: 3, y: 3)
                    }
            }
            .accessibilityIdentifier("playSolo")
            .padding(.top, 6)
            Button(action: together) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PLAY TOGETHER")
                        .font(.system(size: 17, weight: .black).italic())
                    Text("SAME WI-FI")
                        .font(.system(size: 10, weight: .heavy)).tracking(1.5)
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24).padding(.vertical, 9)
                .background(.white.opacity(0.16), in: Capsule())
            }
            .accessibilityIdentifier("playTogether")
            Button(action: watch) {
                Text("WATCH A BOT MATCH")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            OptionRow(label: "GAME", options: GameType.allCases, selection: $gameType, name: StartChoices.name)
            OptionRow(label: "SPEED", options: Tempo.allCases, selection: $tempo, name: StartChoices.name)
            OptionRow(label: "LEVEL", options: Difficulty.allCases, selection: $difficulty, name: StartChoices.name)
            Button {
                withAnimation(.snappy(duration: 0.2)) { showTeam.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("TEAM")
                        .font(.system(size: 12, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: optionLabelWidth, alignment: .leading)
                    Text("\(StartChoices.name(system)) · ROTATION \(rotation)")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(.white.opacity(0.7))
                        .rotationEffect(.degrees(showTeam ? 90 : 0))
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("teamSection")
            if showTeam {
                VStack(alignment: .leading, spacing: 12) {
                    OptionRow(label: "SYSTEM", options: [OffenseSystem.fiveOne, .sixTwo], selection: $system,
                              name: StartChoices.name)
                    OptionRow(label: "START IN", options: Array(1...6), selection: $rotation, name: { "\($0)" })
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label and a row of pills, one of them picked.
let optionLabelWidth: CGFloat = 70

struct OptionRow<Option: Hashable>: View {

    let label: String
    let options: [Option]
    @Binding var selection: Option
    let name: (Option) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .heavy)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: optionLabelWidth, alignment: .leading)
            ForEach(options, id: \.self) { option in
                let picked = option == selection
                Button {
                    selection = option
                } label: {
                    Text(name(option))
                        .font(.system(size: 14, weight: .black))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(picked ? .black : .white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(picked ? Color.white : Color.white.opacity(0.12), in: Capsule())
                }
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }
}

/// A dark arena with a faint court drawn at an angle behind the menu.
struct StartBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.07, blue: 0.24), Color(red: 0.03, green: 0.05, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { ctx, size in
                let w = size.width * 0.9, h = w / 2
                var court = Path()
                court.addRect(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                court.move(to: CGPoint(x: 0, y: -h / 2 - 12))
                court.addLine(to: CGPoint(x: 0, y: h / 2 + 12))
                for x in [-w / 6, w / 6] {
                    court.move(to: CGPoint(x: x, y: -h / 2))
                    court.addLine(to: CGPoint(x: x, y: h / 2))
                }
                let t = CGAffineTransform(translationX: size.width * 0.62, y: size.height * 0.55)
                    .rotated(by: -0.32).scaledBy(x: 1, y: 0.55)
                ctx.stroke(court.applying(t), with: .color(.white.opacity(0.07)), lineWidth: 3)
            }
        }
        .ignoresSafeArea()
    }
}
