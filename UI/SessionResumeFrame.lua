------------------------------------------------------------------------
-- OrderedLootList  –  UI/SessionResumeFrame.lua
-- Session picker popup: shown when the leader tries to start a new
-- session but multiple resumable sessions exist in the current weekly
-- lockout.  Presents a list with date, boss info, and a Resume button
-- per entry, plus a "Start Fresh" button at the bottom.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local SessionResumeFrame = {}
ns.SessionResumeFrame    = SessionResumeFrame

------------------------------------------------------------------------
-- Layout constants
------------------------------------------------------------------------
local FRAME_W    = 400
local ROW_H      = 56   -- height per session row
local PAD        = 14
local BTN_H      = 26
local HEADER_H   = 40
local FOOTER_H   = BTN_H + PAD * 2
local MAX_ROWS   = 6    -- max visible rows before scrolling

------------------------------------------------------------------------
-- Module-level state
------------------------------------------------------------------------
SessionResumeFrame._frame    = nil
SessionResumeFrame._rowPool  = {}

------------------------------------------------------------------------
-- Row pool
------------------------------------------------------------------------
local function _AcquireRow(parent, pool, idx)
    local row = pool[idx]
    if not row then
        local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        f:SetHeight(ROW_H)

        -- Two-line text block
        local line1 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line1:SetPoint("TOPLEFT",  f, "TOPLEFT",  PAD, -10)
        line1:SetPoint("RIGHT",    f, "RIGHT",   -110,   0)
        line1:SetJustifyH("LEFT")
        f._line1 = line1

        local line2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        line2:SetPoint("TOPLEFT",  f, "TOPLEFT",  PAD, -26)
        line2:SetPoint("RIGHT",    f, "RIGHT",   -110,   0)
        line2:SetJustifyH("LEFT")
        f._line2 = line2

        -- Resume button
        local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        btn:SetSize(90, BTN_H)
        btn:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
        btn:SetText("Resume")
        f._resumeBtn = btn

        -- Separator line at the bottom of the row
        local sep = f:CreateTexture(nil, "ARTWORK")
        sep:SetHeight(1)
        sep:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  PAD,  0)
        sep:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 0)
        f._sep = sep

        pool[idx] = f
        row = f
    end
    row:SetParent(parent)
    row:ClearAllPoints()
    row:Show()
    return row
end

local function _HideRowsFrom(pool, fromIdx)
    for i = fromIdx, #pool do
        if pool[i] then pool[i]:Hide() end
    end
end

------------------------------------------------------------------------
-- Lazy frame creation
------------------------------------------------------------------------
function SessionResumeFrame:_GetFrame()
    if self._frame then return self._frame end

    local theme = ns.Theme:GetCurrent()

    local f = CreateFrame("Frame", "OLLSessionResumeFrame", UIParent, "BackdropTemplate")
    f:SetWidth(FRAME_W)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
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
    f:SetScript("OnDragStop",  function(frm)
        frm:StopMovingOrSizing()
        ns.SaveFramePosition("SessionResumeFrame", frm)
    end)
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(frm) ns.RaiseFrame(frm) end)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("Resume Session?")
    f._title = title

    -- Divider below title
    local titleDiv = f:CreateTexture(nil, "ARTWORK")
    titleDiv:SetHeight(1)
    titleDiv:SetPoint("TOPLEFT",  f, "TOPLEFT",  PAD, -HEADER_H)
    titleDiv:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -HEADER_H)
    titleDiv:SetColorTexture(unpack(theme.dividerColor))
    f._titleDiv = titleDiv

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        if ns.Session then ns.Session:_ExecuteStartFresh() end
    end)

    -- Scroll child (holds the rows)
    local scrollChild = CreateFrame("Frame", nil, f)
    f._scrollChild = scrollChild

    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", "OLLSessionResumeScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     f, "TOPLEFT",     PAD,         -(HEADER_H + 2))
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + 20), FOOTER_H)
    scroll:SetScrollChild(scrollChild)
    f._scroll = scroll

    -- "Start Fresh" button
    local freshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    freshBtn:SetSize(110, BTN_H)
    freshBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
    freshBtn:SetText("Start Fresh")
    freshBtn:SetScript("OnClick", function()
        if ns.Session then ns.Session:_ExecuteStartFresh() end
    end)
    f._freshBtn = freshBtn

    ns.RestoreFramePosition("SessionResumeFrame", f)
    self._frame = f
    return f
end

------------------------------------------------------------------------
-- Show / populate
------------------------------------------------------------------------
function SessionResumeFrame:Show(sessions)
    local f     = self:_GetFrame()
    local theme = ns.Theme:GetCurrent()
    local child = f._scrollChild

    local visibleRows = math.min(#sessions, MAX_ROWS)
    local scrollH     = visibleRows * ROW_H
    local frameH      = HEADER_H + scrollH + FOOTER_H + 10
    f:SetHeight(frameH)
    child:SetSize(FRAME_W - PAD * 2 - 20, #sessions * ROW_H)

    for i, sess in ipairs(sessions) do
        local row = _AcquireRow(child, self._rowPool, i)
        row:SetWidth(child:GetWidth())
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * ROW_H)

        -- Date label (line 1)
        local dateStr = date("%b %d, %Y  %H:%M", sess.startTime)
        row._line1:SetText(dateStr)
        row._line1:SetTextColor(1, 1, 1, 1)

        -- Boss info (line 2)
        local bossCount = #(sess.bosses or {})
        local bossLabel = bossCount == 1 and "1 boss" or (bossCount .. " bosses")
        local bossNames = bossCount > 0 and table.concat(sess.bosses, ", ") or "None"
        if #bossNames > 50 then bossNames = bossNames:sub(1, 47) .. "..." end
        row._line2:SetText(bossLabel .. "  ·  " .. bossNames)
        row._line2:SetTextColor(unpack(theme.bossTextColor))

        -- Resume button callback — capture sess by value
        local capturedSess = sess
        row._resumeBtn:SetScript("OnClick", function()
            if ns.Session then ns.Session:_ExecuteResumeFromList(capturedSess) end
        end)

        -- Separator color
        row._sep:SetColorTexture(unpack(theme.dividerColor))
    end

    _HideRowsFrom(self._rowPool, #sessions + 1)

    f:SetFrameStrata("DIALOG")
    ns.RaiseFrame(f)
    f:Show()
end

------------------------------------------------------------------------
-- Hide
------------------------------------------------------------------------
function SessionResumeFrame:Hide()
    if self._frame then self._frame:Hide() end
end

------------------------------------------------------------------------
-- Apply theme
------------------------------------------------------------------------
function SessionResumeFrame:ApplyTheme(theme)
    if not self._frame then return end
    local f = self._frame
    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    f._titleDiv:SetColorTexture(unpack(theme.dividerColor))
    for _, row in ipairs(self._rowPool) do
        if row and row:IsShown() then
            row._line2:SetTextColor(unpack(theme.bossTextColor))
            row._sep:SetColorTexture(unpack(theme.dividerColor))
        end
    end
end
