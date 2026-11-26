/// What a player looks like. Everything but `team`, `number` and `isLibero` is cosmetic variety,
/// so no two players on a team run together on the court (spec §4.4).
public struct PlayerLook: Sendable, Hashable {
    /// Index into `Palette.skin`, 0..<10 (SpikeCore's `Athlete.skinTone`).
    public var skinTone: Int
    public var number: Int
    public var team: ArtTeam
    /// The libero wears the contrasting jersey.
    public var isLibero: Bool
    public var hair: HairStyle
    /// Index into `Palette.hair`.
    public var hairColor: Int
    public var gear: Gear
    /// Index into `Palette.shoes`.
    public var shoeColor: Int
    public var build: Build

    public init(skinTone: Int, number: Int, team: ArtTeam, isLibero: Bool = false,
                hair: HairStyle = .crop, hairColor: Int = 0, gear: Gear = [],
                shoeColor: Int = 0, build: Build = .average) {
        self.skinTone = skinTone
        self.number = number
        self.team = team
        self.isLibero = isLibero
        self.hair = hair
        self.hairColor = hairColor
        self.gear = gear
        self.shoeColor = shoeColor
        self.build = build
    }

    public enum HairStyle: Int, Sendable, Hashable, CaseIterable {
        case buzz, crop, afro, ponytail, bun, locs
    }

    public struct Gear: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let kneePads = Gear(rawValue: 1 << 0)
        public static let headband = Gear(rawValue: 1 << 1)
        /// Compression sleeves down both arms.
        public static let armSleeves = Gear(rawValue: 1 << 2)
        /// Dark gear instead of light.
        public static let darkGear = Gear(rawValue: 1 << 3)
    }

    /// Body width; height comes from the athlete's `heightM`.
    public enum Build: Int, Sendable, Hashable, CaseIterable {
        case lean, average, broad
        var widthScale: Float {
            switch self {
            case .lean: 0.9
            case .average: 1
            case .broad: 1.12
            }
        }
    }
}

/// The procedural poses. `phase` runs 0...1: a cycle for `run` and `shuffle`, progress for the rest.
public enum Pose: String, Sendable, Hashable, CaseIterable {
    case stand, run, shuffle, approach, jump, spikeSwing, block, passPlatform, setHands, dive, celebrate
}
