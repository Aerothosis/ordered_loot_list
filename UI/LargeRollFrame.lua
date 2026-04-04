------------------------------------------------------------------------
-- OrderedLootList  –  UI/LargeRollFrame.lua
-- Large two-panel roll window: item list (left) + all-player choices (right).
-- Resizable.  Receives real-time choice updates via CHOICES_UPDATE broadcast.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local LargeRollFrame              = {}
ns.LargeRollFrame                 = LargeRollFrame

------------------------------------------------------------------------
-- Layout constants
------------------------------------------------------------------------
local FRAME_WIDTH        = 820
local FRAME_HEIGHT       = 500
local LEFT_PANEL_W       = 260
local DIVIDER_W          = 2
local HEADER_H           = 38   -- Pass All + Timer + Close
local DROPDOWN_H         = 30   -- Boss dropdown height inside left panel
local ITEM_ROW_H         = 34   -- item name + optional badge line
local ROLL_BTN_AREA_H    = 28   -- player's own roll buttons at top of right panel
local SEP_H              = 1    -- thin separator
local COL_HEADER_H       = 18   -- column label row

-- Column x-offsets within the right panel scroll child (0-based from left)
local COL_CHOICE_X       = 180  -- "Choice" column start
local COL_ROLL_X         = 290  -- "Roll" column start
local COL_COUNT_X        = 360  -- "Count" column start

local PLAYER_ROW_H       = 20

-- Priority colours for choices (same as LeaderFrame)
local OPT_PRIORITY_COLORS = {
    [1] = { 0.20, 0.90, 0.20 },
    [2] = { 1.00, 0.82, 0.00 },
    [3] = { 1.00, 0.50, 0.10 },
    [4] = { 0.30, 0.90, 1.00 },
    [5] = { 0.80, 0.30, 1.00 },
    [6] = { 1.00, 0.40, 0.70 },
}
local OPT_COLOR_FALLBACK = { 0.80, 0.80, 0.80 }
local OPT_COLOR_PASS     = { 0.55, 0.55, 0.55 }
local OPT_COLOR_WAITING  = { 0.42, 0.42, 0.42 }

------------------------------------------------------------------------
-- Internal state
------------------------------------------------------------------------
LargeRollFrame._frame           = nil
LargeRollFrame._timerBar        = nil
LargeRollFrame._timerDuration   = 30
LargeRollFrame._respondedItems  = {}  -- [itemIdx] = true
LargeRollFrame._rollOptions     = nil
LargeRollFrame._optPriority     = {}  -- [optName] = priority (built in ShowAllItems)
LargeRollFrame._items           = nil -- current items array
LargeRollFrame._selectedItemIdx = 1
LargeRollFrame._viewingHistory  = false
LargeRollFrame._historyBossKey  = nil
LargeRollFrame._choices         = {}  -- [itemIdx][playerName] = { choice, countAtRoll, roll }
LargeRollFrame._hiddenForCombat = false
LargeRollFrame._itemRowPool     = {}
LargeRollFrame._playerRowPool   = {}
LargeRollFrame._rollBtnPool     = {}  -- roll buttons in right panel header
LargeRollFrame._bossDropdown    = nil
LargeRollFrame._leftScrollChild = nil
LargeRollFrame._rightScrollChild= nil
LargeRollFrame._rollBtnContainer = nil
LargeRollFrame._selectedItemLabel = nil  -- text above right panel roll buttons

------------------------------------------------------------------------
-- Create / return the main frame (lazy init)
------------------------------------------------------------------------
function LargeRollFrame:GetFrame()
    if self._frame then return self._frame end

    local theme = ns.Theme:GetCurrent()

    local f = CreateFrame("Frame", "OLLLargeRollFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frm)
        frm:StopMovingOrSizing()
        ns.SaveFramePosition("LargeRollFrame", frm)
    end)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(frm) ns.RaiseFrame(frm) end)

    -- Resizable
    f._posKey = "LargeRollFrame"
    f:SetResizable(true)
    f:SetResizeBounds(500, 300)

    -----------------------------------------------------------------------
    -- Header
    -----------------------------------------------------------------------
    local passAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    passAllBtn:SetSize(100, 22)
    passAllBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -8)
    passAllBtn:SetText("Pass All Loot")
    passAllBtn:SetScript("OnClick", function()
        LargeRollFrame:AutoPassAll()
    end)
    passAllBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Pass All Loot", 1, 1, 1)
        GameTooltip:AddLine("Passes on all items you have not already\nmade a choice for.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    passAllBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.passAllBtn = passAllBtn

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() LargeRollFrame:Hide() end)

    -- Timer bar (fills space between Pass All and Close button)
    local timerBar = CreateFrame("StatusBar", nil, f)
    timerBar:SetHeight(14)
    timerBar:SetPoint("LEFT",  passAllBtn, "RIGHT",   8,  0)
    timerBar:SetPoint("RIGHT", closeBtn,   "LEFT",   -8,  0)
    timerBar:SetPoint("TOP",   f,          "TOP",     0, -12)
    timerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
    timerBar:SetMinMaxValues(0, 1)
    timerBar:SetValue(1)
    local timerBg = timerBar:CreateTexture(nil, "BACKGROUND")
    timerBg:SetAllPoints()
    timerBg:SetColorTexture(unpack(theme.timerBarBgColor))
    timerBar.bg = timerBg
    local timerText = timerBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timerText:SetPoint("CENTER")
    timerBar.text = timerText
    f.timerBar   = timerBar
    self._timerBar = timerBar

    -- Thin horizontal separator below header
    local hDiv = f:CreateTexture(nil, "ARTWORK")
    hDiv:SetHeight(1)
    hDiv:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -HEADER_H)
    hDiv:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -HEADER_H)
    hDiv:SetColorTexture(unpack(theme.dividerColor))
    f.hDiv = hDiv

    -----------------------------------------------------------------------
    -- Left panel
    -----------------------------------------------------------------------
    local leftPanel = CreateFrame("Frame", nil, f)
    leftPanel:SetPoint("TOPLEFT",    f, "TOPLEFT",    8, -(HEADER_H + 2))
    leftPanel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8,  8)
    leftPanel:SetWidth(LEFT_PANEL_W)
    f.leftPanel = leftPanel

    -- Boss history dropdown (locked during active rolls)
    local dropdown = CreateFrame("Frame", "OLLLargeBossDropdown", leftPanel, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", -8, -2)
    UIDropDownMenu_SetWidth(dropdown, LEFT_PANEL_W - 14)
    UIDropDownMenu_SetText(dropdown, "Current Roll")
    UIDropDownMenu_Initialize(dropdown, function(dd, level)
        LargeRollFrame:_PopulateBossDropdown(dd, level)
    end)
    f.bossDropdown  = dropdown
    self._bossDropdown = dropdown

    -- Left scroll frame (below dropdown, to bottom of left panel)
    local leftSF = CreateFrame("ScrollFrame", "OLLLargeLeftScrollFrame", leftPanel, "UIPanelScrollFrameTemplate")
    leftSF:SetPoint("TOPLEFT",     leftPanel, "TOPLEFT",     0,  -(DROPDOWN_H + 2))
    leftSF:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -16, 0)
    f.leftScrollFrame = leftSF

    local leftSC = CreateFrame("Frame", nil, leftSF)
    leftSC:SetSize(LEFT_PANEL_W - 20, 1)
    leftSF:SetScrollChild(leftSC)
    f.leftScrollChild = leftSC
    self._leftScrollChild = leftSC

    -----------------------------------------------------------------------
    -- Vertical divider
    -----------------------------------------------------------------------
    local vDiv = f:CreateTexture(nil, "ARTWORK")
    vDiv:SetWidth(DIVIDER_W)
    vDiv:SetPoint("TOPLEFT",    leftPanel, "TOPRIGHT",    2, 0)
    vDiv:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMRIGHT", 2, 0)
    vDiv:SetColorTexture(unpack(theme.dividerColor))
    f.vDiv = vDiv

    -----------------------------------------------------------------------
    -- Right panel
    -----------------------------------------------------------------------
    local rightPanel = CreateFrame("Frame", nil, f)
    rightPanel:SetPoint("TOPLEFT",    leftPanel, "TOPRIGHT",    DIVIDER_W + 4, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", f,        "BOTTOMRIGHT", -8,            8)
    f.rightPanel = rightPanel

    -- Selected item label (top of right panel, shows which item's data is displayed)
    local selLabel = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selLabel:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 4, -2)
    selLabel:SetPoint("RIGHT",   rightPanel, "RIGHT",   -4, 0)
    selLabel:SetJustifyH("LEFT")
    selLabel:SetTextColor(unpack(theme.bossTextColor))
    selLabel:SetText("")
    f.selectedItemLabel     = selLabel
    self._selectedItemLabel = selLabel

    -- Roll buttons for the local player (per selected item)
    local rollBtnContainer = CreateFrame("Frame", nil, rightPanel)
    rollBtnContainer:SetPoint("TOPLEFT",  rightPanel, "TOPLEFT",  4,  -(16))
    rollBtnContainer:SetPoint("RIGHT",    rightPanel, "RIGHT",    -4,  0)
    rollBtnContainer:SetHeight(ROLL_BTN_AREA_H)
    f.rollBtnContainer       = rollBtnContainer
    self._rollBtnContainer   = rollBtnContainer

    -- Separator between roll buttons and player list
    local sep = rightPanel:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(SEP_H)
    sep:SetPoint("TOPLEFT",  rollBtnContainer, "BOTTOMLEFT",  0, -2)
    sep:SetPoint("TOPRIGHT", rollBtnContainer, "BOTTOMRIGHT", 0, -2)
    sep:SetColorTexture(unpack(theme.dividerColor))

    -- Column header labels
    local colY = -(16 + ROLL_BTN_AREA_H + 6)
    local colHeaderRow = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colHeaderRow:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 4, colY)
    colHeaderRow:SetText("Player")
    colHeaderRow:SetTextColor(1.00, 0.82, 0.00)

    local colChoiceHeader = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colChoiceHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", COL_CHOICE_X, colY)
    colChoiceHeader:SetText("Choice")
    colChoiceHeader:SetTextColor(1.00, 0.82, 0.00)

    local colRollHeader = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colRollHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", COL_ROLL_X, colY)
    colRollHeader:SetText("Roll")
    colRollHeader:SetTextColor(1.00, 0.82, 0.00)

    local colCountHeader = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colCountHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", COL_COUNT_X, colY)
    colCountHeader:SetText("Count")
    colCountHeader:SetTextColor(1.00, 0.82, 0.00)

    -- Right scroll frame (player list)
    local rightSF = CreateFrame("ScrollFrame", "OLLLargeRightScrollFrame", rightPanel, "UIPanelScrollFrameTemplate")
    local rightSFTopOffset = 16 + ROLL_BTN_AREA_H + 6 + COL_HEADER_H + 2
    rightSF:SetPoint("TOPLEFT",    rightPanel, "TOPLEFT",    0,  -rightSFTopOffset)
    rightSF:SetPoint("BOTTOMRIGHT",rightPanel, "BOTTOMRIGHT", -16, 0)
    f.rightScrollFrame = rightSF

    local rightSC = CreateFrame("Frame", nil, rightSF)
    rightSC:SetSize(400, 1)
    rightSF:SetScrollChild(rightSC)
    f.rightScrollChild = rightSC
    self._rightScrollChild = rightSC

    -----------------------------------------------------------------------
    -- Resize grip
    -----------------------------------------------------------------------
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    grip:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then f:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then
            f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
            ns.SaveFramePosition("LargeRollFrame", f)
        end
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        ns.SaveFramePosition("LargeRollFrame", f)
    end)

    -----------------------------------------------------------------------
    -- Combat hide/show
    -----------------------------------------------------------------------
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:HookScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if f:IsShown() then
                LargeRollFrame._hiddenForCombat = true
                f:Hide()
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if LargeRollFrame._hiddenForCombat then
                LargeRollFrame._hiddenForCombat = false
                f:Show()
            end
        end
    end)

    f:Hide()
    self._frame = f
    ns.RestoreFramePosition("LargeRollFrame", f)
    return f
end

------------------------------------------------------------------------
-- Apply current theme to the frame
------------------------------------------------------------------------
function LargeRollFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    if f.timerBar then
        f.timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
        if f.timerBar.bg then f.timerBar.bg:SetColorTexture(unpack(theme.timerBarBgColor)) end
    end
    if f.hDiv  then f.hDiv:SetColorTexture(unpack(theme.dividerColor)) end
    if f.vDiv  then f.vDiv:SetColorTexture(unpack(theme.dividerColor)) end
end

------------------------------------------------------------------------
-- Show all items for a new loot roll
------------------------------------------------------------------------
function LargeRollFrame:ShowAllItems(items, rollOptions)
    local f = self:GetFrame()

    self._rollOptions    = rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self._respondedItems = {}
    self._items          = items
    self._viewingHistory = false
    self._historyBossKey = nil
    self._choices        = {}

    -- Build option→priority lookup
    self._optPriority = {}
    for _, opt in ipairs(self._rollOptions) do
        self._optPriority[opt.name] = opt.priority
    end

    -- Pre-populate choices from Session.responses if we're the leader
    if ns.IsLeader() and ns.Session and ns.Session.responses then
        for idx, resps in pairs(ns.Session.responses) do
            self._choices[idx] = {}
            for pName, data in pairs(resps) do
                self._choices[idx][pName] = data
            end
        end
    end

    self:LockBossDropdown()
    UIDropDownMenu_SetText(self._bossDropdown, "Current Roll")

    -- Timer setup
    local duration = ns.db.profile.rollTimer or 30
    if ns.Session and ns.Session.sessionSettings then
        duration = ns.Session.sessionSettings.rollTimer or duration
    end
    self._timerDuration = duration
    f.timerBar:SetMinMaxValues(0, duration)
    f.timerBar:SetValue(duration)
    f.timerBar.text:SetText(duration .. "s")
    f.timerBar:Show()

    -- Select first item by default
    self._selectedItemIdx = 1

    self:_RefreshLeftPanel()
    self:_RefreshRightPanel()

    -- Auto-pass off-spec items
    if ns.db.profile.autoPassOffSpec ~= false then
        local playerStat = ns.RF_GetPlayerMainStat and ns.RF_GetPlayerMainStat() or nil
        if playerStat then
            for idx, item in ipairs(items) do
                local itemStat = ns.RF_GetItemMainStat and ns.RF_GetItemMainStat(item.link) or nil
                if itemStat and itemStat ~= playerStat then
                    self:_OnRollChoiceInternal(idx, "Pass")
                end
            end
        end
    end

    -- Auto-pass unequippable items
    if ns.db.profile.autoPassUnequippable then
        for idx, item in ipairs(items) do
            if not self._respondedItems[idx] then
                local typeIsRed = false
                if ns.RF_GetItemTypeLabelAndColor then
                    local _, red = ns.RF_GetItemTypeLabelAndColor(item.link)
                    typeIsRed = red or false
                end
                if typeIsRed then
                    self:_OnRollChoiceInternal(idx, "Pass")
                end
            end
        end
    end

    f:Show()
end

------------------------------------------------------------------------
-- Refresh left panel: item list
------------------------------------------------------------------------
function LargeRollFrame:_RefreshLeftPanel()
    local sc = self._leftScrollChild
    if not sc then return end
    local theme = ns.Theme:GetCurrent()

    -- Return all pooled rows
    for _, row in ipairs(self._itemRowPool) do
        row:Hide()
        row._inUse = false
    end

    local items   = self._viewingHistory
        and (ns.Session and ns.Session.bossHistory
            and ns.Session.bossHistory[self._historyBossKey]
            and ns.Session.bossHistory[self._historyBossKey].items or {})
        or  (self._items or {})

    local yOffset = 0
    local poolIdx = 1

    for idx, item in ipairs(items) do
        local row = self._itemRowPool[poolIdx]
        if not row then
            row = CreateFrame("Frame", nil, sc, "BackdropTemplate")
            row:SetSize(sc:GetWidth(), ITEM_ROW_H)
            row:SetBackdrop({
                bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile     = true,
                tileSize = 16,
                edgeSize = 8,
                insets   = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            -- Name text
            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameText:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
            nameText:SetPoint("RIGHT",   row, "RIGHT",  -6,  0)
            nameText:SetJustifyH("LEFT")
            nameText:SetWordWrap(false)
            row.nameText = nameText
            -- Stat badge region
            local badgeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            badgeText:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 4)
            badgeText:SetTextColor(0.6, 0.8, 0.6)
            row.badgeText = badgeText
            -- Result overlay text (winner or "No winner")
            local resultText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            resultText:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 4)
            resultText:SetJustifyH("RIGHT")
            row.resultText = resultText
            -- Click to select
            row:EnableMouse(true)
            -- Highlight texture
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.08)
            row.hl = hl

            tinsert(self._itemRowPool, row)
        end
        poolIdx = poolIdx + 1

        -- Position
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("RIGHT",   sc, "RIGHT",   0, 0)
        row:SetHeight(ITEM_ROW_H)
        row._inUse = true

        -- Appearance: selected vs normal
        local isSelected = (not self._viewingHistory) and (idx == self._selectedItemIdx)
        if isSelected then
            row:SetBackdropColor(unpack(theme.selectedColor or {0.2, 0.35, 0.55, 0.85}))
        else
            row:SetBackdropColor(unpack(theme.rowBgColor))
        end
        row:SetBackdropBorderColor(unpack(theme.rowBorderColor))

        -- Item name
        local rqr, rqg, rqb = GetItemQualityColor(item.quality or 1)
        row.nameText:SetTextColor(rqr, rqg, rqb)
        row.nameText:SetText(item.name or "Unknown")

        -- Badge line: stat badge text + type label
        local badgeParts = {}
        if ns.db.profile.showStatBadge ~= false then
            local itemStat = ns.RF_GetItemMainStat and ns.RF_GetItemMainStat(item.link) or nil
            if itemStat then tinsert(badgeParts, itemStat) end
        end
        local typeLabel = ns.RF_GetItemTypeLabelAndColor
            and (ns.RF_GetItemTypeLabelAndColor(item.link)) or nil
        if typeLabel then tinsert(badgeParts, typeLabel) end
        row.badgeText:SetText(table.concat(badgeParts, "  "))

        -- Result text (for history view or resolved items)
        local result = nil
        if self._viewingHistory then
            local hist = ns.Session and ns.Session.bossHistory
                and ns.Session.bossHistory[self._historyBossKey]
            result = hist and hist.results and hist.results[idx]
        else
            result = ns.Session and ns.Session.results and ns.Session.results[idx]
        end

        if result and result.winner then
            row.resultText:SetText(ns.StripRealm(result.winner))
            row.resultText:SetTextColor(0.4, 1.0, 0.4)
            row.resultText:Show()
        elseif result then
            row.resultText:SetText("No winner")
            row.resultText:SetTextColor(0.6, 0.6, 0.6)
            row.resultText:Show()
        else
            row.resultText:Hide()
        end

        -- Tooltip
        local _rowLink = item.link
        row:SetScript("OnEnter", function(rf)
            if _rowLink then
                GameTooltip:SetOwner(rf, "ANCHOR_RIGHT")
                if _rowLink:find("|H") then
                    GameTooltip:SetHyperlink(_rowLink)
                else
                    GameTooltip:SetText(_rowLink)
                end
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)

        -- Click handler (capture idx in local for closure)
        local capturedIdx = idx
        row:SetScript("OnMouseDown", function()
            if not self._viewingHistory then
                self._selectedItemIdx = capturedIdx
                self:_RefreshLeftPanel()
                self:_RefreshRightPanel()
            end
        end)

        row:Show()
        yOffset = yOffset - ITEM_ROW_H
    end

    sc:SetHeight(math.max(math.abs(yOffset), 1))
end

------------------------------------------------------------------------
-- Refresh right panel: player choice list for selected item
------------------------------------------------------------------------
function LargeRollFrame:_RefreshRightPanel()
    if not self._frame then return end
    local theme = ns.Theme:GetCurrent()

    -- Update selected item label
    local items = self._items
    local itemIdx = self._selectedItemIdx
    local item = items and items[itemIdx]
    if self._selectedItemLabel then
        if item then
            self._selectedItemLabel:SetText("Item " .. itemIdx .. ": " .. (item.name or "Unknown"))
        else
            self._selectedItemLabel:SetText("")
        end
    end

    -- Rebuild roll buttons for local player
    self:_RebuildRollButtons(itemIdx)

    -- Return all pooled player rows
    local sc = self._rightScrollChild
    if not sc then return end
    for _, row in ipairs(self._playerRowPool) do
        row:Hide()
        row._inUse = false
    end

    -- Build sorted player list
    local playerList = self:_BuildSortedPlayerList(itemIdx)

    local yOffset = 0
    local poolIdx = 1

    for _, entry in ipairs(playerList) do
        local row = self._playerRowPool[poolIdx]
        if not row then
            row = CreateFrame("Frame", nil, sc)
            row:SetHeight(PLAYER_ROW_H)

            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameText:SetPoint("LEFT",  row, "LEFT",  4, 0)
            nameText:SetWidth(COL_CHOICE_X - 8)
            nameText:SetJustifyH("LEFT")
            nameText:SetWordWrap(false)
            row.nameText = nameText

            local choiceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            choiceText:SetPoint("LEFT", row, "LEFT", COL_CHOICE_X, 0)
            choiceText:SetWidth(COL_ROLL_X - COL_CHOICE_X - 4)
            choiceText:SetJustifyH("LEFT")
            row.choiceText = choiceText

            local rollText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rollText:SetPoint("LEFT", row, "LEFT", COL_ROLL_X, 0)
            rollText:SetWidth(COL_COUNT_X - COL_ROLL_X - 4)
            rollText:SetJustifyH("LEFT")
            row.rollText = rollText

            local countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            countText:SetPoint("LEFT", row, "LEFT", COL_COUNT_X, 0)
            countText:SetWidth(50)
            countText:SetJustifyH("LEFT")
            row.countText = countText

            tinsert(self._playerRowPool, row)
        end
        poolIdx = poolIdx + 1

        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("RIGHT",   sc, "RIGHT",   0, 0)
        row._inUse = true

        -- Player name (strip realm for display, highlight self)
        local displayName = ns.StripRealm and ns.StripRealm(entry.player) or entry.player
        local isSelf = ns.NamesMatch(entry.player, ns.GetPlayerNameRealm())
        if isSelf then
            row.nameText:SetTextColor(1.0, 0.85, 0.0)
        else
            row.nameText:SetTextColor(0.85, 0.85, 0.85)
        end
        row.nameText:SetText(displayName or "")

        -- Choice text and color
        local choiceColor = OPT_COLOR_WAITING
        if entry.choice == nil then
            row.choiceText:SetText("Waiting")
            choiceColor = OPT_COLOR_WAITING
        elseif entry.choice == "Pass" then
            row.choiceText:SetText("Pass")
            choiceColor = OPT_COLOR_PASS
        else
            row.choiceText:SetText(entry.choice)
            local pri = self._optPriority[entry.choice]
            choiceColor = (pri and OPT_PRIORITY_COLORS[pri]) or OPT_COLOR_FALLBACK
        end
        row.choiceText:SetTextColor(unpack(choiceColor))

        -- Roll number — only shown if player has made a choice
        if entry.choice ~= nil then
            row.rollText:SetText(tostring(entry.roll or "-"))
            row.rollText:SetTextColor(0.85, 0.85, 0.85)
        else
            row.rollText:SetText("-")
            row.rollText:SetTextColor(0.42, 0.42, 0.42)
        end

        -- Loot count
        row.countText:SetText(tostring(entry.count or 0))
        row.countText:SetTextColor(unpack(theme.countTextColor or {0.85, 0.85, 0.85}))

        row:Show()
        yOffset = yOffset - PLAYER_ROW_H
    end

    sc:SetHeight(math.max(math.abs(yOffset), 1))
end

------------------------------------------------------------------------
-- Build sorted player list for a given item index
-- Sort: by priority asc, then count asc, then roll desc.
-- Waiting players always last.  Pass players second-to-last.
------------------------------------------------------------------------
function LargeRollFrame:_BuildSortedPlayerList(itemIdx)
    local choices = self._choices[itemIdx] or {}
    local eligibleSet = ns.Session and ns.Session:GetEligiblePlayers() or {}

    -- Collect all players (eligible set + anyone with a choice)
    local seen = {}
    local playerList = {}

    for playerName in pairs(eligibleSet) do
        seen[playerName] = true
        local data = choices[playerName]
        local pri
        if data and data.choice == nil then
            pri = 1000
        elseif data and data.choice == "Pass" then
            pri = 900
        elseif data then
            pri = self._optPriority[data.choice] or 500
        else
            pri = 1000
        end
        tinsert(playerList, {
            player  = playerName,
            choice  = data and data.choice or nil,
            roll    = data and data.roll or nil,
            count   = data and data.countAtRoll or ns.LootCount:GetCount(playerName),
            priority = pri,
        })
    end

    -- Also include anyone who responded but wasn't in eligible set
    for playerName, data in pairs(choices) do
        if not seen[playerName] then
            local pri
            if data.choice == "Pass" then
                pri = 900
            else
                pri = self._optPriority[data.choice] or 500
            end
            tinsert(playerList, {
                player   = playerName,
                choice   = data.choice,
                roll     = data.roll,
                count    = data.countAtRoll or ns.LootCount:GetCount(playerName),
                priority = pri,
            })
        end
    end

    -- Sort
    table.sort(playerList, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if (a.count or 0) ~= (b.count or 0) then return (a.count or 0) < (b.count or 0) end
        if (a.roll or 0) ~= (b.roll or 0) then return (a.roll or 0) > (b.roll or 0) end
        return (a.player or "") < (b.player or "")
    end)

    return playerList
end

------------------------------------------------------------------------
-- Rebuild the local player's roll buttons for the selected item
------------------------------------------------------------------------
function LargeRollFrame:_RebuildRollButtons(itemIdx)
    local container = self._rollBtnContainer
    if not container then return end

    -- Hide all pooled buttons
    for _, btn in ipairs(self._rollBtnPool) do
        btn:Hide()
    end

    if not itemIdx or not self._items or not self._items[itemIdx] then
        return
    end

    -- If viewing history, don't show roll buttons
    if self._viewingHistory then return end

    -- If the roll has a result, show result text instead
    local result = ns.Session and ns.Session.results and ns.Session.results[itemIdx]
    if result then
        -- Show a result label, no buttons
        if not container._resultLabel then
            container._resultLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            container._resultLabel:SetPoint("LEFT", container, "LEFT", 0, 0)
        end
        if result.winner then
            container._resultLabel:SetText("Won by: " .. (ns.StripRealm(result.winner) or result.winner)
                .. "  (" .. (result.choice or "?") .. "  roll " .. (result.roll or 0) .. ")")
            container._resultLabel:SetTextColor(0.4, 1.0, 0.4)
        else
            container._resultLabel:SetText("No winner")
            container._resultLabel:SetTextColor(0.6, 0.6, 0.6)
        end
        container._resultLabel:Show()
        return
    end

    if container._resultLabel then container._resultLabel:Hide() end

    -- If player already chose this item, show status text
    if self._respondedItems[itemIdx] then
        if not container._chosenLabel then
            container._chosenLabel = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            container._chosenLabel:SetPoint("LEFT", container, "LEFT", 0, 0)
        end
        -- Find what this player chose from _choices
        local myChoice = nil
        local myChoices = self._choices[itemIdx]
        if myChoices then
            myChoice = myChoices[ns.GetPlayerNameRealm()]
            if myChoice then myChoice = myChoice.choice end
        end
        container._chosenLabel:SetText("You chose: " .. (myChoice or "?"))
        container._chosenLabel:SetTextColor(0.5, 0.9, 0.5)
        container._chosenLabel:Show()
        return
    end

    if container._chosenLabel then container._chosenLabel:Hide() end

    -- Build buttons for available roll options
    local rollOptions = self._rollOptions or ns.DEFAULT_ROLL_OPTIONS
    local numBtns = #rollOptions + 1
    local BTN_W   = 60
    local BTN_H   = ROLL_BTN_AREA_H - 4
    local poolIdx = 1
    local capturedItemIdx = itemIdx

    for i, opt in ipairs(rollOptions) do
        local btn = self._rollBtnPool[poolIdx]
        if not btn then
            btn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
            tinsert(self._rollBtnPool, btn)
        end
        poolIdx = poolIdx + 1

        btn:SetSize(BTN_W, BTN_H)
        btn:SetPoint("LEFT", container, "LEFT", (i - 1) * (BTN_W + 3), 0)
        btn:SetText(opt.name)

        local fs = btn:GetFontString()
        if fs then
            local fp = fs:GetFont()
            if fp then fs:SetFont(fp, 10) end
            if opt.colorR then fs:SetTextColor(opt.colorR, opt.colorG, opt.colorB) end
        end

        local capturedOptName = opt.name
        btn:SetScript("OnClick", function()
            LargeRollFrame:OnRollChoice(capturedItemIdx, capturedOptName)
        end)
        btn:Show()
    end

    -- Pass button
    local passBtn = self._rollBtnPool[poolIdx]
    if not passBtn then
        passBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        tinsert(self._rollBtnPool, passBtn)
    end
    passBtn:SetSize(BTN_W, BTN_H)
    passBtn:SetPoint("LEFT", container, "LEFT", #rollOptions * (BTN_W + 3), 0)
    passBtn:SetText("Pass")
    local pfs = passBtn:GetFontString()
    if pfs then
        local pf = pfs:GetFont()
        if pf then pfs:SetFont(pf, 10) end
        pfs:SetTextColor(0.5, 0.5, 0.5)
    end
    passBtn:SetScript("OnClick", function()
        LargeRollFrame:OnRollChoice(capturedItemIdx, "Pass")
    end)
    passBtn:Show()
end

------------------------------------------------------------------------
-- Handle a roll choice from the local player (via button click or auto-pass)
------------------------------------------------------------------------
function LargeRollFrame:OnRollChoice(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self:_OnRollChoiceInternal(itemIdx, choice)
end

function LargeRollFrame:_OnRollChoiceInternal(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self._respondedItems[itemIdx] = true

    if ns.Session then
        ns.Session:SubmitResponse(itemIdx, choice)
    end

    -- Refresh display for the affected item
    if itemIdx == self._selectedItemIdx then
        self:_RebuildRollButtons(itemIdx)
        self:_RefreshRightPanel()
    end
    self:_RefreshLeftPanel()

    -- If all items answered, hide timer
    if ns.Session and ns.Session.currentItems then
        local allDone = true
        for idx = 1, #ns.Session.currentItems do
            if not self._respondedItems[idx] then allDone = false; break end
        end
        if allDone and self._timerBar then
            self._timerBar:Hide()
        end
    end
end

------------------------------------------------------------------------
-- External selection: leader forces this player's choice
------------------------------------------------------------------------
function LargeRollFrame:SetExternalSelection(itemIdx, choice)
    self._respondedItems[itemIdx] = nil
    self:_OnRollChoiceInternal(itemIdx, choice)
end

------------------------------------------------------------------------
-- Reset item choice (retry after failed ACK)
------------------------------------------------------------------------
function LargeRollFrame:ResetItemChoice(itemIdx)
    self._respondedItems[itemIdx] = nil
    if itemIdx == self._selectedItemIdx then
        self:_RebuildRollButtons(itemIdx)
        self:_RefreshRightPanel()
    end
end

------------------------------------------------------------------------
-- Auto-pass all un-responded items
------------------------------------------------------------------------
function LargeRollFrame:AutoPassAll()
    if not ns.Session then return end
    for idx = 1, #(ns.Session.currentItems or {}) do
        if not self._respondedItems[idx] then
            self:_OnRollChoiceInternal(idx, "Pass")
        end
    end
end

------------------------------------------------------------------------
-- Receive real-time choice update broadcast from leader (CHOICES_UPDATE)
------------------------------------------------------------------------
function LargeRollFrame:UpdateChoices(payload)
    if payload and payload.choices then
        self._choices = payload.choices
    end
    -- Only refresh if showing the current boss
    if self._frame and self._frame:IsShown() and not self._viewingHistory then
        self:_RefreshRightPanel()
        self:_RefreshLeftPanel()
    end
end

------------------------------------------------------------------------
-- Show result for a specific item (panels read from Session.results directly)
------------------------------------------------------------------------
function LargeRollFrame:ShowResult(itemIdx, result)
    if not self._frame or not self._frame:IsShown() then return end
    if self._viewingHistory then return end
    -- Refresh left panel to annotate the resolved item with the winner name
    self:_RefreshLeftPanel()
    -- If this is the currently selected item, refresh right panel too
    if itemIdx == self._selectedItemIdx then
        self:_RefreshRightPanel()
    end
end

------------------------------------------------------------------------
-- Timer tick
------------------------------------------------------------------------
function LargeRollFrame:OnTimerTick(remaining)
    if not self._frame or not self._frame:IsShown() then return end
    if self._viewingHistory then return end
    if remaining <= 0 then
        remaining = 0
        self:AutoPassAll()
    end
    local theme = ns.Theme:GetCurrent()
    self._timerBar:SetValue(remaining)
    self._timerBar.text:SetText(math.ceil(remaining) .. "s")
    if remaining < 5 then
        self._timerBar:SetStatusBarColor(unpack(theme.timerBarLowColor))
    elseif remaining < 10 then
        self._timerBar:SetStatusBarColor(unpack(theme.timerBarMidColor))
    else
        self._timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
    end
end

------------------------------------------------------------------------
-- Boss history dropdown
------------------------------------------------------------------------
function LargeRollFrame:_PopulateBossDropdown(dropdown, level)
    if not ns.Session then return end

    -- "Current Roll" option
    local currentInfo = UIDropDownMenu_CreateInfo()
    currentInfo.text = "Current Roll"
    currentInfo.notCheckable = true
    currentInfo.func = function()
        LargeRollFrame._viewingHistory = false
        LargeRollFrame._historyBossKey = nil
        UIDropDownMenu_SetText(dropdown, "Current Roll")
        LargeRollFrame:_RefreshLeftPanel()
        LargeRollFrame:_RefreshRightPanel()
    end
    UIDropDownMenu_AddButton(currentInfo, level)

    -- Historical bosses
    local keys = ns.Session:GetBossHistoryKeys()
    if #keys == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text    = "No history yet"
        info.disabled = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
        return
    end

    for _, key in ipairs(keys) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = key
        info.notCheckable = true
        local capturedKey = key
        info.func = function()
            LargeRollFrame:_ShowBossHistory(capturedKey)
            UIDropDownMenu_SetText(dropdown, capturedKey)
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

------------------------------------------------------------------------
-- Switch left + right panels to a historical boss
------------------------------------------------------------------------
function LargeRollFrame:_ShowBossHistory(bossKey)
    local data = ns.Session and ns.Session:GetBossHistory(bossKey)
    if not data then return end

    self._viewingHistory = true
    self._historyBossKey = bossKey
    self._selectedItemIdx = 1

    if self._frame and self._frame.timerBar then
        self._frame.timerBar:Hide()
    end

    -- Right panel in history mode: show ranked candidates for selected item
    self:_RefreshLeftPanel()
    self:_RefreshHistoryRightPanel()
end

------------------------------------------------------------------------
-- Right panel for historical boss: shows ranked results
------------------------------------------------------------------------
function LargeRollFrame:_RefreshHistoryRightPanel()
    local sc = self._rightScrollChild
    if not sc then return end

    -- Hide roll buttons area
    if self._rollBtnContainer then
        for _, btn in ipairs(self._rollBtnPool) do btn:Hide() end
        if self._rollBtnContainer._chosenLabel then self._rollBtnContainer._chosenLabel:Hide() end
        if self._rollBtnContainer._resultLabel then
            local data = ns.Session and ns.Session.bossHistory
                and ns.Session.bossHistory[self._historyBossKey]
            local result = data and data.results and data.results[self._selectedItemIdx]
            if result and result.winner then
                self._rollBtnContainer._resultLabel:SetText(
                    "Won by: " .. (ns.StripRealm(result.winner) or result.winner)
                    .. "  (" .. (result.choice or "?") .. "  roll " .. (result.roll or 0) .. ")")
                self._rollBtnContainer._resultLabel:SetTextColor(0.4, 1.0, 0.4)
                self._rollBtnContainer._resultLabel:Show()
            else
                self._rollBtnContainer._resultLabel:SetText("No winner")
                self._rollBtnContainer._resultLabel:SetTextColor(0.6, 0.6, 0.6)
                self._rollBtnContainer._resultLabel:Show()
            end
        end
    end

    -- Update selected item label
    local data = ns.Session and ns.Session.bossHistory
        and ns.Session.bossHistory[self._historyBossKey]
    local item = data and data.items and data.items[self._selectedItemIdx]
    if self._selectedItemLabel then
        self._selectedItemLabel:SetText(
            self._historyBossKey .. " – " ..
            (item and (item.name or "Unknown") or ""))
    end

    -- Return pooled rows
    for _, row in ipairs(self._playerRowPool) do
        row:Hide()
        row._inUse = false
    end

    -- Build ranked list from results
    local result = data and data.results and data.results[self._selectedItemIdx]
    local candidates = result and result.rankedCandidates or {}

    local yOffset = 0
    local poolIdx = 1
    local theme   = ns.Theme:GetCurrent()

    for _, cand in ipairs(candidates) do
        local row = self._playerRowPool[poolIdx]
        if not row then
            row = CreateFrame("Frame", nil, sc)
            row:SetHeight(PLAYER_ROW_H)
            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
            nameText:SetWidth(COL_CHOICE_X - 8)
            nameText:SetJustifyH("LEFT")
            nameText:SetWordWrap(false)
            row.nameText = nameText
            local choiceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            choiceText:SetPoint("LEFT", row, "LEFT", COL_CHOICE_X, 0)
            choiceText:SetWidth(COL_ROLL_X - COL_CHOICE_X - 4)
            row.choiceText = choiceText
            local rollText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rollText:SetPoint("LEFT", row, "LEFT", COL_ROLL_X, 0)
            rollText:SetWidth(COL_COUNT_X - COL_ROLL_X - 4)
            row.rollText = rollText
            local countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            countText:SetPoint("LEFT", row, "LEFT", COL_COUNT_X, 0)
            countText:SetWidth(50)
            row.countText = countText
            tinsert(self._playerRowPool, row)
        end
        poolIdx = poolIdx + 1

        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("RIGHT",   sc, "RIGHT",   0, 0)
        row._inUse = true

        local displayName = ns.StripRealm and ns.StripRealm(cand.player) or cand.player
        row.nameText:SetText(displayName or "")
        local isSelf = ns.NamesMatch(cand.player, ns.GetPlayerNameRealm())
        row.nameText:SetTextColor(isSelf and 1.0 or 0.85, isSelf and 0.85 or 0.85, isSelf and 0.0 or 0.85)

        row.choiceText:SetText(cand.choice or "?")
        local pri = self._optPriority and self._optPriority[cand.choice]
        local choiceColor = (pri and OPT_PRIORITY_COLORS[pri]) or OPT_COLOR_FALLBACK
        row.choiceText:SetTextColor(unpack(choiceColor))

        row.rollText:SetText(tostring(cand.roll or "-"))
        row.rollText:SetTextColor(0.85, 0.85, 0.85)

        row.countText:SetText(tostring(cand.count or 0))
        row.countText:SetTextColor(unpack(theme.countTextColor or {0.85, 0.85, 0.85}))

        row:Show()
        yOffset = yOffset - PLAYER_ROW_H
    end

    sc:SetHeight(math.max(math.abs(yOffset), 1))
end

------------------------------------------------------------------------
-- Boss dropdown lock / unlock
------------------------------------------------------------------------
function LargeRollFrame:LockBossDropdown()
    if self._bossDropdown then
        UIDropDownMenu_DisableDropDown(self._bossDropdown)
    end
end

function LargeRollFrame:UnlockBossDropdown()
    if self._bossDropdown then
        UIDropDownMenu_EnableDropDown(self._bossDropdown)
        -- If we were showing history but are now in a new roll, reset to current
        if self._viewingHistory then
            self._viewingHistory = false
            self._historyBossKey = nil
            UIDropDownMenu_SetText(self._bossDropdown, "Current Roll")
        end
    end
end

------------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------------
function LargeRollFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

function LargeRollFrame:Hide()
    if self._frame then self._frame:Hide() end
end

function LargeRollFrame:Show()
    self:GetFrame():Show()
end

------------------------------------------------------------------------
-- Reset (used when a debug session ends)
------------------------------------------------------------------------
function LargeRollFrame:Reset()
    self:Hide()
    self:UnlockBossDropdown()
    self._respondedItems  = {}
    self._items           = nil
    self._choices         = {}
    self._rollOptions     = nil
    self._optPriority     = {}
    self._viewingHistory  = false
    self._historyBossKey  = nil
    self._selectedItemIdx = 1
    self._timerDuration   = 0
    -- Clear pools
    for _, row in ipairs(self._itemRowPool)   do row:Hide() end
    for _, row in ipairs(self._playerRowPool) do row:Hide() end
    for _, btn in ipairs(self._rollBtnPool)   do btn:Hide() end
    if self._frame and self._frame.timerBar then
        self._timerBar:SetValue(0)
        self._timerBar.text:SetText("")
    end
end
