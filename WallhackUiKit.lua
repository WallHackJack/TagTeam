local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- WallhackUiKit - window chrome, shared verbatim with WhoDoesWhat
--
-- THIS FILE IS DUPLICATED BYTE-FOR-BYTE INTO WhoDoesWhat. Fix a bug here and
-- copy the whole file across; never patch one copy. Everything below is shaped
-- around that one rule:
--
--   * it takes NOTHING from the addon around it - no addon object, no Ace, no
--     logging hook, no constant from another file. `local ADDON_NAME, ns = ...`
--     is the entire contact surface, and that line works in any addon file.
--   * it holds every number the chrome is built from, so a window in either
--     addon cannot drift from a window in the other by someone redefining a
--     margin locally. Three WhoDoesWhat views each declare their own
--     `SCROLLBAR_W = 26` today; that is the drift this exists to stop.
--   * it carries helpers the *other* addon needs even when this one does not.
--     StyleDropdown has no caller in TagTeam. It stays anyway - a helper
--     deleted for being unused here is a diff between the copies tomorrow.
--
-- Each addon gets its own private copy at `ns.UI`. Nothing is shared at
-- runtime, only the source: no global, no LibStub, no revision number and no
-- question about which addon loaded first.
--------------------------------------------------------------------------------

local UI = {}
ns.UI = UI

--------------------------------------------------------------------------------
-- The numbers
--------------------------------------------------------------------------------

UI.TITLEBAR_H  = 22
UI.INSET       = 5    -- backdrop edge to anything inside it
UI.SCROLLBAR_W = 26   -- gutter reserved on the right of a scroll area

UI.TAB_H       = 22
UI.TAB_PAD     = 12   -- either side of a tab's label; tabs size to their text
UI.TAB_GAP     = 2    -- between neighbouring tabs
UI.TAB_INDENT  = 14   -- strip start to the left edge of the first tab, so the
                      -- row sits inboard like the tabs on a real folder
UI.TAB_DROP    = 3    -- title bar to the top of the tabs
UI.TAB_LIP     = 3    -- how far the panel rides UP behind the tab row, so the
                      -- tabs sit on the panel instead of floating above it

-- Solid dark, thin border. Both addons use this and only this, which is the
-- whole reason they look like they came from the same hand.
UI.BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- AceGUI's slider art, used for the track behind a native scrollbar.
UI.SCROLL_TRACK_BACKDROP = {
    bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- BackdropTemplate is the Shadowlands-era split of backdrop support out of the
-- base frame. Both clients have it, but resolve it rather than assume it -
-- CreateFrame takes a nil template happily.
UI.TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- The lookup moved onto C_AddOns and the bare global is a deprecated alias on
-- these clients. Take whichever exists.
local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

-- The host addon's version, resolved once. Windows stamp it into their title
-- bar; an About page wants it too, and neither should look it up again.
UI.VERSION = GetMetadata and GetMetadata(ADDON_NAME, "Version") or nil

--------------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------------

-- A standard window: solid black, title bar with text and version, close
-- button, draggable by anywhere on it, closes on Escape.
--
-- `globalName` must be unique per window - it is what the Escape-close registry
-- keys on, and the only reason these frames are named at all.
--
-- The caller anchors its own content below the title bar, at `f.titleBarHeight`
-- from the top.
--
-- `bare` builds it without the title bar or the close button, for a pop-up: a
-- prompt with two buttons in it does not need a third way to dismiss it, and
-- the title bar on something that small is most of its height. `titleBarHeight`
-- is 0 there, so the same anchoring arithmetic works either way.
function UI.CreateWindow(globalName, width, height, titleText, bare)
    local f = CreateFrame("Frame", globalName, UIParent, UI.TEMPLATE)
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetBackdrop(UI.BACKDROP)
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4)

    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    tinsert(UISpecialFrames, globalName)

    if bare then
        f.titleBarHeight = 0
        f:Hide()
        return f
    end

    local titlebar = f:CreateTexture(nil, "ARTWORK")
    titlebar:SetColorTexture(0.12, 0.12, 0.15, 1)
    titlebar:SetPoint("TOPLEFT", UI.INSET, -UI.INSET)
    titlebar:SetPoint("TOPRIGHT", -UI.INSET, -UI.INSET)
    titlebar:SetHeight(UI.TITLEBAR_H)
    f.titleBar = titlebar

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titlebar, "LEFT", 10, 0)
    title:SetText(titleText or "")
    f.titleText = title

    -- The build number, greyed out and to the right of the title, so a
    -- screenshot of a misbehaving window says which version produced it.
    local version = UI.VERSION
    if version then
        local stamp = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        stamp:SetPoint("LEFT", title, "RIGHT", 8, 0)
        stamp:SetText(version)
        f.versionText = stamp
    end

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() f:Hide() end)
    f.closeButton = close

    f.titleBarHeight = UI.TITLEBAR_H
    f:Hide()
    return f
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

-- One function decides what "selected" looks like, for the tab and its page
-- both, so the two can never disagree about which tab is up.
local function SelectTab(f, index)
    for i, tab in ipairs(f.tabs) do
        local on = i == index
        tab.bg:SetColorTexture(on and 0.22 or 0.10, on and 0.22 or 0.10,
                               on and 0.26 or 0.12, 1)
        tab.label:SetTextColor(on and 1 or 0.65, on and 0.82 or 0.65,
                               on and 0 or 0.65)
        tab.underline:SetShown(on)
        f.pages[i]:SetShown(on)
    end
    f.selectedTab = index
    if f.onTabSelected then f.onTabSelected(index) end
end

-- Deliberately not PanelTabButtonTemplate: the stock tab art is parchment and
-- would look pasted on against a black window, and its availability varies by
-- client. A button, a background and a label is the whole of it.
--
-- Width follows the label rather than a fixed number, so a longer tab name
-- cannot silently clip.
local function BuildTab(f, index, spec)
    local tab = CreateFrame("Button", nil, f)
    tab:SetHeight(UI.TAB_H)

    tab.bg = tab:CreateTexture(nil, "BACKGROUND")
    tab.bg:SetAllPoints(tab)

    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tab.label:SetPoint("CENTER")
    tab.label:SetText(spec.label)

    -- A thin bar along the bottom of the selected tab. Against a dark
    -- background the colour change on its own is too subtle; this is what
    -- actually reads as "this one" at a glance.
    tab.underline = tab:CreateTexture(nil, "ARTWORK")
    tab.underline:SetColorTexture(1, 0.82, 0, 1)
    tab.underline:SetPoint("BOTTOMLEFT", 0, 0)
    tab.underline:SetPoint("BOTTOMRIGHT", 0, 0)
    tab.underline:SetHeight(2)
    tab.underline:Hide()

    tab:SetWidth(tab.label:GetStringWidth() + UI.TAB_PAD * 2)
    tab:SetScript("OnClick", function() SelectTab(f, index) end)

    return tab
end

-- Fit a window out with a tab row and a content panel, one page per tab.
--
-- `specs` is a list of `{ label = "..." }`; adding a tab is adding an entry,
-- and nothing here counts them by hand. Returns the pages, in the same order.
-- The caller fills each page and otherwise ignores the machinery; it can set
-- `f.onTabSelected` to hear about switches, and call `f:SelectTab(i)` to drive
-- one from outside.
--
-- Every page fills the panel and all but the selected one is hidden, so they
-- stack and no page needs to know anything about the others.
function UI.AddTabs(f, specs)
    f.tabs, f.pages = {}, {}

    -- The panel is built FIRST so the tabs are the later siblings and draw over
    -- it. That is what lets the row overlap the panel's top border by TAB_LIP
    -- without the border cutting through the selected tab's underline. The
    -- explicit frame level says so out loud rather than leaning on creation
    -- order, because a future edit that reorders these would be silent.
    local panel = CreateFrame("Frame", nil, f, UI.TEMPLATE)
    panel:SetPoint("TOPLEFT", UI.INSET,
        -(UI.INSET + UI.TITLEBAR_H + UI.TAB_DROP + UI.TAB_H - UI.TAB_LIP))
    panel:SetPoint("BOTTOMRIGHT", -UI.INSET, UI.INSET)
    panel:SetBackdrop(UI.BACKDROP)
    panel:SetBackdropColor(0.06, 0.06, 0.07, 1)
    panel:SetBackdropBorderColor(0.25, 0.25, 0.25)
    f.tabPanel = panel

    -- Tabs run left to right, each anchored to the one before it, so the label
    -- widths stay the only thing deciding the spacing.
    --
    -- A spec with `right = true` is anchored from the other end instead, and
    -- the two runs simply never meet in the middle. That is how a tab that is
    -- not part of the sequence - About, Help, anything you go to rather than
    -- through - gets separated from it without anybody counting pixels.
    local previous, previousRight
    for i, spec in ipairs(specs) do
        local tab = BuildTab(f, i, spec)
        tab:SetFrameLevel(panel:GetFrameLevel() + 2)
        if spec.right then
            if previousRight then
                tab:SetPoint("TOPRIGHT", previousRight, "TOPLEFT", -UI.TAB_GAP, 0)
            else
                tab:SetPoint("TOPRIGHT", f.titleBar, "BOTTOMRIGHT",
                    -UI.TAB_INDENT, -UI.TAB_DROP)
            end
            previousRight = tab
        elseif previous then
            tab:SetPoint("TOPLEFT", previous, "TOPRIGHT", UI.TAB_GAP, 0)
            previous = tab
        else
            tab:SetPoint("TOPLEFT", f.titleBar, "BOTTOMLEFT",
                UI.TAB_INDENT, -UI.TAB_DROP)
            previous = tab
        end
        f.tabs[i] = tab
    end

    for i in ipairs(specs) do
        local page = CreateFrame("Frame", nil, panel)
        page:SetPoint("TOPLEFT", 10, -10)
        page:SetPoint("BOTTOMRIGHT", -10, 10)
        page:Hide()
        f.pages[i] = page
    end

    f.SelectTab = SelectTab
    SelectTab(f, 1)
    return f.pages
end

--------------------------------------------------------------------------------
-- Scrolling
--------------------------------------------------------------------------------

-- A scroll area and its scroll child. The caller anchors `scroll` itself,
-- leaving UI.SCROLLBAR_W of gutter on the right, fills `content`, and calls
-- UI.SetScrollHeight whenever that content changes height.
--
-- `globalName` is required by UIPanelScrollFrameTemplate: the template finds
-- its own scrollbar by appending "ScrollBar" to the frame's name, so an
-- unnamed scroll frame silently has no bar to style or hide.
--
-- scrollBarHideable lets the template drop the bar entirely while everything
-- fits. The gutter stays reserved either way, so nothing shifts sideways at the
-- moment the bar appears.
function UI.CreateScroll(parent, globalName)
    local scroll = CreateFrame("ScrollFrame", globalName, parent,
        "UIPanelScrollFrameTemplate")
    scroll.scrollBarHideable = true

    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT")
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    -- The native bar draws a thumb and arrows over nothing; this is the track
    -- they run in, one frame level behind so the template's own art stays on
    -- top. It follows the bar in and out of view.
    local bar = globalName and _G[globalName .. "ScrollBar"]
    if bar then
        local track = CreateFrame("Frame", nil, scroll, UI.TEMPLATE)
        track:SetAllPoints(bar)
        track:SetFrameLevel(math.max(scroll:GetFrameLevel(),
            bar:GetFrameLevel() - 1))
        track:SetBackdrop(UI.SCROLL_TRACK_BACKDROP)
        scroll.uiScrollBar   = bar
        scroll.uiScrollTrack = track
    end

    -- The scroll child's width has to track the viewport or the content lays
    -- itself out against the 1px placeholder above.
    scroll:HookScript("OnSizeChanged", function(self, w)
        content:SetWidth(w)
        if self.uiContentHeight then UI.SetScrollHeight(self, self.uiContentHeight) end
    end)

    return scroll, content
end

-- Tell a scroll area how tall its content became. Hides the bar and its track
-- while everything fits, and snaps back to the top when it does - a scroll
-- offset left over from taller content strands the view on empty space.
function UI.SetScrollHeight(scroll, height)
    scroll.uiContentHeight = height
    scroll:GetScrollChild():SetHeight(math.max(height, 1))
    scroll:UpdateScrollChildRect()

    local needed = height > scroll:GetHeight() + 0.5
    if scroll.uiScrollBar   then scroll.uiScrollBar:SetShown(needed) end
    if scroll.uiScrollTrack then scroll.uiScrollTrack:SetShown(needed) end
    if not needed then scroll:SetVerticalScroll(0) end
end

--------------------------------------------------------------------------------
-- Sections
--
-- A section is a boxed list with a title and a right-aligned strip of header
-- buttons, stacked vertically with its siblings. WhoDoesWhat's assignment
-- sections are the original; these are the same primitives with the
-- WhoDoesWhat-specific parts (two columns, mass-mail buttons, class tints)
-- taken out, so a caller with one column and no mail can use them too.
--------------------------------------------------------------------------------

UI.SECTION_GAP      = 10   -- between stacked section boxes
UI.SECTION_TITLE_H  = 22   -- box interior reserved for the title strip
UI.BOX_PAD          = 8    -- section box inner margin
UI.ROW_H            = 24
UI.ROW_ICON         = 18   -- gear/action icons on a row
UI.HEADER_BTN_SIZE  = 22
UI.HEADER_STRIP_TOP = 5    -- box top to the top of the header button strip
UI.EMPTY_ROWS_H     = 22   -- rows area height while the list is empty

local function TowardWhite(value, amount)
    return value + (1 - value) * amount
end

-- Boxed section shell: a lighter inset panel with a title on the header strip's
-- midline, so the title text and the header buttons share a line.
--
-- Alternating row colours are derived from the panel colour and cached on the
-- box, so rows tint with the panel instead of being picked twice.
function UI.CreateSectionBox(parent, titleText)
    local box = CreateFrame("Frame", nil, parent, UI.TEMPLATE)
    -- Explicit level: same-level siblings render in unstable order, and the box
    -- backdrop can end up drawing over its own rows until something moves and
    -- re-sorts the frames.
    box:SetFrameLevel(parent:GetFrameLevel() + 1)
    box:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    local r, g, b = 0.16, 0.16, 0.18
    box:SetBackdropColor(r, g, b, 1)
    box:SetBackdropBorderColor(0.4, 0.4, 0.4)
    box.rowColors = {
        { TowardWhite(r, 0.09), TowardWhite(g, 0.09), TowardWhite(b, 0.09) },
        { TowardWhite(r, 0.04), TowardWhite(g, 0.04), TowardWhite(b, 0.04) },
    }

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local font, size = title:GetFont()
    if font and size then title:SetFont(font, size + 2, "OUTLINE") end
    title:SetTextColor(0.95, 0.95, 0.95)
    -- Anchored by LEFT, which vertically centers a FontString, onto the header
    -- strip's midline. Move HEADER_STRIP_TOP and the title follows the buttons.
    title:SetPoint("LEFT", box, "TOPLEFT", UI.BOX_PAD + 2,
        -(UI.HEADER_STRIP_TOP + UI.HEADER_BTN_SIZE / 2))
    title:SetText(titleText)
    box.title = title

    box.headerChain, box.rows = {}, {}
    return box
end

-- Re-anchor a box's header buttons right to left, skipping hidden ones, so the
-- rightmost VISIBLE button hugs the corner instead of leaving a hole. The chain
-- is stored rightmost-first. Run after anything that changes visibility.
function UI.LayoutHeaderChain(box)
    local prev
    for _, btn in ipairs(box.headerChain) do
        if btn:IsShown() then
            btn:ClearAllPoints()
            if prev then
                btn:SetPoint("RIGHT", prev, "LEFT", -2, 0)
            else
                btn:SetPoint("TOPRIGHT", box, "TOPRIGHT",
                    -UI.BOX_PAD, -UI.HEADER_STRIP_TOP)
            end
            prev = btn
        end
    end
end

-- Standard tooltip for a control. While the button is disabled it shows
-- btn.disabledReason instead of the body, so a dead button explains itself
-- rather than just going grey.
function UI.AddTooltip(btn, title, body)
    -- Button-only, and this is called on sliders and anything else with a
    -- tooltip too. Without it a disabled widget stops firing OnEnter, so the
    -- explanation of WHY it is disabled goes away exactly when it is wanted -
    -- which is the whole point of disabledReason.
    if btn.SetMotionScriptsWhileDisabled then
        btn:SetMotionScriptsWhileDisabled(true)
    end
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if self.IsEnabled and not self:IsEnabled() and self.disabledReason then
            GameTooltip:AddLine(self.disabledReason, 1, 0.4, 0.4, true)
        elseif body then
            GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Small text button for a section's header strip - the [+] of an add control,
-- or anything else with a word on it. Appended to the box's chain; call
-- LayoutHeaderChain to place it.
function UI.AddHeaderTextButton(box, text, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btn:SetFrameLevel(box:GetFrameLevel() + 1)
    btn:SetHeight(UI.HEADER_BTN_SIZE)
    btn:SetText(text)
    -- Width from the label: a fixed size crams longer labels against the
    -- template's side bevels, and a bare "+" leaves a stretched empty button.
    btn:SetWidth(math.max(UI.HEADER_BTN_SIZE, btn:GetTextWidth() + 16))
    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)
    box.headerChain[#box.headerChain + 1] = btn
    return btn
end

-- The window's round red close button, reused for the small delete and
-- clear-all controls so they match the title bar's.
--
-- UIPanelCloseButton's texture is mostly transparent padding around a small X,
-- so the textures are grown past the frame: the visible X then fills the
-- button's footprint without the frame changing size and breaking the columns.
function UI.CreateCloseButton(parent, size, growFactor)
    local s = size or UI.HEADER_BTN_SIZE
    local btn = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(s, s)
    btn:SetMotionScriptsWhileDisabled(true)
    local grow = s * (growFactor or 0.3)
    for _, tex in ipairs({ btn:GetNormalTexture(), btn:GetPushedTexture(),
        btn:GetHighlightTexture(), btn:GetDisabledTexture() }) do
        if tex then
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", -grow, grow)
            tex:SetPoint("BOTTOMRIGHT", grow, -grow)
        end
    end
    return btn
end

-- The [x] of a section header. Same button, wired and chained.
function UI.AddHeaderCloseButton(box, tooltipTitle, tooltipText, OnClick)
    local btn = UI.CreateCloseButton(box)
    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)
    box.headerChain[#box.headerChain + 1] = btn
    return btn
end

-- A checkbox, sized to sit in a row rather than at Blizzard's default 32px.
-- The label is optional: in a list the row's own text is the label, and a
-- second one beside the box just repeats it.
function UI.CreateCheckbox(parent, labelText, tooltipTitle, tooltipText, OnClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetFrameLevel(parent:GetFrameLevel() + 1)
    cb:SetSize(UI.ROW_H - 4, UI.ROW_H - 4)
    cb:SetScript("OnClick", OnClick)
    if labelText then
        local label = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        label:SetText(labelText)
        cb.label = label
    end
    UI.AddTooltip(cb, tooltipTitle, tooltipText)
    return cb
end

-- Enable or grey out a run of widgets in one call, for a master switch that
-- turns off everything under it.
--
-- Buttons and checkboxes are disabled, which keeps their tooltips alive
-- (AddTooltip sets MotionScriptsWhileDisabled) so a greyed control can still
-- say why it is greyed. Textures and font strings have no disabled state, so
-- they are faded instead - and fading everything means the disabled ones read
-- as off too, rather than only slightly different.
function UI.SetEnabled(enabled, ...)
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if w then
            if w.Enable and w.Disable then
                if enabled then w:Enable() else w:Disable() end
            end
            if w.SetAlpha then w:SetAlpha(enabled and 1 or 0.35) end
        end
    end
end

-- A slider with its caption above it. OptionsSliderTemplate finds its own Low,
-- High and Text regions by appending to the frame's name, so this one needs a
-- global name whether or not anything else looks it up.
--
-- The Low/High captions are blanked: they would read "0" and "100" under every
-- slider in the addon, and the caption above already says what the number is.
function UI.CreateSlider(parent, globalName, minValue, maxValue, step, OnChange)
    local s = CreateFrame("Slider", globalName, parent, "OptionsSliderTemplate")
    s:SetFrameLevel(parent:GetFrameLevel() + 1)
    s:SetWidth(180)
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    -- Retail-era addition, present on both clients, guarded like every other
    -- optional member. Without it a drag reports every fractional position.
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end

    if _G[globalName .. "Low"]  then _G[globalName .. "Low"]:SetText("") end
    if _G[globalName .. "High"] then _G[globalName .. "High"]:SetText("") end
    s.title = _G[globalName .. "Text"]

    s:SetScript("OnValueChanged", function(self, value)
        -- SetValue fires this too. Without the guard, a refresh that pushes the
        -- saved value in would call back and re-save it, and a drag would fight
        -- the refresh for the handle.
        if self.settingValue then return end
        if OnChange then OnChange(self, value) end
    end)
    return s
end

-- Push a value in without the OnChange coming back out.
function UI.SetSliderValue(s, value)
    s.settingValue = true
    s:SetValue(value)
    s.settingValue = nil
end

-- A dropdown bound to a fixed list of { value, label }. Blizzard's dropdown
-- carries a lot of transparent housing, so StyleDropdown trims it to something
-- that fits a row; see that function for the numbers.
--
-- `Selected` is asked for the current value on every open rather than the
-- caller pushing one in, so the control cannot disagree with what it is showing.
function UI.CreateDropdown(parent, globalName, width, choices, Selected, OnPick)
    local dd = CreateFrame("Frame", globalName, parent, "UIDropDownMenuTemplate")
    dd:SetFrameLevel(parent:GetFrameLevel() + 1)
    UI.StyleDropdown(dd, true)

    local function Label(value)
        for _, entry in ipairs(choices) do
            if entry.value == value then return entry.label end
        end
        return tostring(value)
    end

    UIDropDownMenu_Initialize(dd, function()
        local current = Selected()
        for _, entry in ipairs(choices) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.label
            info.checked = entry.value == current
            info.func = function()
                OnPick(entry.value)
                UIDropDownMenu_SetText(dd, Label(entry.value))
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(dd, width)

    function dd:Sync() UIDropDownMenu_SetText(self, Label(Selected())) end
    dd:Sync()
    return dd
end

UI.GEAR_ICON = "Interface\\Buttons\\UI-OptionsButton"

-- The gear. A framed button with the icon sitting inside it rather than a bare
-- texture, so it matches the [x] and the text buttons beside it and lands in
-- the same column - a naked icon in a row of framed buttons reads as a
-- different kind of control. The 14px icon inside a 22px button is what leaves
-- it room to look like a button at all.
function UI.CreateGearButton(parent, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(UI.HEADER_BTN_SIZE, UI.HEADER_BTN_SIZE)
    btn:SetText("")
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(UI.GEAR_ICON)
    btn.icon = icon
    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)
    return btn
end

-- One section row at the standard grid position: full box width inside the
-- padding, ROW_H tall, row #index sitting under the title strip. Rows are
-- pooled on the box - a refresh reuses row 1 rather than creating a new one -
-- so the caller asks for a row by index and fills it.
function UI.CreateSectionRow(box, index)
    local row = box.rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, box)
    row:SetFrameLevel(box:GetFrameLevel() + 1)
    row:SetHeight(UI.ROW_H)
    row:SetPoint("TOPLEFT", UI.BOX_PAD,
        -(UI.BOX_PAD + UI.SECTION_TITLE_H + (index - 1) * UI.ROW_H))
    row:SetPoint("TOPRIGHT", -UI.BOX_PAD,
        -(UI.BOX_PAD + UI.SECTION_TITLE_H + (index - 1) * UI.ROW_H))

    local color = box.rowColors[index % 2 == 1 and 1 or 2]
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(color[1], color[2], color[3], 1)

    box.rows[index] = row
    return row
end

-- Grey hint in the rows area, for a section with nothing to show.
function UI.CreateEmptyHint(box)
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", UI.BOX_PAD + 4,
        -(UI.BOX_PAD + UI.SECTION_TITLE_H + 4))
    hint:SetTextColor(0.55, 0.55, 0.55)
    return hint
end

-- Size a box to hold `count` rows, and hide any pooled row past that count.
-- An empty list still gets EMPTY_ROWS_H so the hint has somewhere to sit.
function UI.SetSectionRowCount(box, count)
    for i = count + 1, #box.rows do box.rows[i]:Hide() end
    local rowsH = count > 0 and count * UI.ROW_H or UI.EMPTY_ROWS_H
    box:SetHeight(UI.BOX_PAD * 2 + UI.SECTION_TITLE_H + rowsH)
end

-- Stack visible section boxes down a parent, chaining each to the one above so
-- a hidden box leaves no gap. Returns the total height, which is what a scroll
-- area wants to hear. Idempotent - safe to run on every refresh.
function UI.StackSections(parent, boxes)
    local prev, total = nil, 0
    for _, box in ipairs(boxes) do
        if box:IsShown() then
            box:ClearAllPoints()
            if prev then
                box:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -UI.SECTION_GAP)
                box:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -UI.SECTION_GAP)
            else
                box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
                box:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
            end
            prev = box
            total = total + box:GetHeight() + UI.SECTION_GAP
        end
    end
    return total
end

--------------------------------------------------------------------------------
-- Prompts
--
-- One reusable modal per addon: a name field, an optional dropdown, Accept and
-- Cancel. Reconfigured per Ask rather than rebuilt, so the same window serves
-- every "add a thing" control and they all behave identically.
--
-- Not a StaticPopup. StaticPopupDialogs cannot carry a dropdown without
-- anchoring one to a frame it does not own, and its stack is Blizzard's - the
-- rest of the addon keeps preferredIndex 3 to stay off it.
--------------------------------------------------------------------------------

local PROMPT_W        = 300   -- default; opts.width widens one that needs it
local PROMPT_PAD      = UI.BOX_PAD + 6
local PROMPT_BASE_H   = 104   -- heading + edit box + buttons
local PROMPT_ROW_H    = 40    -- added when the dropdown is in play
local PROMPT_SLIDER_H = 34    -- added when the slider is in play
local PROMPT_CHECK_MS = 0.4   -- typing settles this long before Validate runs

-- opts:
--   title    the heading, in the prompt itself - there is no title bar
--   width    frame width; defaults to PROMPT_W
--   hint     greyed text inside the empty edit box, e.g. "Character name"
--   text     value the edit box opens with (may be nil)
--   choices  { { value = ..., label = ... }, ... }; nil hides the dropdown
--   choice   which choice value starts selected
--   slider   { label, min, max, step, value, OnChange } or nil for no slider.
--            Laid out inline - caption, then the handle - and left aligned, so
--            it reads as one row rather than a full-width band. Live: OnChange
--            fires as it moves, because the point of a volume is hearing it.
--   reset    function; adds a Reset button. Closes the prompt.
--   accept   accept button label, default "Add"
--   allowEmpty  accept an empty box; for a prompt where blank means "reset"
--   Validate function(text) -> ok, reason. Runs a moment after typing stops and
--            greys the accept button when it says no. Return nil to abstain -
--            a validator with no opinion must not disable anything.
--   OnAccept function(text, choiceValue) - not called with an empty name
function UI.CreatePrompt(globalName)
    -- Bare: a pop-up, not a window. The buttons already dismiss it, and a title
    -- bar on something this small is a third of its height spent saying again
    -- what the heading says.
    local p = UI.CreateWindow(globalName, PROMPT_W, PROMPT_BASE_H, "", true)
    -- Above DIALOG so it lands on top of the window that opened it.
    p:SetFrameStrata("FULLSCREEN_DIALOG")

    local heading = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetPoint("TOPLEFT", PROMPT_PAD, -(UI.INSET + 10))
    p.heading = heading

    -- Anchored to both edges rather than given a width, so opts.width is the
    -- only place a size is decided.
    local edit = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    edit:SetHeight(20)
    edit:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 6, -8)
    edit:SetPoint("RIGHT", p, "RIGHT", -PROMPT_PAD, 0)
    edit:SetAutoFocus(true)
    p.edit = edit

    -- Placeholder. This client's EditBox has no Instructions region, so it is a
    -- font string on top of the box, hidden the moment there is anything to
    -- read underneath it.
    local hint = edit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 4, 0)
    p.hint = hint

    -- Why the accept button is grey, under the box that caused it.
    local problem = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    problem:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", 2, -3)
    problem:SetTextColor(1, 0.35, 0.35)
    problem:Hide()
    p.problem = problem

    -- UIDropDownMenuTemplate finds its own regions by name, so this one needs
    -- a global name of its own even though nothing else looks it up.
    local dd = CreateFrame("Frame", globalName .. "Choice", p,
        "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", -22, -8)
    UI.StyleDropdown(dd, true)
    p.dropdown = dd

    -- Caption and handle on one line, left aligned. A slider stretched across
    -- the whole pop-up reads as the main event; this one is a detail on a row.
    local sliderLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.sliderLabel = sliderLabel

    local slider = UI.CreateSlider(p, globalName .. "Slider", 0, 100, 5, nil)
    slider:SetWidth(150)
    -- The template's own caption sits above the handle and would fight the
    -- inline one, so it is emptied rather than hidden - hiding a region the
    -- template also touches invites it coming back.
    if slider.title then slider.title:SetText("") end
    p.slider = slider

    -- Cancel left, Reset middle, accept right: the destructive-ish one is
    -- nowhere near the one people reach for, and Reset is not a third option in
    -- the same sentence as the other two.
    local cancel = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    cancel:SetSize(84, 22)
    cancel:SetPoint("BOTTOMLEFT", PROMPT_PAD, UI.INSET + 8)
    cancel:SetText(CANCEL)
    cancel:SetScript("OnClick", function() p:Hide() end)
    p.cancel = cancel

    local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    reset:SetSize(70, 22)
    reset:SetPoint("BOTTOM", 0, UI.INSET + 8)
    reset:SetText("Reset")
    p.reset = reset

    local accept = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    accept:SetSize(84, 22)
    accept:SetPoint("BOTTOMRIGHT", -PROMPT_PAD, UI.INSET + 8)
    p.accept = accept

    local function Accept()
        local text = strtrim(edit:GetText() or "")
        -- An empty box is normally a mis-click, not an answer. A prompt that
        -- means something BY being empty says so.
        if text == "" and not p.allowEmpty then return end
        if not accept:IsEnabled() then return end
        p:Hide()
        if p.OnAccept then p.OnAccept(text, p.choice) end
    end
    accept:SetScript("OnClick", Accept)
    edit:SetScript("OnEnterPressed", Accept)
    edit:SetScript("OnEscapePressed", function() p:Hide() end)

    -- Validation runs a moment AFTER typing stops, never per keystroke: the
    -- callers that have one check a file by trying to play it, and doing that
    -- on every letter of a path would be a machine gun.
    --
    -- The token is what makes the delay safe - a timer that fires after another
    -- keystroke has already been typed finds a token that has moved on, and
    -- does nothing rather than judging text that is no longer there.
    local function Check()
        if not p.Validate then return end
        p.checkToken = (p.checkToken or 0) + 1
        local mine = p.checkToken
        C_Timer.After(PROMPT_CHECK_MS, function()
            if mine ~= p.checkToken or not p:IsShown() then return end
            local ok, reason = p.Validate(strtrim(p.edit:GetText() or ""))
            -- nil abstains. Only an explicit false disables anything.
            if ok == false then
                accept:Disable()
                problem:SetText(reason or "")
                problem:SetShown(reason ~= nil)
            else
                accept:Enable()
                problem:Hide()
            end
        end)
    end

    edit:SetScript("OnTextChanged", function(self)
        hint:SetShown((self:GetText() or "") == "")
        Check()
    end)

    -- Menus are children of UIParent, not of this frame, so one left open would
    -- outlive the prompt and hang in mid-air.
    p:SetScript("OnHide", function() CloseDropDownMenus() end)

    function p:Ask(opts)
        self:SetWidth(opts.width or PROMPT_W)
        self.heading:SetText(opts.title or "")
        self.hint:SetText(opts.hint or "")
        self.OnAccept = opts.OnAccept
        self.Validate = opts.Validate
        self.allowEmpty = opts.allowEmpty
        self.accept:SetText(opts.accept or "Add")
        self.accept:Enable()
        self.problem:Hide()

        if opts.reset then
            self.reset:Show()
            self.reset:SetScript("OnClick", function()
                self:Hide()
                opts.reset()
            end)
        else
            self.reset:Hide()
        end

        self.choices = opts.choices
        self.choice = opts.choice or (opts.choices and opts.choices[1].value)
        if opts.choices then
            self.dropdown:Show()
            UIDropDownMenu_Initialize(self.dropdown, function()
                for _, entry in ipairs(self.choices) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = entry.label
                    info.checked = entry.value == self.choice
                    info.func = function()
                        self.choice = entry.value
                        UIDropDownMenu_SetText(self.dropdown, entry.label)
                        CloseDropDownMenus()
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end)
            UIDropDownMenu_SetWidth(self.dropdown, (opts.width or PROMPT_W) - 90)
            for _, entry in ipairs(opts.choices) do
                if entry.value == self.choice then
                    UIDropDownMenu_SetText(self.dropdown, entry.label)
                end
            end
            self:SetHeight(PROMPT_BASE_H + PROMPT_ROW_H)
        else
            self.dropdown:Hide()
            self:SetHeight(PROMPT_BASE_H)
        end

        -- The slider row hangs off whatever the last thing above it is, so its
        -- anchor is set here rather than at build time.
        if opts.slider then
            local above = opts.choices and self.dropdown or self.edit
            local dx = opts.choices and 22 or 2

            self.sliderLabel:ClearAllPoints()
            self.sliderLabel:SetPoint("TOPLEFT", above, "BOTTOMLEFT", dx, -14)
            self.slider:ClearAllPoints()
            self.slider:SetPoint("LEFT", self.sliderLabel, "RIGHT", 10, 0)

            self.slider:SetMinMaxValues(opts.slider.min or 0, opts.slider.max or 100)
            self.slider:SetValueStep(opts.slider.step or 5)
            self.slider.OnChange = opts.slider.OnChange
            self.slider:SetScript("OnValueChanged", function(s, value)
                if s.settingValue then return end
                if opts.slider.label then
                    self.sliderLabel:SetText(format(opts.slider.label, value))
                end
                if s.OnChange then s.OnChange(value) end
            end)
            UI.SetSliderValue(self.slider, opts.slider.value or 100)
            if opts.slider.label then
                self.sliderLabel:SetText(format(opts.slider.label,
                    opts.slider.value or 100))
            end
            self.sliderLabel:Show()
            self.slider:Show()
            self:SetHeight(self:GetHeight() + PROMPT_SLIDER_H)
        else
            self.sliderLabel:Hide()
            self.slider:Hide()
        end

        self.edit:SetText(opts.text or "")
        self:Show()
        self.edit:SetFocus()
        -- After SetText, or the caret sits in front of the name they were
        -- handed and typing prepends to it.
        self.edit:SetCursorPosition(strlen(opts.text or ""))
        -- Judge what it opened with, not only what gets typed into it.
        Check()
    end

    return p
end

--------------------------------------------------------------------------------
-- Blizzard widgets
--------------------------------------------------------------------------------

-- Apply the compact treatment to Blizzard's legacy dropdown chrome. Its three
-- housing textures are 64px tall (with transparent padding) around a 24px
-- arrow. Trim and position that housing without scaling any click target or
-- menu content, then place its label and arrow independently.
--
-- No caller in TagTeam. See the header: it stays so the copies match.
function UI.StyleDropdown(dd, leftAlign)
    local name = dd:GetName()
    if not name then return end

    if not dd.uiHousingStyled then
        for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
            local texture = _G[name .. suffix]
            if texture then texture:SetHeight(57) end
        end
        local left   = _G[name .. "Left"]
        local button = _G[name .. "Button"]
        local label  = _G[name .. "Text"]
        -- Middle and Right are chained from Left, so moving Left shifts the
        -- entire housing. Its dependent arrow/text anchors follow it; leave the
        -- arrow 0.5px and text 2.8px lower, then nudge the arrow right.
        if left   then left:AdjustPointsOffset(0, -3) end
        if button then button:AdjustPointsOffset(2, 2.5) end
        if label  then label:AdjustPointsOffset(0, 0.2) end
        dd.uiHousingStyled = true
    end

    if leftAlign and not dd.uiTextAligned then
        local label = _G[name .. "Text"]
        if label then
            label:SetJustifyH("LEFT")
            label:SetWidth(label:GetWidth() + 5)
            label:AdjustPointsOffset(0, -1)
        end
        dd.uiTextAligned = true
    end
end
