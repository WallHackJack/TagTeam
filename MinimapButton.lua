local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- The minimap button
--
-- A leaf, like every other file beside the core: it reads ns.db, ns.ToggleView
-- and ns.SlashMenu, and nothing in here is read back except the one refresh the
-- options checkbox calls.
--
-- LibDBIcon, NOT a hand-rolled button, and that is the whole point of the file.
-- The hand-rolled version worked and looked right, and was still wrong: every
-- addon that manages minimap buttons - Leatrix Plus's "hide addon buttons",
-- MinimapButtonButton's bag, SexyMap, Chinchilla - finds buttons by walking
-- LibDBIcon's `lib.objects` registry. A button that never registered is not in
-- that table, so those addons cannot see it, cannot hide it, cannot fade it and
-- cannot bag it. It just sits there ignoring a setting the user believes they
-- turned on, and there is no way to tell that apart from the addon being
-- broken. Method Raid Tools has exactly this bug, down to naming its frame
-- LibDBIcon10_MethodRaidTools without ever registering it.
--
-- So: no fade code here, and none wanted. Registering is what makes the user's
-- own minimap addon responsible for that, which is where it belongs. If the
-- button fades, it is because they asked something to fade it; if it does not,
-- they did not. WhoDoesWhat calls ShowOnEnter on itself and therefore fades
-- whether or not anybody asked - do not copy that.
--
-- The four Libs folders are the cost. They buy correct behaviour under every
-- minimap manager rather than under none.
--------------------------------------------------------------------------------

local ICON = [[Interface\AddOns\TagTeam\Media\TagTeamIcon.tga]]

-- The registry key. Becomes the frame name LibDBIcon10_TagTeam, and is what
-- another addon's exclude list would have to name.
local LDB_NAME = "TagTeam"

-- Where it sits the first time anybody sees it, in degrees anticlockwise from
-- east. Lower left, which is the emptiest quadrant on a default UI.
local DEFAULT_ANGLE = 220

local registered

local function Tooltip(tooltip)
    -- WhoDoesWhat's tooltip shape, deliberately: a white title, then one
    -- AddDoubleLine per binding with the gesture gold on the left and what it
    -- does white on the right. The two columns are what give it the
    -- indentation - the game right-aligns the second string, so the actions
    -- line up as a column however long the gestures get, which a single line
    -- with a colour code in the middle of it never does.
    --
    -- The tooltip is handed to us already owned and anchored. Write into it and
    -- do not Show it: the library does both, and it picks the anchor from which
    -- side of the screen the minimap is on.
    local GOLD, WHITE = { 1, 0.82, 0 }, { 1, 1, 1 }
    local function Binding(gesture, does)
        tooltip:AddDoubleLine(gesture, does,
            GOLD[1], GOLD[2], GOLD[3], WHITE[1], WHITE[2], WHITE[3])
    end

    -- The command in the header is green rather than gold: gold is the colour
    -- every gesture below wears, and the header is not a gesture. It is the
    -- same green /tag prints its own name in, so the two headers match.
    tooltip:AddLine("TagTeam |cff33ff99/Tag|r", WHITE[1], WHITE[2], WHITE[3])
    Binding("Left-Click:", "Open the window")
    Binding("Right-Click:", "Print the chat options")
    Binding("Drag:", "Move around the minimap")
end

local function OnClick(_, mouse)
    -- Both read at click time rather than localized at the top of the file:
    -- they belong to the other two leaves, and looking them up now means the
    -- TOC order is the only thing that has to be right.
    if mouse == "RightButton" then
        -- The chat options: the same list /tag prints, so there is one list of
        -- commands rather than a second one that drifts.
        if ns.SlashMenu then ns.SlashMenu() end
    elseif ns.ToggleView then
        ns.ToggleView()
    end
end

-- Called by the Windows box's checkbox as well as at login.
--
-- `db.minimap` stays the user-facing switch so the options row is one
-- declarative line like every other one, and this mirrors it onto the shape
-- LibDBIcon wants. Two names for one setting is worth it: the alternative is
-- teaching the options builder about a nested table for the sake of one row.
local function UpdateMinimapButton()
    if not registered or not ns.db then return end
    local icon = LibStub("LibDBIcon-1.0", true)
    if not icon then return end
    ns.db.minimapButton.hide = ns.db.minimap == false
    if ns.db.minimapButton.hide then
        icon:Hide(LDB_NAME)
    else
        icon:Show(LDB_NAME)
    end
end

local function Register()
    local broker = LibStub("LibDataBroker-1.1", true)
    local icon   = LibStub("LibDBIcon-1.0", true)
    -- Shipped in Libs, so this should not fail - but an older copy of either
    -- can win LibStub if another addon loaded first, and a nil here is a
    -- missing button rather than an error thrown at somebody mid-pull.
    if not broker or not icon then return end

    -- LibDBIcon owns this table: position, hidden, locked. Ours to store, not
    -- to interpret - the one field we touch is `hide`, and only through the
    -- mirror above.
    local saved = ns.db.minimapButton
    if not saved then
        saved = { hide = false, minimapPos = DEFAULT_ANGLE }
        -- Carry over the hand-rolled version's two keys, so anybody who ran a
        -- build between then and now keeps the button where they dragged it
        -- and keeps it switched off if they switched it off.
        if ns.db.minimapAngle then saved.minimapPos = ns.db.minimapAngle end
        if ns.db.minimap == false then saved.hide = true end
        ns.db.minimapButton = saved
    end
    ns.db.minimapAngle = nil   -- LibDBIcon's minimapPos is the position now

    local launcher = broker:NewDataObject(LDB_NAME, {
        type          = "launcher",
        text          = LDB_NAME,
        icon          = ICON,
        OnClick       = OnClick,
        OnTooltipShow = Tooltip,
    })
    icon:Register(LDB_NAME, launcher, saved)
    registered = true

    local button = icon:GetMinimapButton(LDB_NAME)

    -- Two pixels in from LibDBIcon's default 17x17, so the artwork sits
    -- inside the ring rather than filling it edge to edge. Odd sizes are the
    -- ones that land on whole pixels inside a 31x31 button, which is the other
    -- reason this is 15 and not 14.
    icon:SetButtonIcon(LDB_NAME, ICON, 15, "CENTER", 0, 0)

    -- Rounded off the same way WhoDoesWhat rounds its own, so a square icon
    -- sits inside the ring instead of poking out of the four corners of it.
    -- Left at the library's full 17x17 slot rather than following the icon
    -- down, so shrinking the artwork does not tighten the rounding with it.
    -- Guarded because CreateMaskTexture is not on every client this addon
    -- loads on; without it the icon is a square, which is what every minimap
    -- button looked like for fifteen years.
    if button and button.CreateMaskTexture then
        local mask = button:CreateMaskTexture(nil, "ARTWORK")
        mask:SetTexture([[Interface\CharacterFrame\TempPortraitAlphaMask]],
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetSize(17, 17)
        mask:SetPoint("TOPLEFT", 7, -6)
        button.icon:AddMaskTexture(mask)
    end

    UpdateMinimapButton()
end

-- PLAYER_LOGIN rather than ADDON_LOADED: the core assigns ns.db from its own
-- ADDON_LOADED handler, and which of two frames gets that event first is not
-- ours to decide. By login it is there.
--
-- It is also when Leatrix Plus and friends do their own setup, and registering
-- here rather than earlier is what lets their LibDBIcon_IconCreated callback
-- see us - that callback is how a late button inherits the user's setting.
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    if ns.db.minimap == nil then ns.db.minimap = true end
    Register()
end)

ns.UpdateMinimapButton = UpdateMinimapButton
