# The App, Playable on iPhone, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the throwaway spike with the real Spike Jam app: a solo match against the AI on JD's iPhone, driven entirely by SpikeCore. It includes the huddle (pick your player and call plays), switching, timed touches with the playtested gestures, a readable HUD, a moving camera, haptics, and a cel-shaded placeholder look with jersey numbers, skin tones and heights.

**Architecture:**
- The app owns no game rules. A `GameLoop` on `CADisplayLink` steps SpikeCore at a fixed 60 Hz with an accumulator and keeps the previous and current `GameState` for interpolated drawing at 120 Hz.
- `CourtScene` (RealityKit `ARView` in `.nonAR` mode, as the spike proved) draws state.
- `TouchTranslator` turns touches into SpikeCore `InputAction`s for the current window.
- A SwiftUI overlay draws the HUD, huddle and switch strip from a `HUDModel` derived from state and events.
- `ClientLoop` is a protocol, so plan 6 can swap the local loop for a networked one without touching the UI.

**Tech Stack:** Swift 6, SwiftUI, RealityKit (`ARView` nonAR, `CustomMaterial` toon shading), UIKit touches, Core Haptics/`UIFeedbackGenerator`, GameController (basic), XcodeGen, SpikeCore as a local package.

**Spec:** `docs/superpowers/specs/2026-11-26-spike-jam-design.md`, §4.1 (control, switch strip, readability), §4.2 (gestures), §4.3 (huddle), §4.4 (presentation, readability, players, haptics), §4.6 (solo), §4.7 (game type pick), §4.8 (play labels and huddle diagram, basic version) and §4.9 (difficulty).

**Depends on:** plans 1–4 merged, and the TestFlight pipeline PR merged, which sets the bundle ID to `com.conleychaos.spikejam`, the app icon, `ExportOptions.plist` and CI.

## Global Constraints

Everything in plans 1–4, plus:
- The app never changes game state directly. It feeds inputs to the client loop and draws what the client loop says (spec §5.1).
- Readability (spec §4.4):
  - a white arrow over the player you control;
  - white role tags with numbers (#7 OH) over every player;
  - a white timing ring that turns green (7 pt) at perfect;
  - a white aim reticle with a line from the hitter;
  - faint landing markers (alpha 0.35, only for your receive and dig);
  - set labels showing play names;
  - team colors only on jerseys;
  - no two signals share a color.
- The playtested gestures (spec §4.2):
  - serve: hold to toss, drag onto their court to aim, let go;
  - pass and dig: tap;
  - set: swipe toward a hitter, or tap their label;
  - spike: touch their court, drag, let go;
  - block: tap;
  - read: swipe or tap toward a hitter.
- The prompts the playtests settled:
  - "HOLD TO TOSS • DRAG TO AIM • LET GO TO SERVE";
  - "LET GO WHEN THE RING CLOSES • NEAR THE NET = TIP";
  - "TOUCH THEIR COURT WHERE YOU WANT IT".
- The camera keeps the other team's court visible during aimed touches (spec §4.4).
- Landscape only, status bar hidden, ProMotion on (`CADisableMinimumFrameDurationOnPhone`). These come from the spike's `project.yml`.
- Placeholder art is original, cel-shaded and low-poly: flat color bands with ink outlines. It must read at phone size with 12 players. The final American-anime art direction comes in plan 8. Keep the materials swappable.
- Copy is original. No NBA Jam or other franchise lines (spec §2 anti-goals).

## Review Focus

1. **A finger already down when a new window opens,** for example still holding from an aim when the next pass comes. The new window needs a fresh touch, and the old touch never fires the new contact. Tested in Task 3.
2. **Taps on the switch strip or huddle chips during a live window.** They never count as timing taps. Tested in Task 3.
3. **A frame hitch,** such as a 100 ms stall. The accumulator catches up, capped at 8 steps per frame, without a spiral or skipped inputs. Inputs keep their real touch timestamps. Tested in Task 1.
4. **The app backgrounded mid-rally.** The solo match pauses (solo only), and resumes without a burst of steps. Tested in Task 1.
5. **A small phone** (iPhone SE size, 667×375 pt). The HUD, switch strip and huddle chips don't overlap the court area you aim on. Checked in Task 6's screenshots.

---

### Task 1: The app target, the game loop and the client loop

**Files:**
- Modify: `project.yml`, which replaces the `SpikeJam` target's sources with `App/` and adds the local package `Packages/SpikeCore`
- Delete: `SpikeJam/App.swift`, `SpikeJam/Court.swift` and `SpikeJam/Sim.swift` (the spike). Keep `SpikeJam/Info.plist` and the assets the pipeline PR added, moved into `App/`
- Create: `App/SpikeJamApp.swift`, `App/Loop/GameLoop.swift` and `App/Loop/ClientLoop.swift`
- Create: `AppTests/GameLoopTests.swift`, a new unit-test target in `project.yml`

**Interfaces:**
- Produces:
  - `protocol ClientLoop: AnyObject { var previous: GameState { get }; var current: GameState { get }; var alpha: Double { get }; func send(_ a: InputAction, at time: Double); func advance(to now: Double) -> [GameEvent] }`.
  - `final class LocalClientLoop: ClientLoop`, which steps SpikeCore directly with an accumulator, at most 8 steps per `advance`. `send` stamps the input with its tick and offset from `time`, the touch's own timestamp.
  - `final class GameLoop` owns a `CADisplayLink` at the preferred maximum rate. Each frame it calls `advance(to: CACurrentMediaTime())`, then the scene and the HUD. It has `pause()` and `resume()`, and resuming resets the accumulator's base time.

- [ ] **Step 1: Write the failing tests:**
  - `fixedStepping`: advancing 1.0 s in uneven chunks (7, 13 and 33 ms…) gives exactly 60 steps.
  - `hitchCapped` (Review Focus 3): one 500 ms jump steps at most 8 times, and the leftover time is dropped, not queued.
  - `resumeNoBurst` (Review Focus 4): after `pause()`, 10 s of wall time, then `resume()`, the next `advance` steps at most 1 time.
  - `inputStamping`: an input sent at `time = tickTime(120) + 0.005` gets `tick 120, offset 0.005`.

- [ ] **Step 2: Run them to see them fail.** Run `xcodegen && xcodebuild test -scheme SpikeJam -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Expected: FAIL.

- [ ] **Step 3: Implement it.** `SpikeJamApp` shows a placeholder view for now.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(app): app target on SpikeCore with fixed-step game loop"`.

### Task 2: The court scene and the cel-shaded players

> **Update (2026-11-26):** the toon material, palette, jersey textures, player rig and court model were built early as the `Packages/SpikeArt` package, which doesn't depend on SpikeCore. In this task, add SpikeArt to `project.yml`, and have `CourtScene` and the player mapping use its API instead of creating `ToonMaterials.swift`, `JerseyTextures.swift`, `Palette.swift` and `PlayerRig.swift` in `App/Scene/`. The tests that move with them are already in SpikeArt. What's left here is mapping `GameState` to SpikeArt rigs and poses.

**Files:**
- Create: `App/Scene/CourtScene.swift`, for the court, net, antennas, lines, arena, lights and ball
- Create: `App/Scene/PlayerRig.swift`, a low-poly figure built from meshes: torso, head, arms and legs, with simple procedural poses for stand, run, shuffle, approach, jump, dive, pass platform and set hands
- Create: `App/Scene/ToonMaterials.swift`, a `CustomMaterial` with a 3-band toon ramp plus an inverted-hull outline, falling back to `UnlitMaterial` banding if `CustomMaterial` fails on a device
- Create: `App/Scene/JerseyTextures.swift`, which draws team-colored jerseys with front, back and shorts numbers through Core Graphics
- Create: `App/Scene/Palette.swift`, with 10 skin-tone stops, team colors (home red, away teal, from the spike's score chips) and libero contrast colors
- Test: `AppTests/SceneMappingTests.swift`

**Interfaces:**
- Consumes: `GameState.motion`, `rosters`, `ball` and `fire`.
- Produces: `final class CourtScene { init(arView: ARView); func update(prev: GameState, cur: GameState, alpha: Double) }`.
  - It maps positions by interpolating `prev` and `cur`. Rig height scales by `heightM / 1.9`.
  - Jersey textures are cached per athlete.
  - The skin color is `Palette.skin[athlete.skinTone]`.
  - On-fire athletes get a flame particle emitter and the ball a trail when the attacker is on fire.

- [ ] **Step 1: Write the failing tests:**
  - `heightScaling`: a 2.05 m athlete's rig scale is 2.05 / 1.9 within 1e-4.
  - `jerseyNumberTexture`: the texture for #7 differs from #17's, and both are 512×512.
  - `skinPaletteDistinct`: the 10 skin stops are distinct and ordered by lightness.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.** A `-demo autoplay` launch argument runs an all-bot match, so the scene can be seen without input.

- [ ] **Step 4: Run the tests, then look.** Run them and expect PASS. Then launch in the simulator with `-demo autoplay`. Take a screenshot and check that 12 distinct players are visible, with readable numbers and outlines, and that a rally plays.

- [ ] **Step 5: Commit** with `git commit -m "feat(app): cel-shaded court and players with numbers, skin tones and heights"`.

### Task 3: Touch input

**Files:**
- Create: `App/Input/TouchTranslator.swift`
- Create: `App/Input/FloorPicker.swift`, a ray from a screen point to the y = 0 plane, ported from the spike's `floorHit`
- Create: `App/Input/SetCompass.swift`, which maps a swipe direction to the hitter whose screen-projected position at set time is closest in angle
- Create: `App/Input/ControllerInput.swift`, for a GameController: A to tap or press, the left stick to aim and swipe, the shoulder buttons to cycle the switch, Y to jump to the ball
- Modify: `App/Loop/GameLoop.swift`, to forward touches
- Test: `AppTests/TouchTranslatorTests.swift`

**Interfaces:**
- Consumes: `GameEvent.window`, `ClientLoop.send` and `controlled(by:)`.
- Produces:
  - `final class TouchTranslator`, with `func began(_ p: CGPoint, t: Double)`, `moved`, `ended` and `cancelled`. Each sends the `InputAction` for the open owned window's `ContactID`, by kind:
    - serve: `press` on down, `release` with aim on up, and a tap under 0.2 s is a float;
    - pass, dig and block: `tap`;
    - set: `setTo` from the compass;
    - attack: `release` with aim;
    - read: `read` from the compass while the other team passes and sets.
  - `var excludedRects: [CGRect]` covers the switch strip and huddle chips. Touches starting inside them are never translated.

- [ ] **Step 1: Write the failing tests:**
  - `staleFingerIgnored` (Review Focus 1): a touch that began before window B opened, and ends after it, sends nothing for B.
  - `excludedRectsIgnored` (Review Focus 2): a tap inside the strip's rect during a pass window sends nothing.
  - `serveFloat`: down and up 0.15 s apart give `press` and `release` with `aim: nil` (a float).
  - `compassPicksHitter`: with hitters projected left, center and right of the setter, a swipe at 170° picks the left one.
  - `aimRayHitsFloor`: the center of the screen with a known camera hits the expected floor point within 1 cm.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(app): touch and controller input to SpikeCore actions"`.

### Task 4: The HUD, the switch strip and a basic huddle

**Files:**
- Create: `App/HUD/HUDModel.swift`, `@Observable`, derived each frame from state and events
- Create: `App/HUD/HUDView.swift`, for the score, prompts, timing ring, reticle and aim line, set labels with play names, arrow, role tags with numbers, flashes and banners (KILL, ROOF, ACE, ON FIRE)
- Create: `App/HUD/SwitchStrip.swift`, the six teammates as "#7 OH" chips along the bottom plus a "BALL" chip, with the current one lit
- Create: `App/HUD/HuddleView.swift`, the basic version:
  - a top-down mini court of your side in the current rotation, with chips at the formation spots;
  - tap a chip, or "BALL", to pick;
  - each attacker's call chip shows `PlayCall.display`, and a tap cycles that hitter's calls;
  - a long press shows `meaning`;
  - a countdown bar.
  The full diagram with routes and tempo arcs is plan 7.
- Test: `AppTests/HUDModelTests.swift`

**Interfaces:**
- Consumes: `GameState`, `GameEvent`, `PlayBook` and `liveCalls`.
- Produces: the `HUDModel` fields `prompt`, `ring: RingState?`, `reticle`, `setLabels: [SetLabel]`, `arrowAthlete`, `tags: [Tag]`, `strip: [StripChip]`, `huddle: HuddleModel?`, `score`, `banner` and `flashes`.

- [ ] **Step 1: Write the failing tests:**
  - `ringTurnsGreen`: the ring is `perfect == true` only inside ±60 ms of the owned contact time.
  - `setLabelsUsePlayNames`: when your setter's window is open, the labels read the live calls' `display`, with non-live calls greyed.
  - `stripMatchesRotation`: the strip lists the six on-court athletes with the libero substituted, and it lights the `controlled` one.
  - `huddleCyclesCalls`: tapping the OH's call chip three times cycles 4 → GO → HUT → 32 and sends `call` actions.
  - `promptsExact`: the serve prompt string is exactly "HOLD TO TOSS • DRAG TO AIM • LET GO TO SERVE".

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(app): HUD, switch strip and basic huddle"`.

### Task 5: Camera, haptics, sound placeholders and the start screen

**Files:**
- Create: `App/Scene/CameraDirector.swift`, with a serve cam behind the server, a wide sideline shot, an attack swoop, and slow motion on kill finishes (visual only: the loop keeps stepping at full rate while the camera and presentation use eased time for about 0.6 s; SpikeCore is never slowed)
- Create: `App/Feel/Haptics.swift`, a haptic per touch scaled by power and grade, plus a heavy one for kills and stuffs
- Create: `App/Feel/Sounds.swift`, placeholder ball, net and crowd cues synthesized with AVAudioEngine tones until plan 8
- Create: `App/Screens/StartScreen.swift`, with Play solo; Men's or Women's; Fast, Faster or Stupid Fast; Easy, Medium or Hard; and "Team" holding 5-1 or 6-2 and the starting rotation
- Test: `AppTests/CameraDirectorTests.swift`

**Interfaces:**
- Produces: `CameraDirector.shot(for: GameState, events: [GameEvent]) -> CameraShot`, and `CameraShot { position: SIMD3<Float>; target: SIMD3<Float>; fov: Float }`. `simd` is fine in the app.

- [ ] **Step 1: Write the failing tests:**
  - `aimKeepsOpponentCourtVisible`: during an owned serve or attack window, every corner of the opponent court projects inside the viewport.
  - `serveCamBehindServer`: during `.preServe`, the camera's x is behind the server's x from the serving team's side.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(app): camera director, haptics, placeholder sound, start screen"`.

### Task 6: On-device check and TestFlight

**Files:**
- Create: `scripts/device.sh`, which builds and installs on JD's paired iPhone with `xcodebuild` and `xcrun devicectl`, as the spike did
- Create: `docs/playtest-3-checklist.md`

- [ ] **Step 1: Simulator screenshots** on an iPhone 17 Pro and an iPhone SE (3rd generation), with `-demo autoplay` and a solo match. Check Review Focus 5: no HUD element covers the opponent court during an aimed touch.

- [ ] **Step 2: Install on JD's iPhone** with `scripts/device.sh`. If the phone is locked, ask JD to unlock it.

- [ ] **Step 3: Write `docs/playtest-3-checklist.md`.** It lists what JD should try: the huddle pick, a play call, a switch mid-rally, each touch type, the women's game, a 6-2, each difficulty, and whether the catch-up felt invisible.

- [ ] **Step 4: Open the PR.** JD merges it once CI passes and he has played it. The merge sends the build to TestFlight through the pipeline.

- [ ] **Step 5: Commit** with `git commit -m "chore(app): device script and playtest 3 checklist"`.
