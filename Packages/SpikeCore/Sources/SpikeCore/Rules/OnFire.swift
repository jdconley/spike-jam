/// An athlete's streak toward catching fire (spec §4.4). Streaks belong to
/// the athlete, whoever controls them, so bots catch fire too.
public struct FireState: Codable, Equatable, Sendable {
    /// Kills in a row: a teammate's kill, or the athlete's own attack losing
    /// the point, ends it.
    public var killStreak: Int
    /// A libero's perfect passes and digs in a row.
    public var perfectStreak: Int
    public var onFire: Bool

    public init(killStreak: Int = 0, perfectStreak: Int = 0, onFire: Bool = false) {
        self.killStreak = killStreak
        self.perfectStreak = perfectStreak
        self.onFire = onFire
    }
}

/// On fire (spec §4.4): a hitter with `fireStreak` kills in a row, or a
/// libero with that many perfect passes or digs, catches fire, and it ends
/// when the other team scores. An on-fire hitter hits faster and harder and
/// is harder to stuff; an on-fire libero covers more ground and passes
/// perfectly (`Tuning`'s fire numbers, from the spike).
public enum OnFire {
    /// Keeps the streaks up to date with one event, adding a `fire` event to
    /// `events` when someone catches fire or cools off.
    public static func record(_ e: GameEvent, _ s: inout GameState, _ events: inout [GameEvent]) {
        switch e {
        case .touched(.attack, let hitter, _):
            s.notes.lastAttacker = hitter
        case .touched(let kind, let id, let quality) where kind == .receive || kind == .dig:
            guard s.rosters[id.team.rawValue][id].position == .libero else { return }
            var f = s.fire[id] ?? FireState()
            f.perfectStreak = quality >= Tuning.perfectPass ? f.perfectStreak + 1 : 0
            if f.perfectStreak >= Tuning.fireStreak && !f.onFire {
                f.onFire = true
                events.append(.fire(id, on: true))
            }
            set(id, f, &s)
        case .point(let winner, let reason):
            // The other team scored: the losers cool off, and start their
            // streaks again.
            for id in s.fire.keys.sorted(by: { $0.index < $1.index }) where id.team == winner.other && s.fire[id]!.onFire {
                events.append(.fire(id, on: false))
                set(id, FireState(), &s)
            }
            // A hitter whose own attack loses the point breaks their streak.
            if reason == .attackError || reason == .block, let hitter = s.notes.lastAttacker, hitter.team != winner,
               var f = s.fire[hitter] {
                f.killStreak = 0
                set(hitter, f, &s)
            }
            guard reason == .kill, let hitter = s.notes.lastAttacker, hitter.team == winner else { return }
            // A teammate's kill breaks the streak (the other team's points
            // put out fires instead).
            for id in s.fire.keys.sorted(by: { $0.index < $1.index })
            where id != hitter && id.team == hitter.team && s.fire[id]!.killStreak > 0 {
                var f = s.fire[id]!
                f.killStreak = 0
                set(id, f, &s)
            }
            var f = s.fire[hitter] ?? FireState()
            f.killStreak += 1
            if f.killStreak >= Tuning.fireStreak && !f.onFire {
                f.onFire = true
                events.append(.fire(hitter, on: true))
            }
            set(hitter, f, &s)
        default:
            break
        }
    }

    public static func isOnFire(_ id: AthleteID, _ s: GameState) -> Bool {
        s.fire[id]?.onFire ?? false
    }

    /// Keeps only athletes with something going.
    static func set(_ id: AthleteID, _ f: FireState, _ s: inout GameState) {
        s.fire[id] = f == FireState() ? nil : f
    }

    /// The speed cap multiplier for `id`: an on-fire libero covers more ground.
    static func speedScale(_ id: AthleteID, _ s: GameState) -> Float {
        guard !s.fire.isEmpty, isOnFire(id, s), id == s.lineups[id.team.rawValue].libero else { return 1 }
        return Tuning.fireLiberoSpeed
    }
}
