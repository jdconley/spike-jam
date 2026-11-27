import CoreGraphics
import simd
import SpikeCore

/// The camera as drawn this frame and the view it fills: world points to screen points (for the
/// HUD) and screen points back to rays (for aiming). Screen points are UIKit's: origin top left,
/// y down, in the court view's own coordinates.
struct ScreenProjector: Equatable, Sendable {
    var shot: CameraShot
    var size: CGSize

    var aspect: Float { Float(size.width / max(size.height, 1)) }

    /// Where `p` is drawn; nil when it's behind the camera or the view has no size.
    func point(_ p: SIMD3<Float>) -> CGPoint? {
        guard size.width > 0, size.height > 0, let n = shot.project(p, aspect: aspect) else { return nil }
        return CGPoint(x: (CGFloat(n.x) + 1) / 2 * size.width, y: (1 - CGFloat(n.y)) / 2 * size.height)
    }

    func point(_ p: Vec3) -> CGPoint? { point([p.x, p.y, p.z]) }

    /// `v` on the floor, raised to `height`.
    func point(_ v: Vec2, height: Float) -> CGPoint? { point([v.x, height, v.z]) }

    /// The ray from the camera through screen point `p`, the inverse of `point`.
    func ray(through p: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let b = shot.basis
        let t = tanf(shot.fov * .pi / 360)
        let nx = Float(p.x / max(size.width, 1)) * 2 - 1
        let ny = 1 - Float(p.y / max(size.height, 1)) * 2
        let d = b.forward + b.right * (nx * t * aspect) + b.up * (ny * t)
        return (shot.position, simd_normalize(d))
    }
}

/// Where a finger points on the floor (spec §4.2: serves and spikes aim by location), ported
/// from the spike's `floorHit`: the ray through the touch, met with the y = 0 plane.
enum FloorPicker {
    /// The floor point under screen point `p`; nil when the ray never comes down to the floor.
    static func floorHit(_ p: CGPoint, _ view: ScreenProjector) -> Vec2? {
        let r = view.ray(through: p)
        guard r.direction.y < -0.001 else { return nil }
        let t = -r.origin.y / r.direction.y
        let h = r.origin + r.direction * t
        return Vec2(x: h.x, z: h.z)
    }

    /// Whether `v` is on `side`'s court, with `margin` metres of slack past the lines (a finger
    /// on the line, or just past it, still means that court).
    static func isOnCourt(_ v: Vec2, side: TeamSide, margin: Float = 1) -> Bool {
        let d = LocalFrame.toLocal(v, team: side)
        return d.d > -0.2 && d.d <= Court.halfLength + margin && abs(d.l) <= Court.halfWidth + margin
    }
}
