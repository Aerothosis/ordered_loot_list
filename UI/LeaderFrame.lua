------------------------------------------------------------------------
-- OrderedLootList  –  UI/LeaderFrame.lua
-- Leader session control panel: start/end session, item list,
-- responses, award/re-roll, trade helper queue with Open Trade.
-- Split-panel layout: gear list (left) / player rolls (right).
------------------------------------------------------------------------

local ns                      = _G.OLL_NS

local LeaderFrame             = {}
ns.LeaderFrame                = LeaderFrame

local FRAME_WIDTH             = 700
local FRAME_HEIGHT            = 500
local LEFT_PANEL_WIDTH        = 260
local DIVIDER_WIDTH           = 2
local HEADER_HEIGHT           = 112 -- space for title, two button rows, timer
local ITEM_ROW_HEIGHT         = 30
local PLAYER_ROW_HEIGHT       = 20
local ACTION_BAR_HEIGHT       = 36 -- fixed bottom bar for Announce/Re-roll/Reassign

LeaderFrame._frame            = nil
LeaderFrame._leftScrollChild  = nil
LeaderFrame._rightScrollChild = nil
LeaderFrame._actionBar        = nil
LeaderFrame._tickerHandle     = nil

-- Selection state: { source="current"|"history", bossKey=string, itemIdx=number }
LeaderFrame._selectedItem     = nil
-- Pool of left-panel item row frames for reuse
LeaderFrame._itemRowPool      = {}
-- Pool of right-panel player row frames for reuse
LeaderFrame._playerRowPool    = {}

-- Loot Master popup state
LeaderFrame._lootMasterPopup   = nil  -- popup frame (lazy created)

-- Manual Roll popup state
LeaderFrame._manualRollItems   = {}   -- pending items for manual roll popup
LeaderFrame._manualRollPopup   = nil  -- popup frame (lazy created)
LeaderFrame._manualListChild   = nil  -- scroll child inside the popup
LeaderFrame._manualStartBtn    = nil  -- Start Roll button reference
LeaderFrame._manualCaptureBox       = nil  -- EditBox for manual-paste fallback
LeaderFrame._manualLinkHookInstalled = nil  -- guard: ChatEdit_InsertLink hook
LeaderFrame._manualItemRowPool = {}   -- reusable item row frames for the popup
LeaderFrame._manualEmptyText   = nil  -- "no items" placeholder text
LeaderFrame._manualDiv1        = nil  -- divider (for theme updates)
LeaderFrame._manualDiv2        = nil  -- divider (for theme updates)

-- Trade Queue popup state
LeaderFrame._tradeQueuePopup   = nil  -- popup frame (lazy created)
LeaderFrame._tradeQueueRowPool = {}   -- reusable rows

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function StripRealm(name)
    if not name then return name end
    return name:match("^(.-)%-") or name
end

-- Get all group member names (Name-Realm format)
local function GetGroupMembers()
    local members = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        -- Solo: just the player
        tinsert(members, ns.GetPlayerNameRealm())
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                -- GetRaidRosterInfo returns name without realm if same realm
                local full = name
                if not name:find("-") then
                    full = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(members, full)
            end
        end
    else
        -- Party: "player" + party1..partyN
        tinsert(members, ns.GetPlayerNameRealm())
        for i = 1, numMembers - 1 do
            local unit = "party" .. i
            local name = GetUnitName(unit, true)
            if name then
                if not name:find("-") then
                    name = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(members, name)
            end
        end
    end
    -- In debug mode, append fake players so they show as pending until they roll
    if ns.Session and ns.Session.debugMode then
        for _, name in ipairs(ns.Session._debugFakePlayers) do
            tinsert(members, name)
        end
    end

    return members
end

------------------------------------------------------------------------
-- Create frame (lazy init)
------------------------------------------------------------------------
function LeaderFrame:GetFrame()
    if self._frame then return self._frame end

    local theme = ns.Theme:GetCurrent()

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
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frm)
        frm:StopMovingOrSizing()
        ns.SaveFramePosition("LeaderFrame", frm)
    end)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(frm) ns.RaiseFrame(frm) end)

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

    -- Check Party button
    local checkPartyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    checkPartyBtn:SetSize(140, 28)
    checkPartyBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 160, -34)
    checkPartyBtn:SetText("Check Party")
    checkPartyBtn:SetScript("OnClick", function()
        if ns.CheckPartyFrame then
            ns.CheckPartyFrame:Show()
        end
    end)
    f.checkPartyBtn = checkPartyBtn

    -- Manual Roll button
    local manualRollBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    manualRollBtn:SetSize(110, 28)
    manualRollBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 310, -34)
    manualRollBtn:SetText("Manual Roll")
    manualRollBtn:SetScript("OnClick", function()
        LeaderFrame:ShowManualRollPopup()
    end)
    f.manualRollBtn = manualRollBtn

    -- Stop Roll button
    local stopRollBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    stopRollBtn:SetSize(100, 28)
    stopRollBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 430, -34)
    stopRollBtn:SetText("Stop Roll")
    stopRollBtn:SetScript("OnClick", function()
        ns.Session:StopRoll()
    end)
    stopRollBtn:Disable()
    f.stopRollBtn = stopRollBtn

    -- Loot Master button
    local lootMasterBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    lootMasterBtn:SetSize(115, 28)
    lootMasterBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 540, -34)
    lootMasterBtn:SetText("Loot Master")
    lootMasterBtn:SetScript("OnClick", function()
        LeaderFrame:ShowLootMasterPopup()
    end)
    lootMasterBtn:Disable()
    f.lootMasterBtn = lootMasterBtn

    -- Loot Master current-name label (sits just above the button)
    local lootMasterLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lootMasterLabel:SetPoint("BOTTOM", lootMasterBtn, "TOP", 0, 3)
    lootMasterLabel:SetWidth(115)
    lootMasterLabel:SetJustifyH("CENTER")
    lootMasterLabel:SetText("")
    f.lootMasterLabel = lootMasterLabel

    -- Trade Queue button (second button row)
    local tradeQueueBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    tradeQueueBtn:SetSize(140, 22)
    tradeQueueBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -64)
    tradeQueueBtn:SetText("Trade Queue")
    tradeQueueBtn:SetScript("OnClick", function()
        LeaderFrame:ShowTradeQueuePopup()
    end)
    tradeQueueBtn:Disable()
    f.tradeQueueBtn = tradeQueueBtn

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() LeaderFrame:Hide() end)

    -- Roll timer bar (spans full width below header controls)
    local timerBar = CreateFrame("StatusBar", nil, f)
    timerBar:SetSize(FRAME_WIDTH - 28, 18)
    timerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -90)
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
    timerBar:Hide()
    f.timerBar = timerBar

    -- Vertical divider
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(theme.dividerColor))
    divider:SetSize(DIVIDER_WIDTH, FRAME_HEIGHT - HEADER_HEIGHT - 20)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT_PANEL_WIDTH + 14, -HEADER_HEIGHT)
    f.divider = divider

    -- ===== LEFT PANEL: Item list scroll =====
    local leftScroll = CreateFrame("ScrollFrame", "OLLLeaderLeftScroll", f, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -HEADER_HEIGHT)
    leftScroll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
    leftScroll:SetWidth(LEFT_PANEL_WIDTH - 20) -- leave room for scrollbar (~18px)

    local leftChild = CreateFrame("Frame", nil, leftScroll)
    leftChild:SetSize(LEFT_PANEL_WIDTH - 38, 1)
    leftScroll:SetScrollChild(leftChild)
    f.leftScrollChild = leftChild
    self._leftScrollChild = leftChild

    -- ===== RIGHT PANEL: Player detail scroll =====
    local rightX = LEFT_PANEL_WIDTH + 14 + DIVIDER_WIDTH + 6
    local rightWidth = FRAME_WIDTH - rightX - 14

    -- Fixed action bar pinned to the bottom of the right panel
    local actionBar = CreateFrame("Frame", nil, f)
    actionBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", rightX, 14)
    actionBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)
    actionBar:SetHeight(ACTION_BAR_HEIGHT)

    local actionSep = actionBar:CreateTexture(nil, "ARTWORK")
    actionSep:SetColorTexture(unpack(theme.actionSepColor))
    actionSep:SetPoint("TOPLEFT", actionBar, "TOPLEFT", 0, 0)
    actionSep:SetPoint("TOPRIGHT", actionBar, "TOPRIGHT", 0, 0)
    actionSep:SetHeight(1)
    actionBar.sep = actionSep

    local announceBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    announceBtn:SetSize(90, 24)
    announceBtn:SetPoint("LEFT", actionBar, "LEFT", 4, -6)
    announceBtn:SetText("Announce")
    announceBtn:Hide()
    f.announceBtn = announceBtn

    local rerollBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    rerollBtn:SetSize(80, 24)
    rerollBtn:SetPoint("LEFT", announceBtn, "RIGHT", 6, 0)
    rerollBtn:SetText("Re-roll")
    rerollBtn:Hide()
    f.rerollBtn = rerollBtn

    local reassignBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    reassignBtn:SetSize(90, 24)
    reassignBtn:SetPoint("LEFT", rerollBtn, "RIGHT", 6, 0)
    reassignBtn:SetText("Reassign")
    reassignBtn:Hide()
    f.reassignBtn = reassignBtn

    f.actionBar = actionBar
    self._actionBar = actionBar

    -- Scroll frame stops above the fixed action bar
    local rightScroll = CreateFrame("ScrollFrame", "OLLLeaderRightScroll", f, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, -HEADER_HEIGHT)
    rightScroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 14 + ACTION_BAR_HEIGHT + 4)

    local rightChild = CreateFrame("Frame", nil, rightScroll)
    rightChild:SetSize(rightWidth - 18, 1)
    rightScroll:SetScrollChild(rightChild)
    f.rightScrollChild = rightChild
    self._rightScrollChild = rightChild

    f:Hide()
    self._frame = f
    ns.RestoreFramePosition("LeaderFrame", f)
    return f
end

------------------------------------------------------------------------
-- Apply (or re-apply) the current theme to an already-created frame
------------------------------------------------------------------------
function LeaderFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()

    -- Main frame
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))

    -- Divider
    f.divider:SetColorTexture(unpack(theme.dividerColor))

    -- Timer bar
    f.timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
    if f.timerBar.bg then
        f.timerBar.bg:SetColorTexture(unpack(theme.timerBarBgColor))
    end

    -- Action bar separator
    if f.actionBar and f.actionBar.sep then
        f.actionBar.sep:SetColorTexture(unpack(theme.actionSepColor))
    end

    -- Check Party frame theming
    if ns.CheckPartyFrame then ns.CheckPartyFrame:ApplyTheme(theme) end

    -- Loot Master popup theming
    if self._lootMasterPopup then
        self._lootMasterPopup:SetBackdropColor(unpack(theme.frameBgColor))
        self._lootMasterPopup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
        if self._lootMasterPopup.div then
            self._lootMasterPopup.div:SetColorTexture(unpack(theme.dividerColor))
        end
        if self._lootMasterPopup.sep then
            self._lootMasterPopup.sep:SetColorTexture(unpack(theme.actionSepColor))
        end
    end

    -- Manual roll popup theming
    if self._manualRollPopup then
        self._manualRollPopup:SetBackdropColor(unpack(theme.frameBgColor))
        self._manualRollPopup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
        if self._manualDiv1 then self._manualDiv1:SetColorTexture(unpack(theme.dividerColor)) end
        if self._manualDiv2 then self._manualDiv2:SetColorTexture(unpack(theme.dividerColor)) end
    end

    -- Trade queue popup theming
    if self._tradeQueuePopup then
        self._tradeQueuePopup:SetBackdropColor(unpack(theme.frameBgColor))
        self._tradeQueuePopup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
        if self._tradeQueuePopup._div then
            self._tradeQueuePopup._div:SetColorTexture(unpack(theme.dividerColor))
        end
    end

    -- Pool rows: selected / highlight textures
    for _, row in ipairs(self._itemRowPool) do
        if row.selected then
            row.selected:SetColorTexture(unpack(theme.selectedColor))
        end
        if row.highlight then
            row.highlight:SetColorTexture(unpack(theme.highlightColor))
        end
    end
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

    -- Manual Roll button: only usable while session is active and not mid-roll
    if f.manualRollBtn then
        if session:IsActive() and session.state == session.STATE_ACTIVE then
            f.manualRollBtn:Enable()
        else
            f.manualRollBtn:Disable()
        end
    end

    -- Stop Roll button: only usable while a roll is in progress
    if f.stopRollBtn then
        if ns.IsLeader() and (session.state == session.STATE_ROLLING
                or session.state == session.STATE_RESOLVING) then
            f.stopRollBtn:Enable()
        else
            f.stopRollBtn:Disable()
        end
    end

    -- Loot Master button: available while a session is active
    if f.lootMasterBtn then
        if session:IsActive() then
            f.lootMasterBtn:Enable()
        else
            f.lootMasterBtn:Disable()
        end
    end

    -- Loot Master name label: show current loot master above the button
    if f.lootMasterLabel then
        local lm = session:IsActive() and (session.sessionLootMaster or "") or ""
        if lm ~= "" then
            f.lootMasterLabel:SetText(StripRealm(lm))
            f.lootMasterLabel:SetTextColor(1, 0.82, 0) -- gold
        else
            f.lootMasterLabel:SetText("")
        end
    end

    -- Trade Queue button: available when queue has entries
    if f.tradeQueueBtn then
        local tq = session:GetTradeQueue()
        local queueCount = tq and #tq or 0
        if queueCount > 0 then
            f.tradeQueueBtn:SetText("Trade Queue (" .. queueCount .. ")")
            f.tradeQueueBtn:Enable()
        else
            f.tradeQueueBtn:SetText("Trade Queue")
            f.tradeQueueBtn:Disable()
        end
    end

    -- Check Party button: always available for the leader
    if f.checkPartyBtn then
        if ns.IsLeader() then
            f.checkPartyBtn:Enable()
        else
            f.checkPartyBtn:Disable()
        end
    end

    -- Close the manual roll popup if a roll is in progress or session ended
    if self._manualRollPopup and self._manualRollPopup:IsShown() then
        if not session:IsActive() or session.state ~= session.STATE_ACTIVE then
            self._manualRollPopup:Hide()
        end
    end

    -- Roll timer bar
    if session.state == session.STATE_ROLLING and session._rollTimerStart then
        self:StartTimer()
    else
        self:StopTimer()
    end

    -- Refresh trade queue popup if open
    if self._tradeQueuePopup and self._tradeQueuePopup:IsShown() then
        self:_RefreshTradeQueuePopup()
    end

    -- Refresh both panels
    self:_RefreshLeftPanel()
    self:_RefreshRightPanel()
end

------------------------------------------------------------------------
-- LEFT PANEL: Build the item list
------------------------------------------------------------------------
function LeaderFrame:_RefreshLeftPanel()
    local sc = self._leftScrollChild
    if not sc then return end
    local session = ns.Session
    if not session then return end

    -- Recycle existing item rows
    self:_RecycleItemRows()

    -- Clear non-frame regions (font strings used as section headers)
    for _, region in ipairs({ sc:GetRegions() }) do
        region:Hide()
    end

    local yOffset = 0
    local firstItemKey = nil

    -- === CURRENT BOSS ===
    if session:IsActive() and #session.currentItems > 0 then
        yOffset = self:_DrawSectionHeader(sc, yOffset, "Current Loot – " .. (session.currentBoss or "Unknown"))
        yOffset = yOffset - 2

        for idx, item in ipairs(session.currentItems) do
            local key = self:_MakeItemKey("current", nil, idx)
            if not firstItemKey then firstItemKey = key end
            yOffset = self:_DrawItemListRow(sc, yOffset, key, item,
                session.results and session.results[idx],
                session.state == session.STATE_ROLLING)
        end
    end

    -- === HISTORICAL BOSSES (newest first) ===
    local order = session.bossHistoryOrder or {}
    for i = #order, 1, -1 do
        local bossKey = order[i]
        local data = session.bossHistory[bossKey]
        if data and data.items then
            yOffset = yOffset - 8
            yOffset = self:_DrawSectionHeader(sc, yOffset, bossKey)
            yOffset = yOffset - 2

            for idx, item in ipairs(data.items) do
                local key = self:_MakeItemKey("history", bossKey, idx)
                if not firstItemKey then firstItemKey = key end
                yOffset = self:_DrawItemListRow(sc, yOffset, key, item,
                    data.results and data.results[idx], false)
            end
        end
    end

    sc:SetHeight(math.abs(yOffset) + 20)

    -- Auto-select first item if no selection
    if not self._selectedItem and firstItemKey then
        self._selectedItem = firstItemKey
    end
    -- Validate current selection still exists; if not, reset
    if self._selectedItem and not self:_ItemKeyExists(self._selectedItem) then
        self._selectedItem = firstItemKey
    end

    -- Update highlight on selected row
    self:_UpdateItemHighlights()
end

------------------------------------------------------------------------
-- RIGHT PANEL: Show player rolls for the selected item
------------------------------------------------------------------------
function LeaderFrame:_RefreshRightPanel()
    local sc = self._rightScrollChild
    if not sc then return end
    local session = ns.Session
    if not session then return end

    -- Recycle player rows
    self:_RecyclePlayerRows()

    -- Clear regions (font strings, textures)
    for _, region in ipairs({ sc:GetRegions() }) do
        region:Hide()
    end

    -- Create the persistent header hitbox (for item tooltip) on first use
    if not self._rightItemHit then
        local hit = CreateFrame("Frame", nil, sc)
        hit:EnableMouse(true)
        hit:SetScript("OnEnter", function(f)
            if f._link then
                GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
                if f._link:find("|H") then
                    GameTooltip:SetHyperlink(f._link)
                else
                    GameTooltip:SetText(f._link)
                end
                GameTooltip:Show()
            end
        end)
        hit:SetScript("OnLeave", GameTooltip_Hide)
        self._rightItemHit = hit
    end
    self._rightItemHit:Hide()

    local sel = self._selectedItem
    if not sel then
        local noSel = sc:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        noSel:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, -4)
        noSel:SetText("Select an item on the left.")
        noSel:Show()
        sc:SetHeight(30)
        return
    end

    -- Resolve selected item data
    local item, result, responses, isCurrent = self:_ResolveSelectedItem()

    if not item then
        local missing = sc:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        missing:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, -4)
        missing:SetText("Item no longer available.")
        missing:Show()
        sc:SetHeight(30)
        return
    end

    local theme = ns.Theme:GetCurrent()
    local yOffset = 0

    -- === Item header ===
    local icon = sc:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, yOffset - 2)
    icon:SetTexture((item and item.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:Show()

    local nameText = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameText:SetPoint("LEFT", icon, "RIGHT", 8, 6)
    local hqr, hqg, hqb = GetItemQualityColor((item and item.quality) or 1)
    nameText:SetTextColor(hqr, hqg, hqb)
    nameText:SetText((item and item.name) or "Unknown")
    nameText:Show()

    -- Status
    local statusStr
    if result and result.winner then
        statusStr = "|cff00ff00Won by: " .. result.winner .. " (" .. result.choice .. " " .. result.roll .. ")|r"
    elseif isCurrent and session.state == session.STATE_ROLLING then
        local count = 0
        if responses then
            for _ in pairs(responses) do count = count + 1 end
        end
        statusStr = "|cffffff00Rolling... (" .. count .. " responded)|r"
    else
        statusStr = "|cff888888Pending|r"
    end

    local statusLabel = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusLabel:SetPoint("LEFT", icon, "RIGHT", 8, -8)
    statusLabel:SetText(statusStr)
    statusLabel:Show()

    -- Position tooltip hitbox over the item header (icon + name)
    local rightPanelWidth = sc:GetWidth()
    self._rightItemHit:ClearAllPoints()
    self._rightItemHit:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -2)
    self._rightItemHit:SetSize(rightPanelWidth > 0 and rightPanelWidth or 200, 40)
    self._rightItemHit._link = item and item.link
    self._rightItemHit:Show()

    yOffset = yOffset - 42

    -- === Column headers ===
    local colNameX  = 4
    local colTypeX  = rightPanelWidth * 0.42
    local colRollX  = rightPanelWidth * 0.62
    local colCountX = rightPanelWidth * 0.78
    local hex = theme.columnHeaderHex

    local hdrName = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrName:SetPoint("TOPLEFT", sc, "TOPLEFT", colNameX, yOffset)
    hdrName:SetText("|cff" .. hex .. "Player|r")
    hdrName:Show()

    local hdrType = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrType:SetPoint("TOPLEFT", sc, "TOPLEFT", colTypeX, yOffset)
    hdrType:SetText("|cff" .. hex .. "Roll Type|r")
    hdrType:Show()

    local hdrRoll = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrRoll:SetPoint("TOPLEFT", sc, "TOPLEFT", colRollX, yOffset)
    hdrRoll:SetText("|cff" .. hex .. "Roll|r")
    hdrRoll:Show()

    local hdrCount = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrCount:SetPoint("TOPLEFT", sc, "TOPLEFT", colCountX, yOffset)
    hdrCount:SetText("|cff" .. hex .. "Gear Count|r")
    hdrCount:Show()

    yOffset = yOffset - 16

    -- Separator line
    local sep = sc:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(theme.dividerColor))
    sep:SetSize(rightPanelWidth - 8, 1)
    sep:SetPoint("TOPLEFT", sc, "TOPLEFT", colNameX, yOffset)
    sep:Show()
    yOffset = yOffset - 4

    -- === Build sorted player list ===
    local sortedPlayers = self:_BuildSortedPlayerList(responses or {}, result, session)

    -- === Draw player rows ===
    for _, entry in ipairs(sortedPlayers) do
        yOffset = self:_DrawPlayerRow(sc, yOffset, entry, colNameX, colTypeX, colRollX, colCountX)
    end

    sc:SetHeight(math.abs(yOffset) + 20)

    -- === Action bar (fixed, below the scroll frame) ===
    local f = self._frame
    if f then
        if isCurrent and result and result.winner and sel.source == "current" then
            local itemIdx = sel.itemIdx
            f.announceBtn:SetScript("OnClick", function() session:AnnounceWinner(itemIdx) end)
            f.announceBtn:Show()
            f.rerollBtn:SetScript("OnClick", function()
                session.responses[itemIdx] = {}
                session.results[itemIdx] = nil
                session:StartAllRolls()
            end)
            f.rerollBtn:Show()
            f.reassignBtn:SetScript("OnClick", function()
                LeaderFrame:ShowReassignPopup(itemIdx, item)
            end)
            f.reassignBtn:Show()
        else
            f.announceBtn:Hide()
            f.rerollBtn:Hide()
            f.reassignBtn:Hide()
        end
    end
end

------------------------------------------------------------------------
-- Build sorted player list for right panel
------------------------------------------------------------------------
function LeaderFrame:_BuildSortedPlayerList(responses, result, session)
    local members = GetGroupMembers()
    local playerMap = {} -- dedup

    -- Build a lookup of roll values from rankedCandidates (populated after resolution)
    local rollLookup = {}
    if result and result.rankedCandidates then
        for _, c in ipairs(result.rankedCandidates) do
            rollLookup[c.player] = c.roll
        end
    end

    -- Start with all group members as "Waiting"
    for _, name in ipairs(members) do
        if not playerMap[name] then
            playerMap[name] = {
                player   = name,
                choice   = nil,
                roll     = nil,
                count    = ns.LootCount:GetCount(name),
                priority = 999, -- high number = sorts last (waiting)
                status   = "waiting",
            }
        end
    end

    -- Overlay actual responses
    for player, data in pairs(responses) do
        local choiceName = data.choice
        local opt = session:_FindRollOption(choiceName)
        local priority = 998 -- default for unknown choices
        if choiceName == "Pass" then
            priority = 900
        elseif opt then
            priority = opt.priority or 500
        end

        -- Roll comes from rankedCandidates (post-resolution) or from response data
        local roll = rollLookup[player] or data.roll or nil

        playerMap[player] = {
            player   = player,
            choice   = choiceName,
            roll     = roll,
            count    = data.countAtRoll or ns.LootCount:GetCount(player),
            priority = priority,
            status   = "responded",
            option   = opt,
        }

        -- In case the player wasn't in our group member list (e.g. joined late)
    end

    -- Convert to sorted array
    local sorted = {}
    for _, entry in pairs(playerMap) do
        tinsert(sorted, entry)
    end

    table.sort(sorted, function(a, b)
        -- 1) Priority tier ascending (Need=1 < Greed=2 < Pass=900 < Waiting=999)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        -- 2) Within same tier:
        --    Pass group or Waiting group: alphabetical by name
        if a.priority >= 900 then
            return (a.player or "") < (b.player or "")
        end
        -- 3) Active roll tiers: gear count ascending
        if a.count ~= b.count then
            return a.count < b.count
        end
        -- 4) Same count: roll descending
        local ra = a.roll or 0
        local rb = b.roll or 0
        if ra ~= rb then
            return ra > rb
        end
        -- 5) Tiebreaker: alphabetical
        return (a.player or "") < (b.player or "")
    end)

    return sorted
end

------------------------------------------------------------------------
-- Draw a single player row on the right panel
------------------------------------------------------------------------
function LeaderFrame:_DrawPlayerRow(parent, yOffset, entry, colNameX, colTypeX, colRollX, colCountX)
    local row = self:_AcquirePlayerRow(parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetSize(parent:GetWidth(), PLAYER_ROW_HEIGHT)
    row:Show()

    -- Player name + [Main] if alt-linked
    local displayName = StripRealm(entry.player)
    local mainIdentity = ns.PlayerLinks:ResolveIdentity(entry.player)
    if mainIdentity and mainIdentity ~= entry.player then
        displayName = displayName .. " [" .. StripRealm(mainIdentity) .. "]"
    end

    row.nameText:SetPoint("LEFT", row, "LEFT", colNameX, 0)
    row.nameText:SetText(displayName)
    row.nameText:SetTextColor(1, 1, 1)
    row.nameText:Show()

    -- Roll type
    if entry.status == "waiting" then
        row.typeText:SetPoint("LEFT", row, "LEFT", colTypeX, 0)
        row.typeText:SetText("|cff888888Waiting|r")
        row.typeText:Show()
        row.rollText:SetPoint("LEFT", row, "LEFT", colRollX, 0)
        row.rollText:SetText("-")
        row.rollText:SetTextColor(0.5, 0.5, 0.5)
        row.rollText:Show()
        row.countText:SetPoint("LEFT", row, "LEFT", colCountX, 0)
        row.countText:SetText(tostring(entry.count))
        row.countText:SetTextColor(0.5, 0.5, 0.5)
        row.countText:Show()
    elseif entry.choice == "Pass" then
        row.typeText:SetPoint("LEFT", row, "LEFT", colTypeX, 0)
        row.typeText:SetText("|cff999999Pass|r")
        row.typeText:Show()
        row.rollText:SetPoint("LEFT", row, "LEFT", colRollX, 0)
        row.rollText:SetText("-")
        row.rollText:SetTextColor(0.6, 0.6, 0.6)
        row.rollText:Show()
        row.countText:SetPoint("LEFT", row, "LEFT", colCountX, 0)
        row.countText:SetText(tostring(entry.count))
        row.countText:SetTextColor(0.6, 0.6, 0.6)
        row.countText:Show()
    else
        -- Active roll choice (Need, Greed, etc.)
        local r, g, b = 1, 1, 1
        if entry.option then
            r = entry.option.colorR or 1
            g = entry.option.colorG or 1
            b = entry.option.colorB or 1
        end
        row.typeText:SetPoint("LEFT", row, "LEFT", colTypeX, 0)
        row.typeText:SetText(entry.choice or "?")
        row.typeText:SetTextColor(r, g, b)
        row.typeText:Show()
        row.rollText:SetPoint("LEFT", row, "LEFT", colRollX, 0)
        row.rollText:SetText(tostring(entry.roll or "-"))
        row.rollText:SetTextColor(1, 1, 1)
        row.rollText:Show()
        row.countText:SetPoint("LEFT", row, "LEFT", colCountX, 0)
        row.countText:SetText(tostring(entry.count))
        row.countText:SetTextColor(1, 1, 1)
        row.countText:Show()
    end

    return yOffset - PLAYER_ROW_HEIGHT
end

------------------------------------------------------------------------
-- Draw a section header (left panel)
------------------------------------------------------------------------
function LeaderFrame:_DrawSectionHeader(parent, yOffset, text)
    local theme = ns.Theme:GetCurrent()
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    header:SetText("|cff" .. theme.sectionHeaderHex .. text .. "|r")
    header:Show()
    return yOffset - 16
end

------------------------------------------------------------------------
-- Draw an item row in the left panel (compact, clickable)
------------------------------------------------------------------------
function LeaderFrame:_DrawItemListRow(parent, yOffset, key, item, result, isRolling)
    local row = self:_AcquireItemRow(parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetSize(LEFT_PANEL_WIDTH - 20, ITEM_ROW_HEIGHT)
    row._itemKey  = key
    row._itemLink = item.link or item.name
    row:Show()

    -- Icon
    row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:Show()

    -- Name (quality color)
    local qr, qg, qb = GetItemQualityColor(item.quality or 1)
    row.nameText:SetTextColor(qr, qg, qb)
    row.nameText:SetText(item.name or "Unknown")
    row.nameText:Show()

    -- Compact status
    local statusStr
    if result and result.winner then
        statusStr = "|cff00ff00" .. StripRealm(result.winner) .. "|r"
    elseif isRolling then
        statusStr = "|cffffff00Rolling|r"
    else
        statusStr = "|cff888888Pending|r"
    end
    row.statusText:SetText(statusStr)
    row.statusText:Show()

    return yOffset - ITEM_ROW_HEIGHT
end

------------------------------------------------------------------------
-- Item key helpers
------------------------------------------------------------------------
function LeaderFrame:_MakeItemKey(source, bossKey, itemIdx)
    return { source = source, bossKey = bossKey, itemIdx = itemIdx }
end

function LeaderFrame:_ItemKeysEqual(a, b)
    if not a or not b then return false end
    return a.source == b.source and a.bossKey == b.bossKey and a.itemIdx == b.itemIdx
end

function LeaderFrame:_ItemKeyExists(key)
    local session = ns.Session
    if not session then return false end

    if key.source == "current" then
        return session.currentItems and session.currentItems[key.itemIdx] ~= nil
    elseif key.source == "history" then
        local data = session.bossHistory and session.bossHistory[key.bossKey]
        return data and data.items and data.items[key.itemIdx] ~= nil
    end
    return false
end

------------------------------------------------------------------------
-- Resolve the selected item into its data tables
------------------------------------------------------------------------
function LeaderFrame:_ResolveSelectedItem()
    local sel = self._selectedItem
    if not sel then return nil end
    local session = ns.Session
    if not session then return nil end

    if sel.source == "current" then
        local item = session.currentItems and session.currentItems[sel.itemIdx]
        local result = session.results and session.results[sel.itemIdx]
        local responses = session.responses and session.responses[sel.itemIdx]
        return item, result, responses, true, nil
    elseif sel.source == "history" then
        local data = session.bossHistory and session.bossHistory[sel.bossKey]
        if data then
            local item = data.items and data.items[sel.itemIdx]
            local result = data.results and data.results[sel.itemIdx]
            local responses = data.responses and data.responses[sel.itemIdx]
            return item, result, responses, false, nil
        end
    end

    return nil
end

------------------------------------------------------------------------
-- Frame pooling for item rows (left panel)
------------------------------------------------------------------------
function LeaderFrame:_AcquireItemRow(parent)
    for _, row in ipairs(self._itemRowPool) do
        if not row._inUse then
            row._inUse = true
            row._itemKey = nil
            row._tradeEntry = nil
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end

    local theme = ns.Theme:GetCurrent()

    -- Create new row frame
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ITEM_ROW_HEIGHT)
    row:EnableMouse(true)

    -- Highlight texture
    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints()
    highlight:SetColorTexture(unpack(theme.highlightColor))
    highlight:Hide()
    row.highlight = highlight

    -- Selected texture
    local selected = row:CreateTexture(nil, "BACKGROUND")
    selected:SetAllPoints()
    selected:SetColorTexture(unpack(theme.selectedColor))
    selected:Hide()
    row.selected = selected

    -- Icon
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon = icon

    -- Item name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", icon, "RIGHT", 4, 4)
    nameText:SetWidth(LEFT_PANEL_WIDTH - 60)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.nameText = nameText

    -- Status text (below name)
    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("LEFT", icon, "RIGHT", 4, -7)
    statusText:SetJustifyH("LEFT")
    row.statusText = statusText

    -- Click handler
    row:SetScript("OnClick", function(r)
        LeaderFrame._selectedItem = r._itemKey
        LeaderFrame:_UpdateItemHighlights()
        LeaderFrame:_RefreshRightPanel()
    end)
    row:SetScript("OnEnter", function(r)
        if not LeaderFrame:_ItemKeysEqual(LeaderFrame._selectedItem, r._itemKey) then
            r.highlight:Show()
        end
        if r._itemLink then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            if r._itemLink:find("|H") then
                GameTooltip:SetHyperlink(r._itemLink)
            else
                GameTooltip:SetText(r._itemLink)
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(r)
        r.highlight:Hide()
        GameTooltip:Hide()
    end)

    row._inUse = true
    tinsert(self._itemRowPool, row)
    return row
end

function LeaderFrame:_RecycleItemRows()
    for _, row in ipairs(self._itemRowPool) do
        row._inUse = false
        row._itemKey = nil
        row._tradeEntry = nil
        row:Hide()
    end
end

function LeaderFrame:_UpdateItemHighlights()
    for _, row in ipairs(self._itemRowPool) do
        if row._inUse and row:IsShown() then
            if self:_ItemKeysEqual(self._selectedItem, row._itemKey) then
                row.selected:Show()
            else
                row.selected:Hide()
            end
        end
    end
end

------------------------------------------------------------------------
-- Frame pooling for player rows (right panel)
------------------------------------------------------------------------
function LeaderFrame:_AcquirePlayerRow(parent)
    for _, row in ipairs(self._playerRowPool) do
        if not row._inUse then
            row._inUse = true
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end

    -- Create new row frame
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(PLAYER_ROW_HEIGHT)

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText = nameText

    local typeText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.typeText = typeText

    local rollText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.rollText = rollText

    local countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.countText = countText

    row._inUse = true
    tinsert(self._playerRowPool, row)
    return row
end

function LeaderFrame:_RecyclePlayerRows()
    for _, row in ipairs(self._playerRowPool) do
        row._inUse = false
        row.nameText:Hide()
        row.typeText:Hide()
        row.rollText:Hide()
        row.countText:Hide()
        row:Hide()
    end
end

------------------------------------------------------------------------
-- Loot Master Popup
------------------------------------------------------------------------

-- Returns all group members who qualify as "leaders" (raid leader + officers).
-- In a party only the party leader qualifies; solo returns the player.
local function GetGroupLeaders()
    local leaders = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        tinsert(leaders, ns.GetPlayerNameRealm())
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name, rank = GetRaidRosterInfo(i)
            -- rank: 0 = member, 1 = officer, 2 = raid leader
            if name and rank and rank >= 1 then
                local full = name
                if not full:find("-") then
                    full = full .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(leaders, full)
            end
        end
        if #leaders == 0 then
            tinsert(leaders, ns.GetPlayerNameRealm())
        end
    else
        tinsert(leaders, ns.GetPlayerNameRealm())
    end
    return leaders
end

function LeaderFrame:ShowLootMasterPopup()
    if not ns.IsLeader() then return end

    if not self._lootMasterPopup then
        self:_CreateLootMasterPopup()
    end

    self:_RefreshLootMasterPopup()
    self._lootMasterPopup:Show()
    ns.RaiseFrame(self._lootMasterPopup)
end

function LeaderFrame:_CreateLootMasterPopup()
    local theme = ns.Theme:GetCurrent()

    local popup = CreateFrame("Frame", "OLLLootMasterPopup", UIParent, "BackdropTemplate")
    popup:SetSize(320, 280)
    popup:SetPoint("CENTER", UIParent, "CENTER", -200, 0)
    popup:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    popup:SetBackdropColor(unpack(theme.frameBgColor))
    popup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetFrameStrata("DIALOG")
    popup:SetClampedToScreen(true)
    popup:SetScript("OnMouseDown", function(f) ns.RaiseFrame(f) end)

    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Assign Loot Master")

    local currentLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    currentLabel:SetPoint("TOPLEFT", 14, -36)
    popup.currentLabel = currentLabel

    local div = popup:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(unpack(theme.dividerColor))
    div:SetPoint("TOPLEFT",  14, -56)
    div:SetPoint("TOPRIGHT", -14, -56)
    div:SetHeight(1)
    popup.div = div

    local scroll = CreateFrame("ScrollFrame", nil, popup, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     14, -62)
    scroll:SetPoint("BOTTOMRIGHT", -32, 52)

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(270, 1)
    scroll:SetScrollChild(scrollChild)
    popup.scrollChild = scrollChild

    local sep = popup:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(theme.actionSepColor))
    sep:SetPoint("BOTTOMLEFT",  0, 48)
    sep:SetPoint("BOTTOMRIGHT", 0, 48)
    sep:SetHeight(1)
    popup.sep = sep

    local assignBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    assignBtn:SetSize(110, 24)
    assignBtn:SetPoint("BOTTOMLEFT", 14, 14)
    assignBtn:SetText("Assign")
    assignBtn:Disable()
    assignBtn:SetScript("OnClick", function()
        local selected = popup._selectedPlayer
        if selected then
            ns.Session:UpdateSessionLootMaster(selected)
            popup:Hide()
        end
    end)
    popup.assignBtn = assignBtn

    local cancelBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 24)
    cancelBtn:SetPoint("LEFT", assignBtn, "RIGHT", 8, 0)
    cancelBtn:SetText("Close")
    cancelBtn:SetScript("OnClick", function() popup:Hide() end)

    popup._selectedPlayer = nil
    popup._rows = {}
    popup:Hide()
    self._lootMasterPopup = popup
end

function LeaderFrame:_RefreshLootMasterPopup()
    local popup = self._lootMasterPopup
    if not popup then return end

    -- Update current loot master label
    local currentLM = (ns.Session and ns.Session.sessionLootMaster) or ""
    if currentLM ~= "" then
        popup.currentLabel:SetText("Current: " .. StripRealm(currentLM))
    else
        popup.currentLabel:SetText("Current: None")
    end

    -- Return existing rows to the pool (hide + mark unused)
    for _, row in ipairs(popup._rows) do
        row._inUse = false
        row:Hide()
    end

    -- Reset selection
    popup._selectedPlayer = nil
    popup.assignBtn:Disable()

    local leaders = GetGroupLeaders()

    -- If current loot master is not in the leader list (e.g. was manually assigned
    -- to a non-officer), prepend them so they can still be re-selected.
    if currentLM ~= "" then
        local found = false
        for _, name in ipairs(leaders) do
            if ns.NamesMatch(name, currentLM) then
                found = true
                break
            end
        end
        if not found then
            tinsert(leaders, 1, currentLM)
        end
    end

    local scrollChild = popup.scrollChild
    local rowPool     = popup._rows
    local poolIdx     = 0

    local yPos = 0
    for _, name in ipairs(leaders) do
        -- Acquire or create a row frame
        poolIdx = poolIdx + 1
        local row = rowPool[poolIdx]
        if not row then
            row = CreateFrame("Button", nil, scrollChild)
            row:SetHeight(26)

            local hl = row:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            hl:SetColorTexture(0, 0.55, 1, 0.25)
            hl:Hide()
            row.hl = hl

            local radioText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            radioText:SetPoint("LEFT", 4, 0)
            row.radioText = radioText

            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameText:SetPoint("LEFT", 32, 0)
            nameText:SetPoint("RIGHT", -4, 0)
            nameText:SetJustifyH("LEFT")
            row.nameText = nameText

            rowPool[poolIdx] = row
        end

        -- Configure the row for this leader
        local isCurrentLM = ns.NamesMatch(name, currentLM)
        row.nameText:SetText(
            StripRealm(name) .. (isCurrentLM and " |cff00ff00(Current)|r" or "")
        )
        row.radioText:SetText("[ ]")
        row.hl:Hide()
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  scrollChild, "TOPLEFT",  0, yPos)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, yPos)

        local captureName = name
        row:SetScript("OnClick", function()
            -- Deselect all rows
            for _, r in ipairs(rowPool) do
                if r._inUse then
                    r.hl:Hide()
                    r.radioText:SetText("[ ]")
                end
            end
            -- Select this row
            row.hl:Show()
            row.radioText:SetText("[*]")
            popup._selectedPlayer = captureName
            popup.assignBtn:Enable()
        end)

        row._inUse = true
        row:Show()
        yPos = yPos - 26
    end

    -- Resize scroll child to fit content
    scrollChild:SetHeight(math.max(1, -yPos))

    if #leaders == 0 then
        -- Fallback message if somehow the list is empty
        local msg = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        msg:SetPoint("TOPLEFT", 4, 0)
        msg:SetText("No leaders found in the group.")
        msg:Show()
        scrollChild:SetHeight(20)
    end
end

------------------------------------------------------------------------
-- Trade Queue Popup
------------------------------------------------------------------------
function LeaderFrame:ShowTradeQueuePopup()
    if not self._tradeQueuePopup then
        self:_CreateTradeQueuePopup()
    end
    self:_RefreshTradeQueuePopup()
    self._tradeQueuePopup:Show()
    ns.RaiseFrame(self._tradeQueuePopup)
end

function LeaderFrame:_RefreshTradeQueuePopupIfShown()
    if self._tradeQueuePopup and self._tradeQueuePopup:IsShown() then
        self:_RefreshTradeQueuePopup()
    end
end

function LeaderFrame:_CreateTradeQueuePopup()
    local theme = ns.Theme:GetCurrent()

    local popup = CreateFrame("Frame", "OLLTradeQueuePopup", UIParent, "BackdropTemplate")
    popup:SetSize(400, 320)
    popup:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    popup:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    popup:SetBackdropColor(unpack(theme.frameBgColor))
    popup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetFrameStrata("DIALOG")
    popup:SetClampedToScreen(true)
    popup:SetScript("OnMouseDown", function(f) ns.RaiseFrame(f) end)

    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Trade Queue")

    local div = popup:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(unpack(theme.dividerColor))
    div:SetPoint("TOPLEFT",  14, -30)
    div:SetPoint("TOPRIGHT", -14, -30)
    div:SetHeight(1)
    popup._div = div

    local scroll = CreateFrame("ScrollFrame", nil, popup, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     14, -36)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(360, 1)
    scroll:SetScrollChild(scrollChild)
    popup._scrollChild = scrollChild

    popup._rows = {}
    popup:Hide()
    self._tradeQueuePopup = popup
end

function LeaderFrame:_RefreshTradeQueuePopup()
    local popup = self._tradeQueuePopup
    if not popup then return end

    local scrollChild = popup._scrollChild

    -- Hide all pooled rows and clear one-off font strings
    for _, row in ipairs(popup._rows) do
        row:Hide()
    end
    for _, region in ipairs({ scrollChild:GetRegions() }) do
        region:Hide()
    end

    local session = ns.Session
    local tradeQueue = session and session:GetTradeQueue()

    if not tradeQueue or #tradeQueue == 0 then
        if not popup._emptyMsg then
            local msg = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            msg:SetPoint("TOPLEFT", 4, -8)
            msg:SetText("No items in the trade queue.")
            popup._emptyMsg = msg
        end
        popup._emptyMsg:Show()
        scrollChild:SetHeight(30)
        return
    end

    local ROW_HEIGHT = 44
    local yPos       = 0
    local poolIdx    = 0

    for _, entry in ipairs(tradeQueue) do
        poolIdx = poolIdx + 1
        local row = popup._rows[poolIdx]

        if not row then
            row = CreateFrame("Frame", nil, scrollChild)
            row:SetHeight(ROW_HEIGHT)
            row:EnableMouse(true)

            -- Bottom separator line
            local sep = row:CreateTexture(nil, "ARTWORK")
            sep:SetColorTexture(0.25, 0.25, 0.25, 0.6)
            sep:SetPoint("BOTTOMLEFT")
            sep:SetPoint("BOTTOMRIGHT")
            sep:SetHeight(1)

            -- Item icon
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(30, 30)
            icon:SetPoint("LEFT", 4, 0)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.icon = icon

            -- Item name
            local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameFS:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -4)
            nameFS:SetPoint("RIGHT",   row,  "RIGHT",    -104, 0)
            nameFS:SetJustifyH("LEFT")
            nameFS:SetWordWrap(false)
            row.nameFS = nameFS

            -- Recipient name
            local winnerFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            winnerFS:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 4)
            winnerFS:SetPoint("RIGHT",      row,  "RIGHT",       -104, 0)
            winnerFS:SetJustifyH("LEFT")
            winnerFS:SetWordWrap(false)
            row.winnerFS = winnerFS

            -- "Open Trade" button
            local tradeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            tradeBtn:SetSize(90, 22)
            tradeBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            tradeBtn:SetText("Open Trade")
            row.tradeBtn = tradeBtn

            -- "Done" label (replaces button when trade completes)
            local doneFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            doneFS:SetPoint("RIGHT", row, "RIGHT", -10, 0)
            doneFS:SetText("|cff00ff00Done|r")
            doneFS:Hide()
            row.doneFS = doneFS

            popup._rows[poolIdx] = row
        end

        -- Position
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",  scrollChild, "TOPLEFT",  0, yPos)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, yPos)

        -- Icon
        row.icon:SetTexture(entry.itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")

        -- Item name (quality color)
        local qr, qg, qb = GetItemQualityColor(entry.itemQuality or 1)
        row.nameFS:SetTextColor(qr, qg, qb)
        row.nameFS:SetText(entry.itemName or "Unknown")

        -- Recipient
        row.winnerFS:SetText("|cffffff00→ " .. StripRealm(entry.winner or "?") .. "|r")

        -- Tooltip on hover
        local captureEntry = entry
        row:SetScript("OnEnter", function(r)
            if captureEntry.itemLink and captureEntry.itemLink:find("|H") then
                GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(captureEntry.itemLink)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)

        -- Show button or Done label
        if entry.awarded then
            row.tradeBtn:Hide()
            row.doneFS:Show()
        else
            row.doneFS:Hide()
            row.tradeBtn:SetScript("OnClick", function()
                local shortName = StripRealm(captureEntry.winner or "")
                if shortName == "" then return end
                if UnitExists(shortName) then
                    InitiateTrade(shortName)
                    return
                end
                for i = 1, GetNumGroupMembers() do
                    local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
                    local unitName = GetUnitName(unit, true)
                    if unitName and ns.NamesMatch(unitName, captureEntry.winner) then
                        InitiateTrade(unit)
                        return
                    end
                end
                ns.addon:Print("Could not find " .. captureEntry.winner .. " to trade. Are they nearby?")
            end)
            row.tradeBtn:Show()
        end

        row:Show()
        yPos = yPos - ROW_HEIGHT
    end

    scrollChild:SetHeight(math.max(1, -yPos))
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

    -- Disenchanter setting
    local disenchanter = ns.db.profile.disenchanter or ""
    local hasDisenchanter = disenchanter ~= ""

    -- Calculate popup height based on candidates
    local candidateRows = math.min(#nextCandidates, 8) -- max 8 visible
    local popupHeight = 120 + candidateRows * 26 + (candidateRows > 0 and 24 or 0)
                      + (hasDisenchanter and 58 or 0) -- label + button + separator

    local theme = ns.Theme:GetCurrent()

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
    popup:SetBackdropColor(unpack(theme.frameBgColor))
    popup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
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
        sectionLabel:SetText("|cff" .. theme.columnHeaderHex .. "Reassign to next-place winner:|r")
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
    sep:SetColorTexture(unpack(theme.dividerColor))
    sep:SetSize(328, 1)
    sep:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
    yPos = yPos - 8

    -- Disenchanter button
    if hasDisenchanter then
        local deLabel = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        deLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
        deLabel:SetText("|cff" .. theme.columnHeaderHex .. "Disenchant (no count):|r")
        yPos = yPos - 18

        local deBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
        deBtn:SetSize(328, 22)
        deBtn:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
        deBtn:SetText(disenchanter)
        deBtn:GetFontString():SetJustifyH("LEFT")
        deBtn:SetScript("OnClick", function()
            ns.Session:ReassignItem(itemIdx, disenchanter, true)
            popup:Hide()
        end)
        yPos = yPos - 30

        local sep2 = popup:CreateTexture(nil, "ARTWORK")
        sep2:SetColorTexture(unpack(theme.dividerColor))
        sep2:SetSize(328, 1)
        sep2:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, yPos)
        yPos = yPos - 8
    end

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
-- Manual Roll Popup
------------------------------------------------------------------------
function LeaderFrame:ShowManualRollPopup()
    if not ns.IsLeader() then return end
    if not ns.Session or not ns.Session:IsActive() then
        ns.addon:Print("Start a session first.")
        return
    end
    if ns.Session.state ~= ns.Session.STATE_ACTIVE then
        ns.addon:Print("A roll is already in progress.")
        return
    end

    if not self._manualRollPopup then
        self:_CreateManualRollPopup()
    end

    self:_RefreshManualRollList()
    self._manualRollPopup:Show()
    ns.RaiseFrame(self._manualRollPopup)
end

function LeaderFrame:_CreateManualRollPopup()
    local theme   = ns.Theme:GetCurrent()
    local POPUP_W = 420
    local POPUP_H = 380

    local popup = CreateFrame("Frame", "OLLManualRollPopup", UIParent, "BackdropTemplate")
    popup:SetSize(POPUP_W, POPUP_H)
    popup:SetPoint("CENTER", UIParent, "CENTER", -50, 50)
    popup:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    popup:SetBackdropColor(unpack(theme.frameBgColor))
    popup:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
    popup:SetClampedToScreen(true)
    popup:SetScript("OnMouseDown", function(f) ns.RaiseFrame(f) end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    -- Title
    local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", popup, "TOP", 0, -12)
    title:SetText("Manual Roll")

    -- Instruction text
    local instrText = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instrText:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, -36)
    instrText:SetWidth(POPUP_W - 32)
    instrText:SetText("Shift+click items from your bags to add them. To paste a link manually, click the box below.")
    instrText:SetJustifyH("LEFT")
    instrText:SetWordWrap(true)

    -- Hook HandleModifiedItemClick so shift+clicking a bag item while this
    -- popup is open captures the link.  hooksecurefunc fires at the function-
    -- object level, so it works even when Blizzard calls it via an upvalue.
    if not LeaderFrame._manualLinkHookInstalled then
        LeaderFrame._manualLinkHookInstalled = true
        hooksecurefunc("HandleModifiedItemClick", function(link)
            if not (LeaderFrame._manualRollPopup and LeaderFrame._manualRollPopup:IsShown()) then return end
            if not link then return end
            local itemLink = link:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
                          or link:match("(|Hitem:.-|h%[.-%]|h)")
            if not itemLink then return end
            local name, _, quality, _, _, _, _, _, _, iconTexture = GetItemInfo(itemLink)
            if not name then return end
            tinsert(LeaderFrame._manualRollItems, {
                name    = name,
                link    = itemLink,
                quality = quality or 0,
                icon    = iconTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
            })
            LeaderFrame:_RefreshManualRollList()
        end)
    end

    -- EditBox for manual paste fallback (Ctrl+V)
    local captureBox = CreateFrame("EditBox", "OLLManualRollCaptureBox", popup, "InputBoxTemplate")
    captureBox:SetSize(POPUP_W - 40, 26)
    captureBox:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, -76)
    captureBox:SetAutoFocus(false)
    captureBox:SetMaxLetters(0)

    -- Placeholder hint inside the capture box
    local capHint = captureBox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    capHint:SetPoint("LEFT", captureBox, "LEFT", 4, 0)
    capHint:SetText("Paste an item link here (Ctrl+V)...")
    capHint:Show()

    captureBox:SetScript("OnEditFocusGained", function() capHint:Hide() end)
    captureBox:SetScript("OnEditFocusLost",   function()
        if captureBox:GetText() == "" then capHint:Show() end
    end)

    local _suppressChange = false
    captureBox:SetScript("OnTextChanged", function(eb)
        if _suppressChange then return end
        local text = eb:GetText()
        if not text or text == "" then return end

        _suppressChange = true
        eb:SetText("")
        _suppressChange = false

        -- Extract the first item hyperlink from the pasted text
        local fullLink = text:match("(|c%x%x%x%x%x%x%x%x|H.-|h%[.-%]|h|r)")
                      or text:match("(|H.-|h%[.-%]|h)")
        if not fullLink then return end

        local name, _, quality, _, _, _, _, _, _, iconTexture = GetItemInfo(fullLink)
        if not name then
            ns.addon:Print("OLL: Item info not cached yet – try again in a moment.")
            return
        end

        tinsert(LeaderFrame._manualRollItems, {
            name    = name,
            link    = fullLink,
            quality = quality or 0,
            icon    = iconTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
        })
        LeaderFrame:_RefreshManualRollList()
        eb:SetFocus()
    end)
    captureBox:SetScript("OnEscapePressed", function() popup:Hide() end)

    self._manualCaptureBox = captureBox

    -- Divider below capture box
    local div1 = popup:CreateTexture(nil, "ARTWORK")
    div1:SetColorTexture(unpack(theme.dividerColor))
    div1:SetSize(POPUP_W - 32, 1)
    div1:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, -110)
    self._manualDiv1 = div1

    -- Scroll frame for item list
    local SCROLL_W = POPUP_W - 36  -- leaves ~20px right for scrollbar
    local scroll = CreateFrame("ScrollFrame", "OLLManualRollScroll", popup, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",  popup, "TOPLEFT",  16, -118)
    scroll:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 16, 56)
    scroll:SetWidth(SCROLL_W)

    local listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(SCROLL_W - 18, 1)  -- -18 for scrollbar width
    scroll:SetScrollChild(listChild)
    self._manualListChild = listChild

    -- Empty-list placeholder
    local emptyText = listChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOPLEFT", listChild, "TOPLEFT", 8, -10)
    emptyText:SetText("No items added yet.")
    emptyText:Hide()
    self._manualEmptyText = emptyText

    -- Divider above button bar
    local div2 = popup:CreateTexture(nil, "ARTWORK")
    div2:SetColorTexture(unpack(theme.dividerColor))
    div2:SetSize(POPUP_W - 32, 1)
    div2:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 16, 50)
    self._manualDiv2 = div2

    -- Clear All button
    local clearBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    clearBtn:SetSize(90, 26)
    clearBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 16, 18)
    clearBtn:SetText("Clear All")
    clearBtn:SetScript("OnClick", function()
        LeaderFrame._manualRollItems = {}
        LeaderFrame:_RefreshManualRollList()
        if LeaderFrame._manualCaptureBox then
            LeaderFrame._manualCaptureBox:SetFocus()
        end
    end)

    -- Start Roll button
    local startBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    startBtn:SetSize(100, 26)
    startBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -16, 18)
    startBtn:SetText("Start Roll")
    startBtn:SetScript("OnClick", function()
        local items = LeaderFrame._manualRollItems
        if not items or #items == 0 then
            ns.addon:Print("No items to roll on.")
            return
        end
        -- Hand off a copy and clear the pending list
        local rollItems = {}
        for _, item in ipairs(items) do tinsert(rollItems, item) end
        LeaderFrame._manualRollItems = {}
        popup:Hide()
        ns.Session:StartManualRoll(rollItems)
    end)
    self._manualStartBtn = startBtn

    popup:Hide()
    self._manualRollPopup = popup
end

function LeaderFrame:_RefreshManualRollList()
    -- Recycle all pooled rows
    for _, row in ipairs(self._manualItemRowPool) do
        row._inUse = false
        row:Hide()
    end

    local child = self._manualListChild
    if not child then return end

    local items = self._manualRollItems

    if not items or #items == 0 then
        if self._manualEmptyText then self._manualEmptyText:Show() end
        child:SetHeight(30)
        if self._manualStartBtn then self._manualStartBtn:Disable() end
        return
    end

    if self._manualEmptyText then self._manualEmptyText:Hide() end

    local ROW_H  = 28
    local yOffset = 0

    for i, item in ipairs(items) do
        local row = self:_AcquireManualRow(child)
        row:SetSize(child:GetWidth(), ROW_H)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOffset)
        row._itemLink = item.link or item.name
        row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.icon:Show()
        local mqr, mqg, mqb = GetItemQualityColor(item.quality or 1)
        row.nameFS:SetTextColor(mqr, mqg, mqb)
        row.nameFS:SetText(item.name or "?")
        row.nameFS:Show()
        -- Capture index in closure
        local capturedI = i
        row.removeBtn:SetScript("OnClick", function()
            table.remove(LeaderFrame._manualRollItems, capturedI)
            LeaderFrame:_RefreshManualRollList()
            if LeaderFrame._manualCaptureBox then
                LeaderFrame._manualCaptureBox:SetFocus()
            end
        end)
        row.removeBtn:Show()
        row:Show()
        yOffset = yOffset - ROW_H
    end

    child:SetHeight(math.abs(yOffset) + 4)
    if self._manualStartBtn then self._manualStartBtn:Enable() end
end

function LeaderFrame:_AcquireManualRow(parent)
    for _, row in ipairs(self._manualItemRowPool) do
        if not row._inUse then
            row._inUse = true
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end

    -- Create new row
    local row = CreateFrame("Frame", nil, parent)
    row._inUse = true
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(r)
        if r._itemLink then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            if r._itemLink:find("|H") then
                GameTooltip:SetHyperlink(r._itemLink)
            else
                GameTooltip:SetText(r._itemLink)
            end
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon = icon

    local removeBtn = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    removeBtn:SetSize(20, 20)
    removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.removeBtn = removeBtn

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFS:SetPoint("LEFT",  icon,      "RIGHT", 6,  0)
    nameFS:SetPoint("RIGHT", removeBtn, "LEFT",  -4, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    row.nameFS = nameFS

    tinsert(self._manualItemRowPool, row)
    return row
end

------------------------------------------------------------------------
-- Show / Hide / Toggle
------------------------------------------------------------------------
function LeaderFrame:Show()
    if not ns.IsLeader() then
        ns.addon:Print("Only the group leader or raid assist can open the leader frame.")
        return
    end
    local f = self:GetFrame()
    f:Show()
    self:Refresh()
end

function LeaderFrame:Hide()
    self:StopTimer()
    if self._frame then
        self._frame:Hide()
    end
    if self._lootMasterPopup then
        self._lootMasterPopup:Hide()
    end
    if self._manualRollPopup then
        self._manualRollPopup:Hide()
    end
    if self._tradeQueuePopup then
        self._tradeQueuePopup:Hide()
    end
    if ns.CheckPartyFrame then
        ns.CheckPartyFrame:Hide()
    end
end

function LeaderFrame:Reset()
    self:StopTimer()
    self._selectedItem = nil
    self:Hide()
    -- Recycle pools
    self:_RecycleItemRows()
    self:_RecyclePlayerRows()
    -- Clear any remaining regions
    if self._leftScrollChild then
        for _, region in ipairs({ self._leftScrollChild:GetRegions() }) do
            region:Hide()
        end
    end
    if self._rightScrollChild then
        for _, region in ipairs({ self._rightScrollChild:GetRegions() }) do
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
    local theme = ns.Theme:GetCurrent()
    if remaining < 5 then
        f.timerBar:SetStatusBarColor(unpack(theme.timerBarLowColor))
    elseif remaining < 10 then
        f.timerBar:SetStatusBarColor(unpack(theme.timerBarMidColor))
    else
        f.timerBar:SetStatusBarColor(unpack(theme.timerBarFullColor))
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
