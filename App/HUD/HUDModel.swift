import CoreGraphics
import Foundation
import Observation
import SpikeCore

/// The prompts the playtests settled (spec §4.2), and the short ones for the other touches.
enum Prompt {
    static let serve = "HOLD TO TOSS • DRAG TO AIM • LET GO TO SERVE"
    static let serveToss = "LET GO WHEN THE RING CLOSES"
    static let attack = "TOUCH THEIR COURT WHERE YOU WANT IT"
    static let attackAim = "LET GO WHEN THE RING CLOSES • NEAR THE NET = TIP"
    static let pass = "TAP WHEN THE RING CLOSES"
    static let set = "SWIPE TO A HITTER"
    static let block = "TAP TO BLOCK"
    static let read = "TAP WHO GETS THEIR SET"
}

/// The score readout.
struct ScoreLine: Equatable {
    var home = 0
    var away = 0
    var serving: TeamSide = .home
}

/// Everything the HUD draws (spec §4.4), derived each frame from the match: the score, the
/// prompt, the timing ring, the aim reticle and its line, set labels with play names, the arrow
/// over the player you control, role tags with numbers, grade flashes, banners, the switch strip
/// and the huddle. It never changes the match itself: its taps go out through `send`.
@MainActor
@Observable
final class HUDModel {
    struct RingState: Equatable {
        var center: CGPoint
        /// 1 as the window opens, 0 at the moment to act.
        var progress: Double
        /// Within the perfect window (±60 ms): the ring is green.
        var perfect: Bool
    }

    struct Reticle: Equatable {
        var at: CGPoint
        /// The hitter (or server), where the aim line starts.
        var from: CGPoint?
        /// The finger is on their court.
        var onCourt: Bool
    }

    struct SetLabel: Equatable, Identifiable {
        var id: AthleteID
        var call: PlayCall
        var text: String
        var at: CGPoint
        /// Live off this pass; grey when not.
        var live: Bool
    }

    struct Tag: Equatable, Identifiable {
        var id: AthleteID
        var text: String
        var at: CGPoint
    }

    struct StripChip: Equatable, Identifiable {
        var pick: Pick
        var text: String
        var lit: Bool
        var id: String {
            switch pick {
            case .ball: "ball"
            case .athlete(let a): "\(a.team.rawValue)-\(a.index)"
            }
        }
    }

    struct Banner: Equatable {
        var text: String
        var hot: Bool
        var serial: Int
        var until: Double
    }

    struct Flash: Equatable, Identifiable {
        var id: Int
        var text: String
        var perfect: Bool
        var at: CGPoint
        var until: Double
    }

    /// The huddle overlay (spec §4.3), basic version: your side's rotation, a chip per player to
    /// pick, a call chip per attacker to cycle, "BALL", "GO" and a countdown.
    struct HuddleModel: Equatable {
        struct Spot: Equatable, Identifiable {
            var id: AthleteID
            var zone: Zone
            var text: String
            var picked: Bool
            /// The attacker's call; nil for someone with no calls in this rotation.
            var call: PlayCall?
            var canCycle: Bool
        }

        var spots: [Spot]
        var ballPicked: Bool
        /// 1 as it opens, 0 as the serve comes.
        var fraction: Double
        var ready: Bool
        var serving: Bool
        /// A call's one-line meaning, after a long press.
        var meaning: String?
    }

    // MARK: What's drawn

    var prompt: String?
    var ring: RingState?
    var reticle: Reticle?
    /// A faint marker where the ball you receive or dig comes down.
    var landing: CGPoint?
    var setLabels: [SetLabel] = []
    var arrowAthlete: AthleteID?
    var arrowAt: CGPoint?
    var tags: [Tag] = []
    var strip: [StripChip] = []
    var huddle: HuddleModel?
    var score = ScoreLine()
    var banner: Banner?
    var flashes: [Flash] = []
    /// Where the fixed pieces sit for the view's size.
    var layout = HUDLayout(size: .zero)

    // MARK: Wiring

    let human: HumanID?
    @ObservationIgnored let ownership: HumanOwnership
    /// Sends an action the HUD's chips made (the client loop's send, at now).
    @ObservationIgnored var send: ((InputAction) -> Void)?
    @ObservationIgnored private var serial = 0
    /// Calls and picks tapped but not yet in the state, so quick taps cycle from the last one.
    @ObservationIgnored private var pendingCalls: [AthleteID: PlayCall] = [:]
    @ObservationIgnored private var pendingPick: Pick?
    @ObservationIgnored private var readyTapped = false
    @ObservationIgnored private var meaningFor: (call: PlayCall, until: Double)?
    @ObservationIgnored private(set) var live: GameState?
    @ObservationIgnored private var now: Double = 0

    init(human: HumanID?, ownership: HumanOwnership) {
        self.human = human
        self.ownership = ownership
    }

    /// One frame of the match.
    struct Frame {
        /// The client loop's newest state, and the events of the steps it just took.
        var live: GameState
        var events: [GameEvent] = []
        /// The state drawn (behind the live one during slow motion), between `drawnPrev` and
        /// `drawn` by `alpha`, and the events whose moment was just drawn.
        var drawnPrev: GameState
        var drawn: GameState
        var alpha: Double = 1
        var shownEvents: [GameEvent] = []
        /// The live match time: the clock touches are judged on.
        var time: Double
        var view: ScreenProjector?
        var aim: TouchTranslator.Aim?

        init(live: GameState, events: [GameEvent] = [], time: Double? = nil, view: ScreenProjector? = nil,
             aim: TouchTranslator.Aim? = nil) {
            self.live = live
            self.events = events
            drawnPrev = live
            drawn = live
            self.time = time ?? live.time
            self.view = view
            self.aim = aim
        }
    }

    func update(_ f: Frame) {
        live = f.live
        now = f.time
        let s = f.live
        let drawn = f.drawn
        let side = ownership.localSide

        set(\.score, ScoreLine(home: drawn.score.points(.home), away: drawn.score.points(.away), serving: drawn.score.serving))

        // Where each drawn player stands on screen, above their head.
        let a = Float(min(max(f.alpha, 0), 1))
        func head(_ id: AthleteID, lift: Float = 0.5) -> CGPoint? {
            guard let view = f.view, let m = drawn.motion[id] else { return nil }
            let before = f.drawnPrev.motion[id] ?? m
            let p = SceneMapping.lerp(before.pos, m.pos, a)
            let h = drawn.rosters[id.team.rawValue][id].heightM
            return view.point(p, height: h + lift)
        }
        func floor(_ id: AthleteID) -> CGPoint? {
            guard let view = f.view, let m = s.motion[id] else { return nil }
            return view.point(m.pos, height: 0)
        }

        var tags: [Tag] = []
        if s.phase != .matchOver {
            for side in TeamSide.allCases {
                let roster = drawn.rosters[side.rawValue]
                for (_, id) in drawn.lineups[side.rawValue].onCourt(isServing: drawn.isServing(side)).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    guard let at = head(id) else { continue }
                    let athlete = roster[id]
                    tags.append(Tag(id: id, text: "#\(athlete.number) \(athlete.position.tag)", at: at))
                }
            }
        }
        set(\.tags, tags)

        let controlled = ownership.controlled(in: s)
        set(\.arrowAthlete, controlled)
        set(\.arrowAt, controlled.flatMap { head($0, lift: 0.95) })

        // The window you act on next: its prompt and ring.
        var prompt: String?
        var ring: RingState?
        var landing: CGPoint?
        if let w = ownership.next, s.phase == .rally {
            switch w.kind {
            case .serve:
                prompt = w.tossed ? Prompt.serveToss : Prompt.serve
            case .attack:
                prompt = f.aim?.contact == w.id ? Prompt.attackAim : Prompt.attack
            case .receive, .dig:
                prompt = Prompt.pass
            case .set:
                prompt = Prompt.set
            case .block:
                prompt = Prompt.block
            }
            // While aiming, the ring sits on the aim: that's where your eyes are.
            let aimed = f.aim.flatMap { $0.contact == w.id ? ($0.floor.flatMap { f.view?.point($0, height: 0) } ?? $0.point) : nil }
            if w.kind != .serve || w.tossed, let center = aimed ?? ringCenter(w, s, f.view) {
                ring = Self.ring(for: w, at: center, time: f.time)
            }
            if w.kind == .receive || w.kind == .dig, let b = s.ball, let view = f.view {
                landing = view.point(b.position(at: b.endTime).xz, height: 0)
            }
        } else if let side, s.phase == .rally, let c = s.pending, c.team == side.other,
                  c.kind == .receive || c.kind == .dig || c.kind == .set {
            prompt = Prompt.read
        }
        set(\.prompt, prompt)
        set(\.ring, ring)
        set(\.landing, landing)

        // The reticle and the line from the hitter.
        var reticle: Reticle?
        if let aim = f.aim, let w = ownership.window(aim.contact) {
            let at = aim.floor.flatMap { f.view?.point($0, height: 0) } ?? aim.point
            reticle = Reticle(at: at, from: w.athlete.flatMap { head($0, lift: -0.2) }, onCourt: aim.floor != nil)
        }
        set(\.reticle, reticle)

        // Set labels over your hitters while your side's set is coming.
        var labels: [SetLabel] = []
        if let side, s.phase == .rally, let c = s.pending, c.kind == .set, c.team == side {
            for l in Self.setLabels(s, team: side) {
                guard let at = head(l.id, lift: 0.9) else { continue }
                labels.append(SetLabel(id: l.id, call: l.call, text: l.call.display, at: at, live: l.live))
            }
        }
        set(\.setLabels, labels)

        if let p = pendingSwitch, s.human(human!)?.current == p.pick || f.time > p.until || f.time < p.until - 1 {
            pendingSwitch = nil
        }
        set(\.strip, human.map { Self.strip(s, human: $0, controlled: controlled, pending: pendingSwitch?.pick) } ?? [])

        // Grades, as they're judged.
        var flashes = self.flashes.filter { $0.until > f.time }
        for e in f.events {
            guard case .judged(let id, let grade) = e, let w = ownership.window(id) else { continue }
            serial += 1
            let at = ringCenter(w, s, f.view) ?? w.athlete.flatMap(floor) ?? CGPoint(x: 0, y: 0)
            flashes.append(Flash(id: serial, text: Self.name(grade), perfect: grade == .perfect, at: at, until: f.time + 0.8))
        }
        set(\.flashes, flashes)

        // Banners, as the drawn match reaches them.
        var banner = self.banner.flatMap { $0.until > f.time ? $0 : nil }
        for e in f.shownEvents {
            if let (text, hot) = Self.banner(for: e) {
                serial += 1
                banner = Banner(text: text, hot: hot, serial: serial, until: f.time + 1.4)
            }
        }
        set(\.banner, banner)

        updateHuddle(s)
    }

    /// Assigns only on change, so SwiftUI redraws only what moved.
    private func set<T: Equatable>(_ path: ReferenceWritableKeyPath<HUDModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    // MARK: Pieces

    /// The ring for window `w` at match time `time`: it closes over the last `ringLead` seconds
    /// to the moment to act, and is green within the perfect window either side of it.
    static func ring(for w: OwnedWindow, at center: CGPoint, time: Double) -> RingState {
        let lead = max(min(w.actTime - w.openedTime, ringLead), 0.25)
        let progress = min(max((w.actTime - time) / lead, 0), 1)
        let off = abs(time - w.actTime)
        // Whole microseconds decide, as the judge rounds.
        let perfect = (off * 1_000_000).rounded() <= Tuning.perfectWindow * 1_000_000
        return RingState(center: center, progress: progress, perfect: perfect)
    }

    static let ringLead = 1.1

    /// Where the ring sits: where the ball meets the player.
    private func ringCenter(_ w: OwnedWindow, _ s: GameState, _ view: ScreenProjector?) -> CGPoint? {
        guard let view else { return nil }
        if w.kind == .serve {
            guard let server = w.athlete, let m = s.motion[server] else { return nil }
            return view.point(m.pos, height: 3)
        }
        if let b = s.ball, w.contactTime <= b.endTime + 1e-6 || w.kind == .block {
            return view.point(b.position(at: min(w.contactTime, b.endTime)))
        }
        guard let id = w.athlete, let m = s.motion[id] else { return nil }
        return view.point(m.pos, height: 1.2)
    }

    /// The labels over `team`'s hitters for its set: each attacker's call, or what it falls back
    /// to off this pass, grey when the call isn't live.
    static func setLabels(_ s: GameState, team: TeamSide) -> [(id: AthleteID, call: PlayCall, live: Bool)] {
        let lineup = s.lineups[team.rawValue], roster = s.rosters[team.rawValue]
        let serving = s.isServing(team)
        let live = liveCalls(s, team: team, passQuality: s.notes.passQuality)
        var out: [(AthleteID, PlayCall, Bool)] = []
        let setter = lineup.settingSetter(isServing: serving)
        for z in [Zone.z4, .z3, .z2, .z5, .z6, .z1] {
            let id = lineup.occupant(z, isServing: serving)
            guard id != setter, id != lineup.libero,
                  let called = s.calls[team.rawValue].call(for: id, lineup: lineup, roster: roster, game: s.settings.gameType,
                                                           isServing: serving) else { continue }
            if let l = live.first(where: { $0.0 == id }) {
                out.append((id, l.1, true))
            } else {
                out.append((id, called, false))
            }
        }
        if let dump = live.first(where: { $0.0 == setter }) { out.append((setter, dump.1, true)) }
        return out
    }

    /// The switch strip (spec §4.1): your six on court, libero swapped in, front row left to
    /// right then the back row, and "BALL". The one you control is lit, and BALL while you
    /// follow the ball.
    static func strip(_ s: GameState, human: HumanID, controlled: AthleteID?, pending: Pick? = nil) -> [StripChip] {
        guard let slot = s.human(human), s.phase != .matchOver else { return [] }
        if case .huddle = s.phase { return [] }
        let side = slot.team
        let lineup = s.lineups[side.rawValue], roster = s.rosters[side.rawValue]
        let court = lineup.onCourt(isServing: s.isServing(side))
        let current = pending ?? slot.current
        var chips: [StripChip] = []
        for z in [Zone.z4, .z3, .z2, .z5, .z6, .z1] {
            guard let id = court[z] else { continue }
            let a = roster[id]
            let lit = pending.map { $0 == .athlete(id) } ?? (controlled == id || (controlled == nil && current == .athlete(id)))
            chips.append(StripChip(pick: .athlete(id), text: "#\(a.number) \(a.position.tag)", lit: lit))
        }
        chips.append(StripChip(pick: .ball, text: "BALL", lit: current == .ball))
        return chips
    }

    static func name(_ g: Grade) -> String {
        switch g {
        case .perfect: "PERFECT"
        case .good: "GOOD"
        case .early: "EARLY"
        case .late: "LATE"
        case .wayEarly: "WAY EARLY"
        case .wayLate: "WAY LATE"
        case .miss: "MISS"
        }
    }

    /// KILL, ROOF, ACE and ON FIRE.
    static func banner(for e: GameEvent) -> (String, Bool)? {
        switch e {
        case .point(_, .kill): ("KILL", false)
        case .point(_, .block): ("ROOF", false)
        case .point(_, .ace): ("ACE", false)
        case .fire(_, on: true): ("ON FIRE", true)
        default: nil
        }
    }

    // MARK: Taps from the strip and the huddle

    /// A strip tap the state doesn't show yet.
    @ObservationIgnored private var pendingSwitch: (pick: Pick, until: Double)?

    /// A strip chip: play that player (or the ball) from the next touch.
    func tapStrip(_ p: Pick) {
        pendingSwitch = (p, now + 0.5)
        send?(.switchTo(p))
        if let s = live, let human { set(\.strip, Self.strip(s, human: human, controlled: ownership.controlled(in: s), pending: p)) }
    }

    /// A huddle chip: pick that player, or the ball.
    func tapPick(_ p: Pick) {
        pendingPick = p
        send?(.pick(p))
        if let s = live { updateHuddle(s) }
    }

    /// A call chip: the hitter's next call, round their list.
    func tapCall(_ id: AthleteID) {
        guard let s = live, let h = huddle?.spots.first(where: { $0.id == id }), let call = h.call, h.canCycle else { return }
        let options = Self.callOptions(id, s)
        guard let i = options.firstIndex(of: call) else { return }
        let next = options[(i + 1) % options.count]
        pendingCalls[id] = next
        send?(.call(id, next))
        meaningFor = nil
        updateHuddle(s)
    }

    /// A long press on a call chip: its one-line meaning.
    func showMeaning(_ id: AthleteID) {
        guard let s = live, let call = huddle?.spots.first(where: { $0.id == id })?.call else { return }
        meaningFor = (call, now + 3)
        updateHuddle(s)
    }

    /// "GO": done in the huddle.
    func tapReady() {
        readyTapped = true
        send?(.ready)
        if let s = live { updateHuddle(s) }
    }

    /// The calls `id` can cycle through from where they stand.
    static func callOptions(_ id: AthleteID, _ s: GameState) -> [PlayCall] {
        let lineup = s.lineups[id.team.rawValue]
        guard let zone = lineup.zone(of: id, isServing: s.isServing(id.team)) else { return [] }
        return PlayBook.calls(for: s.rosters[id.team.rawValue][id].position, frontRow: zone.isFrontRow, system: lineup.system)
    }

    private func updateHuddle(_ s: GameState) {
        guard let human, let slot = s.human(human), case .huddle(let until) = s.phase else {
            pendingCalls = [:]
            pendingPick = nil
            pendingSwitch = nil
            readyTapped = false
            meaningFor = nil
            set(\.huddle, nil)
            return
        }
        pendingSwitch = nil
        let side = slot.team
        let lineup = s.lineups[side.rawValue], roster = s.rosters[side.rawValue]
        let serving = s.isServing(side)
        // Taps the state already shows are no longer pending.
        for (id, call) in pendingCalls where s.calls[side.rawValue].byAthlete[id] == call { pendingCalls[id] = nil }
        if pendingPick == slot.pick { pendingPick = nil }
        let pick = pendingPick ?? slot.pick
        var spots: [HuddleModel.Spot] = []
        for z in Zone.allCases {
            let id = lineup.occupant(z, isServing: serving)
            let a = roster[id]
            let options = Self.callOptions(id, s)
            var call: PlayCall?
            if !options.isEmpty {
                call = pendingCalls[id]
                    ?? s.calls[side.rawValue].call(for: id, lineup: lineup, roster: roster, game: s.settings.gameType, isServing: serving)
            }
            spots.append(HuddleModel.Spot(id: id, zone: z, text: "#\(a.number) \(a.position.tag)",
                                          picked: pick == .athlete(id), call: call, canCycle: options.count > 1))
        }
        let total = Tuning.huddleSeconds * Double(Tuning.stepsPerSecond)
        let fraction = min(max(Double(until - s.tick) / total, 0), 1)
        if let m = meaningFor, m.until < now { meaningFor = nil }
        set(\.huddle, HuddleModel(spots: spots, ballPicked: pick == .ball, fraction: fraction,
                                  ready: readyTapped || slot.ready, serving: serving, meaning: meaningFor?.call.meaning))
    }
}
