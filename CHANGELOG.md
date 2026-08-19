# Changelog

## Unreleased

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
