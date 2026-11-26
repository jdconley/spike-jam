/// Ground-plane vector: x along the court length, z across it.
public struct Vec2: Codable, Hashable, Sendable {
    public var x: Float
    public var z: Float

    public init(x: Float, z: Float) {
        self.x = x
        self.z = z
    }

    public static let zero = Vec2(x: 0, z: 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, z: a.z + b.z) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, z: a.z - b.z) }
    public static func * (a: Vec2, s: Float) -> Vec2 { Vec2(x: a.x * s, z: a.z * s) }
    public static func * (s: Float, a: Vec2) -> Vec2 { a * s }

    public var length: Float { (x * x + z * z).squareRoot() }

    public var normalized: Vec2 {
        let l = length
        return l > 0 ? Vec2(x: x / l, z: z / l) : .zero
    }

    /// Lifts this ground point to a 3D point at height `y`.
    public func atHeight(_ y: Float) -> Vec3 { Vec3(x: x, y: y, z: z) }
}

/// World vector: x along the court (net at 0), y up, z across.
public struct Vec3: Codable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(x: 0, y: 0, z: 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    public static func * (a: Vec3, s: Float) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }
    public static func * (s: Float, a: Vec3) -> Vec3 { a * s }

    public var length: Float { (x * x + y * y + z * z).squareRoot() }

    public var normalized: Vec3 {
        let l = length
        return l > 0 ? Vec3(x: x / l, y: y / l, z: z / l) : .zero
    }

    /// The ground-plane part of this vector.
    public var xz: Vec2 { Vec2(x: x, z: z) }
}

/// Home stands at negative x and attacks toward +x; away mirrors x and z.
public enum TeamSide: Int, Codable, Sendable, CaseIterable {
    case home, away

    public var other: TeamSide { self == .home ? .away : .home }

    /// +1 for home, −1 for away: the direction this team attacks along x.
    public var dir: Float { self == .home ? 1 : -1 }
}
