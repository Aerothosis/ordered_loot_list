------------------------------------------------------------------------
-- OrderedLootList  –  UI/HistoryFrame.lua
-- Loot history viewer for all players.
-- Sortable table, filters (player, boss, date), CSV export of filtered data.
------------------------------------------------------------------------

local ns                       = _G.OLL_NS

local HistoryFrame             = {}
ns.HistoryFrame                = HistoryFrame

local FRAME_WIDTH              = 700
local FRAME_HEIGHT             = 500

HistoryFrame._frame            = nil
HistoryFrame._sortKey          = "timestamp"
HistoryFrame._sortAsc          = false
HistoryFrame._filterPlayer     = ""
HistoryFrame._filterBoss       = ""
HistoryFrame._filterDateFrom   = nil
HistoryFrame._filterDateTo     = nil
HistoryFrame._displayedEntries = {}

------------------------------------------------------------------------
-- Column definitions
------------------------------------------------------------------------
local COLUMNS                  = {
    { key = "timestamp",      label = "Date",      width = 120 },
    { key = "bossName",       label = "Boss",      width = 110 },
    { key = "itemLink",       label = "Item",      width = 180 },
    { key = "player",         label = "Winner",    width = 120 },
    { key = "lootCountAtWin", label = "Count",     width = 50 },
    { key = "rollType",       label = "Roll Type", width = 60 },
    { key = "rollValue",      label = "Roll",      width = 40 },
}

------------------------------------------------------------------------
-- Create frame (lazy init)
------------------------------------------------------------------------
function HistoryFrame:GetFrame()
    if self._frame then return self._frame end

    local theme = ns.Theme:GetCurrent()

    local f = CreateFrame("Frame", "OLLHistoryFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER")
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
        ns.SaveFramePosition("HistoryFrame", frm)
    end)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetScript("OnMouseDown", function(frm) ns.RaiseFrame(frm) end)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Loot History")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() HistoryFrame:Hide() end)

    -- Filters
    local filterY = -34
    local filterX = 14

    -- Player filter
    local playerLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    playerLabel:SetPoint("TOPLEFT", f, "TOPLEFT", filterX, filterY)
    playerLabel:SetText("Player:")

    local playerBox = CreateFrame("EditBox", "OLLHistFilterPlayer", f, "InputBoxTemplate")
    playerBox:SetSize(110, 20)
    playerBox:SetPoint("LEFT", playerLabel, "RIGHT", 4, 0)
    playerBox:SetAutoFocus(false)
    playerBox:SetScript("OnEnterPressed", function(eb)
        HistoryFrame._filterPlayer = eb:GetText()
        HistoryFrame:Refresh()
        eb:ClearFocus()
    end)
    f.playerBox = playerBox

    -- Boss filter
    local bossLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bossLabel:SetPoint("LEFT", playerBox, "RIGHT", 12, 0)
    bossLabel:SetText("Boss:")

    local bossBox = CreateFrame("EditBox", "OLLHistFilterBoss", f, "InputBoxTemplate")
    bossBox:SetSize(110, 20)
    bossBox:SetPoint("LEFT", bossLabel, "RIGHT", 4, 0)
    bossBox:SetAutoFocus(false)
    bossBox:SetScript("OnEnterPressed", function(eb)
        HistoryFrame._filterBoss = eb:GetText()
        HistoryFrame:Refresh()
        eb:ClearFocus()
    end)
    f.bossBox = bossBox

    -- Date From
    local dateFromLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dateFromLabel:SetPoint("LEFT", bossBox, "RIGHT", 12, 0)
    dateFromLabel:SetText("From:")

    local dateFromBox = CreateFrame("EditBox", "OLLHistFilterDateFrom", f, "InputBoxTemplate")
    dateFromBox:SetSize(80, 20)
    dateFromBox:SetPoint("LEFT", dateFromLabel, "RIGHT", 4, 0)
    dateFromBox:SetAutoFocus(false)
    dateFromBox:SetScript("OnEnterPressed", function(eb)
        HistoryFrame._filterDateFrom = HistoryFrame:_ParseDate(eb:GetText())
        HistoryFrame:Refresh()
        eb:ClearFocus()
    end)
    dateFromBox:SetScript("OnEnter", function(eb)
        GameTooltip:SetOwner(eb, "ANCHOR_TOP")
        GameTooltip:SetText("Format: YYYY-MM-DD")
        GameTooltip:Show()
    end)
    dateFromBox:SetScript("OnLeave", GameTooltip_Hide)
    f.dateFromBox = dateFromBox

    -- Date To
    local dateToLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dateToLabel:SetPoint("LEFT", dateFromBox, "RIGHT", 8, 0)
    dateToLabel:SetText("To:")

    local dateToBox = CreateFrame("EditBox", "OLLHistFilterDateTo", f, "InputBoxTemplate")
    dateToBox:SetSize(80, 20)
    dateToBox:SetPoint("LEFT", dateToLabel, "RIGHT", 4, 0)
    dateToBox:SetAutoFocus(false)
    dateToBox:SetScript("OnEnterPressed", function(eb)
        HistoryFrame._filterDateTo = HistoryFrame:_ParseDate(eb:GetText())
        HistoryFrame:Refresh()
        eb:ClearFocus()
    end)
    dateToBox:SetScript("OnEnter", function(eb)
        GameTooltip:SetOwner(eb, "ANCHOR_TOP")
        GameTooltip:SetText("Format: YYYY-MM-DD")
        GameTooltip:Show()
    end)
    dateToBox:SetScript("OnLeave", GameTooltip_Hide)
    f.dateToBox = dateToBox

    -- Filter / Clear buttons
    local filterBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    filterBtn:SetSize(60, 22)
    filterBtn:SetPoint("TOPLEFT", f, "TOPLEFT", filterX, filterY - 24)
    filterBtn:SetText("Filter")
    filterBtn:SetScript("OnClick", function()
        self._filterPlayer = f.playerBox:GetText()
        self._filterBoss = f.bossBox:GetText()
        self._filterDateFrom = self:_ParseDate(f.dateFromBox:GetText())
        self._filterDateTo = self:_ParseDate(f.dateToBox:GetText())
        self:Refresh()
    end)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(50, 22)
    clearBtn:SetPoint("LEFT", filterBtn, "RIGHT", 4, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        f.playerBox:SetText("")
        f.bossBox:SetText("")
        f.dateFromBox:SetText("")
        f.dateToBox:SetText("")
        self._filterPlayer = ""
        self._filterBoss = ""
        self._filterDateFrom = nil
        self._filterDateTo = nil
        self:Refresh()
    end)

    -- Export button
    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("LEFT", clearBtn, "RIGHT", 8, 0)
    exportBtn:SetText("Export CSV")
    exportBtn:SetScript("OnClick", function()
        self:ShowExport()
    end)

    -- Column headers
    local headerY = filterY - 52
    local headerX = 14
    f.columnHeaders = {}

    local hex = theme.columnHeaderHex
    for _, col in ipairs(COLUMNS) do
        local header = CreateFrame("Button", nil, f)
        header:SetSize(col.width, 18)
        header:SetPoint("TOPLEFT", f, "TOPLEFT", headerX, headerY)

        local label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetAllPoints()
        label:SetJustifyH("LEFT")
        label:SetText("|cff" .. hex .. col.label .. "|r")
        header._label    = label
        header._colLabel = col.label

        header:SetScript("OnClick", function()
            if self._sortKey == col.key then
                self._sortAsc = not self._sortAsc
            else
                self._sortKey = col.key
                self._sortAsc = true
            end
            self:Refresh()
        end)

        headerX = headerX + col.width + 4
        tinsert(f.columnHeaders, header)
    end

    -- Separator line
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(unpack(theme.histSepColor))
    sep:SetSize(FRAME_WIDTH - 28, 1)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 14, headerY - 18)
    f.sep = sep

    -- Scroll frame for rows
    local scrollFrame = CreateFrame("ScrollFrame", "OLLHistScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 14, headerY - 22)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 14)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 50, 1)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild

    f:Hide()
    self._frame = f
    ns.RestoreFramePosition("HistoryFrame", f)
    return f
end

------------------------------------------------------------------------
-- Apply (or re-apply) the current theme to an already-created frame
------------------------------------------------------------------------
function HistoryFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()

    f:SetBackdropColor(unpack(theme.frameBgColor))
    f:SetBackdropBorderColor(unpack(theme.frameBorderColor))

    if f.sep then
        f.sep:SetColorTexture(unpack(theme.histSepColor))
    end

    -- Update column header text colors
    if f.columnHeaders then
        local hex = theme.columnHeaderHex
        for _, header in ipairs(f.columnHeaders) do
            if header._label and header._colLabel then
                header._label:SetText("|cff" .. hex .. header._colLabel .. "|r")
            end
        end
    end
end

------------------------------------------------------------------------
-- Refresh data display
------------------------------------------------------------------------
function HistoryFrame:Refresh()
    local f = self:GetFrame()
    local sc = f.scrollChild

    -- Clear
    for _, child in ipairs({ sc:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    for _, region in ipairs({ sc:GetRegions() }) do
        region:Hide()
    end

    -- Get filtered data
    local entries = ns.LootHistory:GetFiltered({
        player   = self._filterPlayer,
        boss     = self._filterBoss,
        dateFrom = self._filterDateFrom,
        dateTo   = self._filterDateTo,
    })

    -- Sort
    local sortKey = self._sortKey
    local sortAsc = self._sortAsc
    table.sort(entries, function(a, b)
        local av = a[sortKey] or ""
        local bv = b[sortKey] or ""
        if type(av) == "number" and type(bv) == "number" then
            return sortAsc and av < bv or av > bv
        end
        av = tostring(av):lower()
        bv = tostring(bv):lower()
        if sortAsc then return av < bv else return av > bv end
    end)

    self._displayedEntries = entries

    -- Draw rows
    local yOffset = 0
    local ROW_HEIGHT = 20

    for _, entry in ipairs(entries) do
        local x = 0
        for _, col in ipairs(COLUMNS) do
            local val = entry[col.key]
            local displayVal

            if col.key == "timestamp" then
                displayVal = val and tostring(date("%Y-%m-%d %H:%M", val)) or "?"
            elseif col.key == "itemLink" then
                displayVal = val or "Unknown"
            else
                displayVal = tostring(val or "")
            end

            local text = sc:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetPoint("TOPLEFT", sc, "TOPLEFT", x, yOffset)
            text:SetWidth(col.width)
            text:SetJustifyH("LEFT")
            text:SetText(displayVal)
            text:SetWordWrap(false)
            text:Show()

            -- Overlay hit frame for item link tooltip
            if col.key == "itemLink" and entry.itemLink and entry.itemLink:find("|H") then
                local link = entry.itemLink
                local hit = CreateFrame("Frame", nil, sc)
                hit:SetPoint("TOPLEFT", sc, "TOPLEFT", x, yOffset)
                hit:SetSize(col.width, ROW_HEIGHT)
                hit:EnableMouse(true)
                hit:SetScript("OnEnter", function(f)
                    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink(link)
                    GameTooltip:Show()
                end)
                hit:SetScript("OnLeave", GameTooltip_Hide)
                hit:Show()
            end

            x = x + col.width + 4
        end

        yOffset = yOffset - ROW_HEIGHT
    end

    sc:SetHeight(math.abs(yOffset) + 20)
end

------------------------------------------------------------------------
-- Show export dialog
------------------------------------------------------------------------
function HistoryFrame:ShowExport()
    local entries = self._displayedEntries or {}
    local csv = ns.LootHistory:ExportCSV(entries)

    local theme = ns.Theme:GetCurrent()

    -- Create a simple copy dialog
    local dialog = CreateFrame("Frame", "OLLExportDialog", UIParent, "BackdropTemplate")
    dialog:SetSize(500, 350)
    dialog:SetPoint("CENTER")
    dialog:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    dialog:SetBackdropColor(unpack(theme.frameBgColor))
    dialog:SetBackdropBorderColor(unpack(theme.frameBorderColor))
    dialog:SetFrameStrata("DIALOG")
    dialog:SetMovable(true)
    dialog:EnableMouse(true)
    dialog:RegisterForDrag("LeftButton")
    dialog:SetScript("OnDragStart", dialog.StartMoving)
    dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)

    local dtitle = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dtitle:SetPoint("TOP", 0, -10)
    dtitle:SetText("Export CSV – Select All & Copy")

    local closeBtn = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() dialog:Hide() end)

    local scrollFrame = CreateFrame("ScrollFrame", "OLLExportScroll", dialog, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -36)
    scrollFrame:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -32, 14)

    local editBox = CreateFrame("EditBox", "OLLExportEdit", scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetWidth(450)
    editBox:SetAutoFocus(true)
    editBox:SetText(csv)
    editBox:HighlightText()
    editBox:SetScript("OnEscapePressed", function() dialog:Hide() end)

    scrollFrame:SetScrollChild(editBox)

    dialog:Show()
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
    self:Refresh()
end

function HistoryFrame:Hide()
    if self._frame then self._frame:Hide() end
end

function HistoryFrame:Toggle()
    local f = self:GetFrame()
    if f:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function HistoryFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end
