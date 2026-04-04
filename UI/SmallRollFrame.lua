------------------------------------------------------------------------
-- OrderedLootList  –  UI/SmallRollFrame.lua
-- Compact roll window: item name + roll buttons on a single row each.
-- No item icon, no stat badge, no gear type label.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local SmallRollFrame          = {}
ns.SmallRollFrame             = SmallRollFrame

local FRAME_WIDTH             = 380
local ROW_HEIGHT              = 26   -- just tall enough for buttons
local TIMER_HEIGHT            = 6    -- thinner than the medium frame's 20px
local HEADER_HEIGHT           = 32   -- Pass All + Close buttons

-- Internal state
SmallRollFrame._frame         = nil
SmallRollFrame._timerBar      = nil
SmallRollFrame._timerDuration = 30
SmallRollFrame._respondedItems = {}
SmallRollFrame._itemRows      = {}
SmallRollFrame._rollOptions   = nil
SmallRollFrame._hiddenForCombat = false

------------------------------------------------------------------------
-- Create / return the main frame (lazy init)
------------------------------------------------------------------------
function SmallRollFrame:GetFrame()
    if self._frame then return self._frame end

    local theme = ns.Theme:GetCurrent()

    local f = CreateFrame("Frame", "OLLSmallRollFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, 200)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
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
        ns.SaveFramePosition("SmallRollFrame", frm)
    end)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(frm) ns.RaiseFrame(frm) end)

    f._posKey = "SmallRollFrame"
    local content = ns.MakeResizableScrollFrame(f, FRAME_WIDTH, 200)

    -- Pass All button (top-left)
    local passAllBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    passAllBtn:SetSize(100, 22)
    passAllBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -5)
    passAllBtn:SetText("Pass All Loot")
    passAllBtn:SetScript("OnClick", function()
        SmallRollFrame:AutoPassAll()
        SmallRollFrame:Hide()
    end)
    passAllBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Pass All Loot", 1, 1, 1)
        GameTooltip:AddLine("Passes on all items you have not already\nmade a choice for, then closes the roll window.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    passAllBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.passAllBtn = passAllBtn

    -- Close button (top-right)
    local closeBtn = CreateFrame("Button", nil, content, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() SmallRollFrame:Hide() end)

    -- Timer bar (thin strip below header)
    local timerBar = CreateFrame("StatusBar", nil, content)
    timerBar:SetSize(FRAME_WIDTH - 28, TIMER_HEIGHT)
    timerBar:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -(HEADER_HEIGHT))
    timerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
    timerBar:SetMinMaxValues(0, 1)
    timerBar:SetValue(1)

    local timerBg = timerBar:CreateTexture(nil, "BACKGROUND")
    timerBg:SetAllPoints()
    timerBg:SetColorTexture(unpack(theme.timerBarBgColor))
    timerBar.bg = timerBg
    f.timerBar = timerBar
    self._timerBar = timerBar

    -- Scroll frame for item rows (directly below timer bar)
    local scrollFrame = CreateFrame("ScrollFrame", "OLLSmallRollScrollFrame", content, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     timerBar,  "BOTTOMLEFT",  0,  -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", content,   "BOTTOMRIGHT", -28, 8)
    f.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 50, 1)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild

    -- Combat hide/show
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:HookScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if f:IsShown() then
                SmallRollFrame._hiddenForCombat = true
                f:Hide()
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if SmallRollFrame._hiddenForCombat then
                SmallRollFrame._hiddenForCombat = false
                f:Show()
            end
        end
    end)

    f:Hide()
    self._frame = f
    ns.RestoreFramePosition("SmallRollFrame", f)
    return f
end

------------------------------------------------------------------------
-- Apply theme colors to an already-created frame
------------------------------------------------------------------------
function SmallRollFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    if f.timerBar then
        f.timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
        if f.timerBar.bg then
            f.timerBar.bg:SetColorTexture(unpack(theme.timerBarBgColor))
        end
    end
end

------------------------------------------------------------------------
-- Show all items for rolling
------------------------------------------------------------------------
function SmallRollFrame:ShowAllItems(items, rollOptions)
    local f = self:GetFrame()

    self._rollOptions      = rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self._respondedItems   = {}
    self._itemRows         = {}

    local theme = ns.Theme:GetCurrent()

    -- Timer setup
    local duration = ns.db.profile.rollTimer or 30
    if ns.Session and ns.Session.sessionSettings then
        duration = ns.Session.sessionSettings.rollTimer or duration
    end
    self._timerDuration = duration
    f.timerBar:SetMinMaxValues(0, duration)
    f.timerBar:SetValue(duration)
    f.timerBar:Show()

    -- Clear scroll child
    local sc = f.scrollChild
    for _, child in ipairs({ sc:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end

    -- Build compact item rows
    local yOffset = 0
    for idx, item in ipairs(items) do
        yOffset = self:_DrawItemRow(sc, yOffset, idx, item)
    end

    -- Auto-pass off-spec items
    if ns.db.profile.autoPassOffSpec ~= false then
        local playerStat = ns.RF_GetPlayerMainStat and ns.RF_GetPlayerMainStat() or nil
        if playerStat then
            for idx, item in ipairs(items) do
                local itemStat = ns.RF_GetItemMainStat and ns.RF_GetItemMainStat(item.link) or nil
                if itemStat and itemStat ~= playerStat then
                    self:OnRollChoice(idx, "Pass")
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
                    self:OnRollChoice(idx, "Pass")
                end
            end
        end
    end

    sc:SetHeight(math.abs(yOffset) + 10)

    -- Size the frame to fit rows (cap at 10 visible)
    local numRows = math.min(#items, 10)
    local contentHeight = HEADER_HEIGHT + TIMER_HEIGHT + 4 + numRows * ROW_HEIGHT + 16
    if f._contentPanel then f._contentPanel:SetSize(FRAME_WIDTH, contentHeight) end
    f:SetSize(FRAME_WIDTH, contentHeight)

    f:Show()
end

------------------------------------------------------------------------
-- Draw one compact item row: [Item Name (fill)] [Btn1] [Btn2] ... [Pass]
------------------------------------------------------------------------
function SmallRollFrame:_DrawItemRow(parent, yOffset, itemIdx, item)
    local theme = ns.Theme:GetCurrent()
    local rollOptions = self._rollOptions or ns.DEFAULT_ROLL_OPTIONS
    local numBtns = #rollOptions + 1  -- +1 for Pass

    local BTN_W   = 54
    local BTN_H   = ROW_HEIGHT - 4
    local PADDING = 4
    local btnsTotalW = numBtns * BTN_W + (numBtns - 1) * 2

    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(parent:GetWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 8,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    row:SetBackdropColor(unpack(theme.rowBgColor))
    row:SetBackdropBorderColor(unpack(theme.rowBorderColor))

    -- Item name (fills left portion)
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT",  row, "LEFT",  PADDING, 0)
    nameText:SetPoint("RIGHT", row, "RIGHT", -(btnsTotalW + PADDING + 4), 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    local rqr, rqg, rqb = GetItemQualityColor(item.quality or 1)
    nameText:SetTextColor(rqr, rqg, rqb)
    nameText:SetText(item.name or "Unknown")
    row.nameText = nameText

    -- Item tooltip
    local _rowLink = item.link
    row:EnableMouse(true)
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

    -- Roll option buttons
    local btnX = row:GetWidth() - btnsTotalW - PADDING
    row.buttons = {}

    for i, opt in ipairs(rollOptions) do
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(BTN_W, BTN_H)
        btn:SetPoint("LEFT", row, "LEFT", btnX + (i - 1) * (BTN_W + 2), 2)
        btn:SetText(opt.name)
        local fs = btn:GetFontString()
        if fs then
            local fp = fs:GetFont()
            if fp then fs:SetFont(fp, 9) end
            if opt.colorR then fs:SetTextColor(opt.colorR, opt.colorG, opt.colorB) end
        end
        btn:SetScript("OnClick", function()
            SmallRollFrame:OnRollChoice(itemIdx, opt.name)
        end)
        tinsert(row.buttons, btn)
    end

    -- Pass button
    local passBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    passBtn:SetSize(BTN_W, BTN_H)
    passBtn:SetPoint("LEFT", row, "LEFT", btnX + #rollOptions * (BTN_W + 2), 2)
    passBtn:SetText("Pass")
    local pfs = passBtn:GetFontString()
    if pfs then
        local pf = pfs:GetFont()
        if pf then pfs:SetFont(pf, 9) end
        pfs:SetTextColor(0.5, 0.5, 0.5)
    end
    passBtn:SetScript("OnClick", function()
        SmallRollFrame:OnRollChoice(itemIdx, "Pass")
    end)
    tinsert(row.buttons, passBtn)

    -- Status text (shown after choice is made, replaces button area visually)
    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("RIGHT", row, "RIGHT", -PADDING, 0)
    statusText:SetJustifyH("RIGHT")
    statusText:SetTextColor(0.6, 0.8, 0.6)
    statusText:Hide()
    row.statusText = statusText

    row:Show()
    self._itemRows[itemIdx] = row
    return yOffset - ROW_HEIGHT
end

------------------------------------------------------------------------
-- Handle roll choice for an item
------------------------------------------------------------------------
function SmallRollFrame:OnRollChoice(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self._respondedItems[itemIdx] = true

    local row = self._itemRows[itemIdx]
    if row and row.buttons then
        for _, btn in ipairs(row.buttons) do
            btn:Hide()
        end
    end
    if row and row.statusText then
        row.statusText:SetText("You chose: " .. choice)
        row.statusText:Show()
    end

    if ns.Session then
        ns.Session:SubmitResponse(itemIdx, choice)
    end

    -- Hide timer when all items answered
    if ns.Session and ns.Session.currentItems then
        local allDone = true
        for idx = 1, #ns.Session.currentItems do
            if not self._respondedItems[idx] then
                allDone = false
                break
            end
        end
        if allDone and self._timerBar then
            self._timerBar:Hide()
        end
    end
end

------------------------------------------------------------------------
-- External selection (leader forces choice)
------------------------------------------------------------------------
function SmallRollFrame:SetExternalSelection(itemIdx, choice)
    self._respondedItems[itemIdx] = nil
    self:OnRollChoice(itemIdx, choice)
end

------------------------------------------------------------------------
-- Reset item choice (retry after failed ACK)
------------------------------------------------------------------------
function SmallRollFrame:ResetItemChoice(itemIdx)
    self._respondedItems[itemIdx] = nil
    local row = self._itemRows[itemIdx]
    if not row then return end
    if row.buttons then
        for _, btn in ipairs(row.buttons) do btn:Show() end
    end
    if row.statusText then
        row.statusText:SetText("")
        row.statusText:Hide()
    end
end

------------------------------------------------------------------------
-- Auto-pass all un-responded items
------------------------------------------------------------------------
function SmallRollFrame:AutoPassAll()
    if not ns.Session then return end
    for idx = 1, #(ns.Session.currentItems or {}) do
        if not self._respondedItems[idx] then
            self:OnRollChoice(idx, "Pass")
        end
    end
end

------------------------------------------------------------------------
-- Show result for a specific item row
------------------------------------------------------------------------
function SmallRollFrame:ShowResult(itemIdx, result)
    local row = self._itemRows[itemIdx]
    if not row then return end
    -- Hide roll buttons (already hidden if player responded, but guard anyway)
    if row.buttons then
        for _, btn in ipairs(row.buttons) do btn:Hide() end
    end
    if row.statusText then
        if result and result.winner then
            row.statusText:SetText("Won: " .. (ns.StripRealm and ns.StripRealm(result.winner) or result.winner))
            row.statusText:SetTextColor(0.4, 1.0, 0.4)
        else
            row.statusText:SetText("No winner")
            row.statusText:SetTextColor(0.6, 0.6, 0.6)
        end
        row.statusText:Show()
    end
end

------------------------------------------------------------------------
-- Timer tick (called from router / Comm)
------------------------------------------------------------------------
function SmallRollFrame:OnTimerTick(remaining)
    if not self._frame or not self._frame:IsShown() then return end
    if remaining <= 0 then
        remaining = 0
        self:AutoPassAll()
    end
    local theme = ns.Theme:GetCurrent()
    self._timerBar:SetValue(remaining)
    if remaining < 5 then
        self._timerBar:SetStatusBarColor(unpack(theme.timerBarLowColor))
    elseif remaining < 10 then
        self._timerBar:SetStatusBarColor(unpack(theme.timerBarMidColor))
    else
        self._timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
    end
end

------------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------------
function SmallRollFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

function SmallRollFrame:Hide()
    if self._frame then self._frame:Hide() end
end

function SmallRollFrame:Show()
    self:GetFrame():Show()
end

------------------------------------------------------------------------
-- Reset (used when a debug session ends)
------------------------------------------------------------------------
function SmallRollFrame:Reset()
    self:Hide()
    self._respondedItems = {}
    self._itemRows       = {}
    self._rollOptions    = nil
    self._timerDuration  = 0
    if self._frame then
        local sc = self._frame.scrollChild
        if sc then
            for _, child in ipairs({ sc:GetChildren() }) do
                child:Hide()
                child:SetParent(nil)
            end
        end
        if self._timerBar then self._timerBar:SetValue(0) end
    end
end
