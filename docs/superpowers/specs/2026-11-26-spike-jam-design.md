# Spike Jam: Design

Status: draft for JD's review, 2026-11-26. Updated the same day with JD's answers on kids, men's and women's games, and Hetzner hosting.
Owner: JD. Written with Claude after brainstorming and two on-device playtests of a throwaway spike (`~/src/spike-jam`, notes in `docs/playtest-1-notes.md`).

Items marked **(Claude's call)** were not decided by JD. They are proposals he can overturn.

## 1. What this is and why

Spike Jam is an arcade-style indoor volleyball game. Players pick a men's or a women's game (JD, 2026-11-26). It is fast, loud and over the top, with big celebrations and players who get "on fire". It is mobile-first, plays well with a game controller, and is built for live multiplayer with friends.

It is for teens and young adults who play volleyball, boys and girls. It is also for millennial parents who grew up on 90s arcade sports games and now have kids who play volleyball. Parent and kid should be able to play together, on the same team or against each other.

It ships publicly on the App Store under Conley Chaos LLC, like Pounce, and kids under 13 are welcome. They are protected the way Pounce protects them (§5.6) (JD, 2026-11-26).

What makes it special:
- **You coach the team and play one player.** In the huddle you pick the plays and the player you'll be. The AI runs the team on your plan, and you make your player's fast, timed touches. You can switch to another player mid-rally whenever you want.
- **It runs like real high-level volleyball, men's or women's.** The setter calls plays, hitters run combinations, blockers read, and the libero digs. Each touch is still one easy gesture.
- **It is always obvious what is happening.** The camera moves to show the play, and slow motion, prompts and markers say whose touch it is and what to do.

## 2. Goals, non-goals, anti-goals

**Goals**
- A rally that feels FAST. Each touch is one simple gesture whose timing matters.
- Choosing serves, sets and hits is intuitive and super easy. It is decided by where you aim and who you set, not by menus or button combos.
- A strategy layer like the high-level game: play calls in a huddle, changing the call mid-rally, and reading the other team's attack on defense.
- Real rotation, serve-receive stacks and real court movement, with a 5-1 or 6-2 to pick in advanced team settings (§4.1).
- A men's game and a women's game, each with its own net height, pace and style of offense (§4.7).
- Kids under 13 can play safely, with the same protections as Pounce (§5.6).
- Every player is easy to tell apart on the court: jersey numbers, a range of skin tones, heights and builds (§4.4).
- The AI plays like real people, good but imperfect and different from player to player. Against the AI, a hidden catch-up keeps the score close, so your own touches decide the match (§4.9).
- Hitters and liberos can get on fire. Celebrations are huge.
- Live online multiplayer with friends. Each person is on their own phone, as opponents or teammates, with bots filling the empty spots.
- Local play: one phone or an Apple TV runs the game, with phones as controllers. This is like JD's Pounce TV table.
- The game teaches itself with a tutorial that uses bullet time and pauses.

**Non-goals (for now)**
- Simulation-grade physics and stats sheets. The rotations, systems and movement are real, but the ball, the speed and the celebrations stay arcade.
- A career, franchise or season mode. JD expects to build a career mode eventually, but it's out of this design (JD, 2026-11-26). Rosters and player traits (§4.4) should not rule it out.
- Matchmaking with strangers, ranked play and leaderboards **(Claude's call: friends-only first)**.
- Android, Windows and web. The engine choice makes the game Apple-only, which JD accepted.
- More than 2 humans per side at launch.
- Coed teams (men and women on one court) **(Claude's call: one game type per match; coed can come later)**.
- Text or voice chat **(Claude's call)**. With kids playing, no one types or says anything to anyone in the game. Celebrations and quick emotes only.
- Hosting built for big crowds. Start cheap and think about scale later (JD, 2026-11-26).

**Anti-goals: failure even if it technically works**
- A new player picks it up and doesn't know what to do. This happened in playtest 1, and it must not ship that way.
- Online play that feels mushy. If a touch is delayed or overruled often enough to be noticed, the netcode has failed.
- Strategy that slows the game down. The huddle must never feel like a menu screen.
- A clone of an existing game. No names, catchphrases, art, music or announcer lines from NBA Jam or any other franchise. "On fire" as a mechanic is fine, but the look, voice and words must be original.
- A HUD that is hard to read. Playtest 1 showed that too many similar markers (all yellow) confuse people. Each signal gets one clear look.
- A child can be reached by, or reveal anything about themselves to, someone who isn't a friend they joined on purpose.
- The women's game as a reskin: same speeds and plays with different jerseys. It should play like the women's game.

## 3. Constraints

- **Engine:** Swift with RealityKit for rendering, plus SwiftUI for the HUD and menus (JD's choice over Godot). Targets iPhone first, then Apple TV, iPad and Mac. A controller is supported everywhere through the GameController framework.
- **Online:** the server is in charge over the internet. Clients predict and replay, with smoothing and rubberbanding, as AAA action games do. Messages go over UDP, not TCP. Game servers run in containers, and the game code is shared between the app and the server (JD's direction).
- **Hosting cost:** start cheap, on JD's existing Hetzner VPS servers, so nothing new is bought (JD, 2026-11-26). His AWS account is the path for scale later.
- **Kids:** under-13 players are supported, with Pounce's rules: COPPA, Apple's Declared Age Range, and state app-store laws (JD, 2026-11-26).
- **Local:** one phone or the Apple TV is in charge (JD's direction).
- **Feel tests run natively on JD's iPhone**, never in a browser stand-in (JD's standing feedback).
- **Existing infrastructure:** Pounce (`~/src/pounce-tv`) already has a Cloudflare Worker with one Durable Object per room, link and QR joining, and a TV joining as a `role=screen` device. Reuse it for rooms and invites. It cannot host the match itself, because Cloudflare Containers don't take inbound UDP.

## 4. The game

### 4.1 Teams, rotation, movement and control

**Real rotation and real court movement (JD, 2026-11-26).** The team rotates, stacks for serve receive and moves the way a real high-level team does, so defense, attack and player motion all look and play like the real game. This replaces the earlier "light rotation" call.

- **The lineup:** six on the court, with the standard roles: two outside hitters, two middles, an opposite and a setter in a 5-1, or two setters and two outsides in a 6-2 (below). A libero replaces each middle when that middle rotates to the back row.
  - The libero comes in for the back-row middle automatically. It never serves, attacks above the net or sets with fingers in front of the 3 m line, as in FIVB rules **(Claude's call)**.
- **Rotation:**
  - Six rotations. The team rotates clockwise each time it wins the serve back (a side-out), and the player rotating into right back serves.
  - The rotation is part of the shared game state, so the server and every client always agree on who is front row and who is back row.
  - Back-row players can't block, and they can only attack from behind the 3 m line (the pipe or a back-row "D" ball). Front-row players attack and block.
- **Serve receive:**
  - In every rotation, the receiving team lines up in a real stack, legal for the overlap rule at the moment of the serve. It hides the setter and puts the libero and the outsides in the passing lanes.
  - The setter releases from the stack to the target as the serve is struck. Hitters release to their approach spots, and the outside, opposite and middle switch into their own positions once the serve is contacted.
  - The serving team also switches at contact: the setter goes to right side, the middles to the middle, and the outsides to the left.
  - The AI always lines up legally, so there are no overlap faults in the game. A subtle line on the floor shows each player's spot for the people who want to learn **(Claude's call)**.
  - The builder works out each rotation's receive pattern from how high-level teams line up, with three passers (the libero and both outsides) by default.
- **Movement:**
  - Every player moves with real footwork: transition off the net after blocking, a real approach (three or four steps) for every attacker, block footwork (shuffle and crossover), setter penetration from the back row, coverage around the hitter, and base defense positions.
  - The AI runs all of it. You never steer a player across the court. Your touches decide the ball, and the team moves around it.
  - **Defense (Claude's call):** perimeter defense by default, with the libero in left back and the off blocker pulling off the net for tips and short shots. The defensive read (§4.3) shifts the block and the diggers within that system.
  - Movement must stay fast. Players need to reach their spots in the time the ball gives them, so the builder may speed up footwork above real speeds, as it does with the ball.
- **Team systems in an advanced team settings menu (JD, 2026-11-26):**
  - **5-1 (default):** one setter in all six rotations. In three rotations the setter is front row, leaving two front-row hitters plus the setter's dump. In the other three, three front-row hitters.
  - **6-2:** two setters opposite each other in the rotation. Whichever is in the back row sets, and the front-row one hits as the opposite, so there are always three front-row hitters.
  - **Starting rotation (Claude's call):** which rotation the team starts in, the way coaches pick a starting rotation to match up.
  - The menu is tucked away under "Team" before a match, with the 5-1 and rotation 1 as defaults. Nobody has to open it. Online, each team's humans pick their own team's settings, and the last change wins.
  - Later options, not now: a 4-2, two-passer receive, and rotational defense.
- **Readability with real rotation:**
  - Players change spots all the time now, so each player shows a small role tag (OH, MB, OPP, S, L) above them, easy to read at phone size.
  - Set labels name the hitter's role and play, not a fixed spot.
  - The set compass is drawn from where the hitters actually are when the set happens, so the swipe always points at the hitter.
- **Control: pick your player in the huddle, switch any time (JD, 2026-11-26).**
  - In the huddle (§4.3) you see the current rotation and tap the player you'll play. The pick sticks from play to play until you change it.
  - **The pick follows the person, not the spot (Claude's call).** If you pick the outside hitter, you stay on that outside as the team rotates. When the libero subs in for your middle, you're moved to the libero for those rotations, and back to the middle when they return.
  - **What you do:** your player's fast timing touches. That's their serve, pass or dig, set, attack and block jump, with the gestures in §4.2. If you miss the timing or don't touch at all, your player shanks it or misses, just as a mistimed touch would.
  - **What the AI does:** everyone else's touches, and all movement, including your player's. It plays to your coaching: the play calls, the defensive read, and the team systems.
  - **Switching mid-rally:**
    - A strip of your six teammates' role tags along the bottom of the screen. Tap one to become that player right away **(Claude's call)**.
    - A "ball" chip at the end of the strip jumps you to whoever touches the ball next on your side.
    - Taps on the strip never count as timing taps.
    - On a controller, the shoulder buttons cycle players and one button jumps to the ball.
    - A switch lasts until the next huddle. The huddle then shows your pick again, so a switch never quietly changes your plan **(Claude's call)**.
  - **Follow the ball (Claude's call):** the huddle also offers a "ball" pick. With it, you play whoever is about to touch the ball, which means every touch on your side. It's the default for new players and the tutorial, so a beginner never waits through a rally doing nothing. Picking a player is how you play a position for real.
  - The white arrow is always over the player you control right now.
  - **With two humans on a side (Claude's call):**
    - The two humans can't pick the same player. Each makes their own player's touches.
    - If one human picks "ball", they play every touch on the side that isn't the other human's player.
    - If both pick "ball", they alternate touches: each touch goes to the human who did *not* make the side's last touch.
    - Either human can make the defensive read, and the last read wins.
  - **Who owns a touch:** each touch belongs to whoever controls that player when the ball's flight toward it starts, and the server decides. A switch after that applies from the next touch. The netcode's timing judgment depends on this.
  - **Streaks belong to players, not people:** on fire counts for the *player* who touched the ball, whoever was controlling them. So bots can catch fire too, and the spike already showed that's fun. The middle can catch fire on kills like any hitter.
- **Match format (Claude's call):** one set to 15, rally scoring, win by 2. That's about 5–8 minutes. Best of 3 is an option for private rooms.
- **Speed setting:** three tempos (Fast / Faster / Stupid Fast), carried over from the spike. Online rooms choose one for everyone.

### 4.2 Touches: one gesture each

The aim-by-location gestures for serves and spikes come from playtest 2, which replaced swipe-direction aiming after JD found it ambiguous.

| Touch | Gesture | What decides the outcome |
|---|---|---|
| Serve | Hold to toss, drag onto their court to aim, let go at the top of the toss | Release timing against the contact moment, and the aim spot. A quick tap is a safe float serve |
| Pass / dig | Tap as the ring closes on the ball | Timing. Pass quality decides which sets are possible |
| Set | Swipe toward a hitter (a compass around the setter matches where the hitters stand). Tapping a hitter label also works **(Claude's call)** | Which hitter. Timing affects set quality. A bad pass greys out the quick |
| Spike | Touch their court where you want the ball, drag to adjust, let go to hit | Release timing and spot. Aiming near the net makes it a tip or roll shot |
| Block | Tap while their set is in the air, and your blocker jumps right away | Jump timing, plus your defensive read (below) |
| Defensive read | While the other team passes and sets, swipe or tap toward the hitter you expect | Shifts your block and back-row defense toward that hitter (below) |

Timing grades come from the spike: PERFECT ≤ 60 ms, GOOD ≤ 130 ms, EARLY/LATE ≤ 250 ms, and anything worse is a miss. A short grace window lets a slightly late input still play the touch. The builder tunes the numbers on device.

### 4.3 Strategy: huddle, play calls, changing the call, reading

This is JD's direction, modeled on how the high-level game runs. The play catalog differs between the men's and women's games (§4.7).

- **Huddle (between rallies):**
  - During the dead time after a point, a quick huddle overlay shows your side's current rotation, drawn top-down with the six players at their serve or receive spots and their role tags (JD, 2026-11-26).
  - **Tap a player to play them** (§4.1), or tap "ball" to follow the ball. Your current pick is lit.
  - **Pick the plays as the setter:** a play call for each attacker who can hit in this rotation, the front-row hitters and the back-row pipe or D ball. You make the calls whoever you're playing, because you're coaching the team.
  - Who can hit changes with the rotation. In a 5-1 with the setter in the front row, there are two front-row hitters and the setter can dump. Otherwise there are three.
  - Each attacker has a few play options, named with the calls US teams use: 4, Go, 32 and Hut for the outside, 1, 31, Back 1 and Slide for the middle, 5 and Red for the opposite, and Pipe, Bic and D in the back row. The full catalog and how it's drawn are in §4.8 (JD, 2026-11-26).
  - Your last pick and the team's last calls stay as the defaults, so doing nothing is always fine. The huddle closes on its own after a few seconds (the builder tunes it, about 3–5) and never pauses the game.
  - Calls are a few big taps, with no nested menus.
  - With two humans on a side, each picks their own player, either can change the calls, and the last change wins **(Claude's call)**.
- **What a call does:** it sets each hitter's approach path and the tempo and location of the set they'll get. The AI runs the hitters to the call, and the set compass shows that play's options.
- **Who sets:** if you're playing the setter, your swipe picks the hitter, and it can always go to a different hitter than the call, because every hitter running their route is a live option. If an AI setter is setting, it picks among your calls from the pass quality and where the blockers are, the way a good setter does.
- **Changing it mid-rally:**
  - Switch to the setter (§4.1) to make the set yourself.
  - The HUD shows where the other team's blockers are standing, so you can set away from the block.
  - Pass quality limits the options, as in the real game. Fast tempos need a good pass.
- **Defensive read:**
  - When the ball crosses to the other side, you swipe or tap toward the hitter you think will get the set. Your front-row blockers lean or bunch that way, and the back row shifts.
  - A right read raises your block and dig odds. A wrong read opens a gap the other hitter can kill.
  - The AI offense mixes its sets so reading pays off without being a sure thing.
  - The AI defense reads too, influenced by the pass quality and the calls the human has been making.

### 4.4 On fire, celebrations, presentation

- **On fire:** a hitter with 3 kills in a row, or a libero with 3 perfect passes or digs, catches fire. It ends when the other team scores.
  - On-fire hitters hit faster and harder, and are harder to stuff.
  - On-fire liberos cover more ground and pass perfectly.
  - Flames, a ball trail and a banner show it.
  - These rules come from the spike, and the builder tunes them.
- **Celebrations:** slow motion on the last moments of a kill, camera shake, a close-up of the hero, teammates mobbing, and big banners (KILL, ROOF, ACE...).
- **Camera:**
  - Behind the server for the serve, swooping on attacks, and a wide sideline shot otherwise.
  - The playtests showed the camera has to keep the other team's court visible during aimed touches, because you aim on it.
- **Readability (lessons from the playtests):**
  - A white arrow over the player you control right now.
  - The switch strip of role tags along the bottom edge, with your current player lit.
  - Small role tags (OH, MB, OPP, S, L) over every player, because spots change with the rotation.
  - A white timing ring that turns green at the perfect moment.
  - A white aim reticle with a line from the hitter.
  - Faint markers where incoming balls will land.
  - Set labels at the hitters.
  - Team colors only on jerseys. Each signal has one look, and no two signals share a color.
  - Players tell apart at a glance (JD, 2026-11-26), described under Players below.
- **Haptics** on every touch, scaled by power and quality.
- **Audio:** crowd, ball, net, and an original announcer voice with short, punchy lines. Where the sound comes from is the builder's call, within the anti-goals.
- **Players (JD, 2026-11-26):** no two players on a team look alike, so they never run together on the court.
  - **Jersey numbers** on the back and front, big enough to read at phone size, and on the shorts. Each roster has its own numbers, and the switch strip and huddle chips show the number next to the role tag (#7 OH).
  - **Skin tones** across the full human range on every team, in both the men's and women's games.
  - **Heights and builds** like a real roster: middles and opposites tallest, liberos and setters often shortest. Roughly 1.78–2.08 m for men and 1.68–1.93 m for women, tuned for readability.
  - **Hair and gear:** hairstyles, headbands, sleeves, knee pads and shoe colors vary, so a player is recognizable even from the back.
  - **The libero** wears a contrasting jersey, as the rules require.
  - **Height matters a little in play (Claude's call):** taller players reach higher on the block and attack, and shorter ones move a step quicker. The effect is small, so every player is still worth playing.
  - **Rosters (Claude's call):** each team is a generated roster of original players, each with a name, number, look and traits (§4.9). Never real athletes. Teams are generated fresh for solo games and kept per room online, and a career mode could keep them later.
- **Art:** stylized, readable and original low-poly characters and an arena. They must read clearly at phone size with 12 players on screen.
  - Real court movement means a lot of animation: approaches, jumps, block footwork, shuffles, dives, transitions and switches, for both men's and women's players. That is the biggest art cost in the game, and the art plan has to start from it.

### 4.5 Tutorial

The tutorial runs on first launch and can be replayed. It walks through one touch at a time in a scripted rally. As each touch comes up, the game drops into bullet time or pauses, shows the gesture, and waits for the player to do it. Then it repeats at full speed. It ends with a short real rally against easy bots. The huddle (picking your player, picking plays) and the defensive read get their own short lessons. The tutorial uses the "ball" pick, so you play every touch while you learn, then shows how to pick a position and switch. One short lesson pauses a serve-receive stack and shows how the team releases to its spots, so the role tags make sense. It's optional, for players who don't already know rotations.

### 4.6 Modes

- **Solo:** you and bots against bots, at a difficulty you pick (§4.9).
- **Local:**
  - One device runs the game. That's a phone, or the Apple TV as a shared court with phones as controllers.
  - Phones on the same Wi-Fi join by QR or link.
  - **What a phone shows in TV mode (Claude's call):** a simple 2D top-down court. You tap or drag on it to aim, swipe for sets and reads, and see your prompts and timing ring. It also plays haptics and your own audio cues. The 3D court is drawn only on the TV.
  - **TV plus online friends (Claude's call, milestone 3):** an Apple TV can also join an *online* match as a draw-only screen, the way Pounce's TV joins as `role=screen`. The phones in that living room play as online clients. The server is in charge either way, so this costs little.
- **Online with friends:**
  - A private room through an invite link or QR.
  - Up to 2 humans per side, with bots in every empty spot.
  - Humans can be opponents or teammates.

### 4.7 Men's and women's games

Players pick a men's or a women's game (JD, 2026-11-26). How the two differ is Claude's call, and the builder tunes it.

- **Who picks:** the room's creator, before the match, next to the tempo. Solo and local games pick it the same way. Both teams play the same game type. Each device remembers the last choice.
- **Net height:** 2.43 m for the men's game and 2.24 m for the women's, the real heights. This changes block reach, how high the hitters' contact is, and the angles a spike can take.
- **Pace:** the women's game has slightly slower serves and attacks, so rallies are longer and more digs come up. The tempo setting still applies on top, so "Stupid Fast" is fast in both.
- **Offense:**
  - The men's game leans on jump serves, the 1 and 31 quicks, the Pipe and Bic, and big swings on the 4 and 5.
  - The women's game leans on the Slide behind the setter, Go and Hut tempo to the outside, Red to the right side, float serves, and more tips and roll shots.
  - So the huddle offers each game its own play catalog and defaults. The AI sets and reads with that game's habits.
- **Defense:** in the women's game the back row digs more, and the libero matters even more. On-fire rules stay the same, so a hot libero is as big a deal as a hot hitter.
- **Players:** men's and women's player models, animations and celebrations. Original art in both, equally readable at phone size. This doubles the character art, which the art plan has to budget for.
- **Same everywhere else:** gestures, timing grades, the huddle, the defensive read, the camera, the HUD and the netcode. The game type is part of the match settings in the shared state, so SpikeCore holds both rule sets and the server and clients always agree.

### 4.8 Play calls: real names, shown on the court

Plays use the names US teams call (JD, 2026-11-26). There's no single official USA Volleyball list, and clubs differ on a few calls. So Spike Jam picks one meaning per name from common US usage and keeps it consistent everywhere **(Claude's call)**.

**How the numbers work:** the common US number system, popularized by the USA men's team in the 1980s.
- The net is split into nine zones about a meter wide, 1 at the left antenna to 9 at the right antenna, from the attacking team's view.
- A two-digit call is zone then height: "31" is a quick (height 1) in zone 3, and "32" is a little higher in zone 3.
- One-digit calls are the everyday shorthand: a "1" is a quick right in front of the setter, a "4" is the high ball to the left antenna, and a "5" is the high back set to the right antenna.

**The catalog (Claude's call, from common US usage):**

| Hitter | Calls | What it is |
|---|---|---|
| Outside (left front) | **4** | High ball to the left antenna. The safe default, and the out-of-system ball |
| | **Go** | Faster outside set to the antenna (second tempo) |
| | **Hut** | Fastest outside set, low and flat (first tempo) |
| | **32** | A quicker ball inside the antenna, between zones 3 and 4 |
| Middle | **1** | Quick right in front of the setter |
| | **31** | Quick in the gap, zone 3, away from the setter |
| | **Back 1** | Quick just behind the setter |
| | **Slide** | One-foot approach behind the setter toward the right antenna |
| Opposite (right front) | **5** | High back set to the right antenna |
| | **Red** | Fast back set to the right side |
| Setter (front row only) | **Dump** | The setter attacks the second ball |
| Back row | **Pipe** | Back-row attack through the middle, from zone 6 |
| | **Bic** | A faster, lower pipe, set off a good pass |
| | **D** | Back-row attack from right back, zone 1 |
| | **A** | Back-row attack from left back, zone 5. Rare, as in the real game |

- **Combinations (Claude's call):** a few team calls that set several hitters at once.
  - **X:** the middle runs a 1 and the outside crosses behind for a 32.
  - **Tandem:** the middle runs a 1 and another hitter comes right behind for a 2-height ball in the same spot.
  - **Slide-Red:** the middle slides while the opposite runs Red, so two attackers hit the right side.
- **What you can call depends on the rotation and system.** Only hitters who can attack in this rotation get calls, back-row players only get back-row calls, and Dump only shows when the setter is in the front row.
- **The pass decides what's live.** First-tempo calls (1, 31, Back 1, Hut, Bic) need a good pass. Off a bad pass they grey out, and the AI and your swipe fall back to the 4, 5, Pipe or D.
- **Men's and women's defaults** come from §4.7: for example 4, 1, 5 and Pipe for the men's game, and Go, Slide, Red and Pipe for the women's.

**Shown on the court:**
- **In the huddle:** the rotation diagram has a faint strip along the net numbered 1–9. Each hitter has a chip with their call ("31", "SLIDE", "BIC"). A white dashed line runs from their spot to where they'll take off, ending in a small arc over the net zone the set goes to. The arc's height shows the tempo, low for a quick and high for a 4 or 5, so you can see the play without knowing the numbers.
- **Picking a call:** tap a hitter's chip to cycle through their calls, or tap a combination to set several at once. A long press shows a one-line meaning ("31: quick in the gap, zone 3").
- **During the rally:** the set labels over the hitters show their calls ("SLIDE", "PIPE"), and the set compass shows the same names. A grey label means that call isn't live off this pass.
- **Flavor:** before serve receive, the AI setter flashes their calls behind their back with original hand signs, as real setters do. It's for show and teaches nothing you need.
- **Learning the names:** the tutorial's huddle lesson explains the 1–9 zones and three calls (4, 1, Pipe). A glossary of every call sits under "Team" next to the systems.
- The look follows §4.4's readability rule: route lines and arcs are white, with tempo shown by height and never by color.

### 4.9 AI that plays like people, and catch-up

**Imperfect, varied AI (JD, 2026-11-26).** Real players aren't perfect, so the AI isn't either. How it works is Claude's call, and the builder tunes it.

- **Each player has traits:** serving, passing, setting, attacking, blocking, defense and speed, with a little personality: a big server who misses more, a steady passer, a hitter who loves the line. Traits come from the roster (§4.4), so players on the same team play differently.
- **Every AI touch is rolled, not perfect:** pass quality varies, sets drift tight or off the net, swings go out or into the net, and blocks get tooled. Serves miss at roughly real-game rates, which are higher in the men's game, where everyone jump serves.
- **Decisions vary too:** AI setters don't always pick the best hitter, hitters sometimes tip when they should swing, and AI defenders sometimes read the wrong hitter.
- **Mistakes look human:** shanked passes, overpasses, a ball dropping between two players, a net touch. Each has its own animation.
- **Difficulty (Claude's call):** solo games offer three levels, with names chosen by the builder. The level moves the AI's average quality, not its variety: easy AI still makes good plays, and hard AI still errs.
- **Your AI teammates** use the same traits and rolls, so they're imperfect too. Their mistakes stay fewer than the other side's at easier levels, so a beginner isn't let down by their own team.

**Catch-up against the AI (JD, 2026-11-26).** Like rubber-banding in kart racers, a hidden catch-up keeps matches against the AI close, so your own per-touch timing decides who wins. How it works is Claude's call:
- **It only changes AI touches and AI decisions,** on both teams. Your own touches are never helped or hurt: the timing windows and what a PERFECT does stay the same at every score. That keeps your skill the deciding factor.
- **It follows the score:** when your team trails, the opposing AI errs a little more and plays a little safer, and your AI teammates play a little better. When your team leads, the reverse. It starts at about a 2-point margin and grows with the gap.
- **It is bounded,** so it narrows a gap but never flips one. A clearly better player still wins, just not 15–2, and a weaker one still loses, but in a close match.
- **It's invisible.** No meter, no announcement, and no surprise bonuses at game point. Each change is small enough that a single rally never looks rigged.
- **Where it applies (Claude's call):**
  - On by default whenever only one side has humans, which covers solo and you-and-friends against the AI.
  - Off by default when there are humans on both sides. A room setting, "Keep it close", turns it on for family games, such as a parent against a kid, and there it adjusts only the bots on each side.
- **It's part of the shared state.** The catch-up level is computed from the score inside SpikeCore, so the server and clients always agree and prediction still works.
- **Tested headless:** the bot-vs-bot runner (§5.5) plays matches with simulated "humans" of different skill. It checks that margins stay close, that better timing still wins most matches, and that no rally looks rigged.

## 5. Architecture

### 5.1 Parts

- **SpikeCore** (Swift package, no Apple-only frameworks, builds for iOS, tvOS, macOS and Linux) holds the whole game:
  - rules and AI
  - ball flights
  - input model
  - fixed-step simulation
  - serialization
  - It has no rendering, timing or I/O.
- **SpikeNet** (Swift package) holds the protocol messages, the client's prediction-and-replay loop and the server loop. It wraps a small C transport (below).
- **App** (iOS/tvOS/macOS): RealityKit rendering, SwiftUI HUD and menus, touch and controller input, haptics and audio. It never changes game state directly. It only feeds inputs to the client loop and draws what the client loop says.
- **Match server:** a Linux executable built from SpikeCore and SpikeNet with Swift's static Linux SDK, shipped as a small container. One long-running process hosts many matches at once, each on its own fixed-step loop **(Claude's call)**. Running it with one match per process later, for GameLift, is a setting, not a rewrite.
- **Lobby service:** a separate Spike Jam Cloudflare Worker and Durable Object that copies Pounce's room and join code (Claude's call). It doesn't touch Pounce's live service. It handles rooms, invites, QR joining, team picks and the age band. It also picks a match server and issues connect tokens.

### 5.2 Simulation

- Fixed 60 steps per second. Rendering runs at the display rate (120 Hz on ProMotion) and draws between sim steps.
- The whole game state is one value type that is cheap to copy. It includes the rotation, the team systems, and every player's position, velocity and current movement goal.
- Player movement is a steering model inside SpikeCore (targets, speed limits, approach and block footwork), so it is predicted and replayed like everything else. Animation only plays it back. A ring buffer keeps about the last second of states for rewinding.
- Ball flights are analytic, as in the spike: each touch produces a flight from its parameters, so replaying is cheap.
- All randomness comes from a seeded generator stored in the state. That way predictions usually match the server.
- Exact bit-for-bit determinism across devices is **not** required. The server's snapshots correct any drift, so phones and servers with different chips are fine.
- Inputs are keyed by sim step and player. Touch inputs say which upcoming contact they're for, the timing offset and the aim spot.
- The spike's `Sim.swift` holds the touch rules and tuning to port, but it runs on continuous time and isn't shared code. SpikeCore is new code.

### 5.3 Online model: the server is in charge, clients predict and replay

This is modeled on Rocket League's and Overwatch's published designs. Madden, NBA 2K and EA FC don't publish theirs.

- **The server** runs the game and the bots at 60 steps per second.
  - It keeps a small buffer of inputs for each client, targeting 1–2 steps.
  - It tells each client to speed up or slow down slightly so the buffer stays right, which is Rocket League's technique.
  - About 30 times a second it sends each client a snapshot: the full game state, which is a few hundred bytes, plus the confirmed inputs since the last one.
- **Each client** runs ahead of the server by about half a round trip plus the buffer, so its own inputs arrive just in time.
  - When a snapshot arrives, the client restores it at that step, then replays its unconfirmed inputs to the present.
- **Your own touch** plays instantly on your phone: the ball leaves, you feel the haptic and the camera reacts.
- **The server judges timing in the toucher's favor.** Each touch belongs to at most one human (§4.1), so the server grades it against the contact moment as that human saw it.
  - The server accepts it if it arrives within a cap of about 150 ms (tunable). If needed, the server rewinds itself to the contact step and replays, which is cheap.
  - Past the cap, the touch counts as a miss and the toucher's phone corrects.
- **Other players' touches** reach a client about a round trip late. The client rewinds to the contact step and replays.
  - The ball's drawn position eases from the old prediction into the corrected one over about 100–200 ms. That's the visible rubberbanding.
  - The ball is in the air for 0.4–1 s, so the correction lands early in its flight.
- **Bots and AI** are predicted on every client from the shared state, so they rarely need correcting.
- **Huddle calls, team picks, ready and rematch** go over the reliable channel. Time-critical inputs go unreliable, and every packet repeats the last several steps of inputs, so a lost packet costs nothing.
- **Clashing touches (Claude's call):**
  - A block is committed when the blocker jumps, which is during the set. So the attacker's phone already knows about the jump before the spike.
  - The server decides block outcomes when the ball crosses the net, and decides points when the ball lands.
  - Clients show their predictions right away. But kill banners, point celebrations and score changes wait for the server's confirmation, which the slow motion on kills hides.
  - So a predicted kill that turns out to be a stuff shows as the ball being stuffed, never as a celebration that gets taken back.
- **Dropped player:** the AI takes over their player at once. They can rejoin the same team and pick again in the next huddle **(Claude's call)**.

### 5.4 Transport and hosting

- **Transport (Claude's call):**
  - UDP with Glenn Fiedler's `netcode` (encrypted connections with connect tokens issued by the lobby) and `reliable` (an acked reliable channel on top). Both are small C libraries that build for iOS, tvOS, macOS and Linux.
  - Fallback: ENet, which is simpler but has no built-in encryption.
  - Valve's GameNetworkingSockets was rejected because it is heavy to build for iOS.
  - Packets stay under a typical MTU so nothing fragments.
- **Match hosting to start: JD's existing Hetzner VPS servers in Hillsboro, Oregon (JD, 2026-11-26). The setup is Claude's call.**
  - **Which box:** a Hetzner cloud server in Hillsboro, Oregon that JD already pays for and isn't using. Its name, access and operating rules are kept in JD's private operations notes, not in this public repo.
  - **Rules for the box:** its price is grandfathered, so it is never resized or deleted. Cleaning up what still runs on it, or rebuilding it, happens only with JD's OK. Spike Jam gets its own Hetzner firewall rather than changing an existing one.
  - The box runs the match server container, always on, with Docker's restart policy and host networking so UDP goes straight to the process. Spike Jam's firewall opens one UDP port for the game, plus SSH. Nothing new is bought.
  - Every match starts instantly, because the process is already running and a match is just a new loop inside it.
  - Each server checks in with the lobby every few seconds over HTTPS with its load and health. The lobby places a new match on the least-loaded healthy server, then hands the clients its address and a connect token.
  - One 60-step match is light (a small fraction of a CPU core), so one small VPS should hold dozens of matches. The real number gets measured, and the server refuses new matches past a limit.
  - Deploys: build the Linux image, push it to a registry, then pull and restart over SSH. A restarting server first stops taking new matches and lets running ones finish, which takes at most about 10 minutes.
  - **Latency:** Oregon is well placed for US players. The West Coast sees about 20–40 ms round trips and the East Coast about 70–90 ms, all well under the roughly 150 ms lag cap. Players in Europe or Asia would be near the edge. A second region is a scale-later question.
  - The match server keeps nothing on disk: no names, no logs of who played. It only keeps the match in memory while it runs (§5.6).
- **Hosting for scale later: JD's AWS account, with Amazon GameLift Servers managed container fleets (Claude's call, not built now).**
  - Matches go onto match server processes that are already running, placed by player latency across regions, with health checks and scaling handled by GameLift.
  - It costs money around the clock for idle processes in each region, so it waits until there are crowds.
  - Moving there means linking the GameLift server SDK (C++, called from Swift through C++ interop) and having the lobby ask GameLift for a session instead of picking a server itself. The protocol and clients don't change.
  - Not chosen for AWS: Fargate tasks started per match (a cold start for every match), and Lambda and App Runner (no inbound UDP). An always-on ECS service would be the same setup as Hetzner, at AWS prices.
  - Fly.io Machines and Edgegap were the other options considered.
- **Local mode:**
  - The host device runs the same server loop in-process and speaks the same protocol over UDP on the local network.
  - Bonjour handles discovery, and the lobby handles the QR and link flow.
  - The Apple TV is a host that only draws the court. Phones are its controllers and show the player's own prompts.
- **Identity (Claude's call):** a display name plus a device ID at first, with the age band from §5.6. Under-13 players get a generated name. Sign in with Apple for adults when accounts matter, as in Pounce.

### 5.5 Testing

- SpikeCore unit tests run on macOS and Linux.
- A headless bot-vs-bot match runner tests balance and finds crashes (the spike's autoplay harness, grown up). It also measures AI error rates against real-game rates and checks the catch-up (§4.9).
- A network test rig that adds delay, jitter and packet loss, so prediction, replay and smoothing can be judged at 50, 100 and 200 ms round trips with 1–5% loss.
- Feel is tested on JD's iPhone at every milestone.
- The lobby's age-band rules get tests like Pounce's Miniflare tests: a child's device can't create share links or set a typed name, and the server refuses what the band doesn't allow.

### 5.6 Kids under 13

JD's direction is to support kids the way Pounce does (2026-11-26). The pieces are copied from Pounce's design (`~/src/pounce-tv/docs/superpowers/specs/2026-11-05-parent-consent-design.md`, `docs/privacy/`, `docs/app-review-notes.md`). How they apply here is Claude's call, and none of this is legal advice.

- **Age band at first launch:** the app asks Apple's Declared Age Range. If the person doesn't share, it asks for a birth year. Only the band is kept (under 13, 13–17, 18 and over), never the birth date. It is the same flow and wording as Pounce.
- **What an under-13 device can do:**
  - Play solo, local and online games with friends.
  - Join a room by typing its code or scanning its QR on the TV or a friend's phone.
- **What it can't do:**
  - Type its own name. It gets a generated volleyball nickname from a list, with dice to reroll, like Pounce's generated cat names.
  - Create or send share links, or sign in.
  - Receive push notifications.
  - There is no chat for anyone (§2), so there's nothing to turn off there.
- **Why no parent consent is needed at first:** with these limits, Spike Jam collects nothing from a child beyond what playing needs. That's a generated name, the age band, a device ID, and the network address the match server sees while it runs. Nothing is public, and there are no strangers.
- **Pounce's consent flow is the pattern** for when Spike Jam adds something to a child's device that needs it: pushes ("your friend started a game"), friend lists, or invites sent by kids. That flow is a parent linked by code, text plus through Twilio Verify, PermissionKit approvals, and revoking. Adding one of those is a significant change under the Texas law and goes back to counsel, as in Pounce.
- **Not "Made for Kids":** like Pounce, it's for families and players of all ages, not for children on their own. That keeps it out of the Kids Category rules **(Claude's call, matching Pounce)**.
- **Before the first App Store release:**
  - A privacy policy and App Store privacy label drafted from what the code does, kept in step with the privacy manifest by a test, as in Pounce.
  - A retention policy (the match server keeps nothing; the lobby deletes idle devices after Pounce's 90 days).
  - App Review notes explaining the age flow.
  - Counsel reviews all of it.
- **Where data lives:** the match server is in Oregon and keeps nothing, and the lobby is on Cloudflare like Pounce's.

## 6. Milestones

The order is Claude's proposal. Each milestone ends with JD playing it on device.

**First prototype (JD, 2026-11-26):** before the milestones are finished, a TestFlight build that JD and his son can play on two phones on the same Wi-Fi. That pulls the local two-phone mode from milestone 3 forward, right after the core game is playable. The project is open source (MIT, Conley Chaos LLC) at github.com/jdconley/spike-jam, so CI runs on free GitHub runners like Pounce's.

1. **Core game, solo:**
   - SpikeCore with the new fixed-step sim, all touches, the huddle and play calls, the defensive read, on fire, the camera and the tutorial.
   - Real rotation: six rotations, serve-receive stacks, switching, the 5-1 and 6-2, the libero, and the advanced team settings menu.
   - Real court movement: approaches, block footwork, transition, coverage and perimeter defense.
   - The men's and women's games, with both play catalogs and net heights.
   - Imperfect AI with player traits, difficulty levels, and the catch-up against the AI.
   - A first real art and audio pass, with men's and women's players, jersey numbers, and a range of skin tones, heights and builds.
   - The game already runs through the client and server loops in one process (loopback), so it's ready for networking from day one.
2. **Online with friends:** the match server container on JD's Hetzner box in Oregon, lobby and invite links, the age band and under-13 limits, prediction, replay and smoothing, the network test rig, and dropped-player handling. The privacy work in §5.6 is finished before the first public release, whichever milestone that is.
3. **Local and Apple TV:** in-process host on a phone or the Apple TV, phones as controllers, and Bonjour discovery.
4. **Mac with controller, and iPad layout.**

## 7. Approaches considered

**Engine**
- Godot (Claude's first recommendation): cross-platform, including PC and Android.
- Swift + RealityKit: **JD's pick.** Native feel, Apple TV and haptics, at the cost of being Apple-only.

**Rotation**
1. A light version with fixed spots, so each human's player kept one role (Claude's first call): simpler to read, but not the real game.
2. **Real rotation, stacks and court movement:** **picked (JD).** It plays like the real game, and the role tags and set compass keep it readable.

**Control**
1. Every touch is yours, with control following the ball (the spike's model): the most action, but you never feel like a position. It survives as the "ball" pick.
2. One fixed player for the whole match: simple, but you may wait through rallies, and it fights real rotation.
3. **Pick your player in the huddle, AI plays to your coaching, switch any time:** **picked (JD).** You choose your role, the strategy matters, and switching keeps you in the action.

**Online model**
1. **The server is in charge, clients predict and replay** (Rocket League / Overwatch style): **picked.** Instant local touches, the server stays authoritative, and the cost is the complexity of replaying.
2. The server is in charge and clients only show snapshots, with no prediction: simple, but every one of your own touches would wait a full round trip. Rejected for a timing game.
3. Everyone's touches wait for the slowest connection, with a relay server (classic lockstep): every touch is delayed by the worst connection. Rejected.
4. Phone-hosted over the internet with a relay: one codebase and cheap, but JD wants the server in charge online. It survives as local mode only.
5. A TypeScript server sim (the Pounce pattern): it would be a second copy of the rules. Rejected.
6. The Swift sim compiled to WebAssembly and run on Cloudflare: experimental, and it can't take UDP. Rejected.

**Match hosting**
1. **An always-on server on JD's Hetzner box in Oregon, many matches per process:** **picked (JD: cheap first, use the Hetzner servers).** Nothing new to buy, instant starts, and we do our own placement in the lobby.
2. GameLift managed containers on AWS: latency-based placement and scaling across regions, but idle processes cost money around the clock. Kept as the path for scale.
3. An always-on ECS service on AWS: the same shape as 1, at AWS prices.

**Shared code language**
- Swift for the core and C only for transport: **picked (Claude's call).** One language for gameplay, and fast iteration on feel.
- C++ for the core: the proven AAA choice, but two languages and slower feel tuning.

## 8. Left to the builder

- All tuning numbers: timing windows, odds, speeds, the lag cap, the smoothing duration and the buffer targets.
- AI trait ranges, error rates, difficulty levels, and the catch-up's start point, curve and bound, within §4.9.
- The roster generator's names, numbers, looks and height ranges, within §4.4.
- The final play list and each play's exact tempo, height and approach route, within §4.8. The huddle's visual design, within §4.3 and §4.8.
- The switch strip's exact look and the controller button mapping, within §4.1.
- Each rotation's serve-receive pattern for the 5-1 and the 6-2, the base defense spots, and the footwork speeds, modeled on the high-level game.
- The art and audio pipeline and sources, within the anti-goals.
- How SpikeCore's state, packing and replay are organized internally.
- How the C transport libraries are integrated, how many matches the Oregon box takes, and the deploy scripts.
- The exact speed and odds differences between the men's and women's games, and the generated nickname list.
- HUD layout details, within the readability rules in §4.4.
