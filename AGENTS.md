# TagTeam — agent instructions

TagTeam is a single-file Lua 5.1 addon for the WoW TBC Anniversary client. The
checked-out repository is also the user's live addon directory, so source files
must remain directly loadable by the game.

For the user-facing overview see [README.md](README.md). For the TBC experience
formulas the XP estimate is built on, see [XP_RULES.md](XP_RULES.md).

## The two roles

Every identifier in the codebase uses these words. They were deliberately chosen
after "taggee", "booster/boostee" and "driver/gunner" were all rejected —
*driver* especially, because it is reversible and two people assigned it to
opposite characters. Do not reintroduce any of them.

- **carry** — the high-level character doing the killing.
- **tagger** — a low-level character being levelled, who must deal `db.threshold`
  percent (default **31%**) of a mob's max health to earn credit for the kill.

There can be several taggers. **Their damage is pooled** against the one
threshold, which is correct when they are grouped with each other, since a party
shares one tag.

## Two modes

| Mode | Set by | Meaning |
|---|---|---|
| carry (default) | `db.taggers` populated | You are the carry; the list is who you're boosting. |
| tagger | `/tag carry <name>` sets `db.carryKey` | You are a tagger; **you and your whole party** are taggers, rebuilt into `dynamicTaggers`. |

They are **mutually exclusive** and every transition is confirmed by a popup.
Tagger mode is *tracking only* — invites, auto-leave, the grouped-in-combat
warning, markers and focus are all carry-side and stay off, because in tagger
mode being grouped with the other taggers is the correct state.

## Non-negotiable client rules

These were each learned by breaking them in-game. Do not re-litigate them.

- **Never measure a nameplate, or anything parented to one.**
  `NamePlateN:GetCenter()` and the same call on an addon-created child both throw
  *"Can't measure restricted regions"* for the entire duration of combat, and work
  fine out of it — so the bug looks intermittent. Anchoring, showing and setting
  text on those children is fine; it is *measurement* specifically that is blocked.
  Consequence: a mob's screen position is unknowable at the moment it dies, so
  death visuals are drawn at a fixed screen spot.
- **Setting focus is protected.** `FocusUnit` silently refuses from addon code.
  Never drive the chat edit box as a workaround — on a ticker it hijacks the
  user's typing every tick. The working answer is the `SecureActionButtonTemplate`
  button with `type="macro"` + `macrotext`, bound via `Bindings.xml`; a keybind
  press is a hardware event, so `/focus` runs. The addon only ever *observes* focus.
- **Secure attributes are locked in combat.** Refresh the macro button on
  `PLAYER_REGEN_ENABLED`.
- **Cosmetic code never runs before functional code** in an event handler, and is
  wrapped in `SafeCall`. A Lua error unwinds the entire handler; the X-burst
  position code silenced the badge *and* the 31% ding twice before this rule
  existed. Errors thrown inside `C_Timer` callbacks are worse — they unwind on a
  later frame where they are invisible and unattributable.
- **Guard every optional API member individually.** `C_FriendList.SendWho` exists
  on this client while `C_FriendList.SetWhoToUI` does not; checking only the first
  crashed the addon.
- Client differences follow WhoDoesWhat's `ClientFeatures.lua` idiom:
  `WOW_PROJECT_ID == WOW_PROJECT_CLASSIC` resolved once into named flags at the
  top (`isClassicEra`, `HAS_FOCUS`), never scattered inline checks. **Classic Era
  has no focus unit**; everything focus-based is skipped there.

## Architecture (single file, ordered by dependency)

Load order inside `TagTeam.lua` matters — functions are locals and must be defined
before use. Where that was impossible, a single forward-declared upvalue is used
rather than reordering: `ReportTaggedKill`, `SendAddon`, `linked`.

1. Constants and tunables (thresholds, textures, animation timings, markers).
2. Runtime state tables, all keyed by mob GUID and cleared in `Forget`/`ResetAll`.
3. Identity layer — `HasTaggers`, `TaggerKeyOf`, `MatchesTracked`, `MatchesCarry`,
   `ReassignMarkers`. Everything reads identities through here.
4. Mob worth — `IsGrey`, `IsBanned`, `IsWorthless`. Pure predicates over cached
   state, cheap enough for the 4 Hz repaint ticker.
5. Nameplate badges and the threshold stamp.
6. Screen-space death float (pooled marks).
7. Sounds, XP estimate, party logistics.
8. Addon comms.
9. Events, then slash commands.

## Important invariants

- Damage accumulates per mob GUID; the threshold is measured against
  `UnitHealthMax`, never against total observed damage — that survives partial
  observation, which matters because combat log range is ~50 yd.
- Reactive damage (`DAMAGE_SHIELD`, `DAMAGE_SPLIT` — Thorns, Retribution Aura,
  Lightning Shield, shield spikes) **never establishes tag ownership**, though it
  still counts toward the threshold.
- Worthless mobs — grey, `UnitClassification == "minus"`, critters, and banned
  names — get no ding, float, XP, marker or steal warning; only a plain checkmark.
- Mobs the carry tapped first show a standing X and suppress the ding, and the
  death handler skips them entirely. Counting their XP would be a lie.
- Marker slots are **derived, never handed out**: confirmed taggers sort by who
  answered first, unconfirmed by when they were added. Only three slots exist
  (triangle/diamond/orange, indices 4/3/2). Mob tags use 8/7/6 and cannot clash.
- "Confirmed" means their addon has talked to ours, or we have seen them on a unit
  token. Any name can be added; only a confirmed one can hold the triangle.
- Only the player we held **focus** on gets asked for an invite.

## Addon comms

Hidden addon channel over WHISPER, prefix `TagTeam`, so nothing appears in chat.

| Message | Direction | Meaning |
|---|---|---|
| `PAIRC` / `PAIRT` | either | Offer the inverse role. Always confirmed by popup — never applied unilaterally. |
| `OK` / `NO` | reply | Pairing accepted / declined. |
| `HELLO` / `HI` | either | Silent handshake, sent 5 s after login to re-verify saved links. |
| `INV` | carry → tagger | Ask for a party invite. **Only honoured from an established pair.** |
| `XP:<n>` | tagger → carry | Real XP from `UnitXP` deltas. `0` means max level. |

`db.linked` persists so a `/reload` does not silently drop back to visible
whispers. A saved link proves they *had* the addon, not that they are listening —
so a direct `INV` falls back to a readable whisper after 8 s if no invite lands.

## XP estimate

Formula verified against warcraft.wiki.gg, not memory. Base is
`mobLevel*5 + 45` in Azeroth but **`mobLevel*5 + 235` in Outland** — continent is
recomputed per kill, because at login the map system often isn't ready and
`GetBestMapForUnit` returns nil, which silently latches "Azeroth" and
under-reports every Outland kill by ~1.5×.

**When an estimate looks wrong, suspect the cached tagger level before the
formula.** One stale level applies a phantom penalty worth ~6% per level gap,
which reads exactly like a broken constant. Validated in-game: a level 62 Outland
mob at no level gap paid 544 against a predicted 545.

Rested (2×) and group splits are invisible to an addon, so the number is always
labelled an estimate. A linked tagger's reported XP is authoritative and should be
preferred wherever both exist.

## Releases (CurseForge automatic packaging)

Same pipeline as WhoDoesWhat. A GitHub push webhook feeds the CurseForge packager,
configured to package **tagged commits only** — pushes to `main` are free, a
release happens only when a tag lands.

One-time setup on the CurseForge side:

1. Create the project on the CurseForge author dashboard (name, summary, category,
   MIT license, supported game versions). Note the project ID.
2. In the project's settings, link the public GitHub repo
   `WallHackJack/TagTeam` and authorise the CurseForge GitHub app for it.
3. Set packaging to **tagged commits only**.

Per release:

- Set the TOC debug block's literal `## Version` to exactly the intended tag.
- Add the release summary to [CHANGELOG.md](CHANGELOG.md).
- Include both in the tagged commit, then `git tag 0.1.1 && git push origin 0.1.1`.

Rules that bite:

- Tag text becomes the packaged `## Version:` through `@project-version@`. Use
  plain `0.1.1`, **no `v` prefix**. A tag containing `alpha`/`beta` packages to
  that channel instead of Release.
- `.pkgmeta` sets `package-as: TagTeam` and ignores the dev docs. Anything added
  to the repo that shouldn't ship needs an entry there.
- `## Interface:` stays literal. CurseForge documents `@project-version@` but has
  no equivalent token for the current Interface number — revalidate it after
  client patches.
- Reference: [CurseForge automatic packaging](https://support.curseforge.com/support/solutions/articles/9000197281)
  and the [BigWigs packager](https://github.com/BigWigsMods/packager).

## Working checks

No automated test suite. For every change:

- `luac -p TagTeam.lua` to catch syntax errors before loading.
- Reload in-game and exercise the affected path.
- `/tag` for full status, `/tag diag` for the runtime picture including the last
  captured cosmetic error (cleared on read, so a second run shows whether it
  recurred).
