------------------------------------------------------------------------
-- OrderedLootList  –  UI/SmallRollFrame.lua  (Ledger)
-- Compact roll window (400 wide): 32px title bar with Pass all and the
-- countdown, 2px timer, 30px rows (quality tick, name, 22px segmented
-- Need/Greed/Pass), 28px footer with boss name and gear count.
-- No icons, no pills — that is its brief.  The footer boss name doubles
-- as the boss-history menu (BOSS v) once the roll has resolved.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local SmallRollFrame          = {}
ns.SmallRollFrame             = SmallRollFrame

local FRAME_WIDTH             = 400
local ROW_HEIGHT              = 30
local HEADER_HEIGHT           = 32
local TIMER_HEIGHT            = 2
local FOOTER_HEIGHT           = 28
local MAX_VISIBLE_ROWS        = 10
local INSET                   = 16

SmallRollFrame._frame         = nil
SmallRollFrame._timerBar      = nil
SmallRollFrame._timerDuration = 30
SmallRollFrame._respondedItems = {}
SmallRollFrame._itemRows      = {}
SmallRollFrame._rowPool       = {}
SmallRollFrame._rollOptions   = nil
SmallRollFrame._hiddenForCombat = false
SmallRollFrame._viewingHistory = false
SmallRollFrame._historyLocked  = false

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

function SmallRollFrame:GetFrame()
    if self._frame then return self._frame end

    local f = ns.MakeLedgerFrame("OLLSmallRollFrame", FRAME_WIDTH, 152, "SmallRollFrame", { strata = "HIGH", y = 100 })

    -- Header: ROLL · [PASS ALL] 19 X
    local header = ns.MakeHeaderBar(f, "Roll", nil, { height = HEADER_HEIGHT, onClose = function() SmallRollFrame:Hide() end })
    f.header = header
    header.closeBtn:SetSize(24, 24)

    local countdown = header:CreateFontString(nil, "OVERLAY")
    countdown:SetFontObject(ns.Ledger.Fonts.OLLFontNumberSmall)
    countdown:SetPoint("RIGHT", header.closeBtn, "LEFT", -10, 0)
    f.countdown = countdown

    local passAllBtn = ns.MakeButton(header, "outline", "Pass all", 84, 22)
    passAllBtn:SetPoint("RIGHT", countdown, "LEFT", -12, 0)
    passAllBtn:SetScript("OnClick", function()
        SmallRollFrame:AutoPassAll()
        SmallRollFrame:Hide()
    end)
    passAllBtn:HookScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Pass All Loot", 1, 1, 1)
        GameTooltip:AddLine("Passes on all items you have not already\nmade a choice for, then closes the roll window.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    passAllBtn:HookScript("OnLeave", GameTooltip_Hide)
    f.passAllBtn = passAllBtn

    -- Timer
    local timerBar = ns.MakeTimerBar(f)
    timerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_HEIGHT + 2))
    timerBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(HEADER_HEIGHT + 2))
    f.timerBar = timerBar
    self._timerBar = timerBar

    -- Footer: boss name · COUNT N
    local footer = ns.MakeBar(f, FOOTER_HEIGHT, "barBgColor", "TOP")
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.footer = footer
    local bossBtn = CreateFrame("Button", nil, footer)
    bossBtn:SetPoint("LEFT", footer, "LEFT", INSET - 2, 0)
    bossBtn:SetPoint("RIGHT", footer, "CENTER", 40, 0)
    bossBtn:SetHeight(FOOTER_HEIGHT)
    f.bossBtn = bossBtn
    local bossText = bossBtn:CreateFontString(nil, "OVERLAY")
    bossText:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    bossText:SetPoint("LEFT", bossBtn, "LEFT", 0, 0)
    bossText:SetPoint("RIGHT", bossBtn, "RIGHT", -14, 0)
    bossText:SetJustifyH("LEFT"); bossText:SetWordWrap(false)
    f.bossText = bossText
    local bossCaret = bossBtn:CreateFontString(nil, "OVERLAY")
    bossCaret:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    bossCaret:SetPoint("LEFT", bossText, "RIGHT", 4, 0)
    bossCaret:SetText("v")
    f.bossCaret = bossCaret
    bossBtn:SetScript("OnClick", function() SmallRollFrame:_OpenHistoryMenu() end)
    bossBtn:SetScript("OnEnter", function(b)
        if SmallRollFrame._historyLocked then return end
        GameTooltip:SetOwner(b, "ANCHOR_TOP")
        GameTooltip:SetText("Boss history", 1, 1, 1)
        GameTooltip:AddLine("Show a previous boss's rolls.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    bossBtn:SetScript("OnLeave", GameTooltip_Hide)
    local countNum = footer:CreateFontString(nil, "OVERLAY")
    countNum:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    countNum:SetPoint("RIGHT", footer, "RIGHT", -(INSET - 2), 0)
    f.countNum = countNum
    local countLbl = footer:CreateFontString(nil, "OVERLAY")
    countLbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    countLbl:SetPoint("RIGHT", countNum, "LEFT", -6, 0)
    countLbl:SetText(ns.Track("Count"))
    f.countLbl = countLbl

    -- Rows scroll
    local scrollFrame = CreateFrame("ScrollFrame", "OLLSmallRollScrollFrame", f)
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_HEIGHT + TIMER_HEIGHT + 2))
    scrollFrame:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 0)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * ROW_HEIGHT)))
    end)
    f.scrollFrame = scrollFrame
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 4, 1)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild

    -- Combat hide/show
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:HookScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if f:IsShown() then SmallRollFrame._hiddenForCombat = true; f:Hide() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if SmallRollFrame._hiddenForCombat then SmallRollFrame._hiddenForCombat = false; f:Show() end
        end
    end)

    f:Hide()
    self._frame = f
    -- Reset to centre if the saved position is entirely off-screen
    do
        local cx, cy = f:GetCenter()
        local sw = GetScreenWidth()  / UIParent:GetEffectiveScale()
        local sh = GetScreenHeight() / UIParent:GetEffectiveScale()
        if not cx or cx < 0 or cx > sw or not cy or cy < 0 or cy > sh then
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
        end
    end
    self:ApplyTheme()
    return f
end

function SmallRollFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f.countdown:SetTextColor(C(theme, "textColor"))
    f.bossText:SetTextColor(C(theme, "textDimColor"))
    f.bossCaret:SetTextColor(C(theme, "textMutedColor"))
    f.countNum:SetTextColor(C(theme, "countTextColor"))
    f.countLbl:SetTextColor(C(theme, "textDimColor"))
    for _, row in ipairs(self._rowPool) do
        row:ApplyTheme(theme)
        row.statusText:SetTextColor(C(theme, "textMutedColor"))
    end
end

------------------------------------------------------------------------
-- Row pool
------------------------------------------------------------------------
function SmallRollFrame:_AcquireRow(parent)
    for _, row in ipairs(self._rowPool) do
        if not row._inUse then
            row._inUse = true
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end
    local row = ns.MakeItemRow(parent, ROW_HEIGHT, { noIcon = true })
    row.seg = ns.MakeSegmented(row, ns.DEFAULT_ROLL_OPTIONS, nil, { h = 22, segW = { 48, 48 }, passW = 44, defaultW = 48 })
    row.seg:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
    row.statusText = row:CreateFontString(nil, "OVERLAY")
    row.statusText:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    row.statusText:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
    row.statusText:Hide()
    row:HookScript("OnEnter", function(r)
        if r._link then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            if r._link:find("|H") then GameTooltip:SetHyperlink(r._link) else GameTooltip:SetText(r._link) end
            GameTooltip:Show()
        end
    end)
    row:HookScript("OnLeave", GameTooltip_Hide)
    row._inUse = true
    tinsert(self._rowPool, row)
    return row
end

function SmallRollFrame:_RecycleRows()
    for _, row in ipairs(self._rowPool) do row._inUse = false; row:Hide() end
    self._itemRows = {}
end

function SmallRollFrame:_SetRowState(row, state, text, rgb)
    local theme = ns.Theme:GetCurrent()
    row.seg:Hide(); row.statusText:Hide()
    row:SetDimmed(1)
    if state == "open" then
        row.seg:SetEnabled(true); row.seg:SetSelected(nil); row.seg:Show()
        row.rightSlot:SetWidth(row.seg:GetWidth())
    elseif state == "chosen" then
        row.seg:SetEnabled(false); row.seg:SetSelected(text); row.seg:Show()
        row.rightSlot:SetWidth(row.seg:GetWidth())
    else -- "text": passed reason or result
        row.statusText:SetText(text or "")
        row.statusText:SetTextColor(C(theme, rgb or "textMutedColor"))
        row.statusText:Show()
        row.rightSlot:SetWidth(row.statusText:GetStringWidth())
        if rgb == nil then row:SetDimmed(0.6) end
    end
end

------------------------------------------------------------------------
-- Show all items for rolling
------------------------------------------------------------------------
function SmallRollFrame:ShowAllItems(items, rollOptions)
    local f = self:GetFrame()
    local theme = ns.Theme:GetCurrent()

    self._rollOptions    = rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self._respondedItems = {}
    self._viewingHistory = false
    self:LockBossDropdown()
    self:_RecycleRows()

    f.bossText:SetText(ns.Track(ns.Session and ns.Session.currentBoss or "Unknown"))
    f.countNum:SetText(tostring(ns.LootCount:GetCount(ns.GetPlayerNameRealm())))

    local duration = (ns.Session and ns.Session.GetRollDuration and ns.Session:GetRollDuration())
        or ns.db.profile.rollTimer or 30
    self._timerDuration = duration
    f.timerBar:SetProgress(duration, duration)
    f.timerBar:Show()
    f.countdown:SetText(tostring(math.ceil(duration)))
    f.countdown:SetTextColor(C(theme, "textColor"))

    local sc = f.scrollChild
    local yOffset = 0
    for idx, item in ipairs(items) do
        local row = self:_AcquireRow(sc)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)
        row:SetItem(item)
        local capturedIdx = idx
        row.seg:SetOptions(self._rollOptions)
        row.seg:SetOnPick(function(choice) SmallRollFrame:OnRollChoice(capturedIdx, choice) end)
        self:_SetRowState(row, "open")
        row:Show()
        self._itemRows[idx] = row
        yOffset = yOffset - ROW_HEIGHT
    end
    sc:SetHeight(math.abs(yOffset) + 2)

    ns.RF_AutoPassScan(items, self._respondedItems, function(idx, reason)
        self:OnRollChoice(idx, "Pass")
        local row = self._itemRows[idx]
        if row then self:_SetRowState(row, "text", ns.Track("Passed · " .. reason)) end
    end)

    local numRows = math.min(#items, MAX_VISIBLE_ROWS)
    f:SetSize(FRAME_WIDTH, HEADER_HEIGHT + TIMER_HEIGHT + numRows * ROW_HEIGHT + FOOTER_HEIGHT + 4)

    ns.RaiseFrame(f)
    f:Show()
end

------------------------------------------------------------------------
-- Choices
------------------------------------------------------------------------
function SmallRollFrame:OnRollChoice(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self._respondedItems[itemIdx] = true
    local row = (not self._viewingHistory) and self._itemRows[itemIdx] or nil
    if row then self:_SetRowState(row, "chosen", choice) end
    if ns.Session then ns.Session:SubmitResponse(itemIdx, choice) end
    if ns.Session and ns.Session.currentItems then
        local allDone = true
        for idx = 1, #ns.Session.currentItems do
            if not self._respondedItems[idx] then allDone = false break end
        end
        if allDone and self._timerBar then
            self._timerBar:Hide()
            if self._frame then self._frame.countdown:SetText("") end
        end
    end
end

function SmallRollFrame:SetExternalSelection(itemIdx, choice)
    self._respondedItems[itemIdx] = nil
    self:OnRollChoice(itemIdx, choice)
end

function SmallRollFrame:ResetItemChoice(itemIdx)
    self._respondedItems[itemIdx] = nil
    if self._viewingHistory then return end
    local row = self._itemRows[itemIdx]
    if row then self:_SetRowState(row, "open") end
end

function SmallRollFrame:AutoPassAll()
    if not ns.Session then return end
    for idx = 1, #(ns.Session.currentItems or {}) do
        if not self._respondedItems[idx] then self:OnRollChoice(idx, "Pass") end
    end
end

function SmallRollFrame:ShowResult(itemIdx, result)
    if self._viewingHistory then return end
    local row = self._itemRows[itemIdx]
    if not row then return end
    if result and result.winner then
        self:_SetRowState(row, "text", ns.Track("Won · ") .. ns.StripRealm(result.winner), "timerBarFullColor")
    else
        self:_SetRowState(row, "text", ns.Track("No winner"), "textDimColor")
    end
end

function SmallRollFrame:OnTimerTick(remaining)
    if not self._frame or not self._frame:IsShown() then return end
    if self._viewingHistory then
        if remaining <= 0 then self:AutoPassAll() end
        return
    end
    if remaining <= 0 then
        remaining = 0
        self:AutoPassAll()
    end
    local f = self._frame
    f.timerBar:SetProgress(remaining, self._timerDuration)
    f.countdown:SetText(tostring(math.ceil(remaining)))
    local theme = ns.Theme:GetCurrent()
    if remaining < 5 then f.countdown:SetTextColor(C(theme, "timerBarLowColor"))
    elseif remaining < 10 then f.countdown:SetTextColor(C(theme, "timerBarMidColor"))
    else f.countdown:SetTextColor(C(theme, "textColor")) end
end

------------------------------------------------------------------------
-- Boss history (footer menu)
------------------------------------------------------------------------
function SmallRollFrame:_OpenHistoryMenu()
    if self._historyLocked then return end
    local f = self:GetFrame()
    ns.RF_OpenHistoryMenu(f.bossBtn, function()
        SmallRollFrame._viewingHistory = false
        if ns.Session and ns.Session.state == ns.Session.STATE_ROLLING then
            local items = ns.Session.currentItems
            if items and #items > 0 then SmallRollFrame:ShowAllItems(items, ns.Session.rollOptions) end
        end
    end, function(key) SmallRollFrame:ShowBossHistory(key) end)
end

function SmallRollFrame:PopulateBossDropdown() end   -- legacy no-op

function SmallRollFrame:ShowBossHistory(bossKey)
    local data = ns.Session and ns.Session:GetBossHistory(bossKey)
    if not data then return end
    self._viewingHistory = true
    local f = self:GetFrame()
    f.bossText:SetText(ns.Track(bossKey))
    f.timerBar:Hide()
    f.countdown:SetText("")
    self:_RecycleRows()

    local sc = f.scrollChild
    local yOffset = 0
    for idx, item in ipairs(data.items or {}) do
        local result = data.results and data.results[idx]
        local row = self:_AcquireRow(sc)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)
        row:SetItem(item)
        if result and result.winner then
            self:_SetRowState(row, "text", ns.Track("Won · ") .. ns.StripRealm(result.winner), "timerBarFullColor")
        else
            self:_SetRowState(row, "text", ns.Track("No winner"), "textDimColor")
        end
        row:Show()
        self._itemRows[idx] = row
        yOffset = yOffset - ROW_HEIGHT
    end
    sc:SetHeight(math.abs(yOffset) + 2)
    local numRows = math.min(#(data.items or {}), MAX_VISIBLE_ROWS)
    f:SetSize(FRAME_WIDTH, HEADER_HEIGHT + TIMER_HEIGHT + math.max(numRows, 1) * ROW_HEIGHT + FOOTER_HEIGHT + 4)
    f:Show()
end

function SmallRollFrame:LockBossDropdown()
    self._historyLocked = true
    if self._frame then
        self._frame.bossBtn:Disable()
        self._frame.bossCaret:Hide()
    end
end

function SmallRollFrame:UnlockBossDropdown()
    self._historyLocked = false
    if self._frame then
        self._frame.bossBtn:Enable()
        self._frame.bossCaret:Show()
    end
end

------------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------------
function SmallRollFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

function SmallRollFrame:Hide()
    self._hiddenForCombat = false
    if self._frame then self._frame:Hide() end
end

function SmallRollFrame:Show()
    self:GetFrame():Show()
end

function SmallRollFrame:Reset()
    self._hiddenForCombat = false
    self:Hide()
    self:UnlockBossDropdown()
    self._viewingHistory = false
    self._respondedItems = {}
    self._rollOptions    = nil
    self._timerDuration  = 0
    self:_RecycleRows()
    if self._frame then
        self._frame.timerBar:SetProgress(0, 1)
        self._frame.countdown:SetText("")
    end
end
