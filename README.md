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
  your minimum target it wears a warning icon and sits orange, because the kill
  is a write-off however it ends; above that the warning comes off and it
  climbs orange to green as it reaches your ideal target, where it becomes a
  checkmark. The kill line in chat and the death float use the same three
  verdicts, and a kill that lands between the two gets its own sound.
- **A sound and a stamped checkmark at your ideal target**, so you never have
  to stare at numbers mid-pull.
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
  reached is in the chat line. A kill that got past the minimum but not to your
  ideal target is a near miss instead: a softer sound and a warning icon,
  because it still banked most of its XP and an X over that would be a lie.
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
  owns what.
- **One keybind to target, follow and focus your partner.** It builds itself from
  your follow targets and your taggers, tries each of them in priority order,
  and falls back to your focus or your target when none of them are in range.
  Set it — and those fallbacks — under **General → Follow Binds**, and it stays
  current as your roster changes.

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

Then open `/tag ui`, go to **General → Follow Binds**, and set a key to target,
follow and focus your partner in one press. Focus matters: it's how TagTeam knows
when you've drifted out of range, and it can't set focus for you — that action is
protected, so it only happens on the key.

## Logistics it handles for you

- Whispers or silently asks for a party invite when you lose your partner, or on
  demand with `/tag inv` — and if you're already in a group, `/tag inv` invites
  them into it instead of asking to be taken out of it
- Tells the carry when a tagger joins or leaves a party. Everyone in it counts
  toward the tag, and the XP estimate is divided by the size of the group
- Auto-accepts invites from your partner only
- Sets loot to free-for-all in a two-person tag group
- Leaves the party again once you're back together
- Puts a triangle on your primary tagger while you're ungrouped

## Useful commands

Most settings live in the window — `/tag ui` — and the commands below are the
ones worth having on a hotkey or in a macro. Anything that is purely a
preference is on a tab rather than here: the threshold, badge position and
styling, the XP zone, which cues play, and the two by-name mob lists (Ignore).

| Command | Does |
|---|---|
| `/tag` (`/tag status`) | Full status and command list |
| `/tag ui` (`/tag window`) | Open the settings window |
| `/tag add <name>` / `/tag remove <name>` (`/tag rem`, `/tag del`) | Manage taggers |
| `/tag carry <name>` | Run on a tagger's client: you and your party become the taggers |
| `/tag pair <name>` | Open the window on the pairing prompt |
| `/tag reset` (`/tag clear`, `/tag off`, `/tag none`) | Clear all roles |
| `/tag stats` | Session totals, estimated and actual |
| `/tag link` | Pair with the other client over the addon channel |
| `/tag inv` (`/tag invite`) | Get the two of you into one group: asks for an invite when you're alone, sends one when you're already in a party |
| `/tag sound` (`/tag audio`, `/tag mute`) | Master mute. Which cues play, and what each is set to, are on the Audio tab |
| `/tag diag` | Runtime picture: what was detected, what is cached, and the last cosmetic error |

## Requirements

TBC Anniversary or Classic Era. Focus-based features need TBC; on Classic Era
they fall back to a timer. The miss cue ships with the addon; the tag and
near-miss cues come from WeakAuras if you have it, and fall back to built-in
sounds if you don't.
