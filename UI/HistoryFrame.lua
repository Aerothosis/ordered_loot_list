------------------------------------------------------------------------
-- OrderedLootList  –  UI/HistoryFrame.lua  (Ledger)
-- Loot history viewer (800x520): 44px title bar with the filtered award
-- total and Export CSV, 44px filter row (Player / Boss menus, From / To
-- date fields, Filter primary, Clear quiet), and a MakeTable of awards
-- grouped by raid night when sorted by date.
------------------------------------------------------------------------

local ns                       = _G.OLL_NS

local HistoryFrame             = {}
ns.HistoryFrame                = HistoryFrame

local FRAME_WIDTH              = 800
local FRAME_HEIGHT             = 520
local HEADER_H                 = 44
local FILTER_BAR_H             = 44
local ROW_H                    = 26
local INSET                    = 16

HistoryFrame._frame            = nil
HistoryFrame._sortKey          = "timestamp"
HistoryFrame._sortAsc          = false
HistoryFrame._filterPlayer     = ""
HistoryFrame._filterBoss       = ""
HistoryFrame._filterDateFrom   = nil
HistoryFrame._filterDateTo     = nil
HistoryFrame._displayedEntries = {}

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

local function _GetUniqueValues(field)
    local seen, out = {}, {}
    local history = ns.LootHistory:GetAll()
    if not history then return out end
    for _, e in ipairs(history) do
        local v = e[field]
        if v and v ~= "" and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    table.sort(out)
    return out
end

------------------------------------------------------------------------
-- Column definitions (Count sits before Choice; both numeric columns are
-- right-aligned and get MakeTable's trailing padding)
------------------------------------------------------------------------
local COLUMNS = {
    { key = "timestamp",      label = "Date",   width = 112 },
    { key = "bossName",       label = "Boss",   width = 104 },
    { key = "itemLink",       label = "Item",   width = "1fr" },
    { key = "player",         label = "Winner", width = 104 },
    { key = "lootCountAtWin", label = "Count",  width = 46, justify = "RIGHT" },
    { key = "rollType",       label = "Choice", width = 62 },
    { key = "rollValue",      label = "Roll",   width = 40, justify = "RIGHT" },
}

------------------------------------------------------------------------
-- Filter widgets
------------------------------------------------------------------------
-- Outlined button with a quiet label prefix and the current value:
-- "PLAYER  All ▾".  Opens a MenuUtil context menu listing getOptions().
local function _MakeFilterMenu(parent, prefix, width, getOptions, onChange)
    local btn = ns.MakeButton(parent, "outline", prefix, width, 30)
    btn._value = ""
    btn._text:ClearAllPoints()
    btn._text:SetPoint("LEFT", btn, "LEFT", 12, 0)
    local val = btn:CreateFontString(nil, "OVERLAY")
    val:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    val:SetPoint("LEFT", btn._text, "RIGHT", 8, 0)
    val:SetPoint("RIGHT", btn, "RIGHT", -22, 0)
    val:SetJustifyH("LEFT"); val:SetWordWrap(false)
    btn.valueText = val
    local caret = btn:CreateFontString(nil, "OVERLAY")
    caret:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    caret:SetPoint("RIGHT", btn, "RIGHT", -10, 0)
    caret:SetText("v")
    btn.caret = caret

    function btn:SetValue(v)
        self._value = v or ""
        self.valueText:SetText(self._value == "" and "All" or self._value)
    end
    function btn:GetValue() return self._value end
    function btn:ApplyThemeExtra(th)
        self._text:SetTextColor(C(th, "textMutedColor"))
        self.valueText:SetTextColor(C(th, "textColor"))
        self.caret:SetTextColor(C(th, "textMutedColor"))
    end
    btn:SetScript("OnClick", function(b)
        local options = getOptions()
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(b, function(_, root)
                for _, opt in ipairs(options) do
                    root:CreateButton(opt.label, function() b:SetValue(opt.value); onChange(opt.value) end)
                end
            end)
        else
            -- Fallback: cycle through the values
            local idx = 1
            for i, opt in ipairs(options) do if opt.value == b._value then idx = i end end
            local nextOpt = options[(idx % #options) + 1]
            if nextOpt then b:SetValue(nextOpt.value); onChange(nextOpt.value) end
        end
    end)
    btn:SetValue("")
    btn:ApplyThemeExtra(ns.Theme:GetCurrent())
    return btn
end

-- Outlined 30px date field: "FROM  2026-08-01" with a YYYY-MM-DD placeholder
local function _MakeDateField(parent, prefix, width, onEnter)
    local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    wrap:SetSize(width, 30)
    ns.SkinNineSlice(wrap, "btn")
    local lbl = wrap:CreateFontString(nil, "OVERLAY")
    lbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    lbl:SetPoint("LEFT", wrap, "LEFT", 12, 0)
    lbl:SetText(ns.Track(prefix))
    wrap.label = lbl
    local eb = CreateFrame("EditBox", nil, wrap)
    eb:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    eb:SetPoint("RIGHT", wrap, "RIGHT", -10, 0)
    eb:SetHeight(28)
    eb:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(10)
    wrap.editBox = eb
    local ph = eb:CreateFontString(nil, "OVERLAY")
    ph:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    ph:SetPoint("LEFT", eb, "LEFT", 0, 0)
    ph:SetText("YYYY-MM-DD")
    wrap.placeholder = ph
    local function updatePh() ph:SetShown(eb:GetText() == "" and not eb:HasFocus()) end
    eb:SetScript("OnEditFocusGained", function() ph:Hide(); wrap:ApplyThemeExtra(ns.Theme:GetCurrent(), true) end)
    eb:SetScript("OnEditFocusLost", function() updatePh(); wrap:ApplyThemeExtra(ns.Theme:GetCurrent(), false) end)
    eb:SetScript("OnTextChanged", updatePh)
    eb:SetScript("OnEnterPressed", function(e) onEnter(e:GetText()); e:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)
    eb:SetScript("OnEnter", function(e)
        GameTooltip:SetOwner(e, "ANCHOR_TOP")
        GameTooltip:SetText("Format: YYYY-MM-DD")
        GameTooltip:Show()
    end)
    eb:SetScript("OnLeave", GameTooltip_Hide)
    function wrap:GetText() return self.editBox:GetText() end
    function wrap:SetText(t) self.editBox:SetText(t or ""); updatePh() end
    function wrap:ApplyThemeExtra(th, focused)
        local hasValue = self.editBox:GetText() ~= ""
        self:SetBackdropBorderColor(C(th, (focused or hasValue) and "strokeColor" or "strokeDimColor"))
        self.label:SetTextColor(C(th, "textMutedColor"))
        self.editBox:SetTextColor(C(th, "textColor"))
        self.placeholder:SetTextColor(C(th, "textDimColor"))
    end
    wrap:ApplyThemeExtra(ns.Theme:GetCurrent(), false)
    updatePh()
    return wrap
end

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
function HistoryFrame:GetFrame()
    if self._frame then return self._frame end
    local theme = ns.Theme:GetCurrent()

    local f = ns.MakeLedgerFrame("OLLHistoryFrame", FRAME_WIDTH, FRAME_HEIGHT, "HistoryFrame", { strata = "HIGH" })

    -- Title bar: LOOT HISTORY · 148 awards · [EXPORT CSV] · X
    local header = ns.MakeHeaderBar(f, "Loot History", {
        { label = "Export CSV", tooltip = "Export the filtered rows as CSV", onClick = function() HistoryFrame:ShowExport() end },
    }, { height = HEADER_H, onClose = function() HistoryFrame:Hide() end })
    f.header = header

    -- Filter row
    local bar = ns.MakeBar(f, FILTER_BAR_H, "barBgColor", "BOTTOM")
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + 2))
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(HEADER_H + 2))
    f.filterBar = bar

    local playerDD = _MakeFilterMenu(bar, "Player", 150, function()
        local opts = { { value = "", label = "All" } }
        for _, v in ipairs(_GetUniqueValues("player")) do opts[#opts + 1] = { value = v, label = ns.StripRealm(v) } end
        return opts
    end, function(v) HistoryFrame._filterPlayer = v; HistoryFrame:Refresh() end)
    playerDD:SetPoint("LEFT", bar, "LEFT", INSET - 2, 0)
    f.playerDD = playerDD

    local bossDD = _MakeFilterMenu(bar, "Boss", 150, function()
        local opts = { { value = "", label = "All" } }
        for _, v in ipairs(_GetUniqueValues("bossName")) do opts[#opts + 1] = { value = v, label = v } end
        return opts
    end, function(v) HistoryFrame._filterBoss = v; HistoryFrame:Refresh() end)
    bossDD:SetPoint("LEFT", playerDD, "RIGHT", 8, 0)
    f.bossDD = bossDD

    local dateFromBox = _MakeDateField(bar, "From", 150, function(text)
        HistoryFrame._filterDateFrom = HistoryFrame:_ParseDate(text)
        HistoryFrame:Refresh()
    end)
    dateFromBox:SetPoint("LEFT", bossDD, "RIGHT", 8, 0)
    f.dateFromBox = dateFromBox

    local dateToBox = _MakeDateField(bar, "To", 136, function(text)
        HistoryFrame._filterDateTo = HistoryFrame:_ParseDate(text)
        HistoryFrame:Refresh()
    end)
    dateToBox:SetPoint("LEFT", dateFromBox, "RIGHT", 8, 0)
    f.dateToBox = dateToBox

    local clearBtn = ns.MakeButton(bar, "quiet", "Clear", 76, 30)
    clearBtn:SetPoint("RIGHT", bar, "RIGHT", -(INSET - 2), 0)
    clearBtn:SetScript("OnClick", function()
        f.playerDD:SetValue("")
        f.bossDD:SetValue("")
        f.dateFromBox:SetText("")
        f.dateToBox:SetText("")
        self._filterPlayer   = ""
        self._filterBoss     = ""
        self._filterDateFrom = nil
        self._filterDateTo   = nil
        self:Refresh()
    end)
    f.clearBtn = clearBtn

    local filterBtn = ns.MakeButton(bar, "primary", "Filter", 84, 30)
    filterBtn:SetPoint("RIGHT", clearBtn, "LEFT", -8, 0)
    filterBtn:SetScript("OnClick", function()
        self._filterDateFrom = self:_ParseDate(f.dateFromBox:GetText())
        self._filterDateTo   = self:_ParseDate(f.dateToBox:GetText())
        self:Refresh()
    end)
    f.filterBtn = filterBtn

    -- Table (header fixed, body scrolls)
    local tbl = ns.MakeTable(f, COLUMNS, { rowH = ROW_H, headerH = 24 })
    tbl:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + FILTER_BAR_H + 2))
    tbl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(HEADER_H + FILTER_BAR_H + 2))
    tbl:SetHeight(24)
    f.table = tbl
    self._table = tbl

    -- Sort buttons over the header labels
    f.columnHeaders = {}
    for _, col in ipairs(COLUMNS) do
        local hb = CreateFrame("Button", nil, tbl.header)
        hb:SetHeight(24)
        hb:SetPoint("LEFT", tbl.header.labels[col.key], "LEFT", -4, 0)
        hb:SetPoint("RIGHT", tbl.header.labels[col.key], "RIGHT", 4, 0)
        hb:SetScript("OnClick", function()
            if self._sortKey == col.key then
                self._sortAsc = not self._sortAsc
            else
                self._sortKey = col.key
                self._sortAsc = (col.key ~= "timestamp")
            end
            self:Refresh()
        end)
        f.columnHeaders[col.key] = hb
    end

    -- Body scroll: the table's body is re-parented into a scroll child so
    -- long histories scroll under the fixed header.
    local scrollFrame = CreateFrame("ScrollFrame", "OLLHistScroll", f)
    scrollFrame:SetPoint("TOPLEFT", tbl.header, "BOTTOMLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * ROW_H * 2)))
    end)
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 4, 1)
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame:SetScript("OnSizeChanged", function(sf, w) scrollChild:SetWidth(w) end)
    tbl.body:SetParent(scrollChild)
    tbl.body:ClearAllPoints()
    tbl.body:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, 0)
    tbl.body:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, 0)
    f.scrollFrame = scrollFrame
    f.scrollChild = scrollChild

    local empty = scrollChild:CreateFontString(nil, "OVERLAY")
    empty:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    empty:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", INSET, -14)
    empty:Hide()
    f.empty = empty

    f:Hide()
    self._frame = f
    self:ApplyTheme(theme)
    return f
end

------------------------------------------------------------------------
-- Theme
------------------------------------------------------------------------
function HistoryFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f.playerDD:ApplyThemeExtra(theme)
    f.bossDD:ApplyThemeExtra(theme)
    f.dateFromBox:ApplyThemeExtra(theme, false)
    f.dateToBox:ApplyThemeExtra(theme, false)
    f.empty:SetTextColor(C(theme, "textDimColor"))
    if self._exportDialog and self._exportDialog.ApplyThemeExtra then
        self._exportDialog:ApplyThemeExtra(theme)
    end
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------
local function _NightKey(ts)
    -- Raid nights that run past midnight stay in one group: shift by 6h
    return date("%Y-%m-%d", (ts or 0) - 6 * 3600)
end

function HistoryFrame:Refresh()
    local f = self:GetFrame()
    local theme = ns.Theme:GetCurrent()
    local tbl = self._table

    local entries = ns.LootHistory:GetFiltered({
        player   = self._filterPlayer,
        boss     = self._filterBoss,
        dateFrom = self._filterDateFrom,
        dateTo   = self._filterDateTo,
    })

    local sortKey, sortAsc = self._sortKey, self._sortAsc
    table.sort(entries, function(a, b)
        local av, bv = a[sortKey] or "", b[sortKey] or ""
        if type(av) == "number" and type(bv) == "number" then
            if sortAsc then return av < bv else return av > bv end
        end
        av, bv = tostring(av):lower(), tostring(bv):lower()
        if sortAsc then return av < bv else return av > bv end
    end)
    self._displayedEntries = entries

    f.header:SetSubtitle(#entries .. (#entries == 1 and " award" or " awards"))
    tbl:SetSortIndicator(sortKey)
    tbl:ReleaseRows()

    if #entries == 0 then
        f.empty:SetText("No loot history matches these filters.")
        f.empty:Show()
        f.scrollChild:SetHeight(40)
        return
    end
    f.empty:Hide()

    local groupByNight = (sortKey == "timestamp")
    local lastNight = nil
    local nightCounts = {}
    if groupByNight then
        for _, e in ipairs(entries) do
            local k = _NightKey(e.timestamp)
            nightCounts[k] = (nightCounts[k] or 0) + 1
        end
    end

    local bodyFont = ns.Ledger.Fonts.OLLFontBody
    for _, entry in ipairs(entries) do
        if groupByNight then
            local night = _NightKey(entry.timestamp)
            if night ~= lastNight then
                lastNight = night
                local hdr = tbl:AcquireRow()
                for key, fs in pairs(hdr.cells) do fs:SetFontObject(bodyFont) end
                hdr.cells.timestamp:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
                hdr:SetCell("timestamp", ns.Track(date("%b %d", (entry.timestamp or 0)) .. " · "
                    .. nightCounts[night] .. (nightCounts[night] == 1 and " award" or " awards")), theme.textDimColor)
                hdr.cells.timestamp:SetWidth(400)   -- span across the row
                hdr:EnableMouse(false)
                hdr._hl:Hide()
                hdr._link = nil; hdr._player = nil
            end
        end

        local row = tbl:AcquireRow()
        for _, fs in pairs(row.cells) do fs:SetFontObject(bodyFont) end
        row:EnableMouse(true)
        row._link   = entry.itemLink
        row._player = entry.player

        row:SetCell("timestamp", entry.timestamp and date("%m-%d %H:%M", entry.timestamp) or "?", theme.textColor)
        row:SetCell("bossName", entry.bossName or "", theme.textMutedColor)

        local link = entry.itemLink
        local itemName, qr, qg, qb = link or "Unknown", C(theme, "textColor")
        if link and link:find("|H") then
            itemName = link:match("|h%[(.-)%]|h") or link
            local _, _, quality = GetItemInfo(link)
            if quality then qr, qg, qb = GetItemQualityColor(quality) end
        end
        row:SetCell("itemLink", itemName, { qr, qg, qb })
        row:SetCell("player", ns.StripRealm(entry.player or ""), theme.textColor)
        row:SetCell("lootCountAtWin", tostring(entry.lootCountAtWin or 0), theme.textColor)
        local choiceColor = (entry.rollType == "Passed" or entry.rollType == "Disenchant")
            and theme.choicePassColor or ns.Theme:ChoiceColor(entry.rollType, theme)
        row:SetCell("rollType", ns.Track(entry.rollType or ""), choiceColor)
        row:SetCell("rollValue", (entry.rollValue and entry.rollValue > 0) and tostring(entry.rollValue) or "—",
            (entry.rollValue and entry.rollValue > 0) and theme.textColor or theme.textDimColor)

        if not row._tooltipHooked then
            row._tooltipHooked = true
            row:HookScript("OnEnter", function(r)
                if r._link and r._link:find("|H") then
                    GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink(r._link)
                    if r._player then
                        local mainIdentity = ns.PlayerLinks:ResolveIdentity(r._player)
                        if mainIdentity and mainIdentity ~= r._player then
                            GameTooltip:AddLine("Winner's Main: " .. ns.StripRealm(mainIdentity), 1, 1, 1)
                        end
                    end
                    GameTooltip:Show()
                end
            end)
            row:HookScript("OnLeave", GameTooltip_Hide)
        end
    end

    tbl:Layout()
    f.scrollChild:SetHeight(tbl._used * ROW_H + 12)
end

------------------------------------------------------------------------
-- Export dialog (one instance, reused)
------------------------------------------------------------------------
function HistoryFrame:ShowExport()
    local entries = self._displayedEntries or {}
    local csv = ns.LootHistory:ExportCSV(entries)

    local dialog = self._exportDialog
    if not dialog then
        dialog = ns.MakeLedgerFrame("OLLExportDialog", 520, 360, nil, { strata = "DIALOG" })
        dialog.header = ns.MakeHeaderBar(dialog, "Export CSV", nil, { height = 44, subtitle = "Select all and copy" })

        local wrap = CreateFrame("Frame", nil, dialog, "BackdropTemplate")
        wrap:SetPoint("TOPLEFT", dialog, "TOPLEFT", INSET, -(44 + 12))
        wrap:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -INSET, INSET)
        ns.SkinNineSlice(wrap, "btn")
        dialog.wrap = wrap

        local scrollFrame = CreateFrame("ScrollFrame", "OLLExportScroll", wrap)
        scrollFrame:SetPoint("TOPLEFT", wrap, "TOPLEFT", 8, -8)
        scrollFrame:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -8, 8)
        scrollFrame:EnableMouseWheel(true)
        scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
            local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
            sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 40)))
        end)
        local editBox = CreateFrame("EditBox", "OLLExportEdit", scrollFrame)
        editBox:SetMultiLine(true)
        editBox:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
        editBox:SetWidth(470)
        editBox:SetAutoFocus(true)
        editBox:SetScript("OnEscapePressed", function() dialog:Hide() end)
        scrollFrame:SetScrollChild(editBox)
        scrollFrame:SetScript("OnSizeChanged", function(_, w) editBox:SetWidth(w) end)
        dialog.editBox = editBox

        function dialog:ApplyThemeExtra(th)
            self.wrap:SetBackdropColor(C(th, "panelBgColor"))
            self.wrap:SetBackdropBorderColor(C(th, "strokeDimColor"))
            self.editBox:SetTextColor(C(th, "textColor"))
        end
        dialog:ApplyThemeExtra(ns.Theme:GetCurrent())
        self._exportDialog = dialog
    end

    dialog.editBox:SetText(csv)
    dialog.editBox:HighlightText()
    dialog:Show()
    dialog.editBox:SetFocus()
end

------------------------------------------------------------------------
-- Parse date string "YYYY-MM-DD" to timestamp
------------------------------------------------------------------------
function HistoryFrame:_ParseDate(str)
    if not str or str == "" then return nil end
    local y, m, d = str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return time({ year = tonumber(y) or 0, month = tonumber(m) or 0, day = tonumber(d) or 0, hour = 0, min = 0, sec = 0 })
end

------------------------------------------------------------------------
-- Show / Hide / Toggle
------------------------------------------------------------------------
function HistoryFrame:Show()
    local f = self:GetFrame()
    f:Show()
    ns.RaiseFrame(f)
    self:Refresh()
end

function HistoryFrame:Hide()
    if self._frame then self._frame:Hide() end
end

function HistoryFrame:Toggle()
    local f = self:GetFrame()
    if f:IsShown() then self:Hide() else self:Show() end
end

function HistoryFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end
