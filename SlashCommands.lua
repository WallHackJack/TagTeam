local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Slash commands
--
-- Everything /tag does, and nothing else does. This file is a leaf: it reads
-- from the core, the core never reads from it, and the whole boundary between
-- them is the export block at the bottom of TagTeam.lua.
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
local TaggersByPriority         = ns.TaggersByPriority
local InviteTarget              = ns.InviteTarget
local PrimaryTaggerKey          = ns.PrimaryTaggerKey
local ReassignMarkers           = ns.ReassignMarkers
local AddTagger                 = ns.AddTagger
local SetCarryTo                = ns.SetCarryTo
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
local LeaveTaggerParty          = ns.LeaveTaggerParty
local CheckLootMethod           = ns.CheckLootMethod
local AskForInvite              = ns.AskForInvite
local SendAddon                 = ns.SendAddon
local PushThreshold             = ns.PushThreshold
local PlayCue                   = ns.PlayCue
local PlayAlertSound            = ns.PlayAlertSound
local PlayMissSound             = ns.PlayMissSound
local SpawnBurst                = ns.SpawnBurst

local db            -- refreshed from ns.db on every dispatch
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
        Print(format("combined damage from %d tagger%s must reach |cffffff00%d%%|r of max health:",
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
    Print(format("XP base: %s | session: %d tags, ~%d XP",
        UsingOutlandBase() and "Outland" or "Azeroth",
        state.sessionTags, state.sessionXP))
    Print(format("pets: %s | pvp mobs: %s | announce: %s | markers: %s | steal warning: %s | enabled: %s",
        db.includePets and "on" or "off",
        db.ignorePvP and "ignored" or "tracked",
        db.announce and "on" or "off",
        db.markers and "on" or "off",
        db.stealWarning and "on" or "off",
        db.enabled and "on" or "off"))
    -- Loud, because a suspended addon looks exactly like a broken one.
    if Suspended() then
        Print("|cffff8080SUSPENDED|r - dungeon or raid. |cffffff00/tag instance|r to run here anyway.")
    end
    Print(format("auto-invite: %s | auto-accept: %s | marks: %s | focus: %s | grouped: %s",
        db.autoInvite and "on" or "off",
        db.autoAccept and "on" or "off",
        db.taggerMarker and "on" or "off",
        C.HAS_FOCUS and (db.autoFocus and "on" or "off") or "n/a",
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
        if PlaySoundFile(rest, C.SOUND_CHANNEL) then
            Print(format("%s sound set to %s", label, rest))
            return rest, id, enabled
        end
        Print("|cffff8080couldn't play|r " .. rest .. " |cffff8080- check the path.|r")
        return file, id, enabled
    end

    Print(format("%s sound %s", label, (not enabled) and "on." or "off."))
    return file, id, not enabled
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
    Print("|cffffff00/tag add <name>|r  |cffffff00/tag remove <name>|r  |cffffff00/tag reset|r")
    Print("|cffffff00/tag threshold <1-100>|r - damage share needed to tag; set it from either client, both follow")
    Print("|cffffff00/tag carry <name>|r - run on a TAGGER's client: you and your party become the taggers")
    Print("|cffffff00/tag ban <mob>|r  |cffffff00/tag unban <mob>|r  |cffffff00/tag banlist|r - mobs to ignore entirely")
    Print("|cffffff00/tag link|r  |cffffff00/tag comms|r - addon-to-addon pairing and real XP reporting")
    Print("|cffffff00/tag macro|r - copyable target/follow/focus macro for your taggers")
    Print("|cffffff00/tag pos <above|below|left|right>|r - where the badge sits on the nameplate")
    Print("|cffffff00/tag audio|r|cffffff00/tag level <n>|r  |cffffff00/tag xp|r  |cffffff00/tag zone|r  |cffffff00/tag calibrate|r  |cffffff00/tag markers|r  |cffffff00/tag steal|r  |cffffff00/tag pets|r  |cffffff00/tag pvp|r  |cffffff00/tag announce|r  |cffffff00/tag instance|r  |cffffff00/tag reset|r  |cffffff00/tag diag|r")
    Print("|cffffff00/tag sound|r |cffffff00/tag sound <id|path>|r |cffffff00/tag testsound|r - tag cue")
    Print("|cffffff00/tag miss|r |cffffff00/tag miss <id|path>|r |cffffff00/tag testmiss|r - miss cue")
    Print("|cffffff00/tag testkill|r - preview the tagged-kill checkmarks")
    Print("|cffffff00/tag inv|r - ask your tagger (or your carry) to invite you now")
    Print("|cffffff00/tag autoinvite|r  |cffffff00/tag accept|r  |cffffff00/tag marks|r  |cffffff00/tag focus|r  |cffffff00/tag focuswarn|r - party handling")
    Print("|cffffff00/tag leave|r  |cffffff00/tag autoleave|r  |cffffff00/tag groupwarn|r  |cffffff00/tag loot|r - grouping")
end
commands["status"] = commands[""]

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

commands["macro"] = function(rest, cmd)
    local text = BuildFollowMacro()
    ShowMacroWindow(text)
    Print("macro shown - Ctrl+C, then paste into a new macro (|cffffff00/macro|r).")
    if #text > 255 then
        Print(format("|cffff8080That's %d characters; WoW macros cap at 255.|r " ..
            "Drop a tagger or trim a line.", #text))
    end
end

commands["ban"] = function(rest, cmd)
    local name = strtrim(rest or "")

    if cmd == "ban" and name ~= "" then
        db.banlist[strlower(name)] = name
        ResetAll(); UpdateAllPlates()
        Print(format("|cffff8080%s|r banned - ignored like a trivial minion.", name))
        return
    end

    if cmd == "unban" and name ~= "" then
        local key = strlower(name)
        local was = db.banlist[key] or C.BANNED_DEFAULT[key]
        if was and db.banlist[key] ~= false then
            -- One of ours is unbanned by overriding it, not by deleting it -
            -- there is nothing saved to delete, and the default would just
            -- reapply on the next login. One of theirs is simply removed.
            --
            -- Spelled out rather than `DEFAULT[key] and false or nil`, which
            -- looks equivalent and is not: `and false` makes the whole
            -- expression falsy, so `or nil` always wins and the override is
            -- never stored. The unban then prints success and does nothing.
            if C.BANNED_DEFAULT[key] then
                db.banlist[key] = false
            else
                db.banlist[key] = nil
            end
            ResetAll(); UpdateAllPlates()
            Print(format("|cff00ff00%s|r unbanned.", was))
        else
            Print(format("%s isn't banned.", name))
        end
        return
    end

    -- Both halves, minus the ones they turned off. Defaults are marked so it is
    -- clear which came with the addon and which they added.
    local list = {}
    for key, display in pairs(C.BANNED_DEFAULT) do
        if db.banlist[key] ~= false then list[#list + 1] = display .. " |cff808080(default)|r" end
    end
    for key, display in pairs(db.banlist) do
        if display and not C.BANNED_DEFAULT[key] then list[#list + 1] = display end
    end
    sort(list)
    if #list == 0 then
        Print("banlist is empty. |cffffff00/tag ban <mob name>|r")
    else
        Print(format("banned mobs (%d): |cffff8080%s|r",
            #list, table.concat(list, ", ")))
        Print("|cffffff00/tag ban <name>|r  |cffffff00/tag unban <name>|r")
    end
end
commands["unban"], commands["banlist"] = commands["ban"], commands["ban"]

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
end

commands["add"] = function(rest, cmd)
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
            info.name, C.MARKER_NAMES[info.marker], table.concat(TaggerNames(), ", ")))
        Print("|cffffff00/tag macro|r for an updated target/follow/focus macro.")
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
    local was = db.taggers[key].name
    db.taggers[key] = nil
    ReassignMarkers()   -- free the slot and re-derive the rest
    ResetAll(); UpdateAllPlates(); UpdateMacroButton()
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

commands["level"] = function(rest, cmd)
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
end

commands["zone"] = function(rest, cmd)
    local mode = strlower(strtrim(rest or ""))
    if mode == "outland" or mode == "azeroth" then
        db.continent = mode
    elseif mode == "auto" then
        db.continent = nil
    else
        Print("|cffffff00/tag zone auto|outland|azeroth|r - forces the XP base constant.")
    end
    RefreshContinent()
    Print(format("XP base: |cffffff00%s|r (%s) | auto-detect says %s, map %s",
        UsingOutlandBase() and "Outland +235" or "Azeroth +45",
        db.continent and "forced" or "auto",
        state.inOutland and "Outland" or "Azeroth",
        MapDiag()))
end
commands["continent"] = commands["zone"]

commands["xp"] = function(rest, cmd)
    Print(format("this session: |cffffff00%d|r tags, ~|cffffff00%s|r XP estimated.",
        state.sessionTags,
        BreakUpLargeNumbers and BreakUpLargeNumbers(state.sessionXP) or tostring(state.sessionXP)))
    if state.reportedKills > 0 then
        Print(format("|cff00ff00%d|r kills reported by linked taggers, |cff00ff00%s|r XP actual%s.",
            state.reportedKills,
            BreakUpLargeNumbers and BreakUpLargeNumbers(state.reportedXP) or tostring(state.reportedXP),
            state.saidMaxLevel and " |cff808080(tagger at max level)|r" or ""))
        if state.matchedEst > 0 then
            Print(format("paired against estimates: |cffffff00%s|r expected, "
                .. "|cffffff00%s|r actual, %s overall.",
                BreakUpLargeNumbers and BreakUpLargeNumbers(state.matchedEst) or tostring(state.matchedEst),
                BreakUpLargeNumbers and BreakUpLargeNumbers(state.matchedXP) or tostring(state.matchedXP),
                MultiplierText(state.matchedXP / state.matchedEst)))
        end
    else
        Print("|cff808080Estimate only: doubles if they're rested, splits if grouped.|r")
    end
end

commands["comms"] = function(rest, cmd)
    db.comms = not db.comms
    Print("addon comms " .. (db.comms and "on." or "off."))
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

commands["calibrate"] = function(rest, cmd)
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
            db.xpScale or 1, state.lastRawXP or "-", state.lastXPInfo or "none yet"))
        return
    end

    if not state.lastRawXP then
        Print("|cffff8080No estimated kill yet - tag and kill something first.|r")
        return
    end

    db.xpScale = actual / state.lastRawXP
    Print(format("scale set to |cffffff00%.3f|r (%d actual vs %d predicted; %s).",
        db.xpScale, actual, state.lastRawXP, state.lastXPInfo))
    Print("|cff808080Check their level is current first - a stale level looks exactly like a bad formula.|r")
end

commands["leave"] = function(rest, cmd)
    if not IsInGroup() and not IsInRaid() then
        Print("not in a group.")
    else
        Print("leaving the party.")
        LeaveTaggerParty()
    end
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

commands["pos"] = function(rest, cmd)
    local mode = strlower(strtrim(rest or ""))
    if not C.BADGE_ANCHORS[mode] then
        Print(format("badge position: |cffffff00%s|r", db.badgePos))
        Print("|cffffff00/tag pos above|below|left|right|r")
        return
    end
    db.badgePos = mode
    UpdateAllPlates()   -- GetBadge re-anchors each plate as it comes through
    Print(format("badge moved |cffffff00%s|r the nameplate.", mode))
end
commands["position"] = commands["pos"]

commands["audio"] = function(rest, cmd)
    db.audio = not db.audio
    if db.audio then
        Print("audio |cff00ff00on|r - tag and miss cues will play.")
    else
        Print("audio |cffff2020off|r - all cues silenced, visuals unaffected.")
    end
end
commands["mute"] = commands["audio"]

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

commands["accept"] = function(rest, cmd)
    db.autoAccept = not db.autoAccept
    Print("auto-accept invites from the tagger " .. (db.autoAccept and "on." or "off."))
end

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
    Print("|cff808080Setting focus is protected. Bind a key under Key Bindings > TagTeam, or use /tag macro.|r")
end

commands["markers"] = function(rest, cmd)
    db.markers = not db.markers
    Print("raid markers on their tags " .. (db.markers and "on." or "off."))
end

commands["steal"] = function(rest, cmd)
    db.stealWarning = not db.stealWarning
    Print("tag-steal warning " .. (db.stealWarning and "on." or "off."))
end

commands["pets"] = function(rest, cmd)
    db.includePets = not db.includePets
    Print("pet damage " .. (db.includePets and "counted." or "ignored."))
end

-- On by default. These do pay XP, so it is a real choice - but hitting one
-- flags the tagger for PvP, and a defenceless low-level alt wearing a PvP
-- flag in contested Outland is a corpse run, not a level.
commands["pvp"] = function(rest, cmd)
    db.ignorePvP = not db.ignorePvP
    UpdateAllPlates()
    Print("PvP-flagged mobs " ..
        (db.ignorePvP and "|cffff8080ignored|r." or "|cff00ff00tracked|r."))
end

-- On by default: a dungeon or raid run is grouped by definition, so a tag
-- there is worth almost nothing and every cue is noise. Off is for anyone
-- who wants the badges anyway.
commands["instance"] = function(rest, cmd)
    db.instanceOff = (db.instanceOff == false)
    UpdateAllPlates()
    local inside, kind = IsInInstance()
    inside = inside and (kind == "party" or kind == "raid")
    Print(format("dungeon/raid suspend %s.%s",
        db.instanceOff and "on" or "off",
        inside and (db.instanceOff and " |cffff8080Suspended now.|r"
            or " |cff00ff00Active now.|r") or ""))
end
commands["dungeon"] = commands["instance"]

commands["announce"] = function(rest, cmd)
    db.announce = not db.announce
    Print("chat announcements " .. (db.announce and "on." or "off."))
end

commands["testsound"] = function(rest, cmd)
    PlayAlertSound()
    Print("played " .. (db.soundFile or ("sound id " .. db.soundId)) .. ".")
end

commands["testmiss"] = function(rest, cmd)
    local miss = (cmd == "testmiss")
    if miss then
        Print("miss preview: " .. (db.missFile or ("sound id " .. db.missId)))
        PlayMissSound()
    else
        Print("tagged-kill preview.")
    end
    if miss then
        SafeCall(SpawnBurst, C.X_TEXTURE, nil, 1, 0.35, 0.35)
    else
        SafeCall(SpawnBurst, C.CHECK_TEXTURE, "+142 XP", 1, 0.86, 0.3)
    end
end
commands["testkill"] = commands["testmiss"]

-- Both cues configure identically: a bare command toggles, a number sets a
-- SOUNDKIT id, anything else is treated as a file path.
commands["sound"] = function(rest, cmd)
    db.soundFile, db.soundId, db.sound =
        ConfigureCue("tag", rest, db.soundFile, db.soundId, db.sound)
end

commands["miss"] = function(rest, cmd)
    db.missFile, db.missId, db.missAlert =
        ConfigureCue("miss", rest, db.missFile, db.missId, db.missAlert)
end

-- Runs from either end: the tagger watching its own damage climb is usually
-- the one who knows the number is wrong, and both clients have to agree on
-- it or they disagree about what counts as tagged.
commands["threshold"] = function(rest, cmd)
    local pct = tonumber(strtrim(rest or ""))
    if not pct or pct <= 0 or pct > 100 then
        Print(format("threshold is |cffffff00%d%%|r of max health - "
            .. "|cffffff00/tag threshold <1-100>|r to change it.", db.threshold))
        return
    end
    local sent = PushThreshold(pct)
    Print(format("threshold set to %d%% of max health%s.", pct,
        sent > 0 and format(" |cff808080(sent to %d linked client%s)|r",
            sent, sent == 1 and "" or "s") or ""))
end
commands["thresh"] = commands["threshold"]

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
