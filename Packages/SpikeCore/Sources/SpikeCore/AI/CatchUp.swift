/// The hidden catch-up against the AI (spec §4.9), like rubber-banding in a
/// kart racer: when a human's team trails, the AI against them errs a little
/// more and sets a little less sharply, and their AI teammates play a little
/// better; when it leads, the reverse. Human touches are never changed.
///
/// It is computed from the score each time, never stored, so the server and
/// every client agree and prediction can't drift. It starts at a 2-point
/// margin, grows with the gap to full strength at 6, and is bounded there:
/// no bigger boost at game point, so it narrows a gap but can't flip one.
public enum CatchUp {
    /// Each side's level, −1...1: positive makes that side's bots play
    /// better, negative worse.
    /// - Exactly one side has humans and `catchUp` is on: both sides are
    ///   nudged by the human side's deficit (the AI side the opposite way).
    /// - Humans on both sides and `keepItClose` is on: each side's bots by
    ///   that side's own deficit.
    /// - Otherwise 0.
    public static func level(_ s: GameState) -> [TeamSide: Float] {
        let humans = s.settings.humanSides.count
        let on = (humans == 1 && s.settings.catchUp) || (humans == 2 && s.settings.keepItClose)
        guard on else { return [.home: 0, .away: 0] }
        return [.home: nudge(deficit: s.score.points(.away) - s.score.points(.home)),
                .away: nudge(deficit: s.score.points(.home) - s.score.points(.away))]
    }

    /// 0 within a point, then (|deficit| − 1) / 5 up to 1, positive for the
    /// side behind.
    public static func nudge(deficit: Int) -> Float {
        let gap = abs(deficit)
        guard gap > 1 else { return 0 }
        return Float(deficit.signum()) * min(1, Float(gap - 1) / 5)
    }
}
