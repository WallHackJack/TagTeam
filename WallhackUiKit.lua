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
UI.TAB_DROP    = 6    -- title bar to the top of the tabs
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

-- The trough of a horizontal slider, and the height that art is cut for.
--
-- Same two files the scroll track uses, but the insets are NOT the same, and
-- that difference is the whole point. UI-SliderBar-Border is an 8px edge file:
-- a corner piece is 8px tall, so at 8 + 8 = 16 the top and bottom corners of an
-- end cap meet and the cap reads as one rounded shape. Go taller and the
-- backdrop fills the difference by stretching the left and right edge segments
-- between them, and since those segments are cap art rather than a repeating
-- rail, what you get is four disjointed corners with nothing joining them. That
-- is the whole bug: the height, not the insets.
--
-- 15 rather than 16, so the two corners overlap by a pixel instead of merely
-- touching. Not a number worth deriving - it is what AceGUI-3.0's slider widget
-- and DBM-GUI's panel prototype both use, which between them is most of the
-- sliders anybody running this game has ever looked at.
UI.SLIDER_H = 15
UI.SLIDER_BACKDROP = {
    bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 6, bottom = 6 },
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

-- Retitling goes through here so the version suffix cannot be lost by a caller
-- that only meant to change the name. WhoDoesWhat re-sets its main title
-- whenever a peer reports a version, and a plain SetText there would drop the
-- stamp - or, worse, keep it by pasting the parenthesis together at the call
-- site, which is the drift this kit exists to stop.
--
-- A colour escape rather than a second font string: one region keeps the name
-- and the version centred as a single unit, which is what actually reads as a
-- title bar. Two regions would centre one of them and hang the other off its
-- edge, leaving the pair off-centre by half the stamp's width.
local function SetTitle(f, text)
    text = text or ""
    if UI.VERSION then
        text = text .. " |cff808080(v" .. UI.VERSION .. ")|r"
    end
    f.titleText:SetText(text)
end

-- A standard window: solid black, a centred title bar carrying the name and the
-- version, a close button, draggable by anywhere on it, closes on Escape.
--
-- The title reads `Name (vX.Y.Z)`, the parenthesis greyed against the gold of
-- the name. Retitle with `f:SetTitle("Name")` - it re-applies the stamp, so no
-- caller ever spells the parenthesis out. `bare` windows have no title bar and
-- therefore no `SetTitle`.
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
    -- Centred on the BAR, not on the window, and the bar is anchored to both
    -- edges - so a window that changes width re-centres its own title with no
    -- arithmetic and nothing to keep in step. WhoDoesWhat's main window does
    -- this by hand today against `f` TOP with a half-height offset; this is the
    -- same result without the offset to get wrong.
    title:SetPoint("CENTER", titlebar, "CENTER", 0, 0)
    f.titleText = title

    f.SetTitle = SetTitle
    f:SetTitle(titleText)

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
--
-- Depth is part of "selected" here, which is what gives the row its folder
-- shape: the selected tab comes forward OVER the panel, so its bottom edge and
-- its underline sit on top of the panel's border and it reads as one piece with
-- the page below. Every other tab drops BEHIND the panel, and the border runs
-- unbroken across them.
--
-- Both levels are derived from the panel rather than written down, so the only
-- thing that has to stay true is the gap AddTabs leaves around it.
local function SelectTab(f, index)
    local panelLevel = f.tabPanel:GetFrameLevel()
    for i, tab in ipairs(f.tabs) do
        local on = i == index
        tab.bg:SetColorTexture(on and 0.22 or 0.10, on and 0.22 or 0.10,
                               on and 0.26 or 0.12, 1)
        tab.label:SetTextColor(on and 1 or 0.65, on and 0.82 or 0.65,
                               on and 0 or 0.65)
        tab.underline:SetShown(on)
        -- +2 clears the pages, which are the panel's own children at +1.
        tab:SetFrameLevel(on and panelLevel + 2 or panelLevel - 1)
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
-- `specs` is a list of `{ label = "...", page = "..." }`; adding a tab is adding
-- an entry, and nothing here counts them by hand. The caller fills each page and
-- otherwise ignores the machinery; it can set `f.onTabSelected` to hear about
-- switches, and call `f:SelectTab(i)` to drive one from outside.
--
-- Returns the pages under BOTH keys: the index, and `spec.page` when a spec
-- carries one. Reach for the name - `pages.sounds`, not `pages[6]`. The index is
-- what the tab row itself runs on and cannot go away, but a caller that counts
-- positions is one inserted tab away from building the wrong page onto the wrong
-- label, and nothing would say so: every page is the same empty frame, so the
-- mistake surfaces as a tab full of its neighbour's contents rather than as an
-- error. `page` is a stable key precisely because it is not the label - the
-- label is the part that gets reworded.
--
-- Every page fills the panel and all but the selected one is hidden, so they
-- stack and no page needs to know anything about the others.
function UI.AddTabs(f, specs)
    f.tabs, f.pages = {}, {}

    -- The panel is deliberately parked THREE levels above the window, and every
    -- tab level is measured from it (see SelectTab). The gap underneath is the
    -- point: an unselected tab has to be below the panel to tuck behind it, and
    -- still above `f` to be clickable at all.
    --
    -- That second half is easy to lose. `f` is mouse-enabled - it is what you
    -- drag the window by - so a tab left on the same level as `f` is not merely
    -- drawn wrong, it stops receiving clicks entirely, and the tabs go dead with
    -- nothing in the log to say why. One level of clearance is what keeps them
    -- alive; the panel needs the extra one so its own pages sit under a
    -- brought-forward tab.
    local panel = CreateFrame("Frame", nil, f, UI.TEMPLATE)
    panel:SetFrameLevel(f:GetFrameLevel() + 3)
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

    for i, spec in ipairs(specs) do
        local page = CreateFrame("Frame", nil, panel)
        page:SetPoint("TOPLEFT", 10, -10)
        page:SetPoint("BOTTOMRIGHT", -10, 10)
        page:Hide()
        f.pages[i] = page
        -- The named key is an ALIAS onto the same frame, not a second page. A
        -- duplicated `page` in the specs would silently overwrite the earlier
        -- alias and leave one tab unreachable by name, so it is caught here
        -- rather than puzzled over later.
        if spec.page then
            if f.pages[spec.page] then
                error(("UI.AddTabs: duplicate page key %q"):format(spec.page), 2)
            end
            f.pages[spec.page] = page
        end
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
UI.ROW_CHECK        = 22   -- a checkbox on a row. Bigger than the icons beside
                           -- it on purpose: it is the control, they are
                           -- shortcuts, and it is the one thing on the row that
                           -- has to be hittable without aiming.
UI.ROW_CLICK_FRAC   = 0.8  -- how much of a row's width toggles it. Its buttons
                           -- live at the right end, and missing one by a pixel
                           -- used to hit the stripe behind it instead.
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

-- The checkbox at the left edge of a section row, and the row behind it as a
-- click target: a checkbox you have to hit exactly is a checkbox people miss,
-- so the label, the icon and the empty space after them toggle it too - out to
-- UI.ROW_CLICK_FRAC, short of wherever the row's own buttons sit.
-- Guarded on the box being live, because a row greyed out by a master
-- switch must not stay clickable through its stripe.
--
-- Stored as row.check, which is where every refresh looks for it.
function UI.AddRowCheckbox(row, labelText, tooltipTitle, tooltipText, OnClick)
    local cb = UI.CreateCheckbox(row, labelText, tooltipTitle, tooltipText,
        OnClick)
    cb:SetSize(UI.ROW_CHECK, UI.ROW_CHECK)
    cb:SetPoint("LEFT", 4, 0)
    row.check = cb

    row:EnableMouse(true)
    -- ...but only the left of the row, so the space around its buttons is not a
    -- second, larger target for the wrong thing. Re-cut on resize: the width is
    -- anchor-driven and still zero here.
    row:SetScript("OnSizeChanged", function(self, width)
        self:SetHitRectInsets(0, (width or 0) * (1 - UI.ROW_CLICK_FRAC), 0, 0)
    end)
    row:SetScript("OnMouseUp", function()
        if cb:IsEnabled() then cb:Click() end
    end)
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

-- A horizontal slider, dressed by hand rather than taken from
-- OptionsSliderTemplate.
--
-- The template was the source of the mismatched end caps. It ships a frame
-- height that does not suit the border art (see UI.SLIDER_H), it carries Low,
-- High and Text regions we blank on every single slider anyway, and the numbers
-- behind all of that differ by client - which is a lot of art we do not control
-- in exchange for three font strings we do not want.
--
-- What is here instead is what AceGUI-3.0 and DBM-GUI both do, to the pixel: a
-- bare Slider on BackdropTemplate, explicitly horizontal, 15 tall, with the
-- SliderBar backdrop and the SliderBar thumb. Those two are the reference
-- implementation by sheer weight of use, and a slider that matches them is a
-- slider that looks like every other addon's.
--
-- `globalName` is no longer needed for region lookups, but it stays: it is what
-- makes a control findable from a /script line while debugging, and callers
-- already pass one.
function UI.CreateSlider(parent, globalName, minValue, maxValue, step, OnChange)
    local s = CreateFrame("Slider", globalName, parent, UI.TEMPLATE)
    s:SetFrameLevel(parent:GetFrameLevel() + 1)
    s:SetOrientation("HORIZONTAL")
    s:SetWidth(180)
    s:SetHeight(UI.SLIDER_H)
    -- The trough is a backdrop and the handle is a thumb texture, both left at
    -- the art's own size. Guarded only because SetBackdrop lives on the
    -- template, and UI.TEMPLATE resolves to nil on a client without it.
    if s.SetBackdrop then s:SetBackdrop(UI.SLIDER_BACKDROP) end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    -- 15px of grabbable height is a thin target for something people drag.
    -- Widened a little top and bottom, but nowhere near AceGUI's -10: its
    -- sliders have empty space under them and ours have the next setting.
    s:SetHitRectInsets(0, 0, -4, -4)
    s:SetMinMaxValues(minValue, maxValue)
    s:SetValueStep(step)
    -- Retail-era addition, present on both clients, guarded like every other
    -- optional member. Without it a drag reports every fractional position.
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end

    s:SetScript("OnValueChanged", function(self, value)
        -- SetValue fires this too. Without the guard, a refresh that pushes the
        -- saved value in would call back and re-save it, and a drag would fight
        -- the refresh for the handle.
        if self.settingValue then return end
        if OnChange then OnChange(self, value) end
    end)

    -- Let go of the handle. A drag reports every step it passes through, so
    -- anything expensive or audible hangs off this rather than off OnChange:
    -- dragging 0 to 100 is twenty values and one release. Fires on a click on
    -- the track too, which is a jump to a value and equally a release.
    s:SetScript("OnMouseUp", function(self)
        if self.OnRelease then self:OnRelease(self:GetValue()) end
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
--
-- An entry carrying `entries` instead of a `value` is a SUBMENU holding that
-- list. This is not decoration: Blizzard's dropdown draws its buttons in one
-- column and does not scroll them, so a list long enough to reach past the
-- screen edge simply has a bottom nobody can get to - which is what a font
-- list borrowed from a media pack does the moment it is more than a screenful.
-- Grouping is the caller's business, since only the caller knows what the list
-- means; all this knows is how to nest one.
function UI.CreateDropdown(parent, globalName, width, choices, Selected, OnPick)
    local dd = CreateFrame("Frame", globalName, parent, "UIDropDownMenuTemplate")
    dd:SetFrameLevel(parent:GetFrameLevel() + 1)
    UI.StyleDropdown(dd, true)

    -- `choices` may be a function, and then it is called EVERY time rather than
    -- resolved once: an entry whose label reports something that moves - where
    -- you currently are, what a setting currently costs - is frozen and wrong
    -- otherwise. A caller whose list is expensive to build memoises it itself.
    local function List()
        return type(choices) == "function" and choices() or choices
    end

    -- Depth first: the label for the box has to be found wherever in the tree
    -- the value ended up, and the caller does not tell us where that was.
    local function Find(value, list)
        for _, entry in ipairs(list) do
            if entry.entries then
                local found = Find(value, entry.entries)
                if found then return found end
            elseif entry.value == value then
                return entry.label
            end
        end
    end

    local function Label(value)
        return Find(value, List()) or tostring(value)
    end

    -- `menuList` is whatever the parent button put in info.menuList, and comes
    -- back here when a submenu opens - so one initialiser serves every level.
    UIDropDownMenu_Initialize(dd, function(_, level, menuList)
        local current = Selected()
        for _, entry in ipairs(menuList and menuList.entries or List()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.label
            if entry.entries then
                -- notCheckable, because a submenu is a way through rather than
                -- a choice: a tick box beside it would be a tick nobody can set.
                info.hasArrow, info.notCheckable = true, true
                info.menuList = entry
            else
                info.checked = entry.value == current
                -- An entry may name a Font OBJECT to draw its own label with.
                -- A font list that shows each name in the font it names is the
                -- whole point of a font list, and a dropdown button takes a
                -- font object or nothing - there is no other way in.
                info.fontObject = entry.font
                info.func = function()
                    OnPick(entry.value)
                    UIDropDownMenu_SetText(dd, Label(entry.value))
                    CloseDropDownMenus()   -- every level, not just this one
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetWidth(dd, width)

    function dd:Sync() UIDropDownMenu_SetText(self, Label(Selected())) end
    dd:Sync()
    return dd
end

UI.GEAR_ICON = "Interface\\Buttons\\UI-OptionsButton"
-- The old voice-chat speaker, which is the only plain volume glyph the client
-- ships outside an ability icon. If it ever comes up blank this is the one line
-- to change - a missing texture draws as nothing rather than erroring.
UI.SPEAKER_ICON = "Interface\\COMMON\\VoiceChat-Speaker"

-- A framed button with an icon inside it rather than a bare texture, so it
-- matches the [x] and the text buttons beside it and lands in the same column -
-- a naked icon in a row of framed buttons reads as a different kind of control.
-- The 14px icon inside a 22px button is what leaves it room to look like a
-- button at all.
function UI.CreateIconButton(parent, iconPath, tooltipTitle, tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(UI.HEADER_BTN_SIZE, UI.HEADER_BTN_SIZE)
    btn:SetText("")
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(iconPath)
    btn.icon = icon
    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)
    return btn
end

-- The gear, by far the commonest of these. Kept as its own name because every
-- caller of it means "settings" rather than "a button with a picture on".
function UI.CreateGearButton(parent, tooltipTitle, tooltipText, OnClick)
    return UI.CreateIconButton(parent, UI.GEAR_ICON,
        tooltipTitle, tooltipText, OnClick)
end

-- The icon and nothing else - no frame, no fill. For a row that already has a
-- framed button on it: two of those side by side read as a button bar, where
-- the point is one control and one shortcut.
--
-- It highlights on hover instead, which is what says it can be clicked. The
-- click target is the button, so it stays the full size whatever the art does.
function UI.CreateBareIconButton(parent, iconPath, size, tooltipTitle,
                                 tooltipText, OnClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetFrameLevel(parent:GetFrameLevel() + 1)
    btn:SetSize(size, size)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(iconPath)
    btn.icon = icon

    btn:SetScript("OnClick", OnClick)
    UI.AddTooltip(btn, tooltipTitle, tooltipText)

    -- Dimmed until you point at it, so a row of them does not shout over the
    -- labels they sit beside. HOOKED rather than set: AddTooltip owns OnEnter
    -- and OnLeave, and setting them after it would take the tooltip with them.
    icon:SetVertexColor(0.75, 0.75, 0.75)
    btn:HookScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 1, 1)
    end)
    btn:HookScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.75, 0.75, 0.75)
    end)
    return btn
end

-- One section row at the standard grid position: full box width inside the
-- padding, ROW_H tall, row #index sitting under the title strip. Rows are
-- pooled on the box - a refresh reuses row 1 rather than creating a new one -
-- so the caller asks for a row by index and fills it.
function UI.CreateSectionRow(box, index)
    local row = box.rows[index]
    if row then return row end

    -- Rows normally hang off the box itself, below its title and whatever strip
    -- has been reserved. A box given its own scroll area (ScrollSectionRows)
    -- puts them in the scroll child instead, where neither offset applies -
    -- the child IS the rows area.
    local host = box.rowHost or box
    local pad  = box.rowHost and 0 or UI.BOX_PAD
    local top  = (box.rowHost and 0
        or (UI.BOX_PAD + UI.SECTION_TITLE_H + (box.rowsInset or 0)))
        + (index - 1) * UI.ROW_H

    row = CreateFrame("Frame", nil, host)
    row:SetFrameLevel(host:GetFrameLevel() + 1)
    row:SetHeight(UI.ROW_H)
    row:SetPoint("TOPLEFT", pad, -top)
    row:SetPoint("TOPRIGHT", -pad, -top)

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
        -(UI.BOX_PAD + UI.SECTION_TITLE_H + (box.rowsInset or 0) + 4))
    hint:SetTextColor(0.55, 0.55, 0.55)
    return hint
end

-- Reserve a strip between a box's title and its first row, for a box whose top
-- is a picture rather than a list. The caller fills the strip itself.
--
-- MUST be called before any row is created: a row anchors once, at creation,
-- and a pooled row that already exists will not move for this.
function UI.ReserveSectionStrip(box, height)
    box.rowsInset = height
end

-- Give a box its own scroll area for its rows, capped at `maxRows` tall.
--
-- For a list with no natural ceiling. Without it a box simply grows and the
-- PAGE scrolls, which is right for a handful of settings and wrong for a list
-- somebody can keep adding to: one long list otherwise pushes everything under
-- it off the bottom, and you scroll the whole tab to reach the next section.
--
-- Must be called before any row is created - a row anchors once, at creation,
-- and rows made before this belong to the box rather than to the scroll child.
--
-- `globalName` is required by UIPanelScrollFrameTemplate; see CreateScroll.
function UI.ScrollSectionRows(box, globalName, maxRows)
    local scroll = UI.CreateScroll(box, globalName)
    scroll:SetPoint("TOPLEFT", UI.BOX_PAD,
        -(UI.BOX_PAD + UI.SECTION_TITLE_H + (box.rowsInset or 0)))
    scroll:SetPoint("BOTTOMRIGHT", -(UI.BOX_PAD + UI.SCROLLBAR_W), UI.BOX_PAD)
    box.rowScroll, box.rowHost, box.maxRows = scroll, scroll:GetScrollChild(), maxRows
end

-- Size a box to hold `count` rows, and hide any pooled row past that count.
-- An empty list still gets EMPTY_ROWS_H so the hint has somewhere to sit.
function UI.SetSectionRowCount(box, count)
    for i = count + 1, #box.rows do box.rows[i]:Hide() end
    local rowsH = count > 0 and count * UI.ROW_H or UI.EMPTY_ROWS_H

    -- A scrolling box stops growing at its cap and lets the bar take over. The
    -- scroll child keeps the FULL height either way - that is what there is to
    -- scroll through.
    local shown = rowsH
    if box.rowHost then
        UI.SetScrollHeight(box.rowScroll, rowsH)
        shown = min(rowsH, box.maxRows * UI.ROW_H)
    end
    box:SetHeight(UI.BOX_PAD * 2 + UI.SECTION_TITLE_H
        + (box.rowsInset or 0) + shown)
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
local PROMPT_BASE_H   = 112   -- heading + edit box + buttons
local PROMPT_ROW_H    = 40    -- added when the dropdown is in play
local PROMPT_SLIDER_H = 50    -- added when the slider is in play: caption over
                              -- handle, so two lines rather than one
local PROMPT_TOGGLE_H = 26    -- and when the checkbox is
local PROMPT_CHECK_MS = 0.4   -- typing settles this long before Validate runs
local PROMPT_BTN_W    = 84    -- all three of them, so the pair on the right lines up
local PROMPT_FIELD_H  = 22    -- added when the field carries a caption line
local PROMPT_EDIT_H   = 30    -- the edit box row itself
local PROMPT_HEADING_H = 22   -- the heading line, at GameFontNormalLarge

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

    -- Centred and a size up: it is the only thing on the pop-up that says WHAT
    -- you are editing, and left-aligned at body size it read as another label.
    local heading = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", PROMPT_PAD, -(UI.INSET + 10))
    heading:SetPoint("TOPRIGHT", -PROMPT_PAD, -(UI.INSET + 10))
    heading:SetJustifyH("CENTER")
    p.heading = heading

    -- A caption in front of the box, for a prompt whose field needs naming.
    -- Hidden when there is nothing to say, and then the box takes the full
    -- width as before.
    local editLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    -- Same width as the slider caption below it, so the field and the handle
    -- start in the same column.
    editLabel:SetJustifyH("CENTER")
    p.editLabel = editLabel

    -- Anchored to both edges rather than given a width, so opts.width is the
    -- only place a size is decided.
    local edit = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    edit:SetHeight(20)
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
    --
    -- FIXED WIDTH, left-justified. The caption carries the value, so its text
    -- gets shorter at 5% than at 100% - and a handle anchored to the right of a
    -- font string that sizes to its text slides left and right as you drag it,
    -- which is exactly the one control where that is unbearable.
    local sliderLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sliderLabel:SetJustifyH("CENTER")
    p.sliderLabel = sliderLabel

    local slider = UI.CreateSlider(p, globalName .. "Slider", 0, 100, 5, nil)
    slider:SetWidth(150)
    -- The template's own caption sits above the handle and would fight the
    -- inline one, so it is emptied rather than hidden - hiding a region the
    -- template also touches invites it coming back.
    p.slider = slider

    -- A switch on the pop-up itself, for the setting somebody came here to
    -- change but would otherwise have to close this and find on another tab.
    p.toggle = UI.CreateCheckbox(p, "", "", "", nil)
    p.toggle:SetSize(UI.ROW_CHECK, UI.ROW_CHECK)

    -- Cancel alone on the left; Reset and the accept button paired on the
    -- right, all three the same width.
    --
    -- Reset next to accept rather than marooned in the middle because it is one
    -- of the two things you can do to the thing you are editing - Cancel is the
    -- way out, and the way out belongs at the far end on its own.
    local cancel = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    cancel:SetSize(PROMPT_BTN_W, 22)
    cancel:SetPoint("BOTTOMLEFT", PROMPT_PAD, UI.INSET + 8)
    cancel:SetText(CANCEL)
    cancel:SetScript("OnClick", function() p:Hide() end)
    p.cancel = cancel

    local accept = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    accept:SetSize(PROMPT_BTN_W, 22)
    accept:SetPoint("BOTTOMRIGHT", -PROMPT_PAD, UI.INSET + 8)
    p.accept = accept

    local reset = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    reset:SetSize(PROMPT_BTN_W, 22)
    reset:SetPoint("RIGHT", accept, "LEFT", -6, 0)
    reset:SetText("Reset")
    p.reset = reset

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

        -- Laid out top down with a RUNNING OFFSET rather than by chaining each
        -- row to the one above it.
        --
        -- Chaining is fine while everything is left aligned. These rows are
        -- centred, and a centred row chained to the row above centres on THAT
        -- row - so a caption under the toggle would centre on a checkbox
        -- sitting at the left edge rather than on the frame. Anchoring every
        -- row to the frame keeps the two things independent: `y` decides how
        -- far down, the frame decides where across.
        local y = -(UI.INSET + 10 + PROMPT_HEADING_H)

        -- The toggle goes ABOVE the field: it decides whether the thing below
        -- it matters at all, and a switch found under the setting it governs is
        -- a switch found second.
        if opts.toggle then
            self.toggle:ClearAllPoints()
            self.toggle:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD + 2, y)
            y = y - PROMPT_TOGGLE_H
        end

        -- A labelled field is a CAPTION OVER A BOX, both centred; an unlabelled
        -- one is the box on its own. Stacked rather than inline because these
        -- pop-ups are narrow and a sound path is long - side by side, the
        -- caption ate a third of the width the value needed.
        self.edit:ClearAllPoints()
        if opts.label then
            self.editLabel:SetText(opts.label)
            self.editLabel:ClearAllPoints()
            -- Both corners at the SAME y: two points that fix the width and one
            -- height between them, which is what a centred line of text needs.
            -- A third point for the vertical would fight these two.
            self.editLabel:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD, y)
            self.editLabel:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PROMPT_PAD, y)
            self.editLabel:Show()
            y = y - PROMPT_FIELD_H
        else
            self.editLabel:Hide()
        end
        self.edit:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD + 6, y - 4)
        self.edit:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PROMPT_PAD, y - 4)
        y = y - PROMPT_EDIT_H

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
            -- Chained to the edit box at build time rather than placed off `y`,
            -- because it is left aligned and has nothing to centre. The running
            -- offset still has to step past it for anything below.
            y = y - PROMPT_ROW_H
        else
            self.dropdown:Hide()
            self:SetHeight(PROMPT_BASE_H)
        end
        -- The caption above the field is a line the base height does not know
        -- about. Added here, before the slider and toggle add theirs.
        if opts.label then self:SetHeight(self:GetHeight() + PROMPT_FIELD_H) end

        -- Placed off `y` like the field above it; see the note there.
        if opts.slider then
            -- Caption over the handle, both centred, same as the field above.
            -- The caption carries the value, so inline it changed width as you
            -- dragged and walked the handle sideways with it; stacked, there is
            -- nothing for the digits to push.
            --
            -- The handle takes ONE point: a Slider has a width of its own, so
            -- TOP against the frame centres it across and places it down in the
            -- same anchor.
            self.sliderLabel:ClearAllPoints()
            self.sliderLabel:SetPoint("TOPLEFT", self, "TOPLEFT", PROMPT_PAD, y - 10)
            self.sliderLabel:SetPoint("TOPRIGHT", self, "TOPRIGHT", -PROMPT_PAD, y - 10)
            self.slider:ClearAllPoints()
            self.slider:SetPoint("TOP", self, "TOP", 0, y - 10 - PROMPT_FIELD_H)

            self.slider:SetMinMaxValues(opts.slider.min or 0, opts.slider.max or 100)
            self.slider:SetValueStep(opts.slider.step or 5)
            self.slider.OnChange = opts.slider.OnChange
            -- Wrapped so a prompt's handlers all take just the value, the way
            -- OnChange above does; the kit hands its own sliders (self, value).
            self.slider.OnRelease = opts.slider.OnRelease and function(_, value)
                opts.slider.OnRelease(value)
            end or nil
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

        -- Anchored above, with the rest of the layout. Only its state and its
        -- handler are set here.
        if opts.toggle then
            self.toggle:SetChecked(opts.toggle.checked and true or false)
            if self.toggle.label then
                self.toggle.label:SetText(opts.toggle.label or "")
            end
            -- Applied as it is clicked rather than on Accept: it is a switch,
            -- not part of the answer being typed, and Cancel on a box you have
            -- already watched take effect would be a strange thing to want -
            -- the same reasoning the volume slider above it uses.
            self.toggle:SetScript("OnClick", function(box)
                if opts.toggle.OnClick then
                    opts.toggle.OnClick(box:GetChecked() and true or false)
                end
            end)
            self.toggle:Show()
            self:SetHeight(self:GetHeight() + PROMPT_TOGGLE_H)
        else
            self.toggle:Hide()
        end

        self.edit:SetText(opts.text or "")
        self:Show()
        self.edit:SetFocus()
        -- Taking focus selects whatever is in the box, and a name handed to the
        -- prompt is a starting point rather than something to type over - a
        -- selected one is gone on the first keystroke. Cleared explicitly
        -- rather than by not focusing: the box should still be ready to type in.
        self.edit:HighlightText(0, 0)
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
