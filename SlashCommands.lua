local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Slash commands
--
-- Everything /tag does, and nothing else does. This file is a leaf: it reads
-- from the core, the core never reads from it, and the whole boundary between
-- them is the export block at the bottom of TagTeam.lua. It also reads
-- ns.ToggleView from the other leaf, TagTeamView.lua, which is why that one
-- loads first.
--
-- It is a separate file because the main chunk of a Lua file is itself a
-- function, and Lua 5.1 allows only 200 locals per function - the core had
-- reached 197. Splitting gives this half its own budget.
--
-- Splitting does NOT relieve the other ceiling, 60 upvalues per function: that
-- is counted per function wherever the function lives, and HandleSlash sat on
-- it because a 575-line if/elseif chain charges every name any branch touches
-- to one enclosing function. The command table below is what fixed that.
--------------------------------------------------------------------------------

local C, state = ns.C, ns.state

-- Re-localized once, at load. These are functions, and a function never changes
-- identity, so caching them here is safe. `db` is the exception - it does not
-- exist until ADDON_LOADED, which is after this file has finished loading - so
-- it is read from ns per dispatch instead. See HandleSlash.
local Print                     = ns.Print
local SafeCall                  = ns.SafeCall
local NormalizeName             = ns.NormalizeName
local InTaggerMode              = ns.InTaggerMode
local TaggerNames               = ns.TaggerNames
local TaggerInfo                = ns.TaggerInfo
local TaggerKeyOf               = ns.TaggerKeyOf
local InviteTarget              = ns.InviteTarget
local PrimaryTaggerKey          = ns.PrimaryTaggerKey
local RebuildDynamicTaggers     = ns.RebuildDynamicTaggers
local ResetAll                  = ns.ResetAll
local UpdateAllPlates           = ns.UpdateAllPlates
local UpdateMacroButton         = ns.UpdateMacroButton
local BuildFollowMacro          = ns.BuildFollowMacro
local RefreshContinent          = ns.RefreshContinent
local MapDiag                   = ns.MapDiag
local UsingOutlandBase          = ns.UsingOutlandBase
local LowestTaggerLevel         = ns.LowestTaggerLevel
local TaggerUnit                = ns.TaggerUnit
local TaggerInRange             = ns.TaggerInRange
local GroupedWithTagger         = ns.GroupedWithTagger
local Suspended                 = ns.Suspended
local MultiplierText            = ns.MultiplierText
local CheckLootMethod           = ns.CheckLootMethod
local AskForInvite              = ns.AskForInvite
local SendAddon                 = ns.SendAddon
local Roster                    = ns.Roster
-- The two names here that come from TagTeamView.lua rather than the core, which
-- is why that file loads before this one.
local ToggleView                = ns.ToggleView
local ShowPairPrompt            = ns.ShowPairPrompt

local db            -- refreshed from ns.db on every dispatch
-- Kept deliberately though nothing calls it: /tag macro is gone and the macro
-- itself may want a window again. BuildFollowMacro still builds the text.
local macroFrame    -- the copyable-macro window, built on first use

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
        Print(format("|cffffff00tagger mode|r - carry is |cff00ff00%s|r%s.", db.carry,
            db.carryPet and format(" with pet |cff00ff00%s|r", db.carryPet) or ""))
    end

    local names = TaggerNames()
    if #names == 0 then
        Print("|cffff8080no taggers set|r - |cffffff00/tag add <name>|r")
    else
        Print(format("combined damage from %d tagger%s must reach |cffffff00%.1f%%|r of max health:",
            #names, #names == 1 and "" or "s", db.threshold))
        for i = 1, #names do
            local info = TaggerInfo(NormalizeName(names[i]))
            Print(format("  |cff00ff00%s|r  level %s  %s  %s%s", names[i],
                (info and info.level) or "|cffff8080?|r",
                (info and info.marker) and C.MARKER_NAMES[info.marker]
                    or "|cffff8080no marker|r",
                (info and info.confirmed) and "|cff00ff00confirmed|r"
                    or "|cff808080unverified|r",
                (info and info.pet) and format("  pet |cff00ff00%s|r", info.pet) or ""))
        end
    end
    -- Once any report has arrived, the confirmed total replaces the estimate
    -- rather than sitting beside it. Two totals for one session invites reading
    -- the wrong one, and the estimate is the wrong one.
    Print(format("XP base: %s | session: %d tags, %s",
        UsingOutlandBase() and "Outland" or "Azeroth",
        state.sessionTags,
        state.reportedKills > 0
            and format("|cff00ff00%d|r XP confirmed", state.reportedXP)
            or format("~%d XP estimated", state.sessionXP)))
    Print(format("pvp mobs: %s | kill line: %s | quest progress: %s | steal warning: %s",
        db.ignorePvP and "ignored" or "tracked",
        db.announce and "on" or "off",
        db.questProgress and "on" or "off",
        db.stealWarning and "on" or "off"))
    -- Loud, because a suspended addon looks exactly like a broken one.
    if Suspended() then
        Print("|cffff8080SUSPENDED|r - dungeon or raid. The Ignore tab on "
            .. "|cffffff00/tag ui|r has the switch to run here anyway.")
    end
    Print(format("auto-invite: %s | marks: %s | focus: %s | grouped: %s",
        db.autoInvite and "on" or "off",
        db.taggerMarker and "on" or "off",
        C.HAS_FOCUS and (db.autoFocus and "on" or "off") or "n/a",
        IsInGroup() and (GroupedWithTagger() and "|cffff2020with tagger|r" or "yes")
            or "no"))
    Print(format("auto-leave: %s | group warning: %s | focus reminder: %s",
        db.autoLeave and "on" or "off",
        db.groupWarning and "on" or "off",
        db.focusWarning and "on" or "off"))
    Print(format("badge position: |cffffff00%s|r the nameplate", db.badgePos))
    -- Per-cue settings are not listed. There are seven of them now and they live
    -- on the window's Audio tab; a status line that reprints all seven every
    -- time you type /tag is worse than a pointer to where they are.
    Print(format("sound: %s | miss notice: %s",
        db.audio and "|cff00ff00on|r" or "|cffff2020MUTED|r",
        db.missAlert and "on" or "off"))
end


-- Commands, one function each.
--
-- This was a 575-line if/elseif chain, which is how it came to sit on Lua
-- 5.1's 60-upvalue-per-function ceiling: every name any branch reached for
-- was charged to the single enclosing function. A table gives each handler
-- its own budget of five or six, and the ceiling stops being something to
-- design around. Aliases are assignments rather than extra `or` arms.
--
-- Handlers take (rest, cmd): `rest` is everything after the command word,
-- and the three handlers that serve more than one name need to know which.
local commands = {}

commands[""] = function(rest, cmd)
    Status()
    Print("|cffffff00/tag ui|r - everything below, and every setting that no longer has a command")
    Print("|cffffff00/tag add <name>|r  |cffffff00/tag remove <name>|r  |cffffff00/tag reset|r")
    Print("|cffffff00/tag carry <name>|r - run on a TAGGER's client: you and your party become the taggers")
    Print("|cffffff00/tag link|r - pair with the other client over the addon channel")
    Print("|cffffff00/tag sound|r (|cffffff00/tag audio|r) - master mute. Which cues play is on the window's Audio tab.")
    Print("|cffffff00/tag stats|r  |cffffff00/tag steal|r  |cffffff00/tag reset|r  |cffffff00/tag diag|r")
    Print("|cffffff00/tag inv|r - ask your tagger (or your carry) to invite you now")
    Print("|cffffff00/tag autoinvite|r  |cffffff00/tag marks|r  |cffffff00/tag focus|r  |cffffff00/tag focuswarn|r - party handling")
    Print("|cffffff00/tag autoleave|r  |cffffff00/tag groupwarn|r  |cffffff00/tag loot|r - grouping")
end
commands["status"] = commands[""]

-- Deliberately absent from the help text above while the window is still empty:
-- pointing people at it would only be an invitation to be disappointed.
commands["ui"] = function(rest, cmd)
    ToggleView()
end
commands["window"] = commands["ui"]

-- /tag pair <name> - the window's add prompt, with the name filled in and the
-- role still open. It deliberately does NOT decide anything itself: naming
-- somebody is not the same as saying what they are to you, and getting that
-- backwards is what the two roles exist to prevent.
--
-- Also absent from the help text while the window is empty; see above.
commands["pair"] = function(rest, cmd)
    local name = strtrim(rest or "")
    if name == "" then
        Print("|cffffff00/tag pair <name>|r - pick what they are from the list.")
        return
    end
    ShowPairPrompt(name)
end

commands["diag"] = function(rest, cmd)
    RefreshContinent()
    Print(format("map: %s | auto-detect: %s | XP base in use: %s%s|r",
        MapDiag(),
        state.inOutland and "Outland" or "Azeroth",
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
        state.focusEverSet and "|cff00ff00yes|r" or "|cffff8080not yet|r"))
    Print(format("keybind button: %s | macro: %d chars",
        state.followButton and "|cff00ff00ready|r" or "|cffff8080not built|r",
        #(BuildFollowMacro() or "")))
    Print(format("in combat: %s | tag cue: %s | miss cue: %s | pooled marks: %d",
        InCombatLockdown() and "yes" or "no",
        db.sound and "|cff00ff00on|r" or "|cffff2020OFF|r",
        db.missAlert and "|cff00ff00on|r" or "|cffff2020OFF|r",
        #state.markPool))
    Print("last cosmetic error: " ..
        (state.lastCosmeticError and ("|cffff8080" .. state.lastCosmeticError .. "|r") or "none"))
    -- Cleared on read, so running it again tells you whether it recurred
    -- rather than showing the same stale error forever.
    state.lastCosmeticError = nil
end

commands["carry"] = function(rest, cmd)
    local name = strtrim(rest or "")
    if strlower(name) == "off" or strlower(name) == "none" then
        db.carry, db.carryKey, db.carryPet, db.carryPetKey = nil, nil, nil, nil
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

    -- Same rule in the other direction. The guard itself lives in the core, so
    -- the window cannot enforce a different one - it raises the same popup and
    -- that popup does the reporting from there.
    if Roster.RequestCarry(name) == "switch" then return end

    Print(format("carry set to |cff00ff00%s|r - |cffffff00tagger mode|r.", db.carry))
    Print(format("Taggers: you%s. Party automation is off in this mode.",
        IsInGroup() and " and your party" or ""))

    -- Offer them the inverse role; their client decides.
    SendAddon("PAIRT", db.carry)
end

commands["add"] = function(rest, cmd)
    local name = strtrim(rest or "")
    if name == "" then
        Print("|cffffff00/tag add <name>|r")
        return
    end
    -- Can't hold both roles. Confirm the switch rather than silently
    -- discarding a carry the user deliberately set. The guard is the core's,
    -- shared with the window; "switch" means the popup has it from here.
    local outcome, info = Roster.RequestTagger(name)
    if outcome == "switch" or not info then return end

    -- Offer them the inverse role; their client decides.
    SendAddon("PAIRC", info.name)

    if info.marker then
        Print(format("added |cff00ff00%s|r (%s). Taggers: %s",
            info.name, C.MARKER_NAMES[info.marker], table.concat(TaggerNames(), ", ")))
    else
        Print(format("added |cff00ff00%s|r, but |cffff8080all three markers are taken|r.",
            info.name))
        Print("Drop one with |cffffff00/tag remove <name>|r to free a marker:")
        for _, n in ipairs(TaggerNames()) do
            local other = TaggerInfo(NormalizeName(n))
            if other and other.marker then
                Print(format("  %s - %s", n, C.MARKER_NAMES[other.marker]))
            end
        end
    end
end

commands["remove"] = function(rest, cmd)
    local key = TaggerKeyOf(strtrim(rest or ""))
    if not key then
        Print("|cffff8080Not a tagger.|r Current: " ..
            (#TaggerNames() > 0 and table.concat(TaggerNames(), ", ") or "none"))
        return
    end
    -- Frees the marker and re-derives the rest. In the core because the window
    -- removes taggers too, and both had better do the same four things.
    local was = Roster.RemoveTagger(key)
    -- TaggerKeyOf also matches the party-derived taggers of tagger mode, and
    -- those are not a list anyone can edit - they are rebuilt from the roster
    -- on every change. Say so rather than reporting a removal that did nothing.
    if not was then
        Print("|cffff8080That tagger comes from your party in tagger mode.|r " ..
            "Leave the group, or |cffffff00/tag carry off|r.")
        return
    end
    Print(format("removed |cffff8080%s|r. Taggers: %s", was,
        #TaggerNames() > 0 and table.concat(TaggerNames(), ", ") or "none"))
end
commands["rem"], commands["del"] = commands["remove"], commands["remove"]

commands["reset"] = function(rest, cmd)
    -- Clears both roles: reset means "no relationships", not "no taggers".
    wipe(db.taggers)
    db.carry, db.carryKey, db.carryPet, db.carryPetKey = nil, nil, nil, nil
    RebuildDynamicTaggers()
    ResetAll(); UpdateAllPlates(); UpdateMacroButton()
    Print("cleared - no taggers, no carry.")
end
commands["clear"], commands["off"], commands["none"] = commands["reset"], commands["reset"], commands["reset"]
commands["stats"] = function(rest, cmd)
    local Big = function(n)
        return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
    end

    -- The estimate is not printed at all once reports are arriving. A linked
    -- tagger's number is authoritative, and showing a guess beside it only
    -- invites reading the guess. The pairing line below still contrasts the two,
    -- which is a different job: that one is how you catch a stale level.
    if state.reportedKills > 0 then
        Print(format("this session: |cffffff00%d|r tags, |cff00ff00%s|r XP "
            .. "|cff00ff00confirmed|r over |cff00ff00%d|r reported kills%s.",
            state.sessionTags, Big(state.reportedXP), state.reportedKills,
            state.saidMaxLevel and " |cff808080(tagger at max level)|r" or ""))
        if state.matchedEst > 0 then
            Print(format("paired against estimates: |cffffff00%s|r expected, "
                .. "|cffffff00%s|r actual, %s overall.",
                Big(state.matchedEst), Big(state.matchedXP),
                MultiplierText(state.matchedXP / state.matchedEst)))
        end
    else
        Print(format("this session: |cffffff00%d|r tags, ~|cffffff00%s|r XP estimated.",
            state.sessionTags, Big(state.sessionXP)))
        Print("|cff808080Estimate only: doubles if they're rested, splits if grouped.|r")
    end
    -- Their own XP, earned away from the tag. Listed apart from everything above
    -- rather than folded into it: it inflates no multiplier and tags no mob.
    if state.offTagXP > 0 then
        Print(format("|cff808080plus|r |cffffff00%s|r |cff808080XP of their own, from quests and discoveries.|r",
            Big(state.offTagXP)))
    end
    -- Rested, as last reported. It drains as they kill and only crossings are
    -- pushed, so this is "as of their last report", not live to the second.
    for key, pct in pairs(state.taggerRested) do
        if pct and pct > 0 then
            local info = db.taggers[key]
            Print(format("|cff66ccff%s|r had |cff66ccff%.1f%%|r of a level rested - "
                .. "their kill estimates are doubled.", (info and info.name) or key, pct))
        end
    end
end

commands["link"] = function(rest, cmd)
    local target = InTaggerMode() and db.carry or (TaggerNames()[1])
    if not target then
        Print("|cffff8080Nothing to link to|r - set a carry or add a tagger first.")
        return
    end
    SendAddon(InTaggerMode() and "PAIRT" or "PAIRC", target)
    Print(format("pairing request sent to |cff00ff00%s|r.", target))
end

commands["loot"] = function(rest, cmd)
    db.autoLoot = not db.autoLoot
    Print("free-for-all loot in a two-person tag group: " ..
        (db.autoLoot and "on." or "off."))
    if db.autoLoot then CheckLootMethod() end
end

commands["autoleave"] = function(rest, cmd)
    db.autoLeave = not db.autoLeave
    Print("auto-leave the tagger's party when back in range: " ..
        (db.autoLeave and "on." or "off."))
end

commands["groupwarn"] = function(rest, cmd)
    db.groupWarning = not db.groupWarning
    Print("grouped-in-combat warning " .. (db.groupWarning and "on." or "off."))
end

commands["focuswarn"] = function(rest, cmd)
    db.focusWarning = not db.focusWarning
    Print("no-focus reminder " .. (db.focusWarning and "on." or "off."))
end
-- The master switch, and the only sound command left. The seven individual cues
-- - which one plays, and what each is set to - are the Audio tab's job now;
-- there were five commands for it and nobody could hold them in their head.
commands["sound"] = function(rest, cmd)
    db.audio = not db.audio
    if db.audio then
        Print("sound |cff00ff00on|r - per-cue settings are on the window's Audio tab.")
    else
        Print("sound |cffff2020off|r - every cue silenced, visuals unaffected.")
    end
end
commands["audio"], commands["mute"] = commands["sound"], commands["sound"]
commands["autoinvite"] = function(rest, cmd)
    db.autoInvite = not db.autoInvite
    Print(format("ask for an invite when out of range: %s",
        db.autoInvite and "on." or "off."))
end

commands["inv"] = function(rest, cmd)
    -- Asks THEM to invite US, which is the same exchange the automatic
    -- out-of-range path runs - this is just the manual trigger for it.
    --
    -- One target, never the whole tagger list: several taggers would mean
    -- several party invites arriving at once and only one of them could ever
    -- be accepted, leaving the rest as stale popups.
    -- Typed by hand, so it falls back to the primary tagger where the automatic
    -- out-of-range path deliberately would not - see InviteTarget.
    local target = InTaggerMode() and db.carry or InviteTarget(true)

    if not target then
        Print("|cffff8080Nobody to ask|r - add a tagger or set a carry first.")
        return
    end

    local key = NormalizeName(target)
    local present = false
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            if NormalizeName(UnitName("raid" .. i)) == key then present = true end
        end
    elseif IsInGroup() then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and NormalizeName(UnitName(u)) == key then
                present = true
            end
        end
    end
    if present then
        Print(format("|cff00ff00%s|r is already in your group.", target))
        return
    end

    -- No cooldown CHECK - this one was typed, so it happens. AskForInvite
    -- still claims the cooldown, so the ticker can't ask again a second later.
    AskForInvite(target)
end
commands["invite"] = commands["inv"]

commands["triangle"] = function(rest, cmd)
    db.taggerMarker = not db.taggerMarker
    Print("markers on taggers while ungrouped " ..
        (db.taggerMarker and "on." or "off."))
end
commands["marks"] = commands["triangle"]

commands["focus"] = function(rest, cmd)
    if not C.HAS_FOCUS then
        Print("|cffff8080This client has no focus unit|r - out-of-range falls back to a timer.")
        return
    end
    db.autoFocus = not db.autoFocus
    state.focusEverSet = false
    Print("use focus for range detection: " .. (db.autoFocus and "on." or "off."))
    Print("|cff808080Setting focus is protected. Bind a key under Key Bindings > TagTeam.|r")
end

commands["steal"] = function(rest, cmd)
    db.stealWarning = not db.stealWarning
    Print("tag-steal warning " .. (db.stealWarning and "on." or "off."))
end

local function HandleSlash(input)
    -- The core assigns this in ADDON_LOADED, after this file has loaded, so
    -- it is read per dispatch rather than captured at load time.
    db = ns.db

    input = strtrim(input or "")
    local cmd, rest = strsplit(" ", input, 2)
    cmd = strlower(cmd or "")

    local handler = commands[cmd]
    if handler then return handler(rest, cmd) end

    -- Deliberately does NOT fall through to "add": a typo'd subcommand used to
    -- silently create a tagger named after the typo.
    Print(format("|cffff8080Unknown command:|r %s", input))
    Print("Use |cffffff00/tag add <name>|r to add a tagger, or |cffffff00/tag|r for the full list.")
end

SLASH_TAGTEAM1 = "/tag"
SLASH_TAGTEAM2 = "/tagteam"
SlashCmdList["TAGTEAM"] = HandleSlash
