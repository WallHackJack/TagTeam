# Changelog

## Unreleased

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
