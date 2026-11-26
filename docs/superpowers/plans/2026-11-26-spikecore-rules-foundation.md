# SpikeCore Rules Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless SpikeCore Swift package: real volleyball rules (rosters, six-rotation lineups for the 5-1 and 6-2, the libero, rally scoring), analytic ball flights, and a fixed 60-step simulation that plays complete bot-vs-bot matches. It is tested on macOS and Linux.

**Architecture:** SpikeCore is a pure Swift package with no rendering, timing or I/O. The whole match is one `GameState` value type, advanced by a pure `step(_:inputs:)` function at 60 steps per second, with all randomness drawn from a seeded generator stored in the state. In this plan, a placeholder rally engine with fixed odds plays every touch. Later plans replace it with real movement, AI traits and human input, on the same state and step function.

**Tech Stack:** Swift 6 (language mode 6), Swift Package Manager, Swift Testing (`import Testing`), Docker's official `swift` image for Linux tests. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-26-spike-jam-design.md`. This plan covers §5.1 (SpikeCore), §5.2 (simulation), §4.1 (rotation, the libero, the 5-1 and 6-2, match format, tempo), §4.4 (rosters: numbers, skin tones, heights) and §4.7 (net heights, pace). It covers them at the level of the rules, not movement or AI.

## Where this plan fits

The spec is too big for one plan. Milestone 1 (§6) is split into plans that each end in working, tested software. They run in this order:

1. **SpikeCore rules foundation** (this plan): state, rules, rotation, scoring, flights and the headless match runner.
2. **Court movement and formations:** serve-receive stacks for every rotation (legal for the overlap rule), switching, approaches, block footwork, transition, coverage, perimeter defense, and the steering model.
3. **AI and plays:** player traits, imperfect touches and decisions, the play catalog (§4.8), AI setter choices, blocks and digs, difficulty, and the catch-up (§4.9).
4. **Input and control in SpikeCore:** timed touches, timing grades, touch ownership, huddle picks, switching, the "ball" pick, the defensive read, and on fire.
5. **The app, playable on JD's iPhone:** RealityKit rendering of SpikeCore, gestures, the HUD and the camera. This replaces the throwaway spike.
6. **Huddle and presentation:** the huddle UI with rotation and play diagrams, the switch strip, celebrations and team settings.
7. **Tutorial.**
8. **Art and audio pass.**
9. **SpikeNet loopback:** the client and server loops in one process.

Milestones 2–4 get their own plans after that.

## Global Constraints

- SpikeCore builds for iOS 26, tvOS 26, macOS 26 and Linux. It imports no `simd`, no `UIKit`/`AppKit`/`RealityKit`, and no other Apple-only framework (spec §5.1). This plan needs no `Foundation` in the library either.
- Fixed 60 steps per second: `dt = 1.0 / 60.0` (spec §5.2).
- The whole game state is one `Codable, Equatable, Sendable` value type. All randomness comes from the seeded generator stored in it (spec §5.2).
- Bit-for-bit determinism across devices is not required. The same seed and settings on the same build must give the same match (spec §5.2, and the basis for replay later).
- Court: 18 m × 9 m, net at x = 0. Home stands at negative x and attacks toward +x. From a team's own view facing the net, left is −z for home. Away mirrors both x and z. These are the spike's coordinates.
- Net height 2.43 m for the men's game and 2.24 m for the women's (spec §4.7).
- Match format: one set to 15, rally scoring, win by 2 (spec §4.1).
- Tempo flight scales, from the spike: Fast 1.2, Faster 1.0 (the default), Stupid Fast 0.82 (spec §4.1).
- Arcade gravity, from the spike: `-9.8 * 1.7` m/s².
- The libero never serves, attacks above the net, or blocks (FIVB rules, spec §4.1).
- Rosters are original, generated players. Never use real athlete names (spec §4.4, §2 anti-goals).
- Every placeholder odds number lives in one `Tuning` file, so plan 3 can replace it.
- Use the spec's role tags exactly: OH, MB, OPP, S, L.

## Review Focus

1. **A middle rotating into zone 1 to serve.** The middle serves, and the libero is not on the court for them while they serve. The moment their team loses the serve, the libero replaces them in zone 1. Tested in Task 5.
2. **Deuce:** 14–14 must go on to 16–14, and a long deuce such as 24–22 must also win. 15–14 must not end the match. Tested in Task 6.
3. **A 6-2 in every rotation:** exactly one setter is in the back row and sets, and the front-row setter attacks as the opposite. It must never happen that neither or both are setting. Tested in Task 5.
4. **A starting rotation other than 1, and the first side-out.** The team that serves first does not rotate before its first serve. The receiving team rotates only when it wins the serve. Tested in Task 6.
5. **The women's lower net and Stupid Fast.** Every serve and attack flight that isn't an intended net error must clear the net at x = 0 for that game's height. No flight may last less than one step. Tested in Task 8.

---

### Task 1: Repository and package scaffold, with vector math

**Files:**
- Create: `Packages/SpikeCore/Package.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Math/Vec.swift`
- Create: `Packages/SpikeCore/Sources/spikesim/main.swift` (a stub that prints `spikesim` for now)
- Create: `Packages/SpikeCore/Tests/SpikeCoreTests/VecTests.swift`
- Create: `scripts/test-linux.sh`

**Interfaces:**
- Produces: `public struct Vec2: Codable, Hashable, Sendable { public var x: Float; public var z: Float }` and `public struct Vec3: Codable, Hashable, Sendable { public var x, y, z: Float }`, with `+`, `-`, scalar `*`, `length`, `normalized`, `Vec3.xz -> Vec2`, `Vec2.atHeight(_ y: Float) -> Vec3`, and `.zero` on both.
- Produces: `public enum TeamSide: Int, Codable, Sendable, CaseIterable { case home, away }` with `other` and `dir: Float` (+1 for home, −1 for away), in `Vec.swift`.

- [x] **Step 1: Repository.** Already done: `main` on the public GitHub repo `jdconley/spike-jam`, with the MIT license, README and `.gitignore`. Work on a branch and open a PR.

- [ ] **Step 2: Write `Package.swift`.** Use swift-tools-version 6.0 and platforms `.iOS("26.0")`, `.tvOS("26.0")`, `.macOS("26.0")`. The products are the library `SpikeCore` and the executable `spikesim` (depending on `SpikeCore`). Add the test target `SpikeCoreTests`. There are no dependencies.

- [ ] **Step 3: Write the failing test** in `VecTests.swift`:

```swift
import Testing
@testable import SpikeCore

@Test func vecArithmetic() {
    let a = Vec3(x: 1, y: 2, z: 3), b = Vec3(x: 0.5, y: -1, z: 2)
    #expect(a + b == Vec3(x: 1.5, y: 1, z: 5))
    #expect(a - b == Vec3(x: 0.5, y: 3, z: 1))
    #expect(a * 2 == Vec3(x: 2, y: 4, z: 6))
    #expect(Vec2(x: 3, z: 4).length == 5)
    #expect(abs(Vec2(x: 3, z: 4).normalized.length - 1) < 1e-6)
    #expect(a.xz == Vec2(x: 1, z: 3))
}

@Test func teamSides() {
    #expect(TeamSide.home.dir == 1 && TeamSide.away.dir == -1)
    #expect(TeamSide.home.other == .away)
}
```

- [ ] **Step 4: Run it to see it fail.** Run `cd Packages/SpikeCore && swift test --filter VecTests`. Expected: a compile failure, because `Vec3` is not defined.

- [ ] **Step 5: Implement `Vec2`, `Vec3` and `TeamSide`** in `Vec.swift`. Use `Float.squareRoot()` (stdlib), not Foundation. `normalized` of a zero vector returns `.zero`.

- [ ] **Step 6: Run the tests and see them pass.** Run `swift test --filter VecTests`. Expected: PASS.

- [ ] **Step 7: Write `scripts/test-linux.sh`.** It runs `docker run --rm -v "$PWD/Packages/SpikeCore":/pkg -w /pkg swift:<tag> swift test`. Use the tag matching the local `swift --version` major.minor, or the newest 6.x tag if that one doesn't exist, and write the chosen tag into the script. Make it executable.

- [ ] **Step 8: Run the Linux tests.** Run `scripts/test-linux.sh`. Expected: `VecTests` passes in the container. This proves SpikeCore has no Apple-only imports.

- [ ] **Step 9: Commit.**

```bash
git add Packages scripts
git commit -m "feat(core): SpikeCore package scaffold with vector math and Linux test script"
```

### Task 2: Seeded random generator

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Random/SeededRNG.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/SeededRNGTests.swift`

**Interfaces:**
- Produces: `public struct SeededRNG: RandomNumberGenerator, Codable, Hashable, Sendable`, with `init(seed: UInt64)`, `mutating next() -> UInt64`, `mutating unit() -> Float` in [0, 1), `mutating float(in: ClosedRange<Float>) -> Float`, `mutating int(in: Range<Int>) -> Int` and `mutating chance(_ p: Float) -> Bool`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func splitMix64KnownValue() {
    var r = SeededRNG(seed: 0)
    #expect(r.next() == 0xE220A8397B1DCDAF)
}

@Test func sameSeedSameSequence() {
    var a = SeededRNG(seed: 42), b = SeededRNG(seed: 42)
    for _ in 0..<1000 { #expect(a.next() == b.next()) }
}

@Test func unitAndRanges() {
    var r = SeededRNG(seed: 7)
    for _ in 0..<10_000 {
        let u = r.unit(); #expect(u >= 0 && u < 1)
        let f = r.float(in: -2...3); #expect(f >= -2 && f <= 3)
        let i = r.int(in: 3..<9); #expect(i >= 3 && i < 9)
    }
    var c = SeededRNG(seed: 9)
    let hits = (0..<20_000).filter { _ in c.chance(0.25) }.count
    #expect(abs(Float(hits) / 20_000 - 0.25) < 0.02)
}

@Test func copiesAreIndependent() {
    var a = SeededRNG(seed: 5); _ = a.next()
    var b = a
    #expect(a.next() == b.next())
}
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter SeededRNGTests`. Expected: a compile failure.

- [ ] **Step 3: Implement `SeededRNG` as SplitMix64.** Its state is one `UInt64`. `unit()` uses the top 24 bits divided by 2^24.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): seeded SplitMix64 generator"`.

### Task 3: Match settings

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Settings/MatchSettings.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Settings/Tuning.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/MatchSettingsTests.swift`

**Interfaces:**
- Produces:
  - `public enum GameType: String, Codable, Sendable, CaseIterable { case mens, womens }`, with `netHeight: Float` (2.43 and 2.24) and `paceScale: Double` (mens 1.0, womens 1.08). `paceScale` multiplies serve and attack flight durations (Claude's call; plan 3 tunes it).
  - `public enum Tempo: String, Codable, Sendable, CaseIterable { case fast, faster, stupidFast }`, with `flightScale: Double` (1.2, 1.0 and 0.82).
  - `public enum OffenseSystem: String, Codable, Sendable { case fiveOne, sixTwo }`.
  - `public struct TeamSettings: Codable, Equatable, Sendable { var system: OffenseSystem = .fiveOne; var startingRotation: Int = 1 }`, where `startingRotation` is 1...6.
  - `public struct MatchSettings: Codable, Equatable, Sendable`, with `gameType = .mens`, `tempo = .faster`, `pointsToWin = 15`, `winBy = 2`, `teams: [TeamSettings]` (count 2, indexed by `TeamSide.rawValue`), `firstServer: TeamSide = .home`, `catchUp = true` (unused until plan 3) and `seed: UInt64 = 1`. It also has `func team(_ side: TeamSide) -> TeamSettings`.
  - `public enum Tuning`, a namespace of `static let` constants, with `gravity: Float = -9.8 * 1.7`, `stepsPerSecond = 60`, `dt = 1.0 / 60.0`, `serveDelay = 0.8` s and `deadBall = 1.5` s. The rally odds are added in Task 8.

- [ ] **Step 1: Write the failing tests.** They check that `GameType.mens.netHeight == 2.43`, `GameType.womens.netHeight == 2.24`, the three `Tempo.flightScale` values, that `MatchSettings()` defaults to 15, win by 2, `.faster` and `.fiveOne`, and that it round-trips through `JSONEncoder` and `JSONDecoder` unchanged. JSON is used only in the test target, which imports Foundation.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement both files.** Also add a `validate() -> [String]` method on `MatchSettings`. It returns a problem when `startingRotation` is outside 1...6, `teams.count != 2`, `pointsToWin < 1` or `winBy < 1`.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): match settings, game types, tempos, tuning"`.

### Task 4: Rosters

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Roster/Athlete.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Roster/RosterGenerator.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/RosterTests.swift`

**Interfaces:**
- Consumes: `SeededRNG`, `GameType`, `OffenseSystem` and `TeamSide`.
- Produces:
  - `public enum Position: String, Codable, Sendable { case outside, middle, opposite, setter, libero }`, with `tag: String` ("OH", "MB", "OPP", "S", "L").
  - `public struct AthleteID: Codable, Hashable, Sendable { public let team: TeamSide; public let index: Int }`.
  - `public struct Traits: Codable, Equatable, Sendable { serve, pass, set, attack, block, defense, speed: Float }`, each in 0...1. Plan 3 uses them.
  - `public struct Athlete: Codable, Equatable, Sendable { id: AthleteID; name: String; number: Int; position: Position; heightM: Float; skinTone: Int; traits: Traits }`. `skinTone` is an index into 10 tone stops, 0..<10.
  - `public struct Roster: Codable, Equatable, Sendable { athletes: [Athlete] }`, with `subscript(_ id: AthleteID) -> Athlete` and `func ids(_ p: Position) -> [AthleteID]`.
  - `public enum RosterGenerator { static func make(team: TeamSide, gameType: GameType, system: OffenseSystem, rng: inout SeededRNG) -> Roster }`.

The roster composition is seven athletes in a fixed index order, because Task 5 relies on that order:
- 5-1: index 0 S, 1 OH1, 2 MB1, 3 OPP, 4 OH2, 5 MB2, 6 L.
- 6-2: index 0 S1, 1 OH1, 2 MB1, 3 S2, 4 OH2, 5 MB2, 6 L.

Height ranges (spec §4.4): men 1.78–2.08 m and women 1.68–1.93 m. Middles and opposites draw from the top third of the range, liberos and setters from the bottom half, and outsides from the middle (Claude's call).

- [ ] **Step 1: Write the failing tests:**

```swift
@Test(arguments: [GameType.mens, .womens], [OffenseSystem.fiveOne, .sixTwo])
func rosterShape(game: GameType, system: OffenseSystem) {
    var rng = SeededRNG(seed: 11)
    let r = RosterGenerator.make(team: .home, gameType: game, system: system, rng: &rng)
    #expect(r.athletes.count == 7)
    #expect(Set(r.athletes.map(\.number)).count == 7)
    #expect(r.athletes.allSatisfy { (1...99).contains($0.number) })
    #expect(Set(r.athletes.map(\.skinTone)).count == 7)          // no two alike
    #expect(r.athletes.allSatisfy { (0..<10).contains($0.skinTone) })
    let range: ClosedRange<Float> = game == .mens ? 1.78...2.08 : 1.68...1.93
    #expect(r.athletes.allSatisfy { range.contains($0.heightM) })
    let tallest = r.ids(.middle).map { r[$0].heightM }.min()!
    #expect(tallest > r[r.ids(.libero)[0]].heightM)
    #expect(r.ids(.setter).count == (system == .fiveOne ? 1 : 2))
    #expect(r.ids(.opposite).count == (system == .fiveOne ? 1 : 0))
    #expect(r.athletes[6].position == .libero)
    #expect(r.athletes.allSatisfy { $0.id.team == .home })
}

@Test func rostersAreSeeded() {
    var a = SeededRNG(seed: 3), b = SeededRNG(seed: 3)
    #expect(RosterGenerator.make(team: .away, gameType: .mens, system: .fiveOne, rng: &a)
         == RosterGenerator.make(team: .away, gameType: .mens, system: .fiveOne, rng: &b))
}
```

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement the generator.**
  - Names: first name plus last name from two original lists of at least 40 each in `RosterGenerator.swift`. Keep separate first-name lists for the men's and women's games, and use no real athletes.
  - Numbers: drawn without replacement from 1...99.
  - Skin tones: 7 distinct stops drawn from 0..<10.
  - Traits: each drawn from 0.45...0.9. Plan 3 shapes them by position.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): generated rosters with numbers, heights, skin tones, traits"`.

### Task 5: Lineup, rotation and the libero

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Rules/Lineup.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/LineupTests.swift`

**Interfaces:**
- Consumes: `Roster`, `AthleteID`, `Position`, `OffenseSystem` and `TeamSettings`.
- Produces:
  - `public enum Zone: Int, Codable, Sendable, CaseIterable { case z1 = 1, z2, z3, z4, z5, z6 }`, with `isFrontRow` (z2, z3, z4).
  - `public struct Lineup: Codable, Equatable, Sendable`, with:
    - `init(roster: Roster, settings: TeamSettings)`;
    - `var rotation: Int`, 0-based, where 0 is "rotation 1" with the first setter in zone 1;
    - `let system: OffenseSystem`;
    - `func baseOccupant(_ z: Zone) -> AthleteID`, before the libero swap;
    - `func onCourt(isServing: Bool) -> [Zone: AthleteID]`, after the libero swap;
    - `func server() -> AthleteID`, the zone-1 base occupant;
    - `func settingSetter(isServing: Bool) -> AthleteID`;
    - `func attackers(isServing: Bool) -> [AthleteID]`, the front-row players other than the setting setter;
    - `mutating func rotate()`.

The rules to implement:
- Serving order is the roster's indices 0–5, standing in zones 1, 2, 3, 4, 5 and 6 at rotation 0.
- Rotation is clockwise: the zone-2 player moves to zone 1, then 1 to 6, 6 to 5, 5 to 4, 4 to 3, and 3 to 2. So the first setter is in zone 1 in rotation 1, zone 6 in rotation 2, then 5, 4, 3 and 2.
- `startingRotation` n gives `rotation = n - 1`.
- The libero replaces whichever middle is in back-row zones 1, 5 or 6, except the middle who is in zone 1 while their team is serving.
- In a 5-1, the setting setter is always the setter. In a 6-2, it's whichever setter is in the back row.

- [ ] **Step 1: Write the failing tests.** Build rosters with `RosterGenerator` (seed 1). Each named player below is `roster.athletes[i].id`, using the index order from Task 4.

```swift
@Test func fiveOneRotationOne() {
    let l = lineup(.fiveOne, start: 1)
    #expect(l.baseOccupant(.z1) == S && l.baseOccupant(.z2) == OH1
         && l.baseOccupant(.z3) == MB1 && l.baseOccupant(.z4) == OPP
         && l.baseOccupant(.z5) == OH2 && l.baseOccupant(.z6) == MB2)
    #expect(l.onCourt(isServing: false)[.z6] == L)          // libero in for back-row MB2
    #expect(Set(l.attackers(isServing: false)) == [OH1, MB1, OPP])
}

@Test func fiveOneRotationFourSetterFrontRow() {
    let l = lineup(.fiveOne, start: 4)
    #expect(l.baseOccupant(.z4) == S && l.baseOccupant(.z3) == MB2
         && l.baseOccupant(.z2) == OH2 && l.baseOccupant(.z1) == OPP)
    #expect(Set(l.attackers(isServing: false)) == [MB2, OH2])  // two hitters + setter
}

@Test func setterPathThroughRotations() {
    var l = lineup(.fiveOne, start: 1)
    var zones: [Zone] = []
    for _ in 0..<6 { zones.append(Zone.allCases.first { l.baseOccupant($0) == S }!); l.rotate() }
    #expect(zones == [.z1, .z6, .z5, .z4, .z3, .z2])
    #expect(l.rotation == 0)                                    // wrapped
}

@Test func middleServesThenLiberoComesIn() {                    // Review Focus 1
    let l = lineup(.fiveOne, start: 3)                          // MB1 in zone 1
    #expect(l.server() == MB1)
    #expect(l.onCourt(isServing: true)[.z1] == MB1)
    #expect(!l.onCourt(isServing: true).values.contains(L))
    #expect(l.onCourt(isServing: false)[.z1] == L)
}

@Test func liberoNeverFrontRowNeverServes() {
    for system in [OffenseSystem.fiveOne, .sixTwo] {
        var l = lineup(system, start: 1)
        for _ in 0..<6 {
            for serving in [true, false] {
                let court = l.onCourt(isServing: serving)
                #expect(court.count == 6 && Set(court.values).count == 6)
                for (z, id) in court where id == L { #expect(!z.isFrontRow) }
            }
            #expect(l.server() != L)
            l.rotate()
        }
    }
}

@Test func sixTwoAlwaysOneBackRowSetter() {                     // Review Focus 3
    var l = lineup(.sixTwo, start: 1)
    for _ in 0..<6 {
        let setter = l.settingSetter(isServing: false)
        let zone = Zone.allCases.first { l.baseOccupant($0) == setter }!
        #expect(!zone.isFrontRow)
        let other = [S1, S2].first { $0 != setter }!
        #expect(l.attackers(isServing: false).contains(other))
        #expect(l.attackers(isServing: false).count == 3)
        l.rotate()
    }
}
```

- [ ] **Step 2: Run them to see them fail.** Run `swift test --filter LineupTests`. Expected: a compile failure.

- [ ] **Step 3: Implement `Lineup`.** Store the six serving-order IDs and the libero's ID from the roster. `baseOccupant` maps a zone back through `rotation` clockwise steps to the starting slot.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): six-rotation lineups for 5-1 and 6-2 with libero replacement"`.

### Task 6: Rally scoring and side-outs

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Rules/Score.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/ScoreTests.swift`

**Interfaces:**
- Consumes: `MatchSettings`, `Lineup` and `TeamSide`.
- Produces:
  - `public struct Score: Codable, Equatable, Sendable { points: [Int]; serving: TeamSide; winner: TeamSide? }`, with `init(settings:)`, where `serving` is `settings.firstServer`.
  - `public struct RallyResult: Equatable, Sendable { sideOut: Bool; matchWon: Bool }`.
  - `public func awardRally(to winner: TeamSide, score: inout Score, lineups: inout [Lineup], settings: MatchSettings) -> RallyResult`. It adds the point. If the winner was receiving, it rotates the winner's lineup, makes the winner the server, and sets `sideOut = true`. It sets `winner` when `points[w] >= pointsToWin && points[w] - points[other] >= winBy`.

- [ ] **Step 1: Write the failing tests:**
  - `deuce` (Review Focus 2): play home and away alternately to 14–14, then home, home. Expect the match won at 16–14. A separate case reaches 15–14 and expects not won. A long case alternates to 22–22, then home wins two, and expects it won at 24–22.
  - `straightWin`: home wins 15 in a row from 0–0, and the match is won at 15–0.
  - `firstServerDoesNotRotateBeforeServing` (Review Focus 4): use `startingRotation` 4 for home and 2 for away, with home serving first. Home wins the first rally: no side-out, and home's rotation stays at 3. Away wins the next: a side-out, away's rotation goes from 1 to 2, and away serves.
  - `serverStaysWhileWinning`: the serving team wins five in a row, and its rotation is unchanged.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement `Score` and `awardRally`.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): rally scoring to 15 win by 2 with side-out rotation"`.

### Task 7: Analytic ball flights

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Sim/Flight.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/FlightTests.swift`

**Interfaces:**
- Consumes: `Vec3` and `Tuning.gravity`.
- Produces: `public struct Flight: Codable, Equatable, Sendable { p0: Vec3; v0: Vec3; startTime: Double; duration: Double }`, with:
  - `static func make(from: Vec3, to: Vec3, duration: Double, startTime: Double) -> Flight`;
  - `func position(at t: Double) -> Vec3`;
  - `var endTime: Double`;
  - `func heightAtNet() -> Float?`, the ball's y where x crosses 0, or nil if it never does;
  - `func timeDescending(through y: Float) -> Double?`.
  These are ported from the spike's `Flight` in `SpikeJam/Sim.swift` without `simd`.

- [ ] **Step 1: Write the failing tests:**
  - `hitsEndpoints`: `position(at: startTime)` is `from` and `position(at: endTime)` is `to`, each within 1e-4.
  - `apexBetween`: for a level flight of 1 s, the height at the midpoint is above both ends by `-gravity * 0.125`, within 1e-3.
  - `heightAtNet`: a flight from (−6, 1, 0) to (6, 0, 0) over 1 s gives the analytic height at x = 0. A flight that stays at x < 0 gives nil.
  - `descendingThrough`: on a 1 s level flight from y = 0, passing y = 0.5 on the way down happens after the midpoint.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement `Flight`.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): analytic ball flights"`.

### Task 8: Game state, the step function and the placeholder rally engine

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Sim/GameState.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Sim/Court.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Sim/Step.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Sim/PlaceholderRally.swift`
- Modify: `Packages/SpikeCore/Sources/SpikeCore/Settings/Tuning.swift`, to add the rally odds
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/StepTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `public enum Phase: Codable, Equatable, Sendable { case preServe(untilTick: Int), rally, deadBall(untilTick: Int), matchOver }`.
  - `public enum TouchKind: String, Codable, Sendable { case serve, receive, set, attack, dig }`. Block arrives in plan 3.
  - `public struct PendingContact: Codable, Equatable, Sendable { kind: TouchKind?; team: TeamSide; athlete: AthleteID?; tick: Int }`. A nil `kind` means the ball lands.
  - `public enum PointReason: String, Codable, Sendable { case ace, serviceError, kill, attackError, handlingError }`.
  - `public enum GameEvent: Equatable, Sendable`, with the cases `served(AthleteID)`, `touched(TouchKind, AthleteID, quality: Float)`, `point(TeamSide, PointReason)`, `sideOut(TeamSide, rotation: Int)`, `liberoIn(AthleteID, for: AthleteID)` and `matchWon(TeamSide)`.
  - `public struct PlayerInput: Codable, Equatable, Sendable {}`, empty until plan 4, so the signature is stable.
  - `public struct GameState: Codable, Equatable, Sendable`. Its fields are `tick: Int`, `settings`, `rosters: [Roster]`, `lineups: [Lineup]`, `score: Score`, `rng: SeededRNG`, `phase: Phase`, `ball: Flight?`, `pending: PendingContact?`, `positions: [AthleteID: Vec2]`, `touchesThisSide: Int` and `rallyCount: Int`. It has `init(settings: MatchSettings)`, which generates both rosters from `settings.seed` and starts in `.preServe`.
  - `public func step(_ s: inout GameState, inputs: [PlayerInput]) -> [GameEvent]`, which advances exactly one tick.
  - `public enum Court`, with `zoneSpot(_ z: Zone, team: TeamSide) -> Vec2`. The home spots are z4 (−2, −3), z3 (−2, 0), z2 (−2, 3), z5 (−6.5, −3), z6 (−6.5, 0) and z1 (−6.5, 3). Away mirrors x and z. It also has `setterTarget(team:) -> Vec3`, home (−0.8, 2.55, 0.5) mirrored, and `attackPoint(_ z: Zone, team:) -> Vec3`. The front-row attack points come from the spike's `setOptions`, mirrored for zone: z4 (−1.1, 3.15, −3.5), z3 (−0.6, 3.0, −0.3) and z2 (−1.1, 3.15, 3.5).

How the placeholder rally engine works:
- Players stand on their zone spots. Plan 2 replaces this with real formations and movement.
- Every flight ends at its next contact's point, and the contact resolves on the first tick at or after `endTime`.
- Durations multiply by `settings.tempo.flightScale`. Serves and attacks also multiply by `settings.gameType.paceScale`. A flight never lasts less than `Tuning.dt`.
- **Serve:** from (−9.9, 2.6, the server's zone spot z) mirrored, toward a random spot in the other court, |x| 1.5...8.5 and |z| ≤ 4.2. Duration 0.95 s.
- **Receive and dig:** by the nearest on-court player of the defending team to the landing spot, never the setting setter. The ball goes to `setterTarget` over 0.85 + 0.35 × (1 − quality) s.
- **Set:** by the setting setter, to a random attacker's `attackPoint`. Durations are 0.78 s for z4, 0.42 s for z3 and 0.72 s for z2.
- **Attack:** toward a random spot in the other court, |x| 0.8...8.7, over 0.4 s.
- **Odds,** all in `Tuning` (Claude's placeholders, replaced in plan 3):
  - serve error 0.12, half into the net and half long beyond the end line;
  - ace 0.07;
  - pass error 0.06 (`handlingError` for the passing side);
  - set error 0.03;
  - attack error 0.10;
  - dig success 0.45, otherwise a kill;
  - pass quality drawn from 0.3...1.
- Net errors fly to (0.05 × −dir, 1.2, z). Every other serve and attack must clear the net: if `heightAtNet()` is below `netHeight + 0.15`, raise the flight's apex by giving it a higher peak with the same endpoints and duration. This is Review Focus 5.
- After a point, the phase is `.deadBall` for `Tuning.deadBall`, then `.preServe` for `Tuning.serveDelay`, then the serve. `.matchOver` once `score.winner` is set.
- After every rally, refresh `positions` from `onCourt` and emit `liberoIn` events for any swap that changed.

- [ ] **Step 1: Write the failing tests:**
  - `firstServeHappens`: `GameState(settings: MatchSettings())`, stepped until the first `served` event. The event arrives on tick `Int(0.8 * 60)`, ±1, and names home's zone-1 player.
  - `rallyEndsWithOnePoint`: step from the serve to the first `point`. Exactly one `point` event, and `score.points` sums to 1.
  - `flightsClearTheNet` (Review Focus 5): for `gameType` in mens and womens and `tempo` `.stupidFast`, run 50 seeded matches. On every tick where a new serve or attack flight starts that is not a net error, check that `heightAtNet()` > `netHeight`, and that every flight's duration is ≥ `Tuning.dt`. Add a debug-only `lastFlightWasNetError: Bool` on `GameState` for this check.
  - `fullMatchCompletes`: one match runs to `.matchOver` within 60 × 60 × 30 ticks. Exactly one `matchWon` event, and the winner has at least 15 points and leads by at least 2.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement the files.** `step` is a `switch` on `phase`, and the touch logic lives in `PlaceholderRally.swift` as `static func resolve(_ c: PendingContact, _ s: inout GameState, _ events: inout [GameEvent])`. Every random draw goes through `s.rng`.

- [ ] **Step 4: Run the tests and see them pass.** Run `swift test --filter StepTests`. Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): game state, fixed-step loop and placeholder rally engine"`.

### Task 9: Invariants, soak test and determinism

**Files:**
- Create: `Packages/SpikeCore/Sources/SpikeCore/Rules/Invariants.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/SoakTests.swift`

**Interfaces:**
- Consumes: `GameState`.
- Produces: `public func checkInvariants(_ s: GameState) -> [String]`, which is empty when the state is valid. It checks:
  - each team has 6 distinct athletes on court;
  - the libero is only in back-row zones and is never the server;
  - in a 6-2, the setting setter is a back-row player;
  - `rotation` is in 0..<6;
  - the serving team's server is its zone-1 base occupant;
  - neither team's points exceed what the win rule allows;
  - `phase == .matchOver` if and only if `score.winner != nil`.

- [ ] **Step 1: Write the failing tests:**
  - `soak`: 200 matches, seeds 1...200, cycling through mens and womens, 5-1 and 6-2, all three tempos and starting rotations 1–6. Call `checkInvariants` after every step and expect it to stay empty. Every match must finish.
  - `deterministic`: two `GameState`s from the same settings, stepped to the end, are `==`, and their event streams are equal.
  - `differentSeedsDiffer`: seeds 1 and 2 produce different final scores or different rally counts.

- [ ] **Step 2: Run them to see them fail.** Expected: a compile failure.

- [ ] **Step 3: Implement `checkInvariants`.**

- [ ] **Step 4: Run the tests and see them pass.** Run `swift test` (all tests). Expected: PASS. Then run `scripts/test-linux.sh`. Expected: PASS on Linux too.

- [ ] **Step 5: Commit** with `git commit -m "test(core): invariants, 200-match soak and determinism"`.

### Task 10: The `spikesim` headless match runner

**Files:**
- Modify: `Packages/SpikeCore/Sources/spikesim/main.swift`
- Create: `Packages/SpikeCore/Sources/SpikeCore/Sim/MatchStats.swift`
- Test: `Packages/SpikeCore/Tests/SpikeCoreTests/MatchStatsTests.swift`

**Interfaces:**
- Consumes: `GameState`, `step` and `checkInvariants`.
- Produces:
  - `public struct MatchStats: Equatable, Sendable`, with `matches`, `rallies`, `touches`, `sideOuts`, `aces`, `serviceErrors`, `kills`, `attackErrors`, `invariantFailures` and `marginTotal`, plus the computed `avgTouchesPerRally`, `sideOutRate` and `avgMargin`.
  - `public func runMatches(_ settings: MatchSettings, count: Int) -> MatchStats`, where match i uses seed `settings.seed + i`.
  - The CLI is `spikesim [--matches N] [--seed S] [--game mens|womens] [--system 51|62] [--tempo fast|faster|stupidfast]`. It uses plain `CommandLine.arguments` parsing, defaults to 100 matches with seed 1, prints one `key: value` line per stat, and exits 1 if `invariantFailures > 0`.

- [ ] **Step 1: Write the failing test.** `statsAddUp` runs `runMatches(MatchSettings(), count: 20)`. It expects `matches == 20`, `invariantFailures == 0`, `sideOutRate` strictly between 0 and 1, and `avgTouchesPerRally >= 1`.

- [ ] **Step 2: Run it to see it fail.** Expected: a compile failure.

- [ ] **Step 3: Implement `MatchStats`, `runMatches` and the CLI.**

- [ ] **Step 4: Run the test and the CLI.** Run `swift test --filter MatchStatsTests`, expecting PASS. Then run `swift run spikesim --matches 200 --game womens --system 62`. Expected: the stats lines, with `invariantFailures: 0` and exit code 0.

- [ ] **Step 5: Commit** with `git commit -m "feat(core): spikesim headless match runner"`.
