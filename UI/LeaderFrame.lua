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
local HEADER_HEIGHT           = 88 -- space for title, buttons, timer
local ITEM_ROW_HEIGHT         = 30
local PLAYER_ROW_HEIGHT       = 20

LeaderFrame._frame            = nil
LeaderFrame._leftScrollChild  = nil
LeaderFrame._rightScrollChild = nil
LeaderFrame._tickerHandle     = nil

-- Selection state: { source="current"|"history"|"trade", bossKey=string, itemIdx=number }
LeaderFrame._selectedItem     = nil
-- Pool of left-panel item row frames for reuse
LeaderFrame._itemRowPool      = {}
-- Pool of right-panel player row frames for reuse
LeaderFrame._playerRowPool    = {}

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
        return members
    end
    if IsInRaid() then
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
    return members
end

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

    -- Roll timer bar (spans full width below header controls)
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

    -- Vertical divider
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.6)
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

    local rightScroll = CreateFrame("ScrollFrame", "OLLLeaderRightScroll", f, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT", f, "TOPLEFT", rightX, -HEADER_HEIGHT)
    rightScroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 14)

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

    -- === TRADE QUEUE ===
    local tradeQueue = session:GetTradeQueue()
    if tradeQueue and #tradeQueue > 0 then
        yOffset = yOffset - 8
        yOffset = self:_DrawSectionHeader(sc, yOffset, "Trade Queue")
        yOffset = yOffset - 2

        for idx, entry in ipairs(tradeQueue) do
            local key = self:_MakeItemKey("trade", nil, idx)
            yOffset = self:_DrawTradeRow(sc, yOffset, key, entry)
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
    local item, result, responses, isCurrent, tradeEntry = self:_ResolveSelectedItem()

    if not item and not tradeEntry then
        local missing = sc:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        missing:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, -4)
        missing:SetText("Item no longer available.")
        missing:Show()
        sc:SetHeight(30)
        return
    end

    local yOffset = 0

    -- Trade queue items get their own simple display
    if tradeEntry then
        yOffset = self:_DrawTradeDetail(sc, yOffset, tradeEntry)
        sc:SetHeight(math.abs(yOffset) + 20)
        return
    end

    -- === Item header ===
    local icon = sc:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, yOffset - 2)
    icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:Show()

    local nameText = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameText:SetPoint("LEFT", icon, "RIGHT", 8, 6)
    nameText:SetText(item.link or item.name or "Unknown")
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

    yOffset = yOffset - 42

    -- === Column headers ===
    local rightPanelWidth = sc:GetWidth()
    local colNameX = 4
    local colTypeX = rightPanelWidth * 0.42
    local colRollX = rightPanelWidth * 0.62
    local colCountX = rightPanelWidth * 0.78

    local hdrName = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrName:SetPoint("TOPLEFT", sc, "TOPLEFT", colNameX, yOffset)
    hdrName:SetText("|cffffd100Player|r")
    hdrName:Show()

    local hdrType = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrType:SetPoint("TOPLEFT", sc, "TOPLEFT", colTypeX, yOffset)
    hdrType:SetText("|cffffd100Roll Type|r")
    hdrType:Show()

    local hdrRoll = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrRoll:SetPoint("TOPLEFT", sc, "TOPLEFT", colRollX, yOffset)
    hdrRoll:SetText("|cffffd100Roll|r")
    hdrRoll:Show()

    local hdrCount = sc:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrCount:SetPoint("TOPLEFT", sc, "TOPLEFT", colCountX, yOffset)
    hdrCount:SetText("|cffffd100Gear Count|r")
    hdrCount:Show()

    yOffset = yOffset - 16

    -- Separator line
    local sep = sc:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
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

    -- === Action buttons (for resolved current-boss items) ===
    if isCurrent and result and result.winner then
        yOffset = yOffset - 10
        yOffset = self:_DrawActionButtons(sc, yOffset, sel)
    end

    sc:SetHeight(math.abs(yOffset) + 20)
end

------------------------------------------------------------------------
-- Build sorted player list for right panel
------------------------------------------------------------------------
function LeaderFrame:_BuildSortedPlayerList(responses, result, session)
    local rollOptions = session.rollOptions or ns.DEFAULT_ROLL_OPTIONS
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
            count    = ns.LootCount:GetCount(player),
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
    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    header:SetText("|cffffd100" .. text .. "|r")
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
    row._itemKey = key
    row:Show()

    -- Icon
    row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:Show()

    -- Name
    row.nameText:SetText(item.link or item.name or "Unknown")
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
-- Draw a trade queue row in the left panel
------------------------------------------------------------------------
function LeaderFrame:_DrawTradeRow(parent, yOffset, key, entry)
    local row = self:_AcquireItemRow(parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetSize(LEFT_PANEL_WIDTH - 20, ITEM_ROW_HEIGHT)
    row._itemKey = key
    row._tradeEntry = entry
    row:Show()

    -- Icon
    row.icon:SetTexture(entry.itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:Show()

    -- Name + winner
    local nameStr = (entry.itemLink or entry.itemName or "?")
    row.nameText:SetText(nameStr)
    row.nameText:Show()

    -- Status
    if entry.awarded then
        row.statusText:SetText("|cff00ff00Traded|r")
    else
        row.statusText:SetText("→ " .. StripRealm(entry.winner or "?"))
    end
    row.statusText:Show()

    return yOffset - ITEM_ROW_HEIGHT
end

------------------------------------------------------------------------
-- Draw trade detail on the right panel
------------------------------------------------------------------------
function LeaderFrame:_DrawTradeDetail(parent, yOffset, entry)
    -- Icon
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yOffset - 2)
    icon:SetTexture(entry.itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:Show()

    -- Name
    local nameText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameText:SetPoint("LEFT", icon, "RIGHT", 8, 6)
    nameText:SetText(entry.itemLink or entry.itemName or "?")
    nameText:Show()

    -- Winner
    local winText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    winText:SetPoint("LEFT", icon, "RIGHT", 8, -8)
    winText:SetText("Winner: " .. (entry.winner or "?"))
    winText:Show()

    yOffset = yOffset - 44

    -- Status / Trade button
    if entry.awarded then
        local doneText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        doneText:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yOffset)
        doneText:SetText("|cff00ff00Traded successfully.|r")
        doneText:Show()
        yOffset = yOffset - 20
    else
        local tradeBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        tradeBtn:SetSize(100, 26)
        tradeBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yOffset)
        tradeBtn:SetText("Open Trade")
        tradeBtn:SetScript("OnClick", function()
            local shortName = (entry.winner or ""):match("^(.-)%-") or entry.winner
            if UnitExists(shortName) then
                InitiateTrade(shortName)
            else
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
        yOffset = yOffset - 30
    end

    return yOffset
end

------------------------------------------------------------------------
-- Draw action buttons on the right panel (Announce, Re-roll, Reassign)
------------------------------------------------------------------------
function LeaderFrame:_DrawActionButtons(parent, yOffset, sel)
    local session = ns.Session
    if not sel or sel.source ~= "current" then return yOffset end
    local itemIdx = sel.itemIdx

    local announceBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    announceBtn:SetSize(90, 24)
    announceBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yOffset)
    announceBtn:SetText("Announce")
    announceBtn:SetScript("OnClick", function()
        session:AnnounceWinner(itemIdx)
    end)
    announceBtn:Show()

    local rerollBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    rerollBtn:SetSize(80, 24)
    rerollBtn:SetPoint("LEFT", announceBtn, "RIGHT", 6, 0)
    rerollBtn:SetText("Re-roll")
    rerollBtn:SetScript("OnClick", function()
        session.responses[itemIdx] = {}
        session.results[itemIdx] = nil
        session:StartAllRolls()
    end)
    rerollBtn:Show()

    local reassignBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    reassignBtn:SetSize(90, 24)
    reassignBtn:SetPoint("LEFT", rerollBtn, "RIGHT", 6, 0)
    reassignBtn:SetText("Reassign")
    reassignBtn:SetScript("OnClick", function()
        local item = session.currentItems[itemIdx]
        LeaderFrame:ShowReassignPopup(itemIdx, item)
    end)
    reassignBtn:Show()

    return yOffset - 30
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
    elseif key.source == "trade" then
        local tq = session:GetTradeQueue()
        return tq and tq[key.itemIdx] ~= nil
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
    elseif sel.source == "trade" then
        local tq = session:GetTradeQueue()
        local entry = tq and tq[sel.itemIdx]
        return nil, nil, nil, false, entry
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

    -- Create new row frame
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ITEM_ROW_HEIGHT)
    row:EnableMouse(true)

    -- Highlight texture
    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.1)
    highlight:Hide()
    row.highlight = highlight

    -- Selected texture
    local selected = row:CreateTexture(nil, "BACKGROUND")
    selected:SetAllPoints()
    selected:SetColorTexture(0.2, 0.5, 1.0, 0.25)
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
    row:SetScript("OnClick", function(self)
        LeaderFrame._selectedItem = self._itemKey
        LeaderFrame:_UpdateItemHighlights()
        LeaderFrame:_RefreshRightPanel()
    end)
    row:SetScript("OnEnter", function(self)
        if not LeaderFrame:_ItemKeysEqual(LeaderFrame._selectedItem, self._itemKey) then
            self.highlight:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.highlight:Hide()
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
