import SpikeCore

/// What the local player is aiming right now: the serve (drag onto their court) or an attack
/// (touch their court where you want it). The camera keeps the other team's court in view for
/// both (spec §4.4).
enum AimWindow: Equatable, Sendable {
    case serve
    case attack
}

/// The seam between the app and "who is the local human, and what do they own right now".
///
/// Until plan 4 lands ownership (`controlled(by:)`) and contact windows, `SideOwnership` goes by
/// team: the local human's team owns its serves and attacks, and its touches are theirs. Plan 5
/// Task 3 points this at real ownership and the open window, and the camera, haptics and sound
/// follow without other changes.
@MainActor
protocol LocalOwnership {
    /// The local human's team; nil when nobody is playing (`-demo autoplay`).
    var localSide: TeamSide? { get }
    /// The aimed touch the local human owns in `s`, if any.
    func aimWindow(in s: GameState) -> AimWindow?
    /// Whether `athlete`'s touch is the local human's own (for haptics).
    func owns(_ athlete: AthleteID, in s: GameState) -> Bool
}

extension LocalOwnership {
    func isAiming(in s: GameState) -> Bool { aimWindow(in: s) != nil }
}

/// Ownership by side, until plan 4: a serve is aimed while the local team waits to serve, and an
/// attack while the local team's set is in the air on its way to a hitter.
struct SideOwnership: LocalOwnership {
    var localSide: TeamSide?

    func aimWindow(in s: GameState) -> AimWindow? {
        guard let side = localSide else { return nil }
        switch s.phase {
        case .preServe:
            return s.score.serving == side ? .serve : nil
        case .rally:
            guard let p = s.pending, p.team == side, p.kind == .attack else { return nil }
            return .attack
        default:
            return nil
        }
    }

    func owns(_ athlete: AthleteID, in s: GameState) -> Bool {
        athlete.team == localSide
    }
}
