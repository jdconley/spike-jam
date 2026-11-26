import Foundation
import simd

/// One limb: the directions of its upper and lower segments.
/// Arms are in the torso's frame, legs in the pelvis's: +y up, +z forward, +x the player's left.
struct LimbSpec {
    var upper: SIMD3<Float>
    var lower: SIMD3<Float>

    /// The same limb on the other side.
    var mirrored: LimbSpec { LimbSpec(upper: upper * [-1, 1, 1], lower: lower * [-1, 1, 1]) }

    static func hanging(out: Float = 0.1) -> LimbSpec { LimbSpec(upper: [out, -1, 0.03], lower: [out * 0.6, -1, 0.2]) }

    /// A limb swung forward by `swing` radians (negative is back) in the sagittal plane, with the
    /// lower segment bent a further `bend` (forward for arms, back for legs with a negative bend).
    static func swing(_ swing: Float, bend: Float, out: Float = 0.08) -> LimbSpec {
        LimbSpec(upper: [out, -cosf(swing), sinf(swing)],
                 lower: [out * 0.5, -cosf(swing + bend), sinf(swing + bend)])
    }

    func mix(_ o: LimbSpec, _ t: Float) -> LimbSpec {
        LimbSpec(upper: simd_mix(upper, o.upper, SIMD3(repeating: t)), lower: simd_mix(lower, o.lower, SIMD3(repeating: t)))
    }
}

/// Every joint of a pose.
struct PoseSpec {
    var pelvisPitch: Float = 0   // whole body tips forward (dives)
    var forward: Float = 0       // pelvis shift forward, meters
    var spineLean: Float = 0.04  // forward bend
    var spineTwist: Float = 0    // + turns the chest to the player's left
    var headPitch: Float = 0     // + looks up
    var toePoint: Float = 0      // + tips the toes down
    var armL = LimbSpec.hanging()
    var armR = LimbSpec.hanging().mirrored
    var legL = LimbSpec(upper: [0.05, -1, 0.03], lower: [0.04, -1, -0.03])
    var legR = LimbSpec(upper: [-0.05, -1, 0.03], lower: [-0.04, -1, -0.03])
}

enum PoseLibrary {
    static func spec(_ pose: Pose, phase raw: Float) -> PoseSpec {
        let p = raw.isFinite ? min(max(raw, 0), 1) : 0
        let cyc = sinf(2 * .pi * p)
        var s = PoseSpec()
        switch pose {
        case .stand:
            s.legL = .swing(0.06, bend: -0.12, out: 0.06)
            s.legR = LimbSpec.swing(0.06, bend: -0.12, out: 0.06).mirrored

        case .run:
            let a = 0.7 * cyc
            let kneeL = 0.35 + 1.0 * max(0, sinf(2 * .pi * p + 1.2))
            let kneeR = 0.35 + 1.0 * max(0, -sinf(2 * .pi * p + 1.2))
            s.legL = .swing(a, bend: -kneeL, out: 0.04)
            s.legR = LimbSpec.swing(-a, bend: -kneeR, out: 0.04).mirrored
            s.armL = .swing(-0.75 * cyc, bend: 1.45, out: 0.12)
            s.armR = LimbSpec.swing(0.75 * cyc, bend: 1.45, out: 0.12).mirrored
            s.spineLean = 0.28
            s.spineTwist = 0.18 * cyc
            s.toePoint = 0.2

        case .shuffle:
            // Athletic ready stance, feet stepping wide and back together.
            let step = 0.1 * cyc
            s.spineLean = 0.38
            s.legL = LimbSpec(upper: [0.36 + step, -0.82, 0.42], lower: [0.22 + step, -1, -0.2])
            s.legR = LimbSpec(upper: [0.36 - step, -0.82, 0.42], lower: [0.22 - step, -1, -0.2]).mirrored
            s.armL = LimbSpec(upper: [0.22, -0.55, 0.8], lower: [0.05, -0.15, 1])
            s.armR = s.armL.mirrored
            s.headPitch = 0.3

        case .approach:
            // The last two steps: arms swing from far back (0) to forward and up (1), hips loaded.
            let arms = -1.5 + p * 2.4
            s.spineLean = 0.6 - 0.25 * p
            s.legL = .swing(0.85, bend: -0.95, out: 0.08)
            s.legR = LimbSpec.swing(-0.25, bend: -1.1, out: 0.06).mirrored
            s.armL = .swing(arms, bend: 0.15, out: 0.14)
            s.armR = LimbSpec.swing(arms, bend: 0.15, out: 0.14).mirrored
            s.headPitch = 0.35

        case .jump:
            // Takeoff (0) to the top (1): arms drive up, legs tuck.
            let arms = 1.6 + 1.25 * p
            s.spineLean = 0.12 - 0.15 * p
            s.legL = .swing(0.2 + 0.4 * p, bend: -0.25 - 0.6 * p, out: 0.07)
            s.legR = LimbSpec.swing(0.15 + 0.3 * p, bend: -0.3 - 0.7 * p, out: 0.07).mirrored
            s.armL = .swing(arms, bend: 0.1, out: 0.16)
            s.armR = LimbSpec.swing(arms, bend: 0.1, out: 0.16).mirrored
            s.toePoint = 0.6
            s.headPitch = 0.3

        case .spikeSwing:
            // Cocked bow-and-arrow (0), contact high and in front (0.5), follow-through (1).
            let cocked = LimbSpec(upper: [-0.8, 0.55, -0.25], lower: [0.15, 0.7, -0.7])
            let contact = LimbSpec(upper: [-0.18, 0.95, 0.3], lower: [-0.12, 0.95, 0.35])
            let through = LimbSpec(upper: [0.25, -0.5, 0.85], lower: [0.35, -0.75, 0.55])
            let hit = p < 0.5 ? cocked.mix(contact, p * 2) : contact.mix(through, (p - 0.5) * 2)
            s.armR = hit
            let reach = LimbSpec(upper: [0.25, 0.85, 0.5], lower: [0.15, 0.9, 0.45])
            let pulled = LimbSpec(upper: [0.35, -0.75, 0.4], lower: [0.15, -0.6, 0.8])
            s.armL = reach.mix(pulled, p)
            s.spineLean = -0.35 + 0.8 * p
            s.spineTwist = 0.55 - 1.0 * p
            s.headPitch = 0.4 - 0.4 * p
            s.legL = .swing(0.5, bend: -0.9, out: 0.08)
            s.legR = LimbSpec.swing(0.1, bend: -0.6, out: 0.08).mirrored
            s.toePoint = 0.6

        case .block:
            // Hands up, then pressing over the net.
            s.armL = LimbSpec(upper: [0.16, 1, 0.08 + 0.35 * p], lower: [0.12, 1, 0.12 + 0.45 * p])
            s.armR = s.armL.mirrored
            s.spineLean = 0.02 + 0.1 * p
            s.legL = .swing(0.1, bend: -0.15, out: 0.08)
            s.legR = LimbSpec.swing(0.1, bend: -0.15, out: 0.08).mirrored
            s.headPitch = 0.2
            s.toePoint = 0.3 * p

        case .passPlatform:
            // Low and wide, arms straight together in a platform.
            let sink = 0.85 + 0.2 * p
            s.spineLean = 0.5
            s.legL = LimbSpec(upper: [0.38, -0.55 / sink, 0.75], lower: [0.16, -1, -0.12])
            s.legR = s.legL.mirrored
            s.armL = LimbSpec(upper: [-0.4, -0.6 + 0.3 * p, 0.75], lower: [-0.4, -0.6 + 0.3 * p, 0.75])
            s.armR = s.armL.mirrored
            s.headPitch = 0.45

        case .setHands:
            // Elbows out, hands shaping a window above the forehead.
            s.armL = LimbSpec(upper: [0.6, 0.55 + 0.25 * p, 0.45], lower: [-0.35, 0.8, 0.4 + 0.2 * p])
            s.armR = s.armL.mirrored
            s.spineLean = -0.06
            s.headPitch = 0.4
            s.legL = .swing(0.25, bend: -0.45, out: 0.07)
            s.legR = LimbSpec.swing(0.2, bend: -0.4, out: 0.07).mirrored

        case .dive:
            // Lunge (0) to laid out along the floor, arms reaching (1).
            s.pelvisPitch = 0.5 + 0.95 * p
            s.forward = 0.4 * p
            s.spineLean = 0.2 * (1 - p)
            s.headPitch = 0.6 + 0.4 * p
            s.armL = LimbSpec(upper: [0.28, 0.6 + 0.35 * p, 0.6], lower: [0.18, 0.7 + 0.3 * p, 0.6])
            s.armR = s.armL.mirrored
            s.legL = .swing(-0.15 * p, bend: -0.2, out: 0.1)
            s.legR = LimbSpec.swing(0.9 - 0.7 * p, bend: -1.2 + 0.6 * p, out: 0.12).mirrored
            s.toePoint = 0.8

        case .celebrate:
            // Fists up in a V, bouncing.
            let bounce = 0.5 + 0.5 * cyc
            s.armL = LimbSpec(upper: [0.62, 0.78, 0.12], lower: [0.5, 0.86, 0.08 + 0.2 * bounce])
            s.armR = s.armL.mirrored
            s.spineLean = -0.12
            s.headPitch = 0.35
            s.legL = .swing(0.12 + 0.2 * bounce, bend: -0.25 - 0.35 * bounce, out: 0.1)
            s.legR = LimbSpec.swing(0.12 + 0.2 * bounce, bend: -0.25 - 0.35 * bounce, out: 0.1).mirrored
        }
        return s
    }
}
