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
local ReassignMarkers   = ns.ReassignMarkers
local PushThreshold     = ns.PushThreshold
local Roster, Cues = ns.Roster, ns.Cues
local TaggersByPriority = ns.TaggersByPriority
local NormalizeName = ns.NormalizeName
local Print = ns.Print
local C = ns.C

local WIDTH, HEIGHT = 560, 470

-- The sound pop-up is half again as wide as the default: a sound path is a long
-- thing to read in a box sized for a character name.
local SOUND_PROMPT_W = 450
local PREVIEW_GAP    = 0.3   -- seconds between previews while a slider moves
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
    { page = "sounds",    label = "Sounds" },
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
        row.check:SetSize(UI.ROW_ICON, UI.ROW_ICON)
        row.check:SetPoint("LEFT", 4, 0)
        textLeft = 4 + UI.ROW_ICON + 6

        row:EnableMouse(true)
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

local sounds = { boxes = {} }   -- the page's widgets, built once

-- Previewing, throttled. Every one of these hangs off a slider, and a slider
-- reports every step of a drag - without this, dragging from 0 to 100 would
-- fire the cue twenty times on top of itself.
local lastPreview = 0
local function Preview(key)
    local now = GetTime()
    if now - lastPreview < PREVIEW_GAP then return end
    lastPreview = now
    Cues.Play(key)
end

-- The gear's pop-up: which sound, how loud, and a way back to the default.
local function AskSound(cue)
    if not prompt then prompt = UI.CreatePrompt("TagTeamPromptFrame") end
    prompt:Ask({
        title = cue.label,
        -- Half again as wide as the name prompt: a sound path is a long thing
        -- to read in a box sized for "Meepmerp".
        width = SOUND_PROMPT_W,
        hint  = "Sound id, or a file path",
        -- Pre-filled with what it is actually playing. An empty box would make
        -- somebody guess the shape of the thing they are meant to replace.
        text  = Cues.CurrentSetting(cue.key),
        accept = "Save",
        -- Blank is an answer here: it puts the cue back to its default.
        allowEmpty = true,
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
            -- Saved as it moves rather than on accept, and played: the point of
            -- a volume slider is hearing the difference, and Cancel on a volume
            -- you have already listened to would be a strange thing to want.
            OnChange = function(value)
                Cues.SetVolume(cue.key, value)
                Preview(cue.key)
                ns.RefreshView()
            end,
        },
        reset = function()
            Cues.Reset(cue.key)
            Print(format("%s reset to its default.", cue.label))
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

    row.gear = UI.CreateGearButton(row, "Change the sound",
        "Pick a SOUNDKIT id or a file path, set this cue's own volume, or "
        .. "reset it. A path is checked by playing it.",
        function() AskSound(cue) end)
    row.gear:SetSize(UI.ROW_ICON, UI.ROW_ICON)
    row.gear:SetPoint("RIGHT", -4, 0)

    row.check = UI.CreateCheckbox(row, nil, cue.label, cue.about, function()
        -- Ticking one on plays it. The /tag test* commands are gone, and this
        -- is the moment somebody wants to hear what they just switched on.
        if Cues.Toggle(cue.key) then Cues.Play(cue.key) end
        ns.RefreshView()
    end)
    row.check:SetSize(UI.ROW_ICON, UI.ROW_ICON)
    row.check:SetPoint("RIGHT", row.gear, "LEFT", -6, 0)

    -- The verdict marks are the same textures the death burst draws, so the
    -- row and the thing it makes a noise about are unmistakably the same event.
    local textLeft = 6
    if cue.icon then
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(UI.ROW_ICON, UI.ROW_ICON)
        row.icon:SetPoint("LEFT", 4, 0)
        row.icon:SetTexture(cue.icon)
        textLeft = 4 + UI.ROW_ICON + 6
    end

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.label:SetPoint("LEFT", textLeft, 0)
    row.label:SetText(cue.label)

    -- What it is currently set to, grey and to the right of the name. The gear
    -- changes it, and this is how you see that the change took.
    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.note:SetPoint("RIGHT", row.check, "LEFT", -8, 0)
    row.note:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
    row.note:SetJustifyH("RIGHT")
    row.note:SetTextColor(0.55, 0.55, 0.55)

    return row
end

local function BuildSoundsPage(page)
    -- The three controls that govern everything below them, so they sit above
    -- the boxes rather than inside one.
    sounds.master = UI.CreateCheckbox(page, "Enable sounds", "Enable sounds",
        "Every cue below is silenced while this is off. The on-screen marks "
        .. "are unaffected. Same switch as |cffffff00/tag sound|r.",
        function()
            ns.db.audio = not ns.db.audio
            ns.RefreshView()
        end)
    sounds.master:SetPoint("TOPLEFT", 2, -2)

    -- Caption then handle, on one line and left aligned - the same row shape
    -- the per-cue volume uses in its pop-up, so the two read as one control in
    -- two places rather than two different ideas.
    sounds.volumeLabel = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sounds.volumeLabel:SetPoint("TOPLEFT", sounds.master, "BOTTOMLEFT", 4, -14)

    sounds.volume = UI.CreateSlider(page, "TagTeamViewVolume", 0, 100, 5,
        function(_, value)
            ns.db.volume = value
            -- Played as it moves. A volume you cannot hear while setting it is
            -- a number you are guessing at.
            Preview("tag")
            ns.RefreshView()
        end)
    sounds.volume:SetWidth(160)
    sounds.volume:SetPoint("LEFT", sounds.volumeLabel, "RIGHT", 12, 0)
    if sounds.volume.title then sounds.volume.title:SetText("") end
    UI.AddTooltip(sounds.volume, "TagTeam volume",
        "How loud this addon's own cues are. The game's Sound Effects slider "
        .. "and each cue's own volume both multiply this one.")

    sounds.followGame = UI.CreateCheckbox(page, "", "Follow the game's volume",
        "Multiply everything by your Sound Effects slider as well. Off, this "
        .. "addon plays at its own volume whatever the game is set to.",
        function()
            ns.db.useGameVolume = not ns.db.useGameVolume
            Preview("tag")
            ns.RefreshView()
        end)
    sounds.followGame:SetSize(UI.ROW_ICON, UI.ROW_ICON)
    sounds.followGame:SetPoint("TOPLEFT", sounds.volumeLabel, "BOTTOMLEFT", -4, -12)

    local scroll = UI.CreateScroll(page, "TagTeamViewSoundsScroll")
    scroll:SetPoint("TOPLEFT", sounds.followGame, "BOTTOMLEFT", -2, -10)
    scroll:SetPoint("BOTTOMRIGHT", -UI.SCROLLBAR_W, 0)
    sounds.scroll = scroll

    for i, group in ipairs(C.CUE_SECTIONS) do
        local box = UI.CreateSectionBox(scroll:GetScrollChild(), group.title)
        UI.LayoutHeaderChain(box)   -- no header buttons; keeps the call uniform
        sounds.boxes[i] = box
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
        local box, index = sounds.boxes[i], 0
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

                row.check.disabledReason = "Sounds are off. Turn on Enable sounds."
                row.gear.disabledReason = "Sounds are off. Turn on Enable sounds."

                UI.SetEnabled(on, row.icon, row.label, row.note, row.gear,
                    row.check)
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

local OPTION_PAGES = {
    general = {
        {
            title = "Tracking",
            rows = {
                { db = "enabled", label = "TagTeam running",
                  about = "The master switch. Off means no tracking, no badges "
                       .. "and no cues, without losing any of your setup.",
                  after = "plates" },
                { db = "threshold", label = "Damage share needed: %.1f%%",
                  slider = { min = 5, max = 100, step = 0.5 },
                  about = "How much of a mob's maximum health your taggers have "
                       .. "to deal between them to earn the kill. Sent to your "
                       .. "partner too - both clients have to agree on it.",
                  -- Throttled, because this one does not just write a db field:
                  -- it whispers the other client. A drag from 38 to 60 steps
                  -- forty-odd times, and forty addon messages to say what the
                  -- last one says is how you get muted by the server.
                  Set = function(value) PushThresholdSoon(value) end },
                { db = "includePets", label = "Count pet damage",
                  about = "A hunter's or warlock's pet does a large share of a "
                       .. "tagger's damage. Off, a pet class looks like it "
                       .. "cannot reach the threshold." },
                { db = "ignorePvP", label = "Ignore PvP-flagged mobs",
                  about = "Mobs another player has tagged in a PvP context are "
                       .. "not yours to measure." },
                { db = "instanceOff", label = "Suspend in dungeons and raids",
                  about = "Inside an instance the carry and the tagger are "
                       .. "necessarily grouped, so a tag earns almost nothing "
                       .. "and every cue fires into a run you cannot act on." },
            },
        },
        {
            title = "Partner link",
            rows = {
                { db = "comms", label = "Addon-to-addon link",
                  about = "Pairing, threshold sync and real XP reporting, over "
                       .. "the hidden whisper channel. Off, everything falls "
                       .. "back to estimates." },
                { db = "announce", label = "Announce each tagged kill in chat",
                  about = "One line per kill, with what it paid." },
                { db = "questNotices",
                  label = "Show your partner's quest log activity",
                  about = "What they accept, abandon and tick over. The "
                       .. "chattiest thing on the channel." },
            },
        },
        {
            title = "Party",
            rows = {
                { db = "autoInvite", label = "Ask for an invite when out of range",
                  about = "Out of combat-log range nothing can be measured, so "
                       .. "the addon asks to be grouped rather than going quiet." },
                { db = "autoAccept", label = "Accept invites from your partner",
                  about = "Only from a name on your own list." },
                { db = "autoLeave", label = "Leave the party once back in range",
                  about = "Being grouped splits the XP, so the group is dropped "
                       .. "the moment it stops being needed." },
                { db = "autoLoot", label = "Free-for-all loot in a tag group",
                  about = "A two-person tag group wants everything lootable by "
                       .. "whoever gets there." },
                { db = "autoFocus", label = "Use focus for range detection",
                  about = "The focus unit is the most reliable range check "
                       .. "there is. Setting focus is protected, so bind a key "
                       .. "under Key Bindings > TagTeam.",
                  -- Classic Era has no focus unit at all.
                  requires = "HAS_FOCUS", after = "macro" },
            },
        },
    },

    popups = {
        {
            title = "On screen",
            rows = {
                { db = "missAlert", label = "Miss notice",
                  about = "The mark drawn over a kill that paid too little, and "
                       .. "the report queued behind it. This is the notice "
                       .. "itself - its sound is on the Sounds tab." },
                { db = "stealWarning", label = "Warn when a tag is stolen",
                  about = "Somebody else tapped the mob first. Nothing your "
                       .. "tagger does to it after that can pay." },
                { db = "groupWarning",
                  label = "Warn when grouped with your tagger in combat",
                  about = "Being grouped splits the XP. In carry mode that is "
                       .. "almost always a mistake, and an expensive one." },
                { db = "focusWarning", label = "Remind you when no focus is set",
                  about = "Without a focus, range falls back to a timer.",
                  requires = "HAS_FOCUS" },
            },
        },
        {
            title = "Windows",
            rows = {
                { db = "levelPopup", label = "Pop up when your tagger levels",
                  about = "The event the whole addon exists to produce. Off, it "
                       .. "is still announced in chat." },
            },
        },
    },

    nameplate = {
        {
            title = "Badge",
            rows = {
                { db = "badgePos", label = "Badge position",
                  choices = BADGE_CHOICES, after = "plates",
                  about = "Where the damage-share badge sits relative to the "
                       .. "nameplate." },
            },
        },
        {
            title = "Markers",
            rows = {
                { db = "markers", label = "Raid marker on their tag",
                  about = "Marks the mob your tagger has credit for, so it is "
                       .. "obvious which one to leave alone.",
                  after = "markers" },
                { db = "taggerMarker", label = "Mark taggers while ungrouped",
                  about = "Ungrouped there is no party frame to find them on, "
                       .. "so the marker goes on the tagger instead.",
                  after = "markers" },
            },
        },
    },
}

-- Everything built for a page, kept so the refresh can find its widgets again.
local optionPages = {}

local function OptionValue(row)
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

local function DressOptionRow(box, index, row)
    local widget = box.rows and box.rows[index]
    if widget and widget.built then return widget end

    widget = UI.CreateSectionRow(box, index)
    widget.built = true

    if row.slider then
        -- Caption then handle, on one line. The caption carries the value, so
        -- the slider needs no numbers of its own.
        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", 6, 0)

        widget.slider = UI.CreateSlider(widget, "TagTeamOption" .. row.db,
            row.slider.min, row.slider.max, row.slider.step,
            function(_, value) SetOption(row, value) end)
        widget.slider:SetWidth(150)
        widget.slider:SetPoint("LEFT", widget.label, "RIGHT", 12, 0)
        if widget.slider.title then widget.slider.title:SetText("") end
        -- Parenthesised: gsub returns a count as well, and that second value
        -- would arrive as the tooltip body.
        UI.AddTooltip(widget.slider, (row.label:gsub("%s*:.*", "")), row.about)

    elseif row.choices then
        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", 6, 0)
        widget.label:SetText(row.label)

        widget.dropdown = UI.CreateDropdown(widget, "TagTeamOption" .. row.db,
            90, row.choices,
            function() return OptionValue(row) end,
            function(value) SetOption(row, value) end)
        widget.dropdown:SetPoint("RIGHT", 8, -2)
        UI.AddTooltip(widget.dropdown, row.label, row.about)

    else
        widget.check = UI.CreateCheckbox(widget, nil, row.label, row.about,
            function() SetOption(row, not OptionValue(row)) end)
        widget.check:SetSize(UI.ROW_ICON, UI.ROW_ICON)
        widget.check:SetPoint("LEFT", 4, 0)

        widget.label = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        widget.label:SetPoint("LEFT", 4 + UI.ROW_ICON + 6, 0)
        widget.label:SetText(row.label)
        -- The label is part of the click target: a checkbox you have to hit
        -- exactly is a checkbox people miss.
        widget:EnableMouse(true)
        widget:SetScript("OnMouseUp", function() widget.check:Click() end)
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
        UI.LayoutHeaderChain(box)   -- no header buttons; keeps the call uniform
        boxes[i] = box
    end
    optionPages[key] = { scroll = scroll, boxes = boxes }
end

local function RefreshOptionsPage(key)
    local built = optionPages[key]
    if not built then return end

    for i, group in ipairs(OPTION_PAGES[key]) do
        local box, index = built.boxes[i], 0
        for _, row in ipairs(group.rows) do
            -- A setting this client cannot honour is not shown at all. Classic
            -- Era has no focus unit, and a greyed row explaining that on every
            -- login is worse than the row not being there.
            if not row.requires or C[row.requires] then
                index = index + 1
                local widget = DressOptionRow(box, index, row)
                local value = OptionValue(row)

                if widget.slider then
                    UI.SetSliderValue(widget.slider, tonumber(value) or 0)
                    widget.label:SetText(format(row.label, tonumber(value) or 0))
                elseif widget.dropdown then
                    widget.dropdown:Sync()
                elseif widget.check then
                    widget.check:SetChecked(value and true or false)
                end
                widget:Show()
            end
        end
        UI.SetSectionRowCount(box, index)
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
--------------------------------------------------------------------------------

local LINKS = {
    { label = "CurseForge", value = "https://www.curseforge.com/wow/addons/tagteam" },
    { label = "GitHub",     value = "https://github.com/WallHackJack/TagTeam" },
}

local DISCORD = "wallhackjack"

local TAGLINE = "Tracks how much of a mob's health your power-levelling partner "
    .. "has dealt, and marks the nameplate the moment they have earned the kill."

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

    -- TODO: patch notes. CHANGELOG.md already carries every release; this box
    -- wants a RELEASES table beside LINKS above (version, date, notes) and a
    -- version dropdown in this header, the way WhoDoesWhat's AboutView does it.
    -- Deliberately left empty rather than half-filled: a notes panel showing
    -- one stale release is worse than one that admits it has nothing.
    local notes = UI.CreateSectionBox(page, "Patch notes")
    notes:SetPoint("TOPLEFT", links, "BOTTOMLEFT", 0, -10)
    notes:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

    local soon = UI.CreateEmptyHint(notes)
    soon:SetText("Not wired up yet - see CHANGELOG.md in the addon folder.")

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
            for _, row in ipairs(group.rows) do
                parts[#parts + 1] = tostring(ns.db and ns.db[row.db])
            end
        end
    end
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
    RefreshOptionsPage("nameplate")
    RefreshSounds()
end

local REFRESH_EVERY = 0.5   -- seconds between staleness checks, window up only

local function Build()
    frame = UI.CreateWindow("TagTeamViewFrame", WIDTH, HEIGHT, "TagTeam")

    local pages = UI.AddTabs(frame, TABS)
    BuildPlayersPage(pages[1])
    BuildOptionsPage(pages[2], "general")
    BuildOptionsPage(pages[3], "popups")
    BuildOptionsPage(pages[4], "nameplate")
    BuildSoundsPage(pages[5])
    BuildAboutPage(pages[6])

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

local function ToggleView()
    if not Ready() then return end
    SafeCall(function() frame:SetShown(not frame:IsShown()) end)
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
