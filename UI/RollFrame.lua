------------------------------------------------------------------------
-- OrderedLootList  –  UI/RollFrame.lua
-- Roll window shown to all players during a loot roll.
-- Displays ALL items at once with per-item roll buttons, shared timer,
-- and boss history dropdown.
------------------------------------------------------------------------

local ns                  = _G.OLL_NS

local RollFrame           = {}
ns.RollFrame              = RollFrame

local FRAME_WIDTH         = 420
local ITEM_ROW_HEIGHT     = 56
local TIMER_HEIGHT        = 20
local HEADER_HEIGHT       = 50
local FOOTER_HEIGHT       = 46

-- Internal state
RollFrame._frame          = nil
RollFrame._timerBar       = nil
RollFrame._timerStart     = 0
RollFrame._timerDuration  = 30
RollFrame._tickerHandle   = nil
RollFrame._respondedItems = {} -- { [itemIdx] = true }
RollFrame._itemRows       = {} -- { [itemIdx] = rowFrame }
RollFrame._viewingHistory = false
RollFrame._rollOptions    = nil

------------------------------------------------------------------------
-- Create the main frame (lazy init)
------------------------------------------------------------------------
function RollFrame:GetFrame()
    if self._frame then return self._frame end

    local f = CreateFrame("Frame", "OLLRollFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, 300) -- height set dynamically
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SaveFramePosition("RollFrame", self)
    end)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Loot Roll")
    f.title = title

    -- Boss name
    local bossText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bossText:SetPoint("TOP", title, "BOTTOM", 0, -2)
    bossText:SetTextColor(0.7, 0.7, 0.7)
    f.bossText = bossText

    -- Loot count display
    local countText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -40, -12)
    countText:SetTextColor(1, 0.82, 0)
    f.countText = countText

    -- Timer bar (at top, below header)
    local timerBar = CreateFrame("StatusBar", nil, f)
    timerBar:SetSize(FRAME_WIDTH - 28, TIMER_HEIGHT)
    timerBar:SetPoint("TOP", f, "TOP", 0, -(HEADER_HEIGHT))
    timerBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    timerBar:SetStatusBarColor(0.2, 0.6, 1.0)
    timerBar:SetMinMaxValues(0, 1)
    timerBar:SetValue(1)

    local timerBg = timerBar:CreateTexture(nil, "BACKGROUND")
    timerBg:SetAllPoints()
    timerBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local timerText = timerBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timerText:SetPoint("CENTER")
    timerBar.text = timerText
    f.timerBar = timerBar
    self._timerBar = timerBar

    -- Scroll frame for item rows
    local scrollFrame = CreateFrame("ScrollFrame", "OLLRollScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", timerBar, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, FOOTER_HEIGHT)
    f.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 50, 1) -- height set dynamically
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild

    -- Boss history dropdown (bottom)
    local dropdown = CreateFrame("Frame", "OLLBossDropdown", f, "UIDropDownMenuTemplate")
    dropdown:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -4, 4)
    UIDropDownMenu_SetWidth(dropdown, 140)
    UIDropDownMenu_SetText(dropdown, "Boss History")
    UIDropDownMenu_Initialize(dropdown, function(self, level)
        RollFrame:PopulateBossDropdown(self, level)
    end)
    f.bossDropdown = dropdown

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() RollFrame:Hide() end)

    f:Hide()
    self._frame = f
    ns.RestoreFramePosition("RollFrame", f)
    return f
end

------------------------------------------------------------------------
-- Show all items at once for rolling
------------------------------------------------------------------------
function RollFrame:ShowAllItems(items, rollOptions)
    local f = self:GetFrame()

    self._rollOptions = rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self._respondedItems = {}
    self._viewingHistory = false
    self._itemRows = {}

    -- Boss & count display
    f.bossText:SetText("Boss: " .. (ns.Session and ns.Session.currentBoss or "Unknown"))
    local myCount = ns.LootCount:GetCount(ns.GetPlayerNameRealm())
    f.countText:SetText("Your Loot Count: " .. myCount)

    -- Timer
    local duration = ns.db.profile.rollTimer or 30
    if ns.Session and ns.Session.sessionSettings then
        duration = ns.Session.sessionSettings.rollTimer or duration
    end
    self._timerDuration = duration
    self._timerStart = GetTime()
    f.timerBar:SetMinMaxValues(0, duration)
    f.timerBar:SetValue(duration)
    f.timerBar.text:SetText(duration .. "s")
    f.timerBar:Show()

    -- Start timer ticker
    if self._tickerHandle then
        self._tickerHandle:Cancel()
    end
    self._tickerHandle = C_Timer.NewTicker(0.1, function()
        self:UpdateTimer()
    end)

    -- Clear scroll child
    local sc = f.scrollChild
    for _, child in ipairs({ sc:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end

    -- Build item rows
    local yOffset = 0
    for idx, item in ipairs(items) do
        yOffset = self:_DrawItemRow(sc, yOffset, idx, item)
    end
    sc:SetHeight(math.abs(yOffset) + 10)

    -- Resize frame based on number of items (cap at 5 visible rows)
    local numRows = math.min(#items, 5)
    local contentHeight = numRows * ITEM_ROW_HEIGHT
    local totalHeight = HEADER_HEIGHT + TIMER_HEIGHT + 4 + contentHeight + FOOTER_HEIGHT + 10
    f:SetHeight(totalHeight)

    f:Show()
end

------------------------------------------------------------------------
-- Draw a single item row with roll buttons
------------------------------------------------------------------------
function RollFrame:_DrawItemRow(parent, yOffset, itemIdx, item)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(FRAME_WIDTH - 50, ITEM_ROW_HEIGHT - 4)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    row:SetBackdropColor(0.08, 0.08, 0.15, 0.7)
    row:SetBackdropBorderColor(0.3, 0.3, 0.4, 0.6)

    -- Item icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Item name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -2)
    nameText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    nameText:SetText(item.link or item.name or "Unknown")

    -- Roll buttons container
    local btnContainer = CreateFrame("Frame", nil, row)
    btnContainer:SetSize(FRAME_WIDTH - 100, 22)
    btnContainer:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 0)
    row.btnContainer = btnContainer

    self:_BuildItemRollButtons(btnContainer, itemIdx)

    -- Status / result text (hidden initially)
    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 2)
    statusText:SetTextColor(0.6, 0.6, 0.6)
    statusText:Hide()
    row.statusText = statusText

    -- Result text (winner display)
    local resultText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resultText:SetPoint("LEFT", icon, "RIGHT", 6, -8)
    resultText:SetTextColor(0, 1, 0)
    resultText:Hide()
    row.resultText = resultText

    row:Show()
    self._itemRows[itemIdx] = row

    return yOffset - ITEM_ROW_HEIGHT
end

------------------------------------------------------------------------
-- Build roll buttons for a single item row
------------------------------------------------------------------------
function RollFrame:_BuildItemRollButtons(container, itemIdx)
    local rollOptions = self._rollOptions or ns.DEFAULT_ROLL_OPTIONS
    local numButtons = #rollOptions + 1 -- +1 for Pass
    local maxWidth = container:GetWidth()
    local btnWidth = math.floor((maxWidth - (numButtons - 1) * 3) / numButtons)
    btnWidth = math.min(btnWidth, 80)

    container.buttons = {}

    -- Roll option buttons
    for i, opt in ipairs(rollOptions) do
        local btn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
        btn:SetSize(btnWidth, 20)
        btn:SetPoint("LEFT", container, "LEFT", (i - 1) * (btnWidth + 3), 0)
        btn:SetText(opt.name)

        local fontStr = btn:GetFontString()
        if fontStr then
            fontStr:SetFont(fontStr:GetFont(), 10)
            if opt.colorR then
                fontStr:SetTextColor(opt.colorR, opt.colorG, opt.colorB)
            end
        end

        btn:SetScript("OnClick", function()
            self:OnRollChoice(itemIdx, opt.name)
        end)
        tinsert(container.buttons, btn)
    end

    -- Pass button
    local passBtn = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    passBtn:SetSize(btnWidth, 20)
    passBtn:SetPoint("LEFT", container, "LEFT", #rollOptions * (btnWidth + 3), 0)
    passBtn:SetText("Pass")
    local passFontStr = passBtn:GetFontString()
    if passFontStr then
        passFontStr:SetFont(passFontStr:GetFont(), 10)
        passFontStr:SetTextColor(0.5, 0.5, 0.5)
    end
    passBtn:SetScript("OnClick", function()
        self:OnRollChoice(itemIdx, "Pass")
    end)
    tinsert(container.buttons, passBtn)
end

------------------------------------------------------------------------
-- Handle player roll choice for a specific item
------------------------------------------------------------------------
function RollFrame:OnRollChoice(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self._respondedItems[itemIdx] = true

    -- Disable buttons for this item
    local row = self._itemRows[itemIdx]
    if row and row.btnContainer and row.btnContainer.buttons then
        for _, btn in ipairs(row.btnContainer.buttons) do
            btn:Hide()
        end
    end

    -- Show status
    if row then
        row.statusText:SetText("You chose: " .. choice)
        row.statusText:Show()
    end

    -- Submit to session
    if ns.Session then
        ns.Session:SubmitResponse(itemIdx, choice)
    end

    -- If all items have been responded to, hide the timer for this player
    if ns.Session and ns.Session.currentItems then
        local allDone = true
        for idx = 1, #ns.Session.currentItems do
            if not self._respondedItems[idx] then
                allDone = false
                break
            end
        end
        if allDone then
            if self._tickerHandle then
                self._tickerHandle:Cancel()
                self._tickerHandle = nil
            end
            if self._timerBar then
                self._timerBar:Hide()
            end
        end
    end
end

------------------------------------------------------------------------
-- Auto-pass all un-responded items
------------------------------------------------------------------------
function RollFrame:AutoPassAll()
    if not ns.Session then return end
    local items = ns.Session.currentItems or {}
    for idx = 1, #items do
        if not self._respondedItems[idx] then
            self:OnRollChoice(idx, "Pass")
        end
    end
end

------------------------------------------------------------------------
-- Update timer bar (shared for all items)
------------------------------------------------------------------------
function RollFrame:UpdateTimer()
    if not self._frame or not self._frame:IsShown() then
        if self._tickerHandle then
            self._tickerHandle:Cancel()
            self._tickerHandle = nil
        end
        return
    end

    if self._viewingHistory then return end

    local elapsed = GetTime() - self._timerStart
    local remaining = self._timerDuration - elapsed

    if remaining <= 0 then
        remaining = 0
        if self._tickerHandle then
            self._tickerHandle:Cancel()
            self._tickerHandle = nil
        end
        -- Auto-pass any un-responded items
        self:AutoPassAll()
    end

    self._timerBar:SetValue(remaining)
    self._timerBar.text:SetText(math.ceil(remaining) .. "s")

    -- Color changes as time runs out
    if remaining < 5 then
        self._timerBar:SetStatusBarColor(1, 0.2, 0.2)
    elseif remaining < 10 then
        self._timerBar:SetStatusBarColor(1, 0.6, 0.2)
    else
        self._timerBar:SetStatusBarColor(0.2, 0.6, 1.0)
    end
end

------------------------------------------------------------------------
-- Show result inline on a specific item row
------------------------------------------------------------------------
function RollFrame:ShowResult(itemIdx, result)
    local row = self._itemRows[itemIdx]
    if not row then return end

    -- Hide buttons
    if row.btnContainer and row.btnContainer.buttons then
        for _, btn in ipairs(row.btnContainer.buttons) do
            btn:Hide()
        end
    end
    row.btnContainer:Hide()
    row.statusText:Hide()

    -- Show result
    if result and result.winner then
        row.resultText:SetText(
            result.winner .. " won! (" .. (result.choice or "?") .. " - " .. (result.roll or 0) .. ")"
        )
        row.resultText:SetTextColor(0, 1, 0)
    else
        row.resultText:SetText("No winner.")
        row.resultText:SetTextColor(0.7, 0.7, 0.7)
    end
    row.resultText:Show()
end

------------------------------------------------------------------------
-- Boss history dropdown
------------------------------------------------------------------------
function RollFrame:PopulateBossDropdown(dropdown, level)
    if not ns.Session then return end

    local keys = ns.Session:GetBossHistoryKeys()
    if #keys == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "No history yet"
        info.disabled = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
        return
    end

    -- "Current" option
    local currentInfo = UIDropDownMenu_CreateInfo()
    currentInfo.text = "Current Roll"
    currentInfo.notCheckable = true
    currentInfo.func = function()
        RollFrame._viewingHistory = false
        UIDropDownMenu_SetText(dropdown, "Current Roll")
        -- Re-show current items if rolling
        if ns.Session.state == ns.Session.STATE_ROLLING then
            local items = ns.Session.currentItems
            if items and #items > 0 then
                RollFrame:ShowAllItems(items, ns.Session.rollOptions)
            end
        end
    end
    UIDropDownMenu_AddButton(currentInfo, level)

    -- Historical bosses
    for _, key in ipairs(keys) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = key
        info.notCheckable = true
        info.func = function()
            RollFrame:ShowBossHistory(key)
            UIDropDownMenu_SetText(dropdown, key)
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

------------------------------------------------------------------------
-- Show historical boss roll data
------------------------------------------------------------------------
function RollFrame:ShowBossHistory(bossKey)
    local data = ns.Session:GetBossHistory(bossKey)
    if not data then return end

    self._viewingHistory = true

    local f = self:GetFrame()

    -- Update boss name display
    f.bossText:SetText("Boss: " .. bossKey)

    -- Stop timer
    if self._tickerHandle then
        self._tickerHandle:Cancel()
        self._tickerHandle = nil
    end
    f.timerBar:Hide()

    -- Clear scroll child
    local sc = f.scrollChild
    for _, child in ipairs({ sc:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    self._itemRows = {}

    -- Build summary rows
    local yOffset = 0
    for idx, item in ipairs(data.items or {}) do
        local result = data.results and data.results[idx]

        local row = CreateFrame("Frame", nil, sc, "BackdropTemplate")
        row:SetSize(FRAME_WIDTH - 50, 36)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        row:SetBackdropColor(0.08, 0.08, 0.12, 0.6)
        row:SetBackdropBorderColor(0.3, 0.3, 0.4, 0.5)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(28, 28)
        icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")

        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        text:SetJustifyH("LEFT")

        local line = (item.link or item.name or "Unknown")
        if result and result.winner then
            line = line .. "  →  " .. result.winner .. " (" .. (result.choice or "?") .. " " .. (result.roll or 0) .. ")"
            text:SetTextColor(0.5, 1, 0.5)
        else
            line = line .. "  →  No winner"
            text:SetTextColor(0.6, 0.6, 0.6)
        end
        text:SetText(line)

        row:Show()
        yOffset = yOffset - 40
    end

    sc:SetHeight(math.abs(yOffset) + 10)

    -- Resize frame
    local numRows = math.min(#(data.items or {}), 5)
    local contentHeight = numRows * 40
    local totalHeight = HEADER_HEIGHT + 4 + contentHeight + FOOTER_HEIGHT + 10
    f:SetHeight(math.max(totalHeight, 180))

    f:Show()
end

------------------------------------------------------------------------
-- Toggle visibility
------------------------------------------------------------------------
function RollFrame:Toggle()
    local f = self:GetFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

function RollFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

function RollFrame:Hide()
    if self._frame then
        self._frame:Hide()
    end
    if self._tickerHandle then
        self._tickerHandle:Cancel()
        self._tickerHandle = nil
    end
end

------------------------------------------------------------------------
-- Fully reset & clear the roll frame (used when debug session ends)
------------------------------------------------------------------------
function RollFrame:Reset()
    self:Hide()
    self._respondedItems = {}
    self._itemRows = {}
    self._viewingHistory = false
    self._rollOptions = nil
    self._timerStart = 0
    self._timerDuration = 0

    if self._frame then
        -- Clear all child frames / font strings from the scroll child
        local sc = self._frame.scrollChild
        if sc then
            for _, child in ipairs({ sc:GetChildren() }) do
                child:Hide()
                child:SetParent(nil)
            end
        end
        -- Reset timer bar
        if self._timerBar then
            self._timerBar:SetValue(0)
            self._timerBar.text:SetText("")
        end
    end
end

function RollFrame:Show()
    self:GetFrame():Show()

    -- Restart the timer ticker if still within the roll window
    if not self._viewingHistory and not self._tickerHandle then
        local remaining = self._timerDuration - (GetTime() - self._timerStart)
        if remaining > 0 then
            self._tickerHandle = C_Timer.NewTicker(0.1, function()
                self:UpdateTimer()
            end)
        end
    end
end

-- Legacy compatibility: ShowForItem redirects to ShowAllItems
function RollFrame:ShowForItem(item, itemIdx, rollOptions)
    if ns.Session and ns.Session.currentItems and #ns.Session.currentItems > 0 then
        self:ShowAllItems(ns.Session.currentItems, rollOptions)
    end
end
