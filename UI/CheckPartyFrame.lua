------------------------------------------------------------------------
-- OrderedLootList  –  UI/CheckPartyFrame.lua  (Ledger)
-- Party Check (400x420): pings every group member for their addon
-- version and shows per-player status.  44px title bar, 44px action row
-- (Send Check primary, Test Loot outline), 38px tally strip
-- (Ready / Outdated / Missing | Checking, N of M pinged), 22px column
-- header, 26px rows sorted Missing → Outdated → Checking → Ready.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local CheckPartyFrame = {}
ns.CheckPartyFrame    = CheckPartyFrame

local FRAME_W        = 400
local FRAME_H        = 420
local HEADER_H       = 44
local ACTION_BAR_H   = 44
local TALLY_BAR_H    = 38
local COL_HDR_H      = 22
local ROW_H          = 26
local INSET          = 16
local CHECK_TIMEOUT  = 10  -- seconds before non-responders become "Missing"

local STATUS_READY    = "Ready"
local STATUS_OUTDATED = "Outdated"
local STATUS_MISSING  = "Missing"
local STATUS_CHECKING = "Checking"

-- Sort order: rows that need action first
local STATUS_ORDER = { [STATUS_MISSING] = 1, [STATUS_OUTDATED] = 2, [STATUS_CHECKING] = 3, [STATUS_READY] = 4 }

CheckPartyFrame._frame            = nil
CheckPartyFrame._playerStatuses   = {}  -- { [playerName] = { status, version } }
CheckPartyFrame._checkTimerHandle = nil
CheckPartyFrame._playerRowPool    = {}
CheckPartyFrame._listChild        = nil

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

local function StripRealm(name)
    if not name then return name end
    return name:match("^(.-)%-") or name
end

local function GetGroupMembers()
    local members = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        tinsert(members, ns.GetPlayerNameRealm())
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                if not name:find("-") then name = name .. "-" .. (GetNormalizedRealmName() or "") end
                tinsert(members, name)
            end
        end
    else
        tinsert(members, ns.GetPlayerNameRealm())
        for i = 1, numMembers - 1 do
            local name = GetUnitName("party" .. i, true)
            if name then
                if not name:find("-") then name = name .. "-" .. (GetNormalizedRealmName() or "") end
                tinsert(members, name)
            end
        end
    end
    return members
end

local function StatusColorKey(status)
    if status == STATUS_READY then return "timerBarFullColor" end
    if status == STATUS_OUTDATED then return "timerBarMidColor" end
    if status == STATUS_MISSING then return "timerBarLowColor" end
    return nil -- checking: #8b909b
end

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
function CheckPartyFrame:GetFrame()
    if self._frame then return self._frame end
    local theme = ns.Theme:GetCurrent()

    local f = ns.MakeLedgerFrame("OLLCheckPartyFrame", FRAME_W, FRAME_H, "CheckPartyFrame", { strata = "DIALOG", x = -100, y = 50 })
    f.header = ns.MakeHeaderBar(f, "Party Check", nil, { height = HEADER_H, onClose = function() CheckPartyFrame:Hide() end })

    -- Action row
    local action = ns.MakeBar(f, ACTION_BAR_H, "barBgColor", "BOTTOM")
    action:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + 2))
    action:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(HEADER_H + 2))
    f.actionRow = action

    local sendBtn = ns.MakeButton(action, "primary", "Send Check", 110, 30)
    sendBtn:SetPoint("LEFT", action, "LEFT", INSET - 2, 0)
    sendBtn:SetScript("OnClick", function() CheckPartyFrame:SendCheck() end)
    f.sendBtn = sendBtn

    local testBtn = ns.MakeButton(action, "outline", "Test Loot", 96, 30)
    testBtn:SetPoint("LEFT", sendBtn, "RIGHT", 8, 0)
    testBtn:SetScript("OnClick", function() if ns.Session then ns.Session:StartTestLoot() end end)
    f.testLootBtn = testBtn

    -- Tally strip
    local tally = CreateFrame("Frame", nil, f)
    tally:SetPoint("TOPLEFT", action, "BOTTOMLEFT", 0, 0)
    tally:SetPoint("TOPRIGHT", action, "BOTTOMRIGHT", 0, 0)
    tally:SetHeight(TALLY_BAR_H)
    tally.rule = ns.MakeHairline(tally, "dividerColor")
    tally.rule:SetPoint("BOTTOMLEFT", tally, "BOTTOMLEFT", 0, 0)
    tally.rule:SetPoint("BOTTOMRIGHT", tally, "BOTTOMRIGHT", 0, 0)
    f.tally = tally

    local function makeCount(label, anchorTo)
        local num = tally:CreateFontString(nil, "OVERLAY")
        num:SetFontObject(ns.Ledger.Fonts.OLLFontNumberSmall)
        if anchorTo then num:SetPoint("LEFT", anchorTo, "RIGHT", 16, 0)
        else num:SetPoint("LEFT", tally, "LEFT", INSET - 2, 0) end
        num:SetText("0")
        local lbl = tally:CreateFontString(nil, "OVERLAY")
        lbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
        lbl:SetPoint("LEFT", num, "RIGHT", 6, -1)
        lbl:SetText(ns.Track(label))
        return num, lbl
    end
    f.readyNum,    f.readyLbl    = makeCount("Ready")
    f.outdatedNum, f.outdatedLbl = makeCount("Outdated", f.readyLbl)
    f.missingNum,  f.missingLbl  = makeCount("Missing",  f.outdatedLbl)
    f.tallySep = ns.MakeHairline(tally, "dividerColor")
    f.tallySep:ClearAllPoints(); f.tallySep:SetSize(1, 20)
    f.tallySep:SetPoint("LEFT", f.missingLbl, "RIGHT", 16, 0)
    f.checkingNum, f.checkingLbl = makeCount("Checking", f.tallySep)
    f.pinged = tally:CreateFontString(nil, "OVERLAY")
    f.pinged:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    f.pinged:SetPoint("RIGHT", tally, "RIGHT", -(INSET - 2), 0)
    f.pinged:SetJustifyH("RIGHT")

    -- Column header
    local colHdr = CreateFrame("Frame", nil, f)
    colHdr:SetPoint("TOPLEFT", tally, "BOTTOMLEFT", 0, 0)
    colHdr:SetPoint("TOPRIGHT", tally, "BOTTOMRIGHT", 0, 0)
    colHdr:SetHeight(COL_HDR_H)
    colHdr.player = colHdr:CreateFontString(nil, "OVERLAY")
    colHdr.player:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    colHdr.player:SetPoint("LEFT", colHdr, "LEFT", INSET - 2, 0)
    colHdr.player:SetText(ns.Track("Player"))
    colHdr.status = colHdr:CreateFontString(nil, "OVERLAY")
    colHdr.status:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    colHdr.status:SetPoint("LEFT", colHdr, "LEFT", FRAME_W - 150, 0)
    colHdr.status:SetText(ns.Track("Status"))
    colHdr.rule = ns.MakeHairline(colHdr, "dividerColor")
    colHdr.rule:SetPoint("BOTTOMLEFT", colHdr, "BOTTOMLEFT", 0, 0)
    colHdr.rule:SetPoint("BOTTOMRIGHT", colHdr, "BOTTOMRIGHT", 0, 0)
    f.colHdr = colHdr

    -- Player list
    local scroll = CreateFrame("ScrollFrame", "OLLCheckPartyScroll", f)
    scroll:SetPoint("TOPLEFT", colHdr, "BOTTOMLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * ROW_H * 2)))
    end)
    local listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(FRAME_W - 4, 1)
    scroll:SetScrollChild(listChild)
    self._listChild = listChild

    f:Hide()
    self._frame = f
    self:ApplyTheme(theme)
    return f
end

------------------------------------------------------------------------
-- Theme
------------------------------------------------------------------------
function CheckPartyFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f.tally.rule:SetVertexColor(C(theme, "dividerColor"))
    f.tallySep:SetVertexColor(C(theme, "dividerColor"))
    f.colHdr.rule:SetVertexColor(C(theme, "dividerColor"))
    local hr, hg, hb = tonumber(theme.columnHeaderHex:sub(1, 2), 16) / 255,
                       tonumber(theme.columnHeaderHex:sub(3, 4), 16) / 255,
                       tonumber(theme.columnHeaderHex:sub(5, 6), 16) / 255
    f.colHdr.player:SetTextColor(hr, hg, hb)
    f.colHdr.status:SetTextColor(hr, hg, hb)
    f.readyNum:SetTextColor(C(theme, "timerBarFullColor"))
    f.outdatedNum:SetTextColor(C(theme, "timerBarMidColor"))
    f.missingNum:SetTextColor(C(theme, "timerBarLowColor"))
    f.checkingNum:SetTextColor(0.545, 0.565, 0.608)  -- #8b909b
    for _, lbl in ipairs({ f.readyLbl, f.outdatedLbl, f.missingLbl, f.checkingLbl }) do
        lbl:SetTextColor(C(theme, "textMutedColor"))
    end
    f.pinged:SetTextColor(0.337, 0.361, 0.404)       -- #565c67
    for _, row in ipairs(self._playerRowPool) do
        row.hair:SetVertexColor(C(theme, "histSepColor"))
        row.hl:SetVertexColor(C(theme, "highlightColor"))
    end
end

------------------------------------------------------------------------
-- Show / Hide
------------------------------------------------------------------------
function CheckPartyFrame:Show()
    if not ns.IsLeader() then
        ns.ChatPrint("Normal", "Only the group leader can use Party Check.")
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
    local me = ns.GetPlayerNameRealm()
    self._playerStatuses[me] = { status = STATUS_READY, version = ns.VERSION }
    for _, name in ipairs(GetGroupMembers()) do
        if not ns.NamesMatch(name, me) then
            self._playerStatuses[name] = { status = STATUS_CHECKING, version = nil }
        end
    end

    if self._checkTimerHandle then
        ns.addon:CancelTimer(self._checkTimerHandle)
        self._checkTimerHandle = nil
    end

    if IsInRaid() or IsInGroup() then
        ns.Comm:Send(ns.Comm.MSG.ADDON_CHECK, { version = ns.VERSION })
        self._checkTimerHandle = ns.addon:ScheduleTimer(function() self:_OnCheckTimeout() end, CHECK_TIMEOUT)
    end

    self:Refresh()
end

------------------------------------------------------------------------
-- A player responded to the check
------------------------------------------------------------------------
function CheckPartyFrame:OnCheckResponse(payload, sender)
    if not self._frame or not self._frame:IsShown() then return end
    local player   = payload.player or sender
    local theirVer = payload.version or "unknown"
    local status   = (theirVer == ns.VERSION) and STATUS_READY or STATUS_OUTDATED

    local matched = false
    for name in pairs(self._playerStatuses) do
        if ns.NamesMatch(name, player) then
            self._playerStatuses[name] = { status = status, version = theirVer }
            matched = true
            break
        end
    end
    if not matched then
        self._playerStatuses[player] = { status = status, version = theirVer }
    end
    self:Refresh()   -- tally (incl. Checking) recomputes live
end

function CheckPartyFrame:_OnCheckTimeout()
    self._checkTimerHandle = nil
    for _, data in pairs(self._playerStatuses) do
        if data.status == STATUS_CHECKING then data.status = STATUS_MISSING end
    end
    self:Refresh()
end

------------------------------------------------------------------------
-- Rebuild tally + list
------------------------------------------------------------------------
function CheckPartyFrame:Refresh()
    local f = self._frame
    if not f or not f:IsShown() then return end
    local theme = ns.Theme:GetCurrent()

    self:_UpdateTestLootButton()
    self:_RecycleRows()

    local child = self._listChild
    if not child then return end

    -- Tally counts derived from _playerStatuses each refresh
    local counts = { [STATUS_READY] = 0, [STATUS_OUTDATED] = 0, [STATUS_MISSING] = 0, [STATUS_CHECKING] = 0 }
    local entries = {}
    for name, data in pairs(self._playerStatuses) do
        counts[data.status] = (counts[data.status] or 0) + 1
        tinsert(entries, { name = name, status = data.status, version = data.version })
    end
    f.readyNum:SetText(tostring(counts[STATUS_READY]))
    f.outdatedNum:SetText(tostring(counts[STATUS_OUTDATED]))
    f.missingNum:SetText(tostring(counts[STATUS_MISSING]))
    f.checkingNum:SetText(tostring(counts[STATUS_CHECKING]))
    local total = #GetGroupMembers()
    local pinged = total - counts[STATUS_CHECKING]
    f.pinged:SetText(pinged .. " of " .. total .. "\npinged")

    -- Sort: Missing → Outdated → Checking → Ready, then alphabetical
    table.sort(entries, function(a, b)
        local oa, ob = STATUS_ORDER[a.status] or 9, STATUS_ORDER[b.status] or 9
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)

    local yOffset = 0
    for _, entry in ipairs(entries) do
        yOffset = self:_DrawRow(child, yOffset, entry, theme)
    end
    child:SetHeight(math.abs(yOffset) + 4)
end

function CheckPartyFrame:_DrawRow(parent, yOffset, entry, theme)
    local row = self:_AcquireRow(parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
    row:SetHeight(ROW_H)
    row._playerName = entry.name
    row:Show()

    row.nameText:SetText(StripRealm(entry.name))
    local isChecking = entry.status == STATUS_CHECKING
    row.nameText:SetTextColor(C(theme, isChecking and "textMutedColor" or "textColor"))

    local key = StatusColorKey(entry.status)
    local r, g, b
    if key then r, g, b = C(theme, key) else r, g, b = 0.545, 0.565, 0.608 end
    row.dot:SetVertexColor(r, g, b)
    row.statusText:SetText(ns.Track(entry.status))
    row.statusText:SetTextColor(r, g, b)
    if entry.version and entry.status ~= STATUS_CHECKING and entry.status ~= STATUS_MISSING then
        row.versionText:SetText(entry.version)
        row.versionText:Show()
    else
        row.versionText:Hide()
    end
    row.hair:SetVertexColor(C(theme, "histSepColor"))
    row.versionText:SetTextColor(C(theme, "textDimColor"))
    return yOffset - ROW_H
end

function CheckPartyFrame:_UpdateTestLootButton()
    local f = self._frame
    if not f or not f.testLootBtn then return end
    local session = ns.Session
    local canTest = ns.IsLeader() and session and not session.debugMode
        and session.state ~= session.STATE_ROLLING
        and session.state ~= session.STATE_RESOLVING
    f.testLootBtn:SetEnabled(canTest and true or false)
end

------------------------------------------------------------------------
-- Row pool
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
    local theme = ns.Theme:GetCurrent()
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row:EnableMouse(true)
    row._inUse = true
    row.hair = ns.MakeHairline(row, "histSepColor")
    row.hair:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); row.hair:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.hl = row:CreateTexture(nil, "BACKGROUND"); row.hl:SetTexture(ns.Ledger.TEX.white); row.hl:SetAllPoints(); row.hl:Hide()
    row.hl:SetVertexColor(C(theme, "highlightColor"))
    row.nameText = row:CreateFontString(nil, "OVERLAY")
    row.nameText:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    row.nameText:SetPoint("LEFT", row, "LEFT", INSET - 2, 0)
    row.nameText:SetPoint("RIGHT", row, "LEFT", FRAME_W - 160, 0)
    row.nameText:SetJustifyH("LEFT"); row.nameText:SetWordWrap(false)
    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetTexture(ns.Ledger.TEX.dot); row.dot:SetSize(5, 5)
    row.dot:SetPoint("LEFT", row, "LEFT", FRAME_W - 150, 0)
    row.statusText = row:CreateFontString(nil, "OVERLAY")
    row.statusText:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    row.statusText:SetPoint("LEFT", row.dot, "RIGHT", 8, 0)
    row.versionText = row:CreateFontString(nil, "OVERLAY")
    row.versionText:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    row.versionText:SetPoint("LEFT", row.statusText, "RIGHT", 8, 0)
    row:SetScript("OnEnter", function(r) r.hl:Show() end)
    row:SetScript("OnLeave", function(r) r.hl:Hide() end)
    ns.AttachAltTooltip(row, function() return row._playerName end)
    tinsert(self._playerRowPool, row)
    return row
end

function CheckPartyFrame:_RecycleRows()
    for _, row in ipairs(self._playerRowPool) do
        row._inUse = false
        row:Hide()
    end
end
