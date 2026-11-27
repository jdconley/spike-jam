import SpikeCore

/// What the local player is aiming right now: the serve (drag onto their court) or an attack
/// (touch their court where you want it). The camera keeps the other team's court in view for
/// both (spec §4.4).
enum AimWindow: Equatable, Sendable {
    case serve
    case attack
}

/// The seam between the app and "who is the local human, and what do they own right now". The
/// camera, haptics and sound read it; `HumanOwnership` is the real one.
@MainActor
protocol LocalOwnership {
    /// The local human's team; nil when nobody is playing (`-demo autoplay`).
    var localSide: TeamSide? { get }
    /// The aimed touch the local human owns in `s`, if any.
    func aimWindow(in s: GameState) -> AimWindow?
    /// Whether `athlete`'s touch around `s` is the local human's own (for haptics).
    func owns(_ athlete: AthleteID, in s: GameState) -> Bool
}

extension LocalOwnership {
    func isAiming(in s: GameState) -> Bool { aimWindow(in: s) != nil }
}

/// A touch the local human owns (spec §4.1: decided as the flight toward it starts), from its
/// `.window` event.
struct OwnedWindow: Equatable, Sendable {
    var id: ContactID
    var kind: TouchKind
    /// The contact's tick: the serve clock, then the toss's top once tossed; the attack's for a
    /// block.
    var contactTick: Int
    /// Who makes the touch: the contact's athlete, or the block window's blocker.
    var athlete: AthleteID?
    /// The tick the window first opened on.
    var openedTick: Int
    /// A serve whose toss is up (its window came again with the toss's top).
    var tossed = false
    /// The tick it closed on; nil while open.
    var closedTick: Int?

    var contactTime: Double { Double(contactTick) * Tuning.dt }
    var openedTime: Double { Double(openedTick) * Tuning.dt }

    /// When the finger should act for the touch to be on time: the contact itself, except a block,
    /// whose jump peaks half a jump after the tap.
    var actTime: Double {
        kind == .block ? contactTime - Double(Tuning.blockJumpTicks / 2) * Tuning.dt : contactTime
    }
}

/// The real ownership (spec §4.1, §5.3): the local human, the windows SpikeCore opened for them
/// (`GameEvent.window`) that are still open in the state, and who they control (`controlled(by:)`).
/// Fed the live client loop's events each frame with `observe`.
@MainActor
final class HumanOwnership: LocalOwnership {
    let human: HumanID?
    let localSide: TeamSide?
    /// Open windows by contact.
    private(set) var open: [ContactID: OwnedWindow] = [:]
    /// Windows closed in the last couple of seconds, newest last: the drawn match can run up to
    /// `Presentation.maxLag` behind, and haptics follow the drawn moment.
    private(set) var recent: [OwnedWindow] = []
    /// The local human's grades, by contact, for the recent windows.
    private(set) var grades: [ContactID: Grade] = [:]

    static let recentSeconds = 2.0

    init(human: HumanID?, side: TeamSide?) {
        self.human = human
        localSide = human == nil ? nil : side
    }

    /// Nobody playing (`-demo autoplay`).
    static let nobody = HumanOwnership(human: nil, side: nil)

    /// Takes a step's (or a frame's) events and the state they led to.
    func observe(_ events: [GameEvent], in s: GameState) {
        guard let human else { return }
        for e in events {
            switch e {
            case .window(let id, let kind, let owner, let tick) where owner == human:
                if var w = open[id] {
                    w.tossed = w.tossed || (kind == .serve && tick != w.contactTick)
                    w.contactTick = tick
                    open[id] = w
                } else {
                    open[id] = OwnedWindow(id: id, kind: kind, contactTick: tick, athlete: Self.athlete(for: id, s),
                                           openedTick: s.tick)
                }
            case .judged(let id, let grade) where open[id] != nil || recent.contains(where: { $0.id == id }):
                grades[id] = grade
            default:
                break
            }
        }
        let live = Self.openContacts(s)
        for (id, w) in open where !live.contains(id) {
            var closed = w
            closed.closedTick = s.tick
            recent.append(closed)
            open[id] = nil
        }
        let keep = s.tick - Int(Self.recentSeconds * Double(Tuning.stepsPerSecond))
        recent.removeAll { ($0.closedTick ?? s.tick) < keep || $0.closedTick! > s.tick }
        let known = Set(open.keys).union(recent.map(\.id))
        grades = grades.filter { known.contains($0.key) }
    }

    /// Forgets everything, as at the start of a new match.
    func reset() {
        open = [:]
        recent = []
        grades = [:]
    }

    /// The contacts still to come in `s`: the pending one, the dig held behind a block, and the
    /// human block window.
    static func openContacts(_ s: GameState) -> Set<ContactID> {
        Set([s.pending?.id, s.notes.afterBlock?.id, s.notes.block?.id].compactMap { $0 }.filter { $0 != .none })
    }

    static func athlete(for id: ContactID, _ s: GameState) -> AthleteID? {
        if let w = s.notes.block, w.id == id { return w.athlete }
        if let c = s.pending, c.id == id { return c.athlete }
        if let c = s.notes.afterBlock, c.id == id { return c.athlete }
        return nil
    }

    /// The open window the finger acts on next: the earliest to act on.
    var next: OwnedWindow? {
        open.values.min { ($0.actTime, $0.id) < ($1.actTime, $1.id) }
    }

    /// An open or recently closed window.
    func window(_ id: ContactID) -> OwnedWindow? {
        open[id] ?? recent.last { $0.id == id }
    }

    func isOpen(_ id: ContactID) -> Bool { open[id] != nil }

    /// Who the local human controls in `s` (the white arrow).
    func controlled(in s: GameState) -> AthleteID? {
        human.flatMap { SpikeCore.controlled(by: $0, s) }
    }

    // MARK: LocalOwnership

    /// The serve or attack the local human owns in `s`: the contact coming next is theirs.
    func aimWindow(in s: GameState) -> AimWindow? {
        guard let human, let p = s.pending, p.owner == human else { return nil }
        switch p.kind {
        case .serve?: return .serve
        case .attack?: return .attack
        default: return nil
        }
    }

    func owns(_ athlete: AthleteID, in s: GameState) -> Bool {
        guard human != nil else { return false }
        if open.values.contains(where: { $0.athlete == athlete }) { return true }
        return recent.contains { $0.athlete == athlete }
    }
}
