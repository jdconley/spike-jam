// THROWAWAY SPIKE. The RealityKit view: court, players, ball, camera, touches, feel.

import RealityKit
import UIKit
import Combine
import GameController

@MainActor
final class CourtView: ARView {
    let sim = Sim()
    let hud: HUDModel
    var root = AnchorEntity(world: .zero)
    let camera = PerspectiveCamera()
    var playerEntities: [Entity] = []
    var bodies: [ModelEntity] = []
    var arms: [[Entity]] = []
    let autoplay = ProcessInfo.processInfo.environment["SPIKE_AUTOPLAY"] != nil
    var autoDone: Double = -1
    var fireFX: [Entity] = []
    let ball = ModelEntity()
    let ballShadow = ModelEntity()
    let ballTrail = Entity()
    let youArrow = ModelEntity()
    let landMarker = ModelEntity()
    let reticle = Entity()
    let aimLine = ModelEntity()
    var updates: Cancellable?
    var camPos = V3(0, 8, 16)
    var camLook = V3(0, 1.2, 0)
    var shake: Float = 0
    var last = CACurrentMediaTime()

    // Touch tracking
    var touchStart: CGPoint = .zero
    var touchStartTime: Double = 0
    var swiped = false
    var aiming = false
    var aimTarget: V2?

    // Haptics
    let light = UIImpactFeedbackGenerator(style: .light)
    let medium = UIImpactFeedbackGenerator(style: .medium)
    let heavy = UIImpactFeedbackGenerator(style: .heavy)
    let rigid = UIImpactFeedbackGenerator(style: .rigid)
    let notify = UINotificationFeedbackGenerator()

    init(hud: HUDModel) {
        self.hud = hud
        super.init(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        environment.background = .color(UIColor(red: 0.05, green: 0.04, blue: 0.10, alpha: 1))
        renderOptions.insert(.disableMotionBlur)
        isMultipleTouchEnabled = false
        build()
        updates = scene.subscribe(to: SceneEvents.Update.self) { [weak self] e in
            self?.frame(e.deltaTime)
        }
        [light, medium, heavy, rigid].forEach { $0.prepare() }
        setupController()
    }

    @MainActor required dynamic init(frame frameRect: CGRect) { fatalError() }
    @MainActor required dynamic init?(coder decoder: NSCoder) { fatalError() }

    // MARK: Scene

    func mat(_ c: UIColor, rough: Float = 0.6) -> SimpleMaterial {
        SimpleMaterial(color: c, roughness: .float(rough), isMetallic: false)
    }

    func build() {
        scene.addAnchor(root)
        camera.camera.fieldOfViewInDegrees = 46
        root.addChild(camera)

        let sun = DirectionalLight()
        sun.light.intensity = 3800
        sun.light.color = .white
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 30, depthBias: 2)
        sun.look(at: .zero, from: V3(-4, 14, 8), relativeTo: nil)
        root.addChild(sun)
        let fill = PointLight()
        fill.light.intensity = 90000
        fill.light.attenuationRadius = 40
        fill.position = V3(0, 9, 10)
        root.addChild(fill)

        // Arena floor, court, lines
        let arena = ModelEntity(mesh: .generatePlane(width: 40, depth: 26), materials: [mat(UIColor(red: 0.12, green: 0.10, blue: 0.22, alpha: 1))])
        arena.position.y = -0.01
        root.addChild(arena)
        let court = ModelEntity(mesh: .generatePlane(width: 18, depth: 9), materials: [mat(UIColor(red: 0.93, green: 0.60, blue: 0.30, alpha: 1), rough: 0.35)])
        root.addChild(court)
        let free = ModelEntity(mesh: .generatePlane(width: 24, depth: 14), materials: [mat(UIColor(red: 0.16, green: 0.36, blue: 0.75, alpha: 1))])
        free.position.y = -0.005
        root.addChild(free)
        let lineMat = UnlitMaterial(color: .white)
        func line(_ w: Float, _ d: Float, _ x: Float, _ z: Float) {
            let l = ModelEntity(mesh: .generatePlane(width: w, depth: d), materials: [lineMat])
            l.position = V3(x, 0.004, z)
            root.addChild(l)
        }
        line(18.1, 0.06, 0, 4.5); line(18.1, 0.06, 0, -4.5)
        line(0.06, 9, 9, 0); line(0.06, 9, -9, 0); line(0.06, 9, 0, 0)
        line(0.05, 9, 3, 0); line(0.05, 9, -3, 0)

        // Net
        let net = ModelEntity(mesh: .generateBox(width: 0.03, height: 1.0, depth: 9.6),
                              materials: [UnlitMaterial(color: UIColor(white: 0.05, alpha: 0.55))])
        net.position = V3(0, netHeight - 0.5, 0)
        root.addChild(net)
        let tape = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.07, depth: 9.6), materials: [UnlitMaterial(color: .white)])
        tape.position = V3(0, netHeight - 0.035, 0)
        root.addChild(tape)
        for z: Float in [-5, 5] {
            let post = ModelEntity(mesh: .generateCylinder(height: 2.6, radius: 0.06), materials: [mat(.lightGray)])
            post.position = V3(0, 1.3, z)
            root.addChild(post)
        }
        // Crowd blocks for depth
        for i in 0..<14 {
            let h = Float.random(in: 1.5...3)
            let stand = ModelEntity(mesh: .generateBox(width: 2.6, height: h, depth: 2),
                                    materials: [mat(UIColor(hue: CGFloat.random(in: 0...1), saturation: 0.5, brightness: 0.35, alpha: 1))])
            stand.position = V3(-17 + Float(i) * 2.6, h / 2, -11)
            root.addChild(stand)
        }

        // Players
        for p in sim.players {
            let e = Entity()
            let jersey: UIColor
            if p.role == .libero {
                jersey = p.team == .home ? UIColor(white: 0.95, alpha: 1) : UIColor(red: 0.12, green: 0.12, blue: 0.3, alpha: 1)
            } else {
                jersey = p.team == .home ? UIColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 1) : UIColor(red: 0.1, green: 0.75, blue: 0.75, alpha: 1)
            }
            let body = ModelEntity(mesh: .generateBox(width: 0.5, height: 1.15, depth: 0.32, cornerRadius: 0.12), materials: [mat(jersey)])
            body.position.y = 1.05
            let legs = ModelEntity(mesh: .generateBox(width: 0.42, height: 0.55, depth: 0.26, cornerRadius: 0.08), materials: [mat(UIColor(white: 0.12, alpha: 1))])
            legs.position.y = 0.3
            let head = ModelEntity(mesh: .generateSphere(radius: 0.17), materials: [mat(UIColor(red: 0.78, green: 0.56, blue: 0.4, alpha: 1))])
            head.position.y = 1.82
            let armL = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.7, depth: 0.12, cornerRadius: 0.05), materials: [mat(jersey)])
            armL.position = V3(0, 1.1, 0.32)
            let armR = armL.clone(recursive: true)
            armR.position.z = -0.32
            arms.append([armL, armR])
            e.addChild(body); e.addChild(legs); e.addChild(head); e.addChild(armL); e.addChild(armR)
            let fx = Entity()
            fx.position.y = 1.2
            var pe = ParticleEmitterComponent()
            pe.emitterShape = .sphere
            pe.emitterShapeSize = V3(0.35, 0.6, 0.35)
            pe.mainEmitter.birthRate = 260
            pe.mainEmitter.lifeSpan = 0.5
            pe.mainEmitter.size = 0.12
            pe.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.1
            pe.mainEmitter.acceleration = V3(0, 4, 0)
            pe.mainEmitter.blendMode = .additive
            pe.mainEmitter.color = .evolving(start: .single(UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)), end: .single(UIColor(red: 1, green: 0.15, blue: 0, alpha: 1)))
            pe.speed = 0.6
            pe.isEmitting = false
            fx.components.set(pe)
            e.addChild(fx)
            fireFX.append(fx)
            root.addChild(e)
            playerEntities.append(e)
            bodies.append(body)
        }

        // Ball
        ball.model = ModelComponent(mesh: .generateSphere(radius: 0.15), materials: [mat(UIColor(red: 1, green: 0.95, blue: 0.75, alpha: 1), rough: 0.3)])
        root.addChild(ball)
        var trail = ParticleEmitterComponent()
        trail.emitterShape = .point
        trail.mainEmitter.birthRate = 500
        trail.mainEmitter.lifeSpan = 0.35
        trail.mainEmitter.size = 0.2
        trail.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.05
        trail.mainEmitter.blendMode = .additive
        trail.mainEmitter.color = .evolving(start: .single(UIColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)), end: .single(UIColor(red: 1, green: 0.1, blue: 0, alpha: 1)))
        trail.speed = 0.05
        trail.isEmitting = false
        ballTrail.components.set(trail)
        ball.addChild(ballTrail)
        ballShadow.model = ModelComponent(mesh: .generateCylinder(height: 0.005, radius: 0.22), materials: [UnlitMaterial(color: UIColor(white: 0, alpha: 0.45))])
        root.addChild(ballShadow)
        // You: a white arrow over your player's head, pointing down.
        youArrow.model = ModelComponent(mesh: .generateCone(height: 0.45, radius: 0.24), materials: [UnlitMaterial(color: .white)])
        youArrow.orientation = simd_quatf(angle: .pi, axis: V3(1, 0, 0))
        root.addChild(youArrow)
        landMarker.model = ModelComponent(mesh: .generateCylinder(height: 0.008, radius: 0.28), materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 0.35))])
        root.addChild(landMarker)
        // Aim reticle: a ring of four ticks plus a dot, on the floor where the ball will go.
        let tickMat = UnlitMaterial(color: .white)
        for i in 0..<4 {
            let a = Float(i) * .pi / 2
            let t = ModelEntity(mesh: .generateBox(width: 0.32, height: 0.01, depth: 0.08), materials: [tickMat])
            t.position = V3(cos(a) * 0.55, 0.012, sin(a) * 0.55)
            t.orientation = simd_quatf(angle: -a, axis: V3(0, 1, 0))
            reticle.addChild(t)
        }
        let dot = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: 0.12), materials: [tickMat])
        dot.position.y = 0.012
        reticle.addChild(dot)
        reticle.isEnabled = false
        root.addChild(reticle)
        aimLine.model = ModelComponent(mesh: .generateBox(width: 1, height: 0.006, depth: 0.06), materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 0.5))])
        aimLine.isEnabled = false
        root.addChild(aimLine)
    }

    // MARK: Frame

    func frame(_ dt: Double) {
        let dt = min(dt, 1.0 / 30)
        pollController()
        if autoplay { autoInput() }
        sim.tick(dt)
        for e in sim.events { handle(e); if autoplay { log(e) } }
        sync(dt)
    }

    func handle(_ e: SimEvent) {
        switch e {
        case .touch(let k, let team, _, let q, let power):
            switch k {
            case .attack: (power > 0.6 ? heavy : medium).impactOccurred(intensity: team == .home ? 1 : 0.5); if power > 0.6 { shake = 0.22 * power }
            case .block: rigid.impactOccurred(); shake = 0.25
            case .serve: medium.impactOccurred(intensity: team == .home ? 0.9 : 0.4)
            case .set: light.impactOccurred(intensity: team == .home ? 0.8 : 0.3)
            default: light.impactOccurred(intensity: team == .home ? CGFloat(0.5 + q * 0.5) : 0.3)
            }
        case .judged(let text, let at, let good):
            hud.flash(text, good: good, at: project(at) ?? .zero)
        case .point(let team, _, _):
            notify.notificationOccurred(team == .home ? .success : .error)
            hud.score = sim.score
        case .banner(let text, let hot, let small):
            hud.show(text, hot: hot, small: small)
        case .fire(let id, let on):
            fireFX[id].components[ParticleEmitterComponent.self]?.isEmitting = on
            if on { heavy.impactOccurred(); shake = 0.3 }
        case .bounce: shake = max(shake, 0.06)
        case .net: break
        }
    }

    func sync(_ dt: Double) {
        let now = sim.now
        for (i, p) in sim.players.enumerated() {
            let e = playerEntities[i]
            e.position = p.pos
            var yaw: Float = p.team == .home ? 0 : .pi
            if now < p.celebrateUntil { yaw += Float(now - p.celebrateStart) * 14 }
            e.orientation = simd_quatf(angle: yaw, axis: V3(0, 1, 0))
            let up = p.pos.y > 0.15 || now < p.celebrateUntil
            for (j, a) in arms[i].enumerated() {
                a.position = V3(0, up ? 1.85 : 1.1, j == 0 ? 0.32 : -0.32)
            }
            let pulse: Float = p.onFire ? 1 + 0.06 * sin(Float(now) * 20) : 1
            e.scale = V3(repeating: pulse)
        }
        let b = sim.ballPos
        ball.position = b
        ballShadow.position = V3(b.x, 0.003, b.z)
        let sh = max(0.3, 1 - b.y / 8)
        ballShadow.scale = V3(sh, 1, sh)
        let hot = sim.flight?.hot == true && (sim.flight.map { now < $0.t0 + $0.dur } ?? false)
        ballTrail.components[ParticleEmitterComponent.self]?.isEmitting = hot

        // You: arrow over whoever plays the next home touch (the server while waiting to serve).
        let w = sim.window
        var youID: Int? = w?.player
        if case .serveWait = sim.phase, sim.server == .home { youID = sim.serverID }
        if let id = youID {
            let p = sim.players[id]
            youArrow.isEnabled = true
            youArrow.position = V3(p.pos.x, p.pos.y + 2.55 + 0.08 * sin(Float(now) * 10), p.pos.z)
        } else { youArrow.isEnabled = false }
        if let p = sim.pending, p.team == .home, p.kind == .receive || p.kind == .dig {
            landMarker.isEnabled = true
            landMarker.position = V3(p.point.x, 0.007, p.point.z)
        } else { landMarker.isEnabled = false }
        // Aim reticle and line while the finger is down on a serve or spike.
        if aiming, let a = aimTarget {
            let t = sim.clampAim(.home, a)
            reticle.isEnabled = true
            reticle.position = V3(t.x, 0, t.y)
            let s: Float = 1 + 0.08 * sin(Float(now) * 14)
            reticle.scale = V3(s, 1, s)
            let fromID = youID ?? sim.serverID
            let f = sim.players[fromID].xz
            let d = t - f
            let len = simd_length(d)
            aimLine.isEnabled = len > 0.3
            aimLine.position = V3((f.x + t.x) / 2, 0.01, (f.y + t.y) / 2)
            aimLine.scale = V3(len, 1, 1)
            aimLine.orientation = simd_quatf(angle: -atan2(d.y, d.x), axis: V3(0, 1, 0))
        } else { reticle.isEnabled = false; aimLine.isEnabled = false }

        updateCamera(dt)
        updateHUD(w)
    }

    func updateCamera(_ dt: Double) {
        var pos: V3
        var look: V3
        var rate: Float = 3
        let b = sim.ballPos
        switch sim.phase {
        case .serveWait:
            let s = sim.players[sim.serverID]
            let d = sim.server.dir
            pos = V3(s.pos.x - d * 3.5, 3.2, s.pos.z + 5)
            look = V3(s.pos.x + d * 6, 1.4, 0)
            rate = 2.5
        case .dead:
            if sim.celebrating >= 0 {
                let p = sim.players[sim.celebrating].pos
                pos = V3(p.x * 0.85, 2.4, p.z + 5.2)
                look = V3(p.x, 1.4, p.z)
                rate = 2.2
            } else {
                pos = V3(b.x * 0.4, 6.5, 13)
                look = V3(b.x * 0.5, 1, 0)
            }
        case .rally:
            if let p = sim.pending, p.kind == .attack {
                let d = p.team.dir
                pos = V3(p.point.x - d * 5.5, 4.2, p.point.z * 0.4 + 9.5)
                look = V3(d * 3.5, 1.6, p.point.z * 0.3)
                rate = 4.5
            } else {
                pos = V3(b.x * 0.5, 6.6, 13.2)
                look = V3(b.x * 0.55, 1.2, -0.4)
            }
        }
        let k = 1 - exp(-rate * Float(dt))
        camPos += (pos - camPos) * k
        camLook += (look - camLook) * k
        shake *= exp(-7 * Float(dt))
        let jitter = V3(Float.random(in: -1...1), Float.random(in: -1...1), 0) * shake
        camera.look(at: camLook + jitter * 0.5, from: camPos + jitter, relativeTo: nil)
    }

    func updateHUD(_ w: Sim.Window?) {
        hud.score = sim.score
        hud.serving = sim.server
        hud.matchOver = sim.matchOver
        if case .serveWait = sim.phase, sim.server == .home {
            hud.prompt = "HOLD TO TOSS • DRAG TO AIM • LET GO TO SERVE"
            hud.ring = nil
            hud.options = []
            return
        }
        guard let w else { hud.prompt = nil; hud.ring = nil; hud.options = []; return }
        let left = w.time - sim.now
        let lead = 0.6
        if left < lead, left > -0.12, let pt = project(w.point) {
            hud.ring = RingState(center: pt, progress: CGFloat(max(0, left) / lead), perfect: abs(left) < 0.06)
        } else { hud.ring = nil }
        switch w.kind {
        case .serve: hud.prompt = aiming ? "LET GO WHEN THE RING CLOSES" : "TOUCH THEIR COURT TO AIM"
        case .receive: hud.prompt = "TAP TO PASS"
        case .dig: hud.prompt = "TAP TO DIG!"
        case .block: hud.prompt = "TAP TO BLOCK"
        case .set: hud.prompt = "SWIPE TOWARD A HITTER"
        case .attack: hud.prompt = aiming ? "LET GO WHEN THE RING CLOSES • NEAR THE NET = TIP" : "TOUCH THEIR COURT WHERE YOU WANT IT"
        case .land: hud.prompt = nil
        }
        if w.kind == .set, let p = sim.pending, let sp = project(sim.players[w.player].pos + V3(0, 1.8, 0)) {
            hud.options = sim.setOptions(.home, incoming: p.incoming).compactMap { o in
                guard o.player != w.player else { return nil }
                let off: CGPoint
                let label: String
                switch o.role {
                case .outside: off = CGPoint(x: 0, y: -78); label = "OUTSIDE ↑"
                case .opposite: off = CGPoint(x: 0, y: 78); label = "↓ OPPOSITE"
                case .middle: off = CGPoint(x: 110, y: 0); label = "QUICK →"
                default: off = CGPoint(x: -100, y: 0); label = "← PIPE"
                }
                return SetMarker(label: label, at: CGPoint(x: sp.x + off.x, y: sp.y + off.y + 30), available: o.available,
                                 hot: sim.players[o.player].onFire)
            }
        } else { hud.options = [] }
    }

    // MARK: Autoplay (test harness: plays the human side with sloppy timing)

    func autoInput() {
        if case .serveWait(let since) = sim.phase, sim.server == .home, sim.now - since > 1 {
            sim.input(.press(sim.now)); return
        }
        if case .dead = sim.phase, sim.matchOver { sim.rematch() }
        guard let w = sim.window, w.time != autoDone else { return }
        let jitter = Double.random(in: -0.15...0.08)
        guard sim.now >= w.time + jitter else { return }
        autoDone = w.time
        switch w.kind {
        case .receive, .dig, .block: sim.input(.press(sim.now))
        case .set:
            sim.input(.swipe(sim.now, dir: simd_normalize(V2(Float.random(in: -1...1), Float.random(in: -1...1))), power: 0.5))
        case .attack, .serve:
            sim.input(.aim(sim.now, target: V2(Float.random(in: 1...8.5), Float.random(in: -4...4))))
        case .land: break
        }
    }

    func log(_ e: SimEvent) {
        switch e {
        case .touch(let k, let t, let p, let q, let pw): print(String(format: "t=%.2f touch %@ %@ p%d q=%.2f pw=%.2f", sim.now, "\(k)", "\(t)", p, q, pw))
        case .point(let t, let r, let by): print(String(format: "t=%.2f POINT %@ %@ by %d  score %d-%d", sim.now, "\(t)", r, by, sim.score[0], sim.score[1]))
        case .banner(let s, let hot, _): print("   banner \(s)\(hot ? " 🔥" : "")")
        case .judged(let s, _, _): print("   judged \(s)")
        case .fire(let id, let on): print("   FIRE \(id) \(on)")
        default: break
        }
    }

    // MARK: Touch

    func groundDir(_ a: CGPoint, _ b: CGPoint) -> V2? {
        func hit(_ p: CGPoint) -> V2? {
            guard let r = ray(through: p), r.direction.y < -0.001 else { return nil }
            let t = (1.0 - r.origin.y) / r.direction.y
            let h = r.origin + r.direction * t
            return V2(h.x, h.z)
        }
        guard let ha = hit(a), let hb = hit(b) else { return nil }
        let d = hb - ha
        let len = simd_length(d)
        return len > 0.01 ? d / len : nil
    }

    func floorHit(_ p: CGPoint) -> V2? {
        guard let r = ray(through: p), r.direction.y < -0.001 else { return nil }
        let t = -r.origin.y / r.direction.y
        let h = r.origin + r.direction * t
        return V2(h.x, h.z)
    }

    /// Serves and spikes aim by location: the ball goes where your finger is when you let go.
    var aimKindNow: Bool {
        if case .serveWait = sim.phase, sim.server == .home { return true }
        guard let w = sim.window else { return false }
        return w.kind == .serve || w.kind == .attack
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        touchStart = t.location(in: self)
        touchStartTime = sim.now
        swiped = false
        aiming = aimKindNow
        aimTarget = aiming ? floorHit(touchStart) : nil
        sim.input(.press(sim.now))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if aiming { aimTarget = floorHit(t.location(in: self)) ?? aimTarget; return }
        guard !swiped else { return }
        let p = t.location(in: self)
        let dx = p.x - touchStart.x, dy = p.y - touchStart.y
        let dist = sqrt(dx * dx + dy * dy)
        if dist > 28 {
            swiped = true
            let elapsed = max(0.016, sim.now - touchStartTime)
            let speed = Double(dist) / elapsed            // points per second
            let power = Float(min(1, max(0, (speed - 250) / 1100)))
            if let d = groundDir(touchStart, p) {
                sim.input(.swipe(sim.now, dir: d, power: power))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if aiming {
            aiming = false
            let held = sim.now - touchStartTime
            if let a = aimTarget, !(held < 0.2 && sim.window?.kind == .serve) {
                sim.input(.aim(sim.now, target: a))
            } else {
                sim.input(.tap(touchStartTime))   // quick tap on the serve: a safe float
            }
            aimTarget = nil
        } else if !swiped && sim.now - touchStartTime < 0.3 { sim.input(.tap(touchStartTime)) }
        if sim.matchOver { sim.rematch(); hud.score = sim.score }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        aiming = false; aimTarget = nil
    }

    // MARK: Controller

    var lastA = false, lastX = false
    func setupController() {
        GCController.startWirelessControllerDiscovery {}
    }

    func pollController() {
        guard let pad = GCController.current?.extendedGamepad else { return }
        let a = pad.buttonA.isPressed
        let x = pad.buttonX.isPressed
        let stick = V2(pad.leftThumbstick.xAxis.value, -pad.leftThumbstick.yAxis.value)
        if a && !lastA {
            sim.input(.press(sim.now))
            if simd_length(stick) > 0.35 {
                sim.input(.swipe(sim.now, dir: simd_normalize(stick), power: min(1, simd_length(stick))))
            } else if sim.window?.kind == .set || sim.window?.kind == .attack || sim.window?.kind == .serve {
                sim.input(.swipe(sim.now, dir: V2(1, 0), power: 0.8))
            }
            if sim.matchOver { sim.rematch() }
        }
        if x && !lastX {
            sim.input(.press(sim.now))
            sim.input(.tap(sim.now))
        }
        lastA = a; lastX = x
    }
}
