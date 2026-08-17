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

local ADDON_NAME = ...

local THRESHOLD_DEFAULT = 31   -- damage share needed to tag a mob

-- WeakAuras' bundled "Brass" sound. Referenced where it sits rather than copied
-- in: it's WA's asset, not Blizzard's, so it isn't in SOUNDKIT and can't be
-- played by id. PlaySoundFile reports whether it actually played, so if WA is
-- ever uninstalled we fall back to a built-in instead of going silent.
local DEFAULT_SOUND_FILE = [[Interface\AddOns\WeakAuras\Media\Sounds\Brass.mp3]]
-- A tone rather than a voice clip: voice clips grate fast when you hear them
-- dozens of times a session, which is exactly what a miss cue does.
local DEFAULT_MISS_FILE  = [[Interface\AddOns\WeakAuras\Media\Sounds\ErrorBeep.ogg]]
local LEGACY_MISS_FILE   = [[Interface\AddOns\WeakAuras\Media\Sounds\OhNo.ogg]]

-- "SFX" rather than "Master": Master ignores your sound sliders entirely and
-- plays at full volume, which is why these were blasting. SFX rides the Sound
-- Effects slider like the rest of the game.
local SOUND_CHANNEL = "SFX"

local STALE_SECONDS     = 60    -- forget mobs we haven't seen damaged in this long
local SWEEP_INTERVAL    = 5
local REFRESH_INTERVAL  = 0.25  -- catches max-health changes; CLEU drives instant updates

local X_TEXTURE     = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local CHECK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- Skull, cross, square. Deliberately only three: more markers than you can hold
-- in your head at a glance is just clutter. The rotation resets out of combat.
local TAG_MARKERS = { 8, 7, 6 }

-- Only warn about stealing a tag if the tagger has actually been doing something
-- recently - otherwise every mob you kill while questing alone would scold you.
local NEAR_SECONDS = 60

-- Client differences in one place, the way WhoDoesWhat's ClientFeatures does it,
-- so version checks don't get scattered through the logic. Focus arrived in TBC;
-- the 1.x client has no focus unit at all, so everything built on it is skipped
-- there and the timer fallback carries the load instead.
local isClassicEra = WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
local HAS_FOCUS    = not isClassicEra

-- Triangle, diamond, orange circle, in that order. Three slots, so a fourth
-- tagger has nowhere to go - adding one prompts you to drop an old one. Mob tags
-- use 8/7/6, so the two sets can never collide.
local TAGGER_MARKERS = { 4, 3, 2 }
local MARKER_NAMES   = { [4] = "triangle", [3] = "diamond", [2] = "orange" }

local INVITE_MESSAGE     = "inv"
local OUT_OF_RANGE_AFTER = 30   -- fallback only, where focus isn't available
local WHISPER_COOLDOWN   = 60   -- floor between whispers, whatever else happens
local INVITE_FALLBACK    = 8    -- wait for a direct invite before whispering
local FOCUS_NAG_INTERVAL = 60   -- between "you have no focus set" reminders
local GROUPED_WARN_INTERVAL = 15 -- between grouped-in-combat warnings
local LEAVE_GRACE = 3           -- settle time after joining before auto-leaving

-- The burst is drawn at a fixed spot on screen rather than over the mob. It has
-- to be: nameplate frames and everything parented to them are restricted regions
-- that cannot be measured while you are in combat, so their screen position is
-- simply not knowable at the moment a mob dies. Centre screen, raised clear of
-- the character, sized to be read at a glance instead of squinted at.
local MARK_SIZE = 44
local MARK_RISE = 180

-- Threshold stamp: a hard collapse from oversized that punches past true size,
-- then springs back out to it. About a fifth of a second end to end - the
-- undershoot and the snap back are what give it the impact.
local STAMP_IN_DURATION   = 0.12
local STAMP_BACK_DURATION = 0.09
local STAMP_FROM          = 3.0
local STAMP_UNDERSHOOT    = 0.78

-- Death float: one mark that rises and fades on the cadence of the Classic XP
-- gain text. Hits and misses share it, differing only in texture and label.
local FLOAT_RISE       = 70
local FLOAT_DURATION   = 1.8
local FLOAT_FADE_DELAY = 0.7

-- Reactive damage: it fires because the mob attacked us, not because we chose to
-- engage it. Thorns, Retribution Aura, Lightning Shield, the Imp's Fire Shield
-- and shield spikes all arrive as DAMAGE_SHIELD; DAMAGE_SPLIT is damage
-- redirected onto us. Neither is a deliberate tag, so neither is allowed to claim
-- one - though the damage itself still counts toward the tagger's threshold,
-- which matters for an enhancement shaman running Lightning Shield.
local REACTIVE_EVENTS = {
    DAMAGE_SHIELD = true,
    DAMAGE_SPLIT  = true,
}

-- Damage subevents carrying a SPELL-style prefix (spellId, spellName, spellSchool
-- occupy args 12-14, so amount/overkill land at 15/16).
local SPELL_DAMAGE_EVENTS = {
    SPELL_DAMAGE          = true,
    SPELL_PERIODIC_DAMAGE = true,
    SPELL_BUILDING_DAMAGE = true,
    RANGE_DAMAGE          = true,
    DAMAGE_SHIELD         = true,
    DAMAGE_SPLIT          = true,
}

-- Runtime state (never saved; all of it is per-pull scratch)
local damage    = {}  -- [destGUID]  = accumulated damage from the tagger
local alerted   = {}  -- [destGUID]  = true once we've played the threshold sound
local lastSeen  = {}  -- [destGUID]  = GetTime() of last accumulation
local maxHealth = {}  -- [destGUID]  = cached UnitHealthMax, so we can score off-screen mobs
local tapOwner  = {}  -- [destGUID]  = "carry" | "tagger" | "other", by first damage
local marked    = {}  -- [destGUID]  = true once we've put a raid marker on it
local mobLevel  = {}  -- [destGUID]  = cached UnitLevel, for the XP estimate
local mobElite  = {}  -- [destGUID]  = true if elite/rare-elite/boss (double XP)
local mobTrivial = {} -- [destGUID]  = true for critters and "minus" minions
local mobName   = {}  -- [destGUID]  = name, for the banlist
local petOwner  = {}  -- [petGUID]   = ownerGUID, learned from SPELL_SUMMON
local isTracked = {}  -- [guid]      = tagger key once a GUID is confirmed as one
local isCarryGuid = {} -- [guid]     = true once a GUID is confirmed as the carry
local plates    = {}  -- [unitToken] = { guid = , badge = }
local guidToUnit = {} -- [guid]      = unitToken, for instant nameplate updates

-- db.taggers = { [normalisedName] = { name = "Display", level = n } }
-- Their damage is pooled: the threshold is measured against the sum, which is
-- correct when the taggers are grouped with each other and sharing a tag.
local db                    -- TagTeamDB
local inOutland = false     -- recomputed on zone change; picks the XP base constant
local sessionXP, sessionTags = 0, 0
local playerGUID            -- our own GUID, for spotting mobs we tapped ourselves
local trackedActiveAt = 0   -- last time we saw the tagger do anything
local markerSlot = 1        -- rotates through TAG_MARKERS, resets out of combat
local lastRawXP, lastXPInfo -- last unscaled estimate, for /tag calibrate
local askedForInvite = false
local lastWhisperAt = 0
local lastFocusNagAt = 0
local lastGroupWarnAt = 0
local groupedAt = 0         -- when we last joined a group, for the leave grace
local wasGrouped = false
local focusEverSet = false  -- only then does losing focus mean anything
local focusTaggerName       -- the one player we'll ask for an invite
local ReportTaggedKill      -- assigned in the comms section, called from HandleDeath
local SendAddon             -- ditto; the contact checker needs it before it's defined
local linked = {}           -- [key] = true; rebound to db.linked so it survives /reload

-- Labels for the Key Bindings panel. Bindings.xml declares the binding itself.
BINDING_HEADER_TAGTEAM = "TagTeam"
_G["BINDING_NAME_CLICK TagTeamFollowButton:LeftButton"] = "Target / follow / focus tagger"

local frame = CreateFrame("Frame", "TagTeamFrame")

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TagTeam|r: " .. msg)
end

local lastCosmeticError   -- surfaced by /tag diag

-- Cosmetics run behind this. Twice now a fault in the death animation has taken
-- the badge or the threshold ding down with it, because a Lua error unwinds the
-- whole event handler. Nothing decorative is allowed to do that again. The error
-- is kept rather than discarded so a silent failure is still diagnosable.
local function SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then lastCosmeticError = err end
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

    local function add(unit)
        local name = UnitName(unit)
        local key = NormalizeName(name)
        if not key or key == db.carryKey then return end
        dynamicTaggers[key] = { name = name, level = UnitLevel(unit) }
    end

    add("player")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do add("raid" .. i) end
    elseif IsInGroup() then
        for i = 1, 4 do
            if UnitExists("party" .. i) then add("party" .. i) end
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
        list[i].marker = TAGGER_MARKERS[i]   -- nil past the third: no slot left
    end
end

-- The tagger holding the first slot. Focus follows the triangle.
local function PrimaryTaggerKey()
    if not db or not db.taggers then return nil end
    for key, info in pairs(db.taggers) do
        if info.marker == TAGGER_MARKERS[1] then return key end
    end
    return nil
end

-- Marker order, not alphabetical: triangle, diamond, orange, then anyone unmarked.
local function TaggersByPriority()
    local list = {}
    if not db or not db.taggers then return list end
    for i = 1, #TAGGER_MARKERS do
        for _, info in pairs(db.taggers) do
            if info.marker == TAGGER_MARKERS[i] then list[#list + 1] = info end
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
local followButton

local function UpdateMacroButton()
    -- Secure attributes are locked during combat; PLAYER_REGEN_ENABLED retries.
    if InCombatLockdown() then return end

    if not followButton then
        followButton = CreateFrame("Button", "TagTeamFollowButton", UIParent,
            "SecureActionButtonTemplate")

        -- Real size, real anchor, shown. A CLICK binding dispatches to a live
        -- frame; a zero-size unanchored one can be skipped silently.
        followButton:SetSize(1, 1)
        followButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, 200)
        followButton:Show()

        -- Both edges: bindings may deliver the click on key down or key up
        -- depending on client settings, and registering one misses the other.
        followButton:RegisterForClicks("AnyUp", "AnyDown")
        followButton:SetAttribute("type", "macro")
    end
    followButton:SetAttribute("macrotext", BuildFollowMacro() or "")
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

local function Forget(guid)
    damage[guid]    = nil
    alerted[guid]   = nil
    lastSeen[guid]  = nil
    maxHealth[guid] = nil
    mobLevel[guid]  = nil
    mobElite[guid]  = nil
    mobTrivial[guid] = nil
    mobName[guid]   = nil
    tapOwner[guid]  = nil
    marked[guid]    = nil
end

local function ResetAll()
    wipe(damage); wipe(alerted); wipe(lastSeen); wipe(maxHealth); wipe(isTracked)
    wipe(mobLevel); wipe(mobElite); wipe(mobTrivial); wipe(mobName)
    wipe(tapOwner); wipe(marked); wipe(isCarryGuid)
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
    local ml = mobLevel[guid]
    if not pl or not ml or pl <= 0 or ml <= 0 then return false end
    return (pl - ml) >= ZeroDiff(pl)
end

-- Named mobs you never want tracked, whatever their level says. Netherweb Victims
-- ship banned: they're the cocoon spawns in Terokkar, and they clutter a grind
-- with tags nobody wants.
local function IsBanned(guid)
    local name = mobName[guid]
    if not name or not db or not db.banlist then return false end
    return db.banlist[strlower(name)] ~= nil
end

-- Grey mobs, trivial minions and banned names pay nothing, so they get no
-- threshold ding, no death float and no XP. They still get a checkmark the
-- instant the tagger touches one: at zero XP the only question is whether they
-- have it at all, so a climbing percentage would be noise.
local function IsWorthless(guid)
    return IsBanned(guid) or mobTrivial[guid] or IsGrey(guid)
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
local BADGE_SIDE_INSET = 12

-- badge point, plate point, x, y
local BADGE_ANCHORS = {
    above = { "BOTTOM", "TOP",     0,                    4 },
    below = { "TOP",    "BOTTOM",  0,                   -4 },
    left  = { "RIGHT",  "LEFT",    BADGE_SIDE_INSET,     0 },
    right = { "LEFT",   "RIGHT",  -BADGE_SIDE_INSET,     0 },
}

local function ApplyBadgeAnchor(badge, plateFrame)
    local a = BADGE_ANCHORS[db.badgePos] or BADGE_ANCHORS.above
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
    badge.check:SetTexture(CHECK_TEXTURE)
    badge.check:SetAllPoints(badge)
    badge.check:Hide()

    -- Shown on mobs we tapped ourselves: the tagger can never get credit for
    -- these, so the percentage is meaningless and the X is permanent.
    badge.deny = badge:CreateTexture(nil, "OVERLAY")
    badge.deny:SetTexture(X_TEXTURE)
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
        punch:SetDuration(STAMP_IN_DURATION)
        punch:SetSmoothing("OUT")
        punch:SetOrigin("CENTER", 0, 0)
        punch:SetScaleFrom(STAMP_FROM, STAMP_FROM)
        punch:SetScaleTo(STAMP_UNDERSHOOT, STAMP_UNDERSHOOT)

        -- Opaque before the slam lands, so it reads as an impact and not a fade.
        local fadeIn = badge.stamp:CreateAnimation("Alpha")
        fadeIn:SetOrder(1)
        fadeIn:SetDuration(STAMP_IN_DURATION * 0.5)
        fadeIn:SetFromAlpha(0)
        fadeIn:SetToAlpha(1)

        -- Phase two: spring back out to true size.
        local settle = badge.stamp:CreateAnimation("Scale")
        settle:SetOrder(2)
        settle:SetDuration(STAMP_BACK_DURATION)
        settle:SetSmoothing("IN_OUT")
        settle:SetOrigin("CENTER", 0, 0)
        settle:SetScaleFrom(STAMP_UNDERSHOOT, STAMP_UNDERSHOOT)
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
    local p = plates[unit]
    if not p then return end

    local guid = p.guid
    local dealt = guid and damage[guid]

    -- Only cache max health for mobs the tagger has actually hit -
    -- caching every plate we ever see would grow unbounded, since the sweep
    -- only walks mobs with damage recorded.
    local maxhp = maxHealth[guid]
    if dealt then
        local live = UnitHealthMax(unit)
        if live and live > 0 then
            maxHealth[guid] = live
            maxhp = live
        end
    end

    -- The carry owns this tag, so nothing the tagger does can earn credit. Show a
    -- standing X instead of a percentage that would only be misleading.
    if db.enabled and HasTaggers() and tapOwner[guid] == "carry" then
        local badge = GetBadge(unit, true)
        if badge then
            badge.text:Hide()
            badge.check:Hide()
            badge.deny:Show()
        end
        return
    end

    if not db.enabled or not HasTaggers() or not dealt or not maxhp or maxhp <= 0 then
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
    for unit in pairs(plates) do
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

local markPool = {}

local function ReleaseMark(anim)
    local f = anim:GetParent()
    f:Hide()
    tinsert(markPool, f)
end

local function AcquireMark()
    local f = tremove(markPool)
    if f then return f end

    f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(MARK_SIZE, MARK_SIZE)
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
    f.move:SetDuration(FLOAT_DURATION)
    f.move:SetSmoothing("OUT")
    f.fade = f.anim:CreateAnimation("Alpha")
    f.fade:SetDuration(FLOAT_DURATION)
    f.fade:SetFromAlpha(1)
    f.fade:SetToAlpha(0)
    f.anim:SetScript("OnFinished", ReleaseMark)

    return f
end

local function SpawnBurst(texture, label, r, g, b)
    local f = AcquireMark()
    f.anim:Stop()   -- a pooled frame may still be mid-flight; you cannot
                    -- reconfigure an animation that is playing

    f.tex:SetTexture(texture)
    if label then
        f.label:SetText(label)
        f.label:SetTextColor(r or 1, g or 1, b or 1)
        f.label:Show()
    else
        f.label:Hide()
    end

    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
        UIParent:GetWidth() / 2, UIParent:GetHeight() / 2 + MARK_RISE)
    f:SetAlpha(1)

    f.move:SetOffset(0, FLOAT_RISE)
    f.move:SetDuration(FLOAT_DURATION)
    -- Holding opacity before the fade is what makes it read as the XP text
    -- rather than something merely disappearing.
    f.fade:SetStartDelay(FLOAT_FADE_DELAY)
    f.fade:SetDuration(FLOAT_DURATION - FLOAT_FADE_DELAY)

    f:Show()
    f.anim:Play()
end

--------------------------------------------------------------------------------
-- Combat log
--------------------------------------------------------------------------------

-- In carry mode the carry is us; in tagger mode it's the named player boosting us.
local function MatchesCarry(guid, name)
    if not InTaggerMode() then
        if guid == playerGUID then return true end
        return (db.includePets and petOwner[guid] == playerGUID) or false
    end

    if isCarryGuid[guid] then return true end
    if name and NormalizeName(name) == db.carryKey then
        isCarryGuid[guid] = true
        return true
    end
    if db.includePets then
        local owner = petOwner[guid]
        if owner and isCarryGuid[owner] then return true end
    end
    return false
end

-- Returns the matching tagger's key, or nil. Truthy either way, so callers that
-- only care whether it matched still read naturally.
local function MatchesTracked(guid, name)
    if not guid or not HasTaggers() then return nil end
    if isTracked[guid] then return isTracked[guid] end

    local key = TaggerKeyOf(name)
    if key then
        isTracked[guid] = key   -- CLEU always pairs name with GUID, so learn it once
        return key
    end

    if db.includePets then
        local owner = petOwner[guid]
        if owner and isTracked[owner] then return isTracked[owner] end
    end

    return nil
end

-- A cue is either a file path or a SOUNDKIT id; the file wins when both are set,
-- and a file that fails to play falls back to the id rather than going silent.
local function PlayCue(file, id)
    -- Master mute. Sits here rather than at each call site so nothing added later
    -- can accidentally bypass it.
    if not db.audio then return end

    if file and PlaySoundFile(file, SOUND_CHANNEL) then return end
    PlaySound(id, SOUND_CHANNEL)
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

--------------------------------------------------------------------------------
-- XP estimate
--
-- Classic/TBC mob XP is deterministic given both levels, so this is arithmetic
-- rather than guesswork. Two multipliers are invisible to us and are called out
-- where the number is shown: rested XP doubles it, and grouping splits it.
--------------------------------------------------------------------------------

local OUTLAND_MAP_ID = 101
-- Outland's zone uiMapIDs cluster in this range. Checked as well as the parent
-- chain, because a zone whose parent lookup fails still identifies itself.
local OUTLAND_MAP_MIN, OUTLAND_MAP_MAX = 100, 111

local currentMapID   -- surfaced by /tag diag

-- Outland mobs use a different base constant to Azeroth's, so the continent has
-- to be known. Walk the map parent chain rather than matching zone names, which
-- are localised.
local function RefreshContinent()
    local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    currentMapID = id

    local guard = 0
    while id and guard < 12 do
        if id == OUTLAND_MAP_ID or (id >= OUTLAND_MAP_MIN and id <= OUTLAND_MAP_MAX) then
            inOutland = true
            return
        end
        local info = C_Map.GetMapInfo(id)
        id = info and info.parentMapID
        guard = guard + 1
    end
    inOutland = false
end

-- db.continent forces the base constant when auto-detection is wrong:
-- nil = detect, "outland" or "azeroth" = forced.
local function UsingOutlandBase()
    if db.continent == "outland" then return true end
    if db.continent == "azeroth" then return false end
    RefreshContinent()
    return inOutland
end

-- Returns estimated XP, 0 for a grey mob, or nil when either level is unknown.
local function EstimateXP(guid)
    local pl = LowestTaggerLevel()
    local ml = mobLevel[guid]
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

    if mobElite[guid] then xp = xp * 2 end
    return floor(xp + 0.5)
end

local function CacheMobInfo(unit, guid)
    if not mobName[guid] then mobName[guid] = UnitName(unit) end

    local lvl = UnitLevel(unit)
    if lvl and lvl > 0 then mobLevel[guid] = lvl end   -- -1 means unreadable (skull)

    local class = UnitClassification(unit)
    mobElite[guid] = (class == "elite" or class == "rareelite" or class == "worldboss")

    -- "minus" is Blizzard's own flag for trivial minions - the low-health adds
    -- that pay nothing. Critters are the same story.
    mobTrivial[guid] = (class == "minus") or (UnitCreatureType(unit) == "Critter")
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
        info.marker and (" - " .. MARKER_NAMES[info.marker]) or ""))
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
    local key = NormalizeName(other)
    return (db.carryKey == key) or (db.taggers and db.taggers[key] ~= nil) or false
end

-- A two-person carry+tagger group is never a real party, it's transport. Free for
-- all means neither of you clicks through loot rolls on the way.
--
-- Retried rather than fired once, because a freshly formed party settles over a
-- second or two: leadership arrives WITH the roster, so an immediate check sees
-- us as a non-leader, and SetLootMethod itself gets swallowed if it lands during
-- that window. So we verify the result and try again rather than assume.
local LOOT_ATTEMPTS = 6

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
            elseif attempt < LOOT_ATTEMPTS then
                CheckLootMethod(attempt + 1)
            end
        end)
        return
    end

    -- Not leader yet, or not leader at all. Either way, look again shortly.
    if attempt < LOOT_ATTEMPTS then
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
    if not HAS_FOCUS then return end
    if UnitExists("focus") and TaggerKeyOf(UnitName("focus")) then
        -- Remembered by name: this is the only player we'll ask for an invite.
        focusTaggerName = UnitName("focus")
        if not focusEverSet then
            focusEverSet = true
            Print(format("focus is on |cff00ff00%s|r - losing it now asks for an invite.",
                focusTaggerName))
        end
    end
end

-- Nothing pushes the tagger's level to us - they aren't in our group - so
-- sample it whenever they pass through a unit we can inspect. Targeting them once
-- is enough, and it re-samples as they level.
local function SampleTrackedLevel(unit)
    if not HasTaggers() or not UnitExists(unit) or not UnitIsPlayer(unit) then return end

    local guid = UnitGUID(unit)
    local key = guid and isTracked[guid] or TaggerKeyOf(UnitName(unit))
    if not key then return end
    if guid then isTracked[guid] = key end

    -- Seeing them on any unit token counts as contact, same as seeing them fight.
    trackedActiveAt = GetTime()
    SafeCall(MarkTagger, unit, key)

    ConfirmTagger(key, "on sight")

    local info = db.taggers[key]
    local lvl = UnitLevel(unit)
    if not info or not lvl or lvl <= 0 or lvl == info.level then return end

    local was = info.level
    info.level = lvl
    if was then
        Print(format("%s is now level |cffffff00%d|r (was %d).", info.name, lvl, was))
    else
        Print(format("%s is level |cffffff00%d|r - XP estimates are live.", info.name, lvl))
    end
end

-- Every unit token the tagger plausibly occupies. "targettarget" is the valuable
-- one while powerlevelling: you target the mob, the mob is hitting them, so they
-- sit in your target's target slot for most of the pull. A level that goes stale
-- by one silently applies a level penalty that isn't real - a ~6% error per kill.
local SCAN_TOKENS = {
    "target", "targettarget", "mouseover", "focus",
    "party1", "party2", "party3", "party4",
}

local function ScanForTracked()
    if not HasTaggers() then return end
    NoticeFocus()
    for i = 1, #SCAN_TOKENS do
        SampleTrackedLevel(SCAN_TOKENS[i])
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

    for guid, unit in pairs(guidToUnit) do
        if isTracked[guid] and UnitExists(unit) then return unit end
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
    if not HAS_FOCUS or not db.autoFocus or not focusEverSet then return nil end

    if not UnitExists("focus") then return true end
    if not TaggerKeyOf(UnitName("focus")) then return nil end
    return not UnitIsVisible("focus")
end

-- Every pull made while grouped with a tagger is wasted: the two-player rule
-- computes XP from the carry's level, so the mob is grey to the group and pays
-- next to nothing. This is the single most expensive mistake the addon can catch.
local function WarnGroupedCombat()
    if InTaggerMode() then return end   -- grouped with other taggers is correct
    if not db.groupWarning or not GroupedWithTagger() then return end
    if (GetTime() - lastGroupWarnAt) < GROUPED_WARN_INTERVAL then return end

    lastGroupWarnAt = GetTime()
    Print("|cffff2020GROUPED WITH YOUR TAGGER|r - this kill earns them almost nothing. "
        .. "|cffffff00/tag leave|r to drop the party.")
    SafeCall(SpawnBurst, X_TEXTURE, "GROUPED", 1, 0.2, 0.2)
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
    if InTaggerMode() then return end   -- our party IS the tagger group
    if not db.autoLeave or InCombatLockdown() then return end
    if not GroupedWithTagger() then return end
    if (GetTime() - groupedAt) < LEAVE_GRACE then return end

    local unit = TaggerPartyUnit()
    if not unit then return end

    -- checkedRange false means the answer is meaningless, not that they're far.
    local inRange, checked = UnitInRange(unit)
    if checked == false or not inRange then return end

    Print("tagger back in range - |cff00ff00leaving the party|r so tags count again.")
    LeaveTaggerParty()
end

-- Nag when we're clearly levelling but nothing is focused, since out-of-range
-- detection is blind without it. Silent if focus points anywhere at all, even at
-- something unrelated - that's a deliberate choice by the user, not an oversight.
local function CheckFocusNag()
    if InTaggerMode() then return end
    if not HAS_FOCUS or not db.focusWarning or not db.autoFocus then return end
    if not HasTaggers() or UnitExists("focus") then return end
    if IsInGroup() or IsInRaid() then return end

    -- Only while actually levelling: the tagger has done something recently.
    if trackedActiveAt == 0 or (GetTime() - trackedActiveAt) > NEAR_SECONDS then return end
    if (GetTime() - lastFocusNagAt) < FOCUS_NAG_INTERVAL then return end

    lastFocusNagAt = GetTime()
    Print("|cffff8080No focus set.|r Press your TagTeam keybind, or /focus a tagger - "
        .. "out-of-range detection needs it. |cffffff00/tag focuswarn|r to silence.")
end

-- Ask for an invite once we've lost contact. Rate limited twice over - a latch
-- that only re-arms when they come back, plus a hard cooldown - because an addon
-- that whispers on a timer is an addon that spams.
local function CheckContact()
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
        if inRange == nil and (GetTime() - trackedActiveAt) < OUT_OF_RANGE_AFTER then
            askedForInvite = false
            return
        end
    end

    if askedForInvite or (GetTime() - lastWhisperAt) < WHISPER_COOLDOWN then return end

    -- Only the player we actually held focus on and lost. Asking every tagger
    -- meant names that were typo'd, offline or simply elsewhere got whispered too.
    local target = focusTaggerName
    if not target and not HAS_FOCUS then
        -- No focus on this client at all, so fall back to the primary tagger.
        local list = TaggersByPriority()
        target = list[1] and list[1].name
    end
    if not target then return end

    lastWhisperAt = GetTime()
    askedForInvite = true

    if linked[NormalizeName(target)] then
        SendAddon("INV", target)
        Print(format("out of range - asked |cff00ff00%s|r to invite (addon link).", target))

        -- A saved link says they HAD the addon, not that they're listening now.
        C_Timer.After(INVITE_FALLBACK, function()
            if not db.autoInvite or IsInGroup() or IsInRaid() then return end
            SendChatMessage(INVITE_MESSAGE, "WHISPER", nil, target)
            Print(format("no invite from %s - whispered \"%s\" instead.",
                target, INVITE_MESSAGE))
        end)
    else
        SendChatMessage(INVITE_MESSAGE, "WHISPER", nil, target)
        Print(format("out of range - whispered \"%s\" to %s.", INVITE_MESSAGE, target))
    end
end

-- Put one of the three markers on a mob the tagger has tagged. Marking is not a
-- protected action, so this works solo and in combat.
local function MarkTaggedMob(guid)
    if not db.markers or marked[guid] then return end

    local unit = guidToUnit[guid]
    if not unit then return end   -- retried from OnNameplateAdded

    SetRaidTarget(unit, TAG_MARKERS[markerSlot])
    marked[guid] = true
    markerSlot = markerSlot + 1
    if markerSlot > #TAG_MARKERS then markerSlot = 1 end
end

-- The carry just took a mob out from under the tagger. Only fires when the tagger
-- has been active recently, so it can't nag during solo play.
local function WarnTagStolen()
    if not db.stealWarning then return end
    if GetTime() - trackedActiveAt > NEAR_SECONDS then return end
    SafeCall(SpawnBurst, X_TEXTURE, "TAGGED", 1, 0.55, 0.1)
end

-- Fires only for mobs the tagger actually damaged. A mob they never
-- touched is indistinguishable from any random kill of your own, and alerting on
-- those would scold you for every mob you solo.
local function HandleDeath(guid, name)
    if not db.enabled or not HasTaggers() then return end

    -- The carry owned the tag, so the tagger earned nothing regardless of damage
    -- done. Reporting a tag or banking XP here would be a lie, and the steal
    -- warning already fired when it happened.
    if tapOwner[guid] == "carry" then return end

    -- Greys and trivial minions pay nothing: no float, no sound, no session
    -- count. Counting them would quietly inflate the XP total with zeroes.
    if IsWorthless(guid) then return end

    local dealt = damage[guid]
    if not dealt or dealt <= 0 then return end

    -- No cached max health means we never had eyes on this mob, so we have no
    -- honest denominator - stay quiet rather than guess either way.
    local maxhp = maxHealth[guid]
    if not maxhp or maxhp <= 0 then return end

    local pct = dealt / maxhp * 100

    -- Tagged it. Checkmarks only, no sound: the threshold ding already fired when
    -- it crossed 31%, and a second cue on every successful kill would be noise.
    if pct >= db.threshold then
        local raw = EstimateXP(guid)
        local label, r, g, b

        if raw == 0 then
            label, r, g, b = "grey", 0.62, 0.62, 0.62
        elseif raw then
            local shown = floor(raw * (db.xpScale or 1) + 0.5)
            label, r, g, b = format("+%d XP", shown), 1, 0.86, 0.3
            sessionXP = sessionXP + shown

            -- Held unscaled so /tag calibrate can solve for the scale directly.
            lastRawXP = raw
            lastXPInfo = format("%s, mob %d vs their %d",
                name or "target", mobLevel[guid] or 0, LowestTaggerLevel() or 0)
        end
        sessionTags = sessionTags + 1
        if ReportTaggedKill then ReportTaggedKill() end

        SafeCall(SpawnBurst, CHECK_TEXTURE, label, r, g, b)
        return
    end

    if not db.missAlert then return end

    -- Message first, then sound, then the cosmetic flourish: if the visual ever
    -- throws, it must not be able to swallow the alert that actually matters.
    if db.announce then
        Print(format("|cffff2020MISSED|r %s - died at |cffff8080%d%%|r, needed %d%%.",
            name or "target", pct, db.threshold))
    end
    PlayMissSound()
    SafeCall(SpawnBurst, X_TEXTURE, format("%d%%", pct), 1, 0.35, 0.35)
end

local function OnCombatLog()
    local _, subevent, _, sourceGUID, sourceName, _, _, destGUID, destName,
          _, _, p12, p13, p14, p15, p16 = CombatLogGetCurrentEventInfo()

    if subevent == "UNIT_DIED" then
        HandleDeath(destGUID, destName)
        Forget(destGUID)
        return
    end

    -- Pet damage can't be matched by name, so learn ownership from summons.
    if subevent == "SPELL_SUMMON" then
        petOwner[destGUID] = sourceGUID
        return
    end

    if not HasTaggers() or not db.enabled then return end

    local amount, overkill
    if subevent == "SWING_DAMAGE" then
        amount, overkill = p12, p13
    elseif SPELL_DAMAGE_EVENTS[subevent] then
        amount, overkill = p15, p16
    else
        return
    end

    if not amount or amount <= 0 then return end
    if not destGUID or strsub(destGUID, 1, 7) == "Player-" then return end

    -- Recorded before the worthless check, which the banlist feeds into.
    if destName and not mobName[destGUID] then mobName[destGUID] = destName end

    local unit = guidToUnit[destGUID]

    -- Cached before any tag decision runs, because worthless mobs are excluded
    -- from most of them and that verdict needs the mob's level and classification.
    if unit then
        local live = UnitHealthMax(unit)
        if live and live > 0 then maxHealth[destGUID] = live end
        CacheMobInfo(unit, destGUID)
    end

    local worthless = IsWorthless(destGUID)

    local fromTracked = MatchesTracked(sourceGUID, sourceName)
    if fromTracked then trackedActiveAt = GetTime() end

    -- Whoever lands the first hit owns the tag. Recorded for every source, not
    -- just the tagger, because spotting that the carry took it is the whole point.
    if not tapOwner[destGUID] and not REACTIVE_EVENTS[subevent] then
        local fromCarry = MatchesCarry(sourceGUID, sourceName)

        tapOwner[destGUID] = fromCarry and "carry"
            or (fromTracked and "tagger" or "other")

        -- Nothing is at stake on a worthless mob, so neither the scolding nor the
        -- marker clutter is worth it.
        if not worthless then
            if tapOwner[destGUID] == "carry" then
                WarnTagStolen()
            elseif tapOwner[destGUID] == "tagger" then
                SafeCall(MarkTaggedMob, destGUID)
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

    local before = damage[destGUID] or 0
    local after  = before + amount
    damage[destGUID]   = after
    lastSeen[destGUID] = GetTime()

    if not alerted[destGUID] and not worthless then
        local maxhp = maxHealth[destGUID]
        if maxhp and maxhp > 0 and (after / maxhp * 100) >= db.threshold then
            alerted[destGUID] = true
            -- Silent on mobs the carry tapped: crossing the threshold there earns
            -- the tagger nothing, so a ding would be a false promise.
            if tapOwner[destGUID] ~= "carry" then
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

local ADDON_PREFIX = "TagTeam"

local reportedXP = 0    -- real XP relayed by taggers this session
local reportedKills = 0 -- kills relayed, including zero-XP ones
local saidMaxLevel = false
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
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "WHISPER", target)
    elseif SendAddonMessage then
        SendAddonMessage(ADDON_PREFIX, msg, "WHISPER", target)
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
    -- UpdateMacroButton matters here: in tagger mode the carry IS the follow
    -- target, so leaving the secure button stale makes the keybind a no-op.
    RebuildDynamicTaggers(); ResetAll(); UpdateAllPlates(); UpdateMacroButton()
end

-- The two modes are mutually exclusive: a client is either boosting or being
-- boosted, never both. Switching always clears the other side, and never without
-- asking - the old set is someone's configuration, not scratch data.
local function SwitchToCarryMode(taggerName)
    db.carry, db.carryKey = nil, nil
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
    end,
    OnCancel = function(_, data)
        if data then SendAddon("NO", data.who) end
    end,
}

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

    elseif cmd == "HI" then
        -- Nothing to say. Arriving at all is the whole message.

    elseif cmd == "INV" then
        -- Only ever from the other half of an established pair. Without this
        -- check any stranger running the addon could make us open a group.
        if db.carryKey ~= key and not (db.taggers and db.taggers[key]) then return end
        InviteToParty(who)
        Print(format("|cff00ff00%s|r is out of range - invite sent.", who))

    elseif cmd == "OK" then
        Print(format("|cff00ff00TagTeam linked|r with %s.", who))

    elseif cmd == "NO" then
        Print(format("|cffff8080%s|r declined the pairing.", who))

    elseif cmd == "XP" then
        local amount = tonumber(arg)
        if not amount then return end
        reportedKills = reportedKills + 1

        if amount <= 0 then
            -- Max-level tagger. Say it once so the link is visibly alive, then
            -- keep quiet - one line per kill would bury the chat frame.
            if not saidMaxLevel then
                saidMaxLevel = true
                Print(format("|cff00ff00%s|r is tagging, but at |cffffff00max level|r - "
                    .. "0 XP per kill. Counting tags only from here.", who))
            end
            return
        end

        reportedXP = reportedXP + amount
        Print(format("|cff00ff00%s|r gained |cffffff00%d|r XP |cff808080(actual)|r.",
            who, amount))
    end
end

-- Re-handshake after a reload. The saved link tells us who HAD the addon; this
-- confirms they still do, and re-marks them if the saved table was lost.
local function GreetPartners()
    if not db.comms then return end
    if db.carry then SendAddon("HELLO", db.carry) end
    if db.taggers then
        for _, info in pairs(db.taggers) do SendAddon("HELLO", info.name) end
    end
end

-- At max level PLAYER_XP_UPDATE never fires, so there's nothing to hang a report
-- on. Report the kill itself with a zero, so the carry can still see the link
-- working and count tags.
ReportTaggedKill = function()
    if not InTaggerMode() or not db.carry then return end
    if not AtMaxLevel() then return end   -- PLAYER_XP_UPDATE covers every other case
    SendAddon("XP:0", db.carry)
end

-- Tagger side: read the real gain off UnitXP and relay it.
local function ReportXPGain()
    local cur, max = UnitXP("player"), UnitXPMax("player")

    if lastXP then
        local gained
        if cur >= lastXP then
            gained = cur - lastXP
        else
            gained = (lastXPMax - lastXP) + cur   -- levelled during the gain
        end
        if gained > 0 and InTaggerMode() and db.carry then
            SendAddon("XP:" .. gained, db.carry)
        end
    end

    lastXP, lastXPMax = cur, max
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function OnNameplateAdded(unit)
    local guid = UnitGUID(unit)
    if not guid then return end
    plates[unit] = { guid = guid }
    guidToUnit[guid] = unit
    -- Only for mobs we're already tracking: caching level for every plate we ever
    -- see would grow unbounded, since the sweep only walks mobs with damage.
    if damage[guid] then CacheMobInfo(unit, guid) end
    -- The tag may have been recorded before this plate existed, so marking gets
    -- a second chance here.
    if tapOwner[guid] == "tagger" then SafeCall(MarkTaggedMob, guid) end
    UpdatePlate(unit)   -- mob may already have damage banked from outside plate range
end

local function OnNameplateRemoved(unit)
    local badge = GetBadge(unit, false)
    if badge then
        badge.check:Hide()
        badge.text:Hide()
        badge.deny:Hide()
    end

    local p = plates[unit]
    if p and p.guid and guidToUnit[p.guid] == unit then
        guidToUnit[p.guid] = nil
    end
    plates[unit] = nil
end

local function Sweep()
    local cutoff = GetTime() - STALE_SECONDS
    for guid, t in pairs(lastSeen) do
        if t < cutoff and not guidToUnit[guid] then
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

frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == ADDON_PREFIX then OnAddonMessage(arg2, arg4) end
    elseif event == "PLAYER_XP_UPDATE" then
        ReportXPGain()
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
        -- Strictly the tagger, by name. Auto-accepting anything else would hand
        -- any passing stranger a way into your group.
        if db.autoAccept and TaggerKeyOf(arg1) then
            AcceptGroup()
            StaticPopup_Hide("PARTY_INVITE")
            askedForInvite = false
            Print(format("accepted party invite from |cff00ff00%s|r.", arg1))
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        wipe(petOwner)   -- pet GUIDs don't survive a zone anyway
        ResetAll()
        RefreshContinent()
        playerGUID = UnitGUID("player")
        RebuildDynamicTaggers()
        -- Delayed: the chat system isn't ready to carry addon messages at login.
        C_Timer.After(5, GreetPartners)
    elseif event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        TagTeamDB = TagTeamDB or {}
        db = TagTeamDB
        if db.enabled     == nil then db.enabled     = true end
        if db.includePets == nil then db.includePets = true end
        if db.audio       == nil then db.audio       = true end
        if db.sound       == nil then db.sound       = true end
        if db.announce    == nil then db.announce    = true end
        if db.missAlert   == nil then db.missAlert   = true end
        if db.markers     == nil then db.markers     = true end
        if db.stealWarning == nil then db.stealWarning = true end
        if db.autoInvite   == nil then db.autoInvite   = true end
        if db.autoAccept   == nil then db.autoAccept   = true end
        if db.taggerMarker == nil then db.taggerMarker = true end
        if db.autoFocus    == nil then db.autoFocus    = HAS_FOCUS end
        if db.focusWarning == nil then db.focusWarning = true end
        if db.groupWarning == nil then db.groupWarning = true end
        if db.autoLeave    == nil then db.autoLeave    = true end
        -- Seeded once. Clearing it stays cleared; this won't re-add itself.
        if db.banlist == nil then
            db.banlist = { ["netherweb victim"] = "Netherweb Victim" }
        end
        if db.comms == nil then db.comms = true end
        if db.autoLoot == nil then db.autoLoot = true end
        db.badgePos = BADGE_ANCHORS[db.badgePos] and db.badgePos or "above"

        -- Rebind the runtime table onto the saved one: who has the addon is a
        -- stable fact about a character pair, and losing it on /reload silently
        -- dropped us back to visible "inv" whispers.
        db.linked = db.linked or {}
        linked = db.linked

        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(ADDON_PREFIX)
        end
        lastXP, lastXPMax = UnitXP("player"), UnitXPMax("player")
        db.threshold = db.threshold or THRESHOLD_DEFAULT
        db.soundId   = db.soundId or (SOUNDKIT and SOUNDKIT.LEVELUP) or 888
        db.missId    = db.missId or (SOUNDKIT and SOUNDKIT.IG_QUEST_FAILED) or 847
        if db.soundFile == nil then db.soundFile = DEFAULT_SOUND_FILE end
        if db.missFile  == nil then db.missFile  = DEFAULT_MISS_FILE end
        -- Saved settings pin the old default, so move anyone still on it.
        if db.missFile == LEGACY_MISS_FILE then db.missFile = DEFAULT_MISS_FILE end
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

        C_Timer.NewTicker(REFRESH_INTERVAL, UpdateAllPlates)
        C_Timer.NewTicker(SWEEP_INTERVAL, Sweep)
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
-- Slash commands
--------------------------------------------------------------------------------

local macroFrame

local function ShowMacroWindow(text)
    if not macroFrame then
        local f = CreateFrame("Frame", "TagTeamMacroFrame", UIParent,
            BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(400, 260)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        if f.SetBackdrop then
            f:SetBackdrop({
                bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 },
            })
        end

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -16)
        title:SetText("TagTeam follow macro - Ctrl+C to copy")

        local scroll = CreateFrame("ScrollFrame", "TagTeamMacroScroll", f,
            "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -40)
        scroll:SetPoint("BOTTOMRIGHT", -36, 44)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(320)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        close:SetSize(90, 22)
        close:SetPoint("BOTTOM", 0, 16)
        close:SetText("Close")
        close:SetScript("OnClick", function() f:Hide() end)

        macroFrame = f
    end

    macroFrame.edit:SetText(text)
    macroFrame.edit:HighlightText()
    macroFrame.edit:SetFocus()
    macroFrame:Show()
end

local function Status()
    if InTaggerMode() then
        Print(format("|cffffff00tagger mode|r - carry is |cff00ff00%s|r.", db.carry))
    end

    local names = TaggerNames()
    if #names == 0 then
        Print("|cffff8080no taggers set|r - |cffffff00/tag add <name>|r")
    else
        Print(format("combined damage from %d tagger%s must reach |cffffff00%d%%|r of max health:",
            #names, #names == 1 and "" or "s", db.threshold))
        for i = 1, #names do
            local info = TaggerInfo(NormalizeName(names[i]))
            Print(format("  |cff00ff00%s|r  level %s  %s  %s", names[i],
                (info and info.level) or "|cffff8080?|r",
                (info and info.marker) and MARKER_NAMES[info.marker]
                    or "|cffff8080no marker|r",
                (info and info.confirmed) and "|cff00ff00confirmed|r"
                    or "|cff808080unverified|r"))
        end
    end
    Print(format("XP base: %s | session: %d tags, ~%d XP",
        UsingOutlandBase() and "Outland" or "Azeroth",
        sessionTags, sessionXP))
    Print(format("pets: %s | announce: %s | markers: %s | steal warning: %s | enabled: %s",
        db.includePets and "on" or "off",
        db.announce and "on" or "off",
        db.markers and "on" or "off",
        db.stealWarning and "on" or "off",
        db.enabled and "on" or "off"))
    Print(format("auto-invite: %s | auto-accept: %s | marks: %s | focus: %s | grouped: %s",
        db.autoInvite and "on" or "off",
        db.autoAccept and "on" or "off",
        db.taggerMarker and "on" or "off",
        HAS_FOCUS and (db.autoFocus and "on" or "off") or "n/a",
        IsInGroup() and (GroupedWithTagger() and "|cffff2020with tagger|r" or "yes")
            or "no"))
    Print(format("auto-leave: %s | group warning: %s | focus reminder: %s",
        db.autoLeave and "on" or "off",
        db.groupWarning and "on" or "off",
        db.focusWarning and "on" or "off"))
    Print(format("badge position: |cffffff00%s|r the nameplate", db.badgePos))
    Print(format("audio: %s | tag cue: %s (%s)",
        db.audio and "|cff00ff00on|r" or "|cffff2020MUTED|r",
        db.sound and "on" or "off", db.soundFile or ("id " .. db.soundId)))
    Print(format("miss cue: %s (%s)",
        db.missAlert and "on" or "off", db.missFile or ("id " .. db.missId)))
end

-- Returns the new (file, id, enabled) triple for a cue.
local function ConfigureCue(label, rest, file, id, enabled)
    rest = rest and strtrim(rest) or ""

    local num = tonumber(rest)
    if num then
        -- false, not nil: nil would be re-defaulted to the bundled file on load.
        PlayCue(false, num)
        Print(format("%s sound set to id %d.", label, num))
        return false, num, enabled
    end

    if rest ~= "" then
        if PlaySoundFile(rest, SOUND_CHANNEL) then
            Print(format("%s sound set to %s", label, rest))
            return rest, id, enabled
        end
        Print("|cffff8080couldn't play|r " .. rest .. " |cffff8080- check the path.|r")
        return file, id, enabled
    end

    Print(format("%s sound %s", label, (not enabled) and "on." or "off."))
    return file, id, not enabled
end

local function HandleSlash(input)
    input = strtrim(input or "")
    local cmd, rest = strsplit(" ", input, 2)
    cmd = strlower(cmd or "")

    if cmd == "" or cmd == "status" then
        Status()
        Print("|cffffff00/tag add <name>|r  |cffffff00/tag remove <name>|r  |cffffff00/tag reset|r  |cffffff00/tag <number>|r threshold")
        Print("|cffffff00/tag carry <name>|r - run on a TAGGER's client: you and your party become the taggers")
        Print("|cffffff00/tag ban <mob>|r  |cffffff00/tag unban <mob>|r  |cffffff00/tag banlist|r - mobs to ignore entirely")
        Print("|cffffff00/tag link|r  |cffffff00/tag comms|r - addon-to-addon pairing and real XP reporting")
        Print("|cffffff00/tag macro|r - copyable target/follow/focus macro for your taggers")
        Print("|cffffff00/tag pos <above|below|left|right>|r - where the badge sits on the nameplate")
        Print("|cffffff00/tag audio|r|cffffff00/tag level <n>|r  |cffffff00/tag xp|r  |cffffff00/tag continent|r  |cffffff00/tag calibrate|r  |cffffff00/tag markers|r  |cffffff00/tag steal|r  |cffffff00/tag pets|r  |cffffff00/tag announce|r  |cffffff00/tag reset|r  |cffffff00/tag diag|r")
        Print("|cffffff00/tag sound|r |cffffff00/tag sound <id|path>|r |cffffff00/tag testsound|r - tag cue")
        Print("|cffffff00/tag miss|r |cffffff00/tag miss <id|path>|r |cffffff00/tag testmiss|r - miss cue")
        Print("|cffffff00/tag testkill|r - preview the tagged-kill checkmarks")
        Print("|cffffff00/tag inv|r - invite your taggers (or your carry) to the group now")
        Print("|cffffff00/tag autoinvite|r  |cffffff00/tag accept|r  |cffffff00/tag marks|r  |cffffff00/tag focus|r  |cffffff00/tag focuswarn|r - party handling")
        Print("|cffffff00/tag leave|r  |cffffff00/tag autoleave|r  |cffffff00/tag groupwarn|r  |cffffff00/tag loot|r - grouping")
        return
    end

    if cmd == "diag" then
        RefreshContinent()
        Print(format("map: %s | auto-detect: %s | XP base in use: %s%s|r",
            tostring(currentMapID),
            inOutland and "Outland" or "Azeroth",
            UsingOutlandBase() and "|cff00ff00Outland +235" or "|cffffff00Azeroth +45",
            db.continent and " (forced)" or ""))
        Print(format("lowest level: %s | range token: %s | in range: %s",
            LowestTaggerLevel() or "|cffff8080unknown|r",
            TaggerUnit() or "|cffff8080none|r",
            tostring(TaggerInRange())))
        local primary = PrimaryTaggerKey()
        Print(format("primary (triangle): %s | focus now: %s | tracking focus: %s",
            primary and db.taggers[primary].name or "|cffff8080none|r",
            UnitExists("focus") and UnitName("focus") or "|cffff8080empty|r",
            focusEverSet and "|cff00ff00yes|r" or "|cffff8080not yet|r"))
        Print(format("keybind button: %s | macro: %d chars",
            followButton and "|cff00ff00ready|r" or "|cffff8080not built|r",
            #(BuildFollowMacro() or "")))
        Print(format("in combat: %s | tag cue: %s | miss cue: %s | pooled marks: %d",
            InCombatLockdown() and "yes" or "no",
            db.sound and "|cff00ff00on|r" or "|cffff2020OFF|r",
            db.missAlert and "|cff00ff00on|r" or "|cffff2020OFF|r",
            #markPool))
        Print("last cosmetic error: " ..
            (lastCosmeticError and ("|cffff8080" .. lastCosmeticError .. "|r") or "none"))
        -- Cleared on read, so running it again tells you whether it recurred
        -- rather than showing the same stale error forever.
        lastCosmeticError = nil
        return
    end

    if cmd == "macro" then
        local text = BuildFollowMacro()
        ShowMacroWindow(text)
        Print("macro shown - Ctrl+C, then paste into a new macro (|cffffff00/macro|r).")
        if #text > 255 then
            Print(format("|cffff8080That's %d characters; WoW macros cap at 255.|r " ..
                "Drop a tagger or trim a line.", #text))
        end
        return
    end

    if cmd == "ban" or cmd == "unban" or cmd == "banlist" then
        local name = strtrim(rest or "")

        if cmd == "ban" and name ~= "" then
            db.banlist[strlower(name)] = name
            ResetAll(); UpdateAllPlates()
            Print(format("|cffff8080%s|r banned - ignored like a trivial minion.", name))
            return
        end

        if cmd == "unban" and name ~= "" then
            local key = strlower(name)
            if db.banlist[key] then
                local was = db.banlist[key]
                db.banlist[key] = nil
                ResetAll(); UpdateAllPlates()
                Print(format("|cff00ff00%s|r unbanned.", was))
            else
                Print(format("%s isn't banned.", name))
            end
            return
        end

        local list = {}
        for _, display in pairs(db.banlist) do list[#list + 1] = display end
        sort(list)
        if #list == 0 then
            Print("banlist is empty. |cffffff00/tag ban <mob name>|r")
        else
            Print(format("banned mobs (%d): |cffff8080%s|r",
                #list, table.concat(list, ", ")))
            Print("|cffffff00/tag ban <name>|r  |cffffff00/tag unban <name>|r")
        end
        return
    end

    if cmd == "carry" then
        local name = strtrim(rest or "")
        if strlower(name) == "off" or strlower(name) == "none" then
            db.carry, db.carryKey = nil, nil
            RebuildDynamicTaggers(); ResetAll(); UpdateAllPlates(); UpdateMacroButton()
            Print("carry cleared - back to |cffffff00carry mode|r (you do the killing).")
            return
        end
        if name == "" then
            Print(InTaggerMode()
                and format("your carry is |cff00ff00%s|r. |cffffff00/tag carry off|r to clear.", db.carry)
                or "|cffffff00/tag carry <name>|r - run this on the character being boosted.")
            return
        end

        -- Same rule in the other direction.
        if db.taggers and next(db.taggers) then
            StaticPopup_Show("TAGTEAM_MODE_SWITCH",
                format("|cff33ff99TagTeam|r\n\nYou're in |cffffff00carry mode|r with "
                    .. "|cff00ff00%s|r.\n\nSetting a carry switches you to tagger mode "
                    .. "and clears your tagger list.\n\nContinue?",
                    table.concat(TaggerNames(), ", ")),
                nil, { mode = "tagger", who = name })
            return
        end

        SetCarryTo(name)
        Print(format("carry set to |cff00ff00%s|r - |cffffff00tagger mode|r.", db.carry))
        Print(format("Taggers: you%s. Party automation is off in this mode.",
            IsInGroup() and " and your party" or ""))

        -- Offer them the inverse role; their client decides.
        SendAddon("PAIRT", db.carry)
        return
    end

    if cmd == "add" then
        local name = strtrim(rest or "")
        if name == "" then
            Print("|cffffff00/tag add <name>|r")
            return
        end
        -- Can't hold both roles. Confirm the switch rather than silently
        -- discarding a carry the user deliberately set.
        if InTaggerMode() then
            StaticPopup_Show("TAGTEAM_MODE_SWITCH",
                format("|cff33ff99TagTeam|r\n\nYou're in |cffffff00tagger mode|r with "
                    .. "|cff00ff00%s|r as your carry.\n\nAdding a tagger switches you to "
                    .. "carry mode and clears your carry.\n\nContinue?", db.carry),
                nil, { mode = "carry", who = name })
            return
        end

        local info = AddTagger(name)
        if not info then return end

        -- Offer them the inverse role; their client decides.
        SendAddon("PAIRC", info.name)

        if info.marker then
            Print(format("added |cff00ff00%s|r (%s). Taggers: %s",
                info.name, MARKER_NAMES[info.marker], table.concat(TaggerNames(), ", ")))
            Print("|cffffff00/tag macro|r for an updated target/follow/focus macro.")
        else
            Print(format("added |cff00ff00%s|r, but |cffff8080all three markers are taken|r.",
                info.name))
            Print("Drop one with |cffffff00/tag remove <name>|r to free a marker:")
            for _, n in ipairs(TaggerNames()) do
                local other = TaggerInfo(NormalizeName(n))
                if other and other.marker then
                    Print(format("  %s - %s", n, MARKER_NAMES[other.marker]))
                end
            end
        end
        return
    end

    if cmd == "remove" or cmd == "rem" or cmd == "del" then
        local key = TaggerKeyOf(strtrim(rest or ""))
        if not key then
            Print("|cffff8080Not a tagger.|r Current: " ..
                (#TaggerNames() > 0 and table.concat(TaggerNames(), ", ") or "none"))
            return
        end
        local was = db.taggers[key].name
        db.taggers[key] = nil
        ReassignMarkers()   -- free the slot and re-derive the rest
        ResetAll(); UpdateAllPlates(); UpdateMacroButton()
        Print(format("removed |cffff8080%s|r. Taggers: %s", was,
            #TaggerNames() > 0 and table.concat(TaggerNames(), ", ") or "none"))
        return
    end

    if cmd == "reset" or cmd == "off" or cmd == "none" then
        -- Clears both roles: reset means "no relationships", not "no taggers".
        wipe(db.taggers)
        db.carry, db.carryKey = nil, nil
        RebuildDynamicTaggers()
        ResetAll(); UpdateAllPlates(); UpdateMacroButton()
        Print("cleared - no taggers, no carry.")
        return
    end

    if cmd == "level" then
        -- "/tag level 24" works when there's only one tagger; name it otherwise.
        local who, num = strsplit(" ", strtrim(rest or ""), 2)
        local lvl = tonumber(num) or tonumber(who)
        local key = TaggerKeyOf(who)

        if not key then
            local names = TaggerNames()
            if #names == 1 then key = NormalizeName(names[1]) end
        end

        local info = key and TaggerInfo(key)
        if info and lvl and lvl >= 1 and lvl <= 70 then
            -- Party members read their real level from the unit, so a manual
            -- override there would be overwritten on the next roster update.
            if db.taggers[key] then
                info.level = lvl
                Print(format("%s set to level |cffffff00%d|r.", info.name, lvl))
            else
                Print(format("%s is in your party - their level reads live and can't be overridden.",
                    info.name))
            end
        else
            Print("|cffffff00/tag level <name> <n>|r - levels auto-sample when you see them.")
            for _, n in ipairs(TaggerNames()) do
                local info = TaggerInfo(NormalizeName(n))
                Print(format("  %s: %s", n, (info and info.level) or "|cffff8080unknown|r"))
            end
        end
        return
    end

    if cmd == "continent" then
        local mode = strlower(strtrim(rest or ""))
        if mode == "outland" or mode == "azeroth" then
            db.continent = mode
        elseif mode == "auto" then
            db.continent = nil
        else
            Print("|cffffff00/tag continent auto|outland|azeroth|r - forces the XP base constant.")
        end
        RefreshContinent()
        Print(format("XP base: |cffffff00%s|r (%s) | auto-detect says %s, map %s",
            UsingOutlandBase() and "Outland +235" or "Azeroth +45",
            db.continent and "forced" or "auto",
            inOutland and "Outland" or "Azeroth",
            tostring(currentMapID)))
        return
    end

    if cmd == "xp" then
        Print(format("this session: |cffffff00%d|r tags, ~|cffffff00%s|r XP estimated.",
            sessionTags,
            BreakUpLargeNumbers and BreakUpLargeNumbers(sessionXP) or tostring(sessionXP)))
        if reportedKills > 0 then
            Print(format("|cff00ff00%d|r kills reported by linked taggers, |cff00ff00%s|r XP actual%s.",
                reportedKills,
                BreakUpLargeNumbers and BreakUpLargeNumbers(reportedXP) or tostring(reportedXP),
                saidMaxLevel and " |cff808080(tagger at max level)|r" or ""))
        else
            Print("|cff808080Estimate only: doubles if they're rested, splits if grouped.|r")
        end
        return
    end

    if cmd == "comms" then
        db.comms = not db.comms
        Print("addon comms " .. (db.comms and "on." or "off."))
        return
    end


    if cmd == "link" then
        local target = InTaggerMode() and db.carry or (TaggerNames()[1])
        if not target then
            Print("|cffff8080Nothing to link to|r - set a carry or add a tagger first.")
            return
        end
        SendAddon(InTaggerMode() and "PAIRT" or "PAIRC", target)
        Print(format("pairing request sent to |cff00ff00%s|r.", target))
        return
    end

    if cmd == "calibrate" then
        rest = rest and strtrim(rest) or ""
        if strlower(rest) == "reset" then
            db.xpScale = nil
            Print("XP scale reset to 1.000.")
            return
        end

        local actual = tonumber(rest)
        if not actual or actual <= 0 then
            Print("|cffffff00/tag calibrate <actual XP>|r - after a tagged kill, tell it what they really got.")
            Print(format("scale: |cffffff00%.3f|r | last estimate: |cffffff00%s|r (%s)",
                db.xpScale or 1, lastRawXP or "-", lastXPInfo or "none yet"))
            return
        end

        if not lastRawXP then
            Print("|cffff8080No estimated kill yet - tag and kill something first.|r")
            return
        end

        db.xpScale = actual / lastRawXP
        Print(format("scale set to |cffffff00%.3f|r (%d actual vs %d predicted; %s).",
            db.xpScale, actual, lastRawXP, lastXPInfo))
        Print("|cff808080Check their level is current first - a stale level looks exactly like a bad formula.|r")
        return
    end

    if cmd == "leave" then
        if not IsInGroup() and not IsInRaid() then
            Print("not in a group.")
        else
            Print("leaving the party.")
            LeaveTaggerParty()
        end
        return
    end

    if cmd == "loot" then
        db.autoLoot = not db.autoLoot
        Print("free-for-all loot in a two-person tag group: " ..
            (db.autoLoot and "on." or "off."))
        if db.autoLoot then CheckLootMethod() end
        return
    end

    if cmd == "autoleave" then
        db.autoLeave = not db.autoLeave
        Print("auto-leave the tagger's party when back in range: " ..
            (db.autoLeave and "on." or "off."))
        return
    end

    if cmd == "groupwarn" then
        db.groupWarning = not db.groupWarning
        Print("grouped-in-combat warning " .. (db.groupWarning and "on." or "off."))
        return
    end

    if cmd == "focuswarn" then
        db.focusWarning = not db.focusWarning
        Print("no-focus reminder " .. (db.focusWarning and "on." or "off."))
        return
    end

    if cmd == "pos" or cmd == "position" then
        local mode = strlower(strtrim(rest or ""))
        if not BADGE_ANCHORS[mode] then
            Print(format("badge position: |cffffff00%s|r", db.badgePos))
            Print("|cffffff00/tag pos above|below|left|right|r")
            return
        end
        db.badgePos = mode
        UpdateAllPlates()   -- GetBadge re-anchors each plate as it comes through
        Print(format("badge moved |cffffff00%s|r the nameplate.", mode))
        return
    end

    if cmd == "audio" or cmd == "mute" then
        db.audio = not db.audio
        if db.audio then
            Print("audio |cff00ff00on|r - tag and miss cues will play.")
        else
            Print("audio |cffff2020off|r - all cues silenced, visuals unaffected.")
        end
        return
    end

    if cmd == "autoinvite" then
        db.autoInvite = not db.autoInvite
        Print(format("ask for an invite when out of range: %s",
            db.autoInvite and "on." or "off."))
        return
    end

    if cmd == "inv" or cmd == "invite" then
        -- Who the other side of the pair is depends on which mode we're in.
        local targets = {}
        if InTaggerMode() then
            if db.carry then targets[1] = db.carry end
        else
            for _, n in ipairs(TaggerNames()) do targets[#targets + 1] = n end
        end

        if #targets == 0 then
            Print("|cffff8080Nobody to invite|r - add a tagger or set a carry first.")
            return
        end

        -- Skip anyone already here; re-inviting a party member is just an error.
        local present = {}
        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                present[NormalizeName(UnitName("raid" .. i)) or ""] = true
            end
        elseif IsInGroup() then
            for i = 1, 4 do
                local u = "party" .. i
                if UnitExists(u) then present[NormalizeName(UnitName(u)) or ""] = true end
            end
        end

        local sent = {}
        for i = 1, #targets do
            if not present[NormalizeName(targets[i])] then
                InviteToParty(targets[i])
                sent[#sent + 1] = targets[i]
            end
        end

        if #sent == 0 then
            Print("everyone's already in the group.")
        else
            Print(format("invited |cff00ff00%s|r.", table.concat(sent, ", ")))
        end
        return
    end

    if cmd == "accept" then
        db.autoAccept = not db.autoAccept
        Print("auto-accept invites from the tagger " .. (db.autoAccept and "on." or "off."))
        return
    end

    if cmd == "triangle" or cmd == "marks" then
        db.taggerMarker = not db.taggerMarker
        Print("markers on taggers while ungrouped " ..
            (db.taggerMarker and "on." or "off."))
        return
    end

    if cmd == "focus" then
        if not HAS_FOCUS then
            Print("|cffff8080This client has no focus unit|r - out-of-range falls back to a timer.")
            return
        end
        db.autoFocus = not db.autoFocus
        focusEverSet = false
        Print("use focus for range detection: " .. (db.autoFocus and "on." or "off."))
        Print("|cff808080Setting focus is protected. Bind a key under Key Bindings > TagTeam, or use /tag macro.|r")
        return
    end

    if cmd == "markers" then
        db.markers = not db.markers
        Print("raid markers on their tags " .. (db.markers and "on." or "off."))
        return
    end

    if cmd == "steal" then
        db.stealWarning = not db.stealWarning
        Print("tag-steal warning " .. (db.stealWarning and "on." or "off."))
        return
    end

    if cmd == "pets" then
        db.includePets = not db.includePets
        Print("pet damage " .. (db.includePets and "counted." or "ignored."))
        return
    end

    if cmd == "announce" then
        db.announce = not db.announce
        Print("chat announcements " .. (db.announce and "on." or "off."))
        return
    end

    if cmd == "testsound" then
        PlayAlertSound()
        Print("played " .. (db.soundFile or ("sound id " .. db.soundId)) .. ".")
        return
    end

    if cmd == "testmiss" or cmd == "testkill" then
        local miss = (cmd == "testmiss")
        if miss then
            Print("miss preview: " .. (db.missFile or ("sound id " .. db.missId)))
            PlayMissSound()
        else
            Print("tagged-kill preview.")
        end
        if miss then
            SafeCall(SpawnBurst, X_TEXTURE, format("%d%%", db.threshold * 0.6), 1, 0.35, 0.35)
        else
            SafeCall(SpawnBurst, CHECK_TEXTURE, "+142 XP", 1, 0.86, 0.3)
        end
        return
    end

    -- Both cues configure identically: a bare command toggles, a number sets a
    -- SOUNDKIT id, anything else is treated as a file path.
    if cmd == "sound" then
        db.soundFile, db.soundId, db.sound =
            ConfigureCue("tag", rest, db.soundFile, db.soundId, db.sound)
        return
    end

    if cmd == "miss" then
        db.missFile, db.missId, db.missAlert =
            ConfigureCue("miss", rest, db.missFile, db.missId, db.missAlert)
        return
    end

    if cmd == "reset" then
        ResetAll(); UpdateAllPlates(); UpdateMacroButton()
        Print("cleared tracked damage.")
        return
    end

    local pct = tonumber(cmd)
    if pct and pct > 0 and pct <= 100 then
        db.threshold = pct
        wipe(alerted)
        UpdateAllPlates()
        Print(format("threshold set to %d%% of max health.", pct))
        return
    end

    -- Deliberately does NOT fall through to "add": a typo'd subcommand used to
    -- silently create a tagger named after the typo.
    Print(format("|cffff8080Unknown command:|r %s", input))
    Print("Use |cffffff00/tag add <name>|r to add a tagger, or |cffffff00/tag|r for the full list.")
end

SLASH_TAGTEAM1 = "/tag"
SLASH_TAGTEAM2 = "/tagteam"
SlashCmdList["TAGTEAM"] = HandleSlash
