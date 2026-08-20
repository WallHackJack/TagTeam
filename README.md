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
  and hold off until it's there.
- **A sound and a stamped checkmark at 36%**, so you never have to stare at
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
  reached is in the chat line.
- **Warnings when *you* steal the tag**, with a standing X on mobs you tapped
  first and the threshold ding suppressed, because nothing can be earned there.
- **The same standing X on anything tagged while you're grouped with your tagger.**
  Grouping computes the mob's XP from *your* level and splits it, so the tag is
  worth a rounding error — the X says so, and every other cue stays quiet rather
  than promising XP nobody earned. It sticks until the mob dies or resets, even
  if you drop the party mid-fight.
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
| `/tag threshold <1-100>` (`/tag thresh`) | Change the tag threshold from 36%, on both linked clients |
| `/tag xp` | Session totals, estimated and actual |
| `/tag macro` | Copyable target/follow/focus macro |
| `/tag ban <mob>` | Ignore a mob by name entirely |
| `/tag audio` | Mute all cues |
| `/tag reset` (`/tag clear`) | Clear all roles |
| `/tag pvp` | Track PvP-flagged mobs instead of ignoring them (ignored by default) |
| `/tag instance` | Stop the addon entirely inside dungeons and raids (on by default) |
| `/tag zone` | Force the XP base constant (`auto`, `outland`, `azeroth`) when auto-detect is wrong |

## Requirements

TBC Anniversary or Classic Era. Focus-based features need TBC; on Classic Era
they fall back to a timer. The default alert sounds come from WeakAuras if you
have it, and fall back to built-in sounds if you don't.
