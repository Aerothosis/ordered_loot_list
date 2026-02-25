------------------------------------------------------------------------
-- OrderedLootList  –  UI/CheckPartyFrame.lua
-- Party Check window: pings all group members for addon version and
-- displays per-player status (Ready / Outdated / Missing).
-- Also provides a "Test Loot" button for a no-consequences trial roll.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local CheckPartyFrame = {}
ns.CheckPartyFrame    = CheckPartyFrame

local FRAME_W        = 380
local FRAME_H        = 380
local ROW_H          = 22
local CHECK_TIMEOUT  = 10  -- seconds before non-responders become "Missing"

-- Status constants
local STATUS_READY    = "Ready"
local STATUS_OUTDATED = "Outdated"
local STATUS_MISSING  = "Missing"
local STATUS_CHECKING = "Checking"

CheckPartyFrame._frame            = nil
CheckPartyFrame._playerStatuses   = {}  -- { [playerName] = { status, version } }
CheckPartyFrame._checkTimerHandle = nil
CheckPartyFrame._playerRowPool    = {}
CheckPartyFrame._listChild        = nil

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function StripRealm(name)
    if not name then return name end
    return name:match("^(.-)%-") or name
end

-- Returns all current group members in Name-Realm format
local function GetGroupMembers()
    local members = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        tinsert(members, ns.GetPlayerNameRealm())
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                if not name:find("-") then
                    name = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(members, name)
            end
        end
    else
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
-- Lazy frame creation
------------------------------------------------------------------------
function CheckPartyFrame:GetFrame()
    if self._frame then return self._frame end

    local theme = ns.Theme:GetCurrent()

    local f = CreateFrame("Frame", "OLLCheckPartyFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER", UIParent, "CENTER", -100, 50)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 24,
        insets   = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frm)
        frm:StopMovingOrSizing()
        ns.SaveFramePosition("CheckPartyFrame", frm)
    end)
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(frm) ns.RaiseFrame(frm) end)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Party Check")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() CheckPartyFrame:Hide() end)

    -- "Send Check" button
    local sendBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sendBtn:SetSize(110, 26)
    sendBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    sendBtn:SetText("Send Check")
    sendBtn:SetScript("OnClick", function()
        CheckPartyFrame:SendCheck()
    end)
    f.sendBtn = sendBtn

    -- "Test Loot" button
    local testBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    testBtn:SetSize(100, 26)
    testBtn:SetPoint("LEFT", sendBtn, "RIGHT", 8, 0)
    testBtn:SetText("Test Loot")
    testBtn:SetScript("OnClick", function()
        if ns.Session then
            ns.Session:StartTestLoot()
        end
    end)
    f.testLootBtn = testBtn

    -- Divider below buttons
    local div = f:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(unpack(theme.dividerColor))
    div:SetSize(FRAME_W - 28, 1)
    div:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -70)
    f.div = div

    -- Column headers
    local hdrPlayer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrPlayer:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -78)
    hdrPlayer:SetText("|cff" .. theme.columnHeaderHex .. "Player|r")

    local hdrStatus = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrStatus:SetPoint("TOPLEFT", f, "TOPLEFT", FRAME_W - 150, -78)
    hdrStatus:SetText("|cff" .. theme.columnHeaderHex .. "Status|r")

    -- Column header divider
    local hdrDiv = f:CreateTexture(nil, "ARTWORK")
    hdrDiv:SetColorTexture(unpack(theme.dividerColor))
    hdrDiv:SetSize(FRAME_W - 28, 1)
    hdrDiv:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -92)
    f.hdrDiv = hdrDiv

    -- Scroll frame for player list
    local scroll = CreateFrame("ScrollFrame", "OLLCheckPartyScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     f, "TOPLEFT",     14,  -96)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 14)

    local listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(FRAME_W - 50, 1)
    scroll:SetScrollChild(listChild)
    self._listChild = listChild

    f:Hide()
    self._frame = f
    ns.RestoreFramePosition("CheckPartyFrame", f)
    return f
end

------------------------------------------------------------------------
-- Apply theme
------------------------------------------------------------------------
function CheckPartyFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()

    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    if f.div   then f.div:SetColorTexture(unpack(theme.dividerColor))    end
    if f.hdrDiv then f.hdrDiv:SetColorTexture(unpack(theme.dividerColor)) end
end

------------------------------------------------------------------------
-- Show / Hide
------------------------------------------------------------------------
function CheckPartyFrame:Show()
    if not ns.IsLeader() then
        ns.addon:Print("Only the group leader can use Party Check.")
        return
    end
    local f = self:GetFrame()
    f:Show()
    ns.RaiseFrame(f)
    self:_UpdateTestLootButton()
    self:SendCheck()
end

function CheckPartyFrame:Hide()
    if self._frame then self._frame:Hide() end
    if self._checkTimerHandle then
        ns.addon:CancelTimer(self._checkTimerHandle)
        self._checkTimerHandle = nil
    end
end

------------------------------------------------------------------------
-- Broadcast the addon check and reset all player statuses
------------------------------------------------------------------------
function CheckPartyFrame:SendCheck()
    self._playerStatuses = {}

    -- Leader is always Ready
    local me = ns.GetPlayerNameRealm()
    self._playerStatuses[me] = { status = STATUS_READY, version = ns.VERSION }

    -- Everyone else starts as "Checking"
    local members = GetGroupMembers()
    for _, name in ipairs(members) do
        if not ns.NamesMatch(name, me) then
            self._playerStatuses[name] = { status = STATUS_CHECKING, version = nil }
        end
    end

    -- Cancel previous timeout
    if self._checkTimerHandle then
        ns.addon:CancelTimer(self._checkTimerHandle)
        self._checkTimerHandle = nil
    end

    -- Only broadcast if in a group
    if IsInRaid() or IsInGroup() then
        ns.Comm:Send(ns.Comm.MSG.ADDON_CHECK, { version = ns.VERSION })

        self._checkTimerHandle = ns.addon:ScheduleTimer(function()
            self:_OnCheckTimeout()
        end, CHECK_TIMEOUT)
    end

    self:Refresh()
end

------------------------------------------------------------------------
-- Called when a player responds to the addon check
------------------------------------------------------------------------
function CheckPartyFrame:OnCheckResponse(payload, sender)
    -- Ignore if frame not shown (responses arrive on all clients)
    if not self._frame or not self._frame:IsShown() then return end

    local player      = payload.player or sender
    local theirVer    = payload.version or "unknown"
    local status      = (theirVer == ns.VERSION) and STATUS_READY or STATUS_OUTDATED

    -- Find the matching entry using NamesMatch (handles realm abbreviation)
    local matched = false
    for name in pairs(self._playerStatuses) do
        if ns.NamesMatch(name, player) then
            self._playerStatuses[name] = { status = status, version = theirVer }
            matched = true
            break
        end
    end
    -- Player wasn't in original list (e.g. joined after check sent)
    if not matched then
        self._playerStatuses[player] = { status = status, version = theirVer }
    end

    self:Refresh()
end

------------------------------------------------------------------------
-- Timeout: mark remaining "Checking" players as "Missing"
------------------------------------------------------------------------
function CheckPartyFrame:_OnCheckTimeout()
    self._checkTimerHandle = nil
    for _, data in pairs(self._playerStatuses) do
        if data.status == STATUS_CHECKING then
            data.status = STATUS_MISSING
        end
    end
    self:Refresh()
end

------------------------------------------------------------------------
-- Rebuild the player status list
------------------------------------------------------------------------
function CheckPartyFrame:Refresh()
    local f = self._frame
    if not f or not f:IsShown() then return end

    self:_UpdateTestLootButton()
    self:_RecycleRows()

    local child = self._listChild
    if not child then return end

    -- Sort: leader first, then alphabetical
    local me      = ns.GetPlayerNameRealm()
    local entries = {}
    for name, data in pairs(self._playerStatuses) do
        tinsert(entries, { name = name, status = data.status, version = data.version })
    end
    table.sort(entries, function(a, b)
        local aIsMe = ns.NamesMatch(a.name, me)
        local bIsMe = ns.NamesMatch(b.name, me)
        if aIsMe ~= bIsMe then return aIsMe end
        return a.name < b.name
    end)

    local yOffset = 0
    for _, entry in ipairs(entries) do
        yOffset = self:_DrawRow(child, yOffset, entry)
    end
    child:SetHeight(math.abs(yOffset) + 4)
end

------------------------------------------------------------------------
-- Draw a single player row
------------------------------------------------------------------------
function CheckPartyFrame:_DrawRow(parent, yOffset, entry)
    local row = self:_AcquireRow(parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetSize(parent:GetWidth(), ROW_H)
    row:Show()

    -- Player name
    row.nameText:SetText(StripRealm(entry.name))
    row.nameText:SetTextColor(1, 1, 1)
    row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.nameText:Show()

    -- Status text + color
    local statusStr, r, g, b
    if entry.status == STATUS_READY then
        statusStr = "|cff00ff00Ready|r"
        r, g, b = 0, 1, 0
    elseif entry.status == STATUS_OUTDATED then
        local vStr = entry.version and ("v" .. entry.version) or "unknown"
        statusStr = "|cffffff00Outdated - " .. vStr .. "|r"
        r, g, b = 1, 1, 0
    elseif entry.status == STATUS_MISSING then
        statusStr = "|cff888888Missing|r"
        r, g, b = 0.53, 0.53, 0.53
    else -- CHECKING
        statusStr = "|cff888888Checking...|r"
        r, g, b = 0.53, 0.53, 0.53
    end

    row.statusText:SetText(statusStr)
    row.statusText:SetPoint("LEFT", row, "LEFT", parent:GetWidth() - 136, 0)
    row.statusText:Show()

    return yOffset - ROW_H
end

------------------------------------------------------------------------
-- Enable/disable the Test Loot button based on current state
------------------------------------------------------------------------
function CheckPartyFrame:_UpdateTestLootButton()
    local f = self._frame
    if not f or not f.testLootBtn then return end

    local session = ns.Session
    local canTest = ns.IsLeader()
        and session
        and not session.debugMode
        and session.state ~= (session.STATE_ROLLING or "")
        and session.state ~= (session.STATE_RESOLVING or "")

    if canTest then
        f.testLootBtn:Enable()
    else
        f.testLootBtn:Disable()
    end
end

------------------------------------------------------------------------
-- Row pool helpers
------------------------------------------------------------------------
function CheckPartyFrame:_AcquireRow(parent)
    for _, row in ipairs(self._playerRowPool) do
        if not row._inUse then
            row._inUse = true
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end

    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row._inUse = true

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetJustifyH("LEFT")
    row.statusText = statusText

    tinsert(self._playerRowPool, row)
    return row
end

function CheckPartyFrame:_RecycleRows()
    for _, row in ipairs(self._playerRowPool) do
        row._inUse = false
        row.nameText:Hide()
        row.statusText:Hide()
        row:Hide()
    end
end
