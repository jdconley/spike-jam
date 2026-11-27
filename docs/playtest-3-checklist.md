# Playtest 3 checklist

The first build of the real app: a solo match against the AI, driven by SpikeCore, with the huddle,
switching, timed touches and the HUD. Install it from TestFlight (or `scripts/device.sh` from a Mac).
Play a few matches and note anything that feels off. Short notes are fine.

## Getting in

- [ ] The start screen: pick **Men's** or **Women's**, a speed and a level, then **PLAY SOLO**.
- [ ] Under **TEAM**, try a **6-2** and a different starting rotation once.
- [ ] **WATCH A BOT MATCH** still plays on its own.

## The huddle (before every serve, about 4 seconds)

- [ ] Your side's rotation shows top down, net at the top. Do the chips make sense?
- [ ] **Pick a player**: tap a chip. Does the white arrow then stay over that player through the rally?
- [ ] **BALL**: you play whoever touches the ball next on your side. Is that a good default for a new player?
- [ ] **A play call**: tap an outside's call chip to cycle 4 → GO → HUT → 32. Does the set go where you called?
- [ ] Long-press a call chip: the one-line meaning shows. Readable?
- [ ] **GO!** closes the huddle early for you. Is 4 seconds long enough to pick and call? Too long?

## Switching mid-rally

- [ ] Tap a chip on the strip along the bottom: you play that player from the next touch.
- [ ] Tap **BALL** on the strip mid-rally.
- [ ] Do taps on the strip ever count as a pass or a block by mistake?
- [ ] After the rally, the huddle shows your huddle pick again, not the switch.

## Each touch

The ring closes on the moment to act and turns green at perfect. Each touch flashes its grade.

- [ ] **Serve**: hold to toss, drag onto their court, let go when the ring closes. Is the aim spot where the ball goes?
- [ ] **Float serve**: a quick tap. It should always go in.
- [ ] **Pass**: tap as the ring closes. The faint marker shows where the ball comes down.
- [ ] **Set**: swipe toward a hitter, or tap their label (the labels show the play names; grey means not live off this pass).
- [ ] **Spike**: touch their court where you want it, drag, let go when the ring closes. Aim near the net for a tip.
- [ ] **Block**: tap while their set is in the air. Does the jump feel on time?
- [ ] **Read**: while they pass and set, tap or swipe toward the hitter you think gets the set. Did you notice the block move?
- [ ] **Dig**: tap as the ring closes.
- [ ] Does the camera always show their court while you aim, with nothing on screen covering it?
- [ ] Haptics: a crisp tap for perfect, softer for early or late, a heavy thump on kills and roofs.

## The game

- [ ] Play the **women's game** once: longer rallies, more digs, Slide and Go as defaults.
- [ ] Try each level (**Easy**, **Medium**, **Hard**). Does each feel different?
- [ ] Each speed (**Fast**, **Faster**, **Stupid Fast**). Is Stupid Fast still playable?
- [ ] **Catch-up**: did the AI ever feel like it was letting you win, or running away from you? It should feel invisible.
- [ ] Banners: **KILL**, **ROOF**, **ACE**, **ON FIRE**. Did anyone catch fire? Did a bot?
- [ ] Put the app in the background mid-rally and come back: it should pause and pick up where it was.

## Notes

- What was most fun?
- What was confusing, and when?
- Any touch that felt late or ignored?
