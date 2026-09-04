------------------------------------------------------------------------
-- OrderedLootList  –  UI/SessionHistoryFrame.lua  (Ledger)
-- Session history viewer (800x540): past raid nights on the left (52px
-- two-line rows), and on the right a 74px detail header (date in
-- Spectral, one metadata line, Delete), boss groups, 28px item rows with
-- the winner and CHOICE ROLL in fixed right-hand columns, and a 20px
-- runners-up sub-row per item.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local SessionHistoryFrame = {}
ns.SessionHistoryFrame    = SessionHistoryFrame

------------------------------------------------------------------------
-- Confirmation dialog
------------------------------------------------------------------------
StaticPopupDialogs["OLL_CONFIRM_DELETE_SESSION"] = {
    text        = "Delete this session record and its loot history rows?\n\nLoot counts are not changed. This cannot be undone.",
    button1     = "Delete",
    button2     = "Cancel",
    OnAccept    = function() SessionHistoryFrame:_ExecuteDelete() end,
    timeout     = 0,
    whileDead   = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

------------------------------------------------------------------------
-- Layout constants
------------------------------------------------------------------------
local FRAME_WIDTH       = 800
local FRAME_HEIGHT      = 540
local LEFT_PANEL_WIDTH  = 246
local HEADER_HEIGHT     = 44
local SESSION_ROW_H     = 52
local BOSS_HDR_H        = 24
local ITEM_ROW_H        = 28
local ROLL_ROW_H        = 20
local DETAIL_HEADER_H   = 74
local INSET             = 16
local ROLL_INDENT       = 49
local CHOICE_COL_W      = 66
local WINNER_COL_W      = 110

------------------------------------------------------------------------
-- Module-level state
------------------------------------------------------------------------
SessionHistoryFrame._frame        = nil
local _selectedSessionId          = nil
local _sessionRowPool             = {}
local _detailBossPool             = {}
local _detailItemPool             = {}
local _detailRollPool             = {}

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function _FormatLongDate(ts)
    return ts and date("%A, %d %B %Y", ts) or "—"
end

local function _FormatShortDate(ts)
    return ts and date("%b %d", ts) or "—"
end

local function _FormatTime(ts)
    return ts and date("%H:%M", ts) or "—"
end

local function _FormatDuration(startTime, endTime)
    if not startTime or not endTime then return "—" end
    local secs = endTime - startTime
    if secs < 0 then return "—" end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return m .. "m"
end

local function _FindSession(sid)
    for _, s in ipairs(ns.db.global.sessionHistory or {}) do
        if s.id == sid then return s end
    end
end

local function _GetSortedSessions()
    local out = {}
    for _, s in ipairs(ns.db.global.sessionHistory or {}) do out[#out + 1] = s end
    table.sort(out, function(a, b) return (a.startTime or 0) > (b.startTime or 0) end)
    return out
end

local function _GetEntriesForSession(sid)
    local out = {}
    for _, e in ipairs(ns.db.global.lootHistory or {}) do
        if e.sessionId == sid then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)
    return out
end

local function _CountEntriesForSession(sid)
    local n = 0
    for _, e in ipairs(ns.db.global.lootHistory or {}) do
        if e.sessionId == sid then n = n + 1 end
    end
    return n
end

local function _IsSessionResumable(sess)
    if not sess.endTime then return false end
    if sess.startTime < ns.GetCurrentWeeklyResetTime() then return false end
    return ns.Session and ns.Session:_IsOwnerOfSession(sess) or false
end

------------------------------------------------------------------------
-- Row pools
------------------------------------------------------------------------
local function _AcquireSessionRow(parent, pool, idx)
    local row = pool[idx]
    if not row then
        row = CreateFrame("Button", nil, parent)
        row:SetHeight(SESSION_ROW_H)
        row.hair = ns.MakeHairline(row, "histSepColor")
        row.hair:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0); row.hair:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        row.sel = row:CreateTexture(nil, "BACKGROUND"); row.sel:SetTexture(ns.Ledger.TEX.white); row.sel:SetAllPoints(); row.sel:Hide()
        row.hl  = row:CreateTexture(nil, "BACKGROUND", nil, 1); row.hl:SetTexture(ns.Ledger.TEX.white); row.hl:SetAllPoints(); row.hl:Hide()
        row.tick = row:CreateTexture(nil, "ARTWORK"); row.tick:SetTexture(ns.Ledger.TEX.white); row.tick:SetWidth(2)
        row.tick:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); row.tick:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0); row.tick:Hide()
        row.line1 = row:CreateFontString(nil, "OVERLAY")
        row.line1:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        row.line1:SetPoint("TOPLEFT", row, "TOPLEFT", INSET, -9)
        row.line1:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
        row.line1:SetJustifyH("LEFT"); row.line1:SetWordWrap(false)
        row.line2 = row:CreateFontString(nil, "OVERLAY")
        row.line2:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
        row.line2:SetPoint("TOPLEFT", row.line1, "BOTTOMLEFT", 0, -4)
        row.line2:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
        row.line2:SetJustifyH("LEFT"); row.line2:SetWordWrap(false)
        row:SetScript("OnEnter", function(r) r.hl:Show() end)
        row:SetScript("OnLeave", function(r) r.hl:Hide() end)
        pool[idx] = row
    end
    row:SetParent(parent)
    row:ClearAllPoints()
    row:Show()
    return row
end

local function _AcquireBossHdr(parent, pool, idx)
    local f = pool[idx]
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f:SetHeight(BOSS_HDR_H)
        f.lbl = f:CreateFontString(nil, "OVERLAY")
        f.lbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
        f.lbl:SetPoint("LEFT", f, "LEFT", INSET, 0)
        f.lbl:SetPoint("RIGHT", f, "RIGHT", -INSET, 0)
        f.lbl:SetJustifyH("LEFT")
        f.rule = ns.MakeHairline(f, "dividerColor")
        f.rule:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0); f.rule:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        pool[idx] = f
    end
    f:SetParent(parent)
    f:ClearAllPoints()
    f:Show()
    return f
end

local function _AcquireItemRow(parent, pool, idx)
    local f = pool[idx]
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f:SetHeight(ITEM_ROW_H)
        f:EnableMouse(true)
        f.hl = f:CreateTexture(nil, "BACKGROUND"); f.hl:SetTexture(ns.Ledger.TEX.white); f.hl:SetAllPoints(); f.hl:Hide()
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetSize(18, 18)
        f.icon:SetPoint("LEFT", f, "LEFT", INSET + 16, 0)
        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f.iconEdge = CreateFrame("Frame", nil, f, "BackdropTemplate")
        f.iconEdge:SetPoint("TOPLEFT", f.icon, "TOPLEFT", -1, 1)
        f.iconEdge:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", 1, -1)
        ns.SkinNineSlice(f.iconEdge, "pill")
        -- fixed right-hand columns: winner, then CHOICE ROLL
        f.choiceLbl = f:CreateFontString(nil, "OVERLAY")
        f.choiceLbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
        f.choiceLbl:SetPoint("RIGHT", f, "RIGHT", -INSET, 0)
        f.choiceLbl:SetWidth(CHOICE_COL_W); f.choiceLbl:SetJustifyH("RIGHT")
        f.winnerLbl = f:CreateFontString(nil, "OVERLAY")
        f.winnerLbl:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        f.winnerLbl:SetPoint("RIGHT", f.choiceLbl, "LEFT", -12, 0)
        f.winnerLbl:SetWidth(WINNER_COL_W); f.winnerLbl:SetJustifyH("RIGHT"); f.winnerLbl:SetWordWrap(false)
        f.itemLbl = f:CreateFontString(nil, "OVERLAY")
        f.itemLbl:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        f.itemLbl:SetPoint("LEFT", f.icon, "RIGHT", 10, 0)
        f.itemLbl:SetPoint("RIGHT", f.winnerLbl, "LEFT", -12, 0)
        f.itemLbl:SetJustifyH("LEFT"); f.itemLbl:SetWordWrap(false)
        -- alt tooltip over the winner column
        f.playerHit = CreateFrame("Frame", nil, f)
        f.playerHit:SetPoint("TOPLEFT", f.winnerLbl, "TOPLEFT", -4, 4)
        f.playerHit:SetPoint("BOTTOMRIGHT", f.winnerLbl, "BOTTOMRIGHT", 4, -4)
        f.playerHit:Hide()
        ns.AttachAltTooltip(f.playerHit, function() return f._playerName end)
        f:SetScript("OnEnter", function(r)
            r.hl:Show()
            if r._link and r._link:find("|H") then
                GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(r._link)
                GameTooltip:Show()
            end
        end)
        f:SetScript("OnLeave", function(r) r.hl:Hide(); GameTooltip_Hide() end)
        pool[idx] = f
    end
    f:SetParent(parent)
    f:ClearAllPoints()
    f:Show()
    return f
end

local function _AcquireRollRow(parent, pool, idx)
    local f = pool[idx]
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f:SetHeight(ROLL_ROW_H)
        f.lbl = f:CreateFontString(nil, "OVERLAY")
        f.lbl:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
        f.lbl:SetPoint("LEFT", f, "LEFT", INSET + ROLL_INDENT, 0)
        f.lbl:SetPoint("RIGHT", f, "RIGHT", -INSET, 0)
        f.lbl:SetJustifyH("LEFT"); f.lbl:SetWordWrap(false)
        f.hair = ns.MakeHairline(f, "histSepColor")
        f.hair:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0); f.hair:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        pool[idx] = f
    end
    f:SetParent(parent)
    f:ClearAllPoints()
    f:Show()
    return f
end

local function _HidePoolFrom(pool, fromIdx)
    for i = fromIdx, #pool do
        if pool[i] then pool[i]:Hide() end
    end
end

------------------------------------------------------------------------
-- Frame creation
------------------------------------------------------------------------
function SessionHistoryFrame:GetFrame()
    if self._frame then return self._frame end
    local theme = ns.Theme:GetCurrent()

    local f = ns.MakeLedgerFrame("OLLSessionHistoryFrame", FRAME_WIDTH, FRAME_HEIGHT, "SessionHistoryFrame", { strata = "HIGH" })
    f.header = ns.MakeHeaderBar(f, "Session History", nil, { height = HEADER_HEIGHT, onClose = function() SessionHistoryFrame:Hide() end })

    -- Left panel
    local leftPanel = CreateFrame("Frame", nil, f)
    leftPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_HEIGHT + 2))
    leftPanel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
    leftPanel:SetWidth(LEFT_PANEL_WIDTH)
    f.leftBg = leftPanel:CreateTexture(nil, "BACKGROUND")
    f.leftBg:SetTexture(ns.Ledger.TEX.white); f.leftBg:SetAllPoints()
    f.divider = ns.MakeHairline(f, "dividerColor")
    f.divider:ClearAllPoints(); f.divider:SetWidth(1)
    f.divider:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 0, 0)
    f.divider:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMRIGHT", 0, 0)

    local leftScroll = CreateFrame("ScrollFrame", "OLLSessHistLeftScroll", leftPanel)
    leftScroll:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, 0)
    leftScroll:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", 0, 0)
    leftScroll:EnableMouseWheel(true)
    leftScroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * SESSION_ROW_H)))
    end)
    local leftChild = CreateFrame("Frame", nil, leftScroll)
    leftChild:SetSize(LEFT_PANEL_WIDTH, 1)
    leftScroll:SetScrollChild(leftChild)
    f._leftScroll = leftScroll
    f._leftChild  = leftChild

    f._leftEmptyLabel = leftPanel:CreateFontString(nil, "OVERLAY")
    f._leftEmptyLabel:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    f._leftEmptyLabel:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", INSET, -16)
    f._leftEmptyLabel:SetText("No session history.")
    f._leftEmptyLabel:Hide()

    -- Right panel
    local rightPanel = CreateFrame("Frame", nil, f)
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 1, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)

    local rightScroll = CreateFrame("ScrollFrame", "OLLSessHistRightScroll", rightPanel)
    rightScroll:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, 0)
    rightScroll:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", 0, 0)
    rightScroll:EnableMouseWheel(true)
    rightScroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 40)))
    end)
    local rightChild = CreateFrame("Frame", nil, rightScroll)
    rightChild:SetSize(FRAME_WIDTH - LEFT_PANEL_WIDTH - 5, 1)
    rightScroll:SetScrollChild(rightChild)
    rightScroll:SetScript("OnSizeChanged", function(_, w) rightChild:SetWidth(w) end)
    f._rightScroll = rightScroll
    f._rightChild  = rightChild

    f._emptyLabel = rightChild:CreateFontString(nil, "OVERLAY")
    f._emptyLabel:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    f._emptyLabel:SetPoint("TOPLEFT", rightChild, "TOPLEFT", INSET, -16)
    f._emptyLabel:SetText("Select a session to view details.")
    f._emptyLabel:Hide()

    -- Detail header (74px): date · one metadata line · Delete
    local detailHdr = CreateFrame("Frame", nil, rightChild)
    detailHdr:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 0, 0)
    detailHdr:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, 0)
    detailHdr:SetHeight(DETAIL_HEADER_H)
    detailHdr:Hide()
    f._detailHdr = detailHdr
    detailHdr.rule = ns.MakeHairline(detailHdr, "dividerColor")
    detailHdr.rule:SetPoint("BOTTOMLEFT", detailHdr, "BOTTOMLEFT", 0, 0)
    detailHdr.rule:SetPoint("BOTTOMRIGHT", detailHdr, "BOTTOMRIGHT", 0, 0)

    f._hdrDate = detailHdr:CreateFontString(nil, "OVERLAY")
    f._hdrDate:SetFontObject(ns.Ledger.Fonts.OLLFontHero)
    f._hdrDate:SetPoint("TOPLEFT", detailHdr, "TOPLEFT", INSET, -14)
    f._hdrDate:SetWordWrap(false)

    -- metadata spans: "21:00 – 22:24 · 1h 24m" | "Leader X" | "LM X, Y"
    f._hdrSpan = detailHdr:CreateFontString(nil, "OVERLAY")
    f._hdrSpan:SetFontObject(ns.Ledger.Fonts.OLLFontMeta)
    f._hdrSpan:SetPoint("TOPLEFT", f._hdrDate, "BOTTOMLEFT", 0, -8)
    f._hdrLeaderLbl = detailHdr:CreateFontString(nil, "OVERLAY")
    f._hdrLeaderLbl:SetFontObject(ns.Ledger.Fonts.OLLFontMeta)
    f._hdrLeaderLbl:SetPoint("LEFT", f._hdrSpan, "RIGHT", 18, 0)
    f._hdrLeaderLbl:SetText("Leader")
    f._hdrLeader = detailHdr:CreateFontString(nil, "OVERLAY")
    f._hdrLeader:SetFontObject(ns.Ledger.Fonts.OLLFontMeta)
    f._hdrLeader:SetPoint("LEFT", f._hdrLeaderLbl, "RIGHT", 6, 0)
    f._hdrLMLbl = detailHdr:CreateFontString(nil, "OVERLAY")
    f._hdrLMLbl:SetFontObject(ns.Ledger.Fonts.OLLFontMeta)
    f._hdrLMLbl:SetPoint("LEFT", f._hdrLeader, "RIGHT", 18, 0)
    f._hdrLMLbl:SetText("LM")
    f._hdrMasters = detailHdr:CreateFontString(nil, "OVERLAY")
    f._hdrMasters:SetFontObject(ns.Ledger.Fonts.OLLFontMeta)
    f._hdrMasters:SetPoint("LEFT", f._hdrLMLbl, "RIGHT", 6, 0)
    f._hdrMasters:SetWordWrap(false)
    -- legacy names some callers may poke
    f._hdrLine1, f._hdrLine2, f._hdrLine3 = f._hdrDate, f._hdrLeader, f._hdrMasters

    -- alt-tooltip hit frames anchored to the inline spans
    local leaderHit = CreateFrame("Frame", nil, detailHdr)
    leaderHit:SetPoint("TOPLEFT", f._hdrLeader, "TOPLEFT", -2, 3)
    leaderHit:SetPoint("BOTTOMRIGHT", f._hdrLeader, "BOTTOMRIGHT", 2, -3)
    ns.AttachAltTooltip(leaderHit, function() return f._sessionLeader end)
    f._leaderHit = leaderHit

    local mastersHit = CreateFrame("Frame", nil, detailHdr)
    mastersHit:SetPoint("TOPLEFT", f._hdrMasters, "TOPLEFT", -2, 3)
    mastersHit:SetPoint("BOTTOMRIGHT", f._hdrMasters, "BOTTOMRIGHT", 2, -3)
    mastersHit:EnableMouse(true)
    mastersHit:HookScript("OnEnter", function(hit)
        local masters = f._sessionMasters
        if not masters or #masters == 0 then return end
        local lines = {}
        for _, m in ipairs(masters) do
            local mainIdentity = ns.PlayerLinks:ResolveIdentity(m)
            if mainIdentity and mainIdentity ~= m then
                lines[#lines + 1] = { name = ns.StripRealm(m), main = ns.StripRealm(mainIdentity) }
            end
        end
        if #lines == 0 then return end
        GameTooltip:SetOwner(hit, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        for _, l in ipairs(lines) do GameTooltip:AddLine(l.name .. " — Main: " .. l.main, 1, 1, 1) end
        GameTooltip:Show()
    end)
    mastersHit:HookScript("OnLeave", function(hit)
        if GameTooltip:GetOwner() == hit then GameTooltip_Hide() end
    end)
    f._mastersHit = mastersHit

    local deleteBtn = ns.MakeButton(detailHdr, "outline", "Delete", 96, 32)
    deleteBtn:SetPoint("TOPRIGHT", detailHdr, "TOPRIGHT", -INSET, -14)
    deleteBtn:SetScript("OnClick", function()
        -- Pin the target now; the selection can change while the dialog is up.
        SessionHistoryFrame._deleteSid = _selectedSessionId
        StaticPopup_Show("OLL_CONFIRM_DELETE_SESSION")
    end)
    deleteBtn:Hide()
    f._deleteBtn = deleteBtn

    f:Hide()
    self._frame = f
    self:ApplyTheme(theme)
    return f
end

------------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------------
function SessionHistoryFrame:Show()
    local f = self:GetFrame()
    f:Show()
    ns.RaiseFrame(f)
    self:Refresh()
end

function SessionHistoryFrame:Hide()
    if self._frame then
        ns.SaveFramePosition("SessionHistoryFrame", self._frame)
        self._frame:Hide()
    end
end

function SessionHistoryFrame:Toggle()
    if self._frame and self._frame:IsShown() then self:Hide() else self:Show() end
end

function SessionHistoryFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

function SessionHistoryFrame:Refresh()
    self:_RefreshSessionList()
    self:_RefreshDetail()
end

------------------------------------------------------------------------
-- Left panel: session list
------------------------------------------------------------------------
function SessionHistoryFrame:_RefreshSessionList()
    local f = self._frame
    if not f then return end
    local theme     = ns.Theme:GetCurrent()
    local sessions  = _GetSortedSessions()
    local leftChild = f._leftChild

    for i, sess in ipairs(sessions) do
        local row = _AcquireSessionRow(leftChild, _sessionRowPool, i)
        row:SetPoint("TOPLEFT", leftChild, "TOPLEFT", 0, -(i - 1) * SESSION_ROW_H)
        row:SetPoint("TOPRIGHT", leftChild, "TOPRIGHT", 0, -(i - 1) * SESSION_ROW_H)

        local isSelected = (sess.id == _selectedSessionId)
        row.sel:SetVertexColor(C(theme, "rowBgColor")); row.sel:SetShown(isSelected)
        row.tick:SetVertexColor(C(theme, "accentColor")); row.tick:SetShown(isSelected)
        row.hl:SetVertexColor(C(theme, "highlightColor"))
        row.hair:SetVertexColor(C(theme, "histSepColor"))

        row.line1:SetText(_FormatShortDate(sess.startTime) .. " · " .. _FormatTime(sess.startTime))
        row.line1:SetTextColor(C(theme, "textColor"))

        local bossCount = #(sess.bosses or {})
        local itemCount = _CountEntriesForSession(sess.id)
        local parts = {
            bossCount .. (bossCount == 1 and " boss" or " bosses"),
            itemCount .. (itemCount == 1 and " item" or " items"),
        }
        if sess.endTime then tinsert(parts, _FormatDuration(sess.startTime, sess.endTime))
        else tinsert(parts, "in progress") end
        local line2 = table.concat(parts, " · ")
        if _IsSessionResumable(sess) then
            local r, g, b = C(theme, "timerBarFullColor")
            line2 = line2 .. string.format("  |cff%02x%02x%02xresumable|r", r * 255, g * 255, b * 255)
        end
        row.line2:SetText(line2)
        row.line2:SetTextColor(C(theme, "textMutedColor"))

        row:SetScript("OnClick", function()
            _selectedSessionId = sess.id
            self:_RefreshSessionList()
            self:_RefreshDetail()
        end)
    end

    _HidePoolFrom(_sessionRowPool, #sessions + 1)
    f._leftEmptyLabel:SetShown(#sessions == 0)
    leftChild:SetHeight(math.max(1, #sessions * SESSION_ROW_H))
end

------------------------------------------------------------------------
-- Right panel: session detail
------------------------------------------------------------------------
local function _ChoiceText(theme, choice, roll)
    local r, g, b = ns.Ledger.UnpackColor(
        (choice == "Passed" or choice == "Disenchant") and theme.choicePassColor or ns.Theme:ChoiceColor(choice, theme))
    local hex = string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
    local label = ns.Track(choice or "?")
    if roll and roll > 0 then label = label .. " " .. roll end
    return "|cff" .. hex .. label .. "|r"
end

function SessionHistoryFrame:_RefreshDetail()
    local f = self._frame
    if not f then return end
    local theme      = ns.Theme:GetCurrent()
    local rightChild = f._rightChild

    _HidePoolFrom(_detailBossPool, 1)
    _HidePoolFrom(_detailItemPool, 1)
    _HidePoolFrom(_detailRollPool, 1)

    local sess = _selectedSessionId and _FindSession(_selectedSessionId)
    if not sess then
        f._detailHdr:Hide()
        f._deleteBtn:Hide()
        f._emptyLabel:SetText(#_GetSortedSessions() == 0 and "No session history recorded yet." or "Select a session to view details.")
        f._emptyLabel:Show()
        rightChild:SetHeight(math.max(1, f._rightScroll:GetHeight()))
        return
    end

    f._emptyLabel:Hide()
    f._detailHdr:Show()
    local isActive = ns.Session and ns.Session.activeSessionId == sess.id
    f._deleteBtn:SetShown(not isActive)

    -- Header
    f._hdrDate:SetText(_FormatLongDate(sess.startTime))
    local endStr = sess.endTime and _FormatTime(sess.endTime) or "…"
    f._hdrSpan:SetText(_FormatTime(sess.startTime) .. " – " .. endStr .. " · " .. _FormatDuration(sess.startTime, sess.endTime))
    f._sessionLeader = sess.leader
    f._hdrLeader:SetText(ns.StripRealm(sess.leader or "Unknown"))
    local masters = sess.lootMasters or {}
    f._sessionMasters = masters
    if #masters == 0 then
        f._hdrMasters:SetText("none")
    else
        local names = {}
        for _, m in ipairs(masters) do tinsert(names, ns.StripRealm(m)) end
        f._hdrMasters:SetText(table.concat(names, ", "))
    end
    f._hdrMasters:SetWidth(math.max(40, rightChild:GetWidth() - INSET * 2 - f._hdrSpan:GetStringWidth()
        - f._hdrLeaderLbl:GetStringWidth() - f._hdrLeader:GetStringWidth() - f._hdrLMLbl:GetStringWidth() - 60 - 110))

    -- Entries grouped by boss
    local entries   = _GetEntriesForSession(_selectedSessionId)
    local bossItems = {}
    for _, e in ipairs(entries) do
        local boss = e.bossName or "Unknown"
        bossItems[boss] = bossItems[boss] or {}
        tinsert(bossItems[boss], e)
    end
    local orderedBosses, seen = {}, {}
    for _, b in ipairs(sess.bosses or {}) do
        if not seen[b] then seen[b] = true; orderedBosses[#orderedBosses + 1] = b end
    end
    for boss in pairs(bossItems) do
        if not seen[boss] then seen[boss] = true; orderedBosses[#orderedBosses + 1] = boss end
    end

    local bossIdx, itemIdx, rollIdx = 0, 0, 0
    local yOffset = -DETAIL_HEADER_H

    for _, boss in ipairs(orderedBosses) do
        bossIdx = bossIdx + 1
        local hdr = _AcquireBossHdr(rightChild, _detailBossPool, bossIdx)
        hdr:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 0, yOffset)
        hdr:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, yOffset)
        local itemList = bossItems[boss]
        local suffix = (itemList and #itemList > 0) and "" or ("  |cff" .. theme.columnHeaderHex .. ns.Track("no items awarded") .. "|r")
        hdr.lbl:SetText("|cff" .. theme.sectionHeaderHex .. ns.Track(boss) .. "|r" .. suffix)
        hdr.rule:SetVertexColor(C(theme, "dividerColor"))
        yOffset = yOffset - BOSS_HDR_H

        for _, entry in ipairs(itemList or {}) do
            itemIdx = itemIdx + 1
            local row = _AcquireItemRow(rightChild, _detailItemPool, itemIdx)
            row:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 0, yOffset)
            row:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, yOffset)
            row.hl:SetVertexColor(C(theme, "highlightColor"))

            local itemLink = entry.itemLink
            local itemName, quality = itemLink or "Unknown", nil
            if itemLink and itemLink:find("|H") then
                itemName = itemLink:match("|h%[(.-)%]|h") or itemLink
                local _, _, q, _, _, _, _, _, _, icon = ns.GetItemInfo(itemLink)
                quality = q
                if icon then row.icon:SetTexture(icon); row.icon:Show(); row.iconEdge:Show()
                else row.icon:Hide(); row.iconEdge:Hide() end
            else
                row.icon:Hide(); row.iconEdge:Hide()
            end
            local qr, qg, qb = ns.GetItemQualityColor(quality or 1)
            row.itemLbl:SetText(itemName)
            row.itemLbl:SetTextColor(qr, qg, qb)
            row.iconEdge:SetBackdropBorderColor(qr, qg, qb, 0.6)
            row._link = itemLink

            row.winnerLbl:SetText(ns.StripRealm(entry.player or "Unknown"))
            row.winnerLbl:SetTextColor(C(theme, "textColor"))
            row._playerName = entry.player
            local mainId = ns.PlayerLinks:ResolveIdentity(entry.player)
            row.playerHit:SetShown(mainId and mainId ~= entry.player)

            row.choiceLbl:SetText(_ChoiceText(theme, entry.rollType, entry.rollValue))
            yOffset = yOffset - ITEM_ROW_H

            -- Runners-up summary: "Miralune Greed 88 · Erevost Need 71 · 6 passed"
            local rolls = entry.rolls
            if rolls and #rolls > 0 then
                rollIdx = rollIdx + 1
                local rrow = _AcquireRollRow(rightChild, _detailRollPool, rollIdx)
                rrow:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 0, yOffset)
                rrow:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, yOffset)
                rrow.hair:SetVertexColor(C(theme, "histSepColor"))
                local parts, passed = {}, 0
                for _, r in ipairs(rolls) do
                    if ns.NamesMatch(r.player, entry.player) then
                        -- winner already shown on the item row
                    elseif r.choice == "Pass" then
                        passed = passed + 1
                    else
                        local piece = ns.StripRealm(r.player) .. " " .. (r.choice or "?") .. " " .. (r.roll or 0)
                        if r.tiebreakerRoll then piece = piece .. " (tb " .. r.tiebreakerRoll .. ")" end
                        tinsert(parts, piece)
                    end
                end
                if passed > 0 then tinsert(parts, passed .. " passed") end
                rrow.lbl:SetText(#parts > 0 and table.concat(parts, " · ") or "No other rolls")
                rrow.lbl:SetTextColor(C(theme, "textMutedColor"))
                yOffset = yOffset - ROLL_ROW_H
            end
        end
    end

    _HidePoolFrom(_detailBossPool, bossIdx + 1)
    _HidePoolFrom(_detailItemPool, itemIdx + 1)
    _HidePoolFrom(_detailRollPool, rollIdx + 1)
    rightChild:SetHeight(math.max(1, -yOffset + INSET))
end

------------------------------------------------------------------------
-- Delete
------------------------------------------------------------------------
function SessionHistoryFrame:_ExecuteDelete()
    local sid = self._deleteSid
    self._deleteSid = nil
    if not sid then return end

    local sessions = ns.db.global.sessionHistory or {}
    for i = #sessions, 1, -1 do
        if sessions[i].id == sid then table.remove(sessions, i); break end
    end
    local history = ns.db.global.lootHistory or {}
    for i = #history, 1, -1 do
        if history[i].sessionId == sid then table.remove(history, i) end
    end

    -- Propagate to the group whenever we are a group leader/officer, active
    -- session or not (history is usually pruned between sessions).
    if ns.IsLeader() and (IsInGroup() or IsInRaid()) then
        ns.Comm:Send(ns.Comm.MSG.SESSION_DELETE, { sessionId = sid })
    end

    if _selectedSessionId == sid then _selectedSessionId = nil end
    self:Refresh()
end

-- Called by Session:OnSessionDeleteReceived when a remote delete arrives.
function SessionHistoryFrame:OnSessionDeleted(sid)
    if _selectedSessionId == sid then _selectedSessionId = nil end
    if self:IsVisible() then self:Refresh() end
end

------------------------------------------------------------------------
-- Theme
------------------------------------------------------------------------
function SessionHistoryFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f.leftBg:SetVertexColor(C(theme, "panelBgColor"))
    f.divider:SetVertexColor(C(theme, "dividerColor"))
    f._leftEmptyLabel:SetTextColor(C(theme, "textDimColor"))
    f._emptyLabel:SetTextColor(C(theme, "textDimColor"))
    f._detailHdr.rule:SetVertexColor(C(theme, "dividerColor"))
    f._hdrDate:SetTextColor(C(theme, "textColor"))
    f._hdrSpan:SetTextColor(C(theme, "textMutedColor"))
    f._hdrLeaderLbl:SetTextColor(C(theme, "textMutedColor"))
    f._hdrLeader:SetTextColor(C(theme, "accentHiColor"))
    f._hdrLMLbl:SetTextColor(C(theme, "textMutedColor"))
    f._hdrMasters:SetTextColor(C(theme, "textColor"))
    -- Delete: red-stroked outline at 40%, red label
    local r, g, b = C(theme, "timerBarLowColor")
    f._deleteBtn:SetStrokeColor({ r, g, b, 0.4 })
    f._deleteBtn._text:SetTextColor(r, g, b)
    if f:IsShown() then
        self:_RefreshSessionList()
        self:_RefreshDetail()
    end
end
