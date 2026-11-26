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
    public static func advance(_ m: inout Motion, team: TeamSide, speedTrait: Float, dt: Double, tick: Int? = nil) {
        let h = Float(dt)
        let a = Tuning.accel
        let cap = cap(m.gait, speedTrait: speedTrait)
        m.goal = clamp(m.goal, team: team)

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

        let next = m.pos + m.vel * h
        let clamped = clamp(next, team: team)
        if clamped.x != next.x { m.vel.x = 0 }
        if clamped.z != next.z { m.vel.z = 0 }
        m.pos = clamped

        // Settle exactly on the goal once there and nearly still.
        if (m.goal - m.pos).length < 0.005 && m.vel.length < maxDv {
            m.pos = m.goal
            m.vel = .zero
        }
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
