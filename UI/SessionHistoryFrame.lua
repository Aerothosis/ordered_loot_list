------------------------------------------------------------------------
-- OrderedLootList  –  UI/SessionHistoryFrame.lua
-- Session history viewer: lists past loot sessions on the left, and
-- shows session detail (bosses + items) on the right.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local SessionHistoryFrame = {}
ns.SessionHistoryFrame    = SessionHistoryFrame

------------------------------------------------------------------------
-- Layout constants
------------------------------------------------------------------------
local FRAME_WIDTH       = 700
local FRAME_HEIGHT      = 520
local HEADER_HEIGHT     = 40   -- title + close button
local LEFT_PANEL_WIDTH  = 220
local DIVIDER_WIDTH     = 2
local SESSION_ROW_H     = 44   -- two-line session rows
local BOSS_HDR_H        = 22
local ITEM_ROW_H        = 20
local DETAIL_HEADER_H   = 70   -- space for session metadata at top of right panel
local PAD                = 14

------------------------------------------------------------------------
-- Module-level state
------------------------------------------------------------------------
SessionHistoryFrame._frame        = nil
local _selectedSessionId          = nil
local _sessionRowPool             = {}
local _detailBossPool             = {}  -- boss header frames
local _detailItemPool             = {}  -- item row frames

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function _FormatDate(ts)
    return ts and date("%b %d, %Y", ts) or "—"
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
    if h > 0 then
        return h .. "h " .. m .. "m"
    else
        return m .. "m"
    end
end

local function _FindSession(sid)
    local sessions = ns.db.global.sessionHistory or {}
    for _, s in ipairs(sessions) do
        if s.id == sid then return s end
    end
end

local function _GetSortedSessions()
    local sessions = ns.db.global.sessionHistory or {}
    local out = {}
    for _, s in ipairs(sessions) do out[#out + 1] = s end
    table.sort(out, function(a, b) return (a.startTime or 0) > (b.startTime or 0) end)
    return out
end

local function _GetEntriesForSession(sid)
    local out = {}
    local history = ns.db.global.lootHistory or {}
    for _, e in ipairs(history) do
        if e.sessionId == sid then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)
    return out
end

------------------------------------------------------------------------
-- Row pool helpers
------------------------------------------------------------------------
local function _AcquireSessionRow(parent, pool, idx)
    local row = pool[idx]
    if not row then
        local f = CreateFrame("Button", nil, parent)
        f:SetHeight(SESSION_ROW_H)

        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(f)
        f._bg = bg

        local line1 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line1:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
        line1:SetPoint("RIGHT",   f, "RIGHT",  -4, 0)
        line1:SetJustifyH("LEFT")
        f._line1 = line1

        local line2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        line2:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22)
        line2:SetPoint("RIGHT",   f, "RIGHT",  -4, 0)
        line2:SetJustifyH("LEFT")
        f._line2 = line2

        pool[idx] = f
        row = f
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

        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("LEFT", f, "LEFT", 6, 0)
        lbl:SetPoint("RIGHT", f, "RIGHT", -4, 0)
        lbl:SetJustifyH("LEFT")
        f._lbl = lbl

        pool[idx] = f
        f = pool[idx]
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

        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", f, "LEFT", 10, 0)
        f._icon = icon

        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        lbl:SetPoint("RIGHT", f, "RIGHT", -4, 0)
        lbl:SetJustifyH("LEFT")
        f._lbl = lbl

        pool[idx] = f
        f = pool[idx]
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

    local f = CreateFrame("Frame", "OLLSessionHistoryFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        ns.SaveFramePosition("SessionHistoryFrame", frame)
    end)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("Session History")
    f._title = title

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() SessionHistoryFrame:Hide() end)

    -- Left scroll frame
    local leftScroll = CreateFrame("ScrollFrame", "OLLSessHistLeftScroll", f, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT",    f, "TOPLEFT",    PAD, -(HEADER_HEIGHT))
    leftScroll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD)
    leftScroll:SetWidth(LEFT_PANEL_WIDTH - 20)
    f._leftScroll = leftScroll

    local leftChild = CreateFrame("Frame", nil, leftScroll)
    leftChild:SetWidth(LEFT_PANEL_WIDTH - 22)
    leftChild:SetHeight(1)
    leftScroll:SetScrollChild(leftChild)
    f._leftChild = leftChild

    -- Divider
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(theme.dividerColor))
    divider:SetWidth(DIVIDER_WIDTH)
    divider:SetPoint("TOPLEFT",    f, "TOPLEFT", PAD + LEFT_PANEL_WIDTH, -(HEADER_HEIGHT))
    divider:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD + LEFT_PANEL_WIDTH, PAD)
    f._divider = divider

    -- Right scroll frame
    local rightX = PAD + LEFT_PANEL_WIDTH + DIVIDER_WIDTH + 6
    local rightScroll = CreateFrame("ScrollFrame", "OLLSessHistRightScroll", f, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT",     f, "TOPLEFT",     rightX, -(HEADER_HEIGHT))
    rightScroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30,     PAD)
    f._rightScroll = rightScroll

    local rightChild = CreateFrame("Frame", nil, rightScroll)
    rightChild:SetWidth(FRAME_WIDTH - rightX - 32)
    rightChild:SetHeight(1)
    rightScroll:SetScrollChild(rightChild)
    f._rightChild = rightChild

    -- Empty state label for right panel
    local emptyLabel = rightChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyLabel:SetPoint("CENTER", rightChild, "CENTER", 0, 80)
    emptyLabel:SetText("Select a session to view details.")
    emptyLabel:Hide()
    f._emptyLabel = emptyLabel

    -- Session detail header (shown when a session is selected)
    local detailHdr = CreateFrame("Frame", nil, rightChild)
    detailHdr:SetPoint("TOPLEFT",  rightChild, "TOPLEFT",  0, 0)
    detailHdr:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, 0)
    detailHdr:SetHeight(DETAIL_HEADER_H)
    detailHdr:Hide()
    f._detailHdr = detailHdr

    local hdrLine1 = detailHdr:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hdrLine1:SetPoint("TOPLEFT", detailHdr, "TOPLEFT", 4, -4)
    hdrLine1:SetPoint("RIGHT",   detailHdr, "RIGHT",  -4, 0)
    hdrLine1:SetJustifyH("LEFT")
    f._hdrLine1 = hdrLine1

    local hdrLine2 = detailHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrLine2:SetPoint("TOPLEFT", detailHdr, "TOPLEFT", 4, -22)
    hdrLine2:SetPoint("RIGHT",   detailHdr, "RIGHT",  -4, 0)
    hdrLine2:SetJustifyH("LEFT")
    f._hdrLine2 = hdrLine2

    local hdrLine3 = detailHdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrLine3:SetPoint("TOPLEFT", detailHdr, "TOPLEFT", 4, -38)
    hdrLine3:SetPoint("RIGHT",   detailHdr, "RIGHT",  -4, 0)
    hdrLine3:SetJustifyH("LEFT")
    f._hdrLine3 = hdrLine3

    self._frame = f
    return f
end

------------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------------
function SessionHistoryFrame:Show()
    local f = self:GetFrame()
    f:Show()
    ns.RaiseFrame(f)
    ns.RestoreFramePosition("SessionHistoryFrame", f)
    self:Refresh()
end

function SessionHistoryFrame:Hide()
    if self._frame then
        ns.SaveFramePosition("SessionHistoryFrame", self._frame)
        self._frame:Hide()
    end
end

function SessionHistoryFrame:Toggle()
    if self._frame and self._frame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function SessionHistoryFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

------------------------------------------------------------------------
-- Refresh entry points
------------------------------------------------------------------------
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
    local rowW      = leftChild:GetWidth()

    for i, sess in ipairs(sessions) do
        local row = _AcquireSessionRow(leftChild, _sessionRowPool, i)
        row:SetWidth(rowW)
        row:SetPoint("TOPLEFT", leftChild, "TOPLEFT", 0, -(i - 1) * SESSION_ROW_H)

        -- Highlight selected
        local isSelected = (sess.id == _selectedSessionId)
        if isSelected then
            row._bg:SetColorTexture(unpack(theme.selectedColor))
        else
            row._bg:SetColorTexture(0, 0, 0, 0)
        end

        -- Line 1: date
        row._line1:SetText(_FormatDate(sess.startTime))
        row._line1:SetTextColor(1, 1, 1, 1)

        -- Line 2: start time · N bosses
        local bossCount = #(sess.bosses or {})
        local bossStr   = bossCount == 1 and "1 boss" or (bossCount .. " bosses")
        row._line2:SetText(_FormatTime(sess.startTime) .. "  ·  " .. bossStr)
        row._line2:SetTextColor(unpack(theme.bossTextColor))

        -- Hover highlight
        row:SetScript("OnEnter", function(btn)
            if sess.id ~= _selectedSessionId then
                btn._bg:SetColorTexture(unpack(theme.highlightColor))
            end
        end)
        row:SetScript("OnLeave", function(btn)
            if sess.id ~= _selectedSessionId then
                btn._bg:SetColorTexture(0, 0, 0, 0)
            end
        end)
        row:SetScript("OnClick", function()
            _selectedSessionId = sess.id
            self:_RefreshSessionList()
            self:_RefreshDetail()
        end)
    end

    _HidePoolFrom(_sessionRowPool, #sessions + 1)
    leftChild:SetHeight(math.max(1, #sessions * SESSION_ROW_H))
end

------------------------------------------------------------------------
-- Right panel: session detail
------------------------------------------------------------------------
function SessionHistoryFrame:_RefreshDetail()
    local f = self._frame
    if not f then return end

    local theme      = ns.Theme:GetCurrent()
    local rightChild = f._rightChild

    -- Hide all pooled items to start
    _HidePoolFrom(_detailBossPool, 1)
    _HidePoolFrom(_detailItemPool, 1)

    if not _selectedSessionId then
        f._detailHdr:Hide()
        f._emptyLabel:Show()
        rightChild:SetHeight(math.max(1, f._rightScroll:GetHeight()))
        return
    end

    local sess = _FindSession(_selectedSessionId)
    if not sess then
        f._detailHdr:Hide()
        f._emptyLabel:Show()
        rightChild:SetHeight(math.max(1, f._rightScroll:GetHeight()))
        return
    end

    f._emptyLabel:Hide()
    f._detailHdr:Show()

    -- Header line 1: date range + duration
    local dateStr     = _FormatDate(sess.startTime)
    local startStr    = _FormatTime(sess.startTime)
    local endStr      = sess.endTime and _FormatTime(sess.endTime) or "?"
    local durationStr = _FormatDuration(sess.startTime, sess.endTime)
    f._hdrLine1:SetText(dateStr .. "   " .. startStr .. " – " .. endStr .. "  (" .. durationStr .. ")")

    -- Header line 2: leader
    local leaderStr = "|cff" .. theme.columnHeaderHex .. "Leader:|r " .. (sess.leader or "Unknown")
    f._hdrLine2:SetText(leaderStr)

    -- Header line 3: loot masters
    local masters = sess.lootMasters or {}
    local masterStr
    if #masters == 0 then
        masterStr = "None"
    else
        masterStr = table.concat(masters, ", ")
    end
    local label = #masters == 1 and "Loot Master:" or "Loot Masters:"
    f._hdrLine3:SetText("|cff" .. theme.columnHeaderHex .. label .. "|r " .. masterStr)

    -- Collect loot entries grouped by boss
    local entries    = _GetEntriesForSession(_selectedSessionId)
    local bossItems  = {}
    for _, e in ipairs(entries) do
        local boss = e.bossName or "Unknown"
        if not bossItems[boss] then bossItems[boss] = {} end
        bossItems[boss][#bossItems[boss] + 1] = e
    end

    -- Determine boss order from session record (append any orphan bosses from entries)
    local orderedBosses = {}
    local seen          = {}
    for _, b in ipairs(sess.bosses or {}) do
        if not seen[b] then seen[b] = true; orderedBosses[#orderedBosses + 1] = b end
    end
    for boss in pairs(bossItems) do
        if not seen[boss] then seen[boss] = true; orderedBosses[#orderedBosses + 1] = boss end
    end

    -- Layout boss sections below the header
    local bossIdx  = 0
    local itemIdx  = 0
    local yOffset  = -DETAIL_HEADER_H

    for _, boss in ipairs(orderedBosses) do
        bossIdx = bossIdx + 1
        local hdr = _AcquireBossHdr(rightChild, _detailBossPool, bossIdx)
        hdr:SetPoint("TOPLEFT",  rightChild, "TOPLEFT",  0, yOffset)
        hdr:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, yOffset)
        local itemList = bossItems[boss]
        local countStr = itemList and #itemList > 0
            and (" (" .. #itemList .. (#itemList == 1 and " item)" or " items)"))
            or " (no items awarded)"
        hdr._lbl:SetText("|cff" .. theme.sectionHeaderHex .. boss .. "|r" .. "|cffaaaaaa" .. countStr .. "|r")
        yOffset = yOffset - BOSS_HDR_H

        if itemList then
            for _, entry in ipairs(itemList) do
                itemIdx = itemIdx + 1
                local row = _AcquireItemRow(rightChild, _detailItemPool, itemIdx)
                row:SetPoint("TOPLEFT",  rightChild, "TOPLEFT",  0, yOffset)
                row:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, yOffset)

                -- Item icon
                local itemId = entry.itemId or 0
                if itemId and itemId > 0 then
                    local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
                    if icon then
                        row._icon:SetTexture(icon)
                        row._icon:Show()
                    else
                        row._icon:Hide()
                    end
                else
                    row._icon:Hide()
                end

                -- Item link + winner
                local displayLink = entry.itemLink or "Unknown"
                local player      = entry.player or "Unknown"
                local rollType    = entry.rollType or ""
                local suffix      = ""
                if rollType == "Disenchant" then
                    suffix = " |cffaaaaaa(DE)|r"
                elseif rollType == "Passed" then
                    suffix = " |cffaaaaaa(Passed)|r"
                end
                row._lbl:SetText(displayLink .. " → " .. player .. suffix)

                yOffset = yOffset - ITEM_ROW_H
            end
        end
    end

    _HidePoolFrom(_detailBossPool, bossIdx + 1)
    _HidePoolFrom(_detailItemPool, itemIdx + 1)

    rightChild:SetHeight(math.max(1, -yOffset + PAD))
end

------------------------------------------------------------------------
-- Theme
------------------------------------------------------------------------
function SessionHistoryFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end

    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    f._divider:SetColorTexture(unpack(theme.dividerColor))

    -- Re-draw rows with updated colors
    if f:IsShown() then
        self:_RefreshSessionList()
        self:_RefreshDetail()
    end
end
