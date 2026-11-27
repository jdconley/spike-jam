import SpikeCore
import UIKit

/// How a touch went, for the feel layer: until plan 4's timing grades, the touch quality SpikeCore
/// reports, banded the way the HUD will name it.
enum TouchGrade: Equatable, Sendable {
    case perfect, good, okay, poor

    init(quality q: Float) {
        self = q >= 0.85 ? .perfect : q >= 0.6 ? .good : q >= 0.3 ? .okay : .poor
    }
}

/// How hard the ball was moving for a touch, 0...1: the ball coming in for a pass, dig or block,
/// the ball going out for a serve or attack, and a soft constant for a set.
enum TouchPower {
    static func of(_ kind: TouchKind, incoming: Flight?, outgoing: Flight?) -> Float {
        switch kind {
        case .serve, .attack: speed(outgoing)
        case .receive, .dig, .block: speed(incoming)
        default: 0.2
        }
    }

    /// A flight's launch speed mapped to 0...1: a soft free ball is ~8 m/s, a big swing ~30.
    static func speed(_ f: Flight?) -> Float {
        guard let f else { return 0 }
        return min(max((f.v0.length - 8) / 22, 0), 1)
    }
}

/// The haptic per touch (spec §4.4: haptics on every touch, scaled by power and quality), and a
/// heavy hit for kills and stuffs.
@MainActor
final class Haptics {
    /// One haptic: the generator style and how hard.
    struct Pulse: Equatable, Sendable {
        enum Style: Equatable, Sendable { case light, soft, medium, rigid, heavy }
        var style: Style
        var intensity: Float
    }

    /// The grade picks the character (a crisp perfect, a mushy miss) and the power the strength.
    static func pulse(kind: TouchKind, power: Float, grade: TouchGrade) -> Pulse {
        let style: Pulse.Style = switch grade {
        case .perfect: .rigid
        case .good: .medium
        case .okay: .soft
        case .poor: .light
        }
        let base: Float = kind == .set ? 0.35 : 0.45
        let gradeBoost: Float = grade == .perfect ? 0.15 : 0
        return Pulse(style: style, intensity: min(1, base + 0.45 * power + gradeBoost))
    }

    /// The pulses `events` call for: one per touch the local player owns, and a heavy one when a
    /// kill or a stuff ends a rally the local team played (full strength when it's their point).
    static func pulses(for events: [FeltEvent], ownership: any LocalOwnership, in s: GameState) -> [Pulse] {
        guard let local = ownership.localSide else { return [] }
        var out: [Pulse] = []
        for e in events {
            switch e.event {
            case .served(let id) where ownership.owns(id, in: s):
                // The serve has no quality of its own yet: a good contact, as hard as it flies.
                let power = TouchPower.of(.serve, incoming: e.incoming, outgoing: e.outgoing)
                out.append(pulse(kind: .serve, power: power, grade: .good))
            case .touched(let kind, let id, let quality) where ownership.owns(id, in: s):
                let power = TouchPower.of(kind, incoming: e.incoming, outgoing: e.outgoing)
                out.append(pulse(kind: kind, power: power, grade: TouchGrade(quality: quality)))
            case .point(let winner, let reason) where reason == .kill || reason == .block:
                out.append(Pulse(style: .heavy, intensity: winner == local ? 1 : 0.7))
            default:
                break
            }
        }
        return out
    }

    private var generators: [Pulse.Style: UIImpactFeedbackGenerator] = [:]

    init() {
        let styles: [Pulse.Style: UIImpactFeedbackGenerator.FeedbackStyle] = [
            .light: .light, .soft: .soft, .medium: .medium, .rigid: .rigid, .heavy: .heavy,
        ]
        for (style, feedback) in styles {
            let g = UIImpactFeedbackGenerator(style: feedback)
            g.prepare()
            generators[style] = g
        }
    }

    func play(_ pulses: [Pulse]) {
        for p in pulses {
            guard let g = generators[p.style] else { continue }
            g.impactOccurred(intensity: CGFloat(p.intensity))
            g.prepare()
        }
    }
}
