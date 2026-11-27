# Two Phones on the Same Wi-Fi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** JD and his son play one match on two iPhones on the same Wi-Fi, as teammates or opponents, with bots filling the other spots. One phone hosts. Touches feel instant on both phones, and the host stays in charge. This is the first TestFlight prototype.

**Architecture:**
- A new **SpikeNet** package holds the protocol messages, a compact binary encoding, the server loop and the client prediction-and-replay loop.
- A `Transport` protocol keeps it independent of the network:
  - an in-memory transport with simulated delay, jitter and loss for tests;
  - a Network.framework UDP transport with Bonjour for local play.
- The host phone runs `ServerLoop` and its own `PredictingClientLoop` in-process. The guest runs a `PredictingClientLoop` over UDP.
- Both conform to plan 5's `ClientLoop`, so the UI doesn't change.

**Tech Stack:** Swift 6, Swift Testing, Network.framework (`NWListener`, `NWConnection`, `NWBrowser`, UDP), SpikeCore, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-26-spike-jam-design.md`:
- §5.3, the online model: the server is in charge; there is a 1–2 tick input buffer with speed-up and slow-down hints; snapshots go out at about 30 Hz; clients run ahead and replay; timing is judged in the toucher's favor with a cap of about 150 ms; corrections are smoothed over 100–200 ms; inputs are sent redundantly and unreliably; calls go reliably; clashing touches wait for confirmation; a dropped player is replaced by the AI;
- §5.4, local mode: the host runs the same server loop in-process, over UDP on the local network, with Bonjour;
- §5.5, the network test rig.

**Depends on:** plans 1–5 merged.

## Global Constraints

Everything in plans 1–5, plus:
- One protocol for local play now and online later (spec §5.4). Messages and loops never assume LAN, and only the transport does.
- **Local play uses a Network.framework transport for now (Claude's call).** The spec's `netcode` and `reliable` C libraries arrive with the online milestone behind the same `Transport` protocol. Local play stays on the local network, so the encryption netcode adds isn't needed yet.
- Packets stay under 1,200 bytes (spec §5.4).
- Snapshots carry only the state that changes during a match. Rosters and settings go once, reliably, at match start.
- Bonjour service type `_spikejam._udp`. The Info.plist gets `NSLocalNetworkUsageDescription` ("Spike Jam finds and joins games on your Wi-Fi.") and `NSBonjourServices`.
- Kill banners, point celebrations and score changes wait for the host's confirmation (spec §5.3).
- No chat, no typed names. Each phone shows a generated nickname, so children can play safely (spec §5.6).

## Review Focus

1. **The guest's own touch in a 100 ms round-trip rally.** It must play instantly on the guest, be judged by the host against the moment the guest saw it, and almost never be overruled within the 150 ms cap. Tested in Task 4 with the rig.
2. **A burst of 5% packet loss during a serve-receive.** Redundant inputs mean the host still gets the tap. Tested in Task 4.
3. **A predicted kill that the host turns into a stuff.** The guest never shows KILL or changes the score before confirmation. Tested in Task 4.
4. **The guest's phone sleeping, or Wi-Fi dropping mid-match.** The host's AI takes over their player within a second. The guest can rejoin into the same team, and gets a fresh pick at the next huddle. Tested in Task 5.
5. **The host backgrounding the app.** The match pauses for both, with a "Host paused" banner on the guest, and resumes cleanly. Hosts can't run in the background on iOS. Tested in Task 6.

---

### Task 1: The SpikeNet package, messages and binary encoding

**Files:**
- Create: `Packages/SpikeNet/Package.swift`, which depends on `../SpikeCore` and targets iOS 26, tvOS 26, macOS 26 and Linux
- Create: `Packages/SpikeNet/Sources/SpikeNet/Messages.swift`
- Create: `Packages/SpikeNet/Sources/SpikeNet/BinaryCoder.swift`, a compact `Encoder` and `Decoder` for Codable with little-endian fixed-width numbers and varint lengths
- Create: `Packages/SpikeNet/Sources/SpikeNet/Snapshot.swift`
- Test: `Packages/SpikeNet/Tests/SpikeNetTests/MessageTests.swift`

**Interfaces:**
- Produces:
  - `public enum Message: Codable, Sendable`, with the cases:
    - `hello(nickname: String, version: Int)`;
    - `welcome(human: HumanID, settings: MatchSettings, rosters: [Roster], startTick: Int)`;
    - `inputs(ack: Int, items: [PlayerInput])`, which carries the last 8 ticks' inputs redundantly;
    - `snapshot(Snapshot)`;
    - `timeHint(adjustPPM: Int16)`;
    - `reliable(seq: UInt32, InputAction)`;
    - `ack(seq: UInt32)`;
    - `bye`.
  - `public struct Snapshot: Codable, Equatable, Sendable { tick: Int; dynamic: DynamicState; confirmedThrough: [HumanID: Int] }`, with `DynamicState` holding every `GameState` field except `settings` and `rosters`.
  - `extension GameState { func dynamic() -> DynamicState; mutating func apply(_ d: DynamicState) }`.
  - `public enum Wire { static func encode(_ m: Message) throws -> Data; static func decode(_ d: Data) throws -> Message }`.

- [ ] **Step 1: Write the failing tests:**
  - `roundTripAll`: every `Message` case round-trips.
  - `snapshotFits`: a snapshot taken at the busiest tick of 50 bot matches, with all 12 players moving and the ball in flight, encodes to at most 1,200 bytes. Print the maximum.
  - `applyRestores`: `s2.apply(s1.dynamic())` with the same settings and rosters makes `s2 == s1`.

- [ ] **Step 2: Run them to see them fail.** Run `swift test --package-path Packages/SpikeNet`. Expected: FAIL.

- [ ] **Step 3: Implement it.** If a snapshot won't fit, quantize positions to centimeters as `Int16` inside `DynamicState`'s own `encode(to:)`, not in `GameState`.

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS, on macOS and Linux (extend `scripts/test-linux.sh` to the new package).

- [ ] **Step 5: Commit** with `git commit -m "feat(net): SpikeNet messages, binary coder, snapshots"`.

### Task 2: The transport protocol and the simulated network rig

**Files:**
- Create: `Packages/SpikeNet/Sources/SpikeNet/Transport.swift`
- Create: `Packages/SpikeNet/Sources/SpikeNet/SimNetwork.swift`
- Test: `Packages/SpikeNet/Tests/SpikeNetTests/SimNetworkTests.swift`

**Interfaces:**
- Produces:
  - `public protocol Transport: AnyObject, Sendable { func send(_ d: Data, to peer: PeerID); var onReceive: (@Sendable (Data, PeerID) -> Void)? { get set } }`.
  - `public struct PeerID: Hashable, Sendable`.
  - `public final class SimNetwork`, a deterministic virtual clock with `connect() -> (Transport, Transport)`. Each link has `oneWayDelay`, `jitter` and `loss`, from a seeded RNG, plus `advance(by seconds:)`.

- [ ] **Step 1: Write the failing tests:**
  - `delays`: with a 50 ms delay and no jitter, a packet arrives exactly 50 ms after sending.
  - `lossRate`: 5% loss over 10,000 packets drops 4–6%.
  - `reorders`: with 30 ms jitter, at least some packets arrive out of order.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(net): transport protocol and simulated network rig"`.

### Task 3: The server loop

**Files:**
- Create: `Packages/SpikeNet/Sources/SpikeNet/ServerLoop.swift`
- Test: `Packages/SpikeNet/Tests/SpikeNetTests/ServerLoopTests.swift`

**Interfaces:**
- Produces: `public final class ServerLoop { init(settings: MatchSettings, transport: Transport); func admit(_ peer: PeerID, team: TeamSide) -> HumanID; func rejoin(_ peer: PeerID, as human: HumanID) -> Bool; func tick(now: Double) }`. It:
  - runs SpikeCore at 60 Hz;
  - keeps a per-client input buffer targeting 1–2 ticks, and sends `timeHint` (±1,000 PPM max) to keep it there;
  - sends a snapshot every 2 ticks (30 Hz);
  - resends reliable actions until acked;
  - judges owned touches in the toucher's favor up to a 150 ms cap. When an owned input arrives late but within the cap, it rewinds to the contact tick from its own ring buffer of the last 60 states, applies the input, and replays to now;
  - marks a peer silent for more than 1.0 s as dropped, and the AI takes over its athlete, with its `HumanSlot` kept for a rejoin.

- [ ] **Step 1: Write the failing tests:**
  - `bufferConverges`: a client clocked 2% fast, after 10 s of hints, keeps the buffer within 1–2 ticks for 95% of ticks.
  - `lateTouchRewinds`: an owned pass tap arriving 120 ms after its contact (within the cap) is graded against its own timestamp. The resulting state equals a no-latency run with the same input.
  - `beyondCapIsMiss`: the same tap arriving 200 ms late is a miss.
  - `droppedGetsAI`: a peer silent for 1.1 s has no owner on the next contact, and `rejoin` restores its slot.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(net): authoritative server loop with input buffer, rewind and drop handling"`.

### Task 4: The predicting client loop and smoothing

**Files:**
- Create: `Packages/SpikeNet/Sources/SpikeNet/PredictingClientLoop.swift`
- Create: `Packages/SpikeNet/Sources/SpikeNet/Smoother.swift`
- Test: `Packages/SpikeNet/Tests/SpikeNetTests/PredictionTests.swift`

**Interfaces:**
- Consumes: plan 5's `ClientLoop` protocol. Move it from `App/Loop/ClientLoop.swift` into SpikeNet so both packages share it, and make the app import it.
- Produces: `public final class PredictingClientLoop: ClientLoop`. It:
  - runs ahead of the server by half the measured round trip plus the buffer, adjusted by `timeHint`;
  - keeps a 60-state ring buffer and its unconfirmed inputs;
  - on each snapshot, restores the snapshot's tick, replays its unconfirmed inputs to the present, and hands the `Smoother` the jump between the old and new predicted positions;
  - `confirmedEvents` holds only score, point, kill-banner and fire events at or before the last snapshot tick (spec: celebrations wait for confirmation). Other events, such as touches, judgments and haptics, play immediately.

  `Smoother` blends the drawn ball and player positions from the old prediction into the corrected one over 150 ms (spec: 100–200 ms), easing out.

- [ ] **Step 1: Write the failing tests** with `SimNetwork` at a 50 ms one-way delay (100 ms round trip), 10 ms jitter and 2% loss, a `SimHuman` on each phone, and 20 matches:
  - `ownTouchInstant` (Review Focus 1): the guest's `judged` event for its own touch appears in the guest's events on the same tick as its input. The host overrules fewer than 2% of the guest's touches.
  - `lossTolerated` (Review Focus 2): at 5% loss, the host receives at least 99.5% of the guests' owned touch inputs, thanks to redundancy.
  - `noTakeBackCelebrations` (Review Focus 3): force a predicted kill that the host resolves as a stuff. The guest's `confirmedEvents` never contain that kill, and its displayed score never changes before the snapshot.
  - `smoothBounded`: no drawn ball position jumps more than 0.5 m in one frame during corrections.
  - `converges`: at the end of each match, the guest's state equals the host's.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run everything.** Run `swift test --package-path Packages/SpikeNet`, `swift test --package-path Packages/SpikeCore` and `scripts/test-linux.sh`. Expected: PASS. Print the overrule and loss figures.

- [ ] **Step 5: Commit** with `git commit -m "feat(net): predicting client loop with replay, smoothing and confirmed celebrations"`.

### Task 5: The local Wi-Fi transport, host and join

**Files:**
- Create: `App/Net/LocalTransport.swift`, a Network.framework UDP transport: `NWListener` on the host, advertised as `_spikejam._udp` with the host's nickname, and `NWConnection` for each peer
- Create: `App/Net/LocalBrowser.swift`, an `NWBrowser` list of hosts nearby
- Create: `App/Net/HostSession.swift`, which owns `ServerLoop`, the host's own in-process `PredictingClientLoop` over a loopback `SimNetwork` link with zero delay, and the guests' `LocalTransport` peers
- Create: `App/Net/GuestSession.swift`
- Modify: `App/Screens/StartScreen.swift`, which adds "Play together (same Wi-Fi)":
  - **Host:** pick men's or women's, the tempo and the difficulty, then wait for players.
  - **Join:** a list of nearby hosts.
  - **Lobby:** each phone picks Home or Away (teammates or opponents), and the host taps Start.
- Modify: `App/Info.plist`, for the local network strings in the Global Constraints
- Create: `App/Net/Nicknames.swift`, generated volleyball nicknames with dice to reroll, original and not typed
- Test: `AppTests/LocalNetTests.swift`

**Interfaces:**
- Consumes: `ServerLoop`, `PredictingClientLoop`, `Transport` and `Wire`.
- Produces: `HostSession.start(settings:)`, `GuestSession.join(_ host: NWBrowser.Result)`, and `var loop: ClientLoop`, which plan 5's `GameLoop` drives unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `loopbackMatch`: in one process, a `HostSession` and a `GuestSession` over real `LocalTransport` on 127.0.0.1 play 30 s with `SimHuman`s. No errors, and the states converge.
  - `rejoin` (Review Focus 4): close the guest's connection for 2 s, then reconnect. The guest gets the same `HumanID` and team, and its pick resets at the next huddle.
  - `nicknamesNotTyped`: `Nicknames.random(rng:)` returns only list entries.

- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.

- [ ] **Step 3: Implement it.**

- [ ] **Step 4: Run the tests and see them pass.** Expected: PASS.

- [ ] **Step 5: Commit** with `git commit -m "feat(app): host and join on the same Wi-Fi with Bonjour"`.

### Task 6: Pausing, two-device testing and the TestFlight prototype

**Files:**
- Modify: `App/Net/HostSession.swift` and `GuestSession.swift`, for the background handling
- Modify: `docs/playtest-3-checklist.md`, which adds the two-phone items
- Test: `AppTests/PauseTests.swift`

- [ ] **Step 1: Write the failing test** `hostBackgroundPauses` (Review Focus 5). When the host's scene phase goes to background, the host sends a reliable `paused` action and stops stepping. The guest shows "Host paused" and stops predicting past the last snapshot. On resume, both continue from the same tick.

- [ ] **Step 2: Run it to see it fail, implement it, then run it to see it pass.**

- [ ] **Step 3: Test on two simulators.** Boot two iPhone simulators on this Mac, host on one and join from the other, play one rally each way, and screenshot both.

- [ ] **Step 4: Test on two devices.** Install on JD's iPhone and a second phone (JD's son's, if JD can add it). Play one match on the same Wi-Fi, as teammates, then as opponents.

- [ ] **Step 5: Open the PR.** JD merges it once CI passes. The pipeline uploads the build and sends it to the TestFlight "Family and Friends" group, which is the prototype for JD and his son.

- [ ] **Step 6: Commit** with `git commit -m "feat(app): host pause handling and two-phone playtest checklist"`.

---

## As built: corrections (Tasks 1–4)

The code in `Packages/SpikeNet` is the reference; these are the places it differs from the text above.

**Messages and the wire (Task 1)**
- `welcome(human:settings:startTick:)` carries no rosters. Both rosters encode to about 1.3 KB, past the 1,200-byte packet, and they follow from the settings: both ends make them with `GameState(settings:)`.
- `inputs(tick:ack:first:items:)`: `tick` is the guest's current tick (the host measures its input buffer from it), and the items are numbered from `first`. Each input goes again in every packet until a snapshot confirms it, rather than for a fixed 8 ticks, so a burst of loss costs nothing however long the round trip. Items are `NetInput`: a `PlayerInput` plus, for a touch, `seen`, the contact's tick on the guest's phone (see Task 3).
- `Snapshot` has `confirmedThrough: [Confirmation]` (per human: the newest input and reliable numbers taken, and the newest packet tick), not `[HumanID: Int]`. It adds `pending`, the inputs the host has but hasn't played yet, and `confirmed`, the score and the latest celebrations confirmed for good.
- `DynamicState` keeps the settings, which are a few dozen bytes: a team's system can change in the first huddle (`teamSettings`), which rebuilds the rosters. `apply` makes the rosters again when the settings change them.
- The binary coder writes `Int` and `UInt` as varints (zig-zag) rather than 8 fixed bytes: SpikeCore uses `Int` for ticks, indices and every enum raw value. Strings that are SpikeCore enum names or case names are one byte (`StringTable`). Arrays have varint counts. The hot small types (vectors, motion, the ball's flight, IDs) skip Codable's containers (`WireValue`): a snapshot encodes in about 25 µs and decodes in about 40 µs. The busiest snapshot of 50 matches is 828 bytes.

**Transport and rig (Task 2)**
- `SimNetwork` has `endpoint()` as well as `connect()`, since one host transport talks to several peers; link conditions are per direction (`setLink(_:from:to:)`, `setLink(_:between:and:)`). Jitter is uniform in 0…`jitter` on top of the delay.

**Host loop (Task 3)**
- The time hint is capped at ±25,000 PPM (2.5%), not ±1,000. The test's 2% fast clock needs 20,000; a real clock drifts by tens of PPM, but a display-driven loop can be a percent off. It's a PI controller on the measured slack, and the guest jumps its own clock when the slack is far off (at the start, or after a stall).
- The hints aim for 1.5 steps of continuous slack, measured when the host takes a packet; that keeps the whole steps waiting beyond the host's tick (`buffer(of:)`) at 1–2 (all 1,200 samples in `bufferConverges`).
- Touches are judged against the contact as the toucher saw it (spec §5.3), through `Placement`, which host and guests share: if the host's contact comes later or sooner than the guest's phone predicted, the input moves with it, up to the 150 ms cap; a touch for a contact not open yet on the host (a block jump for a set the host hasn't seen leave) waits for it, as long as the cap. Without this, 2.3% of the guest's touches were overruled; with it, 1.1%.
- Celebrations (points, side-outs, match won, fire) and the score in snapshots are confirmed once they're older than the rewind cap, so a late touch's rewind can never take one back.
- There's no `start`: the clock starts at the first `tick(now:)`. `admit` before that sets up the match's humans; after it, they join the match in progress. `rejoin` returns the human on the same team with their pick reset to "ball" until the next huddle. Added: `onHello` (an unknown peer said hello, for the host session to admit), `onDrop`, `onStep`, `stats`, `state(at:)`, `connected`, `confirmedPoints`.

**Predicting client (Task 4)**
- `ClientLoop` stays in `App/`: it's `@MainActor` and app-internal. `PredictingClientLoop` has the same members (and isn't tied to an actor, so it runs on the Linux server too); `App/Loop/PredictingClientLoop+ClientLoop.swift` is the one-line conformance.
- A snapshot that matches the prediction for its tick (state and waiting inputs) is taken without a replay.
- Another human's pass, dig, set or attack the guest hasn't heard of yet is predicted as on time with the AI's choices, instead of a miss when the grace window closes.
- `confirmedEvents` is every confirmed celebration of the match; `advance` returns them as they're confirmed, with the predicted events that aren't celebrations. Predicted celebrations never come out (`onPredictedCelebration` sees them, for tests). The drawn `previous` and `current` carry the confirmed score.
- `Smoother` eases out over 150 ms but closes at most 10 m/s, so a correction of more than about 0.75 m takes a little longer. The drawn flight carries the offset's rate, so the ball moves smoothly between steps.
- An own judgment the host overrules shows again with the host's grade.

**Tests**
- `smoothBounded` measures the drawn ball at 120 Hz, as the app draws it. Frames where a touch since the previous frame started the ball elsewhere don't count: some SpikeCore touches start the new flight away from the old one's end, solo too. The largest jump is 0.45 m.
- `ownTouchInstant` counts each contact's first judgment, against the contact's tick in the guest's latest prediction, with two steps of leeway for a correction that moved it between frames (waiting for the host would be 8 steps or more). A correction can renumber later contacts, so a contact is the guest's if its newest window was.
- `noTakeBackCelebrations` forces predicted kills: while the hosting phone's player has a block up against the guest's side, the guest hears nothing from the host until the rally is over. Six matches give a few kills the host turned into stuffs; the guest's confirmed celebrations equal the host's exactly, and it never draws a score the host hadn't confirmed.
- `lossTolerated` plays 4 matches at 5% loss each way (294 of 294 touches arrived). `snapshotFits` plays its 50 matches with a simulated human on each side, so the snapshots have humans in them.
- The 20 matches at 100 ms are played once and read by `ownTouchInstant`, `smoothBounded` and `converges`.
- The tests run optimized (`swift test -c release -Xswiftc -enable-testing`, in CI and `scripts/test-linux.sh`): neither package uses `assert`, so every check still runs, about ten times faster.

## As built: corrections (Tasks 5–6)

**The local transport, host and join (Task 5)**
- `LocalTransport` is UDP through Network.framework: hosting, an `NWListener` advertised as `_spikejam._udp` under the host's nickname, with an `NWConnection` per guest (peers numbered from 2³², clear of the in-process `SimNetwork`'s); joining, one `NWConnection` to the host's service. A listener that fails (iOS can reclaim a suspended app's sockets) starts again on the same port. It delivers on its own queue; the sessions drain it on the main thread.
- The lobby is its own small message, `LobbyMessage` (`join`, `room`, `leave`), JSON under its own first byte on the same connection; SpikeNet's loops ignore it. `join` carries the generated nickname, a private random token and the side picked, four times a second until the guest plays; the host sends each guest the room back. The token is how a phone that comes back finds its old slot, even if two phones roll the same nickname. SpikeNet's `hello` is still the guest's ask to join a match in progress.
- `HostSession.start()` (the settings are given when the room opens) makes the `ServerLoop`, admits the host's own player and every guest in the room, and the host's own `PredictingClientLoop` over a fresh zero-delay `SimNetwork` link each match. `HostClientLoop` is the hosting phone's `ClientLoop`: each frame the lobby, `net.advance`, `server.tick`, `net.advance`, then the own client. `rematch()` is Play again with the same phones.
- `GuestSession.join(_:as:team:now:)` takes a `NearbyHost` (name and endpoint) from `LocalBrowser`, not an `NWBrowser.Result`. `GuestClientLoop` is the guest's `ClientLoop` through rejoins and rematches; after a rejoin the old prediction stays on screen until the new client has a snapshot.
- **Rejoining is always a new connection.** A guest that hears nothing for 1.2 s (3 s while the host said it paused), or that comes back after more than half a second off screen, connects again; the host sees a new peer, and `rejoin` gives it the same human, team and a fresh pick, with fresh input numbering on both ends. Reusing the old connection could leave the two ends numbering differently.
- `MatchMode.network(NetMatch)` plays a hosted or joined match through the same `MatchView`: banners for "HOST PAUSED", "WAITING FOR THE HOST…", a guest dropped, and a card for the host leaving. The score chip reads YOU for the local side (it can be away now), and the match-over card says YOU WIN by the local side. Only the host has PLAY AGAIN.
- Launch arguments for checks on simulators: `-together host|join`, `-auto` (open the room and start three seconds after a guest is in; join the first host found), `-robot` (the robot finger plays this phone), `-port <n>` (host on n; a guest that found a host with Bonjour connects to 127.0.0.1:n, because the Mac's firewall turns away UDP to its own network address from simulator apps).
- Added tests: `manyPacketsThroughTheLinks` (below), and in SpikeNet `PauseTests` and `StallTests`.

**Pausing and stalls (Task 6)**
- SpikeNet has `Message.paused(tick:)`. `ServerLoop.pause()` stops stepping and sends three copies to every guest (it can't resend: the app is about to stop running); `resume(now:)` carries on from the same tick without stepping the paused time or counting it as anyone's silence. `PredictingClientLoop` stops its clock on `paused` (`hostPaused`) and starts it again on the first snapshot after the pause's tick; a `paused` older than a snapshot it already has is ignored. The hosting phone's own client sets `ignoresHostPause`, since it pauses with the host directly. The test is `hostBackgroundPauses` (with `longHostPauseRejoins` for a pause long enough that the guest connects again).
- Two bugs that only showed up in the app, now with tests:
  - **A stall on the hosting phone** (the match view loading its scene took 1.6 s on a simulator) left the server skipping what it couldn't catch up while its own client caught up all of it and ran 100 steps ahead. The clock jump back then repeated on every snapshot (the guard only knew forward jumps), and the server, which only took rising packet ticks, kept a stale slack. Now the server orders a guest's packets by their ack, then tick, and restarts its slack measurement on a jump; the client waits for a packet sent since its jump either way; and a gap between the server's own ticks isn't counted as its guests' silence (`StallTests.stallRecovers`).
  - **A handler stored as `Mutex<closure?>`** grew two reabstraction thunks on every `withLock` (an `inout` of a generic value writes back wrapped), and after a few thousand packets the network thread overflowed its stack. Handlers are kept in a struct now (`Receiver`).
- Two-device notes and what to try are in `docs/playtest-4-checklist.md`.
