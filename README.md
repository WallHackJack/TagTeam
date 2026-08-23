# TagTeam

**An addon for World of Warcraft Classic and Burning Crusade Classic.**

TagTeam shows you, live on every nameplate, whether the character you're
power-levelling has done enough damage to earn credit for the kill.

Boosting a low-level alt or a friend means walking a line: hit the mob too hard
and they get nothing, hold back too long and it takes all night. TagTeam tracks
the exact damage share off the combat log — no group required — and tells you the
moment a mob is safe to finish.

Type `/tag` for all options.

## What it does

- **Live percentage on every nameplate.** Watch a mob climb toward the threshold
  and hold off until it's there. The number is graded against two marks: below
  34% it wears a warning icon and sits orange, because the kill is a write-off
  however it ends; above that the warning comes off and it climbs orange to green
  as it reaches your threshold, where it becomes a checkmark. The kill line in
  chat and the death float use the same three verdicts, and a kill that lands
  between the two gets its own sound rather than the miss beep.
- **A sound and a stamped checkmark at 38%**, so you never have to stare at
  numbers mid-pull.
- **Real XP reporting, checked against the estimate.** When both sides run
  TagTeam, your alt's client sends its actual XP gain — rested included — and it
  prints on yours next to what TagTeam predicted, the multiplier between the two,
  and how much of that mob your taggers actually dealt:

  ```
  Aimbotscott gained 545 XP on Netherweb Victim - expected 545, 1.00x, taggers dealt 43%.
  ```

  A multiplier that isn't 1.00x is telling you something: 2.00x is rested, a
  fraction is a group split, and anything else usually means a cached level has
  gone stale. `/tag xp` shows the same ratio across the whole session.
- **A buzz and a red X when a mob dies short.** Most misses are incidental — your
  tagger clipped something you were killing anyway — so the cue is deliberately
  just "that one got away", with no number to read mid-pull. The exact share it
  reached is in the chat line. A kill that got past 34% but not to your threshold
  is a near miss instead: a softer sound and a warning icon, because it still
  banked most of its XP and an X over that would be a lie.
- **Warnings when *you* steal the tag**, with a standing X on mobs you tapped
  first and the threshold ding suppressed, because nothing can be earned there.
  The mob still gets the failure sound when it dies — the warning at tap time
  says stop, this one says that one is gone.
- **The same standing X on anything tagged while you're grouped with your tagger.**
  Grouping computes the mob's XP from *your* level and splits it, so the tag is
  worth a rounding error — the X says so, and every cue that would promise XP
  stays quiet rather than lying about it. The failure sound still plays on death,
  since the mob got away either way. It sticks until the mob dies or resets, even
  if you drop the party mid-fight.
- **Pets count, without being asked.** A hunter's or warlock's pet does a large
  share of a tagger's damage. Linked clients tell each other their pet by name,
  so it counts even when it was summoned before you logged in — and a tagger who
  isn't running TagTeam is placed from the pet's own tooltip the first time it
  crosses your target, your mouseover, or your target's target. `/tag` lists who
  owns what, and `/tag pets` turns the whole thing off.
- **Raid markers** on the mobs your taggers have claimed — skull, cross, square.
- **One keybind to target, follow and focus your partner.** It builds itself from
  whoever you've set up, tries each of them in priority order, and falls back to
  following your current target if nobody's configured. Bind it under
  **Key Bindings → TagTeam** and it stays current as your roster changes.

## Why not just group up?

Because grouping destroys the XP. In a two-player group the game computes the
mob's value from the **higher** character's level, then splits it — so a level 65
carry grouped with a level 20 alt killing a level 20 mob produces **zero XP for
both of you**. See [XP_RULES.md](XP_RULES.md) for the full formulas.

TagTeam is built around staying ungrouped, and actively polices the trap: it
warns when you enter combat while grouped with a tagger, and can leave the party
automatically once you're back in range.

## Getting started

**On the carry** (the character doing the killing):

```
/tag add Ragechief
```

**On the tagger** (the character being levelled):

```
/tag carry Wallhackjack
```

Either one offers the other the matching role over the addon's own hidden
channel; the other client confirms with a popup. Once linked, XP reports flow and
party invites happen silently without whispering anything visible.

Then bind a key under **Key Bindings → TagTeam** to target, follow and focus your
partner in one press. Focus matters: it's how TagTeam knows when you've drifted
out of range, and it can't set focus for you — that action is protected.

## Logistics it handles for you

- Whispers or silently asks for a party invite when you lose your partner, or on
  demand with `/tag inv`
- Auto-accepts invites from your partner only
- Sets loot to free-for-all in a two-person tag group
- Leaves the party again once you're back together
- Puts a triangle on your primary tagger while you're ungrouped

## Useful commands

| Command | Does |
|---|---|
| `/tag` | Full status and command list |
| `/tag add <name>` / `/tag remove <name>` | Manage taggers |
| `/tag carry <name>` | Run on a tagger's client |
| `/tag threshold <1-100>` (`/tag thresh`) | Change the tag threshold from 38%, on both linked clients. Decimals allowed (`37.5`). Bare, it explains what your threshold costs you in XP |
| `/tag xp` | Session totals, estimated and actual |
| `/tag macro` | Copyable target/follow/focus macro |
| `/tag ban <mob>` | Ignore a mob by name entirely |
| `/tag autotag <mob>` | Mobs your tagger keeps credit on without tapping first — no stolen-tag warning |
| `/tag audio` | Mute all cues |
| `/tag near <id|path>` (`/tag testnear`) | The near-miss cue, for a kill past 34% that still missed your threshold. `/tag miss` silences near misses and misses together |
| `/tag reset` (`/tag clear`) | Clear all roles |
| `/tag pvp` | Track PvP-flagged mobs instead of ignoring them (ignored by default) |
| `/tag instance` | Stop the addon entirely inside dungeons and raids (on by default) |
| `/tag zone` | Force the XP base constant (`auto`, `outland`, `azeroth`) when auto-detect is wrong |

## Requirements

TBC Anniversary or Classic Era. Focus-based features need TBC; on Classic Era
they fall back to a timer. The miss cue ships with the addon; the tag and
near-miss cues come from WeakAuras if you have it, and fall back to built-in
sounds if you don't.
