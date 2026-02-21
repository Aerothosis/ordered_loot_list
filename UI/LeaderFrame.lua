------------------------------------------------------------------------
-- OrderedLootList  –  UI/LeaderFrame.lua
-- Leader session control panel: start/end session, item list,
-- responses, award/re-roll, trade helper queue with Open Trade.
------------------------------------------------------------------------

local ns                  = _G.OLL_NS

local LeaderFrame         = {}
ns.LeaderFrame            = LeaderFrame

local FRAME_WIDTH         = 500
local FRAME_HEIGHT        = 450

LeaderFrame._frame        = nil
LeaderFrame._scrollChild  = nil
LeaderFrame._tickerHandle = nil

------------------------------------------------------------------------
-- Create frame (lazy init)
------------------------------------------------------------------------
function LeaderFrame:GetFrame()
    if self._frame then return self._frame end

    local f = CreateFrame("Frame", "OLLLeaderFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
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
        ns.SaveFramePosition("LeaderFrame", self)
    end)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(self) ns.RaiseFrame(self) end)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Loot Session Control")
    f.title = title

    -- Start / End Session button
    local sessionBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sessionBtn:SetSize(140, 28)
    sessionBtn:SetPoint("TOPLEFT", 14, -34)
    sessionBtn:SetText("Start Session")
    sessionBtn:SetScript("OnClick", function()
        if ns.Session and ns.Session:IsActive() then
            ns.Session:EndSession()
        else
            ns.Session:StartSession()
        end
        LeaderFrame:Refresh()
    end)
    f.sessionBtn = sessionBtn

    -- Session status text
    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("LEFT", sessionBtn, "RIGHT", 12, 0)
    f.sessionStatus = statusText

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() LeaderFrame:Hide() end)

    -- Roll timer bar (between header and scroll area)
    local timerBar = CreateFrame("StatusBar", nil, f)
    timerBar:SetSize(FRAME_WIDTH - 28, 18)
    timerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -66)
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
    timerBar:Hide()
    f.timerBar = timerBar

    -- Scroll frame for item list / trade queue
    local scrollFrame = CreateFrame("ScrollFrame", "OLLLeaderScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -88)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 14)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 50, 1) -- height set dynamically
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild
    self._scrollChild = scrollChild

    f:Hide()
    self._frame = f
    ns.RestoreFramePosition("LeaderFrame", f)
    return f
end

------------------------------------------------------------------------
-- Refresh the display
------------------------------------------------------------------------
function LeaderFrame:Refresh()
    local f = self:GetFrame()
    if not f:IsShown() then return end

    local session = ns.Session
    if not session then return end

    -- Update session button
    if session:IsActive() then
        f.sessionBtn:SetText("End Session")
        f.sessionStatus:SetText("|cff00ff00Active|r")
    else
        f.sessionBtn:SetText("Start Session")
        f.sessionStatus:SetText("|cffff0000Inactive|r")
    end

    -- Roll timer bar
    if session.state == session.STATE_ROLLING and session._rollTimerStart then
        self:StartTimer()
    else
        self:StopTimer()
    end

    -- Clear scroll child
    local sc = self._scrollChild
    for _, child in ipairs({ sc:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ sc:GetRegions() }) do
        region:Hide()
    end

    local yOffset = 0

    -- === CURRENT BOSS (at the top) ===
    if session:IsActive() and #session.currentItems > 0 then
        yOffset = self:_DrawSectionHeader(sc, yOffset, "Current Loot – " .. (session.currentBoss or "Unknown"))
        yOffset = yOffset - 4

        for idx, item in ipairs(session.currentItems) do
            yOffset = self:_DrawItemRow(sc, yOffset, idx, item, session.results, session.responses, true)
        end
    end

    -- === HISTORICAL BOSSES (newest first) ===
    local order = session.bossHistoryOrder or {}
    for i = #order, 1, -1 do
        local bossKey = order[i]
        local data = session.bossHistory[bossKey]
        if data and data.items then
            yOffset = yOffset - 10
            yOffset = self:_DrawSectionHeader(sc, yOffset, bossKey)
            yOffset = yOffset - 4

            for idx, item in ipairs(data.items) do
                yOffset = self:_DrawItemRow(sc, yOffset, idx, item, data.results, data.responses, false)
            end
        end
    end

    -- === TRADE QUEUE ===
    local tradeQueue = session:GetTradeQueue()
    if tradeQueue and #tradeQueue > 0 then
        yOffset = yOffset - 10
        yOffset = self:_DrawSectionHeader(sc, yOffset, "Trade Queue")
        yOffset = yOffset - 4

        for _, entry in ipairs(tradeQueue) do
            yOffset = self:_DrawTradeRow(sc, yOffset, entry)
        end
    end

    -- Update scroll child height
    sc:SetHeight(math.abs(yOffset) + 20)
end

------------------------------------------------------------------------
-- Draw a section header
------------------------------------------------------------------------
function LeaderFrame:_DrawSectionHeader(parent, yOffset, text)
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    header:SetText("|cffffd100" .. text .. "|r")
    header:Show()
    return yOffset - 20
end

------------------------------------------------------------------------
-- Draw an item row with roll info
-- itemResults / itemResponses: the results/responses tables for this boss
-- isCurrent: whether this is the currently active boss (enables action buttons)
------------------------------------------------------------------------
function LeaderFrame:_DrawItemRow(parent, yOffset, itemIdx, item, itemResults, itemResponses, isCurrent)
    local ROW_HEIGHT = 50
    local session = ns.Session

    -- Item icon
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yOffset - 2)
    icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:Show()

    -- Item name
    local nameText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameText:SetPoint("LEFT", icon, "RIGHT", 6, 6)
    nameText:SetText(item.link or item.name or "Unknown")
    nameText:Show()

    -- Status
    local result = itemResults and itemResults[itemIdx]
    local responses = (itemResponses and itemResponses[itemIdx]) or {}

    local statusStr
    if result and result.winner then
        statusStr = "|cff00ff00Won by: " .. result.winner .. " (" .. result.choice .. " " .. result.roll .. ")|r"
    elseif isCurrent and session.state == session.STATE_ROLLING then
        local count = 0
        for _ in pairs(responses) do count = count + 1 end
        statusStr = "|cffffff00Rolling... (" .. count .. " responded)|r"
    else
        statusStr = "|cff888888Pending|r"
    end

    local statusText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("LEFT", icon, "RIGHT", 6, -8)
    statusText:SetText(statusStr)
    statusText:Show()

    -- Response details (if rolling or resolved)
    if next(responses) then
        local detailY = yOffset - 32
        for player, data in pairs(responses) do
            local count = ns.LootCount:GetCount(player)
            local roll = data.roll or "-"
            local detailText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            detailText:SetPoint("TOPLEFT", parent, "TOPLEFT", 44, detailY)
            detailText:SetText(string.format("  %s: %s (Count: %d)", player, data.choice, count))
            detailText:SetTextColor(0.7, 0.7, 0.7)
            detailText:Show()
            detailY = detailY - 14
            ROW_HEIGHT = ROW_HEIGHT + 14
        end
    end

    -- Action buttons (leader only, for resolved items on current boss)
    if isCurrent and result and result.winner then
        local announceBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        announceBtn:SetSize(70, 20)
        announceBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, yOffset - 4)
        announceBtn:SetText("Announce")
        announceBtn:SetScript("OnClick", function()
            session:AnnounceWinner(itemIdx)
        end)
        announceBtn:Show()

        local rerollBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        rerollBtn:SetSize(60, 20)
        rerollBtn:SetPoint("RIGHT", announceBtn, "LEFT", -4, 0)
        rerollBtn:SetText("Re-roll")
        rerollBtn:SetScript("OnClick", function()
            -- Reset this item's responses and re-roll
            session.responses[itemIdx] = {}
            session.results[itemIdx] = nil
            session:StartAllRolls()
        end)
        rerollBtn:Show()

        local reassignBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        reassignBtn:SetSize(70, 20)
        reassignBtn:SetPoint("RIGHT", rerollBtn, "LEFT", -4, 0)
        reassignBtn:SetText("Reassign")
        reassignBtn:SetScript("OnClick", function()
            LeaderFrame:ShowReassignPopup(itemIdx, item)
        end)
        reassignBtn:Show()
    end

    return yOffset - ROW_HEIGHT
end

------------------------------------------------------------------------
-- Draw a trade queue row
------------------------------------------------------------------------
function LeaderFrame:_DrawTradeRow(parent, yOffset, entry)
    local ROW_HEIGHT = 32

    -- Icon
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yOffset - 2)
    icon:SetTexture(entry.itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:Show()

    -- Item link + winner
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetText((entry.itemLink or entry.itemName or "?") .. " → " .. (entry.winner or "?"))
    text:Show()

    -- Status
    if entry.awarded then
        local doneText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        doneText:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, yOffset - 6)
        doneText:SetText("|cff00ff00Traded|r")
        doneText:Show()
    else
        -- Open Trade button
        local tradeBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        tradeBtn:SetSize(80, 22)
        tradeBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, yOffset - 3)
        tradeBtn:SetText("Open Trade")
        tradeBtn:SetScript("OnClick", function()
            -- Try to target and initiate trade with the winner
            local shortName = entry.winner:match("^(.-)%-") or entry.winner
            -- Try to initiate trade
            if UnitExists(shortName) then
                InitiateTrade(shortName)
            else
                -- Try by name in raid/party
                for i = 1, GetNumGroupMembers() do
                    local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
                    local unitName = GetUnitName(unit, true)
                    if unitName and (unitName == entry.winner or unitName == shortName) then
                        InitiateTrade(unit)
                        return
                    end
                end
                ns.addon:Print("Could not find " .. entry.winner .. " to trade. Are they nearby?")
            end
        end)
        tradeBtn:Show()
    end

    return yOffset - ROW_HEIGHT
end

------------------------------------------------------------------------
-- Show reassign popup for an item
------------------------------------------------------------------------
function LeaderFrame:ShowReassignPopup(itemIdx, item)
    -- Hide any existing popup
    if self._reassignPopup then
        self._reassignPopup:Hide()
    end

    -- Get ranked candidates (skip current winner at position 1)
    local ranked = ns.Session:GetRankedCandidates(itemIdx)
    local currentWinner = ns.Session.results[itemIdx] and ns.Session.results[itemIdx].winner

    -- Count eligible next-place candidates (skip current winner)
    local nextCandidates = {}
    for _, c in ipairs(ranked) do
        if c.player ~= currentWinner then
            tinsert(nextCandidates, c)
        end
    end

    -- Calculate popup height based on candidates
    local candidateRows = math.min(#nextCandidates, 8) -- max 8 visible
    local popupHeight = 120 + candidateRows * 26 + (candidateRows > 0 and 24 or 0)

    local popup = CreateFrame("Frame", "OLLReassignPopup", UIParent, "BackdropTemplate")
    popup:SetSize(360, popupHeight)
    popup:SetPoint("CENTER", UIParent, "CENTER")
    popup:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    popup:SetBackdropColor(0.08, 0.08, 0.15, 0.97)
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    -- Title
    local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Reassign: " .. (item and (item.link or item.name) or "Item"))

    local yPos = -36

    -- Next-place candidate buttons
    if #nextCandidates > 0 then
        local sectionLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sectionLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
        sectionLabel:SetText("|cffffd100Reassign to next-place winner:|r")
        yPos = yPos - 18

        for i, candidate in ipairs(nextCandidates) do
            if i > 8 then break end -- limit to 8 buttons

            local ordinalSuffix
            local pos = i + 1 -- 1st was the winner, so +1 for display
            if pos == 2 then
                ordinalSuffix = "2nd"
            elseif pos == 3 then
                ordinalSuffix = "3rd"
            else
                ordinalSuffix = pos .. "th"
            end

            local btnText = string.format("%s  %s (%s %d, Count: %d)",
                ordinalSuffix,
                candidate.player,
                candidate.choice or "?",
                candidate.roll or 0,
                candidate.count or ns.LootCount:GetCount(candidate.player))

            local btn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
            btn:SetSize(328, 22)
            btn:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
            btn:SetText(btnText)
            btn:GetFontString():SetJustifyH("LEFT")
            btn:SetScript("OnClick", function()
                ns.Session:ReassignItem(itemIdx, candidate.player)
                popup:Hide()
            end)

            yPos = yPos - 26
        end
    else
        local noLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        noLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
        noLabel:SetText("|cff888888No other candidates rolled.|r")
        yPos = yPos - 18
    end

    -- Separator
    yPos = yPos - 6
    local sep = popup:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    sep:SetSize(328, 1)
    sep:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
    yPos = yPos - 8

    -- Manual entry section
    local label = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
    label:SetText("Or enter manually (Name-Realm):")
    yPos = yPos - 18

    local editBox = CreateFrame("EditBox", "OLLReassignEdit", popup, "InputBoxTemplate")
    editBox:SetSize(220, 22)
    editBox:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
    editBox:SetAutoFocus(false)

    local confirmBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    confirmBtn:SetSize(80, 22)
    confirmBtn:SetPoint("LEFT", editBox, "RIGHT", 6, 0)
    confirmBtn:SetText("Confirm")
    confirmBtn:SetScript("OnClick", function()
        local newWinner = editBox:GetText():trim()
        if newWinner ~= "" then
            ns.Session:ReassignItem(itemIdx, newWinner)
            popup:Hide()
        end
    end)

    editBox:SetScript("OnEnterPressed", function()
        confirmBtn:Click()
    end)
    editBox:SetScript("OnEscapePressed", function()
        popup:Hide()
    end)

    popup:Show()
    self._reassignPopup = popup
end

------------------------------------------------------------------------
-- Show / Hide / Toggle
------------------------------------------------------------------------
function LeaderFrame:Show()
    local f = self:GetFrame()
    f:Show()
    self:Refresh()
end

function LeaderFrame:Hide()
    self:StopTimer()
    if self._frame then
        self._frame:Hide()
    end
end

function LeaderFrame:Reset()
    self:StopTimer()
    self:Hide()
    if self._scrollChild then
        for _, child in ipairs({ self._scrollChild:GetChildren() }) do
            child:Hide()
            child:SetParent(nil)
        end
        for _, region in ipairs({ self._scrollChild:GetRegions() }) do
            region:Hide()
        end
    end
end

------------------------------------------------------------------------
-- Roll timer bar management
------------------------------------------------------------------------
function LeaderFrame:StartTimer()
    local f = self:GetFrame()
    local session = ns.Session
    if not session or not session._rollTimerStart then return end

    f.timerBar:SetMinMaxValues(0, session._rollTimerDuration)
    f.timerBar:Show()

    if not self._tickerHandle then
        self._tickerHandle = C_Timer.NewTicker(0.1, function()
            self:UpdateTimer()
        end)
    end
    self:UpdateTimer()
end

function LeaderFrame:StopTimer()
    if self._tickerHandle then
        self._tickerHandle:Cancel()
        self._tickerHandle = nil
    end
    if self._frame and self._frame.timerBar then
        self._frame.timerBar:Hide()
    end
end

function LeaderFrame:UpdateTimer()
    local f = self._frame
    if not f or not f:IsShown() then
        self:StopTimer()
        return
    end

    local session = ns.Session
    if not session or not session._rollTimerStart then
        self:StopTimer()
        return
    end

    local elapsed = GetTime() - session._rollTimerStart
    local remaining = session._rollTimerDuration - elapsed

    if remaining <= 0 then
        remaining = 0
        self:StopTimer()
    end

    f.timerBar:SetValue(remaining)
    f.timerBar.text:SetText("Roll Timer: " .. math.ceil(remaining) .. "s")

    -- Color changes as time runs out
    if remaining < 5 then
        f.timerBar:SetStatusBarColor(1, 0.2, 0.2)
    elseif remaining < 10 then
        f.timerBar:SetStatusBarColor(1, 0.6, 0.2)
    else
        f.timerBar:SetStatusBarColor(0.2, 0.6, 1.0)
    end
end

function LeaderFrame:Toggle()
    local f = self:GetFrame()
    if f:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end
