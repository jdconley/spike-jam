/// The AI's level in solo games (spec §4.9). It moves the AI's average
/// quality, not its variety: easy AI still makes good plays, and hard AI
/// still errs. The display names are the app's choice.
public enum Difficulty: String, Codable, Sendable, CaseIterable {
    case easy, medium, hard

    /// Added to every trait the AI rolls a touch around.
    public var traitShift: Float {
        switch self {
        case .easy: -0.12
        case .medium: 0
        case .hard: 0.08
        }
    }

    /// Multiplies every AI error chance.
    public var errorScale: Float {
        switch self {
        case .easy: 1.3
        case .medium: 1.0
        case .hard: 0.8
        }
    }
}
