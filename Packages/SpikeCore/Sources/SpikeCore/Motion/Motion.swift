/// How a player is moving; each has its own speed cap (`Tuning.gaitSpeed`).
public enum Gait: String, Codable, Sendable, CaseIterable {
    case stand, run, shuffle, backpedal, approach, dive
}

/// A jump: a parabola in height over `durationTicks`, 0 outside it.
public struct Jump: Codable, Equatable, Sendable {
    public var startTick: Int
    public var durationTicks: Int
    /// Peak height of the feet above the floor, in metres.
    public var height: Float

    public init(startTick: Int, durationTicks: Int, height: Float) {
        self.startTick = startTick
        self.durationTicks = durationTicks
        self.height = height
    }

    public var endTick: Int { startTick + durationTicks }
    /// The tick of the highest point (rounded down for odd durations).
    public var peakTick: Int { startTick + durationTicks / 2 }

    public func isAirborne(atTick t: Int) -> Bool { t > startTick && t < endTick }

    public func height(atTick t: Int) -> Float {
        guard durationTicks > 0, t > startTick, t < endTick else { return 0 }
        let u = Float(t - startTick) / Float(durationTicks)
        return 4 * height * u * (1 - u)
    }
}

/// One on-court player's movement state (spec §5.2): where they are, how
/// fast they're going, and where the choreographer wants them.
public struct Motion: Codable, Equatable, Sendable {
    public var pos: Vec2
    public var vel: Vec2
    public var goal: Vec2
    public var gait: Gait
    /// When set, the player paces itself to arrive on this tick rather than
    /// early (approaches). It never slows a player who would be late.
    public var arriveByTick: Int?
    public var jump: Jump?

    public init(pos: Vec2, vel: Vec2 = .zero, goal: Vec2? = nil, gait: Gait = .stand,
                arriveByTick: Int? = nil, jump: Jump? = nil) {
        self.pos = pos
        self.vel = vel
        self.goal = goal ?? pos
        self.gait = gait
        self.arriveByTick = arriveByTick
        self.jump = jump
    }

    /// The jump's height at `tick`, 0 when not jumping.
    public func height(atTick tick: Int) -> Float { jump?.height(atTick: tick) ?? 0 }
}
