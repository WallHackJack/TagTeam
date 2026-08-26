local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- TagTeamView - the /tag window
--
-- A leaf, like SlashCommands.lua: it reads from the core, the core never reads
-- from it, and everything in it is chrome. The addon has to keep working with
-- this window never opened.
--
-- The chrome itself is not here - it is in WallhackUiKit.lua, which is shared
-- verbatim with WhoDoesWhat. What belongs here is specific to TagTeam:
-- which tabs there are and what goes on them. Anything that a second window or
-- a pop-up would also want belongs in the kit instead, and then it has to be
-- copied across. Read the kit's header before adding to it.
--
-- The window never decides anything. Every button ends in a `ns.Roster` call,
-- so the mode-exclusivity rule and its confirm popup are enforced once, in the
-- core, for this and for /tag alike. See Roster.RequestTagger.
--
-- BUILT ON FIRST OPEN. A user who never types the command pays nothing for it,
-- and the build is free to read anything the core assigns at ADDON_LOADED,
-- which a build at file scope would not be.
--------------------------------------------------------------------------------

local UI, SafeCall = ns.UI, ns.SafeCall
local UpdateAllPlates   = ns.UpdateAllPlates
local UpdateMacroButton = ns.UpdateMacroButton
local BuildFollowMacro  = ns.BuildFollowMacro
local ReassignMarkers   = ns.ReassignMarkers
local PushThreshold     = ns.PushThreshold
local Roster, Cues, Mobs = ns.Roster, ns.Cues, ns.Mobs
local TaggersByPriority = ns.TaggersByPriority
local NormalizeName = ns.NormalizeName
local Print = ns.Print
local C = ns.C

local WIDTH, HEIGHT = 560, 510

-- Narrower than the name prompt, not wider. It used to be half again as wide,
-- because a sound path is a long thing to read - but the path now gets a line
-- of its own rather than sharing one with its caption, so the width it needed
-- came out of the height instead. A tall narrow panel also reads as a settings
-- card, where a wide flat one read as a dialog box.
local SOUND_PROMPT_W = 320
local PREVIEW_GAP    = 0.3   -- seconds between previews while a slider moves
-- Wide enough for "TagTeam volume: 100%", the longest this caption gets, so
-- the slider anchored to its right never moves. See BuildSoundsPage.
local VOLUME_LABEL_W = 150
local THRESHOLD_SEND_GAP = 0.6   -- settle time before the threshold is whispered

-- The tabs, in display order. Adding one is adding a line: the strip lays
-- itself out from this list. `page` is the stable key for a tab - the label is
-- the part that gets reworded.
-- About stays last on purpose: it is the one tab that is never part of doing
-- anything, so it sits out of the way on the right.
local TABS = {
    { page = "players",   label = "Players" },
    { page = "general",   label = "General" },
    { page = "popups",    label = "Popups" },
    { page = "nameplate", label = "Nameplate" },
    { page = "ignore",    label = "Ignore" },
    { page = "sounds",    label = "Audio" },
    -- Anchored from the right instead of chained onto the run above, so the
    -- gap between it and Sounds is whatever is left over rather than a number
    -- somebody has to keep correct.
    { page = "about",     label = "About", right = true },
}

-- What a name can be, and the order the pair prompt offers them. The values
-- key into SECTIONS below, so the two lists cannot drift apart silently.
local ROLES = {
    { value = "tagger", label = "Tagger" },
    { value = "carry",  label = "Carry" },
    { value = "follow", label = "Follow target" },
}

local frame    -- the window, nil until the first open
local prompt   -- the shared add/pair prompt, nil until something asks for one
local buildFailed   -- set once Build has thrown; see Ready

--------------------------------------------------------------------------------
-- A player, on one line
--
-- Name, level, and where they are, from whatever the last ping brought back.
-- One font string with colour escapes rather than three regions: the fields
-- run into each other left to right, and three anchored regions would each
-- need a width for a name whose length nobody knows.
--------------------------------------------------------------------------------

local GREY = "ff808080"

local function ClassHex(class)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    -- Grey until we have heard from them. A name in a class colour we guessed
    -- would be worse than one that admits it does not know.
    if not color then return GREY end
    return format("ff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
end

local function PlayerLine(entry)
    local seen = Roster.Seen(entry.key)
    local line = format("|c%s%s|r", ClassHex(seen and seen.class), entry.name)

    if seen and seen.level then
        line = line .. format("  |cffffff00%d|r", seen.level)
    end

    local presence, zone = Roster.Presence(entry.key)
    local tail =
        (presence == "here" and (zone or "unknown"))
        or (presence == "silent" and "offline")
        or (presence == "waiting" and "...")
        or "unknown"
    return line .. format("  |c%s- %s|r", GREY, tail)
end

--------------------------------------------------------------------------------
-- The three lists
--
-- One entry per section, which is what actually keeps the three identical: the
-- build and refresh code below knows nothing about carries or taggers, only
-- about these functions. A fourth list is a fourth entry here and nothing else.
--------------------------------------------------------------------------------

local SECTIONS = {
    {
        role  = "carry",
        title = "Carries",
        noun  = "Carry",
        empty = "No carries remembered.",
        add   = "Remember a carry - the character doing the killing.",
        clear = "Forget every remembered carry. The active one stays.",
        -- The checkbox IS the active marker, and clicking anywhere on the row
        -- ticks it. That replaces the word "active" on the end of a line: a
        -- column of boxes says which one at a glance, where a word has to be
        -- read on every row to find out it is not there.
        check = true,
        List  = function() return Roster.Carries() end,
        Add   = function(name) Roster.RequestCarry(name) end,
        Drop  = function(key) Roster.ForgetCarry(key) end,
        Clear = function() Roster.ClearCarries() end,
        Active = function(entry) return ns.db and entry.key == ns.db.carryKey end,
        Pick   = function(entry) Roster.RequestCarry(entry.name) end,
        Line   = function(entry) return PlayerLine(entry) end,
    },
    {
        role  = "tagger",
        title = "Taggers",
        noun  = "Tagger",
        empty = "No taggers. Add the character you are levelling.",
        add   = "Add a tagger - the character being levelled.",
        clear = "Remove every tagger.",
        gear  = true,
        -- Marker order, not alphabetical, so the list reads in the same order
        -- as the markers on screen and the follow macro.
        List  = function()
            local out = {}
            for _, info in ipairs(TaggersByPriority()) do
                out[#out + 1] = { key = NormalizeName(info.name),
                                  name = info.name, marker = info.marker }
            end
            return out
        end,
        Add   = function(name) Roster.RequestTagger(name) end,
        Drop  = function(key) Roster.RemoveTagger(key) end,
        Clear = function() Roster.ClearTaggers() end,
        Note  = function(entry)
            return entry.marker and C.MARKER_NAMES[entry.marker] or nil
        end,
    },
    {
        role  = "follow",
        title = "Follow targets",
        noun  = "Follow target",
        empty = "No follow targets.",
        add   = "Remember a follow target.",
        clear = "Forget every follow target.",
        List  = function() return Roster.Follows() end,
        Add   = function(name) Roster.AddFollow(name) end,
        Drop  = function(key) Roster.ForgetFollow(key) end,
        Clear = function() Roster.ClearFollows() end,
    },
}

local function SectionFor(role)
    for _, section in ipairs(SECTIONS) do
        if section.role == role then return section end
    end
end

--------------------------------------------------------------------------------
-- The prompt
--------------------------------------------------------------------------------

-- One prompt frame serves the three [+] buttons and /tag pair. The only
-- difference between them is whether the role is already settled: a [+] lives
-- on a section so it is, and /tag pair does not, so that one gets the dropdown.
local function Ask(role, name)
    if not prompt then prompt = UI.CreatePrompt("TagTeamPromptFrame") end

    local known = role and SectionFor(role)
    prompt:Ask({
        -- The heading says what is about to happen; the box says what to type.
        -- Two lines that both said "character name" was one line wasted.
        title   = known and ("Add a " .. known.noun) or "Pair with a character",
        hint    = "Character name",
        text    = name,
        choices = (not role) and ROLES or nil,
        choice  = "tagger",
        accept  = "Add",
        OnAccept = function(text, chosen)
            local section = SectionFor(role or chosen)
            if section then section.Add(text) end
            -- A name typed in is a name we know nothing about. Forced past the
            -- throttle: this is the one moment the answer is worth waiting for.
            Roster.Ping(text, true)
            ns.RefreshView()
        end,
    })
end

--------------------------------------------------------------------------------
-- The Players page
--------------------------------------------------------------------------------

-- Row widgets are built once and reused. The refresh below runs on a ticker, so
-- creating anything in it would leak a frame per name per pass.
local function DressRow(section, index)
    local row = UI.CreateSectionRow(section.box, index)
    if row.label then return row end

    row.remove = UI.CreateCloseButton(row, UI.ROW_ICON, 0.35)
    row.remove:SetPoint("RIGHT", -2, 0)
    UI.AddTooltip(row.remove, "Remove", "Take this name off the list.")

    local noteAnchor = row.remove
    if section.gear then
        row.gear = UI.CreateGearButton(row, "Settings",
            "Per-tagger settings aren't built yet.", nil)
        row.gear:SetSize(UI.ROW_ICON, UI.ROW_ICON)
        row.gear:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
        -- Disabled with a reason rather than live and inert: a button that does
        -- nothing when clicked reads as a bug.
        row.gear:Disable()
        row.gear.disabledReason = "Per-tagger settings aren't built yet."
        noteAnchor = row.gear
    end

    -- Right-aligned and grey: a marker name, or whatever else the section has
    -- to say about a row without competing with the name.
    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.note:SetPoint("RIGHT", noteAnchor, "LEFT", -6, 0)
    row.note:SetTextColor(0.6, 0.6, 0.6)

    local textLeft = 6
    if section.check then
        -- The whole row is the click target, so this is an indicator you can
        -- also hit directly rather than the only way in. Both ends run Pick.
        -- Both ends run the same OnPick, which the refresh re-points at whoever
        -- is in this pooled row now. A Frame has no Click(), so the box calls
        -- the handler rather than forwarding to the row.
        local function Pick() if row.OnPick then row.OnPick() end end

        row.check = UI.CreateCheckbox(row, nil, "Make this your carry",
            "Sets who is levelling you. Switching modes still asks first.", Pick)
        row.check:SetSize(UI.ROW_CHECK, UI.ROW_CHECK)
        row.check:SetPoint("LEFT", 4, 0)
        textLeft = 4 + UI.ROW_CHECK + 6

        row:EnableMouse(true)
        -- The left UI.ROW_CLICK_FRAC of it, anyway: the right end belongs to
        -- this row's buttons. Same cut as UI.AddRowCheckbox, and for the same
        -- reason - see there.
        row:SetScript("OnSizeChanged", function(self, width)
            self:SetHitRectInsets(0, (width or 0) * (1 - UI.ROW_CLICK_FRAC),
                0, 0)
        end)
        row:SetScript("OnMouseUp", Pick)
        row:SetScript("OnEnter", function(self) self.hover:Show() end)
        row:SetScript("OnLeave", function(self) self.hover:Hide() end)
        row.hover = row:CreateTexture(nil, "BORDER")
        row.hover:SetAllPoints()
        row.hover:SetColorTexture(1, 1, 1, 0.07)
        row.hover:Hide()
    end

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("LEFT", textLeft, 0)
    row.label:SetPoint("RIGHT", row.note, "LEFT", -6, 0)
    row.label:SetJustifyH("LEFT")

    return row
end

local function RefreshSection(section)
    local list = section.List()

    for i, entry in ipairs(list) do
        local row = DressRow(section, i)
        local live = section.Active and section.Active(entry)

        -- Line carries its own colours, so the font string is left plain white
        -- and the escapes decide. Sections without one just show the name.
        row.label:SetText(section.Line and section.Line(entry) or entry.name)
        row.label:SetTextColor(0.9, 0.9, 0.9)
        row.note:SetText(section.Note and section.Note(entry) or "")

        -- Re-wired per refresh rather than once: a pooled row holds a different
        -- name after a removal, and a closure over the old key would delete
        -- whoever moved up into that slot.
        row.remove:SetScript("OnClick", function()
            section.Drop(entry.key)
            ns.RefreshView()
        end)

        if row.check then
            row.check:SetChecked(live)
            row.OnPick = function()
                -- Re-ticking the one that is already on would only raise the
                -- mode popup for a change that is not one.
                if live then
                    row.check:SetChecked(true)
                    return
                end
                if section.Pick then section.Pick(entry) end
                ns.RefreshView()
            end
        end

        -- The active carry is a mode, not a list entry, and Roster refuses to
        -- forget it. Show that here rather than letting the click do nothing.
        if live then
            row.remove:Disable()
            row.remove.disabledReason =
                "This is your carry right now. |cffffff00/tag carry off|r first."
        else
            row.remove:Enable()
        end
        row:Show()
    end

    UI.SetSectionRowCount(section.box, #list)
    section.hint:SetShown(#list == 0)
    if #list > 0 then section.clearBtn:Enable() else section.clearBtn:Disable() end
    UI.LayoutHeaderChain(section.box)
end

local function BuildPlayersPage(page)
    local scroll = UI.CreateScroll(page, "TagTeamViewPlayersScroll")
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -UI.SCROLLBAR_W, 0)
    frame.playersScroll = scroll

    local boxes = {}
    for i, section in ipairs(SECTIONS) do
        local box = UI.CreateSectionBox(scroll:GetScrollChild(), section.title)
        section.box = box
        boxes[i] = box

        -- Chained rightmost-first: [x] hugs the corner, [+] sits to its left.
        section.clearBtn = UI.AddHeaderCloseButton(box, "Clear " .. section.title,
            section.clear, function()
                section.Clear()
                ns.RefreshView()
            end)
        section.clearBtn.disabledReason = "Nothing to clear."
        -- "Add (+)", the same label WhoDoesWhat's sections use, so the two
        -- addons' section headers read identically.
        UI.AddHeaderTextButton(box, "Add (+)", "Add", section.add, function()
            Ask(section.role)
        end)

        section.hint = UI.CreateEmptyHint(box)
        section.hint:SetText(section.empty)
    end
    frame.playersBoxes = boxes
end

--------------------------------------------------------------------------------
-- The Sounds page
--
-- One row per entry in C.CUES, grouped into the boxes C.CUE_SECTIONS names, so
-- a cue added to the core turns up here without anything in this file changing.
-- The three pull verdicts carry the same marks they draw on screen - checkmark,
-- warning, X - because that is what somebody is actually matching the sound to.
--
-- Above the boxes: the master switch, a volume, and the choice between our
-- volume and the game's. See the Volume block in TagTeam.lua for why following
-- the game is both the default and the only setting that touches nothing.
--------------------------------------------------------------------------------

local sounds = { boxes = {}, cueBoxes = {} }   -- the page's widgets, built once

-- A cue by its key. The Popups tab's audio buttons name a cue in a row spec,
-- and C.CUES is a list rather than a map because its ORDER is what the Audio
-- tab draws - so the lookup lives here rather than the list being reshaped.
local function CueByKey(key)
    for _, cue in ipairs(C.CUES) do
        if cue.key == key then return cue end
    end
end

-- Previewing, throttled. Every one of these hangs off a slider, and a slider
-- reports every step of a drag - without this, dragging from 0 to 100 would
-- fire the cue twenty times on top of itself.
local lastPreview = 0
local function Preview(key)
    local now = GetTime()
    if now - lastPreview < PREVIEW_GAP then return end
    lastPreview = now
    -- No key means the global controls, which preview the addon's own sound at
    -- full strength rather than borrowing a cue - see Cues.PlayMaster.
    if key then Cues.Play(key) else Cues.PlayMaster() end
end

-- Blizzard's confirm rather than the addon's own prompt: that one is a form
-- with a field in it, and this is a yes/no on something that cannot be undone.
-- Spelled out in full because "reset audio" could mean the master block, the
-- cues, or both, and the button is next to the master block only.
StaticPopupDialogs["TAGTEAM_RESET_AUDIO"] = {
    -- "100%%", not "100%". StaticPopup_Show puts this string through
    -- SetFormattedText whether or not it was given arguments, so a lone % is a
    -- format directive that has nothing to consume - it throws, and the pop-up
    -- never appears. The doubled one prints as a single percent sign.
    text = "Reset ALL audio settings to their defaults?\n\n"
        .. "Every cue goes back to its shipped sound, its own volume returns to "
        .. "100%%, and each cue's on/off switch returns to how it ships. The "
        .. "TagTeam volume, the follow-the-game setting and the master switch "
        .. "are reset too.\n\n"
        .. "Nothing outside the Audio tab is changed. This cannot be undone.",
    -- SWAPPED, on purpose. StaticPopup draws button1 on the left and button2 on
    -- the right, and the way out belongs on the left with the accept on the
    -- right - the same order the addon's own prompt uses. So Cancel is the
    -- "accept" slot and the reset hangs off OnCancel.
    button1 = CANCEL,
    button2 = ACCEPT,
    -- No timeout and no escape route into OnCancel: with the handler on that
    -- side, either one would fire the reset without anybody pressing anything.
    -- Escape still closes the window, it just closes it silently.
    timeout = 0,
    noCancelOnEscape = true,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,   -- avoids tainting Blizzard's popup stack
    OnAccept = function() end,   -- button1 is Cancel now: nothing to do
    -- `reason` is "clicked" only for the button. Belt and braces with the two
    -- flags above: a reset this size should need a press, not a dismissal.
    OnCancel = function(_, _, reason)
        if reason ~= "clicked" then return end
        Cues.ResetAll()
        Print("all audio settings reset to their defaults.")
        ns.RefreshView()
    end,
}

-- The gear's pop-up: which sound, how loud, and a way back to the default.
local function AskSound(cue)
    if not prompt then prompt = UI.CreatePrompt("TagTeamPromptFrame") end
    prompt:Ask({
        title = cue.label .. " Audio Queue",
        width = SOUND_PROMPT_W,
        label = "Sound Path",
        hint  = "Sound id, or a file path",
        -- Pre-filled with what it is actually playing. An empty box would make
        -- somebody guess the shape of the thing they are meant to replace.
        text  = Cues.CurrentSetting(cue.key),
        accept = "Save",
        -- Blank is an answer here: it puts the cue back to its default.
        allowEmpty = true,
        -- The same switch the Audio tab's row carries, on the pop-up itself.
        -- This opens from the Popups tab too, and sending somebody to another
        -- tab to turn off the thing they just listened to is a round trip for
        -- one tick box.
        toggle = {
            label   = "Enable this Audio Queue",
            checked = Cues.Enabled(cue.key),
            OnClick = function(on)
                if on ~= Cues.Enabled(cue.key) then Cues.Toggle(cue.key) end
                if on then Cues.Play(cue.key) end
                ns.RefreshView()
            end,
        },
        -- Nothing to save if the path is not there. A number is always fine -
        -- an id resolves to something or to silence, never to an error - and an
        -- empty box means reset, so both abstain.
        Validate = function(text)
            if text == "" or tonumber(text) then return nil end
            if Cues.Playable(text) then return nil end
            return false, "No sound at that path."
        end,
        slider = {
            label = "Volume: %.0f%%",
            min = 0, max = 100, step = 5,
            value = (ns.db.cueVolume and ns.db.cueVolume[cue.key]) or 100,
            -- Saved as it moves rather than on accept: the point of a volume
            -- slider is hearing the difference, and Cancel on a volume you have
            -- already listened to would be a strange thing to want.
            OnChange = function(value)
                Cues.SetVolume(cue.key, value)
                ns.RefreshView()
            end,
            -- Heard on release only. A drag reports every step, and previewing
            -- each one stacked the cue on top of itself all the way across.
            OnRelease = function() Preview(cue.key) end,
        },
        reset = function()
            Cues.Reset(cue.key)
            Print(format("%s reset to its default.", cue.label))
            -- Played, like Save is. Reset changes the sound AND the volume, so
            -- it is exactly as much of a change as saving one, and hearing the
            -- result is the point of both.
            Cues.Play(cue.key)
            ns.RefreshView()
        end,
        OnAccept = function(text)
            -- Reported in chat rather than in the prompt: a bad path is worth
            -- keeping a record of, and the prompt is gone by then.
            local ok, message = Cues.SetSound(cue.key, text)
            Print(ok and message or ("|cffff8080" .. message .. "|r"))
            if ok then Cues.Play(cue.key) end
            ns.RefreshView()
        end,
    })
end

local function DressCueRow(box, index, cue)
    local row = UI.CreateSectionRow(box, index)
    if row.label then return row end

    -- Box first, same as every other settings row in the window. The Popups tab
    -- lists overlapping things, and a control that changed sides between the
    -- two would have to be found twice.
    UI.AddRowCheckbox(row, nil, cue.label, cue.about, function()
        -- Ticking one on plays it. The /tag test* commands are gone, and this
        -- is the moment somebody wants to hear what they just switched on.
        if Cues.Toggle(cue.key) then Cues.Play(cue.key) end
        ns.RefreshView()
    end)

    row.gear = UI.CreateGearButton(row, "Change the sound",
        "Pick a SOUNDKIT id or a file path, set this cue's own volume, or "
        .. "reset it. A path is checked by playing it.",
        function() AskSound(cue) end)
    row.gear:SetSize(UI.ROW_ICON, UI.ROW_ICON)
    row.gear:SetPoint("RIGHT", -4, 0)

    -- The verdict marks are the same textures the death burst draws, so the
    -- row and the thing it makes a noise about are unmistakably the same event.
    local textLeft = 4 + UI.ROW_CHECK + 6
    if cue.icon then
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(UI.ROW_ICON, UI.ROW_ICON)
        row.icon:SetPoint("LEFT", row.check, "RIGHT", 6, 0)
        row.icon:SetTexture(cue.icon)
        textLeft = textLeft + UI.ROW_ICON + 6
    end

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("LEFT", textLeft, 0)
    row.label:SetText(cue.label)

    -- What it is currently set to, grey and to the right of the name. The gear
    -- changes it, and this is how you see that the change took.
    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.note:SetPoint("RIGHT", row.gear, "LEFT", -8, 0)
    row.note:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
    row.note:SetJustifyH("RIGHT")
    row.note:SetTextColor(0.55, 0.55, 0.55)

    return row
end

local function BuildSoundsPage(page)
    -- The scroll owns the WHOLE page, master box included. Anchored above it,
    -- the master box sat still while everything under it moved, and the bar
    -- reported the height of two sections out of three.
    local scroll = UI.CreateScroll(page, "TagTeamViewSoundsScroll")
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -UI.SCROLLBAR_W, 0)
    sounds.scroll = scroll

    -- The three controls that govern everything below them, in a box of their
    -- own above the cue boxes. Loose on the page they read as page furniture;
    -- boxed and titled they read as what they are - a section whose settings
    -- multiply every section under it. Stacked with the others, so it is
    -- boxes[1] rather than a thing on the side.
    local master = UI.CreateSectionBox(scroll:GetScrollChild(), "Master Audio")
    sounds.boxes[1] = master
    sounds.masterBox = master

    -- Deliberately NOT disabled when audio is off: it is the way back from a
    -- settings mess, and one of the things it fixes is the switch that would
    -- have greyed it out.
    UI.AddHeaderTextButton(master, "Reset All Audio to Default",
        "Reset all audio",
        "Every cue's sound, volume and switch, and the master settings in this "
        .. "box, back to how the addon ships. Asks first.",
        function() StaticPopup_Show("TAGTEAM_RESET_AUDIO") end)
    UI.LayoutHeaderChain(master)

    -- One control per row, on the same alternating stripes every other box in
    -- the window uses. Hand-placed they were three loose controls that happened
    -- to be near each other; on rows they line up with the cue rows below, and
    -- the checkboxes are ROW_CHECK like every other checkbox on a row.
    local switchRow = UI.CreateSectionRow(master, 1)
    sounds.master = UI.AddRowCheckbox(switchRow, "Enable TagTeam Audio",
        "Enable TagTeam Audio",
        "Every cue below is silenced while this is off. The on-screen marks "
        .. "are unaffected. Same switch as |cffffff00/tag sound|r.",
        function()
            ns.db.audio = not ns.db.audio
            -- After the flag, not before: PlayCue checks it, so a preview on
            -- the way ON would be silenced by the value it is confirming.
            -- Turning sounds off says so by making none.
            Preview()
            ns.RefreshView()
        end)

    -- Caption then handle, on one line and left aligned, the caption starting
    -- where a row's label starts so the three rows share a left edge.
    --
    -- FIXED WIDTH on the caption, and left-justified: the caption carries the
    -- value, so its text is narrower at 5% than at 100% - and a handle anchored
    -- to the right of a font string that sizes to its own text walks sideways
    -- as you drag it, which is the one control where that is unbearable.
    local volumeRow = UI.CreateSectionRow(master, 2)
    sounds.volumeLabel = volumeRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sounds.volumeLabel:SetWidth(VOLUME_LABEL_W)
    sounds.volumeLabel:SetJustifyH("LEFT")
    -- At the row's own left edge, where the checkboxes above and below start -
    -- NOT indented to where their labels start. There is no box in front of
    -- this one, so the indent read as a stray gap rather than as alignment.
    sounds.volumeLabel:SetPoint("LEFT", 4, 0)

    sounds.volume = UI.CreateSlider(volumeRow, "TagTeamViewVolume", 0, 100, 5,
        function(_, value)
            ns.db.volume = value
            ns.RefreshView()
        end)
    -- Heard when the handle is let go, not at every step of the drag: a drag
    -- across the slider fired this twenty times, each one landing on top of the
    -- last. See UI.CreateSlider's OnMouseUp.
    sounds.volume.OnRelease = function() Preview() end
    sounds.volume:SetWidth(160)
    sounds.volume:SetPoint("LEFT", sounds.volumeLabel, "RIGHT", 12, 0)
    if sounds.volume.title then sounds.volume.title:SetText("") end
    UI.AddTooltip(sounds.volume, "TagTeam volume",
        "How loud this addon's own cues are. The game's Sound Effects slider "
        .. "and each cue's own volume both multiply this one.")

    local followRow = UI.CreateSectionRow(master, 3)
    -- Label left empty here: RefreshSounds writes it, because it carries the
    -- game's current Sound Effects percentage.
    sounds.followGame = UI.AddRowCheckbox(followRow, "",
        "Follow the game's volume",
        "Multiply everything by your Sound Effects slider as well. Off, this "
        .. "addon plays at its own volume whatever the game is set to.",
        function()
            ns.db.useGameVolume = not ns.db.useGameVolume
            Preview()
            ns.RefreshView()
        end)

    -- Three rows, and the box sizes itself to them the way every other section
    -- does. Fixed here rather than in RefreshSounds: this box's row count is
    -- decided by the code above, not by anything in the saved variables.
    UI.SetSectionRowCount(master, 3)

    for i, group in ipairs(C.CUE_SECTIONS) do
        local box = UI.CreateSectionBox(scroll:GetScrollChild(), group.title)
        UI.LayoutHeaderChain(box)   -- no header buttons; keeps the call uniform
        sounds.cueBoxes[i] = box
        sounds.boxes[i + 1] = box   -- master is boxes[1]; these stack under it
    end
end

local function RefreshSounds()
    local db = ns.db
    local on = db and db.audio

    sounds.master:SetChecked(on)
    sounds.followGame:SetChecked(db and db.useGameVolume)
    UI.SetSliderValue(sounds.volume, (db and db.volume) or 100)
    sounds.volumeLabel:SetText(format("TagTeam volume: %.0f%%",
        (db and db.volume) or 100))
    if sounds.followGame.label then
        -- The live CVar in the label, because "the game's volume" is a number
        -- somebody set months ago in a menu they are not looking at.
        sounds.followGame.label:SetText(format(
            "Also follow the game's Sound Effects volume (%.0f%%)",
            Cues.GameVolume() * 100))
    end

    -- Both sliders are live together now: ours is not disabled by following the
    -- game, because the two multiply rather than take turns.
    UI.SetEnabled(on, sounds.followGame, sounds.followGame.label,
        sounds.volume, sounds.volumeLabel)

    for i, group in ipairs(C.CUE_SECTIONS) do
        local box, index = sounds.cueBoxes[i], 0
        for _, cue in ipairs(C.CUES) do
            if cue.section == group.key then
                index = index + 1
                local row = DressCueRow(box, index, cue)
                row.check:SetChecked(Cues.Enabled(cue.key))

                -- What it is set to, then its own volume if it has one, then
                -- whether the file is actually there. A cue turned down to 20%
                -- and one at full volume look identical otherwise, and a cue
                -- pointed at a path this client does not have looks like a cue
                -- that is simply broken.
                local per = db and db.cueVolume and db.cueVolume[cue.key]
                local note = Cues.Describe(cue.key)
                    .. (per and format("  |cffffff00%.0f%%|r", per) or "")
                if Cues.PathOk(cue.key) == false then
                    note = note .. "  |cffff4040missing|r"
                end
                row.note:SetText(note)

                row.check.disabledReason = "Sounds are off. Turn on Enable TagTeam Audio."
                row.gear.disabledReason = "Sounds are off. Turn on Enable TagTeam Audio."

                -- Two states, not one. Sounds off greys the whole row, gear
                -- included, because none of it can do anything. A cue switched
                -- off with sounds on greys only what the cue IS - its mark, its
                -- name and what it is set to - and leaves the box and the gear
                -- lit, since both still work on a silent cue.
                UI.SetEnabled(on, row.gear, row.check)
                UI.SetEnabled(on and Cues.Enabled(cue.key),
                    row.icon, row.label, row.note)
                row:Show()
            end
        end
        UI.SetSectionRowCount(box, index)
    end

    UI.SetScrollHeight(sounds.scroll,
        UI.StackSections(sounds.scroll:GetScrollChild(), sounds.boxes))
end

--------------------------------------------------------------------------------
-- The option pages
--
-- General, Popups and Nameplate are all the same page with different contents,
-- so they are declared rather than built: a table of boxes, each a list of
-- rows, each row naming the db key it stands for. The builder below knows
-- checkbox, slider and dropdown and nothing else about what any of them mean.
--
-- Adding an option is a line in OPTION_PAGES. `after` names the thing that has
-- to be re-derived once it changes - a badge position nobody repaints is a
-- setting that appears not to work - and `Set` replaces the plain db write
-- where the core has its own way in, which the threshold does because it is
-- synchronised with the other client.
--------------------------------------------------------------------------------

-- The threshold, applied locally at once and pushed to the other client once
-- the handle stops moving. Both ends have to agree on this number, so the send
-- cannot be skipped - only deferred until there is one value worth sending.
local pendingThreshold
local function PushThresholdSoon(value)
    ns.db.threshold = value    -- so the label and the badge follow the handle
    if pendingThreshold then pendingThreshold = value; return end
    pendingThreshold = value
    C_Timer.After(THRESHOLD_SEND_GAP, function()
        local send = pendingThreshold
        pendingThreshold = nil
        SafeCall(PushThreshold, send)
    end)
end

local AFTER = {
    plates  = function() UpdateAllPlates() end,
    markers = function() ReassignMarkers(); UpdateAllPlates() end,
    macro   = function() UpdateMacroButton() end,
}

local BADGE_CHOICES = {
    { value = "above", label = "Above" },
    { value = "below", label = "Below" },
    { value = "left",  label = "Left" },
    { value = "right", label = "Right" },
}

-- Which XP base an estimate is built on. Auto is the detection in
-- RefreshContinent, and the other two override it for the case where the map
-- system is not answering - the reason the setting exists at all.
--
-- A FUNCTION rather than a table, because "Auto" has to say what it currently
-- resolves to and that changes when you fly to Outland. The kit re-resolves a
-- callable `choices` on every menu open and every Sync, so the label is live
-- instead of frozen at whichever continent the window was first built on.
--
-- Each option carries what it is worth: the flat term in mobLevel * 5 + base.
-- An option that did not say would be asking somebody to guess which way it
-- moves their estimate. Greyed, because it is a note rather than the name.
local function ZoneNote(text)
    return " |cff808080(" .. text .. ")|r"
end

local function ZoneChoices()
    return {
        { value = "auto",
          label = "Auto" .. ZoneNote(ns.state.inOutland and "Outland" or "Azeroth") },
        { value = "azeroth",
          label = "Azeroth" .. ZoneNote("+" .. C.XP_BASE_AZEROTH .. "xp") },
        { value = "outland",
          label = "Outland" .. ZoneNote("+" .. C.XP_BASE_OUTLAND .. "xp") },
    }
end

-- What a damage target is worth in XP, beside the slider that sets it.
--
-- Through the core's own ExpectedXP - the share-cubed curve the measured kills
-- landed on - so this is the actual answer rather than a placeholder. It
-- is what makes the pair of sliders legible: XP climbs with the share instead
-- of switching on at a line, and 31 against 40 means nothing until you can see
-- what each one pays.
--
-- No tilde in front of it. It used to carry one to say "estimate", but Friz
-- Quadrata draws a tilde high and thin and it read as a smudge above the digits
-- rather than as a word. The tooltip and the chat line both say estimate in
-- actual words, which is where that belongs.
--
-- XP purple because that is what this addon has always coloured xp.
local function TargetXPNote(value)
    return format("|c%s%d%% XP|r", C.HEX_XP,
        floor((ns.ExpectedXP(value) or 0) * 100 + 0.5))
end

--------------------------------------------------------------------------------
-- The fonts the badge can be drawn in
--
-- The game's own four, which are on every client whatever else is installed,
-- plus whatever LibSharedMedia-3.0 has been given IF some other addon you run
-- provides it. That library is how nearly every addon with a font dropdown
-- fills one, so taking its list when it happens to be loaded gets our dropdown
-- the same fonts as the rest of your UI for no dependency of our own - and its
-- absence costs nothing but a shorter list.
--
-- Values are PATHS, never library keys: a path is what SetFont takes, and it is
-- the half that still means something after the addon that registered the name
-- is uninstalled. See SetBadgeFont in the core for what happens when it stops
-- resolving.
--------------------------------------------------------------------------------

-- "" is the game's own font rather than a fifth path, so "Default" follows
-- STANDARD_TEXT_FONT wherever this client's locale puts it.
local SHIPPED_FONTS = {
    { value = "",                    label = "Default" },
    { value = "Fonts\\FRIZQT__.TTF", label = "Friz Quadrata" },
    { value = "Fonts\\ARIALN.TTF",   label = "Arial Narrow" },
    { value = "Fonts\\MORPHEUS.TTF", label = "Morpheus" },
    { value = "Fonts\\SKURRI.TTF",   label = "Skurri" },
}

-- Blizzard's dropdown draws its list as one column and does not scroll it, so a
-- list longer than the screen has a bottom nobody can reach. Everything past
-- the game's own fonts is therefore filed into submenus of this many, labelled
-- by the letters they span - which is also how you find "Expressway" in a media
-- pack of two hundred without reading all two hundred.
local FONT_GROUP = 18

local function LetterRange(first, last)
    local a, b = first:sub(1, 1):upper(), last:sub(1, 1):upper()
    return a == b and a or (a .. " - " .. b)
end

-- Every row drawn in the font it names, with a sample of the thing the badge
-- actually shows on the end of it. A name in a uniform font tells you what a
-- font is called; it does not tell you whether its digits are legible at speed
-- over a mob's head, which is the only question being asked here.
--
-- One Font OBJECT per row, because that is what a dropdown button takes. They
-- are global by necessity - CreateFont needs a name - so they are numbered off
-- a counter and built once, on the single pass FontChoices ever makes.
local FONT_SAMPLE = " - 25%"
local FONT_MENU_SIZE = 11
local fontObjects = 0

local function SampleFont(path)
    fontObjects = fontObjects + 1
    local name = "TagTeamFontSample" .. fontObjects
    local obj = _G[name] or CreateFont(name)
    if path ~= "" then obj:SetFont(path, FONT_MENU_SIZE, "") end
    -- Same fallback the badge uses, and for the same reason: a font object
    -- whose SetFont did not take draws nothing at all, so a dead path would
    -- turn its row into an empty line rather than a name you could avoid.
    if path == "" or not obj:GetFont() then
        obj:SetFont(STANDARD_TEXT_FONT, FONT_MENU_SIZE, "")
    end
    obj:SetTextColor(1, 1, 1)
    return obj
end

local function Sampled(entry)
    return { value = entry.value,
             label = entry.label .. FONT_SAMPLE,
             font  = SampleFont(entry.value) }
end

-- Resolved on first use, not at load: which addons have registered fonts is not
-- settled while this file is still being read.
--
-- MEMOISED, and that is not an optimisation. The dropdown calls a callable
-- `choices` on every open so a live label stays live; this list builds a Font
-- object per row, and a fresh set of those on every open would be a permanent
-- global per font per look. Built once, then handed back.
local fontChoices

local function FontChoices()
    if fontChoices then return fontChoices end

    local out, seen = {}, {}
    for _, entry in ipairs(SHIPPED_FONTS) do
        out[#out + 1] = Sampled(entry)
        seen[entry.value] = true
    end

    -- Guarded member by member, like every other optional API: an old copy of
    -- the library brought in by some other addon is a likelier thing to meet
    -- than no copy at all. The list comes back sorted, which is what makes the
    -- letter ranges below mean anything.
    local extra = {}
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM and LSM.List and LSM.Fetch then
        for _, name in ipairs(LSM:List("font") or {}) do
            -- The third argument is "do not hand me the default instead", so a
            -- name that resolves to nothing is skipped rather than listed a
            -- dozen times over as the same file.
            local path = LSM:Fetch("font", name, true)
            if path and not seen[path] then
                extra[#extra + 1] = { value = path, label = name }
                seen[path] = true
            end
        end
    end

    -- One flat run while there are few enough to read at a glance; grouped once
    -- there are not. The threshold is the same number the groups are sized to,
    -- so a list of nineteen does not become two submenus of ten.
    if #extra <= FONT_GROUP then
        for _, entry in ipairs(extra) do out[#out + 1] = Sampled(entry) end
    else
        for first = 1, #extra, FONT_GROUP do
            local last, group = min(first + FONT_GROUP - 1, #extra), {}
            for i = first, last do group[#group + 1] = Sampled(extra[i]) end
            -- Off the RAW names, before the sample was appended to them: the
            -- first letter is the same either way, but the intent is not.
            out[#out + 1] = {
                label = LetterRange(extra[first].label, extra[last].label),
                entries = group,
            }
        end
    end

    -- A saved font that is not on the list any more - its addon was removed -
    -- still has to name itself in the box, or the dropdown falls back to
    -- showing the raw value. The file name rather than the path: the box is a
    -- hundred and fifty pixels wide.
    local saved = ns.db and ns.db.badgeFont
    if saved and saved ~= "" and not seen[saved] then
        out[#out + 1] = Sampled({ value = saved,
                                  label = saved:match("([^\\/]+)$") or "Custom" })
    end

    fontChoices = out
    return out
end

--------------------------------------------------------------------------------
-- The badge preview
--
-- A grey rectangle standing in for a nameplate, with a real badge over it and a
-- damage share climbing past the threshold on a loop, so the settings under
-- it can be watched rather than guessed at and applied one reload at a time.
--
-- The rectangle is deliberately a rectangle. The addon can never measure a real
-- nameplate (see the client rules in AGENTS.md), every nameplate addon draws a
-- different thing inside the frame the badge actually hangs off, and what this
-- has to show is where the badge lands relative to that frame - which is what a
-- plain box at roughly a plate's size says and a drawing of a health bar would
-- only dress up.
--
-- Everything ON it comes from the core: the anchor, the font, the text, the
-- colour and the slam. A preview that graded or placed a share by its own rules
-- would be a preview of nothing.
--------------------------------------------------------------------------------

-- The preview draws two rectangles' worth of geometry, and only one of them can
-- be seen.
--
-- The badge anchors to the Blizzard BASE nameplate frame, which is WIDER than
-- the bar any nameplate addon actually draws inside it - crossing that gap is
-- what C.BADGE_SIDE_INSET exists for. Drawing the visible rectangle at the base
-- frame's size therefore lied in the one direction that matters: the badge came
-- out sitting on top of the plate here while standing clear of it in game.
--
-- So `anchor` is the base frame, invisible, and `plate` is the bar drawn inside
-- it, narrower by this much a side.
--
-- Its OWN number, deliberately not C.BADGE_SIDE_INSET. The two look alike and
-- are not: the inset is how far the badge hangs off the base frame, and this is
-- how much wider that frame is than the bar. Tying them together was what made
-- moving one of them move the other for no reason. Neither is a measurement -
-- every nameplate addon picks its own geometry, which is what the offset
-- sliders are for - so this is a catch-all for what an untouched plate looks
-- like.
--
-- Horizontal only. The vertical anchors clear the frame by 4px rather than by
-- the inset, and above and below already read correctly.
local PLATE_W, PLATE_H = 188, 40
local PLATE_INSET = 7

-- Room around the plate for a badge beside it. The offsets reach forty pixels
-- and this still does not quite, deliberately: a box tall enough to hold the
-- extremes would be mostly empty every other minute of its life, and the
-- clipping below is what shows an extreme one leaving.
local PREVIEW_H = 150

-- Everything inside the preview is drawn a little under size, so the plate and
-- its badge read as a thing being looked at rather than as another row of the
-- window. On a wrapper frame rather than on the plate, because the badge is
-- parented beside the plate and not to it, and a scale on one of the two would
-- pull them apart.
local PREVIEW_SCALE = 0.8

-- The sweep. Bursts rather than a smooth climb because that is what damage
-- does: a share jumps by whatever the last hit was worth and then sits there,
-- and a bar sliding evenly upward would be a picture of something else.
local SWEEP_FROM = 10
local SWEEP_MIN_BURST, SWEEP_MAX_BURST = 3, 6
local SWEEP_TO    = 60     -- unless the threshold is set past it; see SweepTop
local SWEEP_HOLD  = 0.7    -- seconds a share stays up before the next hit
local SWEEP_PAUSE = 1.8    -- on the finished checkmark, before it starts over

-- Held on one share while a dropdown that wants to be compared against a steady
-- number is open - the font list, where a percentage moving under you is the
-- one thing that makes two fonts hard to tell apart. Keyed by the dropdown
-- frame, which is what FrameXML names in UIDROPDOWNMENU_OPEN_MENU.
local previewHolds = {}

local function HeldShare()
    -- Both halves: the global is not cleared when a menu closes, so on its own
    -- it would pin the preview for the rest of the session after one look.
    if not (DropDownList1 and DropDownList1:IsShown()) then return nil end
    local open = UIDROPDOWNMENU_OPEN_MENU
    return open and previewHolds[open]
end

-- Where the sweep turns round. Normally 60, which clears the default threshold
-- comfortably - but somebody who has set theirs to 80 would otherwise watch a
-- preview that never reaches a checkmark, which is the one moment it exists to
-- show.
local function SweepTop()
    local need = (ns.db and ns.db.threshold) or C.THRESHOLD_DEFAULT
    return max(SWEEP_TO, ceil(need) + SWEEP_MAX_BURST)
end

local function ShowPreviewShare(area, pct)
    local badge = area.badge
    local need = (ns.db and ns.db.threshold) or C.THRESHOLD_DEFAULT

    if pct < need then
        area.stamped = nil
        badge.check:Hide()
        -- The core's own draw: number, colour, warning icon, where each of them
        -- sits, and the pop-in when the badge was showing nothing. Nothing
        -- about the badge is decided in this file.
        ns.DrawBadgeShare(badge, pct)
    elseif not area.stamped then
        -- Once, on the step that crosses. The stamp is the sound of the
        -- threshold being met, and replaying it on every step above the
        -- threshold would turn one event into five.
        area.stamped = true
        ns.ShowBadgeCheck(badge, true)   -- shows the check and hides the number
    end
end

local function SweepPreview(area, elapsed)
    -- Pinned while a dropdown asked for it, and picked up again where it left
    -- off once that closes - restarting the sweep would throw away the frame
    -- somebody was looking at.
    local held = HeldShare()
    if held ~= area.held then
        area.held = held
        ShowPreviewShare(area, held or area.pct)
    end
    if held then return end

    area.since = area.since + elapsed
    local top = SweepTop()
    local done = area.pct >= top
    if area.since < (done and SWEEP_PAUSE or SWEEP_HOLD) then return end

    area.since = 0
    if done then
        -- Wiped before it starts again, so the first share of the next run
        -- arrives out of nothing and pops in the way a real one does on a mob
        -- taking its first hit. Without this the loop would only ever show the
        -- badge changing, never appearing.
        area.pct = SWEEP_FROM
        ns.BlankBadge(area.badge)
    else
        -- min, because a burst can overshoot the top and because the threshold
        -- can be lowered while this runs, taking the top under where the sweep
        -- already got to.
        area.pct = min(area.pct + math.random(SWEEP_MIN_BURST, SWEEP_MAX_BURST), top)
    end
    ShowPreviewShare(area, area.pct)
end

-- Where the badge sits and what it is drawn in, both straight off the core, so
-- a change to either lands on the preview the same pass it lands on a plate.
local function RefreshBadgePreview(box)
    local area = box.preview
    if not area then return end
    -- One call, and the same one a real plate gets: anchor, font and which edge
    -- the contents are pinned to.
    ns.ApplyBadgeStyle(area.badge, area.anchor)
    -- Redrawn at whatever the sweep is on - or at the share a dropdown is
    -- holding it to - so a font or a threshold change shows now instead of at
    -- the next burst.
    ShowPreviewShare(area, area.held or area.pct)
end

local function BuildBadgePreview(box)
    -- The strip above the box's rows, reserved before any of them is created -
    -- a row anchors once and will not move for this afterwards.
    UI.ReserveSectionStrip(box, PREVIEW_H)

    local area = CreateFrame("Frame", nil, box)
    area:SetFrameLevel(box:GetFrameLevel() + 1)
    area:SetPoint("TOPLEFT", UI.BOX_PAD, -(UI.BOX_PAD + UI.SECTION_TITLE_H))
    area:SetPoint("TOPRIGHT", -UI.BOX_PAD, -(UI.BOX_PAD + UI.SECTION_TITLE_H))
    area:SetHeight(PREVIEW_H)
    -- The offsets reach forty pixels each way, which is further than this box
    -- is tall. Clipped, so an extreme one is seen leaving the frame instead of
    -- being drawn over the rows underneath. Guarded on its own like every other
    -- optional API member; without it the badge simply hangs over the edge.
    if area.SetClipsChildren then area:SetClipsChildren(true) end

    -- The scaled stage. Both the plate and the badge hang off this rather than
    -- off the area, so the two shrink together and the clipping above still
    -- happens at the unscaled edge of the box.
    local stage = CreateFrame("Frame", nil, area)
    stage:SetAllPoints()
    stage:SetScale(PREVIEW_SCALE)

    -- The base plate frame: what the badge is anchored to, and never drawn.
    -- See the note on PLATE_INSET for why it is wider than the bar inside it.
    local anchor = CreateFrame("Frame", nil, stage)
    anchor:SetFrameLevel(area:GetFrameLevel() + 1)
    anchor:SetSize(PLATE_W + 2 * PLATE_INSET, PLATE_H)
    anchor:SetPoint("CENTER")

    local plate = CreateFrame("Frame", nil, anchor)
    plate:SetFrameLevel(anchor:GetFrameLevel())
    plate:SetSize(PLATE_W, PLATE_H)
    plate:SetPoint("CENTER")

    local fill = plate:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetColorTexture(0.30, 0.30, 0.33, 1)

    local caption = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("CENTER")
    caption:SetText("Nameplate")
    caption:SetTextColor(0.75, 0.75, 0.75)

    -- Parented to the stage rather than to either rectangle, and a level above
    -- them both, so an offset that walks the badge back over the plate draws on
    -- top of it rather than behind it. The core anchors it to `anchor` all the
    -- same - SetPoint does not care who the parent is.
    --
    -- The same four regions the core builds on a real plate, under the same
    -- names, because ApplyBadgeStyle and DrawBadgeShare are what dress them.
    -- Sizes and points come from the style too, so none are set here.
    local badge = CreateFrame("Frame", nil, stage)
    badge:SetFrameLevel(area:GetFrameLevel() + 2)

    badge.check = badge:CreateTexture(nil, "OVERLAY")
    badge.check:SetTexture(C.CHECK_TEXTURE)
    badge.check:SetAllPoints(badge)
    badge.check:Hide()

    badge.icon = badge:CreateTexture(nil, "OVERLAY")
    badge.icon:SetTexture(C.WARN_TEXTURE)
    badge.icon:Hide()

    -- Never shown here - the preview has no stolen tags to report - but a badge
    -- the core is handed has to be a whole badge, or BlankBadge trips over the
    -- one region this frame did not bother to have.
    badge.deny = badge:CreateTexture(nil, "OVERLAY")
    badge.deny:SetTexture(C.X_TEXTURE)
    badge.deny:SetAllPoints(badge)
    badge.deny:Hide()

    badge.text = badge:CreateFontString(nil, "OVERLAY")

    area.anchor, area.badge = anchor, badge
    area.pct, area.since = SWEEP_FROM, 0

    -- A hidden frame gets no OnUpdate, so the sweep stops on its own the moment
    -- another tab is picked and costs nothing at all while the window is shut.
    -- Wrapped for the same reason the window's own ticker is: an error on a
    -- per-frame script repeats into the chat frame rather than happens.
    area:SetScript("OnUpdate", function(self, elapsed)
        SafeCall(SweepPreview, self, elapsed)
    end)

    box.preview = area
    -- Anchored and dressed here rather than left for the first refresh: an
    -- unanchored badge with no font on it is a frame that draws nowhere.
    RefreshBadgePreview(box)
end

--------------------------------------------------------------------------------
-- Follow binds
--
-- One action, reachable two ways: a key bound straight to the addon's secure
-- button, and a plain macro you can drag to a bar. Both run the same text out
-- of BuildFollowMacro, so there is nothing to keep in step - the macro window
-- is a copy of what the key already does.
--
-- The keybind pop-up is here rather than in the kit because the thing it binds
-- is TagTeam's: it names one action and offers no way to pick another, which
-- is the whole reason it is smaller than the Key Bindings panel it saves you a
-- trip to.
--------------------------------------------------------------------------------

-- What Bindings.xml declares. One string, so the pop-up, the label and the
-- clear button cannot drift onto different actions.
local BIND_ACTION = "CLICK TagTeamFollowButton:LeftButton"

local MACRO_WINDOW_W, MACRO_WINDOW_H = 380, 250
local BIND_POPUP_W,  BIND_POPUP_H    = 320, 150
local BIND_BTN_W = 90

-- Modifier keys on their own are not a binding, they are half of one: a
-- pop-up that closed on the SHIFT of SHIFT-F would bind SHIFT and never see
-- the F.
local BARE_MODIFIERS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, UNKNOWN = true,
}

-- PARENTHESISED. An unbound action makes GetBindingKey return *nothing* rather
-- than nil, and a bare `return GetBindingKey(...)` passes that emptiness on -
-- which reaches tostring() in the refresh signature as no argument at all.
-- The parentheses truncate the call to exactly one value, nil included.
local function BoundKey()
    return (GetBindingKey(BIND_ACTION))
end

-- Written out, not abbreviated. GetBindingText on the whole string gives back
-- the game's own shorthand - "c+spacebar" for CTRL-SPACE - which is what the
-- Key Bindings panel wants in a narrow column and not what a settings row
-- wants on a line of its own.
local MODIFIER_TEXT = { ALT = "Alt", CTRL = "Ctrl", SHIFT = "Shift" }

-- "CTRL-SPACE" -> "Ctrl + Spacebar".
local function PrettyKey(key)
    if not key or key == "" then return nil end

    local parts, rest = {}, key
    -- Modifiers come off the FRONT one at a time rather than splitting the
    -- whole string on "-": the base key can itself be "-", and CTRL-ALT--
    -- would otherwise come apart into empty pieces.
    while true do
        local mod, tail = strmatch(rest, "^(%u+)%-(.+)$")
        if not (mod and MODIFIER_TEXT[mod]) then break end
        parts[#parts + 1] = MODIFIER_TEXT[mod]
        rest = tail
    end

    -- Only the base key goes through the game's names, which is where SPACE
    -- becomes "Spacebar" and BUTTON3 becomes "Middle Mouse".
    parts[#parts + 1] = (GetBindingText and GetBindingText(rest, "KEY_")) or rest
    return table.concat(parts, " + ")
end

local function BoundKeyText()
    -- Greyed rather than absent: the row has to say something in the column
    -- where the key goes, or it reads as having failed to draw.
    return PrettyKey(BoundKey()) or "|cff808080Not bound|r"
end

local macroWindow    -- the copyable-macro window, built on first use
local bindPopup      -- and the key-capture pop-up, likewise

local function ShowMacroWindow()
    if not macroWindow then
        local f = UI.CreateWindow("TagTeamMacroFrame", MACRO_WINDOW_W,
            MACRO_WINDOW_H, "Follow macro")

        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        hint:SetPoint("TOPLEFT", UI.BOX_PAD + 4, -(f.titleBarHeight + UI.INSET + 6))
        hint:SetPoint("TOPRIGHT", -(UI.BOX_PAD + 4),
            -(f.titleBarHeight + UI.INSET + 6))
        hint:SetJustifyH("LEFT")
        hint:SetText("Ctrl+C to copy, then paste it into a macro.")

        local scroll = CreateFrame("ScrollFrame", "TagTeamMacroScroll", f,
            "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
        scroll:SetPoint("BOTTOMRIGHT", -(UI.SCROLLBAR_W + 4), UI.INSET + 34)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(MACRO_WINDOW_W - UI.SCROLLBAR_W - UI.BOX_PAD * 2 - 12)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        close:SetSize(BIND_BTN_W, 22)
        close:SetPoint("BOTTOM", 0, UI.INSET + 6)
        close:SetText(CLOSE)
        close:SetScript("OnClick", function() f:Hide() end)

        macroWindow = f
    end

    -- Rebuilt on every open, never cached: the roster it is made of changes
    -- while this window is closed, and a stale macro is a macro that follows
    -- somebody you dropped an hour ago.
    macroWindow.edit:SetText(BuildFollowMacro() or "/follow")
    macroWindow.edit:HighlightText()
    macroWindow.edit:SetFocus()
    macroWindow:Show()
end

local function SetFollowBind(key)
    -- SetBinding only clears the KEY it is given, so the old one has to go by
    -- hand or the action ends up on two keys and the label can only show one.
    local old = BoundKey()
    if old then SetBinding(old) end
    if key then SetBinding(key, BIND_ACTION) end
    SaveBindings(GetCurrentBindingSet())
    ns.RefreshView()
end

local function ShowBindPopup()
    if not bindPopup then
        local p = UI.CreateWindow("TagTeamBindPopup", BIND_POPUP_W,
            BIND_POPUP_H, "", true)
        -- Above DIALOG, so it lands on top of the window that opened it.
        p:SetFrameStrata("FULLSCREEN_DIALOG")

        local heading = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        heading:SetPoint("TOPLEFT", UI.BOX_PAD + 6, -(UI.INSET + 12))
        heading:SetPoint("TOPRIGHT", -(UI.BOX_PAD + 6), -(UI.INSET + 12))
        heading:SetJustifyH("CENTER")
        heading:SetText("Press a key to follow")

        local current = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        current:SetPoint("TOP", heading, "BOTTOM", 0, -14)
        p.current = current

        local note = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        note:SetPoint("TOP", current, "BOTTOM", 0, -8)
        note:SetText("Escape cancels.")

        local cancel = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        cancel:SetSize(BIND_BTN_W, 22)
        cancel:SetPoint("BOTTOMLEFT", UI.BOX_PAD + 6, UI.INSET + 8)
        cancel:SetText(CANCEL)
        cancel:SetScript("OnClick", function() p:Hide() end)

        local clear = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        clear:SetSize(BIND_BTN_W, 22)
        clear:SetPoint("BOTTOMRIGHT", -(UI.BOX_PAD + 6), UI.INSET + 8)
        clear:SetText("Clear")
        clear:SetScript("OnClick", function()
            p:Hide()
            SetFollowBind(nil)
        end)

        -- The pop-up eats every key while it is up, which is the point: a
        -- capture that let W through would walk you off a cliff mid-bind.
        p:EnableKeyboard(true)
        if p.SetPropagateKeyboardInput then p:SetPropagateKeyboardInput(false) end
        p:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then self:Hide(); return end
            if BARE_MODIFIERS[key] then return end
            local prefix = ""
            if IsAltKeyDown()     then prefix = prefix .. "ALT-" end
            if IsControlKeyDown() then prefix = prefix .. "CTRL-" end
            if IsShiftKeyDown()   then prefix = prefix .. "SHIFT-" end
            self:Hide()
            SetFollowBind(prefix .. key)
        end)

        bindPopup = p
    end

    bindPopup.current:SetText("Currently: |cffffffff" .. BoundKeyText() .. "|r")
    bindPopup:Show()
end

local OPTION_PAGES = {
    general = {
        {
            title = "Tracking",
            Reset = function() ns.ResetTrackingOptions() end,
            -- Both handles start in one column instead of each one starting
            -- where its own caption happened to end. Two sliders one above the
            -- other with their handles at different x read as two unrelated
            -- controls, and dragging either would slide the other's handle
            -- sideways as the caption's digits changed width. Comfortably wider
            -- than the longest caption at its longest value: a handle butted up
            -- against the "%" reads as part of the number rather than as the
            -- control that sets it.
            labelW = 202,
            rows = {
                -- Both targets share one range, and it is the range the XP
                -- curve actually bends over. Outside it there is nothing to
                -- tune: under the floor every kill is a write-off, over the
                -- ceiling the mob pays in full whatever you do.
                -- White on the number alone: the caption is the same on every
                -- pass and the figure is the part that just moved.
                { db = "shareMin",
                  label = "Minimum Damage Target: |cffffffff%.1f%%|r",
                  slider = { min = C.TARGET_MIN, max = C.TARGET_MAX, step = 0.5 },
                  after = "plates", Note = TargetXPNote,
                  about = "The damage required by taggers before the "
                       .. C.WARN_ICON .. " is removed from an enemy nameplate." },
                { db = "threshold",
                  label = "Ideal Damage Target: |cffffffff%.1f%%|r",
                  Note = TargetXPNote,
                  slider = { min = C.TARGET_MIN, max = C.TARGET_MAX, step = 0.5 },
                  -- Repainted on every step rather than waiting for the push
                  -- below to land: the badges are what somebody is watching
                  -- while they drag this.
                  after = "plates",
                  about = "The damage required by taggers to produce a "
                       .. C.CHECK_ICON .. " on enemy nameplate.",
                  -- Throttled, because this one does not just write a db field:
                  -- it whispers the other client. A drag across the range steps
                  -- a dozen times, and a dozen addon messages to say what the
                  -- last one says is how you get muted by the server.
                  Set = function(value) PushThresholdSoon(value) end },
                -- Saved as nil for auto, because "no opinion" is what auto
                -- means and a stored "auto" would be a third state to keep in
                -- step with the two real ones. Get/Set carry the translation.
                { db = "continent", label = "Levelling Zone:", width = 150,
                  choices = ZoneChoices,
                  Get = function() return ns.db.continent or "auto" end,
                  Set = function(value)
                      ns.db.continent = value ~= "auto" and value or nil
                      SafeCall(ns.RefreshContinent)
                  end,
                  about = "Which continent's XP formula an estimate is built "
                       .. "on." },
            },
        },
        {
            -- The two lines TagTeam writes to chat, together, above the rules
            -- that change what it does. Both are about what you get told, not
            -- about how a kill is measured or who you end up grouped with.
            title = "Chat",
            rows = {
                { db = "announce",
                  label = "Show full xp breakdown in chat upon kill",
                  about = "One line per kill, with what it paid." },
                { db = "focusWarning", label = "Set Focus Reminders",
                  about = "Reminds you when focus isn't set on your partner, if "
                       .. "|cffffd100Use focus for range detection|r is enabled.",
                  requires = "HAS_FOCUS" },
                { db = "slashHelp", label = "/Tag prints chat commands",
                  about = "Using /tag will both open this window AND print "
                       .. "commands in chat. Use /tag help when disabled for "
                       .. "chat commands." },
            },
        },
        {
            title = "Grouping rules",
            rows = {
                { db = "autoInvite", label = "Ask for an invite when out of range",
                  about = "Automatically request an invite when out of range of "
                       .. "your tagger for more than 30 seconds, or when focus "
                       .. "is lost (if enabled)." },
                { db = "autoLeave", label = "Leave the party once back in range",
                  about = "Grouping with taggers can destroy their xp earned, "
                       .. "enabling this causes the party to be disbanded "
                       .. "automatically once combat is over." },
                { db = "autoLoot",
                  label = "Use FFA loot when partied with tagteam partners",
                  about = "Automatically sets the Loot mode to "
                       .. "|cff00ff00Free for all|r when partied exclusively "
                       .. "with players listed in TagTeam." },
                -- Here rather than on the Nameplate tab, which is about the
                -- badge: this marker goes on a PERSON, and finding your tagger
                -- is a party problem whichever way round you solve it.
                { db = "taggerMarker", label = "Mark taggers while ungrouped",
                  about = "Marks your partner with a " .. C.MARKER_ICON
                       .. " when ungrouped to help you find them.",
                  after = "markers" },
                { db = "autoFocus", label = "Use focus for range detection",
                  about = "Auto-party with your partner when their "
                       .. "Focus-target status is lost. Helps you quickly find "
                       .. "your partner when separated. Requires /focus to be "
                       .. "set via macro or keybind features below. Might "
                       .. "backfire when using invisibility.",
                  -- Classic Era has no focus unit at all.
                  requires = "HAS_FOCUS", after = "macro" },
            },
        },
        {
            -- Last on the tab, because it is the one box that is about a key
            -- rather than about the addon's behaviour: everything above
            -- changes what TagTeam does, this changes how you reach it.
            title = "Follow Binds",
            -- Both rows' contents start in one column. Without it the bound
            -- key would begin where "Follow Keybind:" happens to end and the
            -- Macro button where "Generate Macro:" does, which is two captions
            -- of different lengths putting their contents at two different x.
            labelW = 118,
            rows = {
                -- The key it is bound to is the read-out; the button is what
                -- changes it, and it says which of the two jobs it is doing.
                { label = "Follow Keybind:", Value = BoundKeyText,
                  Button = function()
                      return BoundKey() and "Rebind" or "Set Key"
                  end,
                  width = 100, OnClick = ShowBindPopup,
                  about = "One key that targets, focuses and follows down the "
                       .. "list below. The same binding as Key Bindings > "
                       .. "TagTeam, set from here." },
                { db = "followFocus", after = "macro", requires = "HAS_FOCUS",
                  label = "Set focus target on Taggers and Carries",
                  about = "The key sets focus as well as following, which is "
                       .. "what makes the range check reliable. Setting focus "
                       .. "is protected, so this only works from the key." },
                { db = "followFocusFallback", after = "macro",
                  requires = "HAS_FOCUS",
                  label = "Follow focus target when no others exist",
                  about = "With nobody from the lists in range, follow whoever "
                       .. "is focused." },
                { db = "followTargetFallback", after = "macro",
                  label = "Follow target when no others exist",
                  about = "The last resort, and what the key did before any of "
                       .. "this: follow whoever you have targeted." },
                -- The same text the key runs, for a bar button or another
                -- addon. Built fresh on open, so it is never a stale copy.
                { label = "Generate Macro:", Button = function() return "Macro" end,
                  width = 100, OnClick = ShowMacroWindow,
                  about = "The follow macro as text, ready to copy into a "
                       .. "macro of your own. /focus will not work from a "
                       .. "normal macro - only the keybind above can set it." },
            },
        },
    },

    popups = {
        {
            -- Labelled by the mark each one draws, because that is how somebody
            -- arrives here: they saw a thing over a mob and want it gone, or
            -- want to know which switch it was. The row and the burst carry the
            -- same icon so there is nothing to translate.
            title = "Screen Bursts",
            -- Icon, flag, test and sound all come off C.BURSTS, so a row here
            -- names the kind and nothing else can drift from what fires.
            rows = {
                { db = "fullAlert", test = "tagged",
                  icon = C.BURSTS.tagged.tex,
                  label = "Full XP Kill",
                  about = "Displays a " .. C.CHECK_ICON .. " Screen Burst with "
                       .. "XP info when an enemy was killed with an ideal "
                       .. "amount of damage applied to it." },
                { db = "nearAlert", test = "short",
                  icon = C.BURSTS.short.tex, cue = C.BURSTS.short.cue,
                  label = "Acceptable XP Kill",
                  about = "Displays a " .. C.WARN_ICON .. " Screen Burst with "
                       .. "XP info when an enemy was killed with less than the "
                       .. "ideal amount of damage, but more than the minimum." },
                { db = "missAlert", test = "failed",
                  icon = C.BURSTS.failed.tex, cue = C.BURSTS.failed.cue,
                  label = "Low XP Kill",
                  about = "Displays a " .. C.X_ICON .. " Screen Burst with XP "
                       .. "info when an enemy was killed with less than the "
                       .. "minimum amount of damage applied to it." },
                { db = "stealWarning", test = "mistag",
                  icon = C.BURSTS.mistag.tex, cue = C.BURSTS.mistag.cue,
                  label = "Mistag Warning",
                  about = "Displays a " .. C.X_ICON .. " Screen Burst when you "
                       .. "tap an enemy before your taggers do, so nothing they "
                       .. "do to it afterwards can pay." },
                { db = "groupWarning", test = "grouped",
                  icon = C.BURSTS.grouped.tex,
                  label = "Grouped Warning",
                  about = "Displays a " .. C.WARN_ICON .. " Screen Burst when a "
                       .. "kill was made while you were grouped, splitting the "
                       .. "XP your taggers earned." },
            },
        },
        {
            -- One flag per kind, not one for the lot. They were one, which
            -- meant silencing the objective spam - the chattiest thing on the
            -- channel - also silenced hand-ins, which are XP reports.
            title = "Quests",
            rows = {
                { db = "questProgress", test = "progress",
                  questIcon = "progress",
                  cue = C.QUEST_NOTICES.progress.cue,
                  label = "Quest Progress",
                  about = "Displays a " .. C.QUEST_ICONS.progress .. " Screen "
                       .. "Notice when a quest objective ticks over on your "
                       .. "partner's screen." },
                { db = "questComplete", test = "complete",
                  questIcon = "complete",
                  cue = C.QUEST_NOTICES.complete.cue,
                  label = "Quest Completion",
                  about = "Displays a " .. C.QUEST_ICONS.complete .. " Screen "
                       .. "Notice with XP info when your partner hands a quest "
                       .. "in. The XP is counted either way." },
                { db = "questAccepted", test = "accepted",
                  questIcon = "accepted",
                  cue = C.QUEST_NOTICES.accepted.cue,
                  label = "Quest Accepted",
                  about = "Displays a " .. C.QUEST_ICONS.accepted .. " Screen "
                       .. "Notice when your partner picks up or abandons a "
                       .. "quest." },
            },
        },
        {
            title = "Windows",
            rows = {
                { db = "levelPopup", label = "Pop up when your tagger levels",
                  about = "Displays a window with the level's summary when a "
                       .. "tagger levels up. Still announced in chat when "
                       .. "disabled." },
            },
        },
    },

    ignore = {
        -- The two blanket switches first, then the two by-name lists: broadest
        -- rule at the top, exceptions under it.
        {
            title = "Skip entirely",
            rows = {
                { db = "ignorePvP", label = "Ignore PvP-flagged mobs",
                  about = "Mobs another player has tagged in a PvP context are "
                       .. "not yours to measure." },
                { db = "instanceOff",
                  label = "Ignore in dungeons and raids",
                  about = "Inside an instance the carry and the tagger are "
                       .. "necessarily grouped, so a tag earns almost nothing." },
            },
        },
        {
            title = "Ignored mobs",
            mobs = {
                noun  = "an ignored mob",
                empty = "No mobs ignored.",
                add   = "Ignore a mob by name - no badge, no cue, no XP, "
                     .. "no stolen-tag warning.",
                List  = function() return Mobs.Banned() end,
                Add   = function(name) Mobs.Ban(name) end,
                Drop  = function(key) Mobs.Unban(key) end,
            },
            Reset = function() Mobs.ResetBanned() end,
        },
        {
            title = "Auto-tagged mobs",
            mobs = {
                noun  = "an auto-tagged mob",
                empty = "No mobs auto-tagged.",
                -- The distinction that matters, and the reason these are two
                -- lists rather than one: an ignored mob pays nothing and is
                -- dropped; an auto-tagged one pays in full and still has to
                -- clear the threshold. Only the TAP stops mattering.
                add   = "Mobs your tagger keeps credit on without tapping "
                     .. "first. They still have to reach the threshold.",
                List  = function() return Mobs.AutoTagged() end,
                Add   = function(name) Mobs.AddAutoTag(name) end,
                Drop  = function(key) Mobs.DropAutoTag(key) end,
            },
            Reset = function() Mobs.ResetAutoTagged() end,
        },
    },

    nameplate = {
        {
            title = "Badge",
            -- The preview is this box's first row in everything but name: a
            -- picture of what the rows under it do, sitting where a reader
            -- looks first. It gets no label of its own because "Preview" over a
            -- picture of a nameplate says nothing the picture did not.
            Build = BuildBadgePreview,
            Refresh = RefreshBadgePreview,
            -- Straight back to how it shipped. In the core, because that is
            -- where the defaults are and a second copy of them out here would
            -- be a second answer to what "default" means.
            Reset = function() ns.ResetBadgeOptions() end,
            -- The controls line up in one column instead of each starting
            -- where its own label happened to end. Worth the number here and
            -- nowhere else: this is the only box with more than one of them.
            labelW = 108,
            rows = {
                -- The `about` strings on this page are ONE SENTENCE each, on
                -- purpose. Ten rows of paragraph-length tooltips is a wall
                -- nobody reads; what a control does is the part somebody
                -- hovering wants, and why it does it belongs in the source.
                { db = "badgePos", label = "Badge Position",
                  choices = BADGE_CHOICES,
                  -- Through the core, which also zeroes the offsets and flips
                  -- "Text before Icon" to suit the new side - all of it in one
                  -- place, rather than half here and half wherever else the
                  -- position ever gets set from.
                  Set = function(value) ns.SetBadgePosition(value) end,
                  about = "Which side of the nameplate the damage-share badge "
                       .. "sits on." },
                -- The badge hangs off Blizzard's base nameplate frame, which is
                -- wider than the bar most nameplate addons actually draw, so
                -- the four positions do not land the same way for everyone.
                -- C.BADGE_SIDE_INSET carries the common case; these are for the
                -- plate that puts its bar somewhere else entirely.
                { db = "badgeX", label = "X Offset: %.0f",
                  slider = { min = -C.BADGE_NUDGE_LIMIT,
                             max =  C.BADGE_NUDGE_LIMIT, step = 1 },
                  after = "plates",
                  about = "Nudge the badge sideways, in pixels." },
                { db = "badgeY", label = "Y Offset: %.0f",
                  slider = { min = -C.BADGE_NUDGE_LIMIT,
                             max =  C.BADGE_NUDGE_LIMIT, step = 1 },
                  after = "plates",
                  about = "Nudge the badge up or down, in pixels." },
                { db = "badgeFont", label = "Badge Font",
                  choices = FontChoices, width = 150, after = "plates",
                  -- The preview stops sweeping and sits on one share while
                  -- this list is open: two fonts are hard to tell apart when
                  -- the number under them keeps changing.
                  holdPreview = 25,
                  about = "The font the percentage is drawn in." },
                { db = "badgeFontSize", label = "Font Size: %.0f",
                  slider = { min = C.BADGE_FONT_MIN,
                             max = C.BADGE_FONT_MAX, step = 1 },
                  after = "plates",
                  about = "How big the percentage is drawn." },
                { db = "badgePercent", label = "Show '%' Character",
                  after = "plates",
                  about = "Add the percentage symbol to tagger's damage "
                       .. "output." },
                -- Above the switch that governs the other two, because it is
                -- not governed by it: this sizes the checkmark and the X as
                -- well, so it still does something with the warning icon off.
                { db = "badgeIconSize", label = "Icon Size: %.0f",
                  slider = { min = C.BADGE_SIZE_MIN,
                             max = C.BADGE_SIZE_MAX, step = 1 },
                  after = "plates",
                  -- Named by drawing them. Three marks described in words is a
                  -- sentence you have to translate back into what you saw over
                  -- a mob; the marks themselves are not.
                  about = "How big the badge's marks are - " .. C.CHECK_ICON
                       .. " " .. C.X_ICON .. " " .. C.WARN_ICON .. " alike." },
                { db = "badgeWarnIcon",
                  label = "Use " .. C.WARN_ICON .. " Icon when below lower threshold",
                  after = "plates",
                  about = "Display a warning icon when tagger's minimum damage "
                       .. "threshold hasn't been met yet." },
                -- Both are about an icon that is not being drawn once the row
                -- above is off. Greyed with a reason rather than hidden: a row
                -- that vanishes makes the box jump and takes the explanation
                -- with it.
                { db = "badgeGap", label = "Icon Padding: %.0f",
                  slider = { min = 0, max = C.BADGE_GAP_MAX, step = 1 },
                  after = "plates", needs = "badgeWarnIcon",
                  about = "The gap between the warning icon and the number "
                       .. "beside it, in pixels." },
                { db = "badgeTextFirst", label = "Text before Icon",
                  after = "plates", needs = "badgeWarnIcon",
                  about = "Put the percentage before the warning icon rather "
                       .. "than after it." },
            },
        },
    },
}

--------------------------------------------------------------------------------
-- The two named-mob lists
--
-- A box of names with a [+] in its header and a bin on every row. The lists
-- themselves are ns.Mobs' business - the tri-state storage behind them has one
-- correct way to be written, and this file writing db.banlist directly would be
-- the second implementation of it.
--
-- No "clear all". These are lists somebody curates a name at a time over
-- weeks, and the shipped entries are in them; one mis-click emptying the lot is
-- a worse outcome than removing four names by hand.
--
-- Their own scroll rather than letting the box grow: two lists with no natural
-- ceiling on one page, and without it a long one pushes the other off the
-- bottom and you scroll the whole tab to reach it.
--------------------------------------------------------------------------------

local MOB_ROWS_MAX = 5   -- rows before the box stops growing and scrolls

local function AskMob(spec)
    if not prompt then prompt = UI.CreatePrompt("TagTeamPromptFrame") end
    prompt:Ask({
        title  = "Add " .. spec.noun,
        hint   = "Mob name",
        accept = "Add",
        OnAccept = function(text)
            spec.Add(text)
            ns.RefreshView()
        end,
    })
end

local function DressMobRow(box, index)
    local row = UI.CreateSectionRow(box, index)
    if row.label then return row end

    row.remove = UI.CreateCloseButton(row, UI.ROW_ICON, 0.35)
    row.remove:SetPoint("RIGHT", -2, 0)
    UI.AddTooltip(row.remove, "Remove", "Take this mob off the list.")

    -- Which entries shipped with the addon. Worth saying: removing one of ours
    -- is remembered as an override rather than a deletion, and somebody
    -- wondering why a name they never added is on the list deserves an answer.
    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.note:SetPoint("RIGHT", row.remove, "LEFT", -6, 0)
    row.note:SetTextColor(0.5, 0.5, 0.5)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("LEFT", 6, 0)
    row.label:SetPoint("RIGHT", row.note, "LEFT", -6, 0)
    row.label:SetJustifyH("LEFT")
    return row
end

local function BuildMobBox(box, spec, globalName)
    UI.AddHeaderTextButton(box, "Add (+)", "Add", spec.add,
        function() AskMob(spec) end)
    spec.hint = UI.CreateEmptyHint(box)
    spec.hint:SetText(spec.empty)
    UI.ScrollSectionRows(box, globalName, MOB_ROWS_MAX)
end

local function RefreshMobBox(box, spec)
    local list = spec.List()
    for i, entry in ipairs(list) do
        local row = DressMobRow(box, i)
        row.label:SetText(entry.name)
        -- The shipped ones dimmer than your own, which is the other half of
        -- sorting them last: the list you curate reads first.
        row.label:SetTextColor(entry.default and 0.6 or 0.9,
            entry.default and 0.6 or 0.9, entry.default and 0.6 or 0.9)
        row.note:SetText(entry.default and "default" or "")

        -- Re-wired per refresh rather than once: a pooled row holds a different
        -- name after a removal, and a closure over the old key would delete
        -- whoever moved up into that slot.
        row.remove:SetScript("OnClick", function()
            spec.Drop(entry.key)
            ns.RefreshView()
        end)
        -- A shipped entry cannot be removed one at a time. Disabled with a
        -- reason rather than hidden: a row missing the button every other row
        -- has reads as a rendering fault, where a greyed one explains itself.
        if entry.default then
            row.remove:Disable()
            row.remove.disabledReason =
                "This one ships with TagTeam. |cffffff00Reset|r puts the whole "
                .. "list back if you have changed it."
        else
            row.remove:Enable()
        end
        row:Show()
    end
    UI.SetSectionRowCount(box, #list)
    spec.hint:SetShown(#list == 0)
end

-- Everything built for a page, kept so the refresh can find its widgets again.
local optionPages = {}

-- Stood in for a group that has no rows, rather than a fresh `{}` per group per
-- pass: the refresh and the signature both run twice a second for as long as
-- the window is up.
local NO_ROWS = {}

-- The control a row can be holding. One list, so the passes that treat them
-- alike do not each carry their own copy of what a row can be.
local OPTION_PARTS = { "check", "slider", "dropdown", "button" }

-- `Get` is the mirror of `Set`, for a row whose control value is not what the
-- db field holds. The XP zone is the one: it saves nil for auto, because "no
-- opinion" is what auto means and a stored "auto" would be a third state to
-- keep in step with the two real ones.
local function OptionValue(row)
    if row.Get then return row.Get() end
    return ns.db and ns.db[row.db]
end

local function SetOption(row, value)
    if row.Set then
        row.Set(value)
    else
        ns.db[row.db] = value
    end
    if row.after and AFTER[row.after] then SafeCall(AFTER[row.after]) end
    ns.RefreshView()
end

local ROW_TEXT_LEFT = 6    -- row edge to a label, matching the checkbox rows
local CONTROL_GAP   = 12   -- label to the control beside it

-- Blizzard's dropdown housing carries this much transparent padding to the left
-- of its visible edge, so anchoring one flush against a label leaves a gap
-- nobody asked for. Backed out below, so the spacing written down is the
-- spacing you see. StyleDropdown trims the housing's height, not this.
local DROPDOWN_LEAD = 15
local NOTE_GAP      = 12   -- slider handle to the value note beside it
local NOTE_W        = 62   -- and the note's own column, wide enough for "~100% XP"
local TEST_BTN_W    = 44   -- the "Test!" button on a notice row
local AUDIO_BTN_SIZE = 22  -- the bare speaker beside it, deliberately larger

-- Where the control beside a label starts. A group setting `labelW` puts every
-- control in one column; without it each starts where its own label happens to
-- end, which is all a box with a single control in it needs.
local function AnchorControl(widget, control, labelW, lead, y)
    if labelW then
        control:SetPoint("LEFT", widget, "LEFT",
            ROW_TEXT_LEFT + labelW - lead, y or 0)
    else
        control:SetPoint("LEFT", widget.label, "RIGHT", CONTROL_GAP - lead, y or 0)
    end
end

local function DressOptionRow(box, index, row, labelW)
    local widget = box.rows and box.rows[index]
    if widget and widget.built then return widget end

    widget = UI.CreateSectionRow(box, index)
    widget.built = true

    -- A read-only line: no db key, no control, just something the rows around
    -- it are saying together. The text comes from a function so it can move
    -- with them rather than being written once at build.
    if row.Text then
        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", ROW_TEXT_LEFT, 0)
        widget.readOnly = true

    elseif row.slider then
        -- Caption then handle, on one line. The caption carries the value, so
        -- the slider needs no numbers of its own.
        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", ROW_TEXT_LEFT, 0)

        widget.slider = UI.CreateSlider(widget, "TagTeamOption" .. row.db,
            row.slider.min, row.slider.max, row.slider.step,
            function(_, value) SetOption(row, value) end)
        widget.slider:SetWidth(150)
        AnchorControl(widget, widget.slider, labelW, 0)

        -- What the handle's position is worth, to the right of it. Reads as a
        -- consequence of the slider rather than a second setting, which is why
        -- it sits after the handle and not in the caption.
        --
        -- Fixed width, right justified: these are numbers stacked over each
        -- other, and a column of numbers lines up on its last digit or it does
        -- not line up at all. "47% XP" and "100% XP" are different lengths, so
        -- left aligning them would stagger the "% XP" down the column.
        if row.Note then
            widget.note = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            widget.note:SetPoint("LEFT", widget.slider, "RIGHT", NOTE_GAP, 0)
            widget.note:SetWidth(NOTE_W)
            widget.note:SetJustifyH("RIGHT")
            -- Outlined. The note is the only coloured text on the page and the
            -- XP purple is a mid tone, which on the row's grey has too little
            -- contrast to read at a glance - the outline gives every stroke a
            -- dark edge to sit against without lightening the colour itself.
            -- The default shadow is dropped: under an outline it only muddies
            -- the bottom of the glyphs.
            local font, size = widget.note:GetFont()
            widget.note:SetFont(font, size, "OUTLINE")
            widget.note:SetShadowOffset(0, 0)
        end
        -- Parenthesised: gsub returns a count as well, and that second value
        -- would arrive as the tooltip body.
        UI.AddTooltip(widget.slider, (row.label:gsub("%s*:.*", "")), row.about)

    elseif row.Button then
        -- A row that does something instead of holding a value. Caption, then
        -- what it is set to, then the button that changes it - left to right in
        -- the order you read it, with the thing you press last.
        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", ROW_TEXT_LEFT, 0)
        widget.label:SetText(row.label)

        -- White, in the `labelW` column with every other control on the page.
        -- No width of its own, so it sizes to the key it is showing and the
        -- button below can sit straight after it. That does mean the button
        -- shifts when the binding changes - which is fine here and would not
        -- be on a slider: this one only moves on the press that moved it.
        if row.Value then
            widget.value = widget:CreateFontString(nil, "OVERLAY",
                "GameFontHighlight")
            widget.value:SetJustifyH("LEFT")
            AnchorControl(widget, widget.value, labelW, 0)
        end

        widget.button = CreateFrame("Button", nil, widget, "UIPanelButtonTemplate")
        widget.button:SetSize(row.width or 100, UI.ROW_ICON + 4)
        -- Packed along to the left after whatever precedes it, not pushed out
        -- to the row's right edge: a caption on one side of the box and its
        -- button on the other reads as two unrelated things.
        if widget.value then
            widget.button:SetPoint("LEFT", widget.value, "RIGHT", CONTROL_GAP, 0)
        else
            AnchorControl(widget, widget.button, labelW, 0)
        end
        widget.button:SetScript("OnClick", function() SafeCall(row.OnClick) end)
        UI.AddTooltip(widget.button, (row.label:gsub("%s*:.*", "")), row.about)

    elseif row.choices then
        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", ROW_TEXT_LEFT, 0)
        widget.label:SetText(row.label)

        widget.dropdown = UI.CreateDropdown(widget, "TagTeamOption" .. row.db,
            row.width or 90, row.choices,
            function() return OptionValue(row) end,
            function(value) SetOption(row, value) end)
        -- Beside its label rather than pushed to the far right edge: a caption
        -- and its control at opposite ends of a wide row read as two unrelated
        -- things.
        AnchorControl(widget, widget.dropdown, labelW, DROPDOWN_LEAD, -2)
        UI.AddTooltip(widget.dropdown, row.label, row.about)
        -- Registered rather than looked up by name later: this is the only
        -- place that holds the frame the preview has to recognise.
        if row.holdPreview then previewHolds[widget.dropdown] = row.holdPreview end

    else
        -- The box that turns it on is the first thing on the row, on both tabs
        -- and on a row with no buttons at all: a column of them down the left
        -- edge is what makes a list of settings scannable.
        UI.AddRowCheckbox(widget, nil, row.label, row.about,
            function() SetOption(row, not OptionValue(row)) end)

        -- Right to left: Test is the outermost thing on the row and the sound
        -- settings sit inside it. Test is the one you reach for repeatedly
        -- while tuning, so it gets the edge.
        local anchor
        if row.test then
            widget.test = CreateFrame("Button", nil, widget,
                "UIPanelButtonTemplate")
            widget.test:SetSize(TEST_BTN_W, UI.ROW_ICON)
            widget.test:SetPoint("RIGHT", -4, 0)
            widget.test:SetText("Test!")
            -- Fires whatever the box says, on purpose: you press this to find
            -- out what the thing looks like, usually while deciding whether to
            -- leave it on. A button that quietly did nothing because the box
            -- beside it is unticked reads as broken. See TestNotice.
            widget.test:SetScript("OnClick",
                function() SafeCall(ns.TestNotice, row.test) end)
            -- No tooltip: the word on the button is the whole explanation, and
            -- one that popped up over the row would only cover the thing the
            -- button just drew.
            anchor = widget.test
        end

        if row.cue then
            -- Bare, and a size up on the row's other icons. Framed, it read as
            -- a second button competing with Test - and the two of them side by
            -- side turned the right of every row into a button bar.
            -- Named after the row it sits on, because that is what the pop-up
            -- it raises is about - "Sound" alone said nothing the speaker
            -- icon had not already said.
            widget.audio = UI.CreateBareIconButton(widget, UI.SPEAKER_ICON,
                AUDIO_BTN_SIZE,
                format("Edit %s audio options", row.label), nil,
                function() SafeCall(AskSound, CueByKey(row.cue)) end)
            if anchor then
                widget.audio:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
            else
                widget.audio:SetPoint("RIGHT", -4, 0)
            end
            anchor = widget.audio
        end

        -- The mark this row draws, at the size the Audio tab's rows use. An
        -- inline |T..|t in the label would size to the FONT instead, which came
        -- out half the size of the same icon one tab over.
        local textLeft = 4 + UI.ROW_CHECK + ROW_TEXT_LEFT
        if row.icon or row.questIcon then
            widget.icon = widget:CreateTexture(nil, "ARTWORK")
            widget.icon:SetSize(UI.ROW_ICON, UI.ROW_ICON)
            widget.icon:SetPoint("LEFT", widget.check, "RIGHT", 6, 0)
            -- A quest mark is asked for by name: the core decides whether this
            -- client has the high-resolution art or the old 16px set.
            if row.questIcon then
                ns.SetQuestIcon(widget.icon, row.questIcon)
            else
                widget.icon:SetTexture(row.icon)
            end
            textLeft = textLeft + UI.ROW_ICON + 6
        end

        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", textLeft, 0)
        widget.label:SetJustifyH("LEFT")
        if anchor then
            widget.label:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
        end
        widget.label:SetText(row.label)
    end

    return widget
end

local function BuildOptionsPage(page, key)
    local scroll = UI.CreateScroll(page, "TagTeamViewScroll" .. key)
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -UI.SCROLLBAR_W, 0)

    local boxes = {}
    for i, group in ipairs(OPTION_PAGES[key]) do
        local box = UI.CreateSectionBox(scroll:GetScrollChild(), group.title)
        if group.Reset then
            UI.AddHeaderTextButton(box, "Reset", "Reset " .. group.title,
                group.mobs
                    and "Drop everything you have added here and put the "
                        .. "shipped list back."
                    or "Put every setting in this box back to the way it "
                        .. "shipped.",
                function()
                    group.Reset()
                    ns.RefreshView()
                end)
        end
        -- Before the chain is laid out, since it adds a header button of its own.
        if group.mobs then
            BuildMobBox(box, group.mobs, "TagTeamViewMobScroll" .. key .. i)
        end
        UI.LayoutHeaderChain(box)
        -- Before any row exists: a custom builder reserves its strip above them,
        -- and a row already anchored will not move for it.
        if group.Build then group.Build(box) end
        boxes[i] = box
    end
    optionPages[key] = { scroll = scroll, boxes = boxes }
end

local function RefreshOptionsPage(key)
    local built = optionPages[key]
    if not built then return end

    for i, group in ipairs(OPTION_PAGES[key]) do
        local box, index = built.boxes[i], 0
        if group.Refresh then group.Refresh(box) end
        if group.mobs then RefreshMobBox(box, group.mobs) end

        for _, row in ipairs(group.rows or NO_ROWS) do
            -- A setting this client cannot honour is not shown at all. Classic
            -- Era has no focus unit, and a greyed row explaining that on every
            -- login is worse than the row not being there.
            if not row.requires or C[row.requires] then
                index = index + 1
                local widget = DressOptionRow(box, index, row, group.labelW)
                local value = OptionValue(row)

                if widget.readOnly then
                    widget.label:SetText(row.Text())
                elseif widget.slider then
                    UI.SetSliderValue(widget.slider, tonumber(value) or 0)
                    widget.label:SetText(format(row.label, tonumber(value) or 0))
                    if widget.note then
                        widget.note:SetText(row.Note(tonumber(value) or 0))
                    end
                elseif widget.button then
                    widget.button:SetText(row.Button())
                    if widget.value then widget.value:SetText(row.Value()) end
                elseif widget.dropdown then
                    widget.dropdown:Sync()
                elseif widget.check then
                    widget.check:SetChecked(value and true or false)
                end

                -- A row `needs` another to be on before it means anything -
                -- the icon's padding and its side, with the icon switched off.
                -- Greyed with a reason rather than hidden: a row that vanishes
                -- makes the box jump and takes its own explanation with it.
                if row.needs then
                    local live = ns.db and ns.db[row.needs] and true or false
                    for _, part in ipairs(OPTION_PARTS) do
                        if widget[part] then
                            widget[part].disabledReason = row.needsReason
                                or "Turn on the option above first."
                        end
                    end
                    UI.SetEnabled(live, widget.label, widget.check,
                        widget.slider, widget.dropdown, widget.button,
                        widget.value)
                end

                -- An unticked row draws nothing, so it reads as nothing: its
                -- name and its mark grey out, and the box stays lit as the one
                -- part still worth clicking. Down here so it takes the `needs`
                -- state above into account rather than undoing it - a row that
                -- is on but gated is still off in practice.
                if widget.check then
                    local lit = value and true or false
                    if row.needs then
                        lit = lit and ns.db and ns.db[row.needs] and true or false
                    end
                    UI.SetEnabled(lit, widget.label, widget.icon)
                end
                widget:Show()
            end
        end
        -- A mob box has already counted its own rows above; counting the
        -- option rows it does not have would put it back to empty-list height.
        if not group.mobs then UI.SetSectionRowCount(box, index) end
    end

    UI.SetScrollHeight(built.scroll,
        UI.StackSections(built.scroll:GetScrollChild(), built.boxes))
end

--------------------------------------------------------------------------------
-- The About page
--
-- Lifted from WhoDoesWhat's AboutView, which is where the one non-obvious part
-- comes from: WoW cannot open a web link, so a link button does not open
-- anything - it drops its URL into a copy-ready box for Ctrl+C. That is the
-- whole reason this page has an edit box on it.
--
-- The patch-notes panel below it is the other half of that page: a version
-- picker over the RELEASES list, which is empty until 1.0.
--------------------------------------------------------------------------------

local LINKS = {
    { label = "CurseForge", value = "https://www.curseforge.com/wow/addons/tagteam" },
    { label = "GitHub",     value = "https://github.com/WallHackJack/TagTeam" },
}

local DISCORD = "wallhackjack"

-- Newest first. One entry per tagged release, and the first is the one the
-- panel opens on - so the top of this list is what somebody who has just
-- updated gets shown. EMPTY UNTIL 1.0, deliberately: the panel below draws a
-- hint instead of a version picker while there is nothing in here, which is
-- why adding the first entry needs no other change.
--
--     { version = "1.0.0", date = "2026-09-01", notes = { "...", "..." } }
--
-- CHANGELOG.md stays the long form. These are the same releases said in one
-- line each, because this panel is glanced at in a window rather than read.
local RELEASES = {}

local TAGLINE = "Tracks how much of a mob's health your power-levelling partner "
    .. "has dealt, and marks the nameplate the moment they have earned the kill."

-- Box top to the first line of notes: the title strip, plus room for the
-- version picker that sits on the title's line and hangs below it.
local NOTES_TOP = UI.BOX_PAD + UI.SECTION_TITLE_H + 14
-- The mirror of DROPDOWN_LEAD: transparent housing on the RIGHT of Blizzard's
-- dropdown, taken back out when the control is anchored by that edge.
local DROPDOWN_TRAIL = 17

-- The patch-notes panel. Split out of BuildAboutPage because it is the only
-- part of this page with any state - which release is being shown - and because
-- with RELEASES empty it is one hint and nothing else.
local function BuildReleaseNotes(box)
    if #RELEASES == 0 then
        -- A picker over an empty list would be a control that does nothing, and
        -- a panel showing one stale release would be worse than one that says
        -- it has nothing. So: say it has nothing.
        local hint = UI.CreateEmptyHint(box)
        hint:SetText("Nothing here until 1.0 - CHANGELOG.md, in the addon "
            .. "folder, has the story so far.")
        return
    end

    -- Beside the title, because the picker has the corner. Anchored to the
    -- title itself rather than to the strip, so the two cannot end up on
    -- different lines.
    local date = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    date:SetPoint("LEFT", box.title, "RIGHT", 14, 0)
    date:SetTextColor(0.65, 0.65, 0.65)

    -- Scrolled, unlike WhoDoesWhat's fixed panel: a release with a dozen lines
    -- in it otherwise runs off the bottom of the box with no way to reach the
    -- rest, and the length of a release is not something this file gets to
    -- decide. The gutter is reserved whether or not the bar is showing.
    local scroll, content = UI.CreateScroll(box, "TagTeamAboutNotesScroll")
    scroll:SetPoint("TOPLEFT", UI.BOX_PAD + 4, -NOTES_TOP)
    scroll:SetPoint("BOTTOMRIGHT", -(UI.BOX_PAD + UI.SCROLLBAR_W), UI.BOX_PAD)

    local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT")
    text:SetPoint("TOPRIGHT")
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")

    -- How tall the wrapped text came out is only knowable after it has a width
    -- to wrap into, and the scroll child gets its real width from the viewport
    -- rather than at creation - so this runs again whenever that width moves.
    local function Measure()
        UI.SetScrollHeight(scroll, text:GetStringHeight() + 4)
    end
    scroll:HookScript("OnSizeChanged", Measure)

    local shown = RELEASES[1]

    local function Show(release)
        shown = release
        date:SetText(release.date or "")
        local lines = {}
        for _, note in ipairs(release.notes) do
            lines[#lines + 1] = "|cffd8d8d8- " .. note .. "|r"
        end
        -- Blank line between notes: they are separate items, and at this size a
        -- run of wrapped bullets with no gap reads as one paragraph.
        text:SetText(table.concat(lines, "\n\n"))
        Measure()
        -- Back to the top on every pick: an offset left over from a longer
        -- release opens the next one halfway down, which reads as a release
        -- whose first few notes are missing.
        scroll:SetVerticalScroll(0)
    end

    local choices = {}
    for _, release in ipairs(RELEASES) do
        choices[#choices + 1] = {
            value = release.version,
            label = "v" .. release.version,
        }
    end

    -- Top right of the box, on the header strip's midline - the corner a
    -- section box otherwise gives to its header buttons, which this box has
    -- none of. DROPDOWN_TRAIL takes the housing's transparent right edge back
    -- out, the way DROPDOWN_LEAD does on the left of an option row, so the
    -- control's VISIBLE edge lines up with the box's inner margin.
    local dropdown = UI.CreateDropdown(box, "TagTeamAboutReleaseDD", 82, choices,
        function() return shown.version end,
        function(value)
            for _, release in ipairs(RELEASES) do
                if release.version == value then Show(release) end
            end
        end)
    dropdown:SetPoint("RIGHT", box, "TOPRIGHT",
        -(UI.BOX_PAD + 4) + DROPDOWN_TRAIL,
        -(UI.HEADER_STRIP_TOP + UI.HEADER_BTN_SIZE / 2) - 2)

    Show(shown)
end

local function BuildAboutPage(page)
    local name = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    name:SetPoint("TOPLEFT", 2, -2)
    name:SetText("TagTeam")

    local installed = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    installed:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -5)
    installed:SetText("Installed version: " .. (UI.VERSION or "unknown"))

    local tagline = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tagline:SetPoint("TOPLEFT", installed, "BOTTOMLEFT", 0, -8)
    tagline:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    tagline:SetJustifyH("LEFT")
    tagline:SetText(TAGLINE)

    local links = UI.CreateSectionBox(page, "Links & Contact")
    -- Anchored by hand rather than through StackSections: this page is two
    -- fixed panels, not a list that grows.
    links:SetPoint("TOPLEFT", tagline, "BOTTOMLEFT", 0, -14)
    links:SetPoint("TOPRIGHT", tagline, "BOTTOMRIGHT", 0, -14)
    links:SetHeight(112)

    local instruction = links:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instruction:SetPoint("LEFT", links.title, "RIGHT", 10, 0)
    instruction:SetText("Pick one, then press Ctrl+C.")
    instruction:SetTextColor(0.65, 0.65, 0.65)

    local copyLabel = links:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    copyLabel:SetPoint("TOPLEFT", 12, -62)
    copyLabel:SetWidth(74)
    copyLabel:SetJustifyH("LEFT")

    local copyEdit = CreateFrame("EditBox", nil, links, "InputBoxTemplate")
    copyEdit:SetPoint("LEFT", copyLabel, "RIGHT", -2, 0)
    copyEdit:SetPoint("RIGHT", links, "RIGHT", -12, 0)
    copyEdit:SetHeight(20)
    copyEdit:SetAutoFocus(false)
    copyEdit:SetMaxLetters(512)
    copyEdit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    copyEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    copyEdit:SetScript("OnEnterPressed", function(self) self:HighlightText() end)

    local function Offer(label, value)
        copyLabel:SetText(label .. ":")
        copyEdit:SetText(value)
        copyEdit:SetFocus()
        copyEdit:HighlightText()
    end

    local prior
    for _, link in ipairs(LINKS) do
        local entry = link
        local button = CreateFrame("Button", nil, links, "UIPanelButtonTemplate")
        button:SetSize(90, 21)
        if prior then
            button:SetPoint("LEFT", prior, "RIGHT", 6, 0)
        else
            button:SetPoint("TOPLEFT", 10, -32)
        end
        button:SetText(entry.label)
        button:SetScript("OnClick", function() Offer(entry.label, entry.value) end)
        prior = button
    end

    local contact = links:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    contact:SetPoint("BOTTOMLEFT", 12, 10)
    contact:SetText("Questions or feedback? Message |cff40c7eb" .. DISCORD
        .. "|r on Discord.")

    local copyName = CreateFrame("Button", nil, links, "UIPanelButtonTemplate")
    copyName:SetSize(90, 18)
    copyName:SetPoint("BOTTOMRIGHT", -10, 7)
    copyName:SetText("Copy name")
    copyName:SetScript("OnClick", function() Offer("Discord", DISCORD) end)

    -- Fills itself from RELEASES above; adding the first entry there is the
    -- whole of turning this from a hint into a version picker.
    local notes = UI.CreateSectionBox(page, "Patch notes")
    notes:SetPoint("TOPLEFT", links, "BOTTOMLEFT", 0, -10)
    notes:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    BuildReleaseNotes(notes)

    Offer(LINKS[1].label, LINKS[1].value)
    copyEdit:ClearFocus()
end
--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

-- What the page is currently showing, as one string.
--
-- The refresh runs on a ticker so a change made from /tag - or by the
-- mode-switch popup, which accepts long after the click that raised it - lands
-- in the window without the core having to know this file exists. Comparing
-- signatures keeps that ticker down to a string build and a compare on the
-- passes where nothing happened, which is all of them but the rare one.
-- Ping every name on every list. Roster.Ping throttles, so calling this on
-- every open costs one whisper per name per throttle window however often the
-- window is toggled.
local function PingEveryone()
    for _, section in ipairs(SECTIONS) do
        for _, entry in ipairs(section.List()) do Roster.Ping(entry.name) end
    end
end

local function Signature()
    local parts = {}
    for _, section in ipairs(SECTIONS) do
        for _, entry in ipairs(section.List()) do
            -- Presence is in here because it changes on its own: a ping that
            -- goes unanswered turns into "offline" when the timeout passes,
            -- with no event to hang a refresh on.
            parts[#parts + 1] = entry.name ..
                (section.Note and section.Note(entry) or "") ..
                (section.Line and section.Line(entry) or "")
        end
        parts[#parts + 1] = "|"
    end
    -- The sounds too: /tag sound still toggles the master, and the window has
    -- to notice that as readily as it notices a tagger being added.
    parts[#parts + 1] = tostring(ns.db and ns.db.audio)
        .. tostring(ns.db and ns.db.volume) .. tostring(ns.db and ns.db.useGameVolume)

    -- And every option on the other three tabs, for the same reason: most of
    -- them still have a /tag command, and a window showing the opposite of
    -- what you just typed is worse than no window.
    for _, page in pairs(OPTION_PAGES) do
        for _, group in ipairs(page) do
            for _, row in ipairs(group.rows or NO_ROWS) do
                parts[#parts + 1] = tostring(ns.db and ns.db[row.db])
            end
        end
    end
    -- The follow key, which the Key Bindings panel can change behind our back:
    -- nothing fires an event for it, so it has to be looked at.
    parts[#parts + 1] = tostring(BoundKey())
    for _, cue in ipairs(C.CUES) do
        parts[#parts + 1] = tostring(Cues.Enabled(cue.key)) .. Cues.Describe(cue.key)
            .. tostring(ns.db and ns.db.cueVolume and ns.db.cueVolume[cue.key])
    end
    return table.concat(parts, ",")
end

-- On ns rather than a local because this file's own buttons call it from inside
-- closures built before it would exist, and a forward local for one function
-- reads worse than the field lookup does.
function ns.RefreshView()
    if not frame then return end
    frame.signature = Signature()
    for _, section in ipairs(SECTIONS) do RefreshSection(section) end
    UI.SetScrollHeight(frame.playersScroll,
        UI.StackSections(frame.playersScroll:GetScrollChild(), frame.playersBoxes))
    RefreshOptionsPage("general")
    RefreshOptionsPage("popups")
    RefreshOptionsPage("ignore")
    RefreshOptionsPage("nameplate")
    RefreshSounds()
end

local REFRESH_EVERY = 0.5   -- seconds between staleness checks, window up only

local function Build()
    frame = UI.CreateWindow("TagTeamViewFrame", WIDTH, HEIGHT, "TagTeam")

    local pages = UI.AddTabs(frame, TABS)
    BuildPlayersPage(pages.players)
    BuildOptionsPage(pages.general,   "general")
    BuildOptionsPage(pages.popups,    "popups")
    BuildOptionsPage(pages.nameplate, "nameplate")
    BuildOptionsPage(pages.ignore,    "ignore")
    BuildSoundsPage(pages.sounds)
    BuildAboutPage(pages.about)

    frame:SetScript("OnShow", function()
        -- Ask first, draw second: the answers land over the next second or two
        -- and the ticker below picks them up as they arrive.
        SafeCall(PingEveryone)
        SafeCall(ns.RefreshView)
    end)
    frame:SetScript("OnUpdate", function(self, elapsed)
        self.since = (self.since or 0) + elapsed
        if self.since < REFRESH_EVERY then return end
        self.since = 0
        -- Wrapped: this runs twice a second for as long as the window is up, so
        -- an error in it would repeat into the chat frame rather than happen.
        SafeCall(function()
            if Signature() ~= self.signature then ns.RefreshView() end
        end)
    end)
end

-- Build once, and REFUSE to carry on from a build that threw.
--
-- The wrapping is right - a fault in chrome must not unwind the slash handler -
-- but the first version of this swallowed the error and left `frame` assigned
-- to a half-built window. The command then did nothing at all the first time
-- and opened a window with no contents the second, with nothing in the chat
-- frame either way. A cosmetic that fails quietly is fine; a command somebody
-- typed is not, so this one says so and says where the error is.
local function Ready()
    if buildFailed then
        Print("|cffff8080The window failed to build.|r Details: |cffffff00/tag diag|r")
        return false
    end
    if frame then return true end
    if SafeCall(Build) then return true end

    -- Not retried: a half-built window is worse than none, and building again
    -- over the wreckage would only make a second one.
    buildFailed, frame = true, nil
    Print("|cffff8080The window failed to build.|r Details: |cffffff00/tag diag|r")
    return false
end

-- Returns whether the window ended up OPEN, which is what /tag needs to decide
-- whether to print the command list with it: the same keystroke closing the
-- window should not spill a menu into chat on the way out.
local function ToggleView()
    if not Ready() then return false end
    local opened = false
    SafeCall(function()
        opened = not frame:IsShown()
        frame:SetShown(opened)
    end)
    return opened
end

-- /tag pair <name>. The same prompt the [+] buttons raise, minus the assumption
-- about which of the three lists the name belongs in.
local function ShowPairPrompt(name)
    if not Ready() then return end
    SafeCall(function()
        frame:Show()
        Ask(nil, name)
    end)
end

--------------------------------------------------------------------------------
-- Exports
--
-- Opening the window, and opening it on the pair prompt. ns.RefreshView is
-- assigned above instead, next to what it refreshes.
--------------------------------------------------------------------------------

ns.ToggleView     = ToggleView
ns.ShowPairPrompt = ShowPairPrompt
