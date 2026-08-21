# TagTeam — agent instructions

TagTeam is a two-file Lua 5.1 addon for the WoW TBC Anniversary client. The
checked-out repository is also the user's live addon directory, so source files
must remain directly loadable by the game.

| File | Holds |
|---|---|
| `TagTeam.lua` | Everything: tracking, nameplates, XP, comms, party logistics, events. |
| `SlashCommands.lua` | `/tag` and nothing else. |

`SlashCommands.lua` is a **leaf** — it reads from the core, the core never reads
from it, and the entire boundary is the export block at the bottom of
`TagTeam.lua`. Keep it that way: anything the core needs back belongs in the
core. The TOC load order is what makes the exports available, so a new file must
be added there.

`db` is deliberately **not** exported at load — it does not exist until
`ADDON_LOADED`, so exporting it then would hand the slash file a nil forever.
The event handler assigns `ns.db` where it binds `db`, and `HandleSlash` re-reads
it per dispatch. Same trap applies to anything else assigned after load.

For the user-facing overview see [README.md](README.md). For the TBC experience
formulas the XP estimate is built on, see [XP_RULES.md](XP_RULES.md).

## The two roles

Every identifier in the codebase uses these words. They were deliberately chosen
after "taggee", "booster/boostee" and "driver/gunner" were all rejected —
*driver* especially, because it is reversible and two people assigned it to
opposite characters. Do not reintroduce any of them.

- **carry** — the high-level character doing the killing.
- **tagger** — a low-level character being levelled, who must deal `db.threshold`
  percent (default **38%**) of a mob's max health to earn credit for the kill.

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
  position code silenced the badge *and* the threshold ding twice before this rule
  existed. Errors thrown inside `C_Timer` callbacks are worse — they unwind on a
  later frame where they are invisible and unattributable.
- **Guard every optional API member individually.** `C_FriendList.SendWho` exists
  on this client while `C_FriendList.SetWhoToUI` does not; checking only the first
  crashed the addon.
- Client differences follow WhoDoesWhat's `ClientFeatures.lua` idiom:
  `WOW_PROJECT_ID == WOW_PROJECT_CLASSIC` resolved once into named flags at the
  top (`isClassicEra`, `HAS_FOCUS`), never scattered inline checks. **Classic Era
  has no focus unit**; everything focus-based is skipped there.

## Architecture (ordered by dependency)

Load order inside `TagTeam.lua` matters — functions are locals and must be defined
before use. Where that was impossible, a single forward-declared upvalue is used
rather than reordering: `ReportTaggedKill`, `SendAddon`, `linked`.

**`/tag` is a command table**, `commands["name"] = function(rest, cmd)`, not an
`if/elseif` chain. Aliases are assignments (`commands["rem"] = commands["remove"]`).
Handlers get `cmd` because three of them serve more than one name. Adding a
command means adding a table entry and a line to the help text in `commands[""]` —
there is no dispatch to edit. The chain it replaced was 575 lines and was what
pinned the file to the 60-upvalue ceiling; each handler now uses about six.

**Two names hold what used to be 64 file-level locals**, because the main chunk
is itself a function and every file-level `local` spends one of Lua 5.1's 200
register slots — see the ceiling note under Working checks.

- **`C`** — constants and tunables, fixed at load. UPPER_CASE fields.
- **`state`** — per-pull scratch, cleared by `Forget`/`ResetAll`. lowercase fields.

Both stay **declared where their explanations are** (`C.LOOT_ATTEMPTS` sits with
the loot-method comment, not hauled up into one block); the comment above a
constant is usually why it has that value. Add new constants and state as fields
on these rather than as new file-level locals. Subsystems get their own table the
same way — `Pets`.

1. Constants and tunables on `C` (thresholds, textures, animation timings, markers).
2. Runtime state on `state`, keyed by mob GUID and cleared in `Forget`/`ResetAll`.
   `C.PER_MOB` is the single list both of those iterate, so they cannot drift;
   `petOwner` is keyed by pet and `isTracked`/`isCarryGuid` by damage source, so
   none of the three is in it.
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
- **Nothing a player drives, and nothing PvP-flagged, is ever a tag.**
  `IgnoredUnit()` gates the damage path: enemy players by GUID prefix, their
  hunter/warlock pets by `Pet-`, and guardians and totems — ordinary `Creature-`
  GUIDs — by `UnitPlayerControlled` when a nameplate gives us a unit token.
  `db.ignorePvP` (default on, `/tag pvp`) adds `UnitIsPVP`, which catches the
  faction guards on contested Outland ground. Player-driven units are a **fact**:
  they pay no XP, so tracking them only ever produced badges and buzzes on
  non-tags. PvP-flagged NPCs are a **preference**: they do pay, but hitting one
  flags the tagger. Both token checks are blind past nameplate range, which is
  also the only range where the addon would have displayed anything.
- Worthless mobs — grey, `UnitClassification == "minus"`, critters, more than
  `C.IGNORE_LEVEL_GAP` levels below the lowest tagger, and banned names — get no
  ding, float, XP, marker or steal warning; only a plain checkmark. `IsGrey` and
  `IsFarBelowTagger` are kept apart on purpose: the first is Blizzard's zero-XP
  formula, the second is a preference about what the session is for.
- **Every worthless test needs a unit token first.** They all read a level or a
  classification, and those only exist once `CacheMobInfo` has had a token — so a
  mob nobody ever got a token for reads as *worth something* and collects cues.
  Nameplates were the only source, which missed two cases badly: critters usually
  have no nameplate at all, so the critter check never ran for the mobs it exists
  to catch, and the first hit routinely lands before the plate registers, which
  is exactly when `tapOwner` is decided and `TAGGED` is said. The damage path
  falls back to `target` then `mouseover`, into a **separate** variable from the
  nameplate `unit` — `UpdatePlate` and `SpawnPlateStamp` anchor to plate frames
  and must never be handed one of these.
- `UnitCreatureType` returns a **localized** string and there is no id-based
  equivalent on this client, so the critter test is best-effort (`C.CRITTER`
  prefers a client constant, falls back to the English word). The level gap is
  what actually carries that case.
- **"Auto-tagged" and "pays no XP" are two different things, and must not be
  merged again.** They were, once, and it produced checkmarks on mobs that still
  had to earn one.

  | | banned / grey / trivial | auto-tagged |
  |---|---|---|
  | why | pays no XP | tap doesn't decide credit |
  | threshold | meaningless | **still applies** |
  | plate | checkmark on any damage | normal climbing percentage |
  | can miss | no | **yes** |
  | carry taps it first | tag lost, standing X | costs nothing |

  Auto-tag is **only** about the tap. `TapLost(guid)` is the single predicate —
  `tapOwner == "carry" and not IsAutoTagged(guid)` — and the four places that
  used to test `tapOwner` directly all route through it: the standing X, the
  suppressed threshold ding, `WarnTagStolen`, and the silent `HandleDeath`. Add
  a fifth site and use `TapLost`, never a bare `tapOwner` comparison. Being
  **grouped** still applies to auto-tagged mobs — that wrecks XP by a different
  rule and is checked separately everywhere.
- **Defaults live in code; saved data holds only the delta.** `C.BANNED_DEFAULT`
  is the shipped ignore list, and `db.banlist` is tri-state: a string means the
  user banned that name, `false` means they turned one of ours off, `nil` means
  they never said and the default decides. Adding a default is a line in the
  table — no migration, and it reaches existing installs. The old scheme copied
  defaults into SavedVariables at first run, which meant a new one reached nobody
  who had ever played before. Apply this shape to any other defaulted list.
  Note `db.banlist[key] = DEFAULT[key] and false or nil` does **not** work —
  `and false` makes the expression falsy so `or nil` always wins. Use an `if`.
- Mobs the carry tapped first show a standing X and suppress the ding, and the
  death handler skips them entirely. Counting their XP would be a lie.
- **A wasted tag shows an X and says nothing.** `TagIsWasted()` — the carry
  grouped with their own tagger — is the shared predicate behind the `GROUPED`
  combat warning, the suppressed threshold ding, the suppressed plate stamp, and
  the silent death handler (no XP float, no miss alert, no session totals). The
  two-player rule computes the mob's XP from the *carry's* level, so the tagger
  banks a rounding error and every one of those cues would claim something
  untrue. One warning per pull, not one warning plus a lie.
- **`GROUPED` outranks `TAGGED`, and is said once per pull.** `WarnTagStolen`
  routes straight to `WarnGroupedCombat` when `TagIsWasted()`, and the tagger-tap
  branch calls it too. Whose tag it was stops mattering once the two-player rule
  is in play, so naming the theft would hide the bigger problem behind it.
  `WarnGroupedCombat` otherwise only rides `PLAYER_REGEN_DISABLED`, which **never
  fires again for someone who joined the party mid-fight** — these two call sites
  are the only places the warning can still be reached in that combat. Routed
  rather than duplicated, so it inherits `GROUPED_WARN_INTERVAL`: that rate limit
  is what makes it one warning per pull instead of one per mob tapped.
- **`groupTagged[guid]` is a latch, not a live read.** Tagger damage landing while
  grouped brands that mob, and the standing X on its nameplate outlives the group
  — dropping the party mid-pull must not quietly turn the X back into a promising
  percentage. It clears only when the mob dies (`Forget`) or evades back to full
  health. The full-health test needs `RESET_GRACE` seconds of quiet first:
  `UnitHealth` can still report the pre-hit value on the frame the combat log
  delivers a hit, so without it a mob would read as "full" the instant we damaged
  it and un-brand itself immediately.
- **A pet is a field on its owner's record, never a tagger of its own.**
  `info.pet` / `info.petKey` on `db.taggers` entries, `db.carryPet` for the other
  direction, and `pet`/`petKey` on `dynamicTaggers` entries read off `pet`,
  `partyNpet`, `raidNpet`. Putting a pet in the list instead would feed its level
  to `LowestTaggerLevel` and bias every XP estimate, hang a marker on it, and put
  it in the follow macro. Two independent ways in, and both are needed:
  `petOwner` by GUID from `SPELL_SUMMON` is exact but requires having witnessed
  the summon and dies with every loading screen; the **name** survives both,
  which is what makes a pet summoned before you arrived countable at all.
  `Pets.TaggerKey` is restricted to `Pet-` GUIDs so a wild mob sharing the name
  cannot bank tagger damage, and it deliberately does **not** cache into
  `isTracked` — that table means "this GUID is the tagger themselves", and
  `SampleTrackedLevel` reads it to decide whose level it just sampled.
- **Three ways in, and all three are load-bearing.** `SPELL_SUMMON` (exact,
  needs to have been witnessed), the `PET:` message (needs them running
  TagTeam), and the pet's **tooltip** (needs only a unit token — the one route
  that covers a tagger without the addon whose pet was summoned before you
  arrived). The tooltip scan hangs off `SampleTrackedLevel`'s non-player branch
  so it inherits every call site that already has: the 2 s sweep over
  `SCAN_TOKENS`, targeting, and mouseover. `targettarget` is the productive one,
  since a pet holding the mob sits there for most of a pull. Owner patterns are
  built from `UNITNAME_TITLE_PET` and friends, never a hardcoded `'s Pet`; if a
  client lacks those globals the list comes back empty and the route disappears
  rather than misfiring.
- Marker slots are **derived, never handed out**: confirmed taggers sort by who
  answered first, unconfirmed by when they were added. Only three slots exist
  (triangle/diamond/orange, indices 4/3/2). Mob tags use 8/7/6 and cannot clash.
- "Confirmed" means their addon has talked to ours, or we have seen them on a unit
  token. Any name can be added; only a confirmed one can hold the triangle.
- Only the player we held **focus** on gets asked for an invite.
- **The backup whisper asks whether a party formed *since* the request, never
  whether one exists now.** `AskForInvite` captures `sentAt` and its timer bails
  when `groupedAt >= sentAt`. A live `IsInGroup()` test is the wrong question and
  produced a loop: the link invite lands, we accept, `CheckAutoLeave` drops the
  party because the tagger is in range, and all of that fits inside
  `INVITE_FALLBACK` (8 s) — so the timer saw no group, whispered out loud, drew a
  second invite, and the pair bounced. `WHISPER_COOLDOWN` is the only thing that
  ever stopped it. Both entry points, the out-of-range ticker and `/tag inv`, go
  through the one function so they cannot drift.
- `TaggerKeyOf` and `IsPartner` answer different questions and are not
  interchangeable. Tagger mode keeps the carry **out** of `dynamicTaggers` on
  purpose — the carry's damage is never pooled — so `TaggerKeyOf` says no to our
  own carry. Anything about *trust* (auto-accept, honouring `INV`, free-for-all
  loot) must ask `IsPartner`, which matches either half of the pair.

## Addon comms

Hidden addon channel over WHISPER, prefix `TagTeam`, so nothing appears in chat.

| Message | Direction | Meaning |
|---|---|---|
| `PAIRC` / `PAIRT` | either | Offer the inverse role. Always confirmed by popup — never applied unilaterally. |
| `OK` / `NO` | reply | Pairing accepted / declined. |
| `HELLO` / `HI` | either | Silent handshake, sent 5 s after login to re-verify saved links. |
| `INV` | either | Ask the other end to invite *us*. Sent by the carry's out-of-range check and by `/tag inv` from either side. **Only honoured from an established pair.** |
| `THRESH:<n>` | either | New tag threshold, pushed by `/tag threshold`. Applied silently, **partners only**. Not relayed onward. |
| `XP:<n>` | tagger → carry | Real XP from `UnitXP` deltas. `0` means max level. |
| `PET:<name>` | either | Our own pet, by name. Empty name clears. **Partners only** — it writes into damage accounting. Sent on `UNIT_PET`, at login, and on every link established or re-verified; broadcasts are deduped against the last one sent, direct sends are not. |

`db.linked` persists so a `/reload` does not silently drop back to visible
whispers. A saved link proves they *had* the addon, not that they are listening —
so a direct `INV` falls back to a readable whisper after 8 s if no invite lands.

## Suspending in dungeons and raids

`Suspended()` is the single predicate: `db.instanceOff` (default on) and
`IsInInstance()` reporting `party` or `raid`. Deliberately **not** cached on a
zone event — `IsInInstance` is a cheap client-state lookup, so reading it live
means `/tag instance` takes effect the moment it's typed with nothing to
invalidate, and it's a *global*, which costs no upvalue in its callers.

It is enforced in one place that matters — the `OnEvent` dispatcher drops every
event not in `SUSPEND_EXEMPT` — plus `UpdatePlate` (so badges hide) and the four
`C_Timer` tickers, which the dispatcher can't see. The exempt list is small on
purpose: the two zone events are how we notice leaving, `ADDON_LOADED` must not
be skippable, `CHAT_MSG_ADDON` keeps pairing and threshold sync live with the
partner, and the nameplate add/remove pair is bookkeeping — dropping those would
leave `plates` holding units that no longer exist.

This is not politeness. In a dungeon the carry and tagger are necessarily
grouped, so the tag is worth almost nothing, and `CheckAutoLeave` would try to
drop the party mid-run while `CheckContact` whispered for an invite.

## XP estimate

Formula verified against warcraft.wiki.gg, not memory. Base is
`mobLevel*5 + 45` in Azeroth but **`mobLevel*5 + 235` in Outland** — continent is
recomputed per kill, because at login the map system often isn't ready and
`GetBestMapForUnit` returns nil, which silently latches "Azeroth" and
under-reports every Outland kill by ~1.5×.

**Detecting Outland: prefer the instance id, never a uiMapID range.** uiMapIDs are
renumbered per client — retail puts Outland at 101 with its zones in 100–111, this
client puts it at 1945 with Nagrand at 1951 — and in this client's block the
Outland zones interleave with the Azeroth zones the Burning Crusade added
(Eversong, Ghostlands, Azuremyst, Bloodmyst, Silvermoon, the Exodar), so a range
over it claims those too. `GetInstanceInfo()`'s 8th return is the Map.dbc id,
which has meant 530 = Outland since the Burning Crusade shipped; that is checked
first, and it also answers before the map system is ready. The parent-map walk
stays as the fallback for Outland instances, which report their own id.

**When an estimate looks wrong, suspect the cached tagger level before the
formula.** One stale level applies a phantom penalty worth ~6% per level gap,
which reads exactly like a broken constant. Validated in-game: a level 62 Outland
mob at no level gap paid 544 against a predicted 545.

Rested (2×) and group splits are invisible to an addon, so the number is always
labelled an estimate. A linked tagger's reported XP is authoritative and should be
preferred wherever both exist.

**One chat line per kill.** A missed mob still pays the tagger — the tap decides
that, not the damage share — so the `MISSED` alert and the `XP:<n>` report that
follows describe the same kill. The report is a whisper from the other client and
lands a beat later, so the chat line waits `MISS_LOG_DELAY` for it and prints the
combined version; `kill.logged` is the flag both paths check, so whichever gets
there first wins and the other stays quiet. The miss **sound and X burst are not
deferred** — they are the alert, the chat line is only the log.

Missed kills are queued for pairing like tagged ones. Leaving them out was
mispairing: the report would arrive, find no entry of its own, and claim the next
tagged kill's. Greys stay unqueued, because they pay nothing and no report can
ever arrive to pair with, so the entry would sit waiting for a real report to
claim by mistake. Missed kills are also kept out of `matchedEst`/`matchedXP` —
their estimate assumes a full tag they never made.

**Pairing an estimate with its report.** The kill and the `XP:<n>` that follows it
are separate events on separate clients, so the carry queues each tagged kill in
`pendingKills` and the report claims one. The ratio it prints is the only visible
handle on rested, splits and stale levels — the very things the formula can't see.

- Claims are **per tagger**, not a pop: damage is pooled against one threshold but
  XP is not, so one kill draws one report from *every* linked tagger and each must
  claim the same entry.
- Greys are never queued. They pay nothing, so `PLAYER_XP_UPDATE` never fires on
  the tagger's end and no report is ever sent; an entry left to expire would
  mispair the next real kill.
- Entries expire after `XP_MATCH_WINDOW` and the queue is capped at
  `XP_MATCH_MAX`, because kills outside the tagger's client range are reported by
  nobody and would otherwise accumulate for the whole session.
- The percentage printed is the **pooled** share, the same number the threshold was
  measured against. It is deliberately not broken down per tagger.

## Releases (CurseForge automatic packaging)

Same pipeline as WhoDoesWhat. A **GitHub webhook** feeds the CurseForge packager.
There is no CurseForge-side repo link or GitHub app — the whole integration is one
webhook on the GitHub repo. The webhook fires on every push, but CurseForge only
builds when the push carries a tag, which is why pushes to `main` are free.

One-time setup:

1. Create the project on the CurseForge author dashboard (name, summary, category,
   MIT license, supported game versions). Note the numeric **project ID** from the
   project URL.
2. Get an API token from CurseForge's API tokens page. It is **account-level**, so
   the same token serves every project — WhoDoesWhat's webhook already carries one.
3. Add a webhook at `github.com/WallHackJack/TagTeam/settings/hooks`:
   - Payload URL `https://www.curseforge.com/api/projects/<projectID>/package?token=<token>`
   - Content type `application/json`
   - Events: **just `push`**

WhoDoesWhat's working reference config is project `1617330`, content type `json`,
events `["push"]`.

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
- Upvalue ceiling — the local `luac` is 5.4, WoW is 5.1, and **5.1 allows only 60
  upvalues per function**. `HandleSlash` sits exactly on it: every file-level
  local it names costs a slot, so referencing one more helper stops the *whole
  file* compiling and the addon silently does not load. `luac` 5.4 will not warn
  (its limit is 255), and it counts `_ENV` as an upvalue where 5.1 does not — so
  the number below must stay **at or under 61**:

  ```
  luac -p -l TagTeam.lua | grep -A1 '^function <' | grep upvalues | sort -t, -k3 -n | tail -1
  ```

  Over the line: split `HandleSlash`'s `if cmd ==` chain into two functions
  rather than shaving references one at a time.
- **Main-chunk local ceiling — 200, and the file is near it.** Lua allows 200
  locals per function, and the main chunk is a function: every file-level `local`
  spends one. `luac -p` says `too many local variables (limit is 200) in main
  function`, pointing at whichever declaration happened to be the 201st, which is
  rarely the one at fault. Measure the headroom rather than guessing:

  ```
  cp TagTeam.lua /tmp/t.lua && for i in $(seq 1 8); do echo "local zz$i" >> /tmp/t.lua; luac -p /tmp/t.lua || { echo "headroom $((i-1))"; break; }; done
  ```

  Three ways to spend less, all of them in use: fields on `C` and `state` instead
  of a local per constant or table; a `do ... end` block, which releases its
  locals' slots at the end of it; and a subsystem behind one table (`Pets`).
  Tables also cost their callers **one upvalue instead of one per entry point**,
  which is why folding these took `HandleSlash` from 61 upvalues to 53 and
  `OnCombatLog` from 50 to 40 at the same time.

  **Verifying a mechanical rewrite like that.** `luac -p` proves nothing here — a
  reference the rewrite missed becomes a *global* read, which compiles fine and
  is nil at runtime. Dump what the file reads from `_ENV` and diff it against the
  previous version; the sets must be identical:

  ```
  luac -p -l -l TagTeam.lua | grep -o '_ENV "[A-Za-z_][A-Za-z0-9_]*"' | sed 's/_ENV "//;s/"//' | sort -u
  ```

  And check the string literals separately. A blind whole-word substitution also
  rewrites names inside user-facing text — `"pet damage "` became
  `"pet state.damage "` in four places, none of which any compiler would object to.
- Reload in-game and exercise the affected path.
- `/tag` for full status, `/tag diag` for the runtime picture including the last
  captured cosmetic error (cleared on read, so a second run shows whether it
  recurred).
