# TBC Experience Rules

Two roles are referred to throughout, matching TagTeam's terminology:

- **carry** — the high-level character doing the killing
- **tagger** — the low-level character being levelled, who must land enough damage
  to earn credit for the kill

Everything below is deterministic — there is no randomness in WoW's XP awards.
Sources: [Mob experience](https://warcraft.wiki.gg/wiki/Mob_experience) and
[Experience point](https://warcraft.wiki.gg/wiki/Experience_point), Warcraft Wiki.

---

## 1. Mob kill XP

### Step 1 — base XP from the mob's level

| Continent | Base XP |
|---|---|
| Azeroth | `5 × MobLevel + 45` |
| **Outland** | `5 × MobLevel + 235` |

That `+235` is why Outland grinding is so much faster than anything in the old
world. A level 63 mob in Hellfire pays **550** base; the same-level mob in
Silithus pays **360**.

### Step 2 — adjust for the level gap

| Mob relative to you | Multiplier |
|---|---|
| Above you | `1 + 0.05 × levelsAbove`, **capped at +4 levels** |
| Equal | `1.0` |
| Below you, above grey | `1 − (gap / ZD)` |
| At or below grey | `0` |

Red mobs pay exactly the same as orange, so fighting more than 4 levels up is
pure risk for zero extra reward.

**ZD — "zero difference".** How far below you a mob must be before it is worth
nothing:

| Your level | ZD | Your level | ZD |
|---|---|---|---|
| 1–7 | 5 | 30–39 | 12 |
| 8–9 | 6 | 40–44 | 13 |
| 10–11 | 7 | 45–49 | 14 |
| 12–15 | 8 | 50–54 | 15 |
| 16–19 | 9 | 55–59 | 16 |
| 20–29 | 11 | 60+ | 17 |

**Grey level.** The highest mob level worth literally nothing:

| Your level | Grey level |
|---|---|
| 1–5 | 0 — everything pays |
| 6–39 | `Level − floor(Level/10) − 5` |
| 40–59 | `Level − floor(Level/5) − 1` |
| 60–70 | `Level − 9` |

There is a nasty discontinuity at 60. At level 59 your grey level is **47**; the
moment you ding 60 it jumps to **51**. Four levels of mobs go worthless
overnight.

### Step 3 — elite multiplier

Elites, rare-elites and bosses pay **×2**.

---

## 2. Rested

- Accrues at **one bubble (5% of a level) per 8 hours** resting in an inn or
  capital city
- Caps at **30 bubbles = 150% of a level** banked
- **Doubles** XP from mob kills, mining, herbing and chests
- **Does not apply to quest XP**

Often described as a "50% bonus" because of how the bar displays it, but
mechanically your kill XP is doubled while the rested pool drains.

---

## 3. Groups

### Two-player groups — the powerlevelling killer

The mob's XP is computed using the **higher-level character's** solo formula,
then split by level ratio:

```
XP₁ = MXP × CL₁ / (CL₁ + CL₂)
XP₂ = MXP × CL₂ / (CL₁ + CL₂)
```

Where `CL₁` is the higher character's level and `MXP` is the solo XP that
higher character would have earned.

**Worked example.** A level 65 carry grouped with a level 20 tagger, killing a
level 20 mob. `MXP` is computed from the carry's perspective — that mob is deep
grey to them — so `MXP` is **zero** and *both* characters get nothing.

This is the entire reason tag-and-leave powerlevelling exists, and why TagTeam
works on damage share rather than party credit. **Stay ungrouped.**

### Three or more

`XP each = MobXP ÷ members × modifier`

| Members | Modifier |
|---|---|
| 1 | 1.0 |
| 2 | 1.0 |
| 3 | 1.166 |
| 4 | 1.3 |
| 5 | 1.4 |

Raid groups are cut drastically.

---

## 4. Quests

Full value while you are within 5 levels of the quest, then it falls off a cliff:

| Levels above quest | XP awarded |
|---|---|
| 0 to +5 | 100% |
| +6 | 80% |
| +7 | 60% |
| +8 | 40% |
| +9 | 20% |
| +10 or more | 10% |

Rested never applies to quests.

---

## 5. What TagTeam can and cannot see

The addon's estimate covers base XP, the level gap, grey level and the elite
multiplier. It deliberately cannot account for:

- **Rested** — would double the number
- **Grouping** — which you should not be doing anyway, see above
- **Realm-wide XP buffs** — a flat multiplier on top of everything

So treat the floating number as a **floor**, not a precise figure.
