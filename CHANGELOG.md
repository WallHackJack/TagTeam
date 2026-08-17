# Changelog

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
