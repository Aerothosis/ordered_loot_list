------------------------------------------------------------------------
-- OrderedLootList  –  Comm.lua
-- AceComm message protocol – serialize / send / receive / dispatch
------------------------------------------------------------------------

local ns = _G.OLL_NS

local Comm = {}
ns.Comm = Comm

------------------------------------------------------------------------
-- Message types
------------------------------------------------------------------------
Comm.MSG = {
    SESSION_START = "SS",
    SESSION_END   = "SE",
    LOOT_TABLE    = "LT",
    ROLL_RESPONSE = "RR",
    ROLL_RESULT   = "RS",
    COUNT_SYNC    = "CS",
    HISTORY_SYNC  = "HS",
    LINKS_SYNC    = "LS",
}

------------------------------------------------------------------------
-- Send a message to the group / specific player.
-- @param msgType  string  one of Comm.MSG.*
-- @param payload  table   data to serialize
-- @param target   string? player name for whisper (optional)
------------------------------------------------------------------------
function Comm:Send(msgType, payload, target)
    local data = {
        t = msgType,
        p = payload,
        v = ns.VERSION,
    }

    local serialized = ns.addon:Serialize(data)
    local channel = ns.GetCommChannel()

    if target then
        ns.addon:SendCommMessage(ns.COMM_PREFIX, serialized, "WHISPER", target)
    else
        ns.addon:SendCommMessage(ns.COMM_PREFIX, serialized, channel)
    end
end

------------------------------------------------------------------------
-- Incoming message handler (called from Core:OnCommReceived).
------------------------------------------------------------------------
function Comm:OnMessageReceived(message, distribution, sender)
    local success, data = ns.addon:Deserialize(message)
    if not success or type(data) ~= "table" then
        return
    end

    local msgType = data.t
    local payload = data.p or {}

    -- Ignore own messages in some cases
    local me = ns.GetPlayerNameRealm()

    -- Dispatch by type
    if msgType == self.MSG.SESSION_START then
        self:HandleSessionStart(payload, sender)
    elseif msgType == self.MSG.SESSION_END then
        self:HandleSessionEnd(payload, sender)
    elseif msgType == self.MSG.LOOT_TABLE then
        self:HandleLootTable(payload, sender)
    elseif msgType == self.MSG.ROLL_RESPONSE then
        self:HandleRollResponse(payload, sender)
    elseif msgType == self.MSG.ROLL_RESULT then
        self:HandleRollResult(payload, sender)
    elseif msgType == self.MSG.COUNT_SYNC then
        self:HandleCountSync(payload, sender)
    elseif msgType == self.MSG.HISTORY_SYNC then
        self:HandleHistorySync(payload, sender)
    elseif msgType == self.MSG.LINKS_SYNC then
        self:HandleLinksSync(payload, sender)
    end
end

------------------------------------------------------------------------
-- Message handlers – delegate to appropriate modules
------------------------------------------------------------------------
function Comm:HandleSessionStart(payload, sender)
    if ns.Session then
        ns.Session:OnSessionStartReceived(payload, sender)
    end
end

function Comm:HandleSessionEnd(payload, sender)
    if ns.Session then
        ns.Session:OnSessionEndReceived(payload, sender)
    end
end

function Comm:HandleLootTable(payload, sender)
    if ns.Session then
        ns.Session:OnLootTableReceived(payload, sender)
    end
end

function Comm:HandleRollResponse(payload, sender)
    if ns.Session then
        ns.Session:OnRollResponseReceived(payload, sender)
    end
end

function Comm:HandleRollResult(payload, sender)
    if ns.Session then
        ns.Session:OnRollResultReceived(payload, sender)
    end
end

function Comm:HandleCountSync(payload, sender)
    -- Only accept from session leader
    if ns.Session and ns.Session.leaderName == sender then
        ns.LootCount:SetCountsTable(payload.counts)
    end
end

function Comm:HandleHistorySync(payload, sender)
    if ns.Session and ns.Session.leaderName == sender then
        ns.LootHistory:SetHistoryTable(payload.entries)
    end
end

function Comm:HandleLinksSync(payload, sender)
    if ns.Session and ns.Session.leaderName == sender then
        ns.PlayerLinks:SetLinksTable(payload.links)
    end
end

------------------------------------------------------------------------
-- Convenience: broadcast session start with all state
------------------------------------------------------------------------
function Comm:BroadcastSessionStart(settings, rollOptions)
    self:Send(self.MSG.SESSION_START, {
        leaderName  = ns.GetPlayerNameRealm(),
        settings    = settings,
        rollOptions = rollOptions,
        counts      = ns.LootCount:GetCountsTable(),
        links       = ns.PlayerLinks:GetLinksTable(),
    })
end

------------------------------------------------------------------------
-- Convenience: broadcast roll result
------------------------------------------------------------------------
function Comm:BroadcastRollResult(itemIdx, winner, roll, choice, newCount)
    self:Send(self.MSG.ROLL_RESULT, {
        itemIdx  = itemIdx,
        winner   = winner,
        roll     = roll,
        choice   = choice,
        newCount = newCount,
    })
end
