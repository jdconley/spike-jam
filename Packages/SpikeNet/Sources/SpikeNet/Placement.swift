import SpikeCore

/// An input as it travels: for a touch, with the tick of the contact as the toucher's phone saw
/// it when they made it.
public struct NetInput: Codable, Equatable, Sendable {
    public var input: PlayerInput
    /// The contact's tick on the toucher's phone (`Placement.contactTick`); nil for the actions
    /// that aren't touches.
    public var seen: Int?

    public init(_ input: PlayerInput, seen: Int? = nil) {
        self.input = input
        self.seen = seen
    }
}

/// When the host plays an input (spec §5.3: timing is judged in the toucher's favour). A touch is
/// judged against the contact as its toucher saw it: if the host's contact comes later or sooner
/// than the toucher's phone predicted (another human's touch before it went differently), the
/// input moves with it, up to `ServerLoop.rewindCap`. One that comes before its contact is open
/// on the host (a block jump for a set the host hasn't seen leave yet) waits for it, as long as
/// the cap.
///
/// The host and every guest's prediction place inputs the same way, so they agree.
public enum Placement {
    /// The tick contact `id` is judged against, while it's open: the touch's own tick, or for a
    /// block the attack's.
    public static func contactTick(_ id: ContactID, _ s: GameState) -> Int? {
        if let c = s.pending, c.id == id { return c.tick }
        if let c = s.notes.afterBlock, c.id == id { return c.tick }
        if let w = s.notes.block, w.id == id { return w.attackTick }
        return nil
    }

    /// `i` as the host plays it in `s`: moved with its contact, or nil while the contact isn't
    /// open yet.
    public static func placed(_ i: NetInput, _ s: GameState) -> PlayerInput? {
        guard let id = i.input.contact, let seen = i.seen else { return i.input }
        guard let now = contactTick(id, s) else { return nil }
        var p = i.input
        p.tick += min(max(now - seen, -ServerLoop.capTicks), ServerLoop.capTicks)
        return p
    }

    /// Takes the inputs due in the step from `s`, in arrival order, out of `waiting`. A touch
    /// whose contact never opens goes after the cap as it is (SpikeCore drops it).
    public static func takeDue(_ waiting: inout [NetInput], _ s: GameState) -> [PlayerInput] {
        guard !waiting.isEmpty else { return [] }
        var due: [PlayerInput] = []
        var keep: [NetInput] = []
        for w in waiting {
            if let p = placed(w, s) {
                if p.tick <= s.tick { due.append(p) } else { keep.append(w) }
            } else if s.tick > w.input.tick + ServerLoop.capTicks {
                due.append(w.input)
            } else {
                keep.append(w)
            }
        }
        waiting = keep
        return due
    }
}
