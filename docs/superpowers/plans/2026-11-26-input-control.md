# Input and Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let humans play SpikeCore. That means tick-stamped inputs, timed touches with the spike's timing grades, touch ownership, huddle picks of a player or "ball", play calls, switching mid-rally, the defensive read, and on fire. All of it lives inside the deterministic state, so a recorded input stream replays the same match.

**Architecture:**
- Each human is a `HumanSlot` in `GameState`. Inputs are values keyed by tick, with a sub-tick time offset for timing precision.
- When a flight toward a contact starts, SpikeCore assigns that contact an owner: a human or nil. An owned contact is resolved from that human's input through `TimingJudge` and `HumanTouch`, never through the AI or the catch-up.
- A new `.huddle` phase between rallies takes picks and calls.
- On-fire streaks live on athletes and feed the touch model.

**Tech Stack:** Swift 6, Swift Testing, SpikeCore (plans 1–3).

**Spec:** `docs/superpowers/specs/2026-11-26-spike-jam-design.md`, §4.1 (control: picks, the switch, the "ball" pick, two humans, ownership), §4.2 (touch gestures and timing grades), §4.3 (the huddle, the defensive read), §4.4 (on fire) and §5.3 (each touch has at most one owner, decided at flight start).

**Depends on:** plans 1–3 merged. It uses `GameState`, `step`, `PlayerInput` (empty until now), `Phase`, `PendingContact`, `TouchKind`, `Rally`, `TouchModel`, `TouchContext`, `TouchSource`, `SetterAI`, `TeamCalls`, `PlayCall`, `Combo`, `DefenseAI`, `CatchUp`, `MatchStats` and `runMatches`.

## Global Constraints

Everything in plans 1–3, plus:
- Timing grades are exact, from the spike: PERFECT ≤ 60 ms, GOOD ≤ 130 ms, EARLY/LATE ≤ 250 ms, WAY EARLY/WAY LATE beyond that, and no input is a MISS. The qualities are 1.0, 0.75, 0.45, 0.2 and 0.2, and a MISS always errs.
- The grace window, from the spike: an input up to 100 ms after the contact moment still plays the touch.
- Quality mixes from the spike: set = 0.5 × incoming + 0.5 × timing, attack = 0.4 × incoming + 0.6 × timing, and pass = timing (capped by the incoming power).
- The athlete's own traits shift a human's touch by at most ±0.08 (Claude's call). Their timing decides, and the catch-up never applies.
- A serve tap shorter than 0.2 s is a safe float serve. An aim within 2.4 m of the net is a tip (spec §4.2, from the spike).
- The huddle lasts `Tuning.huddleSeconds = 4.0` (spec: about 3–5) and never pauses the game. The previous picks and calls are the defaults.
- A pick follows the person: picking a middle who is replaced by the libero controls the libero for those rotations (spec §4.1).
- A switch lasts until the next huddle, which restores the huddle pick (spec §4.1).
- Two humans can't pick the same athlete. A "ball" human plays every touch on the side not owned by the other human. Two "ball" humans alternate touches (spec §4.1).
- Either human can make the defensive read, and the last one wins (spec §4.1).
- On fire (spec §4.4): a hitter with 3 kills in a row, or a libero with 3 perfect passes or digs. It ends when the other team scores. Hitters hit faster and harder and are harder to stuff. Liberos cover more ground and pass perfectly. Bots can catch fire.

## Review Focus

1. **An input arriving for the wrong contact,** for example a late pass tap landing after the set's window opened. It must count only for the contact it was meant for (keyed by `contactID`), never for the next one. Tested in Task 2.
2. **Picking the middle, then the libero subs in, then the middle rotates back to the front row.** Control goes middle → libero → middle with no huddle needed, and the arrow never points at a bench player. Tested in Task 3.
3. **A switch to a player whose touch is already in flight.** Ownership of that touch doesn't change, and the switch applies from the next touch. Tested in Task 3.
4. **Two "ball" humans and a block followed by a dig.** They alternate: block to A, dig to B. Neither human owns two touches in a row. Tested in Task 3.
5. **A recorded match.** Replaying the same settings and the same input stream gives an identical final state and event stream, including picks, switches and reads. Tested in Task 5.

---

### Task 1: Inputs, humans and contact IDs

**Files:**
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/GameState.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Input/PlayerInput.swift`, which replaces plan 1's empty struct
- Create: `Packages/SpikeCore/Sources/SpikeCore/Input/Humans.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/InputModelTests.swift`

**Interfaces:**
- Produces:
  - `public struct HumanID: Codable, Hashable, Sendable { public let raw: UInt8 }`.
  - `public enum Pick: Codable, Equatable, Sendable { case ball, athlete(AthleteID) }`.
  - `public struct HumanSlot: Codable, Equatable, Sendable { id: HumanID; team: TeamSide; pick: Pick; switched: Pick?; ready: Bool }`, where `switched` is the mid-rally override.
  - `public struct ContactID: Codable, Hashable, Sendable { public let raw: UInt32 }`, increasing per contact. `PendingContact` gains `id: ContactID` and `owner: HumanID?`.
  - `public enum InputAction: Codable, Equatable, Sendable`, with the cases:
    - `press(contact: ContactID)`, `release(contact: ContactID, aim: Vec2?)` and `tap(contact: ContactID)`;
    - `setTo(contact: ContactID, hitter: AthleteID)`, which a swipe resolves to on the device;
    - `block(contact: ContactID)`;
    - `read(hitter: AthleteID)`;
    - `pick(Pick)`, `call(AthleteID, PlayCall)`, `combo(Combo)` and `switchTo(Pick)`;
    - `teamSettings(TeamSettings)`, accepted only during the huddle before the first serve.
  - `public struct PlayerInput: Codable, Equatable, Sendable { human: HumanID; tick: Int; offset: Float; action: InputAction }`, where `offset` is seconds into the tick, 0..<dt.
  - `GameState` gains `humans: [HumanSlot]`, `nextContactID` and `fire: [AthleteID: FireState]` (Task 4). `init(settings:humans:)` defaults to no humans, which keeps plans 1–3's all-bot matches working.
  - `func controlled(by h: HumanID, _ s: GameState) -> AthleteID?` resolves the current pick, the switch and the libero substitution.

- [ ] **Step 1: Write the failing tests:**
  - `contactIDsIncrease`: across a match, every new `PendingContact` has a larger `id`.
  - `noHumansUnchanged`: plan 1's determinism and soak tests still pass with `humans: []`.
  - `controlledFollowsPick`: a human picking OH1 controls OH1. A human with `switched = .athlete(MB2)` controls MB2.
  - `inputsRoundTrip`: every `InputAction` case round-trips through Codable.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): human slots, tick-stamped inputs, contact IDs"`.

### Task 2: The timing judge and human touches

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Input/TimingJudge.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Input/HumanTouch.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/Rally.swift`, which routes owned contacts to `HumanTouch` and removes plan 3's `TouchSource` stand-in except as a test helper
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/Step.swift`, which buffers inputs by `ContactID` and applies huddle and read actions
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/TimingTests.swift`

**Interfaces:**
- Produces:
  - `public enum Grade: String, Codable, Sendable { case perfect, good, early, late, wayEarly, wayLate, miss }`, with `quality: Float`.
  - `public enum TimingJudge { static func grade(inputTime: Double?, contactTime: Double) -> Grade }`. Times are in seconds: `tick * dt + offset`.
  - `public enum HumanTouch { static func resolve(_ c: PendingContact, inputs: [PlayerInput], _ s: inout GameState) -> TouchResult }`. It applies the spec's gesture rules per kind:
    - serve: release timing against the toss apex, the aim spot, a float for a quick tap;
    - pass and dig: the tap time;
    - set: the `setTo` hitter and its timing;
    - attack: release timing, the aim, and a tip near the net;
    - block: the jump starts at the input, judged on peak against the attack contact.
  - New `GameEvent` cases: `window(ContactID, TouchKind, owner: HumanID, contactTick: Int)`, emitted when the owned flight starts, and `judged(ContactID, Grade)`.
  - The grace window: an owned contact resolves at `contactTick + 6` (100 ms) when no input has arrived yet. Within that, the first qualifying input resolves it immediately.

- [ ] **Step 1: Write the failing tests:**
  - `gradeBoundaries`: offsets 0, ±60, ±61, ±130, ±131, ±250 and ±251 ms give perfect, perfect, good, good, early or late, early or late, and way, with the sign deciding early or late. `nil` gives miss.
  - `missErrs`: an owned pass with no input is an error (`shank`), and the point goes to the other team.
  - `inputKeyedByContact` (Review Focus 1): a pass `tap` for contact 7 that arrives after contact 8's window opened changes nothing about contact 8.
  - `tipNearNet`: an attack release aimed at |x| < 2.4 in the opponent's court results in `tip == true`.
  - `floatOnQuickTap`: a serve press and release within 0.2 s is a float: lower power, minimum quality 0.45.
  - `catchUpIgnoresHumans`: an owned contact's `TouchResult` is identical at catch-up levels −1 and +1.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): timing judge and human touches"`.

### Task 3: Ownership, the huddle, switching and the defensive read

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Input/Ownership.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Input/Huddle.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/GameState.swift`, which adds `Phase.huddle(untilTick: Int)` between `.deadBall` and `.preServe`, and `lastToucherHuman: [TeamSide: HumanID]`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/AI/DefenseAI.swift`, so that a human read overrides the AI read for that side and rally
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Motion/Choreographer.swift`, which treats `.huddle` like `.deadBall`: players jog to the next formation during it
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/OwnershipTests.swift`

**Interfaces:**
- Produces:
  - `public enum Ownership { static func owner(for athlete: AthleteID, kind: TouchKind, _ s: GameState) -> HumanID? }`. It is called once, when the flight toward the contact starts, and stored on `PendingContact`. The rules, in order:
    1. A human whose `controlled` athlete is the toucher.
    2. Else, the side's "ball" human who isn't controlling another athlete. With two "ball" humans, the one who isn't `lastToucherHuman` for that side.
    3. Else, nil (AI).
  - `public enum Huddle`, with `static func begin(_ s: inout GameState)`, which clears `switched` and sets `ready = false`, and `static func apply(_ a: InputAction, from h: HumanID, _ s: inout GameState) -> Bool`. A pick of an athlete already picked by the side's other human is rejected. Calls and combos update `TeamCalls`, and the last change wins. The huddle ends at `untilTick`. Readiness doesn't shorten it in this plan; plan 6 may.
  - The AI side's calls are made by the AI in the huddle (`TeamCalls.defaults` plus variety from `SetterAI`'s repetition memory).
  - `read(hitter:)` from either human on a side sets that side's read for the current rally, and the last one wins.

- [ ] **Step 1: Write the failing tests:**
  - `pickFollowsPersonThroughLibero` (Review Focus 2): pick MB2 in a 5-1. Step through rotations, and on every tick `controlled` is MB2 while MB2 is on court, and the libero while the libero replaces MB2. It's never an athlete off court.
  - `switchDoesNotStealInFlight` (Review Focus 3): during an owned set flight to OH1 (owner H1), H1 switches to MB1. The attack's owner stays as decided at flight start, and the next touch uses the switch.
  - `switchRevertsAtHuddle`: after the rally, `controlled` is the huddle pick again.
  - `ballHumansAlternate` (Review Focus 4): with two "ball" humans on home, across 100 rallies no human owns two consecutive home touches, including block then dig.
  - `noDuplicatePicks`: H2 picking H1's athlete is rejected, and H2's pick is unchanged.
  - `huddleNeverPauses`: the huddle lasts exactly `huddleSeconds × 60` ticks whatever the inputs.
  - `readShiftsDefense`: a human read for MB on the other team moves the home blockers' goals toward that hitter's set point by at least 0.5 m, compared with no read.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): touch ownership, huddle picks and calls, switching, defensive read"`.

### Task 4: On fire

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Rules/OnFire.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/AI/TouchModel.swift` and `Input/HumanTouch.swift`, which apply the fire effects
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/OnFireTests.swift`

**Interfaces:**
- Produces:
  - `public struct FireState: Codable, Equatable, Sendable { killStreak: Int; perfectStreak: Int; onFire: Bool }`.
  - `public enum OnFire { static func record(_ e: GameEvent, _ s: inout GameState, _ events: inout [GameEvent]) }`, which emits `fire(AthleteID, on: Bool)`.

The effects (from the spike; the builder tunes them):
- An on-fire hitter's attack flight is 25% faster, has +0.2 power, and is stuffed at half the usual chance.
- An on-fire libero's pass quality is at least 0.9, and its steering cap is ×1.15.

- [ ] **Step 1: Write the failing tests:**
  - `threeKillsIgnites`: three kills by OH1 in a row emit `fire(OH1, on: true)`. A kill by someone else in between resets OH1's streak.
  - `liberoPerfects`: three passes or digs by the libero at quality ≥ 0.99 ignite the libero.
  - `opponentPointEndsFire`: any point by the other team emits `fire(_, on: false)` for every on-fire athlete on the side that lost the point.
  - `botsCatchFire`: in 200 all-bot matches, at least one bot ignites.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): on fire for hitters and liberos"`.

### Task 5: A simulated human through real inputs, and replay

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Input/SimHuman.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/MatchStats.swift` and `Sources/spikesim/main.swift`, which add `--humans home|both` and `--skill 0...1`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/ReplayTests.swift`

**Interfaces:**
- Produces: `public struct SimHuman { var id: HumanID; var skill: Float; func inputs(for s: GameState, rng: inout SeededRNG) -> [PlayerInput] }`. It watches `window` events and emits the right action for the contact kind. The timing error is drawn from a normal-ish spread whose width falls with `skill`: about 160 ms at 0 and 35 ms at 1. It aims at random legal spots and picks "ball" in the huddle. It uses its own RNG, not the game's.

- [ ] **Step 1: Write the failing tests:**
  - `replayIdentical` (Review Focus 5): run a match with a `SimHuman` on home and record every `PlayerInput`. Replay a fresh state with the same settings and the recorded stream. The final `GameState` and the event streams are equal.
  - `skillMatters`: through real inputs, a skill-0.9 SimHuman's PERFECT rate exceeds a skill-0.3 one's by at least 25 points, and wins more matches against `.medium` AI.
  - `catchUpThroughInputs`: plan 3's `closesTheGap` and `neverFlips` both hold with a SimHuman instead of the stand-in.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it,** and delete plan 3's `TouchSource` stand-in if nothing else uses it.

- [ ] **Step 4: Run everything.** Run `swift test`, `scripts/test-linux.sh`, and `swift run spikesim --matches 300 --humans home --skill 0.7`. Expected: PASS, and spikesim prints a grade distribution and the catch-up margins.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): simulated human through real inputs, replay test"`.
