@testable import SpikeCore

/// Inputs that play every touch `h` owns exactly on time: the serve tossed
/// at once and released at the top, passes, sets (the AI's choice of hitter)
/// and attacks on the contact tick, and the block jump peaking on the attack.
func perfectInputs(_ h: HumanID, _ s: GameState) -> [PlayerInput] {
    var out: [PlayerInput] = []
    func input(_ a: InputAction) { out.append(PlayerInput(human: h, tick: s.tick, action: a)) }
    if let w = s.notes.block, w.owner == h, w.grade == nil, s.tick >= w.attackTick - Tuning.blockJumpTicks / 2 {
        input(.block(contact: w.id))
    }
    guard let c = s.pending, c.owner == h, let kind = c.kind else { return out }
    let mine = s.inputs(for: c)
    guard HumanTouch.striking(c, inputs: mine) == nil else { return out }
    let deep = LocalFrame.toWorld(LocalSpot(d: 6.5, l: 1.5), team: c.team.other)
    switch kind {
    case .serve:
        if HumanTouch.press(mine) == nil {
            input(.press(contact: c.id))
        } else if s.tick >= c.tick {
            input(.release(contact: c.id, aim: deep))
        }
    case .receive, .dig, .set:
        if s.tick >= c.tick { input(.tap(contact: c.id)) }
    case .attack:
        if s.tick >= c.tick { input(.release(contact: c.id, aim: deep)) }
    case .block:
        break
    }
    return out
}
