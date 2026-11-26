# Court Movement and Formations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every SpikeCore player move like a real high-level team: legal serve-receive stacks in every rotation of the 5-1 and 6-2, releasing and switching at the serve, real approaches, block footwork, transition, hitter coverage and perimeter defense. All of it is driven by a steering model inside the fixed-step simulation.

**Architecture:** Each athlete on court gets a `Motion` value (position, velocity, goal, gait, jump) stored in `GameState`. A `Choreographer` sets goals every tick from the rally situation. The steering integrator moves each player toward its goal with speed and acceleration limits. Formations are hand-authored tables for each rotation and system, guarded by an overlap-rule checker. The placeholder rally engine from plan 1 now picks touchers by who can actually get to the ball.

**Tech Stack:** Swift 6, Swift Testing, SpikeCore (plan 1). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-26-spike-jam-design.md`, §4.1 (rotation, serve receive, movement, defense, readability) and §5.2 (movement is a steering model inside SpikeCore).

**Depends on:** plan 1 (`2026-11-26-spikecore-rules-foundation.md`) merged. It uses `Vec2`, `Vec3`, `TeamSide`, `AthleteID`, `Position`, `Roster`, `Zone`, `Lineup`, `GameState`, `step`, `Flight`, `Court`, `Tuning`, `PlaceholderRally`, `checkInvariants` and `MatchStats` exactly as plan 1 defines them.

## Global Constraints

Everything in plan 1's Global Constraints, plus:
- Team-local frame: depth `d` is the distance from the net into your own court (positive), and lateral `l` is left-to-right from the team's view facing the net (negative is left). For home, `d = -x` and `l = z`. Away mirrors x and z, so its `d = x` and `l = -z`.
- The overlap rule is judged at the tick of serve contact. Each front-row player must be closer to the net than their back-row partner (4 with 5, 3 with 6, 2 with 1). Within each row, the order left to right must be 4, 3, 2 and 5, 6, 1. The server is exempt. Require a margin of at least 0.1 m, so it is visibly legal.
- The AI always lines up legally, and there are no overlap faults in the game (spec §4.1).
- Three passers by default: the libero and both outsides (spec §4.1).
- Perimeter defense by default, with the libero in left back. The off blocker pulls off the net for tips (spec §4.1).
- The libero never takes a front-row approach, block or attack spot.
- Back-row attackers take off with `d >= 3.0` (behind the 3 m line).
- Players stay on their own side (`d >= 0.2`) and inside the free zone: `d <= 12`, `|l| <= 7.5`.
- Footwork may run faster than real life so the game stays FAST. Every speed comes from `Tuning`.

## Review Focus

1. **Serve contact in every rotation, both systems, serving and receiving, with the libero in.** The formation must be legal at the actual serve tick, not just in the table, because players may still be moving. Tested in Task 5's soak.
2. **A bad pass far from the setter target.** The setter's goal follows the pass's predicted contact point, not the fixed target, and the pass contact can't be "made" by a setter still 5 m away. Tested in Task 5.
3. **Goals outside the court rules:** any goal across the net or outside the free zone is clamped, never followed. Tested in Task 2.
4. **The libero in a hitter's spot.** When the libero has replaced a middle, no approach, block or coverage-at-net goal is ever given to the libero. Tested in Task 5.
5. **Back-row approaches near the 3 m line.** A pipe, D or A attacker's takeoff point must be behind it, even when the set is tight to the net. Tested in Task 4.

---

### Task 1: Team-local frames, zone lookup and the overlap checker

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Formations/LocalFrame.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Formations/Overlap.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Rules/Lineup.swift`, to add `zone(of:isServing:)`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/OverlapTests.swift`

**Interfaces:**
- Produces:
  - `public struct LocalSpot: Codable, Hashable, Sendable { var d: Float; var l: Float }`.
  - `public enum LocalFrame { static func toWorld(_ s: LocalSpot, team: TeamSide) -> Vec2; static func toLocal(_ v: Vec2, team: TeamSide) -> LocalSpot }`.
  - `extension Lineup { func zone(of id: AthleteID, isServing: Bool) -> Zone? }`, which includes the libero.
  - `public enum Overlap { static func violations(_ spots: [Zone: LocalSpot], isServing: Bool, margin: Float = 0.1) -> [String] }`. Each problem reads like `"z4 not ahead of z5"` or `"z5 not left of z6"`. When serving, comparisons involving z1 are skipped.

- [ ] **Step 1: Write the failing tests:**
  - `roundTrip`: `toLocal(toWorld(s))` equals `s` for both teams, and home `LocalSpot(d: 2, l: -3)` is world `(-2, -3)`, while away is `(2, 3)`.
  - `baseZonesLegal`: Plan 1's `Court.zoneSpot` layout, converted to local, has no violations.
  - `frontBehindBack`: zone 4 at `d` 7 with zone 5 at `d` 6 gives `"z4 not ahead of z5"`.
  - `lateralOrder`: zone 3 left of zone 4 gives a violation.
  - `serverExempt`: zone 1 placed at `l` −4 (left of 5 and 6) gives no violations when `isServing` is true, and gives them when it's false.
  - `marginEnforced`: front and back players only 0.05 m apart in depth is a violation.

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter OverlapTests`. Expected: a compile failure.

- [ ] **Step 3: Implement the three files.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): team-local frames and overlap rule checker"`.

### Task 2: The motion model and steering integrator

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Motion/Motion.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Motion/Steering.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Settings/Tuning.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/SteeringTests.swift`

**Interfaces:**
- Produces:
  - `public enum Gait: String, Codable, Sendable { case stand, run, shuffle, backpedal, approach, dive }`.
  - `public struct Jump: Codable, Equatable, Sendable { startTick: Int; durationTicks: Int; height: Float }`, with `func height(atTick: Int) -> Float`, a parabola that is 0 outside the jump.
  - `public struct Motion: Codable, Equatable, Sendable { pos: Vec2; vel: Vec2; goal: Vec2; gait: Gait; arriveByTick: Int?; jump: Jump? }`.
  - `public enum Steering { static func advance(_ m: inout Motion, team: TeamSide, speedTrait: Float, dt: Double) }`.
  - New `Tuning` values (Claude's starting numbers; the builder tunes them on device): `footworkScale: Float = 1.25`, with speed caps in m/s before scaling of run 6.0, shuffle 3.5, backpedal 3.5, approach 5.0 and dive 4.0, `accel: Float = 16` m/s², and `arriveRadius: Float = 0.08`.

How steering works:
- The cap is gait cap × `footworkScale` × (0.85 + 0.3 × `speedTrait`).
- Steer toward the goal and decelerate to stop at it.
- If `arriveByTick` is set and the remaining distance can't be covered at the cap, move at the cap anyway. Never exceed the cap.
- Clamp the goal and the position to the team's side and the free zone (`d >= 0.2`, `d <= 12`, `|l| <= 7.5`).

- [ ] **Step 1: Write the failing tests:**
  - `reachesGoal`: from (−6, 0) to (−2, 3) with `run`, it arrives within `arriveRadius` within 2 s and ends with speed below 0.1 m/s.
  - `neverExceedsCap`: on every tick, `vel.length` ≤ cap + 1e-4, across all gaits and speed traits 0 and 1.
  - `goalAcrossNetClamped` (Review Focus 3): a home goal of (+3, 0) never puts `pos.x` above −0.2.
  - `freeZoneClamped`: a goal of (−20, 10) stops at `d` 12 and `l` 7.5.
  - `jumpCurve`: `Jump(startTick: 10, durationTicks: 48, height: 0.9)` gives 0 at ticks 9 and 58, 0.9 at tick 34 within 1e-3, and is symmetric.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): player motion and steering"`.

### Task 3: Serve-receive and serving formations for every rotation

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Formations/ReceivePatterns.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Formations/ServingFormations.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/FormationTests.swift`

**Interfaces:**
- Consumes: `Lineup`, `Zone`, `LocalSpot` and `Overlap`.
- Produces:
  - `public enum Formations { static func receive(_ lineup: Lineup, roster: Roster) -> [AthleteID: LocalSpot]; static func serving(_ lineup: Lineup, roster: Roster) -> [AthleteID: LocalSpot] }`.
  - `public static func passers(_ lineup: Lineup, roster: Roster) -> [AthleteID]`, which returns the libero and the two outsides.

How the formations are built:
- They are hand-authored tables keyed by `(system, rotation)`, 12 in all for receive, and keyed by role in the rotation (the setter, the passers, the hiding hitters), not by athlete.
- The authoring rules for receive (Claude's call, modeled on high-level stacks):
  - The three passers form a line between `d` 5.5 and 7.0, spread across about −3.2, 0 and +3.2 in `l`, ordered to stay legal.
  - The setting setter hides as close to the setter target as the overlap rule allows. It's within 4.5 m of the target in every rotation.
  - Front-row non-passers stand near the net (`d` 0.8 to 2.5), on the side of their attack zone where the rule allows it, so they can release straight to their approach.
  - Back-row non-passers stand behind their row partner.
- The serving rules: the server stands at `d` 9.6 behind the end line, in their zone-1 lane. The others take the perimeter base for an attack from the opponent's left (Task 4), adjusted to be legal.

- [ ] **Step 1: Write the failing tests** (Review Focus 1, for the table part):

```swift
@Test(arguments: [OffenseSystem.fiveOne, .sixTwo], 1...6)
func receiveIsLegal(system: OffenseSystem, rotation: Int) {
    let (lineup, roster) = fixture(system, rotation)
    let spots = Formations.receive(lineup, roster: roster)
    #expect(spots.count == 6)
    let byZone = zoneMap(spots, lineup, isServing: false)
    #expect(Overlap.violations(byZone, isServing: false).isEmpty)
    let passers = Formations.passers(lineup, roster: roster)
    #expect(Set(passers.map { roster[$0].position }) == [.outside, .libero])
    for p in passers { #expect((5.5...7.0).contains(spots[p]!.d)) }
    let setter = lineup.settingSetter(isServing: false)
    #expect(distance(spots[setter]!, setterTargetLocal) <= 4.5)
}

@Test(arguments: [OffenseSystem.fiveOne, .sixTwo], 1...6)
func servingIsLegal(system: OffenseSystem, rotation: Int) {
    let (lineup, roster) = fixture(system, rotation)
    let spots = Formations.serving(lineup, roster: roster)
    #expect(Overlap.violations(zoneMap(spots, lineup, isServing: true), isServing: true).isEmpty)
    #expect(spots[lineup.server()]!.d >= 9.5)
}
```

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Author the 12 receive tables and the serving rule.** Write a short comment for each rotation naming the stack (for example "R4, 5-1: setter front-left, OPP hides behind the 2"). That keeps them reviewable against real teams.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS, 24 cases.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): legal serve-receive stacks and serving formations for 5-1 and 6-2"`.

### Task 4: Base spots: approach starts, attack takeoffs, blocking and perimeter defense

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Formations/BaseSpots.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/BaseSpotTests.swift`

**Interfaces:**
- Produces:
  - `public enum AttackLane: String, Codable, Sendable, CaseIterable { case left, middle, right, backLeft, backMiddle, backRight }`. These are zones 4, 3, 2, 5 ("A"), 6 ("Pipe" and "Bic") and 1 ("D").
  - `public enum BaseSpots`, with:
    - `static func approachStart(_ lane: AttackLane) -> LocalSpot`;
    - `static func takeoff(_ lane: AttackLane, setPoint: Vec3, team: TeamSide) -> LocalSpot`, 0.6 m behind and slightly inside the set point. For back lanes it's clamped to `d >= 3.0`;
    - `static func blockSpot(against setPoint: Vec3, defending: TeamSide) -> LocalSpot`, at `d` 0.45 with `l` aligned to the set point;
    - `static func perimeter(against lane: AttackLane) -> PerimeterSpots`.
  - `public struct PerimeterSpots: Codable, Equatable, Sendable { leftFront, middleFront, rightFront, leftBack, middleBack, rightBack: LocalSpot }`, the defender's own six roles. The libero takes `leftBack`.
  - `public static func defaultLane(for position: Position, frontRow: Bool) -> AttackLane`. OH front is `left`, MB is `middle`, and OPP or the front-row 6-2 setter is `right`. A back-row OH is `backMiddle`, and a back-row OPP is `backRight`.

- [ ] **Step 1: Write the failing tests:**
  - `backRowTakeoffBehindLine` (Review Focus 5): for each back lane, with set points from `d` 0.5 to 4.0, `takeoff(...).d >= 3.0`.
  - `frontTakeoffNearSet`: a front-lane takeoff is within 1.0 m of the set point's floor projection.
  - `perimeterShape`: against `left`, two blockers have `d <= 0.6` across from the attack, the off blocker has `d` between 2.5 and 3.5, `leftBack` is the deepest left spot, and every spot is inside the court.
  - `approachStartsBehindTakeoff`: each lane's `approachStart` is 2.5–4.0 m from its default takeoff, on the same side of the court.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement `BaseSpots`.** Use the spike's set points (plan 1's `Court.attackPoint`) for the default front-lane set points. Use `d` 3.8 at the lane center for back lanes.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): approach, takeoff, block and perimeter defense spots"`.

### Task 5: The choreographer: goals for every moment of the rally

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Motion/Choreographer.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/GameState.swift`, which replaces the stored `positions` with `motion: [AthleteID: Motion]` and keeps `positions` as a computed property, so plan 1's code keeps compiling
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/Step.swift`, which calls `Choreographer.update` and then `Steering.advance` for all twelve on-court players every tick
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Rules/Invariants.swift`, which adds the overlap check at serve contact and the libero-goal check
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/ChoreographyTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4, plus plan 1's `Phase`, `PendingContact` and `Flight`.
- Produces: `public enum Choreographer { static func update(_ s: inout GameState) }`, which sets `goal`, `gait`, `arriveByTick` and `jump` for each on-court player.

The situations and the goals to set:

| Situation | Goals |
|---|---|
| `.deadBall` and `.preServe` | Jog (`run`) to `Formations.receive` or `serving`. In `.preServe`, the serve waits until everyone is within 0.3 m of their spot, for at most 3 s. Then anyone still off their spot snaps to it, so the serve-tick formation is always legal |
| Serve contact (receiving team) | The setting setter releases to the pass's predicted contact point. Passers move into the serve's landing line. Front-row hitters release to `approachStart` for their `defaultLane` |
| Serve contact (serving team) | Switch: everyone moves to the perimeter spots for an attack from the receiving team's left lane, with the libero at left back |
| The ball is passed or dug to our setter | Hitters time their approach (`approach` gait) to reach `takeoff` at the set's contact tick, minus 0.25 s, and jump there. Back-row players go to coverage: 1.5–2.5 m around the hitter's takeoff, low |
| The other team sets | Defenders take `perimeter(against:)` for that set's lane. The blockers shuffle along the net to `blockSpot` and jump 0.3 s before the attack contact |
| Our block is done and the ball stays on our side | Transition: the front-row hitters backpedal off the net to `approachStart` |

Never give the libero an approach, takeoff, block or front-row coverage goal (Review Focus 4).

- [ ] **Step 1: Write the failing tests:**
  - `serveTickAlwaysLegal` (Review Focus 1): 200 seeded matches over both systems and all starting rotations. On each serve contact tick, take the real `motion` positions by zone for both teams and expect `Overlap.violations` to be empty.
  - `setterGetsToBadPasses` (Review Focus 2): over 200 matches, on every set, the setter's position at contact is within 0.6 m of the ball's contact point. Contacts that the placeholder engine would turn into handling errors because nobody could get there are excluded, and their count is reported.
  - `hittersTakeOffOnTime`: on each attack, the hitter's jump peak is within ±3 ticks of the attack contact tick.
  - `liberoNeverAtNet` (Review Focus 4): on every tick of 200 matches, the libero's goal has `d >= 3.0`, and the libero never has a `jump` with `height > 0.3`.
  - `deterministic`: plan 1's determinism test still passes with motion included.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure or failures.

- [ ] **Step 3: Implement the choreographer and the state and step changes.** Get each "predicted contact point" from the current `Flight`'s endpoint.

- [ ] **Step 4: Run all the tests.** Run `swift test` and `scripts/test-linux.sh`. Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): choreographer for receive, switch, approach, block, coverage, defense"`.

### Task 6: Touchers chosen by who can reach the ball, and movement stats in spikesim

**Files:**
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/PlaceholderRally.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/MatchStats.swift`
- Modify: `Packages/SpikeCore/Sources/spikesim/main.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/ReachTests.swift`

**Interfaces:**
- Produces:
  - `static func eta(_ m: Motion, to: Vec2, cap: Float) -> Double`, in `Steering`.
  - In `PlaceholderRally`, the receiver or digger is the eligible player with the smallest ETA to the landing point. If that ETA is more than 0.1 s past the contact time, the ball drops (an ace or a kill).
  - The setter must be the setting setter. If they can't get there in time, the nearest non-libero teammate sets with quality capped at 0.4. Plan 3 refines this.
  - New `MatchStats` fields: `overlapViolations`, `lateSetters` and `droppedForReach`, printed by `spikesim`.

- [ ] **Step 1: Write the failing tests:**
  - `etaMatchesSteering`: for random starts and goals, `eta` is within 0.1 s of the ticks `Steering.advance` actually takes to arrive.
  - `unreachableBallDrops`: a forced landing spot 8 m from every defender with 0.3 s left results in a point to the attacker.
  - `statsReportMovement`: 50 matches report `overlapViolations == 0`.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run everything.** Run `swift test`, `scripts/test-linux.sh`, and `swift run spikesim --matches 200 --system 62`. Expected: all PASS, and spikesim shows `overlapViolations: 0` and `invariantFailures: 0`.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): reach-based touchers and movement stats"`.
