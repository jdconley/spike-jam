import Foundation
import QuartzCore
import SpikeCore

/// Drives the match from the display: each frame it advances the client loop to the frame's time,
/// then hands the states and events to whoever draws them (the scene, later the HUD).
///
/// The display link asks for the screen's top rate (120 Hz on ProMotion); the simulation stays at
/// a fixed 60 Hz inside the client loop and drawing interpolates between steps.
@MainActor
final class GameLoop {
    /// Called once per frame after the client loop advanced.
    typealias FrameHandler = @MainActor (_ client: any ClientLoop, _ events: [GameEvent]) -> Void

    private(set) var client: any ClientLoop
    var onFrame: FrameHandler?
    private(set) var isPaused = false
    private(set) var isRunning = false

    private let clock: () -> Double
    private var link: CADisplayLink?

    /// `clock` is `CACurrentMediaTime`, the clock of display links and touch timestamps; tests
    /// inject their own.
    init(client: any ClientLoop, clock: @escaping () -> Double = { CACurrentMediaTime() }) {
        self.client = client
        self.clock = clock
    }

    /// Starts the display link.
    func start() {
        guard link == nil else { return }
        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        // The system clamps this to what the screen can do: 120 on ProMotion, else 60.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = isPaused
        link.add(to: .main, forMode: .common)
        self.link = link
        isRunning = true
    }

    /// Stops and releases the display link.
    func stop() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    /// Freezes the match (solo only: the app went to the background, or a menu is up).
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        link?.isPaused = true
        client.pause()
    }

    /// Unfreezes the match from now: the paused time is not stepped.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        client.resume(at: clock())
        link?.isPaused = false
    }

    /// Swaps in a new client loop, such as the next match, starting from now.
    func replace(client: any ClientLoop) {
        self.client = client
        if isPaused { client.pause() } else { client.resume(at: clock()) }
    }

    /// One frame: advance to the clock's now and draw. The display link calls it; tests call it
    /// directly.
    func frame() {
        guard !isPaused else { return }
        let events = client.advance(to: clock())
        onFrame?(client, events)
    }
}

/// `CADisplayLink` retains its target; this proxy holds the loop weakly so the loop can go away.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var owner: GameLoop?

    init(owner: GameLoop) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.frame()
    }
}
