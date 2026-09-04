# Changelog

## Unreleased — say which end you are on

The Players tab used to list Carries and Taggers as two boxes, which was one box
too many: nobody is both, and every switch between them wiped the list you were
not using. There is now a **My Setup** box at the top of the page with a single
dropdown — *I am using TagTeam as a:* **Carry** or **Tagger** — and one list
under it, the one that mode is about.

- **Changed:** your role is a **setting** now, not something guessed from which
  list happens to have names in it. Picking it is one click and asks nothing:
  nothing is thrown away, so there is nothing to confirm.

- **Changed:** **both lists are kept forever.** Switching to Tagger no longer
  clears your taggers, and switching to Carry no longer clears your carry. The
  list you are not using is completely ignored while you are not using it — no
  tracking, no markers, no messages to anyone on it — and is exactly where you
  left it when you switch back.

- **Changed:** **your roster is account wide again**, and the setting above is
  what is per character instead. 0.6.0 gave every character its own carries and
  taggers, which meant writing the same handful of names out on every alt — and
  a mode switch made on one login quietly emptying a list you were keeping for
  another. Rosters from all your characters are merged on first login after
  updating, and each character keeps the role it was already playing.

- **Changed:** the bin next to your **active carry** works. It used to be
  refused, because being that carry's tagger *was* the mode; the mode is its own
  setting now, so removing the name just removes the name.

- **Changed:** `/tag` says which mode you are in every time, and the login line
  names your carry rather than a tagger list you are not using.

- **Added:** every row on the Players tab now has an **invite** button (the
  green plus) and a **request invite** button (the envelope) beside its bin —
  on all three lists. The plus invites them; the envelope asks them to invite
  you, going straight over the addon link where they are running TagTeam and
  whispering `inv` where they are not.

  Request invite greys out while you are already in a group, and invite greys
  out for somebody already standing in yours.

- **Changed:** **anyone on any of your lists is auto-accepted from**, and their
  invite arrives with no dialog at all. Before, only the half of the pair you
  were actively using was — so an invite from a follow target, or from a carry
  you were between boosts with, still popped the usual window.

- **Changed:** the add pop-up opens on the role your mode is about — Tagger
  when you are the carry, Carry when you are the tagger — instead of always
  Tagger.

- **Added:** **a tick box beside every name on the Taggers and Carries lists,**
  and it is the connection itself. Ticked is a live link — tracked, marked,
  talked to, listened to. Unticked is a name on a list and nothing else. With
  nothing ticked in the mode you are in, TagTeam is idle, which is now something
  you can reach without emptying a list you want to keep.

- **Changed:** **you can have several carries.** Before, `db.carryKey` named
  exactly one and the rest of the Carries list was people you had boosted with
  before; now any number can be switched on at once and a tagger reports its XP,
  quest and level lines to all of them. Taggers could always be plural and still
  are — there are three raid markers, so the first three switched-on taggers get
  one and any beyond that are tracked without.

- **Changed:** **unticking tells the other client.** The link goes down on both
  sides, so the two of you never disagree about whether you are connected. A
  switched-off partner's XP and quest lines stay out of your chat frame, nothing
  of yours is sent to them, and they hold no marker and no place in the follow
  macro — it is a disconnect, not a mute.

- **Changed:** **ticking asks them,** using the same accept/decline pop-up a
  fresh pairing raises. It is silent only when it costs them nothing: they
  already have you on the matching list and are already in the matching mode, in
  which case both ends just light up. A tagger who is not running TagTeam can
  still be ticked — they are tracked off the combat log and there is nobody to
  tell.

- **Changed:** the tick boxes are **per character**, like the mode and unlike the
  rosters. Your 60 having a tagger switched on does not switch it on for the alt
  being levelled. Upgrading keeps what you had: every tagger on your list starts
  ticked, and your carry starts ticked on the character that had one.

- **Changed:** `/tag` counts what is **switched on** rather than what is written
  down, and the login line names your live carries.

- **Changed:** **naming somebody sets your mode.** Adding a tagger says you are
  the carry, so you are switched to carry mode; setting a carry says you are the
  tagger, so you are switched to tagger mode. A small pop-up with an OK button
  says which way it went, and only when it actually changed. This replaces the
  chat line that used to tell you the name had been saved onto a list your
  character was not reading and then leave it there.

- **Fixed:** **setting a carry now asks them**, the way adding a tagger always
  has. The offer that raises the pairing pop-up on their screen was only sent if
  you happened to already be in tagger mode, so the usual first move — naming
  your carry while still set up as one — told them nothing at all. The mode is
  settled first now, so both directions ask.

- **Changed:** the add pop-up is **narrower**, both its controls are **labelled**
  — *They are my* over the list, *Character name* over the box — and the two are
  finally the same width. The name field is capped at twelve letters, which is
  the game's own limit.

- **Added:** a line of grey text under that list saying **what the role you have
  picked actually is**, changing as you pick. Tagger, carry and follow target are
  three words that mean nothing on first sight, and the cost of guessing wrong is
  a name on the wrong list plus an offer sent to somebody not expecting one.

- **Changed:** `/tag pair` and `/tag add` **open the pop-up with no name on
  them**. They used to answer a bare command by printing a line telling you to
  type it again with a name — a prompt, in chat, for a box that was one click
  away.

- **Removed:** the disabled gear on tagger rows. It was holding a place for
  per-tagger settings; the two invite buttons have the space now.

- **Added:** **every cue is picked from a list now.** The gear on an Audio row
  used to open a box you typed a file path into; it opens a **dropdown** —
  the nine sounds TagTeam ships, then every sound your other addons share
  through LibSharedMedia, which is where WeakAuras, DBM, Plater and the media
  packs all keep theirs. Long lists are filed into lettered submenus, because
  Blizzard's dropdown does not scroll. **Choosing one plays it**, at that cue's
  own volume, so you are hearing the thing you are about to save.

- **Changed:** typing a path is now the **Custom** entry on that list rather
  than the only way in. Pick it and the text field appears, still taking a file
  path or a SOUNDKIT id and still checked by playing it; pick anything else and
  the field is not on screen at all. **Default** is the first entry, and does
  what leaving the box empty used to.

- **Changed:** a cue's row says what the sound is **called** — "Oh No", not
  "OhNo.ogg" — for anything the shared library or TagTeam has a name for.

- **Fixed:** four of the bundled sounds were **too quiet next to the rest** —
  Bell Ding, Error Chord and Sharp Beep have been levelled to sit with Level Up
  and Meep Merp, so switching a cue from one to another no longer changes how
  loud your cues are. Jumpscare was not quiet at all; it had a fifth of a second
  of dead air in front of it and was landing late, which has been trimmed.

- **Note:** TagTeam **reads** that shared list and does not add to it. The
  sounds under `Media/` are licensed for use as part of this addon and are not
  ours to hand to other addons; see LICENSE.

## 0.6.0 — settings, not commands

Eighteen slash commands became settings. What is left of `/tag` is things you
DO rather than things you set, and everything you set lives in the window,
which grew an Ignore tab, a Follow Binds box, and a nameplate badge you can see
while you style it.

- **Changed:** **the volume controls actually work.** The mixer reads the game's
  SFX volume continuously, so setting the CVar, starting a cue and restoring it
  on the next line played every cue at the volume you were trying to change.
  Every volume control in the addon was a placebo before this.

- **Added:** a **Follow Binds** box at the bottom of the General tab. The follow
  key is set from there rather than by going to Key Bindings — press the button,
  press a key — and the **Follow targets** list on the Players tab is now part of
  what that key chases, ahead of the taggers, since it is the one list you type
  out in order to be followed.

  Three switches beside it: whether the key sets focus as well as following, and
  two fallbacks for when nobody on the lists is in range — follow your focus, and
  follow your target. Both are new; the key previously did nothing at all when
  every name on it was away. **Generate Macro** puts the same text in a box for
  copying onto a bar, though `/focus` only ever works from the keybind.

- **Changed:** your **carries and taggers are now saved per character**, where
  before one roster was shared by your whole account. Logging in on the carry to
  find the carry listed as a tagger was the symptom. Your existing roster stays
  with whichever character logs in first after updating; every other character
  starts empty. **Follow targets stay account wide** — they are people you chase
  whoever you are logged in as.

- **Added:** a tagger who joins a party now tells the carry about it. Everyone in
  that party — and their pets — counts as a temporary co-tagger, so their damage
  pools toward the threshold the same way the tagger's does. Neither the names
  nor the group were visible from the carry's side before: the combat log just
  showed a stranger, and there is no way to ask about a group you aren't in.

  The XP estimate is divided by the size of the group, since that is how the mob
  pays. A tagger in a group of three earns a third, so that is what the estimate
  now says. Levels are ignored in the split.

  It is announced in chat both ways — joining and leaving — and there is no
  window for this on purpose: co-taggers are scratch, not roster. Nothing is
  saved, nobody gets a marker, and the level every estimate is measured against
  never counts a stranger who grouped up for one quest.

  `/tag inv` now means "get the two of us into one group" from either end: alone
  it asks to be invited, and in a party it invites them instead.

- **Added:** an **Ignore tab** — the two blanket switches, then the ignored and
  auto-tagged mob lists, each with add, a per-row bin, its own scroll area and a
  Reset. Shipped entries sort last and can't be removed one at a time.

- **Changed:** Popups became **Screen Bursts**, each row labelled by the mark it
  draws and each with a Test. Two new switches: the full-XP burst had none at
  all, and the acceptable one rode the miss flag, so the verdict worth
  celebrating couldn't be switched off and the one worth tightening couldn't be
  switched off separately from the one worth regretting. Quest notices split
  three ways, since one flag was silencing objective ticks and hand-ins
  together.

- **Changed:** the **nameplate badge** gained offsets, font and sizes, over a
  live preview drawn at 0.8 scale so you can see what you're styling. Tracking
  and Badge both have Reset buttons, wired to the same defaults the addon ships
  with. Two damage targets rather than one, both clamped to the range the XP
  curve actually bends over, with what each is worth beside its slider.

- **Fixed:** quest progress no longer defaults to the engine's objective-complete
  flourish, which is the wrong weight of noise for something that fires once per
  mob. The test for a sound there isn't whether it plays, it's whether you could
  stand thirty of them in a minute.

- **Fixed:** pop-up layering, so the burst and the prompts over it stop
  arguing about which is in front.

- **Fixed:** rows on the **Audio** tab toggle from anywhere on the row, the way
  the Screen Bursts rows already did. A checkbox you have to hit exactly is a
  checkbox people miss.

- **Removed:** `pos`, `miss`, `level`, `pets`, `zone`, `leave`, `calibrate`,
  `threshold`, `macro`, `instance`, `announce`, `quests`, `xpdebug`, `pvp`,
  `ban`, `autotag`, `comms` and `accept`. All of them settings in disguise, and
  all of them in the window now. `/tag xp` is now `/tag stats`.

## 0.5.0 — the window

A first pass at a real interface: `/tag ui` opens a tabbed window covering
players, general settings, pop-ups, nameplates and sounds. It needs more work,
and the About tab's patch notes panel is deliberately empty until it gets some.

Notes for this release are still to be written.

## 0.4.0 — the link actually talks

The two clients barely spoke before this. The tagger sent XP and nothing else, so
the carry guessed at everything around it — and guessed wrong often enough to be
noticed.

Now the link carries the tagger's **quest log** (accepted, abandoned, objectives
ticking over, hand-ins with the XP they paid), their **level-ups**, and their
**rested pool**, each with its own sound and screen pop-up. The XP reporting
underneath was largely rebuilt: multi-kill ticks, quest and discovery XP, and
rested doubling were all being mislabelled or misattributed, and the carry now
prefers the tagger's confirmed number over its own estimate everywhere it has
one. The kill line is rewritten and both ends print the same one.

- **Changed:** the kill line is rewritten, and the tagger now prints it too:

  `Wallhackmage gained 860 of 1070 XP (x2), 37.2% damage = 80% XP` + the X icon

  Both ends build it from the same code, so they can't drift into describing the
  same mob differently. The carry sees the tagger's name in their class colour;
  the tagger sees a green "You". Both XP figures are purple, the damage share
  white, and the X shows only when the threshold went unmet — the XP still
  landed, since the tap decides that and not the share, so it's a footnote rather
  than a verdict. It's the same X the pop-up draws, sized to your chat font.

  The `= 80% XP` is the only thing on the line that changes colour, because it's
  the only judgement: red at 70% or below, through yellow, to green at 100%. It
  replaces the old `0.80x` multiplier, which said the same thing in a form you
  had to stop and read.

  `/tag announce` toggles it.
- **Removed:** the separate `MISSED` chat line — the kill line above is the miss
  notice now.

  Worth knowing what that costs: a miss says nothing in chat until the report
  that prices it arrives, and with nobody linked it says nothing at all. The buzz
  still fires the instant the mob dies, and the pop-up still shows the X with the
  damage share — only the chat line waits.
- **Fixed:** a tagger's own client priced its rested kills as if they weren't
  rested, because it was waiting for a message about a rested pool that was
  sitting on its own machine. It reads it directly now, so both ends agree.
- **Changed:** the miss pop-up reads `+545 XP  (22%)`. Three tweaks: the damage
  share is now parenthesised and white instead of taking the X's red — the X is
  the verdict, the share is the evidence, and they separate better as two things;
  the decimal is dropped unless the share lands within a point of your threshold,
  where the difference between 37.6% and 38% is the whole story; and the blue
  `(x2)` is gone from it, since on a miss the number that matters is how close
  they came and a second parenthetical only competes with it.

  Checkmarks keep their `(x2)`, and the chat line keeps its full decimal.
- **Fixed:** a linked tagger's kill could put a blank checkmark on screen when
  their report was slow — the timeout had nothing to draw and drew it anyway.
  There is no timeout on a kill now: nothing appears until the report does, and
  if it never comes, nothing appears. The chat line still says what happened. No
  pop-up is a fine outcome; an empty one isn't.

  Misses keep their timeout, because they have the damage share to show and that
  number is measured on your end. Without it the X would vanish entirely on any
  miss the tagger never tapped — no report is ever coming for those.
- **Changed:** pop-ups stay up 0.8s longer and drift a little more slowly. The
  extra time is all *readable* time — they hold fully opaque for 1.5s now instead
  of 0.7s, and the fade itself is the same 1.1s it always was, so they linger
  rather than sitting around half-transparent. The rise went 70px → 85px across
  the longer flight, which nets out about 16% slower than before.
- **New:** the pop-up on screen carries the blue `(x2)` too when the kill was
  rested — `+1090 XP (x2)` — matching the chat line, and meaning the same thing:
  the number in front of it already has the doubling in it.
- **Changed:** once a linked tagger is reporting, the estimated session total
  isn't shown at all. `/tag` and `/tag xp` print the confirmed number instead —
  not alongside it, not in brackets. Two totals for one session only invites
  reading the wrong one, and the estimate is the wrong one.

  The estimate is still tracked behind the scenes; `/tag calibrate` and the
  "expected N, actual M, 1.02x" line still need it. That line still shows both,
  because contrasting them is its entire job — it's how a stale cached level gets
  caught.
- **Changed:** the number on screen follows the same rule. If a report was
  expected and didn't arrive in time, the checkmark now comes up without a
  number rather than falling back to the guess. A miss shows its damage share on
  its own in that case, since the share is measured on your end and always known.
  With nobody linked, the `~estimate` still appears as before.
- **New:** accepting and completing a quest now float on screen as well, in the
  same yellow that objective progress uses — `Wallhackmage completed "Force
  Commander Danath" for 10000 XP`. Their name comes out in their class colour and
  the reward in purple, so the three parts separate at a glance rather than
  needing to be read.

  The class is picked up for free the first time they pass through a unit you can
  inspect, which in practice is immediately. Until then the name is just yellow —
  no colour beats a guessed one.

  The completion float ignores `/tag quests`, like its fanfare does: that toggle
  is for the running commentary on their quest log, and a completion is an XP
  event. The accept float follows the toggle.
- **New:** when a tagger is linked, the number in the middle of the screen waits
  for them. It used to be drawn the instant the mob died, which meant it could
  only ever be the estimate — the real figure is a fraction of a second behind,
  and the middle of the screen is the one place worth spending that on. A tilde
  marks the difference: `~545 XP` is our guess, `+1090 XP` is what they actually
  got. With nobody linked it draws immediately as before, since there'd be
  nothing to wait for.
- **New:** the red X now carries the numbers too — `+545 XP  22.4%` — so a miss
  tells you what it paid anyway and how close they came, not just that one got
  away. It was a bare X on purpose: most misses are incidental, the tagger
  clipping something you were killing regardless, and on those the share decides
  nothing. But the misses that were real attempts are the ones worth reading, and
  you can't tell them apart without the number.

  The miss buzz still fires the instant the mob dies. That one is the alert, and
  it isn't waiting for anything.
- **Fixed:** with `/tag comms` off, a missed kill's chat line still sat on a
  two-second timer waiting for a report that could never arrive.
- **New:** the tagger reports their rested XP, and the estimate stops pretending
  not to know about it. A rested kill used to read `expected 545, 2.00x` — the
  multiplier is there to show what the formula *can't* see, so a predictable
  doubling sitting in it made the one useful number useless. Now:

  `Wallhackmage gained 1090 XP on Ravager - expected 1090 (x2), 1.00x, taggers dealt 61.2%.`

  The `(x2)` in light blue marks an expectation that already has rested folded
  in, so a 1.00x beside it means the estimate was right — not that the bonus went
  missing. Session totals and the floating `+XP` double too.

  Any rested at all counts the whole kill as doubled. The pool can run dry
  mid-kill and pay somewhere in between, but pricing that needs the pool size at
  the instant the mob died, which is on the other client and a message behind.
- **New:** the pool is reported as a percentage of their level — `Wallhackmage is
  rested: 87.4% of a level` — when you pair, when they ding, and as it drains.
  `/tag xp` shows the last figure. The raw number would mean nothing on your end
  without knowing how big their level is, hence the percentage; it can exceed
  100%, since rested caps at a level and a half.
- **New:** when the rested pool runs out, the carry is told —
  `Wallhackmage has used up their rested XP - kills are back to face value.` That
  message goes out ahead of the kill reports it changes, so the estimates switch
  over on the right kill.
- **Fixed:** a quest hand-in could still be reported to the carry as a kill —
  `gained 9000 XP (actual)` instead of naming the quest, and with no completion
  sound. The previous attempt at this fixed the wrong half.

  The turn-in and the experience bar update are separate events, and the turn-in
  often arrives *first*. The tick was being wrapped up while the bar hadn't
  moved yet, and the evidence was thrown away at that point — so when the XP
  landed a moment later there was nothing left to say where it came from. Now
  nothing is discarded until there's actually some XP to account for, and it's
  only aged out if the XP never turns up at all.

  Waiting longer never fixed this on its own, which is why the last attempt
  didn't take: the wrap-up still happened before the XP arrived, just later.
- **Fixed:** a turn-in is no longer judged by the size of the reward the client
  reports alongside it. The turn-in happening is the evidence; if the reward
  comes back empty and nothing died that tick, the gain was the quest's.
- **New:** handing a quest in plays the completion fanfare on the carry, the
  counterpart to the accept one. It rides the XP report rather than the quest
  notices, so `/tag quests` off doesn't silence it.
- **New:** `/tag xpdebug`, run on the tagger, prints each piece of evidence as it
  arrives and every wrap-up with what it had. The ordering between those events
  is what both of these bugs came down to and it can't be worked out after the
  fact, so if XP is ever labelled wrongly again, this shows why in one hand-in.
- **New:** the tagger's quest progress now floats on your screen as well as
  printing to chat — yellow text that rises and fades exactly like the `+XP` you
  already get, sitting a little above it so the two read as separate notices
  rather than one pile.

  It shares the same pooled frames and the same flight path as the XP burst, so
  the two can't drift into moving at different speeds. Two objectives ticking in
  the same instant stagger by a line instead of landing on the same pixel.

  `/tag quests` turns it off with the rest of the quest notices.
- **Fixed:** kills were being reported as "discovery" at random. The label was
  inferred from the *absence* of a "X dies, you gain N experience" line in that
  tick, and two things make that line absent on a perfectly ordinary kill: the
  game sometimes sends the version with no mob name in it ("You gain N
  experience."), and the line and the experience bar update are separate packets
  that need not land in the same frame. Both are unpredictable from the outside,
  which is why it looked random.

  Nothing is labelled by elimination any more. A kill is identified by its line, a
  quest by the turn-in, and a discovery by the "Discovered X" message it announces
  itself with — and anything that doesn't identify itself is now reported as a
  plain kill, which is what it did before any of the labelling existed. Every way
  of being wrong now lands on the old, safe behaviour.

  The per-mob split is unaffected and stays: that one reads lines that are
  actually there, rather than drawing conclusions from ones that aren't.
- **New:** `/tag quests` turns the tagger's quest notices on and off — accepted,
  abandoned, and objective progress. Level-ups and XP reports are unaffected. It
  gates what your own client prints, so it takes effect where you type it and
  needs nothing from the other end.
- **New:** quest objective progress reaches the carry — the yellow text that
  flashes in the middle of the tagger's screen now prints on yours:
  `Wallhackmage - Clefthoof Meat: 3/10`, `Wallhackmage - Slay the Ravagers
  (Complete)`. Objective ticks, objective-complete and quest-failed all come
  through; the text is forwarded exactly as their client wrote it.

  This is the chattiest of the quest notices, since a tagger with a kill quest
  for what you're pulling generates one line per mob. `/tag comms` off stops it,
  along with everything else on the link.
- **New:** abandoning a quest reaches the carry too — `Wallhackmage abandoned
  "Force Commander Danath".` No sound on this one: dropping a quest isn't worth a
  fanfare, and cueing both would make them indistinguishable by ear.

  It lands about a second after the fact, which is not slowness but the only way
  to be right: the game fires one event for handing a quest in and abandoning it,
  says nothing about which, and can report the removal *before* the hand-in it
  belongs to. So a removal waits a beat to see whether a hand-in claims it.
- **New:** the tagger's dings reach the carry — `Wallhackmage is now level 62
  (was 61).` with the level-up sound, at any distance and whether or not you are
  grouped. It is a whisper under the hood, so range and party have nothing to do
  with it.

  This is more than a notification. The carry's copy of the tagger's level is
  what every XP estimate is measured against, and until now it only moved when
  the carry could physically see them — one level stale is a phantom ~6% penalty
  on every kill. A ding out of range used to go unnoticed until they next walked
  past; now it corrects itself immediately.

  A ding inside a dungeon still goes unannounced, like everything else while the
  addon is suspended in there. Nothing is lost but the notice: the level is
  re-read the moment they're in sight again.
- **New:** the carry sees quests as the tagger picks them up — `Wallhackmage
  accepted "Force Commander Danath".` with the drums-and-horns accept fanfare.
  So when they wander off mid-pull you know why, and you can read the objective
  back to them without alt-tabbing.

  Nothing rides on it and nothing is tallied; it prints and cues, and only from
  your established partner. A quest whose name the client won't give up is not
  announced at all — the name is the whole message.
- **New:** reports now say where the XP came from. A tagger earns it three ways
  and only one of them is a tag, but all three used to arrive looking like a
  kill — so a quest handed in on the way to the pull was pinned to whichever mob
  was waiting to be paired, and printed a nonsense multiplier against it. You now
  get `gained 950 XP by completing "Force Commander Danath".` and
  `gained 90 XP (discovery).`, neither of which claims a kill or moves the
  session multiplier. `/tag xp` keeps a separate total for them, so the kill
  numbers only ever count kills.

  The quest name comes free where the client will give it up; where it won't, the
  line says "by completing a quest".
- **Fixed:** three mobs dying in the same tick were reported as one mob paying
  three times its worth. The server batches the player's experience field, so the
  event the tagger was reporting from fires *once* for the whole tick no matter
  how many mobs died in it. The carry then hung that whole sum on a single kill —
  "gained 1635 XP, expected 545, 3.00x" — while the other two kills sat unclaimed
  until they expired. The chat log is not batched, so the tagger now splits the
  tick across the "X dies, you gain N experience" lines and sends one report per
  mob. The total still comes from the experience bar, so anything the chat line
  words differently is still counted; the parts always add up to it.
- **Fixed:** an invite that worked could still be followed by the visible "inv"
  whisper, and then the two of you bounced in and out of a party. The addon-link
  invite lands, the party forms, the auto-leave puts you back out of it because
  the tagger is in range — all inside the eight seconds the backup whisper waits.
  The whisper then found no party, assumed the link had failed, and asked again
  out loud, drawing a second invite and a second auto-leave. It now asks whether
  a party formed *since* the request rather than whether one exists right now, so
  an invite that arrived cancels the backup whether or not you are still in it.
- Both copies of that logic — the automatic out-of-range path and `/tag inv` —
  are now one function, so the two can't drift apart again.
- **Fixed:** with `/tag comms` off but a saved link, the automatic path claimed
  "asked X to invite (addon link)" and sent nothing, then whispered eight seconds
  later. It now whispers immediately, which is all it could ever have done.
- The backup whisper no longer checks `/tag autoinvite` when it fires. It
  completes a request already made, and the check meant a hand-typed `/tag inv`
  had no backup at all when auto-invite was switched off.
- **Internal:** the 48 constants and 16 per-pull state tables are now fields on
  two tables rather than 64 file-level locals. A Lua file's top level is itself a
  function, and Lua 5.1 allows 200 locals per function — this file had reached
  197 and was three away from not compiling at all, which would have shown up as
  the addon silently failing to load. There are now 66 slots free. No behaviour
  changes; the constants stay where their explanatory comments are.
- **Internal:** `Forget` and `ResetAll` were two hand-maintained lists of the
  same table names, which is a leak waiting to happen. Both now iterate one list.
- **New:** `/tag autotag <mob>` — mobs your tagger keeps credit on without
  tapping first. **You hitting one first is not a theft**: no `TAGGED` warning, no
  standing X, and the kill still reports. Everything else is unchanged — these pay
  XP, so the threshold still decides, the nameplate still counts up, and falling
  short is still a real miss. Run it again on the same name to turn one off; bare
  `/tag autotag` lists them.

  This is a separate axis from the ignore list, which is for mobs paying no XP at
  all. There the threshold is meaningless and a plain checkmark is the whole
  story; here it still has to be earned.
- **New:** Aggonis is ignored by default. He is auto-tagged, but pays no XP
  either, so there is nothing to report and banning outright is simpler.
- **Fixed:** cues fired on mobs the addon had already decided were worthless —
  a `TAGGED` warning on a level 1 Hellfire scorpion being the case that found it.
  Every worthless test needs the mob's level or classification, and those only
  existed once a **nameplate** had appeared for it. Critters generally never get
  one, so the critter check never ran for the mobs it exists to catch; and the
  first hit routinely lands before the plate registers, which is exactly the
  moment the tag owner is decided and `TAGGED` is said. The addon now falls back
  to your target and mouseover, which is almost always the thing you just hit.
- **New:** mobs 10 or more levels below your lowest tagger are ignored outright.
  Grey mobs were already ignored, but grey means "pays literally zero" and at
  higher levels that gap is 17 levels wide — plenty of room for mobs nobody is
  there to kill. They get no ding, float, marker, steal warning or session XP.
- **Fixed:** the critter check compared against the English word "Critter", so it
  never matched on a non-English client. It now prefers the client's own constant
  where there is one. Best-effort either way — the level rule above is what
  actually catches critters, since they're level 1.
- **Changed:** every percentage in chat now carries one decimal — `taggers dealt
  43.3%`, `died at 36.8%, needed 37.5%`. The numbers were always measured that
  precisely and were being truncated on the way out, which made a threshold sat
  between two whole numbers impossible to reason about.
- **New:** `/tag threshold` takes decimals — `/tag threshold 37.5`. The input is
  rounded to the one decimal everything displays at, so the stored number and the
  printed one can never disagree. The nameplate badge stays whole-number; it's a
  glance, not a measurement. alongside
  Netherweb Victim. `/tag unban <name>` counts any of them again, and `/tag
  banlist` now marks which entries came with the addon.
- **Changed:** the default ignore list lives in the addon instead of being copied
  into your saved settings the first time you ran it. That copy was why a new
  default would have reached nobody who had played before — everyone already had
  a list, so the seeding never ran again. Your saved settings now hold only what
  you changed: mobs you banned, and any of ours you turned off. Existing settings
  convert on the next login, and a default you had already unbanned stays off.
- **Internal:** `/tag` moved to its own file, `SlashCommands.lua`, and its 575-line
  `if/elseif` chain became a command table — one function per command, aliases as
  assignments. That was the function pinned to Lua's 60-upvalue-per-function
  ceiling, which three separate comments in the codebase existed to apologise
  for; the worst function there now uses 12. All 53 commands behave as before.
- **Fixed:** the automatic out-of-range invite and `/tag inv` picked their target
  with two copies of the same code, and a comment claiming they were identical —
  which they weren't. `/tag inv` fell back to your primary tagger when no focus
  had been held and the automatic path didn't. Both behaviours were right and
  are kept, but they now come from one function that says why they differ: a
  command you typed should reach someone, a five-second ticker should not whisper
  a person you never focused.

## 0.3.0

- **Changed:** the default tag threshold is now **38%**, up from 36%. A saved 36
  is moved to 38 at load, since it can't be told apart from a deliberate one —
  `/tag threshold 36` puts it back. A saved 31 from before 0.2.1 is moved too, so
  skipping a release no longer leaves you on a default two versions old.
- **Fixed:** a tagger's hunter or warlock pet was only counted if you happened to
  witness the summon. Pet ownership was learned from `SPELL_SUMMON` and keyed by
  GUID, and pet GUIDs do not survive a loading screen — so a hunter who summoned
  once and played all evening dealt half their damage into a void, and their
  tagger read as one who could not reach the threshold. Pets are now tracked by
  **name** as well: the name sits on the tagger's saved record, survives a
  reload, and needs no summon to be seen. The old GUID route stays as the exact
  one where it applies.
- **New:** linked clients tell each other their pet over the addon channel, on
  every summon or dismiss, at login, and whenever a link is made — the owner's
  own client is the only one that can see a pet nobody watched arrive. Nothing
  appears in chat; the carry prints one line naming the pet the first time it
  learns it. Nothing to type, and it covers the carry's own pet in the other
  direction, which taps mobs and steals tags exactly as the carry does.
- **New:** a pet you can target, mouse over, or that shows up as your target's
  target — where a pet holding the mob sits for most of a pull — is placed from
  its own tooltip, which names its owner. That is the route that needs neither a
  summon nor the other client, so a tagger who is **not** running TagTeam is
  covered too, without anyone typing anything.
- `/tag` now lists each tagger's pet, and their carry's pet in tagger mode.
- Pets stay off the tagger list itself. A pet is not a head the XP formula knows
  about, and one in the list would put its level into the lowest-level lookup and
  bias every estimate — as adding it by hand with `/tag add` would have.

- **Fixed:** joining the party mid-fight left every mob pulled for the rest of
  that combat warning about the wrong thing. Mobs you tapped said `TAGGED` —
  true, but the smaller problem, with the group hidden behind it — and mobs your
  tagger tapped said nothing at all, so whether you were warned came down to who
  landed the first hit. Both now say `GROUPED`. The grouped warning otherwise
  rides entering combat, which never fires again for someone already in it.
- The grouped warning keeps its one-per-pull rate limit through the new path, so
  a warning shown at the start of a fight is not replayed on the next mob.
- **New:** PvP-flagged mobs are ignored by default — the faction guards on
  contested Outland ground, Halaa and the Hellfire towers. They do pay XP, so
  this is a preference rather than a fix: hitting one flags your tagger for PvP,
  and a defenceless low-level alt wearing a flag out there is a corpse run, not a
  level. `/tag pvp` tracks them anyway.
- **Fixed:** enemy players were already ignored, but their **pets, minions and
  guardians were not** — a tagger clipping a warlock's felhunter or a hunter's
  boar banked damage on it, badged its nameplate and buzzed when it died. Nothing
  a player drives pays XP, so none of it was ever a tag. Pets are caught by their
  GUID; guardians and totems arrive as ordinary creature GUIDs and are caught by
  `UnitPlayerControlled` whenever a nameplate is up, which is the only time the
  addon would have shown anything anyway.

## 0.2.1

- **Changed:** the miss burst is now a bare red X — the percentage is gone from
  it. Most misses are incidental, your tagger clipping something you were killing
  anyway, and on those the share it happened to reach decides nothing. The buzz
  still carries the part that matters: that one got away. `/tag testmiss` previews
  the new look, and the exact percentage is still in the chat line.
- **Changed:** a missed kill that still paid the tagger printed two lines — the
  `MISSED` alert, then a bare `gained 372 XP (actual)` with nothing tying them
  together. They are now one line: `gained 372 XP on Young Crust Burster -
  expected 532, 0.70x, taggers dealt 35% (MISSED, needed 39%)`. The miss sound
  and the X burst still fire the instant the mob dies; only the chat line waits
  (up to 2s) for the report to arrive, and only when a linked partner might send
  one.
- **Fixed:** missed kills were never queued for XP-report pairing, so the report
  they generated claimed the *next* tagged kill's entry instead and reported it
  against the wrong mob. Missed kills now hold their own slot. They stay out of
  the session multiplier, though — their estimate assumes a full tag they never
  made, and averaging that in would hide what properly tagged kills are paying.
- **Fixed:** a kill made while grouped with your tagger fired the GROUPED warning
  *and* then floated a "+N XP" burst behind it on the same pull. The second one
  was a lie as well as a duplicate — the two-player rule computes the mob's XP
  from the carry's level, so the tagger banks a rounding error. Mobs tagged while
  grouped now wear the **standing X** on their nameplate instead of a percentage
  or a checkmark, and every cue goes quiet: no XP float, no miss alert, no
  threshold ding or plate stamp, and no session XP inflated with numbers nobody
  earned. The GROUPED warning at the pull is the one cue left.
- The X is latched per mob, so **dropping the party mid-pull does not clear it** —
  it stays until the mob dies, or until it evades and resets to full health.
- **New:** TagTeam now suspends itself entirely inside dungeons and raids. No
  badges, no sounds, no combat-log tracking, no invite or leave logistics — the
  carry and tagger are necessarily grouped in there, so a tag is worth almost
  nothing, and the auto-leave check would otherwise try to drop the party
  mid-run. `/tag` says **SUSPENDED** when it applies. `/tag instance` turns the
  behaviour off if you want the badges anyway. Pairing and threshold sync stay
  live with your partner throughout.
- **Changed:** the default tag threshold is now **36%**, up from 31%. A saved 31
  is moved to 36 at load, since it can't be told apart from a deliberate one —
  `/tag threshold 31` puts it back.
- `/tag continent` is now **`/tag zone`** (the old name still works), and
  `/tag clear` does what `/tag reset` does.
- Removed an unreachable second `/tag reset` handler that claimed to clear
  tracked damage. `/tag reset` matched the roles-clearing handler first and
  returned, so that branch could never run.
- **Fixed:** Outland auto-detection failed on this client, so every Outland kill
  was estimated with Azeroth's `+45` base instead of `+235` — about 1.51× low
  (a level 66 mob predicted 375 against a real 565). Detection now reads the
  instance id first (530 = Outland, stable across clients) and recognises this
  client's Outland uiMapID as well as retail's. `/tag diag` reports the instance
  id alongside the map. If you worked around this with `/tag continent outland`
  or `/tag calibrate`, clear them — `/tag continent auto`, `/tag calibrate reset`.
- **Changed:** the tag threshold moves with `/tag threshold <1-100>` (short form
  `/tag thresh`) instead of a bare `/tag <number>`, and it now syncs to the
  linked client over addon comms — set from either end, both follow. A number on
  its own is no longer a command, so a mistyped one says so rather than silently
  changing the threshold.
- A linked tagger's XP report now prints against the carry's own estimate:
  expected, actual, the multiplier between them, and the pooled damage share the
  taggers dealt on that mob. The multiplier reads 1.00x when the estimate is
  right, and is the tell for the things an addon cannot see from the carry's
  side — rested doubles it, a group split cuts it, a stale cached tagger level
  skews it.
- `/tag xp` totals the paired kills separately and shows the overall multiplier
  across them, so one noisy kill doesn't have to be read on its own.
- **Changed:** `/tag inv` now *requests* an invite from the other side instead of
  inviting them — the same exchange the automatic out-of-range path already ran,
  just triggered by hand. It asks one player, not the whole tagger list, since
  only one incoming party invite can ever be accepted.
- Auto-accept now honours an invite from either half of the pair. It only ever
  recognised taggers, so an invite arriving from your carry — which is exactly
  what `/tag inv` now produces in tagger mode — needed clicking by hand.

## 0.2.0

- Badge position is configurable: `/tag pos above|below|left|right`.
- `/tag inv` invites your taggers, or your carry in tagger mode, skipping anyone
  already in the group.
- Side badge positions are inset so they sit against the visible plate rather than
  the wider Blizzard frame underneath it.
- **Renamed:** the out-of-range whisper toggle is now `/tag autoinvite`, freeing
  `/tag inv` for the action and matching `/tag autoleave`.

## 0.1.0

First release.

- Live damage-share percentage on enemy nameplates, measured against the mob's
  max health from `COMBAT_LOG_EVENT_UNFILTERED` — no group required.
- Checkmark stamp and a sound when a tagger crosses the threshold (default 31%).
- Death animations: a rising checkmark on a tagged kill, a red X with the final
  percentage when one dies short.
- Multiple taggers with pooled damage, and a tagger mode for running the addon on
  the character being levelled.
- Addon-to-addon pairing over a hidden whisper channel, with confirmation popups,
  silent party invites, and real XP reporting from the tagger's own client.
- XP estimate using the verified TBC formulas, including the separate Outland base
  constant, elite doubling and grey-level cutoff.
- Tag-ownership tracking: standing X and suppressed ding on mobs the carry tapped
  first, plus a warning when you steal a tag.
- Party logistics: invite requests on losing range, auto-accept from partners
  only, free-for-all loot in a two-person tag group, auto-leave when back in
  range, and a warning when entering combat while grouped with a tagger.
- Raid markers on claimed mobs and a triangle on the primary tagger.
- Keybindable secure macro button for target/follow/focus.
- Mob banlist, ignoring named mobs entirely; ships with Netherweb Victim.
