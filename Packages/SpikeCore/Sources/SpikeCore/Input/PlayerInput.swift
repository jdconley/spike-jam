/// One person playing (spec §4.1). Up to a few per match; the raw value is
/// theirs for the whole match.
public struct HumanID: Codable, Hashable, Sendable {
    public let raw: UInt8

    public init(raw: UInt8) {
        self.raw = raw
    }
}

/// Every contact of the ball the rally schedules (spec §5.3), numbered from 1
/// in the order they're scheduled. A touch input names the contact it's for,
/// so an input that arrives late can never count for the next one.
public struct ContactID: Codable, Hashable, Comparable, Sendable {
    public let raw: UInt32

    public init(raw: UInt32) {
        self.raw = raw
    }

    /// Not yet numbered: a contact gets its number as its flight starts.
    public static let none = ContactID(raw: 0)

    public static func < (a: ContactID, b: ContactID) -> Bool { a.raw < b.raw }
}

/// Who a human plays (spec §4.1): one athlete, or "ball", whoever on their
/// side touches the ball next.
public enum Pick: Codable, Hashable, Sendable {
    case ball
    case athlete(AthleteID)
}

/// What a human did. Touch actions name the contact they're for (from the
/// `window` event); the rest act on the huddle, the switch strip or the
/// defensive read.
public enum InputAction: Codable, Equatable, Sendable {
    /// A finger down: the serve toss starts, or an attack starts aiming.
    case press(contact: ContactID)
    /// The finger up: the serve or attack is struck, at `aim` (a world point on
    /// the floor of the other court) if given.
    case release(contact: ContactID, aim: Vec2?)
    /// A pass or dig; also a quick serve (a float) or a set left to the AI's
    /// choice of hitter.
    case tap(contact: ContactID)
    /// A set to `hitter`, which a swipe toward them resolves to on the device.
    case setTo(contact: ContactID, hitter: AthleteID)
    /// The block jump, which starts at once.
    case block(contact: ContactID)
    /// The defensive read: the hitter this human expects the other side to set.
    case read(hitter: AthleteID)
    /// The huddle pick.
    case pick(Pick)
    /// A huddle play call for one of the human's team's hitters.
    case call(AthleteID, PlayCall)
    /// A huddle combination call.
    case combo(Combo)
    /// The switch strip: play this athlete (or the ball) until the next huddle.
    case switchTo(Pick)
    /// Done in the huddle (online rooms show it; the huddle still runs its
    /// full length).
    case ready
    /// The team's system and starting rotation, accepted only in the huddle
    /// before the first serve.
    case teamSettings(TeamSettings)
}

/// One input, stamped with the step it happened in and how far into that
/// step (spec §5.2). Its time is `tick × dt + offset`.
public struct PlayerInput: Codable, Equatable, Sendable {
    public var human: HumanID
    public var tick: Int
    /// Seconds into the tick, 0..<dt.
    public var offset: Float
    public var action: InputAction

    public init(human: HumanID, tick: Int, offset: Float = 0, action: InputAction) {
        self.human = human
        self.tick = tick
        self.offset = offset
        self.action = action
    }

    /// Match time in seconds.
    public var time: Double { Double(tick) * Tuning.dt + Double(offset) }

    /// The contact a touch action is for; nil for the others.
    public var contact: ContactID? {
        switch action {
        case .press(let c), .release(let c, _), .tap(let c), .setTo(let c, _), .block(let c): c
        default: nil
        }
    }
}
