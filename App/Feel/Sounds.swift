import AVFoundation
import SpikeCore

/// Placeholder sound until plan 8's real audio: ball, net, floor and crowd cues synthesized as
/// short tones and noise bursts, played through `AVAudioEngine`. The session is `.ambient`, so it
/// mixes with the player's music and follows the silent switch.
@MainActor
final class Sounds {
    /// One cue.
    enum Cue: Equatable, Sendable {
        /// A pass, dig, serve, attack or block, `power` 0...1.
        case ball(power: Float)
        /// A set: a soft, high touch.
        case set
        /// The ball into the net.
        case net
        /// The ball hitting the floor.
        case floor
        /// The crowd reacting, `level` 0...1.
        case crowd(level: Float)
        /// A bright ding: the local player timed a touch perfectly.
        case perfect
    }

    /// The cues `events` call for. With `ownership`, the local player's perfect touches ding.
    static func cues(for events: [FeltEvent], ownership: HumanOwnership? = nil) -> [Cue] {
        var out: [Cue] = []
        for e in events {
            switch e.event {
            case .judged(let id, .perfect) where ownership?.window(id) != nil:
                out.append(.perfect)
            case .served:
                out.append(.ball(power: TouchPower.of(.serve, incoming: e.incoming, outgoing: e.outgoing)))
            case .touched(let kind, _, _):
                out.append(kind == .set ? .set : .ball(power: TouchPower.of(kind, incoming: e.incoming, outgoing: e.outgoing)))
            case .erred(_, _, let error) where error == .net:
                out.append(.net)
            case .point(_, let reason):
                out.append(.floor)
                let big = reason == .kill || reason == .ace || reason == .block
                out.append(.crowd(level: big ? 1 : 0.45))
            default:
                break
            }
        }
        return out
    }

    static let sampleRate: Double = 44_100

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Sounds.sampleRate, channels: 1)!
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private let bed = AVAudioPlayerNode()
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private(set) var isRunning = false

    init() {
        buffers = [
            "hitSoft": Self.render(0.14) { t in Self.thump(t, from: 150, to: 95, decay: 30) + 0.25 * Self.click(t) },
            "hitHard": Self.render(0.16) { t in Self.thump(t, from: 190, to: 80, decay: 24) + 0.6 * Self.click(t) },
            "perfect": Self.render(0.22) { t in
                0.35 * (sin(2 * .pi * 1320 * t) + 0.5 * sin(2 * .pi * 1980 * t)) * exp(-16 * t)
            },
            "set": Self.render(0.07) { t in 0.5 * sin(2 * .pi * 520 * t) * exp(-60 * t) + 0.15 * Self.click(t) },
            "net": Self.render(0.4) { t in
                (0.55 * Self.noise(t) * (0.6 + 0.4 * sin(2 * .pi * 38 * t)) + 0.3 * sin(2 * .pi * 70 * t)) * exp(-7 * t)
            },
            "floor": Self.render(0.12) { t in 0.7 * Self.noise(t) * exp(-45 * t) + 0.5 * sin(2 * .pi * 210 * t) * exp(-35 * t) },
            "crowd": Self.render(1.6) { t in
                let swell = min(t / 0.15, 1) * exp(-1.6 * max(t - 0.15, 0))
                return 0.45 * Self.murmur(t) * swell
            },
            "bed": Self.render(4.0) { t in 0.12 * Self.murmur(t) * (0.8 + 0.2 * sin(2 * .pi * 0.5 * t)) },
        ]
    }

    /// Starts the engine and the crowd bed. Silent (and harmless) if audio isn't available.
    func start() {
        guard !isRunning else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if voices.isEmpty {
            for _ in 0..<6 {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                voices.append(node)
            }
            engine.attach(bed)
            engine.connect(bed, to: engine.mainMixerNode, format: format)
        }
        do {
            try engine.start()
        } catch {
            return
        }
        isRunning = true
        if let b = buffers["bed"] {
            bed.volume = 0.5
            bed.scheduleBuffer(b, at: nil, options: .loops)
            bed.play()
        }
    }

    func stop() {
        guard isRunning else { return }
        bed.stop()
        for v in voices { v.stop() }
        engine.stop()
        isRunning = false
    }

    func play(_ cues: [Cue]) {
        guard isRunning else { return }
        for cue in cues {
            switch cue {
            case .ball(let power):
                voice(power > 0.55 ? "hitHard" : "hitSoft", volume: 0.45 + 0.55 * power)
            case .set:
                voice("set", volume: 0.6)
            case .net:
                voice("net", volume: 0.9)
            case .floor:
                voice("floor", volume: 0.7)
            case .crowd(let level):
                voice("crowd", volume: 0.35 + 0.65 * level)
            case .perfect:
                voice("perfect", volume: 0.5)
            }
        }
    }

    private func voice(_ name: String, volume: Float) {
        guard let b = buffers[name], !voices.isEmpty else { return }
        let node = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        node.volume = volume
        node.scheduleBuffer(b, at: nil, options: .interrupts)
        node.play()
    }

    // MARK: Synthesis

    private static func render(_ seconds: Double, _ f: (Double) -> Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let n = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        let out = buf.floatChannelData![0]
        let fade = Int(0.004 * sampleRate)
        for i in 0..<Int(n) {
            // A few milliseconds of fade at the end so nothing clicks off.
            let tail = min(1, Double(Int(n) - i) / Double(fade))
            out[i] = Float(max(-1, min(1, f(Double(i) / sampleRate) * tail)))
        }
        return buf
    }

    /// A sine sweeping down from `from` to `to` Hz, decaying: the body of a hit.
    private static func thump(_ t: Double, from: Double, to: Double, decay: Double) -> Double {
        let k = 25.0
        let phase = 2 * .pi * (to * t + (from - to) * (1 - exp(-k * t)) / k)
        return 0.8 * sin(phase) * exp(-decay * t)
    }

    /// A few milliseconds of noise: the slap of the contact.
    private static func click(_ t: Double) -> Double { noise(t) * exp(-260 * t) }

    /// Repeatable white noise from the sample time.
    private static func noise(_ t: Double) -> Double {
        var x = UInt64(truncatingIfNeeded: Int((t * sampleRate).rounded())) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 31
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 29
        return Double(x % 20_001) / 10_000 - 1
    }

    /// A crowd-ish murmur: noise smeared over a few samples, with a slow wobble.
    private static func murmur(_ t: Double) -> Double {
        let d = 1 / sampleRate
        let smooth = (noise(t) + noise(t - d) + noise(t - 2 * d) + noise(t - 3 * d)) / 4
        return smooth * (0.7 + 0.3 * sin(2 * .pi * 3.1 * t) * sin(2 * .pi * 1.3 * t + 1))
    }
}
