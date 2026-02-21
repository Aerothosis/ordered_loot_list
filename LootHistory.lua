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
            local canonical = ns.PlayerLinks:ResolveIdentity(filters.player)
            if e.player ~= canonical then
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

        local line = string.format("%s,%s,%s,%s,%d,%s,%d",
            dateStr,
            boss,
            itemName,
            player,
            e.lootCountAtWin or 0,
            e.rollType or "?",
            e.rollValue or 0
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
