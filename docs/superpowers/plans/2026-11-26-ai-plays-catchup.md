# AI, Plays and Catch-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace plan 1's placeholder odds with AI that plays like real, imperfect people. That means position-shaped player traits, real play calls by their US names, AI setter choices, blocks, digs and defensive reads, three difficulty levels, and the hidden catch-up that keeps matches against the AI close.

**Architecture:** Every AI touch is resolved by a `TouchModel` from the toucher's traits, the incoming ball, the situation and the RNG. A `PlayBook` defines each call's set point, tempo and approach. `SetterAI` and `DefenseAI` make the decisions. A `CatchUp` level, computed from the score inside the state, nudges only AI touches and decisions. Human-controlled touches come from a stand-in policy until plan 4 wires in real input, and the catch-up never touches them.

**Tech Stack:** Swift 6, Swift Testing, SpikeCore (plans 1 and 2).

**Spec:** `docs/superpowers/specs/2026-11-26-spike-jam-design.md`, §4.3 (calls, who sets, the defensive read), §4.7 (men's and women's offense and pace), §4.8 (the play catalog) and §4.9 (imperfect AI, difficulty, catch-up).

**Depends on:** plans 1 and 2 merged. It uses `Traits`, `Roster`, `Lineup`, `GameState`, `step`, `Flight`, `Motion`, `Steering.eta`, `BaseSpots`, `AttackLane`, `Choreographer`, `MatchStats` and `runMatches` as defined there.

## Global Constraints

Everything in plans 1 and 2, plus:
- Play names and meanings are exactly the spec §4.8 table: 4, Go, Hut, 32, 1, 31, Back 1, Slide, 5, Red, Dump, Pipe, Bic, D and A. The combinations are X, Tandem and Slide-Red.
- Net zones are 1–9, about a meter each, with 1 at the left antenna from the attacking team's view. Zone k's center has local `l = -4.5 + (Float(k) - 0.5)`.
- First-tempo calls (1, 31, Back 1, Hut and Bic) need a good pass, quality ≥ 0.6 (Claude's call). Below that they aren't live, and the fallback is 4, 5, Pipe or D.
- Defaults: men 4 / 1 / 5 / Pipe and women Go / Slide / Red / Pipe (spec §4.8).
- The catch-up changes only AI touches and AI decisions. Human touches are never changed at any score (spec §4.9).
- The catch-up starts at about a 2-point margin, grows with the gap, is bounded so it never flips a match by itself, and is invisible (spec §4.9).
- The catch-up is on by default when exactly one side has humans. It is off when both do, unless "Keep it close" is on, and then it adjusts only bots.
- Target rates, checked as bands by `spikesim` over 500 matches at the middle difficulty (Claude's reading of typical high-level rates; the builder tunes them):

| Stat | Men's | Women's |
|---|---|---|
| Serve error | 12–22% | 7–15% |
| Ace | 4–10% | 4–10% |
| Attack kill | 40–55% | 30–45% |
| Attack error | 8–18% | 8–18% |
| Side-out rate | 60–72% | 55–68% |

## Review Focus

1. **A bad pass on a first-tempo call.** The call isn't live, so the AI setter and the fallback both go to a high ball, never a quick off a 0.3 pass. Tested in Task 3.
2. **A 5-1 with the setter front row.** Dump appears only then, and the setter never sets themselves. Tested in Task 3.
3. **Catch-up at match point.** When the AI trails 14–8, it does not get a bigger boost than at 10–4, because the bound holds and there's no game-point bonus. When the human leads 14–13, the AI's nudge is zero. Tested in Task 5.
4. **Keep it close with humans on both sides.** It adjusts only bots on each side, and a human's touch outcome is identical with it on or off for the same inputs and seed state. Tested in Task 5.
5. **A tool off the block.** It goes out of bounds and the point goes to the attacker, not the blocker. Tested in Task 4.

---

### Task 1: Position-shaped traits, difficulty and match settings

**Files:**
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Roster/RosterGenerator.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Settings/MatchSettings.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/AI/Difficulty.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/TraitTests.swift`

**Interfaces:**
- Produces:
  - `public enum Difficulty: String, Codable, Sendable, CaseIterable { case easy, medium, hard }`, with `traitShift: Float` (−0.12, 0, +0.08) and `errorScale: Float` (1.3, 1.0, 0.8). The display names are the builder's choice, later.
  - New `MatchSettings` fields: `difficulty: Difficulty = .medium`, `humanSides: Set<TeamSide> = []` and `keepItClose = false`.
  - In `RosterGenerator`, traits are shaped by position:
    - setter: high `set`;
    - libero: high `pass` and `defense`, and `attack` and `block` set to 0;
    - middle: high `block` and `attack`, low `pass`;
    - outside: balanced, with good `pass`;
    - opposite: high `attack` and `block`.
  - Each draw is centered on the shaped mean ± 0.12. One "personality" spike is +0.15 on one random trait, with −0.1 on another.

- [ ] **Step 1: Write the failing tests:**
  - `liberoTraits`: the libero's `attack` and `block` are 0, and its `pass` is above the team's average pass.
  - `setterSets`: the setter's `set` is the highest `set` on the team.
  - `middlesBlock`: the middles' average `block` is above the outsides' average.
  - `variety`: across 50 rosters, no two athletes on a team have identical traits.
  - `settingsRoundTrip`: the new fields default as stated and round-trip through Codable.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): position-shaped traits and difficulty"`.

### Task 2: The play book

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Plays/PlayCall.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Plays/PlayBook.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/PlayBookTests.swift`

**Interfaces:**
- Produces:
  - `public enum PlayCall: String, Codable, Sendable, CaseIterable`, with the cases `four, go, hut, thirtyTwo, one, thirtyOne, backOne, slide, five, red, dump, pipe, bic, d, a`. It has `display: String` ("4", "GO", "HUT", "32", "1", "31", "BACK 1", "SLIDE", "5", "RED", "DUMP", "PIPE", "BIC", "D", "A") and `meaning: String`, the spec's one-liners such as "31: quick in the gap, zone 3".
  - `public enum Tempo2: Int, Codable, Sendable { case first = 1, second, high }`, with a name chosen to avoid clashing with plan 1's `Tempo` setting.
  - `public struct PlaySpec: Equatable, Sendable { call: PlayCall; lane: AttackLane; netZone: Float; tempo: Tempo2; setDuration: Double; apex: Float; oneFoot: Bool; needsGoodPass: Bool; behindSetter: Bool }`.
  - `public enum PlayBook`, with:
    - `static func spec(_ c: PlayCall) -> PlaySpec`;
    - `static func calls(for position: Position, frontRow: Bool, system: OffenseSystem) -> [PlayCall]`;
    - `static func defaults(_ game: GameType) -> [Position: PlayCall]`;
    - `static func setPoint(_ c: PlayCall, team: TeamSide, net: Float) -> Vec3`.
  - `public enum Combo: String, Codable, Sendable, CaseIterable { case x, tandem, slideRed }`, with `static func calls(_ combo: Combo) -> [Position: PlayCall]`. X is MB 1 and OH 32. Tandem is MB 1 and OPP a 2-height ball, using 31's spot at second tempo. Slide-Red is MB Slide and OPP Red.

The values, from the spec plus Claude's numbers:
- Set durations: first tempo 0.38–0.45 s, second tempo 0.55–0.65 s, high 0.85–0.95 s.
- Apex above the net: first tempo +0.5 m, second +1.2 m, high +2.6 m.
- Net zones: 4, Go and Hut are zone 1. 32 is zone 2.5. 1 is the zone in front of the setter (6). 31 is zone 3. Back 1 is zone 7. Slide is zone 8.5. 5 and Red are zone 9. Back-row calls: Pipe and Bic zone 5, D zone 8, A zone 2. Their takeoff is clamped behind the 3 m line by `BaseSpots.takeoff`.

- [ ] **Step 1: Write the failing tests:**
  - `catalogComplete`: every `PlayCall` has a spec, and `display` values are unique.
  - `outsideCalls`: front-row outside calls are exactly `[.four, .go, .hut, .thirtyTwo]`.
  - `backRowOnlyBackCalls`: for every position with `frontRow: false`, the calls are a subset of `[.pipe, .bic, .d, .a]`, and the libero has none.
  - `firstTempoNeedsPass`: `needsGoodPass` is true exactly for 1, 31, Back 1, Hut and Bic.
  - `tempoOrdering`: set duration and apex increase from first to high.
  - `defaults`: `defaults(.mens)` is OH 4, MB 1, OPP 5 and pipe hitter Pipe. `defaults(.womens)` is OH Go, MB Slide, OPP Red and Pipe.
  - `setPointsOnTheNet`: every front-row call's `setPoint` has |x| ≤ 1.2 and |z| ≤ 4.5, above the net height.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): play book with US play calls and combos"`.

### Task 3: Team calls, live calls and the AI setter

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Plays/TeamCalls.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/AI/SetterAI.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/GameState.swift`, which adds `calls: [TeamCalls]`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Motion/Choreographer.swift`, which takes approach lanes and takeoffs from the called play rather than `defaultLane`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/SetterAITests.swift`

**Interfaces:**
- Produces:
  - `public struct TeamCalls: Codable, Equatable, Sendable { var byAthlete: [AthleteID: PlayCall] }`, with `static func defaults(lineup:roster:game:) -> TeamCalls`. Those are the defaults for the current rotation's attackers.
  - `public func liveCalls(_ s: GameState, team: TeamSide, passQuality: Float) -> [(AthleteID, PlayCall)]`. These are the attackers who can hit in this rotation with their called play, plus Dump only when the setting setter is front row. A first-tempo call is replaced by its fallback when `passQuality < 0.6`: 4 for the outside, 5 for the right side, Pipe for back-middle and D for back-right. A middle's call is dropped off a bad pass.
  - `public enum SetterAI { static func choose(_ s: inout GameState, team: TeamSide, passQuality: Float) -> (AthleteID, PlayCall) }`. Each live option is scored from:
    - the hitter's `attack`;
    - the expected number of blockers aligned with the set point, which is fewer for faster tempo and farther away;
    - the game type's habits (§4.7);
    - a repetition penalty for the last two sets.
    It chooses by softmax over scores, using `s.rng`, at a temperature that falls with the setter's `set` trait. Setters don't always pick the best.

- [ ] **Step 1: Write the failing tests:**
  - `badPassNoQuicks` (Review Focus 1): with `passQuality` 0.3, the live calls contain no `needsGoodPass` play, and over 1,000 choices `SetterAI` never picks one.
  - `dumpOnlyFrontRow` (Review Focus 2): in a 5-1, rotations 1–3 (setter back row) have no `.dump`. In rotations 4–6, `.dump` is present, and the setter is never chosen as a hitter for anything other than `.dump`.
  - `prefersOpenHitter`: with two blockers parked at zone 1 and one at zone 9, the 5 or Red is picked more often than the 4, over 1,000 seeded choices.
  - `notAlwaysBest`: the most-picked option is under 80% of choices in a neutral spot.
  - `womensUsesSlide`: in women's games over 200 matches, the Slide is among the two most common middle sets. In men's games, the 1 is.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it,** and replace `PlaceholderRally`'s random set target with `SetterAI.choose`.

- [ ] **Step 4: Run all the tests.** Expected: PASS, including plan 2's choreography tests.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): team calls, live calls and AI setter"`.

### Task 4: The touch model: imperfect serves, passes, sets, attacks, blocks and digs

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/AI/TouchModel.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/AI/DefenseAI.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Sim/Rally.swift`, which replaces `PlaceholderRally.swift` (delete that file) and adds `TouchKind.block`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Settings/Tuning.swift`, which removes the placeholder odds and adds the touch model's coefficients
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/TouchModelTests.swift`

**Interfaces:**
- Produces:
  - `public struct TouchContext: Sendable { kind: TouchKind; toucher: Athlete; incomingQuality: Float; incomingPower: Float; reachSlack: Double; blockersAligned: Int; catchUp: Float; isHuman: Bool }`. `reachSlack` is the seconds of spare time the toucher had, which can be negative.
  - `public struct TouchResult: Equatable, Sendable { quality: Float; error: TouchError?; power: Float; target: Vec3?; tip: Bool }`.
  - `public enum TouchError: String, Codable, Sendable { case net, out, shank, overpass, doubleContact, blockedStuff, tooled }`.
  - `public enum TouchModel { static func resolve(_ c: TouchContext, rng: inout SeededRNG, settings: MatchSettings) -> TouchResult }`.
  - `public enum DefenseAI { static func read(_ s: inout GameState, defending: TeamSide) -> AthleteID? }`, which guesses the hitter. Accuracy rises with the team's average `defense` and with how readable the pass was, and the read shifts `BaseSpots.perimeter` 0.5–1.0 m toward that hitter.
  - `Rally.resolve(_ c: PendingContact, _ s: inout GameState, _ events: inout [GameEvent])` takes over from the placeholder. Humans' touches go through a `HumanStandIn` protocol until plan 4: `protocol TouchSource { func quality(for c: PendingContact, _ s: GameState, rng: inout SeededRNG) -> Float? }`, where nil means "not human, use the AI".

How touches resolve:
- Quality is drawn around `trait + difficulty.traitShift + catchUp nudge`, spread by 0.15 and clipped to 0...1.
- Error chance comes from the trait and `difficulty.errorScale`, and rises with incoming power and shrinking `reachSlack`.
- The block resolves when an attack crosses the net. Reach is `heightM * 1.33 + 0.75 × block jump`, against the attack's height at the net. The outcome is a stuff, a soft block (back to the defense for a dig), a tool (out off the block: a point to the attacker), or no touch.
- AI hitters tip 6–10% of the time, more in the women's game.
- Every error is a real type, so plan 5 can animate it.

- [ ] **Step 1: Write the failing tests:**
  - `betterTraitBetterTouch`: over 5,000 rolls, a 0.9 passer's mean quality beats a 0.5 passer's by at least 0.15, and the 0.9 passer's error rate is lower.
  - `notPerfect`: a 1.0-trait server at `.hard` still errs in at least 3% of 5,000 serves.
  - `toolGoesToAttacker` (Review Focus 5): a forced tool result ends the rally with a `point` to the attacking team, reason `.kill`.
  - `blockReachUsesHeight`: a 2.05 m middle stuffs a fixed low attack more often than a 1.80 m outside does.
  - `rateBands`: `runMatches` with 500 matches per game type at `.medium` falls inside every band in the Global Constraints table. The test prints the measured rates.
  - `difficultyOrders`: `.easy` AI against `.hard` AI loses at least 70% of 200 matches.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement the touch model, defense reads and `Rally`,** then tune `Tuning` until `rateBands` passes. Note the final rates in the commit message.

- [ ] **Step 4: Run everything.** Run `swift test` and `scripts/test-linux.sh`. Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): imperfect AI touch model, blocks, defense reads"`.

### Task 5: The catch-up

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/AI/CatchUp.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Sim/Rally.swift`, which passes the nudge into each AI `TouchContext` and the setter and defense choices
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/CatchUpTests.swift`

**Interfaces:**
- Produces:
  - `public enum CatchUp { static func level(_ s: GameState) -> [TeamSide: Float] }`. It is computed from the score each time, not stored, so prediction can't drift.
    - When exactly one side is human and `settings.catchUp` is on: with `trail = aiPoints - humanPoints`, it returns 0 when |trail| ≤ 1, otherwise `sign(trail) × min(1, (|trail| - 1) / 5)`. A positive value is "the human side trails". The AI side gets −level, so it plays worse when the human trails, and the human side's bots get +level. Humans get nothing.
    - With humans on both sides and `keepItClose`, the same formula applies to each side's bots, using that side's own deficit.
    - Otherwise it's 0.
  - Effect bounds, applied in `TouchModel` (Claude's starting numbers): at level ±1, quality ±0.07, error chance ×(1 ± 0.35), and setter temperature +0.3 for the side being held back.

- [ ] **Step 1: Write the failing tests:**
  - `zeroWhenClose`: level is 0 at 7–7, 8–7 and 7–8.
  - `boundedAtMatchPoint` (Review Focus 3): the AI's level at 14–8 (human trailing) equals its level at 10–4, both 1, and no other code path adds a bonus at game point. When the human leads 14–13, the level is 0.
  - `humansUntouched` (Review Focus 4): resolve the same human `TouchContext` with the same RNG state at levels −1, 0 and +1. The results are identical.
  - `keepItCloseBotsOnly`: with both sides human and `keepItClose` on, only bot contexts get a nudge.
  - `closesTheGap`: a simulated human (a `TouchSource` with a fixed timing quality of 0.7) against `.medium` AI over 300 matches, with the catch-up on, has a mean final margin at least 30% smaller than with it off.
  - `skillStillWins`: a 0.85 simulated human beats a 0.6 simulated human's win rate by at least 20 points against the same AI, with the catch-up on.
  - `neverFlips`: in matches where the simulated human leads by 6 or more at any point, the human wins at least 85%.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run everything,** including `swift run spikesim --matches 500`. Expected: PASS. Print the margins with the catch-up on and off.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): hidden catch-up that nudges only AI touches"`.
