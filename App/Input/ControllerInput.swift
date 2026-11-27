import CoreGraphics
import Foundation
import GameController
import QuartzCore
import SpikeCore

/// A game controller, basic (plan 5): A is the finger (down to tap or press, up to let go), the
/// left stick moves it (aim on their court, or flick toward a hitter for a set or a read), the
/// shoulder buttons cycle the switch strip, and Y jumps to the ball. It drives the same
/// `TouchTranslator` as the screen, with a virtual finger.
@MainActor
final class ControllerInput {
    /// The virtual finger's touch key, apart from real fingers'.
    static let touchKey = -1
    /// How fast the stick moves the finger, in points per second at full tilt.
    static let speed: CGFloat = 700

    let translator: TouchTranslator
    /// The strip's chips, in order, and how to switch.
    var strip: () -> [HUDModel.StripChip]
    var switchTo: (Pick) -> Void

    private(set) var cursor: CGPoint?
    private var stick: CGPoint = .zero
    private var down = false
    private var lastWindow: ContactID?
    private var observers: [NSObjectProtocol] = []

    init(translator: TouchTranslator, strip: @escaping () -> [HUDModel.StripChip], switchTo: @escaping (Pick) -> Void) {
        self.translator = translator
        self.strip = strip
        self.switchTo = switchTo
    }

    var isConnected: Bool { GCController.current?.extendedGamepad != nil }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        })
        attach()
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    private func attach() {
        guard let pad = GCController.current?.extendedGamepad else { return }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.button(pressed) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.stick = CGPoint(x: CGFloat(x), y: CGFloat(-y)) }
        }
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.cycle(-1) } }
        }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.cycle(1) } }
        }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { if pressed { self?.switchTo(.ball) } }
        }
    }

    private func button(_ pressed: Bool) {
        let now = CACurrentMediaTime()
        guard let p = cursor else { return }
        if pressed {
            down = true
            translator.began(p, t: now, touch: Self.touchKey)
        } else if down {
            down = false
            translator.ended(p, t: now, touch: Self.touchKey)
        }
    }

    /// The next (`by` 1) or previous (−1) chip on the strip from the lit one.
    private func cycle(_ by: Int) {
        let chips = strip()
        guard !chips.isEmpty else { return }
        let i = chips.firstIndex(where: \.lit) ?? 0
        switchTo(chips[(i + by + chips.count) % chips.count].pick)
    }

    /// Once a frame: a new window puts the finger on the middle of their court (or the setter),
    /// and the stick moves it.
    func frame(dt: Double, view: ScreenProjector?, ownership: HumanOwnership, state: GameState) {
        guard isConnected, let view, let side = ownership.localSide else { return }
        let next = ownership.next
        if next?.id != lastWindow, !down {
            lastWindow = next?.id
            let home: CGPoint?
            switch next?.kind {
            case .set?:
                home = next?.athlete.flatMap { state.motion[$0] }.flatMap { view.point($0.pos, height: 0) }
            default:
                home = view.point(LocalFrame.toWorld(LocalSpot(d: 5, l: 0), team: side.other), height: 0)
            }
            cursor = home ?? CGPoint(x: view.size.width / 2, y: view.size.height / 2)
        }
        guard var c = cursor else { return }
        c.x = min(max(c.x + stick.x * Self.speed * CGFloat(dt), 0), view.size.width)
        c.y = min(max(c.y + stick.y * Self.speed * CGFloat(dt), 0), view.size.height)
        cursor = c
        if down { translator.moved(c, t: CACurrentMediaTime(), touch: Self.touchKey) }
    }
}
