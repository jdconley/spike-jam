/// The steering integrator: moves a player toward its goal under a speed cap
/// and an acceleration limit, stopping at the goal, and never off its own
/// side or out of the free zone.
public enum Steering {
    /// The speed cap: gait cap × `footworkScale` × (0.85 + 0.3 × speed trait).
    public static func cap(_ gait: Gait, speedTrait: Float) -> Float {
        Tuning.gaitSpeed(gait) * Tuning.footworkScale * (0.85 + 0.3 * speedTrait)
    }

    /// Clamps a world point to `team`'s side and the free zone.
    public static func clamp(_ v: Vec2, team: TeamSide) -> Vec2 {
        var s = LocalFrame.toLocal(v, team: team)
        s.d = min(max(s.d, Tuning.minDepth), Tuning.maxDepth)
        s.l = min(max(s.l, -Tuning.maxLateral), Tuning.maxLateral)
        return LocalFrame.toWorld(s, team: team)
    }

    /// One step of `dt` seconds. `tick` is the step being taken; it's only
    /// needed to honour `arriveByTick`, which is ignored without it.
    /// `capScale` multiplies the speed cap (an on-fire libero's).
    public static func advance(_ m: inout Motion, team: TeamSide, speedTrait: Float, dt: Double, tick: Int? = nil,
                               capScale: Float = 1) {
        m.goal = clamp(m.goal, team: team)
        integrate(&m, cap: cap(m.gait, speedTrait: speedTrait) * capScale, dt: Float(dt), tick: tick)
        let clamped = clamp(m.pos, team: team)
        if clamped.x != m.pos.x { m.vel.x = 0 }
        if clamped.z != m.pos.z { m.vel.z = 0 }
        m.pos = clamped
    }

    /// The step itself, without the court clamps.
    static func integrate(_ m: inout Motion, cap: Float, dt h: Float, tick: Int?) {
        let a = Tuning.accel
        let toGoal = m.goal - m.pos
        let dist = toGoal.length
        var desired = Vec2.zero
        if dist > 1e-5 {
            // As fast as allowed, but slow enough to stop at the goal and
            // not overshoot it this step.
            var speed = min(cap, (2 * a * dist).squareRoot(), dist / h)
            if let by = m.arriveByTick, let now = tick,
               let pace = paceSpeed(distance: dist, time: Float(by - now + 1) * h, accel: a) {
                speed = min(speed, pace)
            }
            desired = toGoal * (speed / dist)
        }

        let dv = desired - m.vel
        let maxDv = a * h
        let dvl = dv.length
        m.vel = m.vel + (dvl > maxDv ? dv * (maxDv / dvl) : dv)
        let speed = m.vel.length
        if speed > cap { m.vel = m.vel * (cap / speed) }
        m.pos = m.pos + m.vel * h

        // Settle exactly on the goal once there and nearly still.
        if (m.goal - m.pos).length < 0.005 && m.vel.length < maxDv {
            m.pos = m.goal
            m.vel = .zero
        }
    }

    /// Seconds until steering brings `m` within `arriveRadius` of `to` at
    /// speed cap `cap`, as fast as it can (no `arriveByTick` pacing). It runs
    /// the integrator itself, so it agrees with `advance` exactly; past
    /// `limit` seconds it gives up and returns `limit`.
    public static func eta(_ m: Motion, to: Vec2, cap: Float, limit: Double = 4) -> Double {
        var m = m
        m.goal = to
        m.arriveByTick = nil
        let h = Float(Tuning.dt)
        let steps = Int(limit * Double(Tuning.stepsPerSecond))
        var n = 0
        while (m.pos - to).length > Tuning.arriveRadius {
            if n >= steps { return limit }
            integrate(&m, cap: cap, dt: h, tick: nil)
            n += 1
        }
        return Double(n) * Tuning.dt
    }

    /// The cruise speed of a speed-up, cruise, slow-down profile from rest
    /// that covers `distance` in exactly `time`; nil when even the fastest
    /// such profile can't arrive early.
    static func paceSpeed(distance: Float, time: Float, accel: Float) -> Float? {
        guard time > 0 else { return nil }
        // distance = v·time − v²/accel; the smaller root.
        let disc = time * time - 4 * distance / accel
        guard disc >= 0 else { return nil }
        return (time - disc.squareRoot()) * accel / 2
    }
}
