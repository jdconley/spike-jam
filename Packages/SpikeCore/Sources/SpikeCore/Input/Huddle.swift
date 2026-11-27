/// The huddle between rallies (spec §4.3): each human picks who they play and
/// either can change their team's calls; the last change wins. It lasts
/// `Tuning.huddleSeconds` whatever anyone does and never pauses the game.
/// Doing nothing keeps the previous picks and calls. Bot teams call their
/// plays as the serve goes up (`SetterAI.huddle`).
public enum Huddle {
    /// Opens the huddle: every switch reverts to the huddle pick, and nobody
    /// is ready yet.
    public static func begin(_ s: inout GameState) {
        for i in s.humans.indices {
            s.humans[i].switched = nil
            s.humans[i].ready = false
        }
        s.phase = .huddle(untilTick: s.tick + nearestTicks(Tuning.huddleSeconds))
    }

    /// Applies a huddle action (`pick`, `call`, `combo`, `ready`, and
    /// `teamSettings` before the first serve) from `h`. False when it's
    /// rejected: outside the huddle, for the other team, or a pick of the
    /// athlete a teammate picked.
    @discardableResult
    public static func apply(_ a: InputAction, from h: HumanID, _ s: inout GameState) -> Bool {
        guard case .huddle = s.phase, let i = s.humans.firstIndex(where: { $0.id == h }) else { return false }
        let team = s.humans[i].team
        let lineup = s.lineups[team.rawValue], roster = s.rosters[team.rawValue]
        switch a {
        case .pick(let p):
            guard canPlay(p, h, s) else { return false }
            s.humans[i].pick = p
        case .call(let id, let call):
            guard id.team == team, let zone = lineup.zone(of: id),
                  TeamCalls.canRun(call, roster[id].position, frontRow: zone.isFrontRow, system: lineup.system)
            else { return false }
            s.calls[team.rawValue].byAthlete[id] = call
        case .combo(let combo):
            s.calls[team.rawValue].apply(combo, lineup: lineup, roster: roster, isServing: s.isServing(team))
        case .ready:
            s.humans[i].ready = true
        case .teamSettings(let t):
            guard s.serveTick < 0, (1...6).contains(t.startingRotation) else { return false }
            rebuild(&s, team: team, t)
        default:
            return false
        }
        return true
    }

    /// The switch strip (spec §4.1): `h` plays `p` from the next touch until
    /// the next huddle. Not in the huddle (that's a pick) or after the match.
    @discardableResult
    public static func switchTo(_ p: Pick, from h: HumanID, _ s: inout GameState) -> Bool {
        switch s.phase {
        case .huddle, .matchOver: return false
        default: break
        }
        guard let i = s.humans.firstIndex(where: { $0.id == h }), canPlay(p, h, s) else { return false }
        s.humans[i].switched = p
        return true
    }

    /// Whether `h` may play `p`: "ball", or someone in their own team's
    /// lineup whom no teammate plays now.
    static func canPlay(_ p: Pick, _ h: HumanID, _ s: GameState) -> Bool {
        guard case .athlete(let a) = p else { return true }
        guard let me = s.human(h), a.team == me.team else { return false }
        let lineup = s.lineups[a.team.rawValue]
        guard lineup.order.contains(a) || lineup.libero == a else { return false }
        return !s.humans.contains { $0.id != h && $0.team == me.team && ($0.pick == p || $0.current == p) }
    }

    /// A team's system or starting rotation changed before the first serve:
    /// the match starts again from its settings, keeping the clock, the
    /// huddle and the humans.
    static func rebuild(_ s: inout GameState, team: TeamSide, _ t: TeamSettings) {
        var settings = s.settings
        settings.teams[team.rawValue] = t
        var fresh = GameState(settings: settings, humans: s.humans)
        fresh.tick = s.tick
        fresh.phase = s.phase
        fresh.nextContactID = s.nextContactID
        // The other team keeps its calls if its roster didn't change.
        let other = team.other.rawValue
        if fresh.rosters[other] == s.rosters[other] && fresh.lineups[other] == s.lineups[other] {
            fresh.calls[other] = s.calls[other]
        }
        s = fresh
    }
}
