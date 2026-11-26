import Foundation
import RealityKit
import simd

/// A small faceted mesh built on the CPU: flat normals for the cel look, plus the smoothed
/// normals the ink outline extrudes along (so hull faces stay joined at hard edges).
public struct LowPolyMesh: Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    /// Triangles, counter-clockwise seen from outside.
    public var indices: [UInt32] = []

    public init() {}

    public var triangleCount: Int { indices.count / 3 }

    /// A UV rectangle in 0...1, origin top-left (as drawn by Core Graphics).
    public struct UVRect: Sendable, Equatable {
        public var x0, y0, x1, y1: Float
        public init(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
            self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
        }
        public static let solid = UVRect(0, 0, 0.01, 0.01)
        func at(_ u: Float, _ v: Float) -> SIMD2<Float> {
            // RealityKit's v runs bottom-up; flip so rects read like the CG drawing.
            [x0 + (x1 - x0) * u, 1 - (y0 + (y1 - y0) * v)]
        }
    }

    public enum BoxFace: CaseIterable, Sendable { case front, back, left, right, top, bottom }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       uv: UVRect = .solid) {
        // a b c d counter-clockwise from outside; a is bottom-left of the texture rect.
        let n = simd_normalize(simd_cross(b - a, d - a))
        let base = UInt32(positions.count)
        positions += [a, b, c, d]
        normals += [n, n, n, n]
        uvs += [uv.at(0, 1), uv.at(1, 1), uv.at(1, 0), uv.at(0, 0)]
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, uv: UVRect = .solid) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let base = UInt32(positions.count)
        positions += [a, b, c]
        normals += [n, n, n]
        uvs += [uv.at(0, 1), uv.at(1, 1), uv.at(0.5, 0)]
        indices += [base, base + 1, base + 2]
    }

    /// A box centered on `center`. Front is +z, the character's left is +x.
    public static func box(_ size: SIMD3<Float>, center: SIMD3<Float> = .zero,
                           uv: (BoxFace) -> UVRect = { _ in .solid }) -> LowPolyMesh {
        var m = LowPolyMesh()
        let h = size / 2
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { center + SIMD3(x * h.x, y * h.y, z * h.z) }
        // front (+z), seen from the front: left of the image is −x (the character's right).
        m.quad(p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1), uv: uv(.front))
        // back (−z), seen from behind: left of the image is +x.
        m.quad(p(1, -1, -1), p(-1, -1, -1), p(-1, 1, -1), p(1, 1, -1), uv: uv(.back))
        m.quad(p(1, -1, 1), p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), uv: uv(.left))
        m.quad(p(-1, -1, -1), p(-1, -1, 1), p(-1, 1, 1), p(-1, 1, -1), uv: uv(.right))
        m.quad(p(-1, 1, 1), p(1, 1, 1), p(1, 1, -1), p(-1, 1, -1), uv: uv(.top))
        m.quad(p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1), uv: uv(.bottom))
        return m
    }

    /// A capped, tapered prism along −y from `top` (y = 0) to y = −length: a limb segment.
    public static func limb(length: Float, topRadius: Float, bottomRadius: Float, sides: Int = 6,
                            uv: UVRect = .solid) -> LowPolyMesh {
        frustum(y0: -length, y1: 0, r0: bottomRadius, r1: topRadius, sides: sides, uv: uv)
    }

    /// A capped frustum between heights `y0` (radius `r0`) and `y1` (radius `r1`), centered on the y axis.
    public static func frustum(y0: Float, y1: Float, r0: Float, r1: Float, sides: Int = 8,
                               depthScale: Float = 1, uv: UVRect = .solid) -> LowPolyMesh {
        var m = LowPolyMesh()
        func ring(_ r: Float, _ y: Float, _ i: Int) -> SIMD3<Float> {
            let a = Float(i) / Float(sides) * 2 * .pi + .pi / Float(sides)
            return [sinf(a) * r, y, cosf(a) * r * depthScale]
        }
        for i in 0..<sides {
            let a0 = ring(r0, y0, i), b0 = ring(r0, y0, i + 1)
            let a1 = ring(r1, y1, i), b1 = ring(r1, y1, i + 1)
            m.quad(a0, b0, b1, a1, uv: uv)
            m.triangle(SIMD3(0, y1, 0), a1, b1, uv: uv)
            m.triangle(SIMD3(0, y0, 0), b0, a0, uv: uv)
        }
        return m
    }

    /// A faceted ellipsoid. `yMin`/`yMax` in −1...1 cut it (a cap is `yMin: 0`).
    public static func sphere(radii: SIMD3<Float>, center: SIMD3<Float> = .zero,
                              segments: Int = 10, rings: Int = 7, yMin: Float = -1, yMax: Float = 1,
                              uv: UVRect = .solid) -> LowPolyMesh {
        var m = LowPolyMesh()
        let t0 = acosf(min(max(yMax, -1), 1)), t1 = acosf(min(max(yMin, -1), 1))
        func pt(_ ri: Int, _ si: Int) -> SIMD3<Float> {
            let theta = t0 + (t1 - t0) * Float(ri) / Float(rings)
            let phi = Float(si) / Float(segments) * 2 * .pi
            let s = sinf(theta)
            return center + SIMD3(s * sinf(phi), cosf(theta), s * cosf(phi)) * radii
        }
        for r in 0..<rings {
            for s in 0..<segments {
                let a = pt(r + 1, s), b = pt(r + 1, s + 1), c = pt(r, s + 1), d = pt(r, s)
                if r == 0 && t0 < 1e-4 {
                    m.triangle(a, b, d, uv: uv)
                } else if r == rings - 1 && t1 > .pi - 1e-4 {
                    m.triangle(a, c, d, uv: uv)
                } else {
                    m.quad(a, b, c, d, uv: uv)
                }
            }
        }
        if yMin > -1 { // close the cut with a flat disc
            let y = center.y + yMin * radii.y
            for s in 0..<segments {
                m.triangle(SIMD3(center.x, y, center.z), pt(rings, s + 1), pt(rings, s), uv: uv)
            }
        }
        return m
    }

    /// Appends `other`.
    public mutating func append(_ other: LowPolyMesh) {
        let base = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        uvs += other.uvs
        indices += other.indices.map { $0 + base }
    }

    /// The mesh moved by `t` (rotation and scale applied to normals correctly).
    public func transformed(_ t: simd_float4x4) -> LowPolyMesh {
        var m = self
        let nm = simd_float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                               SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                               SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)).inverse.transpose
        m.positions = positions.map { p in
            let v = t * SIMD4(p, 1)
            return SIMD3(v.x, v.y, v.z)
        }
        m.normals = normals.map { simd_normalize(nm * $0) }
        return m
    }

    public func translated(_ d: SIMD3<Float>) -> LowPolyMesh {
        var m = self
        m.positions = positions.map { $0 + d }
        return m
    }

    /// Per-vertex normals averaged over every face sharing the position.
    func smoothedNormals() -> [SIMD3<Float>] {
        struct Key: Hashable { var x, y, z: Int32 }
        func key(_ p: SIMD3<Float>) -> Key {
            Key(x: Int32((p.x * 1e4).rounded()), y: Int32((p.y * 1e4).rounded()), z: Int32((p.z * 1e4).rounded()))
        }
        var sums: [Key: SIMD3<Float>] = [:]
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = positions[Int(indices[i])], b = positions[Int(indices[i + 1])], c = positions[Int(indices[i + 2])]
            let cr = simd_cross(b - a, c - a)
            let len = simd_length(cr)
            guard len > 1e-9 else { continue }
            // Angle-ish weighting via the face normal, not area, so thin slivers count too.
            let n = cr / len
            for p in [a, b, c] { sums[key(p), default: .zero] += n }
        }
        return positions.map { p in
            let s = sums[key(p)] ?? .zero
            return simd_length(s) > 1e-6 ? simd_normalize(s) : [0, 1, 0]
        }
    }

    /// The inverted hull for the ink outline: every vertex pushed out along its smoothed normal.
    /// Drawn with front faces culled, only the rim behind the silhouette shows.
    public func outlineHull(width: Float) -> LowPolyMesh {
        var m = self
        let sn = smoothedNormals()
        m.positions = zip(positions, sn).map { $0 + $1 * width }
        m.normals = sn
        return m
    }

    /// The flat normal of triangle `i`.
    func faceNormal(_ i: Int) -> SIMD3<Float> {
        let a = positions[Int(indices[i * 3])], b = positions[Int(indices[i * 3 + 1])], c = positions[Int(indices[i * 3 + 2])]
        let cr = simd_cross(b - a, c - a)
        return simd_length(cr) > 1e-9 ? simd_normalize(cr) : [0, 1, 0]
    }

    /// A RealityKit descriptor. `faceMaterials`, one per triangle, selects among several materials.
    func descriptor(name: String = "mesh", faceMaterials: [UInt32]? = nil) -> MeshDescriptor {
        var d = MeshDescriptor(name: name)
        d.positions = MeshBuffer(positions)
        d.normals = MeshBuffer(normals)
        d.textureCoordinates = MeshBuffer(uvs)
        d.primitives = .triangles(indices)
        if let faceMaterials { d.materials = .perFace(faceMaterials) }
        return d
    }
}
