# TagTeam

**A mob-tagging addon for World of Warcraft Classic, to help you and your life partner!**

TagTeam is the #1 resource for tag-boosting a partner for maximum XP!

Boosting a low-level alt or a friend means walking a line: hit the mob too hard
and they get nothing, hold back too long and it takes all night.

TagTeam tracks the damage a set of **Taggers** deals to every enemy at once, and
marks each nameplate the moment a mob is safe for the **Carry** to finish. It's
built to work while ungrouped, for maximum XP gains. All XP and quest progress is
reported back to the carry, so you get a share of that dopamine as well!

But that's not all!

- Fully customisable nameplate badge, tracking progress on each enemy
- Quest progress, completions and accepts routed to the carry
- Fun audio! (also customisable)
- Great for dual-boxing!
- Instantly — and I mean instantly — party up with your partner when you get separated
- ...or form that group manually with `/tag inv` if the carry tags first (bad carry!)
- The party dissolves itself again once you're back in range, so you can get back to tagging
- Automatic `/follow` for carries, taggers and alts, through a single keybind
- Automatic {Triangle} marker on your partner while ungrouped
- A minimap button, for people who prefer buttons to typing
- A great UI! (well, I think it's great)

Usage: `/tag` or `/tag help` for all options.

## What it does

- **Live percentage on every nameplate.** Identifies which enemies your tagger
  has engaged, so there's no guesswork. The badge wears a warning icon until the
  taggers have dealt 31% of the mob's health in damage.
- **A sound and a stamped checkmark at your ideal target (40%).** Lets a carry
  know an enemy is ready to die, so you never have to stare at numbers mid-pull.
  You could literally be watching YouTube while using this thing.
- **Accurate XP reporting.** When both players run TagTeam, the tagger sends its
  real XP gain — rested included — straight to the carry, for an honest pop-up
  and chat line. `/tag stats` totals the session.
- **A buzz and a red X when a mob dies short.** Lets you feel shame when you kill
  an enemy too early and ruin your tagger's day!
- **Warnings when *you* steal the tag.** Also lets you feel shame, this time for
  tagging a mob before your tagger! Shame!!!
- **Pets count toward the tagger automatically.** Hunter and warlock pets are
  identified and pooled into the damage total. Cool!
- **One keybind to target, follow and focus your partner.** You probably have a
  follow macro you've been building for years — ditch it for a cool new UI. Great
  for us dual-boxers. (It'll still write you the macro, if you want one.)
- **Temporary taggers included.** When your tagger parties with other people,
  their party's damage is tracked too.
- **Quest and level cues.** Your tagger's quest progress, completions and accepts
  float on your screen with their own sounds, and there's a pop-up when they ding.
- **Ignore lists.** Skip PvP-flagged mobs, skip dungeons and raids entirely, or
  name individual mobs to ignore — plus an auto-tagged list for the ones that
  count no matter who hits them.
- **Free-for-all loot,** set automatically whenever your group is nothing but
  TagTeam partners.

## Why not just group up?

Grouping with a higher-level player destroys the XP gained. In a two-player group
the game computes the mob's value from the **higher** character's level, then
splits it — so a level 65 carry grouped with a level 20 alt killing a level 20 mob
produces **zero XP for both of you**. See [XP_RULES.md](XP_RULES.md) for the full
formulas.

TagTeam is built around staying ungrouped, and actively polices the trap by
warning you when you enter combat while grouped with a tagger.

## Getting started

On either character, name the other one:

```
/tag add Ragechief
```

That's it! If they also have the addon, they'll get a pop-up to confirm the
pairing.

After that, open `/tag` and find **General → Follow Binds**. You can set one
powerful keybind that follows and focuses every listed partner.

Focus is how TagTeam knows your partner has drifted out of range, which is what
triggers the instant party invite that gets you back to each other.

Unfortunately, Classic Era has no focus target at all :( The fallback is a 30-second timer. 

## Commands

| Command | Does |
|---|---|
| `/tag` | Open the window, and print the command list with it |
| `/tag help` | Print the command list and current status, on its own |
| `/tag add <name>` | Pair with a character — pick what they are to you |
| `/tag remove <name>` | Take that name off every list it's on |
| `/tag inv` | Get the two of you into one group, from either end |
| `/tag stats` | Session totals, estimated and actual |
| `/tag sound` | Master mute. Individual cues live on the Audio tab |

## Requirements

TBC Anniversary or Classic Era. Focus-based features need TBC. 
