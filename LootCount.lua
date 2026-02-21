------------------------------------------------------------------------
-- OrderedLootList  –  LootCount.lua
-- Per-identity loot count with weekly Tuesday 8 AM PT reset
------------------------------------------------------------------------

local ns                = _G.OLL_NS

local LootCount         = {}
ns.LootCount            = LootCount

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
-- Tuesday 8 AM PT = Tuesday 16:00 UTC  (PT is UTC-8, but during PDT
-- it's UTC-7.  WoW uses a fixed "server reset" concept, so we use
-- 15:00 UTC which aligns with the standard NA reset.)
local RESET_DAY_OF_WEEK = 3   -- Tuesday (1=Sun .. 7=Sat)
local RESET_HOUR_UTC    = 15  -- 15:00 UTC = 8:00 AM PT (7 AM PDT)

------------------------------------------------------------------------
-- Check and perform weekly reset if necessary.
-- Called from Core:OnEnable.
------------------------------------------------------------------------
function LootCount:CheckWeeklyReset()
    local now = time()
    local lastReset = ns.db.global.lastResetTimestamp or 0

    local nextReset = self:_GetNextResetTime(lastReset)
    if now >= nextReset then
        self:ResetAll()
        ns.db.global.lastResetTimestamp = now
        ns.addon:Print("Weekly loot counts have been reset.")
    end
end

------------------------------------------------------------------------
-- Get count for a character (resolves identity first).
------------------------------------------------------------------------
function LootCount:GetCount(name)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    return ns.db.global.lootCounts[identity] or 0
end

------------------------------------------------------------------------
-- Increment count for a character.
------------------------------------------------------------------------
function LootCount:IncrementCount(name)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    ns.db.global.lootCounts[identity] = (ns.db.global.lootCounts[identity] or 0) + 1
    return ns.db.global.lootCounts[identity]
end

------------------------------------------------------------------------
-- Set count directly (for admin / sync).
------------------------------------------------------------------------
function LootCount:SetCount(name, count)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    ns.db.global.lootCounts[identity] = count
end

------------------------------------------------------------------------
-- Reset count for a single player.
------------------------------------------------------------------------
function LootCount:ResetCount(name)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    ns.db.global.lootCounts[identity] = 0
end

------------------------------------------------------------------------
-- Reset all counts.
------------------------------------------------------------------------
function LootCount:ResetAll()
    wipe(ns.db.global.lootCounts)
end

------------------------------------------------------------------------
-- Get full counts table (for sync).
------------------------------------------------------------------------
function LootCount:GetCountsTable()
    return ns.db.global.lootCounts
end

------------------------------------------------------------------------
-- Replace counts table (from sync).
------------------------------------------------------------------------
function LootCount:SetCountsTable(tbl)
    ns.db.global.lootCounts = tbl or {}
end

------------------------------------------------------------------------
-- Internal: compute the next reset timestamp after 'after'.
------------------------------------------------------------------------
function LootCount:_GetNextResetTime(after)
    -- Get the date components for 'after' in UTC
    local d = date("!*t", after)

    -- Find the next Tuesday at RESET_HOUR_UTC
    -- d.wday: 1=Sun,2=Mon,...,7=Sat  →  we want wday==3 (Tue)
    local daysUntilTuesday = (RESET_DAY_OF_WEEK - d.wday) % 7
    if daysUntilTuesday == 0 then
        -- It's Tuesday — check if we're past the reset hour
        if d.hour >= RESET_HOUR_UTC then
            daysUntilTuesday = 7 -- next Tuesday
        end
    end

    local resetDate = {
        year  = d.year,
        month = d.month,
        day   = d.day + daysUntilTuesday,
        hour  = RESET_HOUR_UTC,
        min   = 0,
        sec   = 0,
    }
    return time(resetDate)
end
