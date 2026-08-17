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
- **A sound and a stamped checkmark at 31%**, so you never have to stare at
  numbers mid-pull.
- **Real XP reporting.** When both sides run TagTeam, your alt's client sends its
  actual XP gain — rested included — and it prints on yours.
- **A red X and a percentage when a mob dies short**, so you know exactly how
  close it got.
- **Warnings when *you* steal the tag**, with a standing X on mobs you tapped
  first and the threshold ding suppressed, because nothing can be earned there.
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

- Whispers or silently asks for a party invite when you lose your partner
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
| `/tag <number>` | Change the threshold from 31% |
| `/tag xp` | Session totals, estimated and actual |
| `/tag macro` | Copyable target/follow/focus macro |
| `/tag ban <mob>` | Ignore a mob by name entirely |
| `/tag audio` | Mute all cues |
| `/tag reset` | Clear all roles |

## Requirements

TBC Anniversary or Classic Era. Focus-based features need TBC; on Classic Era
they fall back to a timer. The default alert sounds come from WeakAuras if you
have it, and fall back to built-in sounds if you don't.
