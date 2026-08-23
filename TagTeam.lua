-- TagTeam
--
-- Two roles throughout:
--   carry  - you, the high-level character doing the killing
--   tagger - a low-level character being levelled, who must deal db.threshold
--            percent of a mob's max health to earn credit for the kill
--
-- There can be several taggers, and their damage is POOLED against the threshold
-- rather than measured per head. That's correct when the taggers are grouped with
-- each other, since the group shares one tag.
--
-- Tracks how much of an enemy's max health the named players have damaged,
-- using COMBAT_LOG_EVENT_UNFILTERED. The combat log is NOT filtered by group
-- membership, so this works on players who aren't in your party or raid - the
-- only real limit is combat log range (~50yd, wider than nameplate range).
--
-- Once the tagger crosses the threshold on a mob, that mob's nameplate
-- gets a checkmark. Below the threshold it shows a running percentage, so you
-- can see a mob sitting at 20% and hold off instead of guessing.
--
-- If a mob the tagger was working on dies before it hits the threshold,
-- a burst of red Xs fades out where the checkmark should have been, with its own
-- sound and a chat line.

local ADDON_NAME, ns = ...

-- Constants and tunables, and runtime state, each behind one name.
--
-- Not a style preference: the main chunk of a Lua file IS a function, so every
-- file-level `local` spends one of the 200 register slots Lua 5.1 allows per
-- function. This file had 199 of them and would not compile if it grew. Table
-- fields cost nothing against that ceiling, and folding these two groups gave
-- back ~60 slots. The convention the file already used is kept: UPPER_CASE for
-- things fixed at load, lowercase for things that change.
--
-- They stay declared where their explanations are rather than being hauled up
-- into one block - the comment above a constant is usually why it has the value
-- it has, and that is worth more than seeing them all in one place.
local C = {}       -- constants and tunables, set once at load
local state = {}   -- per-pull scratch, all cleared by Forget/ResetAll

C.THRESHOLD_DEFAULT = 38   -- damage share needed to tag a mob
-- Anyone whose saved threshold is still an old default gets moved to the current
-- one at load. A saved 36 can't be told apart from a deliberate 36, so the cost
-- of being wrong is one `/tag threshold 36` for whoever meant it. Every
-- superseded default stays listed rather than only the most recent: someone who
-- skipped a release is still sitting on the one before it.
C.LEGACY_THRESHOLDS = { [31] = true, [36] = true }

-- WeakAuras' bundled "Brass" sound. Referenced where it sits rather than copied
-- in: it's WA's asset, not Blizzard's, so it isn't in SOUNDKIT and can't be
-- played by id. PlaySoundFile reports whether it actually played, so if WA is
-- ever uninstalled we fall back to a built-in instead of going silent.
C.DEFAULT_SOUND_FILE = [[Interface\AddOns\WeakAuras\Media\Sounds\Brass.mp3]]
-- A tone rather than a voice clip: voice clips grate fast when you hear them
-- dozens of times a session, which is exactly what a miss cue does.
C.DEFAULT_MISS_FILE  = [[Interface\AddOns\WeakAuras\Media\Sounds\ErrorBeep.ogg]]
C.LEGACY_MISS_FILE   = [[Interface\AddOns\WeakAuras\Media\Sounds\OhNo.ogg]]

-- "SFX" rather than "Master": Master ignores your sound sliders entirely and
-- plays at full volume, which is why these were blasting. SFX rides the Sound
-- Effects slider like the rest of the game.
C.SOUND_CHANNEL = "SFX"

C.STALE_SECONDS     = 60    -- forget mobs we haven't seen damaged in this long
C.SWEEP_INTERVAL    = 5
C.REFRESH_INTERVAL  = 0.25  -- catches max-health changes; CLEU drives instant updates

C.X_TEXTURE     = "Interface\\RaidFrame\\ReadyCheck-NotReady"
C.CHECK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- The XP colour inside a quest float. A FontString honours |cAARRGGBB runs
-- regardless of what SetTextColor set, which is the only way to get three colours
-- into one float: the label is a single FontString, and |r reverts to the base
-- yellow rather than to white, so only the runs that differ need escaping.
--
-- A brightened epic purple. The XP bar's own (0.58, 0, 0.55) is dark enough to
-- vanish against a night sky, and plain epic (a335ee) still sits heavy against a
-- dark chat frame. One constant, so it is one line to move again.
C.HEX_XP = "ffbf5fff"

-- The rested flair, on the chat line and the float alike. One constant because
-- they mean the same thing in both places: the number in front of it already has
-- the doubling folded in, so a 1.00x beside it is the estimate being right.
C.HEX_RESTED = "ff66ccff"

-- The damage share on a miss. White so it reads as its own fact rather than as
-- part of the red X's alarm - the X is the verdict, the share is the evidence.
C.HEX_SHARE = "ffffffff"

-- The kill line's "N% xp" runs red below RATIO_FLOOR and climbs through yellow to
-- green at 100%. A ratio is the one number on that line you want to judge without
-- reading, so it gets a gradient rather than a fixed colour.
--
-- The floor is where "this is fine" stops. Below it everything is equally red -
-- once a kill has paid half what it should, how far below does not change what
-- you do about it.
C.RATIO_FLOOR = 0.70
-- The miss mark on the kill line is the X TEXTURE, not a letter: it is the same
-- mark the float draws, so the two read as one thing seen twice. ":0" sizes the
-- icon to the line's font rather than to a guessed pixel height.
C.X_ICON = "|T" .. C.X_TEXTURE .. ":0|t"

-- The tagger claims its OWN kills to print the same line the carry does. Claims
-- are keyed per tagger, so this needs a key no character can normalize to - and a
-- name cannot contain a control character.
C.SELF_KEY = "\1self"

-- Skull, cross, square. Deliberately only three: more markers than you can hold
-- in your head at a glance is just clutter. The rotation resets out of combat.
C.TAG_MARKERS = { 8, 7, 6 }

-- Only warn about stealing a tag if the tagger has actually been doing something
-- recently - otherwise every mob you kill while questing alone would scold you.
C.NEAR_SECONDS = 60

-- Mobs this far below the lowest tagger get no cues at all. Grey already covers
-- "pays nothing"; this covers "pays something, but nobody is here for it" - the
-- level 1 critters that share a zone with the mobs you are actually grinding.
C.IGNORE_LEVEL_GAP = 10

-- Feature-detected rather than assumed: if this client exposes a localized name
-- for the critter creature type, use it; otherwise the English word, which is
-- what the comparison used before and works on an English client.
C.CRITTER = _G.CREATURE_TYPE_CRITTER or "Critter"

-- A tagged kill and the tagger's XP report are two separate events on two
-- separate clients: we see the death, their client reads the real gain off UnitXP
-- and whispers it over a moment later. Kills wait in a queue to be paired with
-- their report, which is what lets the carry print expected against actual.
C.XP_MATCH_WINDOW = 20  -- seconds a kill waits before it's written off
C.XP_MATCH_MAX    = 12  -- queue cap, so unreported kills can't grow it forever

-- One tick's xp arrives as SEVERAL separate events - the per-mob chat lines, the
-- experience field update, and QUEST_TURNED_IN - and they do not reliably share a
-- frame. A one-frame window was too tight twice over: a kill whose line landed
-- late got reported unlabelled, and a turn-in that landed late got reported as a
-- kill. This is how long the flush waits for the whole tick to arrive.
--
-- Merging two adjacent server ticks into one flush is harmless, which is what
-- lets this be generous: the split is proportional to the per-mob amounts, and
-- the field update covers every one of them, so the arithmetic holds either way.
-- Short enough that the report still feels attached to the kill that caused it.
C.XP_FLUSH_DELAY = 0.25

-- Evidence can also arrive well AHEAD of the xp it explains - QUEST_TURNED_IN
-- routinely beats the experience field by more than a flush window - so a flush
-- that finds no gain keeps what it has rather than discarding it. This is how
-- long it keeps it. It only matters when the xp never arrives at all: a turn-in
-- at max level, say, which would otherwise sit there and claim the next kill.
C.XP_EVIDENCE_TTL = 3

-- The rested pool drains on every kill, so REST is not sent on every kill. It
-- goes out when the pool crosses into or out of existence - which is what the
-- estimate turns on, and what "they used it up" means - or when it has moved this
-- many percentage points of a level since the last one was sent.
C.REST_STEP = 10

-- QUEST_REMOVED fires for a hand-in and an abandon alike, and can beat the
-- QUEST_TURNED_IN that would have told them apart. This is how long a removal
-- waits for a turn-in to claim it before it counts as abandoned. Questie, on this
-- same client, waits one second for the same reason.
C.ABANDON_GRACE = 1

-- Client differences in one place, the way WhoDoesWhat's ClientFeatures does it,
-- so version checks don't get scattered through the logic. Focus arrived in TBC;
-- the 1.x client has no focus unit at all, so everything built on it is skipped
-- there and the timer fallback carries the load instead.
local isClassicEra = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
C.HAS_FOCUS    = not isClassicEra

-- Triangle, diamond, orange circle, in that order. Three slots, so a fourth
-- tagger has nowhere to go - adding one prompts you to drop an old one. Mob tags
-- use 8/7/6, so the two sets can never collide.
C.TAGGER_MARKERS = { 4, 3, 2 }
C.MARKER_NAMES   = { [4] = "triangle", [3] = "diamond", [2] = "orange" }

C.INVITE_MESSAGE     = "inv"
C.OUT_OF_RANGE_AFTER = 30   -- fallback only, where focus isn't available
C.WHISPER_COOLDOWN   = 60   -- floor between whispers, whatever else happens
C.INVITE_FALLBACK    = 8    -- wait for a direct invite before whispering
C.FOCUS_NAG_INTERVAL = 60   -- between "you have no focus set" reminders
C.GROUPED_WARN_INTERVAL = 15 -- between grouped-in-combat warnings
C.LEAVE_GRACE = 3           -- settle time after joining before auto-leaving
-- UnitHealth can still report the pre-hit value on the frame the combat log
-- delivers a hit, so a mob would look "full" the instant we damaged it. Requiring
-- a quiet gap first means only a real evade-reset clears the grouped mark.
C.RESET_GRACE = 2           -- quiet seconds before full health reads as a reset

-- The burst is drawn at a fixed spot on screen rather than over the mob. It has
-- to be: nameplate frames and everything parented to them are restricted regions
-- that cannot be measured while you are in combat, so their screen position is
-- simply not knowable at the moment a mob dies. Centre screen, raised clear of
-- the character, sized to be read at a glance instead of squinted at.
C.MARK_SIZE = 44
C.MARK_RISE = 180

-- Threshold stamp: a hard collapse from oversized that punches past true size,
-- then springs back out to it. About a fifth of a second end to end - the
-- undershoot and the snap back are what give it the impact.
C.STAMP_IN_DURATION   = 0.12
C.STAMP_BACK_DURATION = 0.09
C.STAMP_FROM          = 3.0
C.STAMP_UNDERSHOOT    = 0.78

-- Death float: one mark that rises and fades on the cadence of the Classic XP
-- gain text. Hits and misses share it, differing only in texture and label.
--
-- The three are read together, so change them together. FADE_DELAY is the OPAQUE
-- hold; the fade itself runs for DURATION - FADE_DELAY, which is what actually
-- decides whether a float reads as lingering or as washed out. Lengthening the
-- life means lengthening the hold and leaving the fade alone - stretching the
-- fade instead just leaves the text half-there for longer.
--
-- RISE over DURATION is the drift speed, so raising DURATION on its own slows
-- everything down whether you meant to or not. RISE is nudged up alongside it to
-- keep that deliberate: 85/2.6 is about 33 px/s against the 39 px/s it was.
C.FLOAT_RISE       = 85
C.FLOAT_DURATION   = 2.6   -- 1.5s held, then 1.1s fading
C.FLOAT_FADE_DELAY = 1.5

-- Quest progress relayed by the tagger rides the same flight, starting clear of
-- the burst rather than through it: the burst's icon is centred at MARK_RISE and
-- its label hangs below that, so this begins a mark-height above the icon.
C.QUEST_FLOAT_RISE = C.MARK_RISE + C.MARK_SIZE + 24
-- Two objectives can tick in the same instant. Staggering by about a line height
-- is what keeps them two readable notices instead of one smeared one.
C.QUEST_FLOAT_STEP = 26
C.QUEST_FLOAT_ROWS = 3

-- How long a MISS float waits for the tagger's real number before it gives up and
-- shows just the damage share. Only misses use this: a linked kill has no timeout
-- at all, because there is nothing honest for one to draw. See FloatKillSoon.
--
-- Kept short because a number that appears a beat after the mob dies reads as
-- broken, where a chat line arriving late just reads as a log. The report itself
-- needs XP_FLUSH_DELAY plus one whisper.
C.FLOAT_WAIT = 1.0

-- Reactive damage: it fires because the mob attacked us, not because we chose to
-- engage it. Thorns, Retribution Aura, Lightning Shield, the Imp's Fire Shield
-- and shield spikes all arrive as DAMAGE_SHIELD; DAMAGE_SPLIT is damage
-- redirected onto us. Neither is a deliberate tag, so neither is allowed to claim
-- one - though the damage itself still counts toward the tagger's threshold,
-- which matters for an enhancement shaman running Lightning Shield.
C.REACTIVE_EVENTS = {
    DAMAGE_SHIELD = true,
    DAMAGE_SPLIT  = true,
}

-- Damage subevents carrying a SPELL-style prefix (spellId, spellName, spellSchool
-- occupy args 12-14, so amount/overkill land at 15/16).
C.SPELL_DAMAGE_EVENTS = {
    SPELL_DAMAGE          = true,
    SPELL_PERIODIC_DAMAGE = true,
    SPELL_BUILDING_DAMAGE = true,
    RANGE_DAMAGE          = true,
    DAMAGE_SHIELD         = true,
    DAMAGE_SPLIT          = true,
}

-- Runtime state (never saved; all of it is per-pull scratch)
state.damage      = {}  -- [destGUID]  = accumulated damage from the tagger
state.alerted     = {}  -- [destGUID]  = true once we've played the threshold sound
state.lastSeen    = {}  -- [destGUID]  = GetTime() of last accumulation
state.maxHealth   = {}  -- [destGUID]  = cached UnitHealthMax, to score off-screen mobs
state.tapOwner    = {}  -- [destGUID]  = "carry" | "tagger" | "other", by first damage
state.marked      = {}  -- [destGUID]  = true once we've put a raid marker on it
state.groupTagged = {}  -- [destGUID]  = true once tagger damage landed while grouped
state.mobLevel    = {}  -- [destGUID]  = cached UnitLevel, for the XP estimate
state.mobElite    = {}  -- [destGUID]  = true if elite/rare-elite/boss (double XP)
state.mobTrivial  = {}  -- [destGUID]  = true for critters and "minus" minions
state.mobName     = {}  -- [destGUID]  = name, for the banlist
state.petOwner    = {}  -- [petGUID]   = ownerGUID, learned from SPELL_SUMMON
state.isTracked   = {}  -- [guid]      = tagger key once a GUID is confirmed as one
state.isCarryGuid = {}  -- [guid]      = true once a GUID is confirmed as the carry
state.plates      = {}  -- [unitToken] = { guid = , badge = }
state.guidToUnit  = {}  -- [guid]      = unitToken, for instant nameplate updates

-- db.taggers = { [normalisedName] = { name = "Display", level = n, pet = "Name" } }
-- Their damage is pooled: the threshold is measured against the sum, which is
-- correct when the taggers are grouped with each other and sharing a tag.
local db                    -- TagTeamDB
state.inOutland = false     -- recomputed on zone change; picks the XP base constant
state.sessionXP, state.sessionTags = 0, 0
local playerGUID            -- our own GUID, for spotting mobs we tapped ourselves
local trackedActiveAt = 0   -- last time we saw the tagger do anything
local markerSlot = 1        -- rotates through TAG_MARKERS, resets out of combat
state.lastRawXP, state.lastXPInfo = nil, nil -- last unscaled estimate, for /tag calibrate
local pendingKills = {}     -- tagged kills awaiting an XP report, oldest first
state.matchedEst, state.matchedXP = 0, 0  -- paired totals, for the session multiplier
local askedForInvite = false
local lastWhisperAt = 0
local lastFocusNagAt = 0
local lastGroupWarnAt = 0
local groupedAt = 0         -- when we last joined a group, for the leave grace
local wasGrouped = false
state.focusEverSet = false  -- only then does losing focus mean anything
state.focusTaggerName = nil     -- the one player we'll ask for an invite
local ReportTaggedKill      -- assigned in the comms section, called from HandleDeath
local SendAddon             -- ditto; the contact checker needs it before it's defined
local ReportRested          -- ditto; the flush and the handshake both push it
local linked = {}           -- [key] = true; rebound to db.linked so it survives /reload

-- Labels for the Key Bindings panel. Bindings.xml declares the binding itself.
BINDING_HEADER_TAGTEAM = "TagTeam"
_G["BINDING_NAME_CLICK TagTeamFollowButton:LeftButton"] = "Target / follow / focus tagger"

local frame = CreateFrame("Frame", "TagTeamFrame")

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TagTeam|r: " .. msg)
end

-- Dungeons and raids are not what this addon is for: the carry and the tagger
-- are necessarily grouped, so a tag earns almost nothing, and every cue fires
-- into a run where none of it can be acted on. Worse, the carry-side logistics
-- would actively misbehave - the auto-leave check would try to drop the party
-- mid-dungeon and the auto-invite check would whisper for one.
--
-- Read live rather than cached on a zone event. IsInInstance is a cheap client-
-- state lookup, and asking each time means /tag instance takes effect the moment
-- it's typed, with nothing to invalidate. It's also a global, which costs no
-- upvalue in its callers, which mattered when this file was one 200-local chunk.
local function Suspended()
    if not db or db.instanceOff == false then return false end
    local inside, kind = IsInInstance()
    return (inside and (kind == "party" or kind == "raid")) and true or false
end

state.lastCosmeticError = nil -- surfaced by /tag diag

-- Cosmetics run behind this. Twice now a fault in the death animation has taken
-- the badge or the threshold ding down with it, because a Lua error unwinds the
-- whole event handler. Nothing decorative is allowed to do that again. The error
-- is kept rather than discarded so a silent failure is still diagnosable.
local function SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then state.lastCosmeticError = err end
    return ok
end

-- "Thrall-Whitemane" and "Thrall" both normalize to "thrall".
local function NormalizeName(name)
    if not name then return nil end
    local base = strsplit("-", name)
    return strlower(base)
end

--------------------------------------------------------------------------------
-- Who is who
--
-- Two modes, and the whole addon reads its identities through here:
--
--   carry mode (default)  db.taggers lists who we're boosting. We are the carry.
--   tagger mode           db.carry names who is boosting US. We are a tagger, and
--                         so is everyone in our party - their damage pools with
--                         ours against the threshold.
--
-- Tagger mode is tracking only. The party automation (invites, auto-leave, the
-- grouped-in-combat warning, markers, focus) is all carry-side and stays off,
-- because in tagger mode being grouped with other taggers is the correct state,
-- not a mistake to warn about.
--------------------------------------------------------------------------------

local dynamicTaggers = {}   -- tagger mode: [key] = { name, level }, self + party

local function InTaggerMode()
    return db and db.carryKey ~= nil
end

-- Rebuilt on roster changes rather than scanned per damage event: this is read
-- from the combat log, which fires constantly during AoE.
local function RebuildDynamicTaggers()
    wipe(dynamicTaggers)
    if not InTaggerMode() then return end

    -- Pets ride on their owner's entry rather than getting one of their own: a
    -- pet is not a head the XP formula knows about, and letting one into the
    -- table would put its level into LowestTaggerLevel and quietly bias every
    -- estimate. Read off the unit token, which is always current for anyone
    -- whose damage we pool here - ourselves and our party.
    local function add(unit, petUnit)
        local name = UnitName(unit)
        local key = NormalizeName(name)
        if not key or key == db.carryKey then return end
        local pet = petUnit and UnitExists(petUnit) and UnitName(petUnit) or nil
        dynamicTaggers[key] = {
            name = name, level = UnitLevel(unit),
            pet = pet, petKey = NormalizeName(pet),
        }
    end

    add("player", "pet")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do add("raid" .. i, "raid" .. i .. "pet") end
    elseif IsInGroup() then
        for i = 1, 4 do
            if UnitExists("party" .. i) then add("party" .. i, "party" .. i .. "pet") end
        end
    end
end

local function HasTaggers()
    if db and db.taggers and next(db.taggers) ~= nil then return true end
    return next(dynamicTaggers) ~= nil
end

local function TaggerKeyOf(name)
    local key = NormalizeName(name)
    if not key then return nil end
    if db and db.taggers and db.taggers[key] then return key end
    if dynamicTaggers[key] then return key end
    return nil
end

--------------------------------------------------------------------------------
-- Pets
--
-- A hunter's or warlock's pet does a large share of a tagger's damage, so a pet
-- that isn't counted reads as a tagger who can't reach the threshold.
--
-- Ownership arrives three ways, and all three are needed to cover the cases:
--
--   by GUID     petOwner, from SPELL_SUMMON. Exact, but only if we were standing
--               there for the summon, and pet GUIDs die with every loading
--               screen. A hunter who summons once and plays all evening is
--               invisible to it - which is the normal case, not the edge one.
--   by message  the owner's own client says so over the addon channel. The most
--               reliable, and the only one that needs nothing to have been
--               witnessed - but it needs them running TagTeam.
--   by tooltip  the game names a pet's owner in the pet's tooltip, so any pet we
--               get a unit token for can be placed on the spot. This is what
--               covers a tagger who is NOT running the addon, with no summon.
--
-- The last two both land as a NAME on the owner's saved record, which is what
-- survives the loading screen that kills the GUID.
--
-- The name route is deliberately restricted to "Pet-" GUIDs. That prefix is
-- exactly the hunter and warlock pets this is for, and it keeps a wild mob that
-- happens to share the name out of the tagger's damage. It does not distinguish
-- a stranger's identically named pet, which is the one hole left; the cost is a
-- few points of inflated share on a mob someone else is also hitting.
-- Guardians and totems arrive as ordinary Creature- GUIDs and stay resolvable
-- only through their summon.
--
-- The whole subsystem hangs off ONE main-chunk local, which is not a style
-- choice: this file compiles against two of Lua 5.1's hard ceilings at once - 200
-- locals in the main chunk and 60 upvalues per function - and had a single-digit
-- number of local slots left. A table costs one slot, and one upvalue in each
-- function that reaches for it rather than one per entry point.
--------------------------------------------------------------------------------

local Pets = { myGUID = nil }   -- myGUID: our own pet, cached off UNIT_PET

function Pets.IsPetGuid(guid)
    return (guid and strsub(guid, 1, 4) == "Pet-") or false
end

-- The tagger whose pet this is, or nil. Compared against a pre-normalised key
-- because this runs per damage event from every pet in range, strangers included.
function Pets.TaggerKey(guid, name)
    if not Pets.IsPetGuid(guid) then return nil end
    local petKey = NormalizeName(name)
    if not petKey then return nil end

    if db and db.taggers then
        for key, info in pairs(db.taggers) do
            if info.petKey == petKey then return key end
        end
    end
    for key, info in pairs(dynamicTaggers) do
        if info.petKey == petKey then return key end
    end
    return nil
end

-- One landing spot for a pet name, whichever way it arrived. Both halves of the
-- pair: a carry's pet taps mobs and steals tags exactly as the carry does, so a
-- tagger's client needs the answer in that direction too.
--
-- Only ever writes to the saved records. dynamicTaggers is derived from unit
-- tokens on every roster change and would throw this away.
function Pets.Learn(ownerName, petName)
    local key = NormalizeName(ownerName)
    if not key or not db then return end
    if petName == "" then petName = nil end
    local petKey = NormalizeName(petName)

    local who
    if key == db.carryKey then
        if petKey == db.carryPetKey then return end
        db.carryPet, db.carryPetKey, who = petName, petKey, db.carry
    else
        local info = db.taggers and db.taggers[key]
        if not info or petKey == info.petKey then return end
        info.pet, info.petKey, who = petName, petKey, info.name
    end

    -- Silent when a pet goes away: a dismissed pet deals no damage, so there is
    -- nothing to tell anyone. Learning one changes what counts, so that is said.
    if petName then
        Print(format("|cff00ff00%s|r's pet |cff00ff00%s|r counts as their damage.",
            who, petName))
    end
end

-- The third route in, and the only one that needs neither a summon nor the other
-- client: the game itself names a pet's owner, in the pet's tooltip. Built from
-- UNITNAME_TITLE_PET and friends rather than a hardcoded "'s Pet", so it holds in
-- every locale - and if this client turns out not to carry those strings, the
-- list comes back empty and the whole route quietly does not exist.
--
-- Wrapped in a do block, and not for tidiness: locals declared inside a block
-- release their slots at the end of it, so the three helpers here cost the main
-- chunk nothing. See the ceilings note at the top of this section.
do

local ownerPatterns
local scanTip

local function OwnerPatterns()
    if ownerPatterns then return ownerPatterns end
    ownerPatterns = {}
    local titles = { UNITNAME_TITLE_PET, UNITNAME_TITLE_MINION,
                     UNITNAME_TITLE_GUARDIAN, UNITNAME_TITLE_CREATION }
    for i = 1, #titles do
        local s = titles[i]
        if type(s) == "string" and s ~= "" then
            -- "%s's Pet" becomes "^(.+)'s Pet$": escape every magic character in
            -- the literal half first, then open the one substitution back up.
            s = gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
            s = gsub(s, "%%%%s", "(.+)")
            ownerPatterns[#ownerPatterns + 1] = "^" .. s .. "$"
        end
    end
    return ownerPatterns
end

local function OwnerFromTooltip(unit)
    local patterns = OwnerPatterns()
    if #patterns == 0 then return nil end

    if not scanTip then
        if not CreateFrame then return nil end
        scanTip = CreateFrame("GameTooltip", "TagTeamScanTooltip", nil, "GameTooltipTemplate")
    end

    -- Re-owned every call: a tooltip that has lost its owner populates nothing,
    -- and ANCHOR_NONE on UIParent is what keeps it off the screen.
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetUnit(unit)
    -- Line 1 is the pet's own name; the owner is on one of the lines under it.
    for i = 2, scanTip:NumLines() do
        local line = _G["TagTeamScanTooltipTextLeft" .. i]
        local text = line and line:GetText()
        if text then
            for j = 1, #patterns do
                local owner = strmatch(text, patterns[j])
                if owner then return owner end
            end
        end
    end
    return nil
end

-- A pet on a unit token we can inspect. Cheap enough for the 2s scan: it only
-- reaches the tooltip for a pet we have not already placed, and during a boost
-- the tagger's pet is usually holding the mob, which puts it in targettarget.
function Pets.Notice(unit)
    local guid = UnitGUID(unit)
    if not Pets.IsPetGuid(guid) then return end
    if Pets.TaggerKey(guid, UnitName(unit)) then return end  -- already placed

    local owner = OwnerFromTooltip(unit)
    if owner then Pets.Learn(owner, UnitName(unit)) end      -- no-op unless ours
end

end

-- The other half of an established pair, in EITHER direction: our carry, or one
-- of our taggers. Distinct from TaggerKeyOf, which answers a different question -
-- tagger mode deliberately keeps the carry out of dynamicTaggers (it is not
-- someone whose damage we pool), so asking TaggerKeyOf about our own carry
-- correctly says no. That is right for damage accounting and wrong for trust.
local function IsPartner(name)
    if not db then return false end
    local key = NormalizeName(name)
    if not key then return false end
    if db.carryKey == key then return true end
    return (db.taggers and db.taggers[key] ~= nil) or false
end

local function TaggerInfo(key)
    if db and db.taggers and db.taggers[key] then return db.taggers[key] end
    return dynamicTaggers[key]
end

-- Sorted display names, so listings don't shuffle between calls.
local function TaggerNames()
    local names, seen = {}, {}
    if db and db.taggers then
        for key, info in pairs(db.taggers) do
            names[#names + 1] = info.name
            seen[key] = true
        end
    end
    for key, info in pairs(dynamicTaggers) do
        if not seen[key] then names[#names + 1] = info.name end
    end
    sort(names)
    return names
end

-- Markers are derived, never handed out ad hoc. Confirmed means their addon has
-- actually talked to ours, or we've laid eyes on them - anyone can be added, but
-- a name that's never answered can't hold the triangle. Confirmed players sort
-- by WHO ANSWERED FIRST; the rest fall in behind by when they were added.
local function ReassignMarkers()
    if not db or not db.taggers then return end

    local list = {}
    for _, info in pairs(db.taggers) do list[#list + 1] = info end

    sort(list, function(a, b)
        local ac, bc = a.confirmed and 1 or 0, b.confirmed and 1 or 0
        if ac ~= bc then return ac > bc end
        if ac == 1 then return (a.confirmedOrder or 0) < (b.confirmedOrder or 0) end
        return (a.order or 0) < (b.order or 0)
    end)

    for i = 1, #list do
        list[i].marker = C.TAGGER_MARKERS[i]   -- nil past the third: no slot left
    end
end

-- The tagger holding the first slot. Focus follows the triangle.
local function PrimaryTaggerKey()
    if not db or not db.taggers then return nil end
    for key, info in pairs(db.taggers) do
        if info.marker == C.TAGGER_MARKERS[1] then return key end
    end
    return nil
end

-- Marker order, not alphabetical: triangle, diamond, orange, then anyone unmarked.
local function TaggersByPriority()
    local list = {}
    if not db or not db.taggers then return list end
    for i = 1, #C.TAGGER_MARKERS do
        for _, info in pairs(db.taggers) do
            if info.marker == C.TAGGER_MARKERS[i] then list[#list + 1] = info end
        end
    end
    for _, info in pairs(db.taggers) do
        if not info.marker then list[#list + 1] = info end
    end
    return list
end

-- Built in reverse priority so the primary tagger is targeted last. A failed
-- /targetexact leaves the previous target intact, so the final /focus and /follow
-- land on the highest-priority tagger who's actually nearby - the sequence
-- degrades on its own instead of needing conditionals macros can't express.
local function BuildFollowMacro()
    local targets = {}

    if InTaggerMode() and db.carry then
        -- On a tagger's client the carry is the only name worth following, ahead
        -- of any tagger entries left over from using this character as a carry.
        targets[1] = db.carry
    else
        -- Never try to follow ourselves. In tagger mode the party set includes
        -- us, and someone can always /tag add their own name by accident.
        local list = TaggersByPriority()
        local me = NormalizeName(UnitName("player"))
        for i = 1, #list do
            if NormalizeName(list[i].name) ~= me then
                targets[#targets + 1] = list[i].name
            end
        end

        -- No taggers to chase? Follow the carry - the other half of the pair.
        if #targets == 0 and db and db.carry then targets[1] = db.carry end
    end

    -- Nothing configured either way: follow whoever is targeted.
    if #targets == 0 then return "/follow" end

    local lines = {}
    for i = #targets, 1, -1 do
        lines[#lines + 1] = "/targetexact " .. targets[i]
        -- [help] so a failed targetexact can't leave us focusing a mob: the
        -- command simply doesn't run when the current target is hostile.
        lines[#lines + 1] = "/focus [help]"
        lines[#lines + 1] = "/follow"
    end
    return table.concat(lines, "\n")
end

-- A secure button carrying that macro. Clicking it counts as a hardware event, so
-- /focus works from here where no API call ever will. Bind a key to it in the
-- Key Bindings panel under "TagTeam"; Bindings.xml declares it.
state.followButton = nil

local function UpdateMacroButton()
    -- Secure attributes are locked during combat; PLAYER_REGEN_ENABLED retries.
    if InCombatLockdown() then return end

    if not state.followButton then
        state.followButton = CreateFrame("Button", "TagTeamFollowButton", UIParent,
            "SecureActionButtonTemplate")

        -- Real size, real anchor, shown. A CLICK binding dispatches to a live
        -- frame; a zero-size unanchored one can be skipped silently.
        state.followButton:SetSize(1, 1)
        state.followButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, 200)
        state.followButton:Show()

        -- Both edges: bindings may deliver the click on key down or key up
        -- depending on client settings, and registering one misses the other.
        state.followButton:RegisterForClicks("AnyUp", "AnyDown")
        state.followButton:SetAttribute("type", "macro")
    end
    state.followButton:SetAttribute("macrotext", BuildFollowMacro() or "")
end

-- The XP estimate needs one level, and the lowest is the honest choice: it is the
-- one being boosted hardest, and it never overstates what anyone earned.
local function LowestTaggerLevel()
    local lowest

    local function consider(info)
        if info.level and info.level > 0 and (not lowest or info.level < lowest) then
            lowest = info.level
        end
    end

    if db and db.taggers then
        for _, info in pairs(db.taggers) do consider(info) end
    end
    for _, info in pairs(dynamicTaggers) do consider(info) end
    return lowest
end

-- Every table keyed by a MOB's GUID, in one list so Forget and ResetAll cannot
-- drift apart. They were two hand-maintained sequences of the same names, and a
-- table added to one but not the other leaks for the whole session.
--
-- petOwner is deliberately absent: it is keyed by pet, outlives any single mob,
-- and is cleared only by a loading screen. So are isTracked and isCarryGuid,
-- which are keyed by the SOURCE of damage - a mob dying says nothing about who
-- the tagger is - and so belong to ResetAll alone.
C.PER_MOB = {
    "damage", "alerted", "lastSeen", "maxHealth", "mobLevel", "mobElite",
    "mobTrivial", "mobName", "tapOwner", "marked", "groupTagged",
}

local function Forget(guid)
    for i = 1, #C.PER_MOB do state[C.PER_MOB[i]][guid] = nil end
end

local function ResetAll()
    for i = 1, #C.PER_MOB do wipe(state[C.PER_MOB[i]]) end
    wipe(state.isTracked); wipe(state.isCarryGuid)
end

--------------------------------------------------------------------------------
-- Mob worth
--
-- Defined up here because the nameplate code needs it too. These are pure
-- predicates over cached state - no map lookups, so they're cheap enough to call
-- from the repaint ticker.
--------------------------------------------------------------------------------

-- "Zero difference": how far below you a mob can be before it greys out and stops
-- giving XP at all. Widens as you level.
local function ZeroDiff(level)
    if     level <= 7  then return 5
    elseif level <= 9  then return 6
    elseif level <= 11 then return 7
    elseif level <= 15 then return 8
    elseif level <= 19 then return 9
    elseif level <= 29 then return 11
    elseif level <= 39 then return 12
    elseif level <= 44 then return 13
    elseif level <= 49 then return 14
    elseif level <= 54 then return 15
    elseif level <= 59 then return 16
    end
    return 17
end

local function IsGrey(guid)
    local pl = LowestTaggerLevel()
    local ml = state.mobLevel[guid]
    if not pl or not ml or pl <= 0 or ml <= 0 then return false end
    return (pl - ml) >= ZeroDiff(pl)
end

-- Named mobs never worth tracking, whatever their level says. Netherweb Victims
-- are the cocoon spawns in Terokkar, and they clutter a grind with tags nobody
-- wants.
--
-- The defaults live HERE, in code, and are never copied into saved data. That is
-- the whole point: shipping a new one takes effect for everybody on the next
-- login, with nothing to migrate. The previous arrangement seeded them into
-- SavedVariables at first run, which meant a new default reached nobody who had
-- ever run the addon before.
C.BANNED_DEFAULT = {
    ["netherweb victim"]  = "Netherweb Victim",
    ["darkness released"] = "Darkness Released",
    ["foul purge"]        = "Foul Purge",
    -- Auto-tagged, so the threshold never applied to him anyway - but he pays no
    -- XP either, so there is nothing to report and banning outright is simpler
    -- than putting him on the auto-tag list.
    ["aggonis"]           = "Aggonis",
}

-- Mobs the tagger is credited with whatever anyone else does - the threshold
-- never applies. Empty by default: this is the list you add to as you find them.
-- Members are shown as already tagged, are never reported as a miss, and the
-- carry tapping one is not a theft, because there was nothing to steal. XP still
-- counts, which is the whole reason they are not simply banned.
C.AUTOTAG_DEFAULT = {}

-- db.banlist holds only what the user changed, which is why it is tri-state:
--
--   a string   they banned this name; the value is how to display it
--   false      they unbanned one of ours, which has to outlive the default
--   nil        they never said anything, so the default decides
--
-- Without the `false` case an unban would last until the next login and then
-- quietly undo itself.
-- Shared by both named-mob lists. `saved` is the user's delta, `defaults` the
-- table shipped in code.
local function ListHas(saved, defaults, name)
    if not name then return false end
    local key = strlower(name)
    local user = saved and saved[key]
    if user ~= nil then return user ~= false end
    return defaults[key] ~= nil
end

local function IsBanned(guid)
    if not db then return false end
    return ListHas(db.banlist, C.BANNED_DEFAULT, state.mobName[guid])
end

-- Mobs where the tagger does not have to land the first hit - credit is theirs
-- whoever tapped it.
--
-- This is ONLY about the tap. These mobs still pay XP and the threshold still
-- decides whether the tagger earned it, so they show a climbing percentage like
-- anything else and can still be missed. That is what separates them from the
-- ban list, which is for mobs paying no XP at all: there the threshold is
-- meaningless and a plain checkmark is the whole story.
local function IsAutoTagged(guid)
    if not db then return false end
    return ListHas(db.autotag, C.AUTOTAG_DEFAULT, state.mobName[guid])
end

-- The carry tapped it first AND that actually cost the tagger something. The
-- four places that used to test tapOwner directly now ask this instead, so the
-- auto-tag exception cannot be applied in one of them and forgotten in another:
-- the standing X, the suppressed threshold ding, the stolen-tag warning and the
-- silent death handler are the same decision wearing four faces.
local function TapLost(guid)
    return state.tapOwner[guid] == "carry" and not IsAutoTagged(guid)
end

-- Far enough below the lowest tagger to be beneath the point of the session.
--
-- Deliberately separate from IsGrey, which answers "does this pay literally
-- zero" and is a Blizzard formula. This one is a preference: Hellfire's level 1
-- scorpions are not grey to a level 20 tagger and do pay a few XP, but nobody is
-- out there farming them, and every cue spent on one is noise. The two are OR'd,
-- so whichever fires first wins.
local function IsFarBelowTagger(guid)
    local pl = LowestTaggerLevel()
    local ml = state.mobLevel[guid]
    if not pl or not ml or pl <= 0 or ml <= 0 then return false end
    return (pl - ml) >= C.IGNORE_LEVEL_GAP
end

-- Grey mobs, trivial minions and banned names pay nothing, so they get no
-- threshold ding, no death float and no XP. They still get a checkmark the
-- instant the tagger touches one: at zero XP the only question is whether they
-- have it at all, so a climbing percentage would be noise.
--
-- Every test here needs the mob's LEVEL or classification, which only exists
-- once CacheMobInfo has had a unit token for it. A mob we never got a token for
-- reads as worth something by default - see the token fallback in the damage
-- path, which is what stops that being the common case.
local function IsWorthless(guid)
    return IsBanned(guid) or state.mobTrivial[guid]
        or IsGrey(guid) or IsFarBelowTagger(guid)
end

--------------------------------------------------------------------------------
-- Nameplate badges
--------------------------------------------------------------------------------

-- Parented to the Blizzard base nameplate frame rather than any unit frame:
-- ThreatPlates/Plater/KUI recycle and restyle their own children, but the base
-- frame from C_NamePlate is stable, so the badge survives their re-skinning.
-- Horizontal anchors are pulled inward: the Blizzard base plate frame is wider
-- than the health bar most nameplate addons actually draw, so anchoring flush to
-- its edge leaves the badge floating well clear of the visible plate.
C.BADGE_SIDE_INSET = 12

-- badge point, plate point, x, y
C.BADGE_ANCHORS = {
    above = { "BOTTOM", "TOP",     0,                    4 },
    below = { "TOP",    "BOTTOM",  0,                   -4 },
    left  = { "RIGHT",  "LEFT",    C.BADGE_SIDE_INSET,     0 },
    right = { "LEFT",   "RIGHT",  -C.BADGE_SIDE_INSET,     0 },
}

local function ApplyBadgeAnchor(badge, plateFrame)
    local a = C.BADGE_ANCHORS[db.badgePos] or C.BADGE_ANCHORS.above
    badge:ClearAllPoints()
    badge:SetPoint(a[1], plateFrame, a[2], a[3], a[4])
    badge.anchorMode = db.badgePos   -- so GetBadge can spot a changed setting
end

local function CreateBadge(plateFrame)
    local badge = CreateFrame("Frame", nil, plateFrame)
    badge:SetSize(24, 24)
    badge:SetFrameStrata("HIGH")
    ApplyBadgeAnchor(badge, plateFrame)

    badge.check = badge:CreateTexture(nil, "OVERLAY")
    badge.check:SetTexture(C.CHECK_TEXTURE)
    badge.check:SetAllPoints(badge)
    badge.check:Hide()

    -- Shown on mobs we tapped ourselves: the tagger can never get credit for
    -- these, so the percentage is meaningless and the X is permanent.
    badge.deny = badge:CreateTexture(nil, "OVERLAY")
    badge.deny:SetTexture(C.X_TEXTURE)
    badge.deny:SetAllPoints(badge)
    badge.deny:Hide()

    badge.text = badge:CreateFontString(nil, "OVERLAY")
    badge.text:SetFont(STANDARD_TEXT_FONT, 18, "THICKOUTLINE")
    badge.text:SetPoint("CENTER", badge, "CENTER", 0, 0)
    badge.text:Hide()

    return badge
end

-- Frames can never be destroyed in WoW, and nameplates churn constantly, so the
-- badge is cached on the plate frame itself rather than on our per-add record.
local function GetBadge(unit, createIfMissing)
    local plateFrame = C_NamePlate.GetNamePlateForUnit(unit)
    if not plateFrame then return nil end
    if not plateFrame.tagTeamBadge and createIfMissing then
        plateFrame.tagTeamBadge = CreateBadge(plateFrame)
    end

    -- Re-anchor lazily instead of sweeping every plate when the setting changes:
    -- badges live on recycled frames, so some aren't reachable at that moment.
    local badge = plateFrame.tagTeamBadge
    if badge and badge.anchorMode ~= db.badgePos then
        ApplyBadgeAnchor(badge, plateFrame)
    end
    return badge
end

-- The moment a mob crosses the threshold, slam its badge checkmark into place.
--
-- This animates the badge itself rather than spawning marks over it. The badge
-- holds nothing but the checkmark at this point (the percentage is hidden once
-- the threshold is met), so scaling the whole frame scales exactly the thing we
-- want - and no separate mark can overlap the static check underneath it.
--
-- It can sit over the mob at all, unlike the death animation, because the mob is
-- still alive: its nameplate exists, so we anchor to it and never calculate a
-- screen position.
local function SpawnPlateStamp(unit)
    local badge = GetBadge(unit, true)
    if not badge then return end

    if not badge.stamp then
        badge.stamp = badge:CreateAnimationGroup()

        -- Phase one: slam in from oversized, past true size to a slight
        -- undershoot. Ordered animations run in sequence; same order runs
        -- together, so the fade rides along with this phase.
        local punch = badge.stamp:CreateAnimation("Scale")
        punch:SetOrder(1)
        punch:SetDuration(C.STAMP_IN_DURATION)
        punch:SetSmoothing("OUT")
        punch:SetOrigin("CENTER", 0, 0)
        punch:SetScaleFrom(C.STAMP_FROM, C.STAMP_FROM)
        punch:SetScaleTo(C.STAMP_UNDERSHOOT, C.STAMP_UNDERSHOOT)

        -- Opaque before the slam lands, so it reads as an impact and not a fade.
        local fadeIn = badge.stamp:CreateAnimation("Alpha")
        fadeIn:SetOrder(1)
        fadeIn:SetDuration(C.STAMP_IN_DURATION * 0.5)
        fadeIn:SetFromAlpha(0)
        fadeIn:SetToAlpha(1)

        -- Phase two: spring back out to true size.
        local settle = badge.stamp:CreateAnimation("Scale")
        settle:SetOrder(2)
        settle:SetDuration(C.STAMP_BACK_DURATION)
        settle:SetSmoothing("IN_OUT")
        settle:SetOrigin("CENTER", 0, 0)
        settle:SetScaleFrom(C.STAMP_UNDERSHOOT, C.STAMP_UNDERSHOOT)
        settle:SetScaleTo(1, 1)
    end

    -- Show the check now rather than waiting for the next UpdatePlate, so the
    -- animation has something to act on from its first frame.
    badge.text:Hide()
    badge.check:Show()

    badge.stamp:Stop()   -- cannot replay an animation mid-flight
    badge.stamp:Play()
end

local function UpdatePlate(unit)
    local p = state.plates[unit]
    if not p then return end

    local guid = p.guid
    local dealt = guid and state.damage[guid]

    -- Only cache max health for mobs the tagger has actually hit -
    -- caching every plate we ever see would grow unbounded, since the sweep
    -- only walks mobs with damage recorded.
    local maxhp = state.maxHealth[guid]
    if dealt then
        local live = UnitHealthMax(unit)
        if live and live > 0 then
            state.maxHealth[guid] = live
            maxhp = live
        end

        -- Back to full with damage still on the books means it evaded and reset.
        -- That's a fresh mob as far as the next pull is concerned, so the grouped
        -- mark comes off - otherwise one bad pull would brand it until it died.
        -- The quiet gap is what makes this safe to read; see RESET_GRACE.
        local quiet = (GetTime() - (state.lastSeen[guid] or 0)) >= C.RESET_GRACE
        if state.groupTagged[guid] and quiet and live and live > 0
            and UnitHealth(unit) >= live then
            state.groupTagged[guid] = nil
        end
    end

    -- Nothing the tagger does here can earn credit: either the carry owns the tag,
    -- or damage landed while we were grouped, which computes the mob's XP from the
    -- carry's level and splits it. Show a standing X rather than a percentage that
    -- would only be misleading.
    --
    -- TapLost, not tapOwner: on an auto-tagged mob the carry's first hit costs the
    -- tagger nothing, so the percentage is still worth watching and the X would be
    -- claiming a tag was lost that was never at risk. Being GROUPED still applies
    -- to them - that wrecks the XP by a different rule entirely.
    --
    -- The grouped mark is latched per mob, not read live, so dropping the party
    -- mid-pull does not quietly turn the X back into a promising number. It clears
    -- when the mob dies (Forget) or resets to full, above.
    if db.enabled and not Suspended() and HasTaggers()
        and (TapLost(guid) or state.groupTagged[guid]) then
        local badge = GetBadge(unit, true)
        if badge then
            badge.text:Hide()
            badge.check:Hide()
            badge.deny:Show()
        end
        return
    end

    if not db.enabled or Suspended() or not HasTaggers() or not dealt or not maxhp or maxhp <= 0 then
        local badge = GetBadge(unit, false)
        if badge then
            badge.check:Hide()
            badge.text:Hide()
            badge.deny:Hide()
        end
        return
    end

    local badge = GetBadge(unit, true)
    if not badge then return end
    badge.deny:Hide()

    -- Worth no XP, so the threshold is meaningless. Any damage at all tags it,
    -- and that's the only fact worth showing.
    if IsWorthless(guid) then
        badge.text:Hide()
        badge.check:Show()
        return
    end

    local pct = dealt / maxhp * 100
    if pct >= db.threshold then
        badge.text:Hide()
        badge.check:Show()
    else
        badge.check:Hide()
        badge.text:SetText(format("%d%%", pct))
        -- Amber as it approaches, plain white early on.
        if pct >= db.threshold * 0.75 then
            badge.text:SetTextColor(1, 0.82, 0)
        else
            badge.text:SetTextColor(1, 1, 1)
        end
        badge.text:Show()
    end

end

local function UpdateAllPlates()
    for unit in pairs(state.plates) do
        UpdatePlate(unit)
    end
end

--------------------------------------------------------------------------------
-- Miss burst
--
-- On death we throw a burst of marks where the badge was: red Xs if the mob died
-- untagged, green checkmarks if the tagger got it.
--
-- The nameplate is torn down as the mob dies, so these can't be parented to it -
-- we use the badge position recorded while it was alive and float the marks on
-- UIParent instead. Frames can't be destroyed in WoW, so they're pooled, and hits
-- and misses share one pool with the texture set per spawn.
--------------------------------------------------------------------------------

state.markPool = {}

local function ReleaseMark(anim)
    local f = anim:GetParent()
    f:Hide()
    tinsert(state.markPool, f)
end

local function AcquireMark()
    local f = tremove(state.markPool)
    if f then return f end

    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(C.MARK_SIZE, C.MARK_SIZE)
    f:SetFrameStrata("HIGH")
    f:Hide()

    -- Texture and label are set per spawn: hits and misses share one pool.
    f.tex = f:CreateTexture(nil, "OVERLAY")
    f.tex:SetAllPoints(f)

    f.label = f:CreateFontString(nil, "OVERLAY")
    f.label:SetFont(STANDARD_TEXT_FONT, 20, "THICKOUTLINE")
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -2)
    f.label:Hide()

    f.anim = f:CreateAnimationGroup()
    f.move = f.anim:CreateAnimation("Translation")
    f.move:SetDuration(C.FLOAT_DURATION)
    f.move:SetSmoothing("OUT")
    f.fade = f.anim:CreateAnimation("Alpha")
    f.fade:SetDuration(C.FLOAT_DURATION)
    f.fade:SetFromAlpha(1)
    f.fade:SetToAlpha(0)
    f.anim:SetScript("OnFinished", ReleaseMark)

    return f
end

-- The flight itself, shared by everything that floats: rise, hold, then fade, on
-- the cadence of the Classic XP gain text. Only the height it starts at differs,
-- and it is shared precisely so the burst and the quest notice above it cannot
-- drift into moving at different speeds.
local function LaunchMark(f, rise)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
        UIParent:GetWidth() / 2, UIParent:GetHeight() / 2 + rise)
    f:SetAlpha(1)

    f.move:SetOffset(0, C.FLOAT_RISE)
    f.move:SetDuration(C.FLOAT_DURATION)
    -- Holding opacity before the fade is what makes it read as the XP text
    -- rather than something merely disappearing.
    f.fade:SetStartDelay(C.FLOAT_FADE_DELAY)
    f.fade:SetDuration(C.FLOAT_DURATION - C.FLOAT_FADE_DELAY)

    f:Show()
    f.anim:Play()
end

local function SpawnBurst(texture, label, r, g, b)
    local f = AcquireMark()
    f.anim:Stop()   -- a pooled frame may still be mid-flight; you cannot
                    -- reconfigure an animation that is playing

    f.tex:SetTexture(texture)
    -- Re-anchored per spawn, not once at creation: the quest float shares this
    -- pool and centres the same FontString on the frame instead.
    f.label:ClearAllPoints()
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -2)
    if label then
        f.label:SetText(label)
        f.label:SetTextColor(r or 1, g or 1, b or 1)
        f.label:Show()
    else
        f.label:Hide()
    end

    LaunchMark(f, C.MARK_RISE)
end

-- Quest progress relayed by the tagger. Text only, no icon: the burst below it is
-- the one carrying a texture, and two icons stacked up the screen read as clutter
-- rather than as two separate notices.
local SpawnQuestFloat
do
local lastAt, row = 0, 0   -- block-scoped: main-chunk slots are scarce

SpawnQuestFloat = function(text)
    if not text or text == "" then return end

    local f = AcquireMark()
    f.anim:Stop()

    f.tex:SetTexture(nil)
    f.label:ClearAllPoints()
    f.label:SetPoint("CENTER", f, "CENTER")
    f.label:SetText(text)
    -- Pure yellow, deliberately NOT the XP text's gold: the two share a flight
    -- path, and near-identical colours a line apart read as one notice.
    f.label:SetTextColor(1, 1, 0)
    f.label:Show()

    -- The row resets once the previous one has cleared, so a steady trickle
    -- always uses the first slot and only a genuine pile-up stacks.
    local now = GetTime()
    if now - lastAt > C.FLOAT_DURATION then row = 0 end
    lastAt = now

    LaunchMark(f, C.QUEST_FLOAT_RISE + row * C.QUEST_FLOAT_STEP)
    row = (row + 1) % C.QUEST_FLOAT_ROWS
end
end

--------------------------------------------------------------------------------
-- Combat log
--------------------------------------------------------------------------------

-- In carry mode the carry is us; in tagger mode it's the named player boosting us.
local function MatchesCarry(guid, name)
    if not InTaggerMode() then
        if guid == playerGUID then return true end
        if not db.includePets then return false end
        -- Our own pet needs no summon and no name: the client will tell us its
        -- GUID outright. petOwner stays as the fallback for the frame or two
        -- before UNIT_PET has been round.
        return guid == Pets.myGUID or state.petOwner[guid] == playerGUID
    end

    if state.isCarryGuid[guid] then return true end
    if name and NormalizeName(name) == db.carryKey then
        state.isCarryGuid[guid] = true
        return true
    end
    if db.includePets then
        local owner = state.petOwner[guid]
        if owner and state.isCarryGuid[owner] then return true end
        if db.carryPetKey and Pets.IsPetGuid(guid)
            and NormalizeName(name) == db.carryPetKey then
            return true
        end
    end
    return false
end

-- Returns the matching tagger's key, or nil. Truthy either way, so callers that
-- only care whether it matched still read naturally.
local function MatchesTracked(guid, name)
    if not guid or not HasTaggers() then return nil end
    if state.isTracked[guid] then return state.isTracked[guid] end

    local key = TaggerKeyOf(name)
    if key then
        state.isTracked[guid] = key   -- CLEU always pairs name with GUID, so learn it once
        return key
    end

    if db.includePets then
        local owner = state.petOwner[guid]
        if owner and state.isTracked[owner] then return state.isTracked[owner] end
        -- Deliberately not cached into isTracked: that table means "this GUID is
        -- the tagger themselves", and SampleTrackedLevel reads it to decide whose
        -- level it just saw. A pet in there would write the pet's level onto its
        -- owner and hang the triangle on the pet.
        return Pets.TaggerKey(guid, name)
    end

    return nil
end

-- A cue is either a file path or a SOUNDKIT id; the file wins when both are set,
-- and a file that fails to play falls back to the id rather than going silent.
local function PlayCue(file, id)
    -- Master mute. Sits here rather than at each call site so nothing added later
    -- can accidentally bypass it.
    if not db.audio then return end

    if type(file) == "table" then
        -- A list of candidate paths, for cues with no saved setting behind them.
        -- The first one this client actually has wins; PlaySoundFile is what says
        -- so, which is why a path that isn't here costs a return value and
        -- nothing else.
        for i = 1, #file do
            if PlaySoundFile(file[i], C.SOUND_CHANNEL) then return end
        end
    elseif file and PlaySoundFile(file, C.SOUND_CHANNEL) then
        return
    end

    -- Silent rather than wrong: a made-up id does not fail, it plays some
    -- unrelated noise.
    if id then PlaySound(id, C.SOUND_CHANNEL) end
end

local function PlayAlertSound()
    PlayCue(db.soundFile, db.soundId)
end

local function PlayMissSound()
    PlayCue(db.missFile, db.missId)
end

local function PlayThresholdSound()
    if not db.sound then return end
    PlayAlertSound()
end

-- Cues for the notices that arrive over the link rather than out of the pull.
--
-- LEVELUP is the client's own ding. It is also this addon's *fallback* threshold
-- cue - but only the fallback: a file wins over an id in PlayCue, and db.soundFile
-- defaults to WeakAuras' Brass, so the two only collide on a client with no
-- WeakAuras installed.
C.DING_CUE = SOUNDKIT and SOUNDKIT.LEVELUP

-- Accepting a quest makes TWO sounds, and they are not interchangeable: the quest
-- log's paper page-turn, and then the drums-and-horns fanfare. The fanfare is the
-- one that means "quest accepted", and it is NOT what IG_QUEST_LIST_OPEN plays -
-- that key is the page-turn, which is what this cue used to send.
--
-- No exposed SOUNDKIT key on this client is the fanfare; it is engine-side, so it
-- has to come from the file. Tried as paths in order, and PlaySoundFile reports
-- whether one landed, so a path this client does not have costs a return value
-- and nothing else. Verify in game - it prints true or false:
--   /run print(PlaySoundFile([[Sound\Interface\iQuestActivate.ogg]]))
C.QUEST_FILES = {
    [[Sound\Interface\iQuestActivate.ogg]],
    [[Sound\Interface\iQuestActivate.wav]],
}

-- Last resort, and deliberately the page-turn: if you hear paper instead of
-- horns, every path above missed and that is the thing to go fix.
C.QUEST_CUE = SOUNDKIT and (SOUNDKIT.IG_QUEST_LIST_OPEN or SOUNDKIT.IG_QUEST_LOG_OPEN)

-- Handing one in gets its own fanfare, and it is a different one. Same trick as
-- above, and on firmer ground than that one was: the accept path is confirmed
-- working in game, which proves this client resolves Sound\Interface paths and
-- that this directory is where these live.
--
-- IG_QUEST_LIST_COMPLETE is the backstop rather than the page-turn, since a
-- completion cue that lands on the wrong sound should at least be a completion
-- sound. Verify the same way:
--   /run print(PlaySoundFile([[Sound\Interface\iQuestComplete.ogg]]))
C.QUEST_DONE_FILES = {
    [[Sound\Interface\iQuestComplete.ogg]],
    [[Sound\Interface\iQuestComplete.wav]],
}
C.QUEST_DONE_CUE = SOUNDKIT and (SOUNDKIT.IG_QUEST_LIST_COMPLETE or SOUNDKIT.IG_QUEST_LIST_OPEN)

--------------------------------------------------------------------------------
-- XP estimate
--
-- Classic/TBC mob XP is deterministic given both levels, so this is arithmetic
-- rather than guesswork. Two multipliers sit on top of it. Rested doubles it and
-- USED to be invisible - the tagger now reports the pool as REST, so it is folded
-- into the estimate rather than left to show up as a 2.00x. Grouping splits it,
-- and that one really is invisible, so the number stays labelled an estimate.
--------------------------------------------------------------------------------

-- Retail's uiMapIDs for Outland and its zones.
C.OUTLAND_MAP_ID = 101
-- Outland's zone uiMapIDs cluster in this range. Checked as well as the parent
-- chain, because a zone whose parent lookup fails still identifies itself.
C.OUTLAND_MAP_MIN, C.OUTLAND_MAP_MAX = 100, 111
-- This client numbers its maps from a different block, which is why auto-detect
-- called Nagrand (1951) "Azeroth" and under-paid every Outland estimate by the
-- gap between the two base constants. Only the continent itself is matched here:
-- the zones around it interleave with the Azeroth ones the Burning Crusade added
-- (Eversong, Ghostlands, Azuremyst, Bloodmyst, Silvermoon, the Exodar), so a
-- range over this block would call those Outland too.
C.OUTLAND_MAP_ID_CLASSIC = 1945
-- Map.dbc id for the Outland world. uiMapIDs get renumbered from client to
-- client; this one has meant Outland since the Burning Crusade shipped, so it's
-- the signal we trust first. Instances inside Outland report their own id and
-- fall through to the map walk below.
C.OUTLAND_INSTANCE_ID = 530

local currentMapID, currentInstanceID   -- surfaced by /tag diag

-- Outland mobs use a different base constant to Azeroth's, so the continent has
-- to be known. Never matches zone names, which are localised.
local function RefreshContinent()
    local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    currentMapID = id

    -- Asked first because it answers even when the map system isn't ready yet,
    -- and because it can't be thrown off by a client renumbering its uiMaps.
    currentInstanceID = GetInstanceInfo and select(8, GetInstanceInfo()) or nil
    if currentInstanceID == C.OUTLAND_INSTANCE_ID then
        state.inOutland = true
        return
    end

    local guard = 0
    while id and guard < 12 do
        if id == C.OUTLAND_MAP_ID or id == C.OUTLAND_MAP_ID_CLASSIC
            or (id >= C.OUTLAND_MAP_MIN and id <= C.OUTLAND_MAP_MAX) then
            state.inOutland = true
            return
        end
        local info = C_Map.GetMapInfo(id)
        id = info and info.parentMapID
        guard = guard + 1
    end
    state.inOutland = false
end

-- Both places that report detection state print this - /tag diag and /tag zone,
-- which must not disagree about what was detected.
local function MapDiag()
    return format("%s (instance %s)", tostring(currentMapID), tostring(currentInstanceID))
end

-- db.continent forces the base constant when auto-detection is wrong:
-- nil = detect, "outland" or "azeroth" = forced.
local function UsingOutlandBase()
    if db.continent == "outland" then return true end
    if db.continent == "azeroth" then return false end
    RefreshContinent()
    return state.inOutland
end

-- Rested doubles the xp off every kill, and only the tagger's client can see it,
-- so it reaches us as REST and lands in state.taggerRested. Folding it into the
-- estimate is what stops a perfectly ordinary rested kill reading as "2.00x" -
-- the multiplier is meant to surface what we CANNOT see, and this we now can.
--
-- All-or-nothing per kill, deliberately. The pool can run dry mid-kill and pay
-- somewhere between 1x and 2x, but pricing that needs the pool size at the
-- instant the mob died, which is on the other client and a message behind.
--
-- Any rested tagger doubles it. Damage pools against one threshold but xp does
-- not, so with several taggers this is a guess - the same simplification
-- LowestTaggerLevel already makes for the level.
local function RestedFactor()
    -- In tagger mode the pool is OUR OWN and needs no message to reach us. Without
    -- this the tagger would price its own kills undoubled while the carry priced
    -- the same kills doubled, and the two ends would disagree on every rested
    -- kill - which is the one thing sharing PrintKillLine is meant to prevent.
    if InTaggerMode() then
        return (GetXPExhaustion and (GetXPExhaustion() or 0) > 0) and 2 or 1
    end

    for _, pct in pairs(state.taggerRested) do
        if pct and pct > 0 then return 2 end
    end
    return 1
end

-- Returns estimated XP, 0 for a grey mob, or nil when either level is unknown.
local function EstimateXP(guid)
    local pl = LowestTaggerLevel()
    local ml = state.mobLevel[guid]
    if not pl or not ml or pl <= 0 or ml <= 0 then return nil end

    -- Resolved per kill rather than trusted from a zone event: at login the map
    -- system often isn't ready, so GetBestMapForUnit returns nil and we latch on
    -- "Azeroth", which under-reports every Outland kill by the gap between the
    -- two base constants - about 1.5x at level 63.
    local base = ml * 5 + (UsingOutlandBase() and 235 or 45)
    local xp

    if ml >= pl then
        -- Red mobs are capped at the orange rate, four levels up.
        xp = base * (1 + 0.05 * min(ml - pl, 4))
    else
        local zd = ZeroDiff(pl)
        local gap = pl - ml
        if gap >= zd then return 0 end
        xp = base * (1 - gap / zd)
    end

    if state.mobElite[guid] then xp = xp * 2 end
    return floor(xp + 0.5)
end

-- Pairing a kill with the report it produces is what turns "they gained 545 XP"
-- into "545 against an expected 545". The ratio between the two is the only
-- honest read on the multipliers an addon cannot observe from this side: rested
-- doubles it, a group split cuts it, a stale cached level skews it.
local function QueueKillForReport(name, pct, est, missed)
    local kill = {
        name = name, pct = pct, est = est, missed = missed,
        rested = RestedFactor() > 1,   -- pinned like `need`: the pool can empty
                                       -- before the report gets back to us
        need = db.threshold,   -- pinned: /tag threshold can move under a pending kill
        at = GetTime(), claimed = {},
    }
    pendingKills[#pendingKills + 1] = kill
    -- Reports that never arrive - comms off, an unlinked tagger, a kill outside
    -- their client's range - would otherwise pile up. Oldest goes first.
    while #pendingKills > C.XP_MATCH_MAX do tremove(pendingKills, 1) end
    return kill
end

-- Is a report actually plausible? Comms off, or nobody who has ever talked to
-- us, means nothing is coming - and then waiting for it only delays a guess.
-- Both the chat line and the float hang their "wait or draw now" on this.
local function ReportComing()
    return db.comms and next(linked) ~= nil
end

-- One float per kill, drawn by whoever gets there first: the tagger's report if
-- it beats the timer, our own estimate if it does not. kill.floated is the flag
-- both the timer and the report check, so neither can draw over the other.
--
-- The number is what changed here. The float used to be drawn the instant the mob
-- died, which meant it could only ever show the estimate; when a tagger is linked
-- the real figure is a fraction of a second away, and the centre of the screen is
-- the one place worth spending that fraction to get right. A "~" says the number
-- is still ours rather than theirs.
--
-- The miss float carries the percentage as well. That reverses an earlier call to
-- keep it a bare X - the reasoning then was that most misses are incidental, the
-- tagger clipping something you were killing anyway, and the share they reached
-- decides nothing. Which is true; it is also true that the ones that WERE real
-- attempts are the ones you want to read, and they are indistinguishable without
-- the number. The buzz is still the alert either way.
local function FloatKill(kill, actual)
    if kill.floated then return end
    kill.floated = true

    -- While a tagger is linked the screen shows CONFIRMED xp or no xp at all. The
    -- estimate is not a consolation prize - it is the number the link exists to
    -- replace, and the middle of the screen is read at a glance, so a guess there
    -- misreports the session.
    --
    -- kill.awaited marks the one path that can arrive here without a report while
    -- linked: a miss whose timer expired. It gets the share and no xp. A linked
    -- KILL never arrives here at all without one - see FloatKillSoon.
    local xp = actual or (not kill.awaited and kill.est) or nil
    local label
    if xp then
        label = format(actual and "+%d XP" or "~%d XP", xp)
        -- (x2) belongs to the CHECKMARK alone. It means the number in front of it
        -- already has the doubling in it, which is a thing you want to know about
        -- xp you earned; on an X the number that matters is how close they came,
        -- and a second parenthetical only competes with it.
        if kill.rested and not kill.missed then
            label = label .. format(" |c%s(x2)|r", C.HEX_RESTED)
        end
    end

    if kill.missed then
        -- The share, in its own colour because it is its own fact: the X is the
        -- verdict, this is the evidence behind it.
        --
        -- One decimal only when it lands within a point of the threshold. "22%"
        -- is the honest precision for a miss that was never close; the tenth is
        -- worth its glyph only where the gap between 37.6 and 38 IS the story.
        local need = kill.need
        local near = need and kill.pct >= need - 1 and kill.pct <= need + 1
        label = (label and label .. "  " or "")
            .. format(near and "|c%s(%.1f%%)|r" or "|c%s(%.0f%%)|r", C.HEX_SHARE, kill.pct)
    end

    if kill.missed then
        SafeCall(SpawnBurst, C.X_TEXTURE, label, 1, 0.35, 0.35)
    else
        SafeCall(SpawnBurst, C.CHECK_TEXTURE, label, 1, 0.86, 0.3)
    end
end

-- Draw it now, or wait for the tagger to say what it was worth.
--
-- Linked, a KILL has no timer at all. There are only two things a timeout could
-- draw and both are wrong: the estimate is the number the link exists to
-- replace, and a checkmark with nothing on it is worse than no checkmark. So
-- nothing appears until the report does, and if the report never comes nothing
-- appears - the chat line still says what happened. Be patient rather than
-- guess.
--
-- A MISS keeps its timer, because it has something honest to put up without the
-- report: the damage share, which is measured on our end. Dropping that would
-- silently lose the X on every miss the tagger never tapped - no report is ever
-- coming for those, so "wait for it" would mean "never show it".
local function FloatKillSoon(kill)
    if not ReportComing() then
        FloatKill(kill)
    elseif kill.missed then
        kill.awaited = true   -- suppresses the estimate; the share still shows
        C_Timer.After(C.FLOAT_WAIT, function() FloatKill(kill) end)
    end
end

-- A tagger's name in their class colour, for dropping into a float. Returns it
-- BARE when we have never had a unit token for them and so never learned the
-- class: the float's own yellow is already the base colour, so an uncoloured
-- name reads fine where a guessed one would just be wrong.
local function TaggerName(key, fallbackName)
    local info = key and db.taggers[key]
    local name = (info and info.name) or fallbackName or key or "your tagger"

    local colours = RAID_CLASS_COLORS
    local c = info and info.class and colours and colours[info.class]
    if not c then return name end

    -- Floored, because %x on a non-integer is a coin toss across Lua versions.
    -- colorStr is present on this client, so that branch is the one that runs.
    local hex = c.colorStr or format("ff%02x%02x%02x",
        floor((c.r or 1) * 255 + 0.5), floor((c.g or 1) * 255 + 0.5),
        floor((c.b or 1) * 255 + 0.5))
    return format("|c%s%s|r", hex, name)
end

-- <name> completed "<title>" for <n> XP - the name in their class colour, the
-- reward in the XP purple, and everything between them in the float's own yellow,
-- which is what |r reverts to. Goes to the same float the objective ticks use, so
-- a quest's whole life reads in one place on screen.
local function FloatQuest(key, who, verb, title, xp)
    local text = format("%s %s \"%s\"", TaggerName(key, who), verb, title or "a quest")
    if xp and xp > 0 then
        text = text .. format(" for |c%s%d XP|r", C.HEX_XP, xp)
    end
    SpawnQuestFloat(text)
end

-- Hand one reporting tagger the oldest kill it has not already claimed. Claims
-- are per tagger because damage is pooled against one threshold but XP is not: a
-- single kill draws one report from every linked tagger, and each of those wants
-- the same kill, not the one before it.
local function ClaimKillForReport(key)
    local now = GetTime()
    while pendingKills[1] and now - pendingKills[1].at > C.XP_MATCH_WINDOW do
        tremove(pendingKills, 1)
    end
    for i = 1, #pendingKills do
        if not pendingKills[i].claimed[key] then
            pendingKills[i].claimed[key] = true
            return pendingKills[i]
        end
    end
    return nil
end

-- 1.00x is exactly what the estimate assumes: not rested, not grouped, both
-- levels current. Anything else is the reading worth noticing, so it gets colour.
local function MultiplierText(mult)
    return format("|cff%s%.2fx|r",
        (mult >= 0.95 and mult <= 1.05) and "00ff00" or "ffff00", mult)
end

-- Red under RATIO_FLOOR, then through yellow to green at 100%. Red and green are
-- both full-on at the midpoint, which is what makes the middle read as yellow
-- rather than as muddy orange.
local function RatioHex(ratio)
    local t = (ratio - C.RATIO_FLOOR) / (1 - C.RATIO_FLOOR)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end

    local r, g
    if t < 0.5 then r, g = 1, t * 2 else r, g = (1 - t) * 2, 1 end
    return format("ff%02x%02x00", floor(r * 255 + 0.5), floor(g * 255 + 0.5))
end

-- ONE kill line, printed by both ends from the same code. The carry builds it
-- from the tagger's report, the tagger from its own flush; sharing the function
-- is what stops the two describing the same kill differently.
--
-- `nameTag` arrives already coloured, because that is the only part that differs:
-- the tagger's class colour on the carry, a green "You" on the tagger.
--
-- Everything on the line is a fact, not a judgement, except the ratio's colour -
-- which is the judgement, so it is the only thing that changes colour.
local function PrintKillLine(nameTag, kill, amount)
    -- /tag announce. This line IS the per-kill chat announcement now - it took
    -- over from the MISSED alert that the toggle used to gate - so the toggle
    -- points here, or it would toggle nothing at all.
    if not db.announce then return end

    local rested = kill.rested and format(" |c%s(x2)|r", C.HEX_RESTED) or ""
    -- The X marks the threshold going unmet, and it is THE miss notice - there is
    -- no separate MISSED line any more. The xp still landed, since the tap decides
    -- that and not the share, so it reads as a footnote rather than a verdict.
    local flag = kill.missed and (" " .. C.X_ICON) or ""

    if not kill.est or kill.est <= 0 then
        -- A level was unknown when it died, so there is nothing to measure the
        -- gain against. The share was still measured and is still worth saying.
        Print(format("%s gained |c%s%d XP|r%s, |c%s%.1f%%|r damage%s",
            nameTag, C.HEX_XP, amount, rested, C.HEX_SHARE, kill.pct, flag))
        return
    end

    local ratio = amount / kill.est
    Print(format("%s gained |c%s%d|r of |c%s%d XP|r%s, |c%s%.1f%%|r damage = "
        .. "|c%s%d%%|r XP%s",
        nameTag, C.HEX_XP, amount, C.HEX_XP, kill.est, rested,
        C.HEX_SHARE, kill.pct, RatioHex(ratio), floor(ratio * 100 + 0.5), flag))
end

-- The tagger's own copy of the line, and its own float. Both ends see the same
-- thing for the same kill; this side simply does not need the message to say it.
local function ReportOwnKill(amount)
    local kill = ClaimKillForReport(C.SELF_KEY)
    if not kill then return end

    PrintKillLine("|cff00ff00You|r", kill, amount)
    FloatKill(kill, amount)
end

local function CacheMobInfo(unit, guid)
    if not state.mobName[guid] then state.mobName[guid] = UnitName(unit) end

    local lvl = UnitLevel(unit)
    if lvl and lvl > 0 then state.mobLevel[guid] = lvl end   -- -1 means unreadable (skull)

    local class = UnitClassification(unit)
    state.mobElite[guid] = (class == "elite" or class == "rareelite" or class == "worldboss")

    -- "minus" is Blizzard's own flag for trivial minions - the low-health adds
    -- that pay nothing. Critters are the same story.
    --
    -- UnitCreatureType returns a LOCALIZED string, so comparing it to "Critter"
    -- is only correct on an English client and there is no id-based equivalent
    -- here. C.CRITTER prefers the client's own localized constant where one
    -- exists and falls back to the English word, which is no worse than before.
    -- Either way this is best-effort: the level gap is what actually carries the
    -- case, since a critter is level 1 and any tagger past level 11 clears it.
    state.mobTrivial[guid] = (class == "minus") or (UnitCreatureType(unit) == C.CRITTER)
end

local function GroupedWithTagger()
    if not HasTaggers() then return false end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if TaggerKeyOf(UnitName("raid" .. i)) then return true end
        end
    elseif IsInGroup() then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and TaggerKeyOf(UnitName(u)) then return true end
        end
    end
    return false
end

-- The carry, grouped with their own tagger. The two-player rule computes the
-- mob's XP from the CARRY's level and then splits it by level ratio, so the
-- tagger banks a rounding error no matter how much damage they landed - which
-- means nothing this addon would say about the kill is true. Every cue that
-- promises the tagger something has to check this.
--
-- Never applies in tagger mode: being grouped with the other taggers is the
-- correct state there, and the pooled threshold assumes it.
local function TagIsWasted()
    return not InTaggerMode() and GroupedWithTagger()
end

-- A tagger's party/raid token, when we're grouped with one. Worth having because
-- UnitInRange only gives real answers for group members - which is exactly the
-- situation auto-leave cares about.
local function TaggerPartyUnit()
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local u = "raid" .. i
            if UnitExists(u) and TaggerKeyOf(UnitName(u)) then return u end
        end
    elseif IsInGroup() then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and TaggerKeyOf(UnitName(u)) then return u end
        end
    end
    return nil
end

-- Promote a tagger to confirmed. Order of confirmation is recorded, because the
-- first one that actually answers should hold the triangle.
local function ConfirmTagger(key, how)
    if not db or not db.taggers then return end
    local info = db.taggers[key]
    if not info or info.confirmed then return end

    db.confirmSeq = (db.confirmSeq or 0) + 1
    info.confirmed = true
    info.confirmedOrder = db.confirmSeq

    ReassignMarkers()
    UpdateMacroButton()
    Print(format("|cff00ff00%s|r confirmed (%s)%s.", info.name, how,
        info.marker and (" - " .. C.MARKER_NAMES[info.marker]) or ""))
end

local function AmGroupLeader()
    if UnitIsGroupLeader then return UnitIsGroupLeader("player") end
    if IsPartyLeader then return IsPartyLeader() end
    return false
end

-- Are we in a two-person group with the other half of our pair?
local function InTagPairGroup()
    if IsInRaid() or not IsInGroup() then return false end
    if GetNumGroupMembers() ~= 2 then return false end

    local other
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then other = UnitName(u) break end
    end
    if not other then return false end

    -- Only for the other half of a pair, never a random duo.
    return IsPartner(other)
end

-- A two-person carry+tagger group is never a real party, it's transport. Free for
-- all means neither of you clicks through loot rolls on the way.
--
-- Retried rather than fired once, because a freshly formed party settles over a
-- second or two: leadership arrives WITH the roster, so an immediate check sees
-- us as a non-leader, and SetLootMethod itself gets swallowed if it lands during
-- that window. So we verify the result and try again rather than assume.
C.LOOT_ATTEMPTS = 6

local function CheckLootMethod(attempt)
    attempt = attempt or 1
    if not db.autoLoot or not InTagPairGroup() then return end
    if GetLootMethod and GetLootMethod() == "freeforall" then return end

    if AmGroupLeader() and SetLootMethod then
        SetLootMethod("freeforall")

        C_Timer.After(1, function()
            if not InTagPairGroup() then return end
            if GetLootMethod and GetLootMethod() == "freeforall" then
                Print("two-person tag group - loot set to |cffffff00free for all|r.")
            elseif attempt < C.LOOT_ATTEMPTS then
                CheckLootMethod(attempt + 1)
            end
        end)
        return
    end

    -- Not leader yet, or not leader at all. Either way, look again shortly.
    if attempt < C.LOOT_ATTEMPTS then
        C_Timer.After(1.5, function() CheckLootMethod(attempt + 1) end)
    end
end

-- Each tagger keeps their own marker, but only while ungrouped - in a party their
-- portrait and minimap dot already locate them, so the icon would be noise.
-- Ungrouped they're just another player in the crowd.
local function MarkTagger(unit, key)
    if InTaggerMode() then return end   -- no marking our own party
    if GroupedWithTagger() then return end

    local info = db.taggers[key]
    if not info then return end

    if db.taggerMarker and info.marker
        and GetRaidTargetIndex(unit) ~= info.marker then
        SetRaidTarget(unit, info.marker)
    end
end

-- Setting focus is protected: FocusUnit refuses from addon code, and driving the
-- chat box instead stole the edit box on every tick. So focus is only ever
-- OBSERVED here - press the keybind or run the macro, and this notices.
local function NoticeFocus()
    if not C.HAS_FOCUS then return end
    if UnitExists("focus") and TaggerKeyOf(UnitName("focus")) then
        -- Remembered by name: this is the only player we'll ask for an invite.
        state.focusTaggerName = UnitName("focus")
        if not state.focusEverSet then
            state.focusEverSet = true
            Print(format("focus is on |cff00ff00%s|r - losing it now asks for an invite.",
                state.focusTaggerName))
        end
    end
end

-- The one place a tagger's cached level moves, because it feeds every XP estimate
-- and a level stale by one quietly applies a penalty that is not real.
--
-- Two things move it, and only one of them works at range: seeing them on a unit
-- token, and their own client saying so over the link. Returns whether the number
-- actually changed, so a caller can tell a real ding from a confirmation.
local function NoteTaggerLevel(key, lvl)
    local info = key and db.taggers[key]
    if not info or not lvl or lvl <= 0 or lvl == info.level then return false end

    local was = info.level
    info.level = lvl
    if was then
        Print(format("%s is now level |cffffff00%d|r (was %d).", info.name, lvl, was))
    else
        Print(format("%s is level |cffffff00%d|r - XP estimates are live.", info.name, lvl))
    end
    return true
end

-- An UNLINKED tagger pushes nothing - they aren't in our group - so sample them
-- whenever they pass through a unit we can inspect. Targeting them once is enough,
-- and it re-samples as they level. A linked one sends LEVEL the moment they ding,
-- which is the only path that survives them being out of range.
local function SampleTrackedLevel(unit)
    if not HasTaggers() or not UnitExists(unit) then return end

    -- Not a player, but it may be a tagger's pet. Hung here rather than on its own
    -- scan so it inherits every call site this already has: the 2s sweep over
    -- eight tokens, targeting, and mouseover.
    if not UnitIsPlayer(unit) then
        SafeCall(Pets.Notice, unit)
        return
    end

    local guid = UnitGUID(unit)
    local key = guid and state.isTracked[guid] or TaggerKeyOf(UnitName(unit))
    if not key then return end
    if guid then state.isTracked[guid] = key end

    -- Seeing them on any unit token counts as contact, same as seeing them fight.
    trackedActiveAt = GetTime()
    SafeCall(MarkTagger, unit, key)

    ConfirmTagger(key, "on sight")
    -- Their class, learned once and saved: it is what colours their name in the
    -- quest floats. Free here and nowhere else - this is the only place we ever
    -- hold a unit token for them, and the class of a character never changes.
    local info = db.taggers[key]
    if info and not info.class then
        local _, classFile = UnitClass(unit)
        info.class = classFile
    end

    NoteTaggerLevel(key, UnitLevel(unit))
end

-- Every unit token the tagger plausibly occupies. "targettarget" is the valuable
-- one while powerlevelling: you target the mob, the mob is hitting them, so they
-- sit in your target's target slot for most of the pull. A level that goes stale
-- by one silently applies a level penalty that isn't real - a ~6% error per kill.
C.SCAN_TOKENS = {
    "target", "targettarget", "mouseover", "focus",
    "party1", "party2", "party3", "party4",
}

local function ScanForTracked()
    if Suspended() then return end
    if not HasTaggers() then return end
    NoticeFocus()
    for i = 1, #C.SCAN_TOKENS do
        SampleTrackedLevel(C.SCAN_TOKENS[i])
    end
end

-- Range can only be queried through a unit token, and an ungrouped player has one
-- only while you're targeting or mousing over them. Two tokens survive looking
-- away: focus, which TBC has and which persists until cleared, and a nameplate,
-- if friendly nameplates are enabled. Either one upgrades range detection from
-- "haven't seen them fight lately" to an actual check.
local function TaggerUnit()
    if not HasTaggers() then return nil end

    if UnitExists("focus") and TaggerKeyOf(UnitName("focus")) then
        return "focus"
    end

    for guid, unit in pairs(state.guidToUnit) do
        if state.isTracked[guid] and UnitExists(unit) then return unit end
    end
    return nil
end

-- true / false when we can actually tell, nil when there's no token to ask with.
local function TaggerInRange()
    local unit = TaggerUnit()
    if not unit then return nil end
    if not UnitIsConnected(unit) then return false end
    return UnitIsVisible(unit) and true or false
end

-- Focus is the signal on TBC: it persists until the unit goes away, so losing it
-- is a real event rather than something inferred from a timer. Returns nil when
-- focus can't answer - no focus client, never established, or the user has
-- pointed it at something of their own, which we don't fight over.
local function TaggerFocusLost()
    if not C.HAS_FOCUS or not db.autoFocus or not state.focusEverSet then return nil end

    if not UnitExists("focus") then return true end
    if not TaggerKeyOf(UnitName("focus")) then return nil end
    return not UnitIsVisible("focus")
end

-- Every pull made while grouped with a tagger is wasted: the two-player rule
-- computes XP from the carry's level, so the mob is grey to the group and pays
-- next to nothing. This is the single most expensive mistake the addon can catch.
local function WarnGroupedCombat()
    -- Same predicate the badge, the ding and the death handler use, so the X on
    -- the nameplate and this warning can never disagree about whether the pull
    -- is wasted.
    if not db.groupWarning or not TagIsWasted() then return end
    if (GetTime() - lastGroupWarnAt) < C.GROUPED_WARN_INTERVAL then return end

    lastGroupWarnAt = GetTime()
    Print("|cffff2020GROUPED WITH YOUR TAGGER|r - this kill earns them almost nothing. "
        .. "|cffffff00/tag leave|r to drop the party.")
    SafeCall(SpawnBurst, C.X_TEXTURE, "GROUPED", 1, 0.2, 0.2)
end

local function LeaveTaggerParty()
    if C_PartyInfo and C_PartyInfo.LeaveParty then
        C_PartyInfo.LeaveParty()
    elseif LeaveParty then
        LeaveParty()
    end
end

-- The party exists to travel together; once we're back in range it's costing XP.
-- Grace period after joining so an invite that arrives when we're already close
-- doesn't join and bounce in the same breath.
local function CheckAutoLeave()
    if Suspended() then return end
    if InTaggerMode() then return end   -- our party IS the tagger group
    if not db.autoLeave or InCombatLockdown() then return end
    if not GroupedWithTagger() then return end
    if (GetTime() - groupedAt) < C.LEAVE_GRACE then return end

    local unit = TaggerPartyUnit()
    if not unit then return end

    -- checkedRange false means the answer is meaningless, not that they're far.
    local inRange, checked = UnitInRange(unit)
    if checked == false or not inRange then return end

    Print("tagger back in range - |cff00ff00leaving the party|r so tags count again.")
    LeaveTaggerParty()
end

-- Ask one partner to invite us: over the addon link where there is one, by a
-- visible whisper where there isn't. `why` prefixes the chat line with the
-- context the caller has and this doesn't.
--
-- The fallback whisper is the delicate part. It exists because a saved link
-- proves they HAD the addon, not that it is listening now - but it must not fire
-- when the link worked. `IsInGroup()` at fire time is NOT that question: the
-- invite lands, we accept, and the auto-leave can put us back out of the party
-- inside the eight seconds, all before the timer runs. It then sees no group,
-- whispers, draws a second invite, and the two of you bounce in and out of a
-- party until someone types something. So it asks whether we joined a group at
-- any point SINCE the ask, which an accepted invite always satisfies.
-- Who to ask for an invite: the tagger we actually held focus on and lost.
-- Asking every tagger meant names that were typo'd, offline or simply elsewhere
-- got whispered too.
--
-- `fallback` is the whole difference between the two callers, and it is
-- deliberate rather than drift - they used to be copies whose comment claimed
-- they were the same pick, which they were not. A command someone typed should
-- reach the primary tagger even if focus was never held; the automatic path must
-- not, because on a five-second ticker that is whispering someone who never
-- agreed to anything. Classic Era has no focus unit at all, so there the
-- automatic path has nothing else to go on and falls back too.
local function InviteTarget(fallback)
    -- A remembered focus outlives the tagger it pointed at: /tag remove, /tag
    -- clear and the carry-mode switch all wipe the list without touching it, and
    -- the stale name then beat the new tagger to every ask.
    if state.focusTaggerName and not TaggerKeyOf(state.focusTaggerName) then
        state.focusTaggerName = nil
        state.focusEverSet = false   -- nobody current has been focused yet
    end

    local target = state.focusTaggerName
    if not target and (fallback or not C.HAS_FOCUS) then
        local list = TaggersByPriority()
        target = list[1] and list[1].name
    end
    return target
end

local function AskForInvite(target, why)
    local key = NormalizeName(target)
    local sentAt = GetTime()

    -- Claims the rate limit either way, so a hand-typed ask can't be followed by
    -- the ticker asking again a second later.
    lastWhisperAt = sentAt
    askedForInvite = true

    if db.comms and linked[key] then
        SendAddon("INV", target)
        Print(format("%sasked |cff00ff00%s|r to invite you |cff808080(addon link)|r.",
            why or "", target))

        C_Timer.After(C.INVITE_FALLBACK, function()
            if IsInGroup() or IsInRaid() then return end
            if groupedAt >= sentAt then return end   -- it worked; we have been and gone
            SendChatMessage(C.INVITE_MESSAGE, "WHISPER", nil, target)
            Print(format("no invite from %s - whispered \"%s\" instead.",
                target, C.INVITE_MESSAGE))
        end)
    else
        SendChatMessage(C.INVITE_MESSAGE, "WHISPER", nil, target)
        Print(format("%swhispered \"%s\" to |cff00ff00%s|r.",
            why or "", C.INVITE_MESSAGE, target))
    end
end

-- Nag when we're clearly levelling but nothing is focused, since out-of-range
-- detection is blind without it. Silent if focus points anywhere at all, even at
-- something unrelated - that's a deliberate choice by the user, not an oversight.
local function CheckFocusNag()
    if Suspended() then return end
    if InTaggerMode() then return end
    if not C.HAS_FOCUS or not db.focusWarning or not db.autoFocus then return end
    if not HasTaggers() or UnitExists("focus") then return end
    if IsInGroup() or IsInRaid() then return end

    -- Only while actually levelling: the tagger has done something recently.
    if trackedActiveAt == 0 or (GetTime() - trackedActiveAt) > C.NEAR_SECONDS then return end
    if (GetTime() - lastFocusNagAt) < C.FOCUS_NAG_INTERVAL then return end

    lastFocusNagAt = GetTime()
    Print("|cffff8080No focus set.|r Press your TagTeam keybind, or /focus a tagger - "
        .. "out-of-range detection needs it. |cffffff00/tag focuswarn|r to silence.")
end

-- Ask for an invite once we've lost contact. Rate limited twice over - a latch
-- that only re-arms when they come back, plus a hard cooldown - because an addon
-- that whispers on a timer is an addon that spams.
local function CheckContact()
    if Suspended() then return end
    if InTaggerMode() then return end   -- carry-side logistics only
    if not db.autoInvite or not HasTaggers() then return end

    -- Any group at all, not just one containing a tagger. If we're already in a
    -- party with other people, an invite is useless - we'd have to leave first -
    -- so asking would be noise.
    if trackedActiveAt == 0 or IsInGroup() or IsInRaid() then
        askedForInvite = false
        return
    end

    -- Focus first where we have it: it's an event, not an inference.
    local lost = TaggerFocusLost()
    if lost == false then
        trackedActiveAt = GetTime()
        askedForInvite = false
        return
    end

    if lost == nil then
        -- No focus to ask. Fall back to a live unit token, then to the timer.
        local inRange = TaggerInRange()
        if inRange == true then
            trackedActiveAt = GetTime()
            askedForInvite = false
            return
        end
        if inRange == nil and (GetTime() - trackedActiveAt) < C.OUT_OF_RANGE_AFTER then
            askedForInvite = false
            return
        end
    end

    if askedForInvite or (GetTime() - lastWhisperAt) < C.WHISPER_COOLDOWN then return end

    local target = InviteTarget(false)
    if not target then return end

    AskForInvite(target, "out of range - ")
end

-- Put one of the three markers on a mob the tagger has tagged. Marking is not a
-- protected action, so this works solo and in combat.
local function MarkTaggedMob(guid)
    if not db.markers or state.marked[guid] then return end

    local unit = state.guidToUnit[guid]
    if not unit then return end   -- retried from OnNameplateAdded

    SetRaidTarget(unit, C.TAG_MARKERS[markerSlot])
    state.marked[guid] = true
    markerSlot = markerSlot + 1
    if markerSlot > #C.TAG_MARKERS then markerSlot = 1 end
end

-- The carry just took a mob out from under the tagger. Only fires when the tagger
-- has been active recently, so it can't nag during solo play.
local function WarnTagStolen()
    -- Grouped beats stolen. Once the two-player rule is in play it stops
    -- mattering whose tag it was - the pull is worth a rounding error either way -
    -- so saying TAGGED here would name the smaller problem and hide the bigger
    -- one behind it.
    --
    -- This is also the only place the grouped warning can still be said. It
    -- otherwise rides PLAYER_REGEN_DISABLED, which does not fire again for
    -- someone who joined the party mid-fight: every mob pulled for the rest of
    -- that combat used to warn about the wrong thing.
    --
    -- Routed rather than duplicated so it inherits GROUPED_WARN_INTERVAL. That
    -- rate limit is what keeps this to one warning per pull instead of one per
    -- mob tapped, and it means a warning already shown at the start of the fight
    -- is not replayed on the next mob.
    if TagIsWasted() then return WarnGroupedCombat() end

    if not db.stealWarning then return end
    if GetTime() - trackedActiveAt > C.NEAR_SECONDS then return end
    SafeCall(SpawnBurst, C.X_TEXTURE, "TAGGED", 1, 0.55, 0.1)
end

-- Fires only for mobs the tagger actually damaged. A mob they never
-- touched is indistinguishable from any random kill of your own, and alerting on
-- those would scold you for every mob you solo.
local function HandleDeath(guid, name)
    if not db.enabled or not HasTaggers() then return end

    -- The carry owned the tag, so the tagger earned nothing regardless of damage
    -- done. Reporting a tag or banking XP here would be a lie, and the steal
    -- warning already fired when it happened.
    --
    -- Not so on an auto-tagged mob, which is the whole point of that list: credit
    -- there does not follow the first hit. The threshold still decides, though -
    -- these pay XP, so falling short of it is a real miss and gets the real cue.
    if TapLost(guid) then return end

    -- Grouped with the tagger, so the two-player rule computed this mob's XP from
    -- the CARRY's level and split it: what they actually banked is a rounding
    -- error, and the threshold no longer decides anything. Every cue this function
    -- has is a lie in that state - the float would claim XP they never earned, the
    -- miss alert would scold them for missing a share that was worthless anyway,
    -- and sessionXP would quietly inflate with numbers nobody got.
    --
    -- Silence is the honest answer, and it is also the only cue that fits: the
    -- pull already fired the GROUPED warning, and on a fast kill a second burst
    -- lands on top of it. One warning per pull, not one warning plus a lie.
    --
    -- Both halves are needed. The latch catches a mob tagged while grouped whose
    -- killing blow came from the carry, so no tagger damage event refreshed it;
    -- the live check catches joining a group part-way through a pull that started
    -- clean. Either one means the X was standing on its plate.
    if state.groupTagged[guid] or TagIsWasted() then return end

    -- Greys and trivial minions pay nothing: no float, no sound, no session
    -- count. Counting them would quietly inflate the XP total with zeroes.
    if IsWorthless(guid) then return end

    local dealt = state.damage[guid]
    if not dealt or dealt <= 0 then return end

    -- No cached max health means we never had eyes on this mob, so we have no
    -- honest denominator - stay quiet rather than guess either way.
    local maxhp = state.maxHealth[guid]
    if not maxhp or maxhp <= 0 then return end

    local pct = dealt / maxhp * 100

    -- Tagged it. Checkmarks only, no sound: the threshold ding already fired when
    -- it crossed the threshold, and a second cue on every kill would be noise.
    if pct >= db.threshold then
        local raw = EstimateXP(guid)
        local shown   -- scaled estimate; stays nil when either level was unknown

        if raw and raw > 0 then
            -- Rested is part of the ESTIMATE, not of the user-tunable scale, so it
            -- goes in before it - which also keeps /tag calibrate honest, since
            -- that solves against lastRawXP and would otherwise read a rested
            -- kill as a scale of 2.
            local base = raw * RestedFactor()
            shown = floor(base * (db.xpScale or 1) + 0.5)
            state.sessionXP = state.sessionXP + shown

            -- Held before db.xpScale so /tag calibrate can solve for it directly.
            state.lastRawXP = base
            state.lastXPInfo = format("%s, mob %d vs their %d%s",
                name or "target", state.mobLevel[guid] or 0, LowestTaggerLevel() or 0,
                RestedFactor() > 1 and ", rested x2" or "")
        end
        state.sessionTags = state.sessionTags + 1

        -- Queued before the report can arrive. pct is the POOLED share of every
        -- tagger, the same number the threshold was measured against - never a
        -- per-head breakdown. A grey pays nothing, so PLAYER_XP_UPDATE never fires
        -- on their end and no report is ever sent: queuing one would leave an
        -- entry to expire and mispair the next real kill.
        local kill
        if raw ~= 0 then kill = QueueKillForReport(name, pct, shown) end

        if ReportTaggedKill then ReportTaggedKill() end

        if kill then
            FloatKillSoon(kill)
        else
            -- A grey. It pays nothing and no report can ever come, so there is
            -- nothing to wait for and nothing to put a number on.
            SafeCall(SpawnBurst, C.CHECK_TEXTURE, "grey", 0.62, 0.62, 0.62)
        end
        return
    end

    if not db.missAlert then return end

    -- A missed mob still pays the tagger - the tap decides that, not the damage
    -- share - so its report is coming and has to be queued like any other kill.
    -- Leaving it out was also mispairing: the report would arrive, find no entry
    -- of its own, and claim the NEXT tagged kill's instead.
    --
    -- Greys are the exception. They pay nothing, so no report can ever arrive to
    -- pair with, and a queued entry would sit there for the next real report to
    -- claim by mistake.
    local raw = EstimateXP(guid)
    -- A missed mob still pays the tagger, so rested still applies to it.
    local est = (raw and raw > 0)
        and floor(raw * RestedFactor() * (db.xpScale or 1) + 0.5) or nil
    local kill
    if raw ~= 0 then
        kill = QueueKillForReport(name, pct, est, true)
    else
        -- A grey miss. Not queued, so no report can claim it - but it still needs
        -- `missed` set, or the float would draw a checkmark over it.
        kill = { name = name, pct = pct, need = db.threshold, missed = true }
    end

    -- There is no separate MISSED line: the kill line carries the X and IS the
    -- notice, so a miss says nothing in chat until the report that prices it
    -- arrives. The SOUND is the alert itself and fires now, which is the part
    -- that has to be immediate.
    PlayMissSound()
    if kill.at then FloatKillSoon(kill) else FloatKill(kill) end
end


-- Units this addon must never treat as a tag.
--
-- Anything a player is driving. Enemy players were already dropped by their GUID
-- prefix; their pets, minions and guardians were not, so a tagger clipping a
-- warlock's felhunter or a hunter's boar banked damage on it, badged its
-- nameplate and buzzed when it died. None of it pays XP, so none of it was ever
-- a tag. The prefix settles players and hunter/warlock pets outright; guardians
-- and totems arrive as ordinary Creature GUIDs and need a unit token.
--
-- PvP-flagged NPCs too, under db.ignorePvP. These are the faction guards in
-- contested Outland ground - Halaa, the Hellfire towers - and unlike a player's
-- pet they DO pay XP, so this one is a preference rather than a fact: hitting one
-- flags the tagger for PvP, which on a defenceless low-level alt ends the session
-- rather than advancing it. /tag pvp for anyone who wants to grind them anyway.
--
-- Both token checks are blind past nameplate range. That is also the only range
-- where the addon would have displayed anything, so the gap is invisible.
local function IgnoredUnit(guid)
    if not guid then return true end
    local prefix = strsub(guid, 1, 4)
    if prefix == "Play" or prefix == "Pet-" then return true end

    local unit = state.guidToUnit[guid]
    if not unit then return false end
    if UnitPlayerControlled and UnitPlayerControlled(unit) then return true end
    if db.ignorePvP and UnitIsPVP and UnitIsPVP(unit) then return true end
    return false
end

local function OnCombatLog()
    local _, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName,
          _, _, p12, p13, p14, p15, p16 = CombatLogGetCurrentEventInfo()

    if subevent == "UNIT_DIED" then
        HandleDeath(destGUID, destName)
        Forget(destGUID)
        return
    end

    -- Learn ownership from summons: by GUID for anyone, and by name for a pet
    -- belonging to someone we care about. CLEU pairs both ends here, and the name
    -- is the half that survives the next loading screen - see the Pets section.
    -- Gated on a Pet- destination so a warlock's Infernal, a guardian with an
    -- ordinary Creature- GUID, can't overwrite the felhunter that does the work.
    if subevent == "SPELL_SUMMON" then
        state.petOwner[destGUID] = sourceGUID
        if Pets.IsPetGuid(destGUID) then Pets.Learn(sourceName, destName) end
        return
    end

    if not HasTaggers() or not db.enabled then return end

    local amount, overkill
    if subevent == "SWING_DAMAGE" then
        amount, overkill = p12, p13
    elseif C.SPELL_DAMAGE_EVENTS[subevent] then
        amount, overkill = p15, p16
    else
        return
    end

    if not amount or amount <= 0 then return end
    if IgnoredUnit(destGUID) then return end

    -- Recorded before the worthless check, which the banlist feeds into.
    if destName and not state.mobName[destGUID] then state.mobName[destGUID] = destName end

    local unit = state.guidToUnit[destGUID]

    -- Nameplates are the usual source of a unit token, and for most mobs they are
    -- enough. Two cases they miss, and both end with cues on things nobody wanted
    -- tracked, because every worthless test needs a level or a classification and
    -- gets neither without a token:
    --
    --   critters       usually have no nameplate at all, so the critter check
    --                  never ran for the very mobs it exists to catch
    --   the first hit  lands before the plate registers, and the first hit is
    --                  exactly when tapOwner is decided and TAGGED is said
    --
    -- Target and mouseover cost two API calls and only when the plate is missing.
    -- Whatever you just hit is usually the thing you had targeted.
    --
    -- Kept in a SEPARATE name from `unit`: that one stays strictly a nameplate
    -- token, because everything downstream of it anchors to a nameplate frame.
    -- Handing UpdatePlate or SpawnPlateStamp a "target" token would be asking
    -- for a restricted-region error on a frame that isn't there.
    local info = unit
    if not info then
        if UnitGUID("target") == destGUID then
            info = "target"
        elseif UnitGUID("mouseover") == destGUID then
            info = "mouseover"
        end
    end

    -- Cached before any tag decision runs, because worthless mobs are excluded
    -- from most of them and that verdict needs the mob's level and classification.
    if info then
        local live = UnitHealthMax(info)
        if live and live > 0 then state.maxHealth[destGUID] = live end
        CacheMobInfo(info, destGUID)
    end

    local worthless = IsWorthless(destGUID)

    local fromTracked = MatchesTracked(sourceGUID, sourceName)
    if fromTracked then trackedActiveAt = GetTime() end

    -- Whoever lands the first hit owns the tag. Recorded for every source, not
    -- just the tagger, because spotting that the carry took it is the whole point.
    if not state.tapOwner[destGUID] and not C.REACTIVE_EVENTS[subevent] then
        local fromCarry = MatchesCarry(sourceGUID, sourceName)

        state.tapOwner[destGUID] = fromCarry and "carry"
            or (fromTracked and "tagger" or "other")

        -- Nothing is at stake on a worthless mob, so neither the scolding nor the
        -- marker clutter is worth it.
        if not worthless then
            -- TapLost rather than tapOwner: on an auto-tagged mob there was
            -- nothing to take, so scolding for taking it is just wrong.
            if TapLost(destGUID) then
                WarnTagStolen()
            elseif state.tapOwner[destGUID] == "tagger" then
                SafeCall(MarkTaggedMob, destGUID)
                -- Being grouped is about the pull, not about who tapped it, so it
                -- has to be said on this side too - WarnTagStolen only covers the
                -- mobs the carry grabbed. Without it, whether a mob pulled after
                -- joining mid-fight warned at all came down to who happened to
                -- land the first hit. No-op when ungrouped, and rate limited when
                -- grouped, so the marker path stays quiet in the normal case.
                WarnGroupedCombat()
            end
        end
    end

    if not fromTracked then return end

    -- Overkill only exists on the killing blow, but counting it would overstate
    -- a threshold that's meant to be measured against real health removed.
    if overkill and overkill > 0 then
        amount = amount - overkill
        if amount <= 0 then return end
    end

    local before = state.damage[destGUID] or 0
    local after  = before + amount
    state.damage[destGUID]   = after
    state.lastSeen[destGUID] = GetTime()

    -- Latched the moment tagger damage lands while grouped, and deliberately not
    -- re-read afterwards: leaving the party does not retroactively make this mob
    -- worth tagging, so the X has to outlive the group. Cleared by the mob dying
    -- or resetting to full - see UpdatePlate.
    if TagIsWasted() then state.groupTagged[destGUID] = true end

    if not state.alerted[destGUID] and not worthless then
        local maxhp = state.maxHealth[destGUID]
        if maxhp and maxhp > 0 and (after / maxhp * 100) >= db.threshold then
            state.alerted[destGUID] = true
            -- Silent on mobs the carry tapped, and silent while grouped with the
            -- tagger: crossing the threshold earns them nothing in either state,
            -- so a ding would be a false promise. Same reasoning as the grouped
            -- early return in HandleDeath.
            if not TapLost(destGUID) and not state.groupTagged[destGUID] then
                PlayThresholdSound()
                if unit then SafeCall(SpawnPlateStamp, unit) end
            end
        end
    end

    if unit then UpdatePlate(unit) end
end

--------------------------------------------------------------------------------
-- Addon comms
--
-- Rides WoW's hidden addon channel over whispers, so nothing appears in either
-- player's chat log. Two jobs:
--
--   pairing  - setting a carry or a tagger offers the other end the inverse role,
--              which they accept or decline in a popup. Never applied unilaterally.
--   xp       - the tagger reports its REAL xp gain, read off UnitXP. That beats
--              the carry's estimate outright: no rested guesswork, no formula.
--------------------------------------------------------------------------------

C.ADDON_PREFIX = "TagTeam"

state.reportedXP = 0    -- real XP relayed by taggers this session
state.taggerRested = {} -- [key] = rested pool as a % of their level, from REST
state.reportedKills = 0 -- kills relayed, including zero-XP ones
state.offTagXP = 0      -- quest and discovery XP relayed, kept off the tag totals
state.saidMaxLevel = false
local lastXP, lastXPMax

local function AtMaxLevel()
    if GetMaxPlayerLevel then
        return UnitLevel("player") >= GetMaxPlayerLevel()
    end
    return (UnitXPMax("player") or 0) <= 0
end

SendAddon = function(msg, target)
    if not db.comms or not target then return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(C.ADDON_PREFIX, msg, "WHISPER", target)
    elseif SendAddonMessage then
        SendAddonMessage(C.ADDON_PREFIX, msg, "WHISPER", target)
    end
end

-- Both halves of the pair, in either direction. Returns how many were reached,
-- which is zero when comms are off - the caller uses that to decide whether it
-- can honestly claim the other client heard anything.
--
-- Defined this early so the pairing popup can announce a pet the moment a link
-- is accepted, rather than leaving the new partner to wait for a summon.
local function SendToPartners(msg)
    if not db.comms then return 0 end
    local n = 0
    if db.carry then SendAddon(msg, db.carry); n = n + 1 end
    if db.taggers then
        for _, info in pairs(db.taggers) do SendAddon(msg, info.name); n = n + 1 end
    end
    return n
end

-- Our own pet, to one partner or to both halves of the pair.
--
-- This is the message that makes a pet reliable rather than lucky: the other
-- client cannot see a pet that was summoned before it arrived, and pet GUIDs do
-- not survive a loading screen. Our own client always knows. Sent on every pet
-- change, at login, and whenever a link is established or re-verified.
--
-- An empty name is the clear, and is what a dismissed pet sends.
local AnnouncePet
do
local lastSent   -- block-scoped: main-chunk local slots are scarce, see Pets
AnnouncePet = function(target)
    local msg = "PET:" .. ((UnitExists("pet") and UnitName("pet")) or "")

    -- Aimed at one partner: always sent. This is the newly-linked or just-logged-
    -- in case, where the dedupe below would be exactly wrong.
    if target then SendAddon(msg, target); return end

    -- UNIT_PET fires on more than summons - dismissals, deaths, a pet swap - and
    -- this rides the whisper channel, so a broadcast only goes out on a change.
    if msg == lastSent then return end
    lastSent = msg
    SendToPartners(msg)
end
end

local function InviteToParty(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    elseif InviteUnit then
        InviteUnit(name)
    end
end

local function AddTagger(name)
    local key = NormalizeName(name)
    if not key then return nil end

    if not db.taggers[key] then
        db.taggerSeq = (db.taggerSeq or 0) + 1
        db.taggers[key] = {
            name = gsub(name, "^%l", strupper),
            order = db.taggerSeq,   -- establishment order, never reused
        }
    end
    ReassignMarkers()
    ResetAll(); UpdateAllPlates(); UpdateMacroButton()
    return db.taggers[key]
end

local function SetCarryTo(name)
    db.carry = gsub(name, "^%l", strupper)
    db.carryKey = NormalizeName(name)
    -- A new carry's pet is not the old carry's pet.
    db.carryPet, db.carryPetKey = nil, nil
    -- UpdateMacroButton matters here: in tagger mode the carry IS the follow
    -- target, so leaving the secure button stale makes the keybind a no-op.
    RebuildDynamicTaggers(); ResetAll(); UpdateAllPlates(); UpdateMacroButton()
end

-- The two modes are mutually exclusive: a client is either boosting or being
-- boosted, never both. Switching always clears the other side, and never without
-- asking - the old set is someone's configuration, not scratch data.
local function SwitchToCarryMode(taggerName)
    db.carry, db.carryKey, db.carryPet, db.carryPetKey = nil, nil, nil, nil
    RebuildDynamicTaggers()
    return AddTagger(taggerName)
end

local function SwitchToTaggerMode(carryName)
    if db.taggers then wipe(db.taggers) end
    SetCarryTo(carryName)
end

StaticPopupDialogs["TAGTEAM_MODE_SWITCH"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function(_, data)
        if not data then return end
        if data.mode == "carry" then
            local info = SwitchToCarryMode(data.who)
            if not info then return end
            Print(format("|cffffff00carry mode|r - tagger |cff00ff00%s|r added, carry cleared.",
                info.name))
            SendAddon("PAIRC", info.name)
        else
            SwitchToTaggerMode(data.who)
            Print(format("|cffffff00tagger mode|r - carry is |cff00ff00%s|r, taggers cleared.",
                db.carry))
            SendAddon("PAIRT", db.carry)
        end
    end,
}

StaticPopupDialogs["TAGTEAM_PAIR"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = DECLINE,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,   -- avoids tainting Blizzard's popup stack
    OnAccept = function(_, data)
        if not data then return end
        -- These clear the opposite side. The popup text already warned when that
        -- was going to happen, so this is the confirmation, not a surprise.
        if data.role == "carry" then
            SwitchToTaggerMode(data.who)
            Print(format("|cff00ff00%s|r is now your carry.", data.who))
        else
            local info = SwitchToCarryMode(data.who)
            Print(format("|cff00ff00%s|r added as a tagger.", info and info.name or data.who))
        end
        SendAddon("OK", data.who)
        AnnouncePet(data.who)
    end,
    OnCancel = function(_, data)
        if data then SendAddon("NO", data.who) end
    end,
}

-- One landing spot for a new threshold, whether it came from our own slash
-- command or from the other client. `alerted` is wiped so a mob that already
-- dinged under the old number can ding again under the new one.
local function ApplyThreshold(pct)
    db.threshold = pct
    wipe(state.alerted)
    UpdateAllPlates()
end

-- Apply and push, as one call, so no caller can do one without the other and
-- leave the two clients disagreeing about what counts as tagged.
--
-- It was originally split out to save an upvalue in HandleSlash, which no longer
-- exists in this file; it stays because the pairing is the point.
local function PushThreshold(pct)
    ApplyThreshold(pct)
    return SendToPartners("THRESH:" .. pct)
end

local function OnAddonMessage(msg, sender)
    local who = strsplit("-", sender or "")
    if not who or who == "" then return end
    local key = NormalizeName(who)
    linked[key] = true

    -- Their addon answering is the confirmation. Anyone can be added; only a name
    -- that talks back earns a marker slot ahead of the rest.
    ConfirmTagger(key, "addon link")

    local cmd, arg = strsplit(":", msg, 2)

    if cmd == "PAIRC" then
        -- They set us as their tagger and are offering to be our carry.
        -- Already paired: acknowledge, but say so - a silent confirm looks broken.
        if db.carryKey == key then
            SendAddon("OK", who)
            Print(format("|cff00ff00TagTeam linked|r with %s (already your carry).", who))
            return
        end
        StaticPopup_Show("TAGTEAM_PAIR",
            format("|cff33ff99TagTeam|r\n\n%s has added you as a tagger.\nSet them as your carry?%s", who,
                (db.taggers and next(db.taggers))
                    and "\n\n|cffff8080This clears your own tagger list.|r" or ""),
            nil, { role = "carry", who = who })

    elseif cmd == "PAIRT" then
        -- They set us as their carry and want to be one of our taggers.
        if db.taggers[key] then
            SendAddon("OK", who)
            Print(format("|cff00ff00TagTeam linked|r with %s (already a tagger).", who))
            return
        end
        StaticPopup_Show("TAGTEAM_PAIR",
            format("|cff33ff99TagTeam|r\n\n%s has set you as their carry.\nAdd them as a tagger?%s", who,
                InTaggerMode()
                    and format("\n\n|cffff8080This clears your carry (%s).|r", db.carry) or ""),
            nil, { role = "tagger", who = who })

    elseif cmd == "HELLO" then
        SendAddon("HI", who)   -- silent handshake; both ends are now marked linked
        AnnouncePet(who)       -- they just logged in; their copy of our pet is gone
        if ReportRested then ReportRested(true) end   -- and their copy of our rested

    elseif cmd == "HI" then
        -- Nothing to say. Arriving at all is the whole message - our own pet went
        -- out with the HELLO, and answering theirs would only bounce it back.

    elseif cmd == "PET" then
        -- Their pet, named by the only client that can see it without having
        -- witnessed the summon. Partners only: this writes into damage
        -- accounting, and a stranger must not get to point it anywhere.
        if not IsPartner(who) then return end
        Pets.Learn(who, arg or "")

    elseif cmd == "INV" then
        -- Only ever from the other half of an established pair. Without this
        -- check any stranger running the addon could make us open a group.
        if not IsPartner(who) then return end
        InviteToParty(who)
        Print(format("|cff00ff00%s|r asked for an invite - sent.", who))

    elseif cmd == "OK" then
        Print(format("|cff00ff00TagTeam linked|r with %s.", who))
        AnnouncePet(who)
        if ReportRested then ReportRested(true) end

    elseif cmd == "NO" then
        Print(format("|cffff8080%s|r declined the pairing.", who))

    elseif cmd == "THRESH" then
        -- This rewrites config on our side, so it is partners only - a stranger
        -- running the addon must not get to move our number.
        local pct = tonumber(arg)
        if not pct or pct <= 0 or pct > 100 then return end
        if not IsPartner(who) then return end
        if pct == db.threshold then return end
        ApplyThreshold(pct)
        Print(format("threshold set to |cffffff00%.1f%%|r of max health by |cff00ff00%s|r.",
            pct, who))

    elseif cmd == "XP" then
        local amount = tonumber(arg)
        if not amount then return end
        state.reportedKills = state.reportedKills + 1

        if amount <= 0 then
            -- Max-level tagger. Say it once so the link is visibly alive, then
            -- keep quiet - one line per kill would bury the chat frame.
            if not state.saidMaxLevel then
                state.saidMaxLevel = true
                Print(format("|cff00ff00%s|r is tagging, but at |cffffff00max level|r - "
                    .. "0 XP per kill. Counting tags only from here.", who))
            end
            return
        end

        state.reportedXP = state.reportedXP + amount

        local kill = ClaimKillForReport(key)
        if not kill then
            -- Killed outside our combat log range, or reported before we ever had
            -- eyes on the mob. Nothing to hold it against, so claim nothing.
            if db.announce then
                Print(format("%s gained |c%s%d XP|r |cff808080(unpaired)|r.",
                    TaggerName(key, who), C.HEX_XP, amount))
            end
            return
        end

        -- Missed kills stay out of the session multiplier. Their estimate assumes
        -- a full tag they never made, so averaging them in would drag the number
        -- down and hide what the properly tagged kills are actually paying.
        if kill.est and kill.est > 0 and not kill.missed then
            state.matchedEst, state.matchedXP = state.matchedEst + kill.est, state.matchedXP + amount
        end

        PrintKillLine(TaggerName(key, who), kill, amount)

        -- Cosmetic, so it goes after the log. This is the ONLY thing that draws a
        -- linked kill's float - there is no timer behind it.
        FloatKill(kill, amount)

    elseif cmd == "XPQ" or cmd == "XPD" then
        -- XP the tagger earned away from the tag: a quest turn-in, or a zone
        -- discovery while running to you. Said out loud so a jump in their bar
        -- has a name on it, but deliberately kept out of the kill counters and
        -- out of the session multiplier - no mob died, so there is no estimate
        -- for it to be measured against, and nothing to claim from pendingKills.
        --
        -- Its own command rather than a suffix on XP, so a partner still running
        -- the old version drops it silently instead of pairing it with a kill.
        --
        -- Split on 2, so a quest title with a colon in it arrives whole.
        local amount, title = strsplit(":", arg or "", 2)
        amount = tonumber(amount)
        if not amount or amount <= 0 then return end
        state.offTagXP = state.offTagXP + amount

        if cmd == "XPD" then
            Print(format("|cff00ff00%s|r gained |cffffff00%d|r XP |cff808080(discovery)|r.",
                who, amount))
            return
        end

        if title and title ~= "" then
            Print(format("|cff00ff00%s|r gained |cffffff00%d|r XP by completing \"%s\".",
                who, amount, title))
        else
            Print(format("|cff00ff00%s|r gained |cffffff00%d|r XP by completing a quest.",
                who, amount))
        end
        -- Handing one in gets its own fanfare, the counterpart to the accept cue.
        -- Not gated on /tag quests: that toggle is for the running commentary on
        -- their quest log, and this is an XP report, which is the whole job.
        PlayCue(C.QUEST_DONE_FILES, C.QUEST_DONE_CUE)
        -- Ungated for the same reason the cue is. Cosmetic, so it goes last.
        SafeCall(FloatQuest, key, who, "completed", title, amount)

    elseif cmd == "QACC" or cmd == "QDROP" then
        -- Their quest log, as it happens. No xp rides on either - they are here so
        -- the carry knows why the tagger just ran off, and can read the name back
        -- to them. Partners only: this is the chattiest thing on the channel, and
        -- a stranger has no business filling your chat frame with their quest log.
        --
        -- Gated on the RECEIVING side, because that is the chat frame filling
        -- up: /tag quests takes effect on the client you type it on, without
        -- needing the other end to agree or even to have the setting.
        if not db.questNotices then return end
        if not IsPartner(who) then return end
        if not arg or arg == "" then return end

        if cmd == "QACC" then
            Print(format("|cff00ff00%s|r accepted \"%s\".", who, arg))
            PlayCue(C.QUEST_FILES, C.QUEST_CUE)
            SafeCall(FloatQuest, key, who, "accepted", arg)
        else
            -- No cue. Dropping a quest is not an event to celebrate, and the
            -- fanfare on both would make the two indistinguishable by ear.
            Print(format("|cff00ff00%s|r abandoned \"%s\".", who, arg))
        end

    elseif cmd == "QPROG" then
        -- An objective ticking over, exactly as it appeared on their screen -
        -- their client formatted it, so it is printed rather than rebuilt.
        -- Partners only, like the rest of the quest notices.
        if not db.questNotices then return end
        if not IsPartner(who) then return end
        if not arg or arg == "" then return end
        Print(format("|cff00ff00%s|r - |cffffff00%s|r", who, arg))

        -- Cosmetic, so it goes last and behind SafeCall: a fault in the float
        -- must not take the chat line down with it.
        SafeCall(SpawnQuestFloat, arg)

    elseif cmd == "REST" then
        -- Partners only, same rule as LEVEL: this decides whether every kill's
        -- estimate gets doubled, and a stranger must not get to move that.
        if not IsPartner(who) then return end
        local pct = tonumber(arg)
        if not pct or pct < 0 then return end

        local was = state.taggerRested[key]
        state.taggerRested[key] = pct

        -- Said out loud on the crossings only, and on the first report that has
        -- something to say, which is the pairing. The pool drains continuously;
        -- narrating every step of that would bury the kills it explains.
        if was == nil and pct <= 0 then return end   -- paired, and not rested
        if was and (was > 0) == (pct > 0) then return end

        if pct > 0 then
            Print(format("|cff00ff00%s|r is rested: |cff66ccff%.1f%%|r of a level - "
                .. "their kills pay |cff66ccffdouble|r, and estimates now say so.", who, pct))
        else
            Print(format("|cff00ff00%s|r has used up their |cff66ccffrested XP|r - "
                .. "kills are back to face value.", who))
        end

    elseif cmd == "LEVEL" then
        -- Partners only, same rule as PET and THRESH: this writes into the XP
        -- estimate, and a stranger must not get to move the number every kill is
        -- measured against.
        if not IsPartner(who) then return end
        local lvl = tonumber(arg)
        if not lvl or lvl <= 0 then return end

        -- The cue fires whether or not the number moved. It is sent once per ding,
        -- and a unit-token scan that happened to see them first should not eat the
        -- one notice that works when they are nowhere near you.
        NoteTaggerLevel(key, lvl)
        PlayCue(nil, C.DING_CUE)
    end
end

-- Re-handshake after a reload. The saved link tells us who HAD the addon; this
-- confirms they still do, and re-marks them if the saved table was lost.
local function GreetPartners()
    SendToPartners("HELLO")
    -- Our pet, unprompted. A hunter who summoned before logging in generates no
    -- summon for anyone to see, so this is the only notice the other end gets.
    AnnouncePet()
    -- Same reasoning for the rested pool: the carry cannot see it at all.
    if ReportRested then ReportRested(true) end
end

-- Our own pet changed. Three jobs: cache the GUID the carry-mode damage path
-- matches on, re-derive the party pets that ride on dynamicTaggers entries, and
-- tell the other client. UNIT_PET is the only notice that a pet was summoned,
-- dismissed, or swapped.
local function OnPetChanged(unit)
    if not db then return end   -- events are registered at load, before ADDON_LOADED
    if unit == "player" then
        Pets.myGUID = UnitExists("pet") and UnitGUID("pet") or nil
        AnnouncePet()
    end
    RebuildDynamicTaggers()
end

-- At max level PLAYER_XP_UPDATE never fires, so there's nothing to hang a report
-- on. Report the kill itself with a zero, so the carry can still see the link
-- working and count tags.
ReportTaggedKill = function()
    if not InTaggerMode() or not db.carry then return end
    if not AtMaxLevel() then return end   -- PLAYER_XP_UPDATE covers every other case
    SendAddon("XP:0", db.carry)
end

-- Tagger side: read the real gain off UnitXP and relay it - one message per MOB,
-- not one per event, and labelled with where it came from.
--
-- A server tick that kills three mobs sends three "X dies, you gain N
-- experience" chat lines, but batches the player's xp field into a single
-- update: PLAYER_XP_UPDATE fires ONCE, carrying the whole sum. Relayed as it
-- stood, that claimed one pending kill on the carry and printed a single mob
-- paying 3x. The chat lines are the only per-mob record the client offers, so
-- they supply the split, while UnitXP stays the authority on the total - a bonus
-- the line words differently still lands in the field.
--
-- The same tick is also where the xp gets its label. Three things pay xp here -
-- kills, quest turn-ins, discoveries - and only kills have anything to do with
-- tagging, but the last two are worded IDENTICALLY in the chat log. So a kill is
-- identified by its line, a turn-in by QUEST_TURNED_IN, and a discovery by being
-- neither. See the note in AGENTS.md before loosening any of that.
--
-- All of it is read a frame late. The lines, the field update and the turn-in
-- arrive in the same frame in an order that is not ours to choose, and both the
-- split and the labelling need the whole tick in hand.
local ReportXPGain, NoteXPGainLine, NoteQuestTurnIn, NoteQuestAccepted, NoteQuestRemoved,
      NoteDiscovery
do
-- Block-scoped, like Pets' locals: main-chunk slots are scarce, see C and state.
local batch = {}   -- this frame's per-mob amounts, in the order they were awarded
local queued       -- a flush is already booked for the end of this frame
local pattern      -- built once from the client's own format string; false = no
local questXP      -- a turn-in this frame, waiting for the flush to classify it
local questName    -- its title, if the client would tell us
local turnedIn = {} -- questIDs handed in, so QUEST_REMOVED can tell that from an abandon
local discovered  -- a zone discovery announced itself this frame
local lastRest     -- last rested percentage sent, so a steady drain is not spam
local evidenceAt  -- when the newest scrap of evidence landed, for the TTL below

-- "%s dies, you gain %d experience." becomes
-- "^(.+) dies, you gain (%d+) experience%." - the escape-then-reopen trick from
-- OwnerPatterns. Deliberately NOT anchored at the end: the group, raid and
-- rested variants extend that sentence rather than rewriting it, so the prefix
-- matches all four. The quest line has no mob in it and never matches, which is
-- what keeps a turn-in out of the split.
local function KillPattern()
    if pattern ~= nil then return pattern end
    pattern = false
    local s = COMBATLOG_XPGAIN_FIRSTPERSON
    if type(s) ~= "string" then return false end
    local nName, nAmount
    s = gsub(s, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    s, nName   = gsub(s, "%%%%s", "(.+)")
    s, nAmount = gsub(s, "%%%%d", "(%%d+)")
    -- A locale that orders the two the other way round, or uses positional
    -- specifiers, leaves one of them unconverted. One lump sum beats a split
    -- built on a pattern we do not actually understand.
    if nName ~= 1 or nAmount ~= 1 then return false end
    pattern = "^" .. s
    return pattern
end

-- Everything the tick awarded, labelled by where it came from and, for kills,
-- divided the way the chat lines divided it.
--
-- EVERY label here rests on POSITIVE evidence, and that rule was learned the hard
-- way. This once inferred "discovery" from the absence of a kill line, which
-- misreported real kills at random - see the note in AGENTS.md. Nothing that
-- fails to identify itself gets a label: it falls through to a plain XP report,
-- which is what this did before any of the labelling existed.
local function Flush()
    queued = nil

    local cur, max = UnitXP("player"), UnitXPMax("player")
    local gained = 0
    if lastXP then
        if cur >= lastXP then
            gained = cur - lastXP
        else
            gained = (lastXPMax - lastXP) + cur   -- levelled during the gain
        end
    end
    lastXP, lastXPMax = cur, max

    -- /tag xpdebug. This exact ordering is what two separate misreports came
    -- down to, so it is worth being able to watch rather than infer.
    if db.xpDebug then
        Print(format("|cff808080xp: flush gained=%d kills=%d quest=%s disc=%s|r",
            gained, #batch, tostring(questXP), tostring(discovered)))
    end

    -- Nothing to attribute it to yet, so the evidence is KEPT rather than
    -- cleared. This is the whole fix for a hand-in being reported as a kill:
    -- QUEST_TURNED_IN routinely arrives BEFORE the xp it explains, this ran while
    -- the bar had not moved, and clearing here threw the turn-in away - so the xp
    -- that landed a moment later had nothing left to identify it.
    --
    -- Only aged out if the xp never turns up at all, which is what stops a
    -- turn-in at max level from lingering and claiming the next kill.
    if gained <= 0 then
        if evidenceAt and GetTime() - evidenceAt > C.XP_EVIDENCE_TTL then
            wipe(batch)
            questXP, questName, discovered, evidenceAt = nil, nil, nil, nil
        end
        return
    end

    local n, sum = #batch, 0
    for i = 1, n do sum = sum + batch[i] end
    local qXP, qName, explored = questXP, questName, discovered

    -- Cleared only now that there is a gain to spend it on.
    wipe(batch)
    questXP, questName, discovered, evidenceAt = nil, nil, nil, nil

    if not InTaggerMode() or not db.carry then return end

    -- Xp was gained, so the rested pool has just drained by some of it. Checked
    -- HERE rather than on a ticker, because gaining xp is the only thing that
    -- moves it - and it goes out ahead of the reports, so "they used it up"
    -- lands before the kills that no longer double.
    if ReportRested then ReportRested() end

    -- A turn-in in the same tick as a kill: taken off the top rather than left
    -- for the mobs to absorb, so neither report lies about the other.
    --
    -- Tested for nil, NOT for a positive amount. questXP becomes a number the
    -- moment a turn-in is noted, so nil-vs-number is what says "a turn-in
    -- happened here" - and QUEST_TURNED_IN firing is the positive evidence, not
    -- the size of the reward it carried. A client that hands us no reward, or a
    -- zero one, must not silently demote the quest back to a kill.
    if qXP then
        -- Reward unknown and nothing died: then the whole gain is the quest's.
        if qXP <= 0 and n == 0 then qXP = gained end
        if qXP > gained then qXP = gained end
        if qXP > 0 then
            SendAddon("XPQ:" .. qXP .. ":" .. (qName or ""), db.carry)
            gained = gained - qXP
            if gained <= 0 then return end
        end
    end

    -- Reporting a kill and logging it on our own screen are the same event, so
    -- they are one call. Both ends then describe the kill through PrintKillLine.
    local function SendKill(part)
        SendAddon("XP:" .. part, db.carry)
        ReportOwnKill(part)
    end

    if n == 0 then
        -- Nothing named a mob this tick. That is NOT proof of anything: a kill's
        -- own line can arrive without a mob name in it, and this client sends
        -- that variant often enough to matter. So only a zone discovery that
        -- announced ITSELF is labelled one, and everything else reports as the
        -- plain kill it almost always is.
        if explored then
            SendAddon("XPD:" .. gained, db.carry)
        else
            SendKill(gained)
        end
    elseif n < 2 or sum <= 0 then
        -- One mob: the field update is the whole story, nothing to divide.
        SendKill(gained)
    else
        -- Scaled onto the field update rather than sent as read, so the parts
        -- still add up to what was actually gained. The last mob takes the
        -- rounding remainder.
        local left = gained
        for i = 1, n do
            local part = (i == n) and left or floor(gained * batch[i] / sum + 0.5)
            if part < 1 then part = 1 end
            if part > left then part = left end
            left = left - part
            -- A zero would read as a max-level tagger on the other end.
            if part > 0 then SendKill(part) end
        end
    end
end

-- One flush per window, once the events that feed it have had time to arrive.
local function Schedule()
    if queued then return end
    queued = true
    C_Timer.After(C.XP_FLUSH_DELAY, Flush)
end

-- Booking a flush AND stamping the evidence, which is what lets the flush tell
-- "the xp has not caught up yet" from "the xp is never coming". Everything that
-- records evidence goes through here rather than calling Schedule directly.
local function Noted(what)
    evidenceAt = GetTime()
    if db.xpDebug then Print(format("|cff808080xp: noted %s|r", what)) end
    Schedule()
end

-- PLAYER_XP_UPDATE. The number is read at the flush, not here, so the event has
-- nothing left to do but book one.
ReportXPGain = Schedule

-- CHAT_MSG_COMBAT_XP_GAIN. Collected rather than sent: the amount on the line is
-- only a share until the tick's total is known.
NoteXPGainLine = function(msg)
    if type(msg) ~= "string" then return end
    if not InTaggerMode() or not db.carry then return end
    local p = KillPattern()
    if not p then return end
    local _, amount = strmatch(msg, p)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return end
    batch[#batch + 1] = amount
    Noted("kill line")
end

-- A quest's name, from whichever of these this client actually has. Guarded one
-- member at a time: it ships C_QuestLog without all of C_QuestLog.
--
-- GetTitleText is NOT in here. It reads whatever frame happens to be open, which
-- is right at a turn-in and a stale lie at an auto-accepted quest, so it stays at
-- the one call site that can vouch for it.
local function QuestTitle(questID, logIndex)
    local title
    if questID and C_QuestLog and C_QuestLog.GetTitleForQuestID then
        title = C_QuestLog.GetTitleForQuestID(questID)
    end
    if (not title or title == "") and logIndex and GetQuestLogTitle then
        title = GetQuestLogTitle(logIndex)
    end
    return (title and title ~= "") and title or nil
end

-- QUEST_TURNED_IN. Held for the flush rather than sent from here, so one tick's
-- xp is classified once against the field update - the only number that knows
-- what actually landed. Two turn-ins in a frame add up rather than overwrite.
NoteQuestTurnIn = function(questID, xpReward)
    if not InTaggerMode() or not db.carry then return end
    questXP = (questXP or 0) + (tonumber(xpReward) or 0)
    if questID then turnedIn[questID] = true end

    -- The quest frame is still open at a turn-in, so GetTitleText is honest here
    -- and it has been in the API since vanilla - worth having as the last resort,
    -- since the reward has already been counted and only the name is missing.
    local title = QuestTitle(questID)
    if not title and GetTitleText then
        title = GetTitleText()
        if title == "" then title = nil end
    end
    if title then questName = title end

    Noted("quest turn-in")
end

-- QUEST_ACCEPTED. Sent straight out: no xp changes hands here, so there is
-- nothing for the flush to classify. Signature is (questLogIndex, questID) on
-- this client - the id is the SECOND argument, not the first.
--
-- Nameless goes unsent. "Accepted a quest" tells the carry nothing they can act
-- on, and a wrong name is worse than no line at all.
NoteQuestAccepted = function(logIndex, questID)
    if not InTaggerMode() or not db.carry then return end
    local title = QuestTitle(questID, logIndex)
    if title then SendAddon("QACC:" .. title, db.carry) end
end

-- QUEST_REMOVED, which fires for a hand-in and an abandon ALIKE and does not say
-- which. Worse, it can arrive BEFORE the QUEST_TURNED_IN for the same quest, so
-- "have we seen a turn-in yet" is not answerable at the moment it fires. Both
-- facts were read off Questie, which runs on this client.
--
-- So: wait out the grace period, and if no turn-in has claimed the id by then, it
-- was abandoned. The title is read NOW rather than in the callback, while the
-- client still has the quest to be asked about.
NoteQuestRemoved = function(questID)
    if not questID then return end
    if not InTaggerMode() or not db.carry then return end

    local title = QuestTitle(questID)
    if not title then return end   -- nameless goes unsent, same rule as QACC

    C_Timer.After(C.ABANDON_GRACE, function()
        -- Cleared whether or not it fires, so the set cannot accumulate ids.
        local handedIn = turnedIn[questID]
        turnedIn[questID] = nil
        if handedIn then return end
        if InTaggerMode() and db.carry then SendAddon("QDROP:" .. title, db.carry) end
    end)
end

-- A zone discovery, announcing itself. This is the ONLY thing that earns the
-- discovery label - see the rule at the top of Flush. It carries no xp of its own
-- to send, it just tells the flush what this tick was.
NoteDiscovery = function()
    discovered = true
    Noted("discovery")
end

-- Tagger side: how much rested the pool still holds, as a PERCENTAGE of this
-- level's xp. The raw number GetXPExhaustion returns is meaningless to the carry
-- without knowing how big the level is, and the level is the tagger's, not
-- theirs. Nil from it means not rested at all; the pool can exceed 100%, since it
-- caps at a level and a half.
local function RestedPct()
    if not GetXPExhaustion then return 0 end      -- guarded on its own, as ever
    local pool = GetXPExhaustion()
    local need = UnitXPMax("player") or 0
    if not pool or pool <= 0 or need <= 0 then return 0 end
    return pool / need * 100
end

-- Sent on a change worth hearing about rather than on every kill. Crossing into
-- or out of rested is always worth it: that is the flag the carry's estimate
-- turns on, and crossing DOWN is "they used it up". Otherwise it waits for
-- REST_STEP of drift, so a full pool costs about fifteen messages as it drains
-- rather than one per mob.
--
-- force is the handshake and the ding, where the carry needs a number regardless
-- of what we last sent - they may have just logged in with none of this.
ReportRested = function(force)
    if not InTaggerMode() or not db.carry then return end

    local pct = RestedPct()
    if not force and lastRest then
        local crossed = (pct > 0) ~= (lastRest > 0)
        local moved = pct - lastRest
        if moved < 0 then moved = -moved end
        if not crossed and moved < C.REST_STEP then return end
    end

    lastRest = pct
    SendAddon(format("REST:%.1f", pct), db.carry)
end

end

-- PLAYER_LEVEL_UP, tagger side. The carry has no way to learn this on their own
-- while we are out of range - their level cache only moves when they can see us
-- on a unit token - and that cache is what every XP estimate is measured against.
--
-- arg1 is the new level. UnitLevel has not necessarily caught up when this fires,
-- so it is only the fallback.
local function ReportLevelUp(newLevel)
    if not InTaggerMode() or not db.carry then return end
    newLevel = tonumber(newLevel) or UnitLevel("player")
    if newLevel and newLevel > 0 then SendAddon("LEVEL:" .. newLevel, db.carry) end
    -- The pool is a percentage of the level, and the level just changed, so the
    -- number they hold is stale the instant this fires. Forced for that reason.
    if ReportRested then ReportRested(true) end
end

-- The yellow text in the middle of the screen, by TYPE rather than by text.
--
-- UI_INFO_MESSAGE carries every one of those messages - loot method changes,
-- party notices, duel results - so something has to sort them. GetGameMessageInfo
-- turns the numeric type into the NAME of the global string behind it, which
-- makes this filter locale-proof and needs no pattern at all: no escaping, no
-- format specifiers, nothing to go stale in a language we did not test.
--
-- The set is Questie's, which does exactly this on this same client.
-- ERR_QUEST_COMPLETE_S is deliberately absent - a finished quest already reports
-- itself when it is handed in, as XPQ.
C.QUEST_PROGRESS = {
    ERR_QUEST_ADD_KILL_SII         = true,
    ERR_QUEST_ADD_FOUND_SII        = true,
    ERR_QUEST_ADD_ITEM_SII         = true,
    ERR_QUEST_ADD_PLAYER_KILL_SII  = true,
    ERR_QUEST_OBJECTIVE_COMPLETE_S = true,
    ERR_QUEST_UNKNOWN_COMPLETE     = true,
    ERR_QUEST_FAILED_S             = true,
}

-- Exploring is the one xp source that announces itself in this same yellow text,
-- which is what lets the flush label a discovery on POSITIVE evidence instead of
-- inferring it from a missing kill line. If neither name is what this client
-- calls it, nothing is ever flagged and discovery xp reports as a plain kill -
-- which is exactly what it did before the label existed, and is the safe way to
-- be wrong.
C.DISCOVERY_INFO = {
    ERR_ZONE_EXPLORED_XP = true,
    ERR_ZONE_EXPLORED    = true,
}

-- UI_INFO_MESSAGE, tagger side. Quest progress is forwarded verbatim: the client
-- that produced it has already formatted and localised it, and re-deriving it
-- here could only make it worse.
local function ReportInfoMessage(errorType, message)
    if not InTaggerMode() or not db.carry then return end
    if not GetGameMessageInfo then return end   -- guarded on its own, as ever
    local kind = GetGameMessageInfo(errorType)

    -- Nothing to send, and deliberately checked before the text is: this one is
    -- read for its TYPE alone, and the flush needs it before it classifies.
    if C.DISCOVERY_INFO[kind] then NoteDiscovery(); return end

    if type(message) ~= "string" or message == "" then return end
    if not C.QUEST_PROGRESS[kind] then return end
    SendAddon("QPROG:" .. message, db.carry)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function OnNameplateAdded(unit)
    local guid = UnitGUID(unit)
    if not guid then return end
    state.plates[unit] = { guid = guid }
    state.guidToUnit[guid] = unit
    -- Only for mobs we're already tracking: caching level for every plate we ever
    -- see would grow unbounded, since the sweep only walks mobs with damage.
    if state.damage[guid] then CacheMobInfo(unit, guid) end
    -- The tag may have been recorded before this plate existed, so marking gets
    -- a second chance here.
    if state.tapOwner[guid] == "tagger" then SafeCall(MarkTaggedMob, guid) end
    UpdatePlate(unit)   -- mob may already have damage banked from outside plate range
end

local function OnNameplateRemoved(unit)
    local badge = GetBadge(unit, false)
    if badge then
        badge.check:Hide()
        badge.text:Hide()
        badge.deny:Hide()
    end

    local p = state.plates[unit]
    if p and p.guid and state.guidToUnit[p.guid] == unit then
        state.guidToUnit[p.guid] = nil
    end
    state.plates[unit] = nil
end

local function Sweep()
    local cutoff = GetTime() - C.STALE_SECONDS
    for guid, t in pairs(state.lastSeen) do
        if t < cutoff and not state.guidToUnit[guid] then
            Forget(guid)
        end
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PARTY_INVITE_REQUEST")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_XP_UPDATE")
frame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("UNIT_PET")

-- Events that keep running while suspended. Everything else - the combat log,
-- XP reporting, level sampling, invites, roster and grouped-combat warnings -
-- is dropped at the door, which is the whole point.
--
--   the two zone events   how we find out we've left again
--   ADDON_LOADED          setup must not be skippable
--   CHAT_MSG_ADDON        pairing and threshold sync stay live with your
--                         partner; neither one acts on the world
--   the nameplate pair    bookkeeping only. Dropping these would leave `plates`
--                         holding units that no longer exist, and UpdatePlate
--                         hides the badge itself while suspended anyway
C.SUSPEND_EXEMPT = {
    PLAYER_ENTERING_WORLD   = true,
    ZONE_CHANGED_NEW_AREA   = true,
    ADDON_LOADED            = true,
    CHAT_MSG_ADDON          = true,
    NAME_PLATE_UNIT_ADDED   = true,
    NAME_PLATE_UNIT_REMOVED = true,
}

frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if not C.SUSPEND_EXEMPT[event] and Suspended() then return end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == C.ADDON_PREFIX then OnAddonMessage(arg2, arg4) end
    elseif event == "PLAYER_XP_UPDATE" then
        ReportXPGain()
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        NoteXPGainLine(arg1)
    elseif event == "QUEST_TURNED_IN" then
        NoteQuestTurnIn(arg1, arg2)
    elseif event == "QUEST_ACCEPTED" then
        NoteQuestAccepted(arg1, arg2)
    elseif event == "QUEST_REMOVED" then
        NoteQuestRemoved(arg1)
    elseif event == "UI_INFO_MESSAGE" then
        ReportInfoMessage(arg1, arg2)
    elseif event == "PLAYER_LEVEL_UP" then
        ReportLevelUp(arg1)
    elseif event == "UNIT_PET" then
        OnPetChanged(arg1)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        OnNameplateAdded(arg1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        OnNameplateRemoved(arg1)
    elseif event == "PLAYER_TARGET_CHANGED" then
        SampleTrackedLevel("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        SampleTrackedLevel("mouseover")
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        RefreshContinent()
    elseif event == "PLAYER_REGEN_DISABLED" then
        WarnGroupedCombat()
    elseif event == "GROUP_ROSTER_UPDATE" then
        local grouped = IsInGroup() or IsInRaid()
        if grouped and not wasGrouped then groupedAt = GetTime() end
        wasGrouped = grouped
        RebuildDynamicTaggers()   -- party membership defines the tagger set
        -- Delayed: leadership and roster aren't settled the instant this fires.
        C_Timer.After(1, CheckLootMethod)
    elseif event == "PLAYER_REGEN_ENABLED" then
        markerSlot = 1   -- start each pull back at skull
        UpdateMacroButton()   -- secure attributes were locked during the fight
    elseif event == "PARTY_INVITE_REQUEST" then
        -- Strictly the other half of the pair, by name. Auto-accepting anything
        -- else would hand any passing stranger a way into your group.
        --
        -- Either direction, because /tag inv asks THEM to invite US: in tagger
        -- mode the invite that arrives is the carry's, and the carry is not a
        -- tagger by any definition this addon uses.
        if db.autoAccept and IsPartner(arg1) then
            AcceptGroup()
            StaticPopup_Hide("PARTY_INVITE")
            askedForInvite = false
            Print(format("accepted party invite from |cff00ff00%s|r.", arg1))
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        wipe(state.petOwner)   -- pet GUIDs don't survive a zone anyway
        ResetAll()
        RefreshContinent()
        playerGUID = UnitGUID("player")
        -- A pet already out at login fires no UNIT_PET on some paths, and its
        -- GUID is new after every loading screen.
        Pets.myGUID = UnitExists("pet") and UnitGUID("pet") or nil
        RebuildDynamicTaggers()
        -- Delayed: the chat system isn't ready to carry addon messages at login.
        C_Timer.After(5, GreetPartners)
    elseif event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        TagTeamDB = TagTeamDB or {}
        db = TagTeamDB
        ns.db = db   -- SlashCommands.lua reads it from here; see the exports
        if db.enabled     == nil then db.enabled     = true end
        if db.instanceOff == nil then db.instanceOff = true end
        if db.ignorePvP   == nil then db.ignorePvP   = true end
        if db.includePets == nil then db.includePets = true end
        if db.audio       == nil then db.audio       = true end
        if db.sound       == nil then db.sound       = true end
        if db.announce    == nil then db.announce    = true end
        if db.questNotices == nil then db.questNotices = true end
        if db.missAlert   == nil then db.missAlert   = true end
        if db.markers     == nil then db.markers     = true end
        if db.stealWarning == nil then db.stealWarning = true end
        if db.autoInvite   == nil then db.autoInvite   = true end
        if db.autoAccept   == nil then db.autoAccept   = true end
        if db.taggerMarker == nil then db.taggerMarker = true end
        if db.autoFocus    == nil then db.autoFocus    = C.HAS_FOCUS end
        if db.focusWarning == nil then db.focusWarning = true end
        if db.groupWarning == nil then db.groupWarning = true end
        if db.autoLeave    == nil then db.autoLeave    = true end
        -- One-time conversion from the scheme that copied defaults into saved
        -- data. Under that one, deleting an entry WAS the unban, so a default
        -- missing from an existing list means the user removed it deliberately -
        -- and that has to become an explicit `false` before the defaults start
        -- applying on their own, or it would come back on this very login.
        --
        -- Netherweb Victim is the only name that scheme ever shipped, so it is
        -- the only one where "absent" carries that meaning. Entries that merely
        -- duplicate a current default are dropped; the default covers them.
        --
        -- Guarded on db.banlist rather than the flag, so a brand-new install
        -- (no saved list at all) is never read as somebody having removed things.
        if db.banlist and not db.banlistMigrated then
            if db.banlist["netherweb victim"] == nil then
                db.banlist["netherweb victim"] = false
            end
            for key in pairs(C.BANNED_DEFAULT) do
                if db.banlist[key] then db.banlist[key] = nil end
            end
        end
        db.banlist = db.banlist or {}
        db.banlistMigrated = true
        db.autotag = db.autotag or {}
        db.banlistSeed = nil   -- retired with the scheme that used it
        if db.comms == nil then db.comms = true end
        if db.autoLoot == nil then db.autoLoot = true end
        db.badgePos = C.BADGE_ANCHORS[db.badgePos] and db.badgePos or "above"

        -- Rebind the runtime table onto the saved one: who has the addon is a
        -- stable fact about a character pair, and losing it on /reload silently
        -- dropped us back to visible "inv" whispers.
        db.linked = db.linked or {}
        linked = db.linked

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(C.ADDON_PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(C.ADDON_PREFIX)
        end
        lastXP, lastXPMax = UnitXP("player"), UnitXPMax("player")
        db.threshold = db.threshold or C.THRESHOLD_DEFAULT
        db.soundId   = db.soundId or (SOUNDKIT and SOUNDKIT.LEVELUP) or 888
        db.missId    = db.missId or (SOUNDKIT and SOUNDKIT.IG_QUEST_FAILED) or 847
        if db.soundFile == nil then db.soundFile = C.DEFAULT_SOUND_FILE end
        if db.missFile  == nil then db.missFile  = C.DEFAULT_MISS_FILE end
        -- Saved settings pin the old default, so move anyone still on it.
        if db.missFile == C.LEGACY_MISS_FILE then db.missFile = C.DEFAULT_MISS_FILE end
        if C.LEGACY_THRESHOLDS[db.threshold] then db.threshold = C.THRESHOLD_DEFAULT end
        -- Migrate the single-tagger fields from before the list existed.
        db.taggers = db.taggers or {}
        if db.name then
            local key = NormalizeName(db.name)
            db.taggers[key] = db.taggers[key]
                or { name = db.name, level = db.trackedLevel }
            db.name, db.trackedLevel = nil, nil
        end
        -- Backfill establishment order for taggers saved before it existed, then
        -- derive every marker from scratch.
        for _, info in pairs(db.taggers) do
            if not info.order then
                db.taggerSeq = (db.taggerSeq or 0) + 1
                info.order = db.taggerSeq
            end
        end
        ReassignMarkers()

        C_Timer.NewTicker(C.REFRESH_INTERVAL, UpdateAllPlates)
        C_Timer.NewTicker(C.SWEEP_INTERVAL, Sweep)
        C_Timer.NewTicker(2, ScanForTracked)
        C_Timer.NewTicker(5, CheckContact)
        C_Timer.NewTicker(5, CheckFocusNag)
        C_Timer.NewTicker(3, CheckAutoLeave)
        UpdateMacroButton()

        local names = TaggerNames()
        Print(format("loaded. Taggers: %s. Type |cffffff00/tag|r for options.",
            #names > 0 and ("|cff00ff00" .. table.concat(names, ", ") .. "|r")
                or "|cffff8080none|r"))
    end
end)

--------------------------------------------------------------------------------
-- Exports
--
-- SlashCommands.lua is the only other file and it is a leaf: it reads from here,
-- nothing here reads from it. This block is the entire boundary between them.
--
-- It sits at the bottom of the file on purpose. Everything below is assigned by
-- the time this runs, including SendAddon, which is a forward-declared local
-- filled in further up.
--
-- `db` is NOT here: it does not exist until ADDON_LOADED, so exporting it now
-- would hand the other file a nil forever. The event handler assigns ns.db when
-- it binds db, and HandleSlash re-reads it per dispatch.
--------------------------------------------------------------------------------

ns.C, ns.state = C, state

ns.Print, ns.SafeCall           = Print, SafeCall
ns.NormalizeName                = NormalizeName
ns.InTaggerMode                 = InTaggerMode
ns.TaggerNames, ns.TaggerInfo   = TaggerNames, TaggerInfo
ns.TaggerKeyOf                  = TaggerKeyOf
ns.TaggersByPriority            = TaggersByPriority
ns.PrimaryTaggerKey             = PrimaryTaggerKey
ns.ReassignMarkers              = ReassignMarkers
ns.AddTagger, ns.SetCarryTo     = AddTagger, SetCarryTo
ns.RebuildDynamicTaggers        = RebuildDynamicTaggers
ns.ResetAll                     = ResetAll
ns.UpdateAllPlates              = UpdateAllPlates
ns.UpdateMacroButton            = UpdateMacroButton
ns.BuildFollowMacro             = BuildFollowMacro
ns.RefreshContinent             = RefreshContinent
ns.MapDiag                      = MapDiag
ns.UsingOutlandBase             = UsingOutlandBase
ns.LowestTaggerLevel            = LowestTaggerLevel
ns.TaggerUnit, ns.TaggerInRange = TaggerUnit, TaggerInRange
ns.GroupedWithTagger            = GroupedWithTagger
ns.Suspended                    = Suspended
ns.MultiplierText               = MultiplierText
ns.LeaveTaggerParty             = LeaveTaggerParty
ns.CheckLootMethod              = CheckLootMethod
ns.AskForInvite                 = AskForInvite
ns.InviteTarget                 = InviteTarget
ns.SendAddon                    = SendAddon
ns.PushThreshold                = PushThreshold
ns.PlayCue                      = PlayCue
ns.PlayAlertSound               = PlayAlertSound
ns.PlayMissSound                = PlayMissSound
ns.SpawnBurst                   = SpawnBurst
