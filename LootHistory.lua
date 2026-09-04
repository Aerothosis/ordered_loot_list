------------------------------------------------------------------------
-- OrderedLootList  –  LootHistory.lua
-- Persistent log of all awarded items
------------------------------------------------------------------------

local ns = _G.OLL_NS

local LootHistory = {}
ns.LootHistory = LootHistory

------------------------------------------------------------------------
-- Add a new history entry.
-- @param entry table {
--   itemLink, itemId, player (canonical), lootCountAtWin,
--   bossName, timestamp, rollType, rollValue
-- }
------------------------------------------------------------------------
function LootHistory:AddEntry(entry)
    entry.timestamp = entry.timestamp or time()
    entry.player = ns.PlayerLinks:ResolveIdentity(entry.player)
    tinsert(ns.db.global.lootHistory, entry)
    -- Open history windows show the new award without being reopened.
    if ns.HistoryFrame and ns.HistoryFrame.IsVisible and ns.HistoryFrame:IsVisible() then
        ns.HistoryFrame:Refresh()
    end
    if ns.SessionHistoryFrame and ns.SessionHistoryFrame.IsVisible
            and ns.SessionHistoryFrame:IsVisible() then
        ns.SessionHistoryFrame:Refresh()
    end
end

------------------------------------------------------------------------
-- Get all entries (newest first by default).
------------------------------------------------------------------------
function LootHistory:GetAll()
    return ns.db.global.lootHistory or {}
end

------------------------------------------------------------------------
-- Get filtered entries.
-- @param filters table {
--   player   = "Name-Realm"  (optional, resolved),
--   boss     = "BossName"    (optional, substring match),
--   dateFrom = timestamp     (optional),
--   dateTo   = timestamp     (optional),
-- }
-- @return table  array of matching entries
------------------------------------------------------------------------
function LootHistory:GetFiltered(filters)
    filters = filters or {}
    local results = {}
    local all = self:GetAll()

    for _, e in ipairs(all) do
        local pass = true

        if filters.player and filters.player ~= "" then
            -- Rows store the identity as it was at award time; links may
            -- have changed since, so match the stored name both raw and
            -- re-resolved against the current main.
            local canonical = ns.PlayerLinks:ResolveIdentity(filters.player)
            if e.player ~= canonical
                    and ns.PlayerLinks:ResolveIdentity(e.player) ~= canonical then
                pass = false
            end
        end

        if pass and filters.boss and filters.boss ~= "" then
            if not e.bossName or not e.bossName:lower():find(filters.boss:lower(), 1, true) then
                pass = false
            end
        end

        if pass and filters.dateFrom then
            if (e.timestamp or 0) < filters.dateFrom then
                pass = false
            end
        end

        if pass and filters.dateTo then
            if (e.timestamp or 0) > filters.dateTo then
                pass = false
            end
        end

        if pass then
            tinsert(results, e)
        end
    end

    return results
end

------------------------------------------------------------------------
-- Export entries to CSV string.
-- @param entries table  array of history entries (pre-filtered)
-- @return string  CSV text
------------------------------------------------------------------------
function LootHistory:ExportCSV(entries)
    local lines = { "Date,Boss,Item,Winner,LootCount,RollType,RollValue" }

    for _, e in ipairs(entries) do
        local dateStr = date("%Y-%m-%d %H:%M", e.timestamp or 0)
        -- Strip color codes from item link for CSV
        local itemName = e.itemLink or "Unknown"
        itemName = itemName:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
        -- Escape commas / quotes
        itemName = itemName:gsub('"', '""')
        if itemName:find(",") then itemName = '"' .. itemName .. '"' end

        local boss = (e.bossName or "Unknown"):gsub('"', '""')
        if boss:find(",") then boss = '"' .. boss .. '"' end

        local player = (e.player or "Unknown"):gsub('"', '""')
        if player:find(",") then player = '"' .. player .. '"' end

        -- Roll option names are user-editable: quote them like the rest.
        local rollType = tostring(e.rollType or "?"):gsub('"', '""')
        if rollType:find(",") then rollType = '"' .. rollType .. '"' end
        local rollValue = tonumber(e.rollValue) or 0

        local line = string.format("%s,%s,%s,%s,%d,%s,%s",
            dateStr,
            boss,
            itemName,
            player,
            math.floor(tonumber(e.lootCountAtWin) or 0),
            rollType,
            tostring(math.floor(rollValue))
        )
        tinsert(lines, line)
    end

    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Replace history table (from sync).
------------------------------------------------------------------------
function LootHistory:SetHistoryTable(tbl)
    ns.db.global.lootHistory = tbl or {}
end

------------------------------------------------------------------------
-- Get raw table (for sync).
------------------------------------------------------------------------
function LootHistory:GetHistoryTable()
    return ns.db.global.lootHistory
end

------------------------------------------------------------------------
-- Clear all history.
------------------------------------------------------------------------
function LootHistory:ClearAll()
    wipe(ns.db.global.lootHistory)
end

------------------------------------------------------------------------
-- Retention (Settings > History).  Rows older than the window are
-- deleted; closed session records older than the window go with them
-- (an open record is never touched).
------------------------------------------------------------------------
LootHistory.RETENTION_CHOICES = { 30, 90, 365 }

function LootHistory:GetRetentionDays()
    local d = tonumber(ns.db.global.historyRetentionDays) or 365
    return d
end

function LootHistory:SetRetentionDays(days)
    ns.db.global.historyRetentionDays = tonumber(days) or 365
end

local function _Cutoff(days)
    return time() - (tonumber(days) or 365) * 86400
end

-- How many loot rows / closed session records a given window would drop.
function LootHistory:CountOlderThan(days)
    local cutoff = _Cutoff(days)
    local rows, sessions = 0, 0
    for _, e in ipairs(ns.db.global.lootHistory or {}) do
        if (e.timestamp or 0) < cutoff then rows = rows + 1 end
    end
    for _, s in ipairs(ns.db.global.sessionHistory or {}) do
        if s.endTime and (s.startTime or 0) < cutoff then sessions = sessions + 1 end
    end
    return rows, sessions
end

-- Delete everything outside the current window.  Returns rows, sessions removed.
function LootHistory:Prune()
    local cutoff = _Cutoff(self:GetRetentionDays())
    local rows, sessions = 0, 0
    local history = ns.db.global.lootHistory or {}
    for i = #history, 1, -1 do
        if (history[i].timestamp or 0) < cutoff then
            table.remove(history, i)
            rows = rows + 1
        end
    end
    local list = ns.db.global.sessionHistory or {}
    for i = #list, 1, -1 do
        local s = list[i]
        if s.endTime and (s.startTime or 0) < cutoff then
            table.remove(list, i)
            sessions = sessions + 1
        end
    end
    if rows > 0 or sessions > 0 then
        if ns.HistoryFrame and ns.HistoryFrame.IsVisible and ns.HistoryFrame:IsVisible() then
            ns.HistoryFrame:Refresh()
        end
        if ns.SessionHistoryFrame and ns.SessionHistoryFrame.IsVisible
                and ns.SessionHistoryFrame:IsVisible() then
            ns.SessionHistoryFrame:Refresh()
        end
    end
    return rows, sessions
end

-- Oldest loot row timestamp, or nil.
function LootHistory:OldestTimestamp()
    local oldest
    for _, e in ipairs(ns.db.global.lootHistory or {}) do
        if e.timestamp and (not oldest or e.timestamp < oldest) then oldest = e.timestamp end
    end
    return oldest
end

------------------------------------------------------------------------
-- Backup / restore.  A backup is one printable string: "OLLB1:" followed
-- by the LibDeflate-compressed AceSerializer form of the loot history and
-- session records.  Restore merges: rows and records already present are
-- skipped, so importing the same backup twice changes nothing.
------------------------------------------------------------------------
local BACKUP_PREFIX = "OLLB1:"

local function _RowKey(e)
    return table.concat({ tostring(e.timestamp or 0), tostring(e.itemLink or ""),
        tostring(e.player or ""), tostring(e.sessionId or "") }, "|")
end

-- Rows / session records inside a scope: { sessions = { [id] = true } }
-- wins over { dateFrom = ts, dateTo = ts }; an empty scope is everything.
-- Both lists come back oldest first.
function LootHistory:SelectScope(scope)
    scope = scope or {}
    local ids = scope.sessions and next(scope.sessions) and scope.sessions or nil
    local from, to = scope.dateFrom, scope.dateTo
    local rows, sessions = {}, {}
    for _, e in ipairs(self:GetAll()) do
        local ok
        if ids then
            ok = e.sessionId and ids[e.sessionId] or false
        else
            local t = e.timestamp or 0
            ok = (not from or t >= from) and (not to or t <= to)
        end
        if ok then tinsert(rows, e) end
    end
    for _, s in ipairs(ns.db.global.sessionHistory or {}) do
        local ok
        if ids then
            ok = s.id and ids[s.id] or false
        else
            local t = s.startTime or 0
            ok = (not from or t >= from) and (not to or t <= to)
        end
        if ok then tinsert(sessions, s) end
    end
    table.sort(rows, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)
    table.sort(sessions, function(a, b) return (a.startTime or 0) < (b.startTime or 0) end)
    return rows, sessions
end

function LootHistory:ExportAllCSV(scope)
    local rows = self:SelectScope(scope)
    return self:ExportCSV(rows)
end

function LootHistory:BuildBackup(scope)
    local ld = LibStub and LibStub("LibDeflate", true)
    if not ld then return nil, "LibDeflate is not available." end
    local rows, sessions = self:SelectScope(scope)
    local payload = {
        v              = 1,
        exportedAt     = time(),
        addonVersion   = ns.VERSION,
        lootHistory    = rows,
        sessionHistory = sessions,
    }
    local serialized = ns.addon:Serialize(payload)
    local compressed = ld:CompressDeflate(serialized, { level = 9 })
    if not compressed then return nil, "Compression failed." end
    return BACKUP_PREFIX .. ld:EncodeForPrint(compressed)
end

-- Returns rowsAdded, sessionsAdded on success; nil, message on failure.
function LootHistory:RestoreBackup(text)
    text = (text or ""):gsub("%s+", "")
    if text:sub(1, #BACKUP_PREFIX) ~= BACKUP_PREFIX then
        return nil, "That is not an OrderedLootList backup."
    end
    local ld = LibStub and LibStub("LibDeflate", true)
    if not ld then return nil, "LibDeflate is not available." end
    local decoded = ld:DecodeForPrint(text:sub(#BACKUP_PREFIX + 1))
    if not decoded then return nil, "The backup text is damaged (decode failed)." end
    local serialized = ld:DecompressDeflate(decoded)
    if not serialized then return nil, "The backup text is damaged (decompress failed)." end
    local ok, payload = ns.addon:Deserialize(serialized)
    if not ok or type(payload) ~= "table" or type(payload.lootHistory) ~= "table" then
        return nil, "The backup text is damaged (unreadable)."
    end

    local existing = {}
    local history = ns.db.global.lootHistory
    for _, e in ipairs(history) do existing[_RowKey(e)] = true end
    local rowsAdded = 0
    for _, e in ipairs(payload.lootHistory) do
        if type(e) == "table" and e.timestamp and not existing[_RowKey(e)] then
            existing[_RowKey(e)] = true
            tinsert(history, e)
            rowsAdded = rowsAdded + 1
        end
    end
    table.sort(history, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)

    local haveSession = {}
    local sessions = ns.db.global.sessionHistory
    for _, s in ipairs(sessions) do if s.id then haveSession[s.id] = true end end
    local sessionsAdded = 0
    for _, s in ipairs(type(payload.sessionHistory) == "table" and payload.sessionHistory or {}) do
        if type(s) == "table" and s.id and not haveSession[s.id] then
            haveSession[s.id] = true
            -- A restored record is history, never a live session.
            s.endTime = s.endTime or s.startTime or time()
            tinsert(sessions, s)
            sessionsAdded = sessionsAdded + 1
        end
    end

    if ns.HistoryFrame and ns.HistoryFrame.IsVisible and ns.HistoryFrame:IsVisible() then
        ns.HistoryFrame:Refresh()
    end
    if ns.SessionHistoryFrame and ns.SessionHistoryFrame.IsVisible
            and ns.SessionHistoryFrame:IsVisible() then
        ns.SessionHistoryFrame:Refresh()
    end
    return rowsAdded, sessionsAdded
end
