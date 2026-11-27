import SpikeCore

/// A type the binary coder writes and reads directly instead of through Codable: the small
/// values a snapshot is mostly made of (positions, players' movement, the ball). Codable's
/// containers cost far more than the bytes for these, and a guest decodes 30 snapshots a second.
/// The bytes are what their Codable encoding through `BinaryEncoder` would be.
protocol WireValue {
    func write(_ s: Sink)
    static func read(_ r: Reader) throws -> Self
}

extension Vec2: WireValue {
    func write(_ s: Sink) {
        s.float(x)
        s.float(z)
    }

    static func read(_ r: Reader) throws -> Vec2 {
        Vec2(x: try r.float(), z: try r.float())
    }
}

extension Vec3: WireValue {
    func write(_ s: Sink) {
        s.float(x)
        s.float(y)
        s.float(z)
    }

    static func read(_ r: Reader) throws -> Vec3 {
        Vec3(x: try r.float(), y: try r.float(), z: try r.float())
    }
}

extension AthleteID: WireValue {
    func write(_ s: Sink) {
        s.int(team.rawValue)
        s.int(index)
    }

    static func read(_ r: Reader) throws -> AthleteID {
        guard let team = TeamSide(rawValue: try r.int()) else { throw r.fail("bad team") }
        return AthleteID(team: team, index: try r.int())
    }
}

extension HumanID: WireValue {
    func write(_ s: Sink) { s.bytes.append(raw) }
    static func read(_ r: Reader) throws -> HumanID { HumanID(raw: try r.byte()) }
}

extension ContactID: WireValue {
    func write(_ s: Sink) { s.fixed(raw) }
    static func read(_ r: Reader) throws -> ContactID { ContactID(raw: try r.fixed(UInt32.self)) }
}

extension Flight: WireValue {
    func write(_ s: Sink) {
        p0.write(s)
        v0.write(s)
        s.double(startTime)
        s.double(duration)
    }

    static func read(_ r: Reader) throws -> Flight {
        Flight(p0: try .read(r), v0: try .read(r), startTime: try r.double(), duration: try r.double())
    }
}

extension Motion: WireValue {
    func write(_ s: Sink) {
        pos.write(s)
        vel.write(s)
        goal.write(s)
        s.string(gait.rawValue)
        if let arriveByTick {
            s.bytes.append(1)
            s.int(arriveByTick)
        } else {
            s.bytes.append(0)
        }
        if let jump {
            s.bytes.append(1)
            s.int(jump.startTick)
            s.int(jump.durationTicks)
            s.float(jump.height)
        } else {
            s.bytes.append(0)
        }
    }

    static func read(_ r: Reader) throws -> Motion {
        let pos = try Vec2.read(r), vel = try Vec2.read(r), goal = try Vec2.read(r)
        guard let gait = Gait(rawValue: try r.string()) else { throw r.fail("bad gait") }
        let arrive = try r.bool() ? try r.int() : nil
        let jump = try r.bool() ? Jump(startTick: try r.int(), durationTicks: try r.int(), height: try r.float()) : nil
        return Motion(pos: pos, vel: vel, goal: goal, gait: gait, arriveByTick: arrive, jump: jump)
    }
}

extension DynamicState.MovingAthlete: WireValue {
    func write(_ s: Sink) {
        id.write(s)
        motion.write(s)
    }

    static func read(_ r: Reader) throws -> DynamicState.MovingAthlete {
        DynamicState.MovingAthlete(id: try .read(r), motion: try .read(r))
    }
}
