------------------------------------------------------------------------
-- OrderedLootList  –  UI/SessionResumeFrame.lua  (Ledger)
-- Session picker (420 wide): shown when the leader starts a session but
-- several resumable sessions exist in the current lockout.  44px title
-- bar, one-line explanation, 60px two-line rows each with a Resume button
-- (newest = brass primary, others outlined), 52px footer with a quiet
-- "Start fresh instead".  The X always cancels; it never starts fresh.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local SessionResumeFrame = {}
ns.SessionResumeFrame    = SessionResumeFrame

local FRAME_W    = 420
local ROW_H      = 60
local HEADER_H   = 44
local EXPLAIN_H  = 40
local FOOTER_H   = 52
local MAX_ROWS   = 4
local INSET      = 16

SessionResumeFrame._frame    = nil
SessionResumeFrame._rowPool  = {}

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

local function _CountEntriesForSession(sid)
    local n = 0
    for _, e in ipairs(ns.db.global.lootHistory or {}) do
        if e.sessionId == sid then n = n + 1 end
    end
    return n
end

local function _RowDate(ts)
    if not ts then return "—" end
    local today = date("%Y-%m-%d")
    if date("%Y-%m-%d", ts) == today then return "Tonight · " .. date("%H:%M", ts) end
    return date("%b %d · %H:%M", ts)
end

------------------------------------------------------------------------
-- Row pool
------------------------------------------------------------------------
local function _AcquireRow(parent, pool, idx)
    local row = pool[idx]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetHeight(ROW_H)
        row.hair = ns.MakeHairline(row, "histSepColor")
        row.hair:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0); row.hair:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        row.resumeBtn = ns.MakeButton(row, "outline", "Resume", 140, 32)
        row.resumeBtn:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
        row.line1 = row:CreateFontString(nil, "OVERLAY")
        row.line1:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        row.line1:SetPoint("TOPLEFT", row, "TOPLEFT", INSET, -13)
        row.line1:SetPoint("RIGHT", row.resumeBtn, "LEFT", -12, 0)
        row.line1:SetJustifyH("LEFT"); row.line1:SetWordWrap(false)
        row.line2 = row:CreateFontString(nil, "OVERLAY")
        row.line2:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
        row.line2:SetPoint("TOPLEFT", row.line1, "BOTTOMLEFT", 0, -5)
        row.line2:SetPoint("RIGHT", row.resumeBtn, "LEFT", -12, 0)
        row.line2:SetJustifyH("LEFT"); row.line2:SetWordWrap(false)
        pool[idx] = row
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
-- Frame
------------------------------------------------------------------------
function SessionResumeFrame:_GetFrame()
    if self._frame then return self._frame end
    local theme = ns.Theme:GetCurrent()

    local f = ns.MakeLedgerFrame("OLLSessionResumeFrame", FRAME_W, HEADER_H + EXPLAIN_H + 2 * ROW_H + FOOTER_H + 4,
        "SessionResumeFrame", { strata = "DIALOG", y = 60 })

    -- X always cancels: clear the pending list and hide, never start fresh
    f.header = ns.MakeHeaderBar(f, "Resume Session", nil, { height = HEADER_H, onClose = function()
        if ns.Session then ns.Session._pendingResumableSessions = nil end
        f:Hide()
    end })

    -- Explanation line
    f.explain = f:CreateFontString(nil, "OVERLAY")
    f.explain:SetFontObject(ns.Ledger.Fonts.OLLFontMeta)
    f.explain:SetPoint("TOPLEFT", f, "TOPLEFT", INSET, -(HEADER_H + 14))
    f.explain:SetPoint("RIGHT", f, "RIGHT", -INSET, 0)
    f.explain:SetJustifyH("LEFT")
    f.explainRule = ns.MakeHairline(f, "dividerColor")
    f.explainRule:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + EXPLAIN_H + 2))
    f.explainRule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(HEADER_H + EXPLAIN_H + 2))

    -- Footer
    local footer = ns.MakeBar(f, FOOTER_H, "barBgColorAlt", "TOP")
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.footer = footer
    local freshBtn = ns.MakeButton(footer, "quiet", "Start fresh instead", 200, 32)
    freshBtn:SetPoint("RIGHT", footer, "RIGHT", -(INSET - 2), 0)
    freshBtn:SetScript("OnClick", function()
        if ns.Session then ns.Session:_ExecuteStartFresh() end
    end)
    f._freshBtn = freshBtn

    -- Rows scroll
    local scroll = CreateFrame("ScrollFrame", "OLLSessionResumeScroll", f)
    f._scroll = scroll
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + EXPLAIN_H + 3))
    scroll:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 0)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * ROW_H)))
    end)
    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(FRAME_W - 4, 1)
    scroll:SetScrollChild(scrollChild)
    f._scroll = scroll
    f._scrollChild = scrollChild

    self._frame = f
    self:ApplyTheme(theme)
    return f
end

------------------------------------------------------------------------
-- Show / populate
-- @param sessions      array of session records (newest-first)
-- @param canStartFresh bool  true for the raid leader; false for LM-only
------------------------------------------------------------------------
function SessionResumeFrame:Show(sessions, canStartFresh)
    local f     = self:_GetFrame()
    local theme = ns.Theme:GetCurrent()
    local child = f._scrollChild

    local n = #sessions
    if n == 0 then self:Hide(); return end

    -- The footer only exists for the raid leader; when it is hidden the
    -- rows take its space (the height maths below already assumes that).
    canStartFresh = canStartFresh and true or false
    f._freshBtn:SetShown(canStartFresh)
    f.footer:SetShown(canStartFresh)
    f._scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, canStartFresh and (FOOTER_H + 2) or 4)
    local words = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten" }
    f.explain:SetText(string.format("%s %s from this lockout %s still resumable. Loot counts carry over.",
        words[n] or tostring(n), n == 1 and "session" or "sessions", n == 1 and "is" or "are"))

    local visibleRows = math.min(n, MAX_ROWS)
    local frameH = HEADER_H + EXPLAIN_H + visibleRows * ROW_H + (canStartFresh and FOOTER_H or 4) + 4
    f:SetSize(FRAME_W, frameH)
    child:SetHeight(math.max(1, n * ROW_H))

    for i, sess in ipairs(sessions) do
        local row = _AcquireRow(child, self._rowPool, i)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * ROW_H)

        local bosses = sess.bosses or {}
        local bossNames = #bosses > 0 and table.concat(bosses, ", ") or "no bosses"
        row.line1:SetText(_RowDate(sess.startTime) .. " — " .. bossNames)
        row.line1:SetTextColor(C(theme, "textColor"))
        local items = _CountEntriesForSession(sess.id)
        row.line2:SetText(items .. (items == 1 and " item awarded" or " items awarded")
            .. " · leader " .. ns.StripRealm(sess.leader or "?"))
        row.line2:SetTextColor(C(theme, "textMutedColor"))
        row.hair:SetVertexColor(C(theme, "histSepColor"))

        row.resumeBtn:SetStyle(i == 1 and "primary" or "outline")
        local capturedSess = sess
        row.resumeBtn:SetScript("OnClick", function()
            if ns.Session then ns.Session:_ExecuteResumeFromList(capturedSess) end
        end)
    end
    _HideRowsFrom(self._rowPool, n + 1)

    ns.RaiseFrame(f)
    f:Show()
end

function SessionResumeFrame:Hide()
    if ns.Session then ns.Session._pendingResumableSessions = nil end
    if self._frame then self._frame:Hide() end
end

------------------------------------------------------------------------
-- Theme
------------------------------------------------------------------------
function SessionResumeFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f.explain:SetTextColor(C(theme, "textMutedColor"))
    f.explainRule:SetVertexColor(C(theme, "dividerColor"))
    for _, row in ipairs(self._rowPool) do
        if row:IsShown() then
            row.line1:SetTextColor(C(theme, "textColor"))
            row.line2:SetTextColor(C(theme, "textMutedColor"))
            row.hair:SetVertexColor(C(theme, "histSepColor"))
        end
    end
end
