# TagTeam — agent instructions

TagTeam is a four-file Lua 5.1 addon for the WoW TBC Anniversary client. The
checked-out repository is also the user's live addon directory, so source files
must remain directly loadable by the game.

| File | Holds |
|---|---|
| `TagTeam.lua` | Everything: tracking, nameplates, XP, comms, party logistics, events. |
| `WallhackUiKit.lua` | Window chrome. **Shared verbatim with WhoDoesWhat** — see below. |
| `TagTeamView.lua` | The `/tag ui` window: which tabs there are, what is on them. |
| `SlashCommands.lua` | `/tag` and nothing else. |

Everything outside the core is a **leaf** — it reads from the core, the core
never reads from it, and the entire boundary is the export block at the bottom
of `TagTeam.lua`. Keep it that way: anything the core needs back belongs in the
core. The TOC load order is what makes the exports available, so a new file must
be added there.

The one edge between leaves is `SlashCommands.lua` reading `ns.ToggleView` from
`TagTeamView.lua`, which is why the view loads first. Keep that arrow pointing
this way: the view must never reach into the slash file.

## WallhackUiKit.lua is shared with WhoDoesWhat

`WallhackUiKit.lua` is **duplicated byte-for-byte** into WhoDoesWhat. The two
copies are kept identical by hand, deliberately, so both addons' windows are the
same windows. Rules that follow, and they are the whole point of the file:

- **Fix a bug here, then copy the entire file across.** Never patch one side.
- It may reference **nothing** from the addon around it. No addon object, no
  Ace, no logging hook, no constant from another file. `local ADDON_NAME, ns =
  ...` is the entire contact surface and works unchanged in either addon.
- Every number the chrome is built from lives in it. A view that declares its
  own margin has already started the drift — three WhoDoesWhat views each carry
  a private `SCROLLBAR_W = 26` today, which is the case in point.
- Helpers the *other* addon needs stay even with no caller here. `StyleDropdown`
  has no caller in TagTeam; deleting it for being unused would make the copies
  differ. Dead code in one addon is the price of the file being one file.
- Each addon gets its own private copy at `ns.UI`. Nothing is shared at runtime,
  only the source — no global, no LibStub, no revision guard, and no question
  about which addon loaded first.

Anything a second window or a pop-up would also want belongs in the kit.
Anything specific to what TagTeam is showing belongs in `TagTeamView.lua`.

WhoDoesWhat's `Views/SectionKit.lua` is where the kit's section primitives come
from — same boxes, header chain, row pooling and `[x]` button, with the
WhoDoesWhat-only parts (two columns, mass-mail, class tints) taken out so a
caller with one column can use them. The migration of WhoDoesWhat onto this file
has **not** happened yet: it still has its own `CreateWindowFrame`,
`StyleDropdown` and three private copies of `SCROLLBAR_W`.

## The tabs

`Players`, `General`, `Popups`, `Nameplate`, `Ignore`, `Sounds`, then `About`
pushed to the far right by `right = true` on its tab spec — the kit anchors that
run from the other end, so the gap is whatever is left over rather than a number
somebody has to keep correct.

**The window is where settings live now, and `/tag` is not.** Commands that were
only a toggle in disguise are gone — the threshold, badge position, the XP zone,
pet damage, the miss notice, PvP mobs, instances, announce, quests, the two mob
lists. What is left is the things you do rather than the things you set: adding
a tagger, pairing, asking for an invite, the master mute, status. Adding a
*setting* means adding a row to `OPTION_PAGES`, not a command; adding a command
is for something that happens rather than something that is.

**General, Popups and Nameplate are declared, not built.** `OPTION_PAGES` in
`TagTeamView.lua` is a table of boxes, each a list of rows naming the `db` key
it stands for; the builder knows checkbox, slider and dropdown and nothing about
what any of them mean. Adding an option is a line there.

Two fields carry the things that bit:

- **`after`** names what has to be re-derived once the value changes. A badge
  position nobody repaints is a setting that appears not to work.
- **`Set`** replaces the plain `db` write where the core has its own way in. The
  threshold uses it because it is *synchronised with the other client* — and it
  goes through `PushThresholdSoon`, which defers the whisper until the handle
  stops moving. Forty addon messages to say what the last one says is how you
  get muted by the server.
- **`requires`** hides a row this client cannot honour (`HAS_FOCUS`). A greyed
  row explaining that on every login is worse than the row not being there.
- **`labelW`** on a *box* puts every control in it in one column instead of each
  starting where its own label happened to end. Worth the number only where a
  box holds more than one; the Badge box is the only one that does.
- **`needs`** names another `db` key this row is meaningless without, and greys
  it while that one is off — the icon's padding and its side, with the warning
  icon switched off. Greyed with a reason, **not hidden**: a row that vanishes
  makes the box jump and takes its own explanation with it. Contrast `requires`,
  which does hide, because a client that has no focus unit will never have one.
- **`Reset`** on a *box* puts a Reset button in its header. It names a core call
  (`ns.ResetBadgeOptions`), never a table of defaults out here — the defaults
  live in the core and a second copy would be a second answer to what "default"
  means. `BadgeDefaults(force)` is that one answer: the load path fills in what
  was never set, the button overwrites, same function.

Every option value is in the window's refresh signature, because most of them
still have a `/tag` command and a window showing the opposite of what you just
typed is worse than no window.

**A box can be a list of names instead of rows of settings.** `mobs` on a group
carries `List`/`Add`/`Drop` and gets a `[+]` in its header, a bin on every row,
and its own scroll area capped at `MOB_ROWS_MAX`. The Ignore tab's two lists are
the only ones, and three things about them are deliberate:

- Every call goes through `ns.Mobs`. Saved data holds **only what the user
  added**; the defaults live in code and are never copied into it, which is what
  lets a new one reach an existing install with nothing to migrate.
- **A shipped entry cannot be removed one at a time**, and its bin is disabled
  with a reason rather than hidden — a row missing the button every other row
  has reads as a rendering fault. This replaced a tri-state where `false` meant
  "one of ours, turned off"; a stale `false` in saved data is now ignored and
  the default comes back. `Reset` is the way out, and it only has to `wipe` the
  saved table.
- **User entries sort first, shipped ones last and dimmer.** Not one
  alphabetical run: the shipped part is what nobody has to think about, and a
  name somebody added themselves is what they came here to find — sorting them
  together buries it in the middle of ours.
- They **scroll inside the box** rather than growing it. Two lists with no
  ceiling on one page, and without that a long one pushes the other off the
  bottom. `UI.ScrollSectionRows` has to be called before any row exists, for the
  same reason `ReserveSectionStrip` does.

**A box can bring a picture as well as rows.** `Build` and `Refresh` on a group
sit alongside `rows`, and the builder calls `UI.ReserveSectionStrip` to leave
room above the first one. That reservation **must happen before any row exists**
— a row anchors once, at creation, and will not move for it afterwards, which is
why `group.Build` runs inside `BuildOptionsPage` rather than at first refresh.

### The badge preview

The Badge box's first row is a picture rather than an option: a grey rectangle
the size of a nameplate with a **real badge** over it and a damage share
climbing past the threshold on a loop, so the settings under it can be watched
instead of being applied one reload at a time. It carries no label of its own —
"Preview" written over a picture of a nameplate says nothing the picture did
not, and it was a separate box once, which put a header between the settings and
the thing they change.

Everything on it comes from the core, through the exports beside
`UpdateAllPlates`: `ApplyBadgeStyle`, `DrawBadgeShare`, `ShowBadgeCheck` and
`BlankBadge`. **Keep it that way.** A preview that placed, graded, wrote or
animated a share by its own rules is a preview of nothing, and the drift would
not be visible until somebody trusted it. Each of those was split out of
`UpdatePlate` for exactly this, and every one still serves the real plate. The
preview frame builds the same four regions under the same names — `check`,
`deny`, `icon`, `text` — and sets no sizes or points of its own. It builds
`deny` too, which it never shows: a badge handed to the core has to be a whole
badge, or `BlankBadge` trips over the one region it did not bother to have.

The rectangle is deliberately a rectangle. The addon can never measure a real
nameplate, every nameplate addon draws something different inside the frame the
badge hangs off, and what the box has to show is where the badge lands relative
to a plate — which a plain box says and a drawing of a health bar would only
dress up.

**There are two rectangles, and one of them is invisible.** The badge anchors to
Blizzard's *base* plate frame, which is wider than the bar any nameplate addon
draws inside it. Drawing the visible rectangle at the base frame's size lied in
the one direction that matters: the badge came out sitting *on* the plate in the
preview while standing clear of it in game. So `area.anchor` is the base frame,
never drawn, and `plate` is the bar inside it, narrower by `PLATE_INSET` a side.
Horizontal only: the vertical anchors clear the frame by 4px rather than by the
inset, and above and below already read right.

`PLATE_INSET` is its own number and **deliberately not `C.BADGE_SIDE_INSET`**.
The two look alike and are not — the inset is how far the badge hangs off the
base frame, this is how much wider that frame is than the bar — and reusing one
for the other meant moving either moved both for no reason. Neither is a
measurement; every nameplate addon picks its own geometry, which is what the
offset sliders exist for.

`C.BADGE_SIDE_INSET` itself was **measured in game, not reasoned out**. It was
12, and 12 sat the badge far enough in that a side-mounted badge needed +8 dialled
back out of it on the X offset before it looked right. The offsets are for a
plate that puts its bar somewhere unusual; they should not be paying for our own
default being wrong.

Four things it depends on:

- The sweep runs off `OnUpdate` on the preview's own frame. A hidden frame gets
  none, so it stops on its own the moment another tab is picked and costs
  nothing while the window is shut. No ticker to cancel.
- It climbs in **random bursts of 3–6%**, because that is what damage does — a
  share jumps by whatever the last hit was worth and then sits there. An evenly
  sliding number would be a picture of something else.
- It turns round at 60%, **or past the threshold if that is set higher** —
  otherwise somebody running at 80% would watch a preview that never reaches the
  checkmark, which is the one moment it exists to show.
- A row carrying `holdPreview = <pct>` **pins the sweep to that share while its
  dropdown is open**, and picks up where it left off after. The font list uses
  it: two fonts are hard to tell apart when the number under them keeps moving.
  `HeldShare` checks `DropDownList1:IsShown()` *as well as*
  `UIDROPDOWNMENU_OPEN_MENU`, because that global is not cleared on close and
  alone would pin the preview for the rest of the session after one look.
- It calls `BlankBadge` before each run rather than jumping back to 10%, so the
  first share of the loop **appears** rather than merely changes — which is what
  makes the pop-in below visible in the preview at all.

### The pop-in, and why `showing` exists

A badge arriving out of nothing plays the same slam the checkmark plays when the
threshold is met. The first damage on a mob is news too, and a number that fades
up unannounced is easy to miss mid-pull.

`badge.showing` (`nil` / `"share"` / `"check"` / `"deny"`) is what tells an
appearance from a change, and the gate is **`not badge.showing`**, not "is not
already the share". A mob taken past the threshold by its first hit shows a
checkmark, which slams on its own — without that gate the two animations would
land on top of each other on exactly the pull where the badge matters most.

Consequences: `PlayBadgeStamp` decides nothing about what is on screen, the
callers do; `ShowBadgeCheck` and `BlankBadge` exist so the bookkeeping cannot be
forgotten at one of the several sites that show or clear a badge; and anything
new that puts something on a badge has to set `showing`, or the next thing to
arrive will pop in when it should not.

The box is deliberately **not** tall enough for the ±100 offsets. One that was
would be mostly empty every other minute of its life; `SetClipsChildren` is what
shows an extreme offset leaving instead of drawing it over the rows below.

### The font dropdown

`SHIPPED_FONTS` is the game's own four, which are on every client. Anything
beyond that comes from **LibSharedMedia-3.0 if some other addon you run has
loaded it** — that library is how nearly every addon with a font dropdown fills
one, so borrowing its list when it is there gets the same fonts as the rest of
your UI for no dependency of ours, and its absence costs a shorter list and
nothing else.

`db.badgeFont` stores a **path, never a library key**: a path is what `SetFont`
takes and is the half that still means something once the addon that registered
the name is uninstalled. When it stops resolving, `SetBadgeFont` puts
`STANDARD_TEXT_FONT` back — checked by asking `GetFont` afterwards, because a
`FontString` whose `SetFont` failed renders *nothing at all*, and `SetFont`'s own
return value reports success on some clients and nothing on others. `""` is the
game font rather than a fifth path, so "Default" follows the client's locale.

**Long lists go into submenus, and that is not decoration.** Blizzard's dropdown
draws its buttons in one column and **does not scroll them**, so a list past the
screen edge has a bottom nobody can reach — which is exactly what happened the
first time this shipped as a flat list with a cap on it. `UI.CreateDropdown`
understands an entry carrying `entries` instead of a `value` as a submenu;
*which* entries get grouped is `FontChoices`' business, since only it knows the
list means fonts. Do not "fix" a too-long dropdown by raising a cap.

**Every row is drawn in the font it names**, with `" - 25%"` on the end of it —
the same share the preview holds at while the list is open. A name in a uniform
font tells you what a font is called; it does not tell you whether its digits
are legible at speed over a mob's head, which is the only question being asked.
A dropdown button takes a **Font object** and nothing else, so `SampleFont`
builds one per row off a counter (`CreateFont` needs a global name) and
`UI.CreateDropdown` passes it through as `info.fontObject`. Same `GetFont`
fallback as the badge: a font object whose `SetFont` did not take draws nothing
at all, which would turn a row into a blank line.

### Where the badge sits, and what faces the plate

`SetBadgePosition` is the only way the position moves, and it carries two
consequences that must not be split off:

- **The offsets go back to zero.** They are a nudge measured against one side.
  A `+40` that lined the badge up beside a health bar means nothing above it.
- **`db.badgeTextFirst` follows the side.** It is really a preference about
  which end of the badge faces the plate, so `left` sets it and the others clear
  it. It stays a checkbox so somebody can disagree.

`C.BADGE_JUSTIFY` pins the badge's contents to the edge facing the plate —
`RIGHT` when the badge is left of the plate, `LEFT` when it is right, `CENTER`
above and below. The text is whatever width the number is, so a centred string
grows *both* ways: fine over the plate, wrong beside it, where one side is up
against the nameplate and the other has the rest of the screen.

Defaults are **right, percent sign on, warning icon on**, with sizes at 26/30
and a 1px gap — a configuration somebody arrived at by using the thing, not a
set of round numbers. Both size ranges run well past them: a badge is read at a
glance from across a pull, on whatever resolution and UI scale somebody happens
to run, so the top of each is set by what stays legible rather than by what
looks sensible in the options window. `badgeTextFirst` is not defaulted flat: it follows the
position, so the shipped `right` gives `false`. No migration was written for the
move off `above` and none is wanted — anyone who set a position already has one
saved, so the default only decides for somebody who never said.

### LayoutBadgeContents measures nothing, and cannot

The warning icon is a real `Texture` beside the number, not a `|T…|t` run inside
it — a run inside a font string can be given neither a size nor a gap of its
own, and both are sliders. That buys the layout a problem: two regions have to
be arranged relative to each other **on a frame parented to a nameplate**, where
`GetStringWidth` throws for the whole of combat like every other measurement.

So the two are chained to each other and the only number in the arithmetic is
`db.badgeIconSize`, which is a setting we already hold. **Centring the pair
falls out of that**: stepping the text half an icon plus half a gap off centre
leaves exactly the room the icon then fills on the other side, whatever width
the text turned out to be. Do not "improve" this with a width lookup.

`withIcon` is memoised on the badge as `laidOut`, because it flips as a share
crosses `SHARE_MIN` and re-anchoring on every 4 Hz pass would be four `SetPoint`
calls per plate for nothing. **Anything that hides the icon by hand must clear
`laidOut`**, or the memo refuses to bring it back and the icon never returns;
`HideBadgeShare` is the one place that does, and every site that hides the
number goes through it.

`db.badgeIconSize` sizes the badge FRAME, so the checkmark, the X and the
warning icon move together. They are three faces of one mark, and a slider
called "Icon Size" that moved one of them would be lying.

## Every screen burst is a row in C.BURSTS

Mark, colour, and the flag that silences it, per kind — the same shape `C.CUES`
has and for the same reason. The Popups tab both **lists** these and offers a
**Test** button for each, so a window picking its own texture and colour for a
preview would drift from the thing it was previewing and nobody would notice
until the real one fired.

`Burst(kind, label)` is the only way one is drawn. The first three keys are
`ShareBand`'s return values, so a verdict picks its own mark; the last two are
their own events and carry a fixed label.

- **The three verdicts have three flags now**, where the full-XP burst had none
  at all and the acceptable one rode the miss flag. The one verdict worth
  celebrating could not be switched off, and the one worth *tightening* could
  not be switched off separately from the one worth regretting.
- The missed path in `HandleDeath` stays alive if **either** of its two flags is
  on, and `FloatKill` picks which mark to draw. Gating the path on one of them
  would silence the other.
- **`TestNotice` deliberately ignores the flag.** You press Test to find out
  what a thing looks like, usually while deciding whether to leave it on, and a
  button that quietly did nothing because the box beside it is unticked reads as
  broken. It fires the **sound too** — half of what somebody is judging is what
  it sounds like — and the three verdicts get a random plausible label off
  `TestKillLabel`, in the shapes `FloatKill` builds. Random so two presses do
  not look like one frozen screenshot; nothing reads the number afterwards.
- **`cue` on a burst names its row in `C.CUES`**, which is what the Popups tab
  hangs an audio button on. `tagged` has none on purpose: the sound for clearing
  the threshold is `tag`, and that fires when the mob *crosses* it rather than
  when it dies. A second one on the kill would be the same news twice.
- `C.QUEST_NOTICES` is the same shape for the three quest rows, so the tab can
  treat all eight alike instead of special-casing three of them.

The audio button opens the Audio tab's own `AskSound` pop-up, which now carries
an **Enabled** checkbox (`opts.toggle` on the kit's prompt). Two tabs list
overlapping things, and sending somebody to the other one to switch off what
they just listened to is a round trip for one tick box. It applies on click
rather than on Accept, like the volume slider beside it and for the same reason.

Row order is the same on both tabs and worth keeping that way — they list
overlapping things, and a control that changed sides between them would have to
be found twice:

    [✓] [mark] Label ……………… [speaker] [Test!]

The **box first**, because a column of them down the left edge is what makes a
list of settings scannable. **Test outermost**, because it is the one you press
repeatedly while tuning. The row's mark is a real `ROW_ICON`-sized texture, not
an inline `|T…|t` — that sizes to the FONT, and came out half the size of the
same icon one tab over.

Rows carry the mark they draw, because that is how somebody arrives: they saw a
thing over a mob and want to know which switch it was.

The quest marks are the game's own — `!` for accepted, `?` for an objective,
gold `?` for a hand-in — which is the whole point of using them: everybody
already reads those. **`SetQuestIcon` picks the source**, because the
gossip-frame set is 16px art and soft at an 18px row icon while the atlas
versions are the modern high-resolution ones and are not on every client.
`C_Texture.GetAtlasInfo` is the guard: `SetAtlas` on a name this client does not
have is not something to discover at runtime.

**X for a loss, `!` for a mistake you are still standing in.** A mistag is gone
and cannot come back, so it takes the X and red; being grouped is something you
can walk out of, so it takes the warning mark and orange — the same pairing the
badge already uses for a share that has not failed yet.

## The window decides nothing

`TagTeamView.lua` has no rules in it. Every button ends in a `ns.Roster` call,
because `/tag` and the window are two front ends to one set of invariants and
the moment each enforces its own they drift.

That is why `Roster.RequestTagger` / `Roster.RequestCarry` exist: the mode-switch
guard and its confirm popup used to live inside `commands["add"]` and
`commands["carry"]`, where the window could not reach them. `"switch"` back from
either means the popup was raised and the caller reports nothing — the popup's
own `OnAccept` does that. `Roster.RemoveTagger` moved for the same reason.

`Roster` also owns the two remembered lists, `db.carries` and `db.followTargets`.
**Neither changes the two modes.** `db.carries` is a roster of names you have
boosted with; exactly one is active at a time, the one `db.carryKey` names, and
`Roster.Carries` pins that one to slot 1. Forgetting the active carry is refused
outright — it is a mode, not a list entry.

The window refreshes off a half-second signature check while it is open, rather
than the core calling into it. That keeps the leaf a leaf, and it means a change
made from `/tag`, or by a confirm popup accepted a minute after the click that
raised it, shows up on its own. Presence is part of that signature on purpose —
a ping that goes unanswered becomes "offline" when its timeout passes, and
there is no event to hang a refresh on.

## Pinging

`PING` / `PONG` over the same hidden whisper channel as everything else. Their
client answers with level, class file and zone; it lands in **`db.seen`**, a
directory keyed by name that belongs to no one list — the same character can be
a remembered carry here and a tagger on your other login, and where they are
does not depend on which.

Both halves are **symmetric and restricted to `Roster.Knows`**: we ping only
names we have written down, and we answer only people who have written us down.
A `PONG` reports your zone, so a stranger who guessed the prefix gets nothing.

There is **no timer behind "offline"**. `Roster.Ping` stamps `asked`, a reply
stamps `at`, and `Roster.Presence` reads the pair at the moment somebody looks:
an `asked` newer than any `at`, past `C.PING_TIMEOUT`, *is* silence. A timer to
reach the same answer would be one more thing to leak. `Roster.Presence` returns
one of `here` / `waiting` / `silent` / `unknown` — deciding that in the core is
what keeps the view free of rules.

The tagger half of a `PONG` (writing `level` onto the tagger record via
`NoteTaggerLevel`) is handled in `OnAddonMessage` rather than in
`Roster.NoteSeen`, because `NoteTaggerLevel` is a local defined after `Roster`.

## Every sound is a row in C.CUES

There is no `PlayAlertSound`/`PlayMissSound`/`PlayShortSound` any more. Every
noise the addon makes is an entry in `C.CUES` and is played as
`Cues.Play("<key>")`, which gates on that entry's `enable` flag.

**This is the point of it.** The quest-accept, quest-complete and level-up
fanfares shipped with no flag at all — nothing but the master mute could silence
them — because each was added as a one-off `PlayCue` at its call site. Adding a
cue is now adding a row, and a row without an `enable` does not work.

Reading a row: `file` is a db key holding a path, where `false` means "the user
picked an id, do not put the default path back" and `nil` means "nothing saved,
use `files`". That distinction is load-bearing — `nil` gets re-defaulted at
`ADDON_LOADED` and `false` does not.

**A cue that is off makes no sound, previews included** — the volume slider, the
Test buttons, all of it. Off means off, and a preview that played anyway would
be the one place in the addon where a silenced cue still made noise. The
consequence to know before "fixing" it: quest progress ships off, so its volume
slider does nothing until the cue is enabled, which is why the sound pop-up
carries its own **Enable this Audio Queue** box directly above the slider.

**Quest progress has no `files`, and that is a correction rather than an
oversight.** It briefly defaulted to `Sound\Interface\iQuestUpdate.ogg`, on the
reasoning that the accept and complete cues live in that directory under that
naming — the reasoning was right and the result was wrong. That path resolves to
the engine's objective-complete flourish, the same weight of noise as accepting
a quest, for something that fires **once per mob** on a kill quest. It is a tick,
not an announcement. `C.LEGACY_QPROG_FILES` sweeps the saved path back off
anyone who ran that build. The test for a file here is not whether it plays; it
is whether you could stand thirty of them in a minute.

Two things that look like sound flags and are not:

- **`db.missAlert` is the low-XP NOTICE**, not its sound — one of the five
  entries in `C.BURSTS`, which is why it sits on Popups rather than Audio. The
  audio half is `db.missSound`.
- **The near miss has no flag of its own.** It rides `db.missSound` because it
  and the miss are one notice graded two ways, and somebody who silenced misses
  did not mean "except the near ones". The window shows that as a checkbox
  disabled with a reason rather than hiding it.

`/tag` keeps exactly one sound command, `/tag sound`, which toggles the master
`db.audio`. Which cue plays and what each is set to belong to the Audio tab.

`C.CUE_SECTIONS` groups the rows into the boxes the tab draws — `pull` for the
four verdicts, `progress` for what your partner is getting on with. A cue's
`section` field decides which box it lands in.

### The four pull verdicts

They are four different pieces of news and each has its own flag. Do not
re-merge them:

| Cue | Says | Fires from |
|---|---|---|
| **Kill Ready** | the threshold cleared | the combat-log threshold crossing |
| **Acceptable Kill** | short of the threshold, past the minimum | `ShareBand(pct) == "short"` |
| **Low XP Kill** | the share was too small | the other arm of that same branch |
| **Mistags** | the tap was lost — stolen, or spent by being grouped | `TapLost` / `groupTagged` / `TagIsWasted` |

The first three grade the same measurement; **Mistags is a different event** and
was previously sharing the miss cue, which made "somebody stole it" and "you
were nearly there" the same noise.

Acceptable Kill used to have no flag of its own and rode `missSound`, shown as a
permanently disabled checkbox. That read as broken — which is exactly how it was
reported — so it has `db.nearSound` now. `db.mistagSound` is likewise split out.
Both default to whatever `db.missSound` was, so nobody's cues changed under them.

`Cues.Describe` says **"Default"** whenever nothing is saved, the saved path is
one the cue ships with, or the saved id is the cue's own `fixedId`. A deliberate
non-default id shows as **`#877`**. All four progress cues are path-first with an
id backstop now, so "Default" means the same thing on every row.

### Volume moves a CVar, so the default never does

This client's `PlaySoundFile` takes no volume. The only lever is
`Sound_SFXVolume`, the CVar the "SFX" channel already rides, so a cue that wants
to be quieter is played with that CVar moved and put back after.

**It has to stay moved for the length of the cue, and this was the bug.** The
mixer reads that CVar *continuously* — that is how the game's own slider changes
a sound already playing — so setting it, starting the sound and restoring on the
next line played every cue at the original volume. The per-cue volume slider
appeared to do nothing, which is precisely what it did.

**`Cues.GameVolume` must never read the CVar while we are holding it.** This is
the subtle one and it bit hard: during a hold the CVar *is* our scaled value, so
computing the next cue from it multiplies our own scaling in a second time, and
the one after that a third. Every cue came out quieter than the last until they
vanished, the "follow the game's volume (40%)" label counted itself down to 1%,
and nothing could raise it again because the number being scaled had already
been scaled. `db.sfxRestore` is what the user actually set, so while it is
non-nil it *is* the answer. Do not "simplify" that branch away.

The formula, in order: **game SFX (1 when not following it) × `db.volume` ×
`db.cueVolume[key]`**, all as 0..1 scalars.

The hold has a cost that cannot be designed away: there is one volume lever on
this client and it is the whole SFX channel, so while we hold it the **game's
own sound effects ride our number too**. That is why the hold is kept to roughly
one cue, and why `Cues.Volume` returning nil for the default configuration
matters — somebody who has not asked for a different volume never pays it.

The restore runs on a `C_Timer` after `C.CUE_VOLUME_HOLD`, and two things guard
it:

- **Only the last cue to start puts it back.** `state.sfxHold` is a token; an
  earlier cue's timer firing part way through a later one would jump the volume
  mid-sound.
- **The value to restore lives in `db`, not `state`.** A reload or a disconnect
  inside the hold would otherwise leave somebody's Sound Effects slider where we
  put it with no record of where it was. `Cues.ReleaseVolume` runs at
  `ADDON_LOADED` for exactly that, and is a no-op when nothing is held.

**All three volumes multiply**: the game's Sound Effects slider (while
`db.useGameVolume` is on), `db.volume`, and the cue's own `db.cueVolume[key]`.
Turning off "follow the game" does not disable ours — it means we stop caring
what the game's slider says and play at our number regardless.

That CVar cost is why **`Cues.Volume` returns nil in the default
configuration**: with `db.useGameVolume` on and both our sliders at 100%,
nothing is touched at all and the cue plays on SFX exactly as it always did.
Only somebody who has asked for a different volume pays for one. Keep it that
way — a change that makes the CVar path unconditional would move every user onto
it for no gain.

`Cues.PathOk` answers whether a cue's file is actually on this client, by
starting it and stopping it in the same call — the only thing that can answer is
`PlaySoundFile`, and `StopSound` takes effect immediately, which is what makes
the check inaudible. Cached on `state`, never on `db`: a file can appear or
vanish between sessions, and a saved "missing" would outlive the reinstall that
fixed it. `Cues.Playable` is the uncached form, for a path somebody is still
typing.

`db.cueVolume[key]` stores 100 as **absent**, which is what keeps that cheap
path the common one.

### The level-up popup

A tagger dinging is the event the whole addon exists to produce, and it used to
be one chat line that scrolled away behind the pull it arrived in.
`TAGTEAM_LEVELUP` is raised from the `LEVEL` message only — never from
`SampleTrackedLevel`, because a unit scan *discovering* a level we did not know
is not the same event as somebody levelling while you watch.

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
  percent of a mob's max health to earn credit for the kill — the **ideal
  target**, default 40%. `db.shareMin` (default 31%) is the **minimum**, under
  which the kill is a write-off however it ends. Both are clamped to
  `C.TARGET_MIN..C.TARGET_MAX`, the range the XP curve actually bends over;
  outside it there is nothing to tune. Only the ideal is on the wire.

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
6. Screen-space floats (one pooled set): the death burst, and the quest-progress
   notice above it. `LaunchMark` is the shared flight path.
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
  `db.ignorePvP` (default on, Ignore tab) adds `UnitIsPVP`, which catches the
  faction guards on contested Outland ground. Player-driven units are a **fact**:
  they pay no XP, so tracking them only ever produced badges and buzzes on
  non-tags. PvP-flagged NPCs are a **preference**: they do pay, but hitting one
  flags the tagger. Both token checks are blind past nameplate range, which is
  also the only range where the addon would have displayed anything.
- Worthless mobs — grey, `UnitClassification == "minus"`, critters, more than
  `C.IGNORE_LEVEL_GAP` levels below the lowest tagger, and banned names — get no
  ding, float, XP or steal warning; only a plain checkmark. `IsGrey` and
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
| `THRESH:<n>` | either | New tag threshold, pushed by the General tab's slider. Applied silently, **partners only**. Not relayed onward. |
| `XP:<n>` | tagger → carry | Real XP from a **kill**, read off `UnitXP`. **One message per mob, not per event** — see the tick-splitting note under XP estimate. `0` means max level. |
| `XPQ:<n>:<title>` | tagger → carry | Quest turn-in. Title may be empty. Printed, tallied in `state.offTagXP`, and claims **no** pending kill. |
| `XPD:<n>` | tagger → carry | Zone discovery. Same handling as `XPQ`. |
| `QACC:<title>` | tagger → carry | Quest accepted. No XP rides on it and nothing is tallied — it prints and plays the accept fanfare. **Partners only**, and never sent without a title. |
| `QDROP:<title>` | tagger → carry | Quest abandoned. Same handling, **no cue** — see the `QUEST_REMOVED` note below for why it arrives a second late. |
| `QPROG:<text>` | tagger → carry | An objective ticking over — the yellow centre-screen text, forwarded verbatim. **Partners only**, no cue. Printing is gated on the receiver's `db.questProgress`; `QACC` and `QDROP` are gated on `db.questAccepted`. |
| `REST:<pct>` | tagger → carry | Rested pool left, as a **percentage of their level's XP** (`0` = none). Feeds `state.taggerRested` and so `RestedFactor`. **Partners only** — it decides whether every estimate doubles. Pushed on the crossings, every `C.REST_STEP` of drift, and forced at the handshake and on a ding. |
| `LEVEL:<n>` | tagger → carry | They dinged. Feeds `NoteTaggerLevel` and plays `C.DING_CUE`. **Partners only** — it writes the number every XP estimate is measured against. |
| `PET:<name>` | either | Our own pet, by name. Empty name clears. **Partners only** — it writes into damage accounting. Sent on `UNIT_PET`, at login, and on every link established or re-verified; broadcasts are deduped against the last one sent, direct sends are not. |

`db.linked` persists so a `/reload` does not silently drop back to visible
whispers. A saved link proves they *had* the addon, not that they are listening —
so a direct `INV` falls back to a readable whisper after 8 s if no invite lands.

**Cues that are not in the pull.** `C.DING_CUE`, `C.QUEST_FILES` and
`C.QUEST_CUE` go through `PlayCue` like everything else, so they respect the
`db.audio` master mute. `PlayCue` takes a **table** of candidate paths as well as
a single one — the first that this client actually has wins, and `PlaySoundFile`
returning false is what says so — and it plays the id only `if id`, so a cue with
no key on this client is **silent rather than wrong**. A made-up id does not
fail; it plays some unrelated noise.

`SOUNDKIT.LEVELUP` is verified: the addon already uses it as the fallback
threshold cue. It does not collide with that in practice, because `PlayCue`
prefers a file and `db.soundFile` defaults to WeakAuras' Brass.

**Accepting a quest makes two sounds, and only one of them means "accepted".**
The quest log's paper page-turn comes first, then the drums-and-horns fanfare.
`SOUNDKIT.IG_QUEST_LIST_OPEN` is the **page-turn** — this cue shipped as that by
mistake, and it sounded wrong because it *was* wrong. The fanfare is engine-side
and no exposed SOUNDKIT key on this client is it, so it comes from
`C.QUEST_FILES` by path instead. The page-turn id stays as the last resort
precisely because it is recognisable: **if you hear paper instead of horns, every
path in the list missed.** Verify a path in game — it prints true or false:

```
/run print(PlaySoundFile([[Sound\Interface\iQuestActivate.ogg]]))
```

**Confirmed in game: this client resolves `Sound\Interface\` paths, and
`iQuestActivate.ogg` is the accept fanfare.** That settles the open question from
when `C.QUEST_FILES` was written, and it is why `C.QUEST_DONE_FILES`
(`iQuestComplete.ogg`, played on `XPQ`) was built the same way rather than hunted
for as a SOUNDKIT key. Its backstop is `IG_QUEST_LIST_COMPLETE` rather than the
page-turn: a completion cue that lands on the wrong sound should at least be a
completion sound.

**Three quest flags, not one.** `db.questProgress`, `db.questAccepted` and
`db.questComplete` are separate because they are three different volumes of
noise: objectives tick over once per mob, accepts happen a few times an hour,
and hand-ins are XP reports. One flag meant silencing the first also silenced
the last, which is the one nobody wants silenced.

`db.questComplete` gates the **announcement only**. `state.offTagXP` is banked
above the gate, deliberately — a session total that moved with a notice setting
would be a lie.

**`QUEST_REMOVED` cannot tell a hand-in from an abandon**, and it can arrive
*before* the `QUEST_TURNED_IN` that would have distinguished them — both facts
read off `Questie`, which runs on this client. So a removal waits
`C.ABANDON_GRACE` (1 s, the same figure Questie uses) and only counts as
abandoned if no turn-in has claimed the id by then. `turnedIn` is keyed by quest
id and cleared in that callback whether or not it fires, so it cannot accumulate.
The title is read **at the removal, not in the callback**, while the client still
has the quest to be asked about.

**Filter the yellow centre-screen text by TYPE, never by its words.**
`UI_INFO_MESSAGE(errorType, message)` carries *every* one of those messages —
loot method changes, party notices, duel results — so `QPROG` has to sort them.
`GetGameMessageInfo(errorType)` returns the **name of the global string** behind
the type (`"ERR_QUEST_ADD_KILL_SII"`), so `C.QUEST_PROGRESS` is a plain set
lookup on that name: locale-proof for free, with no pattern to build, nothing to
escape, and no format specifiers to go stale in a language nobody tested. This is
the one place in the file where a localised string did **not** need the
escape-then-reopen treatment, and the reason is worth remembering.

The set is `Questie`'s, which does exactly this on this same client.
`ERR_QUEST_COMPLETE_S` is deliberately **absent**: a finished quest already
announces itself when it is handed in, as `XPQ`.

The text is forwarded **verbatim**. The client that produced it has already
formatted and localised it, so rebuilding it on the carry could only make it
worse — and the carry may not even share the tagger's locale.

**One pool, two kinds of float, one flight path.** The death burst and the
quest-progress notice share `state.markPool` — frames cannot be destroyed in WoW,
so everything that floats is pooled — and both go up through `LaunchMark`, which
owns the rise, the hold and the fade. That sharing is the point: "the same
fashion" is a requirement, and two copies of the cadence would drift.

Consequences worth knowing before touching either:

- **The label is re-anchored per spawn, not once at creation.** The burst hangs
  it under the icon; the quest float centres it on the frame and clears the
  texture. A pooled frame arrives in whatever state the last spawn left it, so
  both paths set it explicitly. Same reasoning as the texture already had.
- **The three timing constants are read together.** `FLOAT_FADE_DELAY` is the
  OPAQUE hold, and the fade runs for `FLOAT_DURATION - FLOAT_FADE_DELAY`. So
  lengthening a float means lengthening the *hold* and leaving the fade alone —
  stretching the fade instead just leaves text half-there for longer. And
  `FLOAT_RISE / FLOAT_DURATION` is the drift speed, so raising the duration on
  its own slows everything whether you meant it or not; `RISE` moves with it
  when you did not.
- **Heights are derived, not typed twice.** `C.QUEST_FLOAT_RISE` is
  `MARK_RISE + MARK_SIZE + 24`, so it stays clear of the burst if the burst is
  ever resized or moved.
- **The stagger exists because objectives tick together.** Two in one instant
  would land on the same pixel and read as one smeared line, so each takes the
  next of `C.QUEST_FLOAT_ROWS` slots. The row resets once the previous float has
  cleared, so an ordinary trickle always uses the first slot.
- Yellow (1, 1, 0), deliberately not the XP text's gold (1, 0.86, 0.3): they
  share a flight path a line apart, and near-identical colours read as one notice.
- It is **cosmetic**, so it runs last in the handler and behind `SafeCall` — a
  fault in the float must not take the chat line with it.

Measuring `UIParent` is fine, and is what both floats do. The restriction that
matters is on nameplates and anything parented to them.

**Three colours in one float, from one FontString.** The label is a single
FontString, so the only way to colour parts of it differently is inline
`|cAARRGGBB … |r` runs, which a FontString honours regardless of what
`SetTextColor` set. Two things follow, and both are load-bearing:

- `|r` reverts to the **base** colour, which `SpawnQuestFloat` has already set to
  yellow — not to white. So only the runs that differ need escaping, and the
  sentence between them needs nothing.
- `TaggerName` returns the name **bare** when the class is unknown, rather than
  wrapping it in the yellow it would have been anyway. An uncoloured name reads
  fine; a guessed colour is just wrong.

The class is cached in `SampleTrackedLevel`, which is the only place the addon
ever holds a unit token for a tagger. It costs one `UnitClass` call on a path
that already had the token, is written once (a character's class never changes),
and saves into `db.taggers[key].class`. Before it is learned — a fresh pair who
have not been in sight yet — the name simply comes out yellow.

`C.HEX_XP` is the epic-item purple, not the XP bar's own `(0.58, 0, 0.55)`, which
is dark enough to vanish against a night sky.

## Suspending in dungeons and raids

`Suspended()` is the single predicate: `db.instanceOff` (default on) and
`IsInInstance()` reporting `party` or `raid`. Deliberately **not** cached on a
zone event — `IsInInstance` is a cheap client-state lookup, so reading it live
means the Ignore tab's switch takes effect the moment it is set with nothing to
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

**One session total, never two.** `/tag` and `/tag stats` print the *confirmed*
total the moment `state.reportedKills > 0`, and stop printing the estimate
entirely — not beside it, not in brackets. Two totals for one session invites
reading the wrong one, and the estimate is the wrong one. `state.sessionXP` keeps
accumulating either way, because the pairing line still needs
it; it is only the *display* that goes.

The pairing line (`expected N, actual M, 1.02x`) still shows both, and that is a
different job: it is the one place the contrast is the point, and it is how a
stale cached level gets caught.

**When an estimate looks wrong, suspect the cached tagger level before the
formula.** One stale level applies a phantom penalty worth ~6% per level gap,
which reads exactly like a broken constant. Validated in-game: a level 62 Outland
mob at no level gap paid 544 against a predicted 545.

**`NoteTaggerLevel` is the only place that number moves**, and two things reach
it. `SampleTrackedLevel` reads `UnitLevel` off a unit token, which needs them in
front of you; a linked tagger also sends `LEVEL:<n>` from `PLAYER_LEVEL_UP`,
which is the only path that survives them being out of range. Use `arg1` there —
`UnitLevel("player")` has not necessarily caught up when that event fires.

The `LEVEL` handler plays `C.DING_CUE` whether or not the number moved, and
prints only when it did. The message is sent once per ding, so a token scan that
happened to see them first must not swallow the cue — but it must not print the
line twice either.

`PLAYER_LEVEL_UP` is **not** in `SUSPEND_EXEMPT`, so a ding inside a dungeon goes
unannounced. That is deliberate and it costs nothing lasting: the level is
re-sampled the moment they are visible again, so the estimate self-heals; only
the notification is lost, which is what suspension means everywhere else.

Group splits are invisible to an addon, so the number is always labelled an
estimate. A linked tagger's reported XP is authoritative and should be preferred
wherever both exist.

**Rested is no longer invisible, because the tagger tells us.** `GetXPExhaustion`
is on their client, not ours, so it arrives as `REST:<pct>` and lands in
`state.taggerRested`; `RestedFactor()` turns that into the ×2 and it goes into
the estimate itself. The point is not decoration: a rested kill
used to print `2.00x`, and the multiplier exists to surface what the formula
*cannot* see. Anything we can see belongs in the estimate instead, or the one
number worth reading becomes noise.

- The percentage is **of that level's XP**, not the raw pool. The raw number is
  meaningless to the carry, who does not know how big the tagger's level is. It
  can exceed 100% — the pool caps at a level and a half.
- **All-or-nothing per kill**, deliberately. The pool can run dry mid-kill and
  pay somewhere between 1× and 2×; pricing that needs the pool size at the
  instant the mob died, which is on the other client and a message behind.
- `kill.rested` is **pinned at queue time**, like `need`, because the pool can
  empty between the kill and the report coming back.
- It is folded into the estimate itself rather than shown beside it, for the
  reason above: the multiplier is for what the formula cannot see.
- `RestedFactor` doubles if **any** tagger is rested. Damage pools against one
  threshold but XP does not, so with several taggers that is a guess — the same
  simplification `LowestTaggerLevel` already makes.
- The `(x2)` on the report line is **light blue**, and marks an expectation that
  has already had rested folded in. A ~1.00x beside it means the estimate was
  right, not that the bonus went missing.

`REST` is not sent per kill even though the pool drains on every one. It goes out
on the crossings — into rested, and out of it, which is the "they used it up"
report — and otherwise only after `C.REST_STEP` of drift. A full pool costs about
sixteen messages over the ~90 kills it takes to drain. The handshake and a ding
force one regardless: the carry may have just logged in with none of this, and a
ding changes the size of the level the percentage is measured against.

**There is no separate `MISSED` line any more.** The kill line carries the X icon
and *is* the miss notice — `LogMiss`, `kill.logged` and `MISS_LOG_DELAY` are all
gone with it. A missed mob still pays the tagger, since the tap decides that and
not the damage share, so a miss is a footnote on a line about XP rather than an
announcement of its own.

The consequence to know: **a miss says nothing in chat until the report that
prices it arrives**, and with nobody linked it says nothing at all. The sound
still fires the instant the mob dies — that one is the alert and has to be
immediate — and the float still draws the X with the share. Only the chat line
waits.

`db.announce` was the toggle on that old MISSED line, so it would have become a
switch that switched nothing. It gates `PrintKillLine` now, which is what the
per-kill chat announcement actually *is* today.

**One kill line, and BOTH ends print it.** `PrintKillLine` is shared: the carry
builds it from the tagger's `XP:<n>`, the tagger builds it from its own flush via
`ReportOwnKill`. Sharing the function is the whole point — two formatters for one
kill drift, and then the pair are looking at different sentences describing the
same mob.

```
Wallhackmage gained 860 of 1070 XP (x2), 37.2% damage = 80% XP [X icon]
```

- `nameTag` arrives **already coloured**, because it is the only part that
  differs between the two ends: the tagger's class colour on the carry, a green
  `You` on the tagger. Everything downstream of that is identical.
- Both XP figures are purple (`C.HEX_XP`), the share white (`C.HEX_SHARE`), the
  `(x2)` blue (`C.HEX_RESTED`).
- **The ratio's colour is the only judgement on the line.** Everything else is a
  fact, so nothing else changes colour. `RatioHex` runs red at or below
  `C.RATIO_FLOOR`, through yellow, to green at 100% — a ratio is the one number
  there you want to read the health of without reading.
- The miss mark is `C.X_ICON`, the **texture** rather than a letter: it is the
  same mark the float draws, so the two read as one thing seen twice. The `:0`
  in the escape sizes it to the line's font instead of to a guessed pixel height,
  which is what keeps it aligned if the chat font ever changes.
- It is gated on `db.announce` — see the note above on why the toggle moved here.

**`RestedFactor` reads `GetXPExhaustion` directly in tagger mode.** The pool is
our own there and needs no message to reach us. Without that branch the tagger
would price its own kills undoubled while the carry priced the same kills
doubled, and the two ends would disagree on every rested kill — exactly what
sharing the formatter is meant to prevent.

`C.SELF_KEY` is `"\1self"` because claims are keyed per tagger and this one is
us; a control character is a key no character name can ever normalize to.

**One float per kill, and it waits too.** `kill.floated` is checked by both the
`FLOAT_WAIT` timer and the arriving report, and whichever lands first draws. Drawing at the moment of
death meant the centre of the screen could only ever show our *estimate*, when a
linked tagger's real figure is a fraction of a second behind it — and the centre
of the screen is the one place worth spending that fraction on.

- `FloatKillSoon` defers only when `ReportComing()` — comms on **and** somebody
  who has actually talked to us. With nobody linked there is nothing to wait for,
  so it draws immediately with the estimate. `ReportComing` replaced a bare
  `next(linked)` on the old MISSED line too, which had been sitting on a timer
  waiting for a report that comms being off guaranteed would never come.
- **A linked KILL has no timeout at all.** Not "a timeout that draws the
  estimate" — none. There are exactly two things a timeout could put up and both
  are wrong: the estimate is the number the link exists to replace, and a
  checkmark with nothing on it is worse than no checkmark (it shipped that way
  briefly and read as a bug). So a kill does not appear until the report does,
  and if the report never comes it does not appear — the chat line still says
  what happened. **No float is a valid outcome; a blank one never is.**
- **A linked MISS keeps its timeout**, because it has something honest to draw
  without a report: the damage share, which is measured on our end, not theirs.
  Dropping it would silently lose the X on every miss the tagger never tapped —
  no report is ever coming for those, so "wait for it" would mean "never show
  it". `kill.awaited` marks that path so the estimate stays suppressed while the
  share still prints.
- `~545 XP` therefore only ever appears with nobody linked at all; `+1090 XP` is
  theirs, and the tilde is the whole distinction.
- The **share** is ours and always known, so a miss shows `(22%)` on its own when
  there is no XP to put beside it. It is parenthesised and **white**
  (`C.HEX_SHARE`) rather than taking the X's red: the X is the verdict, the share
  is the evidence behind it, and they read better as two things than one.
- **The decimal is conditional.** `(22%)` for a miss that was never close;
  `(37.6%)` only within a point of `kill.need`, where the gap between it and the
  threshold *is* the story. Precision nobody can act on is just noise at a
  glance, and the chat line keeps its full tenth regardless.
- **`(x2)` is the checkmark's alone.** It says the number in front of it already
  has rested folded in, which is worth knowing about XP you earned; on an X the
  number that matters is how close they came, and a second parenthetical only
  competes with it. `C.HEX_RESTED` is one constant shared with the chat line so
  the two cannot drift, and it shows on the `~estimate` too, which has rested
  folded in the same way.
- Greys never wait: nothing pays, and no report can ever arrive for one.
- `C.FLOAT_WAIT` is deliberately short. A chat line arriving late still reads as a
  log; a number that appears a beat after the mob dies reads as broken.

**The miss float carries the share, reversing an earlier call.** It was a bare X
on the reasoning that most misses are incidental — the tagger clipping something
you were killing anyway — so the share they happened to reach decided nothing.
That is still true of those misses. It is also true that the ones that were real
attempts are the ones worth reading, and the two are indistinguishable without
the number, which is the argument that won. The buzz is still the alert either
way, and the chat line is unchanged.

Missed kills are queued for pairing like tagged ones. Leaving them out was
mispairing: the report would arrive, find no entry of its own, and claim the next
tagged kill's. Greys stay unqueued, because they pay nothing and no report can
ever arrive to pair with, so the entry would sit waiting for a real report to
claim by mistake. Missed kills are also kept out of `matchedEst`/`matchedXP` —
their estimate assumes a full tag they never made.

**One report per mob, and `PLAYER_XP_UPDATE` cannot give you that.** The server
batches the player's xp field, so a tick that kills three mobs fires the event
**once**, carrying the sum of all three. Reporting that delta as one message made
the carry claim one pending kill and print a single mob paying 3.00x, while the
other two sat unclaimed until they expired. `CHAT_MSG_COMBAT_XP_GAIN` is not
batched — one line per mob — so the lines supply the split and `UnitXP` stays the
authority on the total, with each share scaled onto the real delta so the parts
still sum to it. All of it is read late, through one
`C_Timer.After(C.XP_FLUSH_DELAY)` flush, because the pieces of a single tick
arrive in an order that is not ours to choose — see the window note below.

**The flush window is 0.25 s, and evidence outlives an empty flush.** The events
that make up one tick — the per-mob chat lines, the experience field update, and
`QUEST_TURNED_IN` — do **not** reliably share a frame, and they can land in
*either order*. Both directions have now been fixed, and they needed different
fixes:

- **Evidence arriving late** is what `C.XP_FLUSH_DELAY` is for. A kill whose chat
  line landed after a one-frame flush got reported unlabelled.
- **Evidence arriving EARLY** is the subtler one, and it caused a hand-in to be
  reported as a kill — the carry printed `gained 9000 XP (actual)` for a quest.
  `QUEST_TURNED_IN` fired, the flush ran while the experience bar had **not yet
  moved**, and the old code cleared `batch`/`questXP` *before* testing `gained`.
  The evidence was gone by the time the xp it explained arrived a moment later.

  A flush that finds no gain therefore **keeps** what it holds, and clears only
  once there is a gain to spend it on. `C.XP_EVIDENCE_TTL` ages it out if the xp
  never comes at all — a turn-in at max level would otherwise sit there and claim
  the next kill.

Widening the window does nothing for the early case: the flush still fires before
the xp lands, it just fires later. That is why both exist.

`Noted()` — not `Schedule()` — is what every evidence recorder calls, because it
stamps `evidenceAt` as well as booking the flush. Adding a new evidence source
means calling `Noted`, or the TTL cannot see it.

**`db.xpDebug`, set on the tagger**, prints each scrap as it lands and every
flush with what it had in hand. The ordering is not inferable after the fact, and
guessing at it cost two wrong fixes; use this before theorising about a third.

Being generous with the window costs nothing: merging two adjacent server ticks
into one flush is **harmless**, because the split is proportional to the per-mob
amounts and the field update covers every one of them, so the arithmetic holds
either way. It is short enough that a report still feels attached to the kill
that caused it.

**`questXP` is tested for nil, never for a positive amount.** It becomes a number
the instant a turn-in is noted, so nil-vs-number is what records "a turn-in
happened in this tick". The *evidence* is `QUEST_TURNED_IN` firing — not the size
of the reward it carried. A client that reports no reward, or a zero one, must
not silently demote the quest back to a kill, so when the reward is unknown and
nothing died, the whole gain is the quest's.

The one case that still cannot be split is an unknown reward arriving in the same
tick as a kill: with no amount to take off the top, it falls through to a plain
kill report. That is the old behaviour, and the safe direction to be wrong in.

The pattern is built from `COMBATLOG_XPGAIN_FIRSTPERSON` the way `OwnerPatterns`
builds its own, and is deliberately **not** anchored at the end — the group, raid
and rested variants extend that sentence rather than rewriting it. A locale that
orders the name and the number the other way round, or uses positional
specifiers, converts to nothing and falls back to the single lump sum. Quest xp
has no mob in its line, so it never matches and never enters a split.

**Labelling where the xp came from.** This expansion pays xp three ways — kills,
quest turn-ins and zone discoveries — and only the first has anything to do with
tagging. Before, all three were relayed as `XP:<n>`, so a turn-in on the way to
the pull claimed a pending kill and printed a wild multiplier against it. The
flush now classifies the whole tick before it sends anything:

- Any kill lines → kills, split as above, `XP:<n>` each.
- A `QUEST_TURNED_IN` this frame → `XPQ:<n>:<title>`, taken **off the top** of
  the delta so a turn-in landing in the same tick as a kill does not inflate the
  mob's report. Args are `(questID, xpReward, moneyReward)`.
- An `ERR_ZONE_EXPLORED*` info message this frame → `XPD:<n>`. Positive evidence
  only; see the elimination rule below.
- **None of the above → `XP:<n>`, unlabelled.** The safe default, and the one
  this had before any labelling existed.

**Quest titles, and the two events' different argument orders.** The ids arrive
in *different positions* in the two events on this client, which is the kind of
thing that silently reports the wrong quest forever:

| Event | Signature |
|---|---|
| `QUEST_TURNED_IN` | `(questID, xpReward, moneyReward)` — id **first** |
| `QUEST_ACCEPTED` | `(questLogIndex, questID)` — id **second** |

Both were read off `Questie`, which runs on this client, rather than from retail
docs where `QUEST_ACCEPTED` carries only the id.

`QuestTitle` resolves a name through `C_QuestLog.GetTitleForQuestID` and then
`GetQuestLogTitle`, each guarded on its own. **`GetTitleText` is deliberately not
in it**: it reads whatever frame is open, which is honest at a turn-in — the
quest frame is still up — and a stale lie for a quest accepted any other way, so
it stays inline at the turn-in call site. A turn-in with no name still sends, and
says "by completing a quest"; the reward is the point and it has already been
counted. A `QACC` with no name is **not** sent at all — the name is the entire
message, and a wrong one is worse than silence.

**Never label XP by elimination. Every label needs positive evidence.** This is
the most important rule in the section, and it is here because breaking it
shipped a bug: discovery was once inferred from "no kill line this tick", which
misreported real kills as discoveries at random. Two independent things empty the
batch on a genuine kill, and neither is rare:

- **A kill's own XP line can arrive with no mob name in it.**
  `COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED` — `"You gain %d experience."` — is a
  *mob-death* string on this client, not just a quest one.
  `NovaInstanceTracker` lists it among its "only strings that are mob died
  related, no quest xp" set. It cannot match a pattern that requires a name, so
  the batch stays empty and the kill looked like a discovery.
- **The chat line and the field update need not share a frame.** They are
  separate packets. The one-frame `C_Timer.After(0)` flush catches them together
  almost always — but "almost" was doing load-bearing work in a branch that
  treated silence as proof.

Both fail *randomly* from the outside, which is exactly how it was reported.

So the rule now: a kill is identified by its line, a turn-in by
`QUEST_TURNED_IN`, a discovery by the `ERR_ZONE_EXPLORED*` info message it
announces itself with (`C.DISCOVERY_INFO`), and **anything that does not identify
itself gets no label at all** — it falls through to a plain `XP:<n>`, which is
what this did before any labelling existed. Every way of being wrong now lands on
the old, safe behaviour instead of on a confident lie.

Note what was *not* reverted. The per-mob split is positive evidence — kill lines
are present and counted — so it stayed. Only the inference went.

`XPQ` and `XPD` are their own commands rather than a suffix on `XP` so the wire
stays backward compatible in both directions: a partner on an older build drops
an unknown command silently, where `XP:250:Some Quest` would have failed
`tonumber` and been dropped anyway — or worse, paired. Neither touches
`reportedKills`, `reportedXP` or `matchedEst`/`matchedXP`; they land in
`state.offTagXP`, which `/tag stats` prints on its own line.

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
