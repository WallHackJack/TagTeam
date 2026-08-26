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

local state = ns.state

-- Re-localized once, at load. These are functions, and a function never changes
-- identity, so caching them here is safe. `db` is the exception - it does not
-- exist until ADDON_LOADED, which is after this file has finished loading - so
-- it is read from ns per dispatch instead. See HandleSlash.
local UI                        = ns.UI
local Print                     = ns.Print
local PrintRaw                  = ns.PrintRaw
local SafeCall                  = ns.SafeCall
local NormalizeName             = ns.NormalizeName
local InTaggerMode              = ns.InTaggerMode
local TaggerNames               = ns.TaggerNames
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
local Suspended                 = ns.Suspended
local MultiplierText            = ns.MultiplierText
local AskForInvite              = ns.AskForInvite
local InviteToParty             = ns.InviteToParty
local AmGroupLeader             = ns.AmGroupLeader
local Roster                    = ns.Roster
-- The two names here that come from TagTeamView.lua rather than the core, which
-- is why that file loads before this one.
local ToggleView                = ns.ToggleView
local ShowPairPrompt            = ns.ShowPairPrompt

local db            -- refreshed from ns.db on every dispatch

-- The tail of the menu block, so these are unstamped and indented like the
-- lines above them. Nothing else calls it.
local function Status()
    if InTaggerMode() then
        PrintRaw(format("  |cffffff00tagger mode|r - carry is |cff00ff00%s|r%s.", db.carry,
            db.carryPet and format(" with pet |cff00ff00%s|r", db.carryPet) or ""))
    end

    -- Who the taggers are, what level each is and which marker each carries is
    -- the window's job, and it does it in a form chat cannot: colour, columns,
    -- and no scrollback burying it. What is left here is the part chat is still
    -- better at - the one-line answer to "is this thing on".
    if #TaggerNames() == 0 then
        PrintRaw("  |cffff8080no taggers set|r - |cffffff00/tag pair <name>|r")
    end

    -- Loud, because a suspended addon looks exactly like a broken one.
    if Suspended() then
        PrintRaw("  |cffff8080SUSPENDED|r - dungeon or raid. The Ignore tab on "
            .. "|cffffff00/tag ui|r has the switch to run here anyway.")
    end
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

-- Declared before the bare-word handler, which calls it: the menu is defined
-- below because that is where it reads best, and a local named later would be
-- nil at the point the closure looks it up.
local Menu

-- The bare word opens the window, and prints the menu too when the Chat option
-- asks for it. The menu on its own is what every OTHER input lands on, typo or
-- not.
commands[""] = function(rest, cmd)
    if ToggleView() and db.slashHelp then Menu() end
end

-- One block: a header that says whose it is, and no name stamped on any line
-- under it. /tag stats and /tag diag are deliberately absent - they still work,
-- they are just not what somebody who typed /tag was asking about.
function Menu()
    PrintRaw(format("|cff33ff99TagTeam|r%s |cffffff00Options:|r",
        (UI and UI.VERSION) and format(" |cff808080(v%s)|r", UI.VERSION) or ""))
    PrintRaw("  |cffffff00/tag inv|r - Asks your active partner for an immediate invite")
    PrintRaw("  |cffffff00/tag pair <name>|r (or |cffffff00add|r) - Add a partner to TagTeam")
    PrintRaw("  |cffffff00/tag remove <name>|r - Takes that name off every list it is on")
    PrintRaw("  |cffffff00/tag reset|r (or |cffffff00clear|r) - Removes all taggers and carries")
    PrintRaw(format("  |cffffff00/tag sound|r (or |cffffff00audio|r) - Toggle TagTeam's audio, "
        .. "currently %s", db.audio and "|cff00ff00ON|r" or "|cffff2020OFF|r"))
    Status()
end
commands["status"] = Menu
commands["help"] = Menu

commands["ui"] = function(rest, cmd)
    ToggleView()
end
commands["window"] = commands["ui"]

-- /tag pair <name> - the window's add prompt, with the name filled in and the
-- role still open. It deliberately does NOT decide anything itself: naming
-- somebody is not the same as saying what they are to you, and getting that
-- backwards is what the two roles exist to prevent.
--
-- /tag add is the same command now. The old one made a tagger out of whatever
-- you typed, without asking - which is exactly the guess this one refuses to
-- make - so the word people already have in their fingers lands on the prompt
-- instead of quietly picking a side for them.
commands["pair"] = function(rest, cmd)
    local name = strtrim(rest or "")
    if name == "" then
        Print("|cffffff00/tag pair <name>|r - pick what they are from the list.")
        return
    end
    ShowPairPrompt(name)
end
commands["add"] = commands["pair"]

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

-- One name, off every list it is on: taggers, the active carry, remembered
-- carries, follow targets. There is no "which list did you mean", because a
-- name is a tagger or a carry or a follow target and there is nothing the
-- caller could tell us about which that we cannot look up ourselves.
commands["remove"] = function(rest, cmd)
    local name = strtrim(rest or "")
    if name == "" then
        Print("|cffffff00/tag remove <name>|r")
        return
    end
    local key = NormalizeName(name)
    local gone = {}

    -- Frees the marker and re-derives the rest. In the core because the window
    -- removes taggers too, and both had better do the same four things.
    if Roster.RemoveTagger(key) then gone[#gone + 1] = "tagger" end

    -- The active carry is not a list entry, it is the mode you are in, so
    -- dropping it is a mode change: back to carry mode, and the party-derived
    -- taggers that only exist inside tagger mode go with it.
    if key == db.carryKey then
        db.carry, db.carryKey, db.carryPet, db.carryPetKey = nil, nil, nil, nil
        RebuildDynamicTaggers(); ResetAll(); UpdateAllPlates(); UpdateMacroButton()
        gone[#gone + 1] = "carry"
    end
    -- After that branch and never before it: ForgetCarry refuses the active one.
    if Roster.ForgetCarry(key) then gone[#gone + 1] = "remembered carry" end

    if db.followTargets and db.followTargets[key] then
        Roster.ForgetFollow(key)
        gone[#gone + 1] = "follow target"
    end

    if #gone == 0 then
        -- TaggerKeyOf also matches the party-derived taggers of tagger mode, and
        -- those are not a list anyone can edit - they are rebuilt from the roster
        -- on every change. Say so rather than reporting a removal that did nothing.
        if TaggerKeyOf(name) then
            Print("|cffff8080That tagger comes from your party in tagger mode.|r "
                .. "Leave the group, or remove your carry.")
        else
            Print(format("|cffff8080%s isn't on any of your lists.|r", name))
        end
        return
    end
    Print(format("removed |cffff8080%s|r (%s).", name, table.concat(gone, ", ")))
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
commands["inv"] = function(rest, cmd)
    -- "Get the two of us into one group", from whichever end typed it.
    --
    -- Alone, that means asking THEM to invite US, which is the same exchange the
    -- automatic out-of-range path runs - this is just the manual trigger for it.
    -- Already in a party, it means the opposite: a group exists, so the thing to
    -- do is pull them into it. Two carries running together and either of them
    -- typing /tag inv should not be asking to be taken out of the group they are
    -- standing in - see the invite branch below.
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

    -- A group already exists, so asking to be invited to another one would mean
    -- leaving this one first. Invite them into it instead.
    if IsInGroup() or IsInRaid() then
        -- Only the leader can invite, and in a raid an assistant can too. Guarded
        -- individually, as every optional API member here is: UnitIsGroupAssistant
        -- is not on every client this addon loads on.
        local mayInvite = AmGroupLeader()
            or (IsInRaid() and UnitIsGroupAssistant and UnitIsGroupAssistant("player"))

        if not mayInvite then
            -- A warning and nothing else, deliberately: falling back to asking
            -- THEM would drag us out of the group we are in, which is the one
            -- thing this branch exists to avoid.
            Print(format("|cffff8080Can't invite %s|r - you aren't the group leader. "
                .. "Ask the leader to invite them, or leave the group first.", target))
            return
        end

        InviteToParty(target)
        Print(format("invited |cff00ff00%s|r to your group.", target))
        return
    end

    -- No cooldown CHECK - this one was typed, so it happens. AskForInvite
    -- still claims the cooldown, so the ticker can't ask again a second later.
    AskForInvite(target)
end
commands["invite"] = commands["inv"]

local function HandleSlash(input)
    -- The core assigns this in ADDON_LOADED, after this file has loaded, so
    -- it is read per dispatch rather than captured at load time.
    db = ns.db

    input = strtrim(input or "")
    local cmd, rest = strsplit(" ", input, 2)
    cmd = strlower(cmd or "")

    local handler = commands[cmd]
    if handler then return handler(rest, cmd) end

    -- Deliberately does NOT fall through to pairing: a typo'd subcommand used to
    -- silently create a tagger named after the typo.
    Print(format("|cffff8080Unknown command:|r %s", input))
    Menu()
end

SLASH_TAGTEAM1 = "/tag"
SLASH_TAGTEAM2 = "/tagteam"
SlashCmdList["TAGTEAM"] = HandleSlash

-- The minimap button's right-click prints this, and it reads it off the
-- namespace at click time rather than at load, so this file can keep loading
-- last. It is the same menu /tag prints - one list of commands, not two.
--
-- `Menu` reads the file-local `db`, which HandleSlash refreshes per dispatch,
-- so anything calling it from outside has to make sure that binding exists.
ns.SlashMenu = function()
    db = ns.db
    Menu()
end
