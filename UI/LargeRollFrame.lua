------------------------------------------------------------------------
-- OrderedLootList  –  UI/LargeRollFrame.lua  (Ledger)
-- Large two-panel roll window (860x520, resizable): item list (left) and
-- the full roster with every player's choice (right).  Receives real-time
-- choice updates via CHOICES_UPDATE.
--
-- Layout: 44px title bar (LOOT ROLL · boss · Pass all N · 19 SEC · X),
-- 2px timer, left 290px (34px history menu row, 48px item rows with pills
-- and the player's own choice), right (56px header: item name + own
-- segmented control; MakeTable roster 1fr/86/50/78 that reflows on resize).
------------------------------------------------------------------------

local ns = _G.OLL_NS

local LargeRollFrame              = {}
ns.LargeRollFrame                 = LargeRollFrame

local FRAME_WIDTH        = 860
local FRAME_HEIGHT       = 520
local LEFT_PANEL_W       = 290
local HEADER_H           = 44
local TIMER_H            = 2
local DROPDOWN_ROW_H     = 34
local ITEM_ROW_H         = 48
local RIGHT_HEADER_H     = 56
local PLAYER_ROW_H       = 26
local INSET              = 16
local MIN_W              = LEFT_PANEL_W + 400 + 40
local MIN_H              = 300

LargeRollFrame._frame           = nil
LargeRollFrame._timerBar        = nil
LargeRollFrame._timerDuration   = 30
LargeRollFrame._respondedItems  = {}
LargeRollFrame._rollOptions     = nil
LargeRollFrame._optPriority     = {}
LargeRollFrame._items           = nil
LargeRollFrame._selectedItemIdx = 1
LargeRollFrame._viewingHistory  = false
LargeRollFrame._historyBossKey  = nil
LargeRollFrame._choices         = {}  -- [itemIdx][playerName] = { choice, countAtRoll, roll }
LargeRollFrame._hiddenForCombat = false
LargeRollFrame._itemRowPool     = {}
LargeRollFrame._historyLocked   = false

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
function LargeRollFrame:GetFrame()
    if self._frame then return self._frame end
    local theme = ns.Theme:GetCurrent()

    local f = ns.MakeLedgerFrame("OLLLargeRollFrame", FRAME_WIDTH, FRAME_HEIGHT, "LargeRollFrame",
        { strata = "HIGH", resizable = true, minW = MIN_W, minH = MIN_H })

    -- Header
    local header = ns.MakeHeaderBar(f, "Loot Roll", nil, { height = HEADER_H, onClose = function() LargeRollFrame:Hide() end })
    f.header = header

    local secLbl = header:CreateFontString(nil, "OVERLAY")
    secLbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    secLbl:SetPoint("RIGHT", header.closeBtn, "LEFT", -14, -4)
    secLbl:SetText(ns.Track("sec"))
    f.secLbl = secLbl
    local countdown = header:CreateFontString(nil, "OVERLAY")
    countdown:SetFontObject(ns.Ledger.Fonts.OLLFontNumberBig)
    countdown:SetPoint("RIGHT", secLbl, "LEFT", -4, 3)
    f.countdown = countdown

    local passAllBtn = ns.MakeButton(header, "outline", "Pass all", 110, 28)
    passAllBtn:SetPoint("RIGHT", countdown, "LEFT", -22, -2)
    passAllBtn:SetScript("OnClick", function()
        LargeRollFrame:AutoPassAll()
        if ns.db.profile.closeOnPassAll ~= false then LargeRollFrame:Hide() end
    end)
    passAllBtn:HookScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Pass All Loot", 1, 1, 1)
        GameTooltip:AddLine("Passes on all items you have not already\nmade a choice for. Closing the window afterwards\nis a General setting.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    passAllBtn:HookScript("OnLeave", GameTooltip_Hide)
    f.passAllBtn = passAllBtn

    -- Timer
    local timerBar = ns.MakeTimerBar(f)
    timerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + 2))
    timerBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(HEADER_H + 2))
    f.timerBar = timerBar
    self._timerBar = timerBar

    -- Left panel
    local leftPanel = CreateFrame("Frame", nil, f)
    leftPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + TIMER_H + 2))
    leftPanel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
    leftPanel:SetWidth(LEFT_PANEL_W)
    local leftBg = leftPanel:CreateTexture(nil, "BACKGROUND")
    leftBg:SetTexture(ns.Ledger.TEX.white); leftBg:SetAllPoints()
    f.leftBg = leftBg
    f.leftPanel = leftPanel

    local vDiv = ns.MakeHairline(f, "dividerColor")
    vDiv:ClearAllPoints(); vDiv:SetWidth(1)
    vDiv:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 0, 0)
    vDiv:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMRIGHT", 0, 0)
    f.vDiv = vDiv

    -- History menu row (34px) inside the left panel
    local historyBtn = ns.MakeButton(leftPanel, "outline", "Current roll", LEFT_PANEL_W - INSET * 2, 26)
    historyBtn:SetPoint("TOP", leftPanel, "TOP", 0, -4)
    historyBtn:SetSubLabel("v")
    historyBtn:SetScript("OnClick", function() LargeRollFrame:_OpenHistoryMenu() end)
    f.historyBtn = historyBtn
    self._bossDropdown = historyBtn
    local ddRule = ns.MakeHairline(leftPanel, "dividerColor")
    ddRule:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, -DROPDOWN_ROW_H)
    ddRule:SetPoint("TOPRIGHT", leftPanel, "TOPRIGHT", 0, -DROPDOWN_ROW_H)
    f.ddRule = ddRule

    local leftSF = CreateFrame("ScrollFrame", "OLLLargeLeftScrollFrame", leftPanel)
    leftSF:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, -DROPDOWN_ROW_H)
    leftSF:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", 0, 0)
    leftSF:EnableMouseWheel(true)
    leftSF:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * ITEM_ROW_H)))
    end)
    local leftSC = CreateFrame("Frame", nil, leftSF)
    leftSC:SetSize(LEFT_PANEL_W, 1)
    leftSF:SetScrollChild(leftSC)
    f.leftSF = leftSF
    f.leftScrollChild = leftSC
    self._leftScrollChild = leftSC

    -- Right panel
    local rightPanel = CreateFrame("Frame", nil, f)
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 1, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.rightPanel = rightPanel

    -- 56px header: item name + YOUR CHOICE + own segmented control
    local rHeader = CreateFrame("Frame", nil, rightPanel)
    rHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, 0)
    rHeader:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", 0, 0)
    rHeader:SetHeight(RIGHT_HEADER_H)
    rHeader.rule = ns.MakeHairline(rHeader, "dividerColor")
    rHeader.rule:SetPoint("BOTTOMLEFT", rHeader, "BOTTOMLEFT", 0, 0)
    rHeader.rule:SetPoint("BOTTOMRIGHT", rHeader, "BOTTOMRIGHT", 0, 0)
    rHeader.name = rHeader:CreateFontString(nil, "OVERLAY")
    rHeader.name:SetFontObject(ns.Ledger.Fonts.OLLFontHero)
    rHeader.name:SetPoint("TOPLEFT", rHeader, "TOPLEFT", INSET, -10)
    rHeader.name:SetWordWrap(false); rHeader.name:SetMaxLines(1)
    rHeader.sub = rHeader:CreateFontString(nil, "OVERLAY")
    rHeader.sub:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    rHeader.sub:SetPoint("TOPLEFT", rHeader.name, "BOTTOMLEFT", 0, -4)
    rHeader.sub:SetText(ns.Track("Your choice"))
    rHeader.seg = ns.MakeSegmented(rHeader, ns.DEFAULT_ROLL_OPTIONS, nil, { h = 30, segW = { 62, 62 }, passW = 56, defaultW = 62 })
    rHeader.seg:SetPoint("RIGHT", rHeader, "RIGHT", -INSET, 0)
    rHeader.seg:SetOnPick(function(choice) LargeRollFrame:OnRollChoice(LargeRollFrame._selectedItemIdx, choice) end)
    rHeader.status = rHeader:CreateFontString(nil, "OVERLAY")
    rHeader.status:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    rHeader.status:SetPoint("RIGHT", rHeader, "RIGHT", -INSET, 0)
    rHeader.status:Hide()
    rHeader.name:SetPoint("RIGHT", rHeader.seg, "LEFT", -12, 0)
    f.rHeader = rHeader
    self._rollBtnContainer = rHeader
    self._selectedItemLabel = rHeader.name

    -- Roster scroll + table
    local rightSF = CreateFrame("ScrollFrame", "OLLLargeRightScrollFrame", rightPanel)
    rightSF:SetPoint("TOPLEFT", rHeader, "BOTTOMLEFT", 0, 0)
    rightSF:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", 0, 0)
    rightSF:EnableMouseWheel(true)
    rightSF:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * PLAYER_ROW_H * 2)))
    end)
    local rightSC = CreateFrame("Frame", nil, rightSF)
    rightSC:SetSize(FRAME_WIDTH - LEFT_PANEL_W - 5, 1)
    f.rightSF = rightSF
    rightSF:SetScrollChild(rightSC)
    rightSF:SetScript("OnSizeChanged", function(sf, w) rightSC:SetWidth(w) end)
    f.rightScrollChild = rightSC
    self._rightScrollChild = rightSC

    local roster = ns.MakeTable(rightSC, {
        { key = "player", label = "Player", width = "1fr" },
        { key = "choice", label = "Choice", width = 86 },
        { key = "roll",   label = "Roll",   width = 50, justify = "RIGHT" },
        { key = "count",  label = "Count",  width = 78, justify = "RIGHT" },
    }, { rowH = PLAYER_ROW_H, headerH = 24 })
    roster:SetPoint("TOPLEFT", rightSC, "TOPLEFT", 0, 0)
    roster:SetPoint("TOPRIGHT", rightSC, "TOPRIGHT", 0, 0)
    roster:SetHeight(24)
    f.roster = roster
    self._roster = roster

    -- Combat hide/show
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:HookScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if f:IsShown() then LargeRollFrame._hiddenForCombat = true; f:Hide() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if LargeRollFrame._hiddenForCombat then LargeRollFrame._hiddenForCombat = false; f._skipFadeOnce = true; f:Show() end
        end
    end)

    f:Hide()
    self._frame = f
    do
        local cx, cy = f:GetCenter()
        local sw = GetScreenWidth()  / UIParent:GetEffectiveScale()
        local sh = GetScreenHeight() / UIParent:GetEffectiveScale()
        if not cx or cx < 0 or cx > sw or not cy or cy < 0 or cy > sh then
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end
    self:ApplyTheme(theme)
    return f
end

function LargeRollFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f.leftBg:SetVertexColor(C(theme, "panelBgColor"))
    f.vDiv:SetVertexColor(C(theme, "dividerColor"))
    f.ddRule:SetVertexColor(C(theme, "dividerColor"))
    f.countdown:SetTextColor(C(theme, "textColor"))
    f.secLbl:SetTextColor(C(theme, "textMutedColor"))
    f.rHeader.rule:SetVertexColor(C(theme, "dividerColor"))
    f.rHeader.sub:SetTextColor(C(theme, "textMutedColor"))
    for _, row in ipairs(self._itemRowPool) do row:ApplyTheme(theme) end
end

------------------------------------------------------------------------
-- Show all items for a new loot roll
------------------------------------------------------------------------
function LargeRollFrame:ShowAllItems(items, rollOptions)
    local f = self:GetFrame()
    -- A short list after a long one must not start scrolled past its end.
    if f.leftSF then f.leftSF:SetVerticalScroll(0) end
    if f.rightSF then f.rightSF:SetVerticalScroll(0) end
    local theme = ns.Theme:GetCurrent()

    self._rollOptions    = rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self._respondedItems = {}
    self._previewMode    = false
    self._items          = items
    self._viewingHistory = false
    self._historyBossKey = nil
    self._choices        = {}

    self._optPriority = {}
    for _, opt in ipairs(self._rollOptions) do self._optPriority[opt.name] = opt.priority end

    -- Pre-populate choices from Session.responses if we're the loot authority
    if ns.Session and ns.Session:IsLootAuthority() and ns.Session.responses then
        for idx, resps in pairs(ns.Session.responses) do
            self._choices[idx] = {}
            for pName, data in pairs(resps) do self._choices[idx][pName] = data end
        end
    end

    self:LockBossDropdown()
    f.historyBtn:SetLabel("Current roll")
    f.header:SetSubtitle(ns.Session and ns.Session.currentBoss or "Unknown")
    f.rHeader.seg:SetOptions(self._rollOptions)

    local duration = (ns.Session and ns.Session.GetRollDuration and ns.Session:GetRollDuration())
        or ns.db.profile.rollTimer or 30
    self._timerDuration = duration
    f.timerBar:SetProgress(duration, duration)
    f.timerBar:Show()
    f.countdown:SetText(tostring(math.ceil(duration)))
    f.countdown:SetTextColor(C(theme, "textColor"))

    self._selectedItemIdx = 1
    self:_RefreshLeftPanel()
    self:_RefreshRightPanel()

    ns.RF_AutoPassScan(items, self._respondedItems, function(idx)
        self:_OnRollChoiceInternal(idx, "Pass")
    end)
    self:_UpdatePassAllLabel()

    ns.RaiseFrame(f)
    f:Show()
end

function LargeRollFrame:_UpdatePassAllLabel()
    local f = self._frame
    if not f then return end
    local remaining = 0
    for idx = 1, #(self._items or {}) do
        if not self._respondedItems[idx] then remaining = remaining + 1 end
    end
    f.passAllBtn:SetLabel("Pass all")
    f.passAllBtn:SetSubLabel(remaining > 0 and tostring(remaining) or nil)
    f.passAllBtn:SetEnabled(remaining > 0 and not self._viewingHistory)
end

------------------------------------------------------------------------
-- Left panel: item rows (48px) with pills and own choice
------------------------------------------------------------------------
function LargeRollFrame:_AcquireItemRow(parent)
    for _, row in ipairs(self._itemRowPool) do
        if not row._inUse then row._inUse = true; row:SetParent(parent); row:ClearAllPoints(); return row end
    end
    local row = ns.MakeItemRow(parent, ITEM_ROW_H, { iconSize = 28 })
    row.statPill = ns.MakePill(row, "", nil, { filled = true, h = 14 })
    row.typePill = ns.MakePill(row, "", nil, { h = 14 })
    row.statPill:Hide(); row.typePill:Hide()
    row:HookScript("OnEnter", function(r)
        if r._link then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            if r._link:find("|H") then GameTooltip:SetHyperlink(r._link) else GameTooltip:SetText(r._link) end
            GameTooltip:Show()
        end
    end)
    row:HookScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", function(r)
        LargeRollFrame._selectedItemIdx = r._idx
        LargeRollFrame:_RefreshLeftPanel()
        if LargeRollFrame._viewingHistory then LargeRollFrame:_RefreshHistoryRightPanel()
        else LargeRollFrame:_RefreshRightPanel() end
    end)
    row._inUse = true
    tinsert(self._itemRowPool, row)
    return row
end

function LargeRollFrame:_RefreshLeftPanel()
    local sc = self._leftScrollChild
    if not sc then return end
    local theme = ns.Theme:GetCurrent()
    for _, row in ipairs(self._itemRowPool) do row:Hide(); row._inUse = false end

    local hist = self._viewingHistory and ns.Session and ns.Session.bossHistory
        and ns.Session.bossHistory[self._historyBossKey]
    local items = self._viewingHistory and (hist and hist.items or {}) or (self._items or {})

    local yOffset = 0
    for idx, item in ipairs(items) do
        local row = self:_AcquireItemRow(sc)
        row._idx = idx
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)
        row:SetItem(item)
        -- pills below the name (row.meta unused here)
        row.name:ClearAllPoints()
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -1)
        row.name:SetPoint("RIGHT", row.rightSlot, "LEFT", -8, 0)
        ns.RF_ApplyPills(row, item.link, row.name, -4)
        row:SetSelected(idx == self._selectedItemIdx)

        -- right slot: winner / own choice / waiting dash
        local result
        if self._viewingHistory then result = hist and hist.results and hist.results[idx]
        else result = ns.Session and ns.Session.results and ns.Session.results[idx] end
        if result and result.winner then
            row:SetRight(ns.StripRealm(result.winner), theme.timerBarFullColor)
        elseif result then
            row:SetRight(ns.Track("No winner"), theme.textDimColor)
        else
            local mine = self._choices[idx] and self._choices[idx][ns.GetPlayerNameRealm()]
            local choice = mine and mine.choice
            if choice then
                row:SetRight(ns.Track(choice), ns.Theme:ChoiceColor(choice, theme))
            else
                row:SetRight("—", theme.textDimColor)
            end
        end
        row:Show()
        yOffset = yOffset - ITEM_ROW_H
    end
    sc:SetHeight(math.max(math.abs(yOffset), 1))
end

------------------------------------------------------------------------
-- Right panel: header (own choice) + roster for the selected item
------------------------------------------------------------------------
function LargeRollFrame:_RefreshRightPanel()
    local f = self._frame
    if not f then return end
    local theme = ns.Theme:GetCurrent()
    local items = self._items
    local itemIdx = self._selectedItemIdx
    local item = items and items[itemIdx]

    -- header
    if item then
        local qr, qg, qb = ns.GetItemQualityColor(item.quality or 1)
        f.rHeader.name:SetText(item.name or "Unknown")
        f.rHeader.name:SetTextColor(qr, qg, qb)
    else
        f.rHeader.name:SetText("")
    end
    self:_RebuildRollButtons(itemIdx)

    -- roster
    local roster = self._roster
    roster:ReleaseRows()
    local playerList = self:_BuildSortedPlayerList(itemIdx)
    for _, entry in ipairs(playerList) do
        local row = roster:AcquireRow()
        local isSelf = ns.NamesMatch(entry.player, ns.GetPlayerNameRealm())
        row:SetCell("player", ns.StripRealm(entry.player) or "", isSelf and theme.accentHiColor or theme.textColor)
        if entry.choice == nil then
            row:SetCell("choice", ns.Track("Waiting"), theme.choiceWaitColor)
            row:SetCell("roll", "—", theme.textDimColor)
            row:SetAlpha(0.7)
        elseif entry.choice == "Pass" then
            row:SetCell("choice", ns.Track("Pass"), theme.choicePassColor)
            row:SetCell("roll", "—", theme.textDimColor)
            row:SetAlpha(0.55)
        else
            row:SetCell("choice", ns.Track(entry.choice), ns.Theme:ChoiceColor(entry.choice, theme))
            row:SetCell("roll", tostring(entry.roll or "—"), theme.textColor)
        end
        row:SetCell("count", tostring(entry.count or 0), theme.textColor)
        row:SetSelected(isSelf)
    end
    roster:SetHeight(roster:GetContentHeight())
    roster:Layout()
    self._rightScrollChild:SetHeight(roster:GetContentHeight() + 8)
end

------------------------------------------------------------------------
-- Build sorted player list for a given item index
------------------------------------------------------------------------
function LargeRollFrame:_BuildSortedPlayerList(itemIdx)
    if ns.Session and ns.Session:IsLootAuthority() and ns.Session.responses
            and ns.Session.responses[itemIdx] then
        self._choices[itemIdx] = self._choices[itemIdx] or {}
        for pName, data in pairs(ns.Session.responses[itemIdx]) do
            self._choices[itemIdx][pName] = data
        end
    end

    local choices = self._choices[itemIdx] or {}
    local eligibleSet = ns.Session and ns.Session:GetEligiblePlayers() or {}
    if ns.Session and ns.Session.debugMode and ns.Session._debugFakePlayers then
        for _, fpName in ipairs(ns.Session._debugFakePlayers) do eligibleSet[fpName] = true end
    end

    local seen, playerList = {}, {}
    for playerName in pairs(eligibleSet) do
        seen[playerName] = true
        local data = choices[playerName]
        local pri
        if not data or data.choice == nil then pri = 1000
        elseif data.choice == "Pass" then pri = 900
        else pri = self._optPriority[data.choice] or 500 end
        tinsert(playerList, {
            player = playerName, choice = data and data.choice or nil, roll = data and data.roll or nil,
            count = data and data.countAtRoll or ns.LootCount:GetCount(playerName), priority = pri,
        })
    end
    for playerName, data in pairs(choices) do
        if not seen[playerName] then
            local pri = data.choice == "Pass" and 900 or (self._optPriority[data.choice] or 500)
            tinsert(playerList, {
                player = playerName, choice = data.choice, roll = data.roll,
                count = data.countAtRoll or ns.LootCount:GetCount(playerName), priority = pri,
            })
        end
    end
    table.sort(playerList, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if (a.count or 0) ~= (b.count or 0) then return (a.count or 0) < (b.count or 0) end
        if (a.roll or 0) ~= (b.roll or 0) then return (a.roll or 0) > (b.roll or 0) end
        return (a.player or "") < (b.player or "")
    end)
    return playerList
end

------------------------------------------------------------------------
-- Own choice control in the right header (segmented / chosen / result)
------------------------------------------------------------------------
function LargeRollFrame:_RebuildRollButtons(itemIdx)
    local f = self._frame
    if not f then return end
    local h = f.rHeader
    local theme = ns.Theme:GetCurrent()
    h.seg:Hide(); h.status:Hide()

    if not itemIdx or not self._items or not self._items[itemIdx] then return end
    if self._viewingHistory then return end

    local result = ns.Session and ns.Session.results and ns.Session.results[itemIdx]
    if result then
        if result.winner then
            h.status:SetText(ns.Track("Won by ") .. ns.StripRealm(result.winner)
                .. "  ·  " .. ns.Track(result.choice or "?") .. " " .. (result.roll or 0))
            h.status:SetTextColor(C(theme, "timerBarFullColor"))
        else
            h.status:SetText(ns.Track("No winner"))
            h.status:SetTextColor(C(theme, "textDimColor"))
        end
        h.status:Show()
        return
    end

    h.seg:SetOptions(self._rollOptions or ns.DEFAULT_ROLL_OPTIONS)
    if self._respondedItems[itemIdx] then
        local myChoices = self._choices[itemIdx]
        local mine = myChoices and myChoices[ns.GetPlayerNameRealm()]
        h.seg:SetSelected(mine and mine.choice or nil)
        h.seg:SetEnabled(false)
    else
        h.seg:SetSelected(nil)
        h.seg:SetEnabled(true)
    end
    h.seg:Show()
end

------------------------------------------------------------------------
-- Choices
------------------------------------------------------------------------
function LargeRollFrame:OnRollChoice(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self:_OnRollChoiceInternal(itemIdx, choice)
end

function LargeRollFrame:MarkResponded(itemIdx, choice)
    self._respondedItems[itemIdx] = true
    self._choices[itemIdx] = self._choices[itemIdx] or {}
    local me = ns.GetPlayerNameRealm()
    self._choices[itemIdx][me] = self._choices[itemIdx][me]
        or { choice = choice, countAtRoll = ns.LootCount:GetCount(me) }
    self._choices[itemIdx][me].choice = choice
    if itemIdx == self._selectedItemIdx then
        self:_RebuildRollButtons(itemIdx)
        self:_RefreshRightPanel()
    end
    self:_RefreshLeftPanel()
    self:_UpdatePassAllLabel()
end

function LargeRollFrame:_OnRollChoiceInternal(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self._respondedItems[itemIdx] = true

    -- record our own choice locally so the header/left panel reflect it
    -- before the leader's CHOICES_UPDATE arrives
    self._choices[itemIdx] = self._choices[itemIdx] or {}
    local me = ns.GetPlayerNameRealm()
    self._choices[itemIdx][me] = self._choices[itemIdx][me] or { choice = choice, countAtRoll = ns.LootCount:GetCount(me) }
    self._choices[itemIdx][me].choice = choice

    if ns.Session and not self._previewMode then ns.Session:SubmitResponse(itemIdx, choice) end

    if itemIdx == self._selectedItemIdx then
        self:_RebuildRollButtons(itemIdx)
        self:_RefreshRightPanel()
    end
    self:_RefreshLeftPanel()
    self:_UpdatePassAllLabel()

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

function LargeRollFrame:SetExternalSelection(itemIdx, choice)
    self._respondedItems[itemIdx] = nil
    self:_OnRollChoiceInternal(itemIdx, choice)
end

function LargeRollFrame:ResetItemChoice(itemIdx)
    self._respondedItems[itemIdx] = nil
    if self._choices[itemIdx] then self._choices[itemIdx][ns.GetPlayerNameRealm()] = nil end
    if itemIdx == self._selectedItemIdx then
        self:_RebuildRollButtons(itemIdx)
        self:_RefreshRightPanel()
    end
    self:_RefreshLeftPanel()
    self:_UpdatePassAllLabel()
end

function LargeRollFrame:AutoPassAll()
    if not ns.Session then return end
    for idx = 1, #(ns.Session.currentItems or {}) do
        if not self._respondedItems[idx] then self:_OnRollChoiceInternal(idx, "Pass") end
    end
end

------------------------------------------------------------------------
-- CHOICES_UPDATE delta from the leader
------------------------------------------------------------------------
function LargeRollFrame:ApplyChoiceDelta(delta)
    if not delta or not delta.itemIdx or not delta.player then return end
    if not self._choices[delta.itemIdx] then self._choices[delta.itemIdx] = {} end
    self._choices[delta.itemIdx][delta.player] = {
        choice = delta.choice, countAtRoll = delta.countAtRoll, roll = delta.roll,
    }
    if self._frame and self._frame:IsShown() and not self._viewingHistory then
        self:_RefreshRightPanel()
        self:_RefreshLeftPanel()
    end
end

function LargeRollFrame:ShowResult(itemIdx, result)
    if not self._frame or not self._frame:IsShown() then return end
    if self._viewingHistory then return end
    self:_RefreshLeftPanel()
    if itemIdx == self._selectedItemIdx then self:_RefreshRightPanel() end
end

------------------------------------------------------------------------
-- Timer
------------------------------------------------------------------------
function LargeRollFrame:OnTimerTick(remaining)
    if not self._frame or not self._frame:IsShown() then return end
    if self._viewingHistory then
        if remaining <= 0 then self:AutoPassAll() end
        return
    end
    local f = self._frame
    if remaining <= 0 then
        remaining = 0
        self:AutoPassAll()
        if not f.timerBar:IsShown() then return end
    end
    f.timerBar:SetProgress(remaining, self._timerDuration)
    f.countdown:SetText(tostring(math.ceil(remaining)))
    local theme = ns.Theme:GetCurrent()
    if remaining < 5 then f.countdown:SetTextColor(C(theme, "timerBarLowColor"))
    elseif remaining < 10 then f.countdown:SetTextColor(C(theme, "timerBarMidColor"))
    else f.countdown:SetTextColor(C(theme, "textColor")) end
end

------------------------------------------------------------------------
-- Boss history
------------------------------------------------------------------------
function LargeRollFrame:_OpenHistoryMenu()
    if self._historyLocked then return end
    local f = self:GetFrame()
    ns.RF_OpenHistoryMenu(f.historyBtn, function()
        LargeRollFrame._viewingHistory = false
        LargeRollFrame._historyBossKey = nil
        f.historyBtn:SetLabel("Current roll")
        f.header:SetSubtitle(ns.Session and ns.Session.currentBoss or "")
        LargeRollFrame:_RefreshLeftPanel()
        LargeRollFrame:_RefreshRightPanel()
        LargeRollFrame:_UpdatePassAllLabel()
    end, function(key) LargeRollFrame:_ShowBossHistory(key) end)
end

function LargeRollFrame:_PopulateBossDropdown() end   -- legacy no-op

function LargeRollFrame:_ShowBossHistory(bossKey)
    if self._frame then
        if self._frame.leftSF then self._frame.leftSF:SetVerticalScroll(0) end
        if self._frame.rightSF then self._frame.rightSF:SetVerticalScroll(0) end
    end
    local data = ns.Session and ns.Session:GetBossHistory(bossKey)
    if not data then return end
    local f = self:GetFrame()
    self._viewingHistory = true
    self._historyBossKey = bossKey
    self._selectedItemIdx = 1
    f.historyBtn:SetLabel(bossKey)
    f.header:SetSubtitle(bossKey)
    f.timerBar:Hide()
    f.countdown:SetText("")
    self:_RefreshLeftPanel()
    self:_RefreshHistoryRightPanel()
    self:_UpdatePassAllLabel()
end

function LargeRollFrame:_RefreshHistoryRightPanel()
    local f = self._frame
    if not f then return end
    local theme = ns.Theme:GetCurrent()
    local data = ns.Session and ns.Session.bossHistory and ns.Session.bossHistory[self._historyBossKey]
    local item = data and data.items and data.items[self._selectedItemIdx]
    local result = data and data.results and data.results[self._selectedItemIdx]

    f.rHeader.seg:Hide()
    if item then
        local qr, qg, qb = ns.GetItemQualityColor(item.quality or 1)
        f.rHeader.name:SetText(item.name or "Unknown")
        f.rHeader.name:SetTextColor(qr, qg, qb)
    else
        f.rHeader.name:SetText("")
    end
    if result and result.winner then
        f.rHeader.status:SetText(ns.Track("Won by ") .. ns.StripRealm(result.winner)
            .. "  ·  " .. ns.Track(result.choice or "?") .. " " .. (result.roll or 0))
        f.rHeader.status:SetTextColor(C(theme, "timerBarFullColor"))
    else
        f.rHeader.status:SetText(ns.Track("No winner"))
        f.rHeader.status:SetTextColor(C(theme, "textDimColor"))
    end
    f.rHeader.status:Show()

    local roster = self._roster
    roster:ReleaseRows()
    for _, cand in ipairs(result and result.rankedCandidates or {}) do
        local row = roster:AcquireRow()
        local isSelf = ns.NamesMatch(cand.player, ns.GetPlayerNameRealm())
        row:SetCell("player", ns.StripRealm(cand.player) or "", isSelf and theme.accentHiColor or theme.textColor)
        row:SetCell("choice", ns.Track(cand.choice or "?"), ns.Theme:ChoiceColor(cand.choice, theme))
        row:SetCell("roll", tostring(cand.roll or "—"), theme.textColor)
        row:SetCell("count", tostring(cand.count or 0), theme.textColor)
        row:SetSelected(result and result.winner and ns.NamesMatch(result.winner, cand.player) or false)
    end
    roster:SetHeight(roster:GetContentHeight())
    roster:Layout()
    self._rightScrollChild:SetHeight(roster:GetContentHeight() + 8)
end

function LargeRollFrame:LockBossDropdown()
    self._historyLocked = true
    if self._frame then self._frame.historyBtn:SetEnabled(false) end
end

function LargeRollFrame:UnlockBossDropdown()
    self._historyLocked = false
    if self._frame then
        self._frame.historyBtn:SetEnabled(true)
        if self._viewingHistory then
            self._viewingHistory = false
            self._historyBossKey = nil
            self._frame.historyBtn:SetLabel("Current roll")
            self:_RefreshLeftPanel()
            self:_RefreshRightPanel()
        end
    end
end

------------------------------------------------------------------------
-- Visibility / reset
------------------------------------------------------------------------
function LargeRollFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

function LargeRollFrame:Hide()
    self._hiddenForCombat = false
    if self._frame then self._frame:Hide() end
end

function LargeRollFrame:Show()
    self:GetFrame():Show()
end

function LargeRollFrame:Reset()
    self._hiddenForCombat = false
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
    for _, row in ipairs(self._itemRowPool) do row:Hide() end
    if self._roster then self._roster:ReleaseRows() end
    if self._frame then
        self._frame.timerBar:SetProgress(0, 1)
        self._frame.countdown:SetText("")
    end
end
