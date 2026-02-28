------------------------------------------------------------------------
-- OrderedLootList  –  LootCount.lua
-- Per-identity loot count with weekly Tuesday 8 AM PT reset
------------------------------------------------------------------------

local ns                = _G.OLL_NS

local LootCount         = {}
ns.LootCount            = LootCount

-- Non-nil during a debug session: shadow table that receives all
-- read/write operations so the real counts are never touched.
LootCount._debugCounts  = nil

------------------------------------------------------------------------
-- Internal: return the active count table (debug overlay or real).
------------------------------------------------------------------------
function LootCount:_GetTable()
    return self._debugCounts or ns.db.global.lootCounts
end

------------------------------------------------------------------------
-- Start debug mode: snapshot real counts into an isolated overlay.
------------------------------------------------------------------------
function LootCount:StartDebug()
    self._debugCounts = {}
    for k, v in pairs(ns.db.global.lootCounts) do
        self._debugCounts[k] = v
    end
end

------------------------------------------------------------------------
-- End debug mode: discard the overlay; real counts are unchanged.
------------------------------------------------------------------------
function LootCount:EndDebug()
    self._debugCounts = nil
end

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
-- Tuesday 8 AM PT = Tuesday 16:00 UTC  (PT is UTC-8, but during PDT
-- it's UTC-7.  WoW uses a fixed "server reset" concept, so we use
-- 15:00 UTC which aligns with the standard NA reset.)
local RESET_DAY_OF_WEEK = 3   -- Tuesday (1=Sun .. 7=Sat)
local RESET_HOUR_UTC    = 15  -- 15:00 UTC = 8:00 AM PT (7 AM PDT)

------------------------------------------------------------------------
-- Check and perform automatic reset if necessary.
-- Called from Core:OnEnable.
------------------------------------------------------------------------
function LootCount:CheckWeeklyReset()
    local schedule = ns.db.profile.resetSchedule or "weekly"

    if schedule == "manual" then
        return  -- automatic reset is disabled
    end

    local now = time()
    local lastReset = ns.db.global.lastResetTimestamp or 0
    local nextReset

    if schedule == "monthly" then
        nextReset = self:_GetNextMonthlyResetTime(lastReset)
    else  -- "weekly"
        nextReset = self:_GetNextResetTime(lastReset)
    end

    if now >= nextReset then
        self:ResetAll()
        ns.db.global.lastResetTimestamp = now
        if schedule == "monthly" then
            ns.addon:Print("Monthly loot counts have been reset.")
        else
            ns.addon:Print("Weekly loot counts have been reset.")
        end
    end
end

------------------------------------------------------------------------
-- Get count for a character (resolves identity first).
------------------------------------------------------------------------
function LootCount:GetCount(name)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    return self:_GetTable()[identity] or 0
end

------------------------------------------------------------------------
-- Increment count for a character.
------------------------------------------------------------------------
function LootCount:IncrementCount(name)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    local t = self:_GetTable()
    t[identity] = (t[identity] or 0) + 1
    return t[identity]
end

------------------------------------------------------------------------
-- Set count directly (for admin / sync).
------------------------------------------------------------------------
function LootCount:SetCount(name, count)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    self:_GetTable()[identity] = count
end

------------------------------------------------------------------------
-- Reset count for a single player.
------------------------------------------------------------------------
function LootCount:ResetCount(name)
    local identity = ns.PlayerLinks:ResolveIdentity(name)
    self:_GetTable()[identity] = 0
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
    return self:_GetTable()
end

------------------------------------------------------------------------
-- Replace counts table (from sync).
------------------------------------------------------------------------
function LootCount:SetCountsTable(tbl)
    if self._debugCounts then
        self._debugCounts = tbl or {}
    else
        ns.db.global.lootCounts = tbl or {}
    end
end

------------------------------------------------------------------------
-- Internal: compute the next weekly reset timestamp after 'after'.
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

------------------------------------------------------------------------
-- Internal: compute the next monthly reset timestamp after 'after'.
-- Resets on the 1st of the month at RESET_HOUR_UTC.
------------------------------------------------------------------------
function LootCount:_GetNextMonthlyResetTime(after)
    local d = date("!*t", after)

    -- If still before the reset time on the 1st of this month, use it
    if d.day == 1 and d.hour < RESET_HOUR_UTC then
        return time({ year = d.year, month = d.month, day = 1,
                      hour = RESET_HOUR_UTC, min = 0, sec = 0 })
    end

    -- Otherwise use the 1st of next month
    local nextMonth = d.month + 1
    local nextYear  = d.year
    if nextMonth > 12 then
        nextMonth = 1
        nextYear  = nextYear + 1
    end
    return time({ year = nextYear, month = nextMonth, day = 1,
                  hour = RESET_HOUR_UTC, min = 0, sec = 0 })
end
