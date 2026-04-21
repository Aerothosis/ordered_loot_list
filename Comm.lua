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
    SESSION_START         = "SS",
    SESSION_END           = "SE",
    LOOT_TABLE            = "LT",
    ROLL_RESPONSE         = "RR",
    ROLL_RESULT           = "RS",
    ROLL_CANCELLED        = "RC",
    COUNT_SYNC            = "CS",
    HISTORY_SYNC          = "HS",
    LINKS_SYNC            = "LS",
    ADDON_CHECK           = "AC",   -- Leader→Group: ping for installed version
    ADDON_CHECK_RESPONSE  = "ACR",  -- Player→Group: reply with own version
    SETTINGS_SYNC         = "ST",   -- Leader→Group: mid-session settings update
    PLAYER_SELECTION_UPDATE = "PSU", -- Leader→Player (whisper): set their roll choice
    SESSION_SYNC          = "SHS",  -- Leader→Group: session record upsert (metadata only)
    SESSION_TAKEOVER      = "STO",  -- NewLeader→Group: assume session control
    SESSION_DELETE        = "SD",   -- Leader→Group: delete a session record from all clients
    SESSION_RESUME        = "SR",   -- Leader→Group: resume an existing session (weekly lockout)
    PLAYER_CHAR_LIST          = "PCL",  -- Member→Group: my character list (broadcast or whisper)
    SESSION_JOIN              = "SJ",   -- Leader→NewPlayer (whisper): late-join session state
    ROLL_RESPONSE_ACK         = "RRA",  -- Leader→Member (whisper): roll choice received
    LOOT_TABLE_READY_CHECK    = "LTRC", -- Leader→Player (whisper): are you ready for loot table?
    LOOT_TABLE_READY_ACK      = "LTRA", -- Player→Leader (whisper): I'm ready for loot table
    TIMER_TICK                = "TT",   -- Leader→Group: authoritative timer remaining (every 1s)
    CHOICES_UPDATE            = "CU",   -- Leader→Group: all current roll choices (for large frame)
}

------------------------------------------------------------------------
-- LibDeflate (lazy-loaded once on first use)
------------------------------------------------------------------------
local _libDeflate = nil
local function _GetLibDeflate()
    if not _libDeflate then
        _libDeflate = LibStub and LibStub("LibDeflate", true)
    end
    return _libDeflate
end

-- Serialized strings longer than this threshold are compressed before send.
-- Messages shorter than this already fit in one 255-byte AceComm packet, so
-- compression overhead would not reduce the packet count.
local COMPRESS_THRESHOLD = 200

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

    -- Compress if the serialized string is large enough to benefit.
    local ld = _GetLibDeflate()
    if ld and #serialized > COMPRESS_THRESHOLD then
        local compressed = ld:CompressDeflate(serialized, { level = 5 })
        if compressed then
            local encoded = ld:EncodeForWoWAddonChannel(compressed)
            -- Re-serialize a thin wrapper; `c = "d"` signals deflate compression.
            serialized = ns.addon:Serialize({
                t = msgType,
                p = encoded,
                v = ns.VERSION,
                c = "d",
            })
        end
    end

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

    -- Decompress if the sender used LibDeflate compression.
    if data.c == "d" then
        local ld = _GetLibDeflate()
        if not ld then return end  -- library missing; silently drop

        local decoded = ld:DecodeForWoWAddonChannel(data.p)
        if not decoded then return end

        local decompressed = ld:DecompressDeflate(decoded)
        if not decompressed then return end

        local ok, inner = ns.addon:Deserialize(decompressed)
        if not ok or type(inner) ~= "table" then return end

        data = inner
    end

    local msgType = data.t
    local payload = data.p or {}

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
    elseif msgType == self.MSG.ROLL_CANCELLED then
        self:HandleRollCancelled(payload, sender)
    elseif msgType == self.MSG.COUNT_SYNC then
        self:HandleCountSync(payload, sender)
    elseif msgType == self.MSG.HISTORY_SYNC then
        self:HandleHistorySync(payload, sender)
    elseif msgType == self.MSG.LINKS_SYNC then
        self:HandleLinksSync(payload, sender)
    elseif msgType == self.MSG.ADDON_CHECK then
        self:HandleAddonCheck(payload, sender)
    elseif msgType == self.MSG.ADDON_CHECK_RESPONSE then
        self:HandleAddonCheckResponse(payload, sender)
    elseif msgType == self.MSG.SETTINGS_SYNC then
        self:HandleSettingsSync(payload, sender)
    elseif msgType == self.MSG.SESSION_SYNC then
        self:HandleSessionSync(payload, sender)
    elseif msgType == self.MSG.SESSION_TAKEOVER then
        self:HandleSessionTakeover(payload, sender)
    elseif msgType == self.MSG.SESSION_DELETE then
        self:HandleSessionDelete(payload, sender)
    elseif msgType == self.MSG.SESSION_RESUME then
        self:HandleSessionResume(payload, sender)
    elseif msgType == self.MSG.PLAYER_CHAR_LIST then
        self:HandlePlayerCharList(payload, sender, distribution)
    elseif msgType == self.MSG.SESSION_JOIN then
        self:HandleSessionJoin(payload, sender)
    elseif msgType == self.MSG.ROLL_RESPONSE_ACK then
        self:HandleRollResponseAck(payload, sender)
    elseif msgType == self.MSG.LOOT_TABLE_READY_CHECK then
        self:HandleLootTableReadyCheck(payload, sender)
    elseif msgType == self.MSG.LOOT_TABLE_READY_ACK then
        self:HandleLootTableReadyAck(payload, sender)
    elseif msgType == self.MSG.PLAYER_SELECTION_UPDATE then
        if ns.RollFrame then
            ns.RollFrame:SetExternalSelection(payload.itemIdx, payload.choice)
        end
    elseif msgType == self.MSG.TIMER_TICK then
        self:HandleTimerTick(payload, sender)
    elseif msgType == self.MSG.CHOICES_UPDATE then
        self:HandleChoicesUpdate(payload, sender)
    end
end

------------------------------------------------------------------------
-- Message handlers – delegate to appropriate modules
------------------------------------------------------------------------
function Comm:HandleSessionStart(payload, sender)
    self._lastTimerRemaining = nil
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

function Comm:HandleRollCancelled(payload, sender)
    if ns.Session then
        ns.Session:OnRollCancelledReceived(payload, sender)
    end
end

function Comm:HandleCountSync(payload, sender)
    if not (ns.Session and ns.NamesMatch(ns.Session.leaderName, sender)) then return end
    -- Ignore count updates during debug sessions to protect real loot counts
    if ns.Session.debugMode then return end
    if payload.delta then
        ns.LootCount:ApplyDelta(payload.delta)
    elseif payload.counts then
        ns.LootCount:SetCountsTable(payload.counts)
    end
end

function Comm:HandleHistorySync(payload, sender)
    if ns.Session and ns.NamesMatch(ns.Session.leaderName, sender) then
        ns.LootHistory:SetHistoryTable(payload.entries)
    end
end

function Comm:HandleLinksSync(payload, sender)
    local inSession = ns.Session and ns.Session:IsActive()
        and ns.NamesMatch(ns.Session.leaderName, sender)
    local idleFromLeader = ns.Session and not ns.Session:IsActive()
        and ns.Session.IsGroupLeaderOrOfficer(sender)
    if inSession or idleFromLeader then
        ns.PlayerLinks:SetLinksTable(payload.links)
        -- If idle, reply with our character list so the leader can merge and rebroadcast
        if idleFromLeader then
            local myChars = ns.PlayerLinks:GetMyCharactersPayload()
            if #myChars.chars > 0 then
                self:Send(self.MSG.PLAYER_CHAR_LIST, myChars, sender)
            end
        end
    end
end

------------------------------------------------------------------------
-- Addon check handlers
------------------------------------------------------------------------
function Comm:HandleAddonCheck(payload, sender)
    -- Any player with OLL responds with their version via group channel
    self:Send(self.MSG.ADDON_CHECK_RESPONSE, {
        version = ns.VERSION,
        player  = ns.GetPlayerNameRealm(),
    })
end

function Comm:HandleAddonCheckResponse(payload, sender)
    if ns.CheckPartyFrame then
        ns.CheckPartyFrame:OnCheckResponse(payload, sender)
    end
end

function Comm:HandleSettingsSync(payload, sender)
    if ns.Session and ns.NamesMatch(ns.Session.leaderName, sender) then
        ns.Session:OnSettingsSyncReceived(payload, sender)
    end
end

function Comm:HandleSessionSync(payload, sender)
    if ns.Session then
        ns.Session:OnSessionSyncReceived(payload, sender)
    end
end

function Comm:HandleSessionTakeover(payload, sender)
    if ns.Session then
        ns.Session:OnSessionTakeoverReceived(payload, sender)
    end
end

function Comm:HandleSessionDelete(payload, sender)
    if ns.Session then
        ns.Session:OnSessionDeleteReceived(payload, sender)
    end
end

function Comm:HandleSessionResume(payload, sender)
    if ns.Session then
        ns.Session:OnSessionResumeReceived(payload, sender)
    end
end

function Comm:HandleRollResponseAck(payload, sender)
    if ns.Session then
        ns.Session:OnRollResponseAckReceived(payload, sender)
    end
end

function Comm:HandleLootTableReadyCheck(payload, sender)
    if ns.Session then
        ns.Session:OnLootTableReadyCheckReceived(sender)
    end
end

function Comm:HandleLootTableReadyAck(payload, sender)
    if ns.Session then
        ns.Session:OnLootTableReadyAckReceived(sender)
    end
end

function Comm:HandlePlayerCharList(payload, sender, distribution)
    ns.PlayerLinks:MergePlayerCharList(payload)

    -- If this arrived as a group broadcast with wantResponse set, the sender is a
    -- late-joiner collecting everyone's char lists.  Whisper back our own data so
    -- they build a complete picture.  Don't set wantResponse on the reply to
    -- avoid any echo loop.
    if payload.wantResponse and distribution ~= "WHISPER" then
        local myChars = ns.PlayerLinks:GetMyCharactersPayload()
        if #myChars.chars > 0 then
            self:Send(self.MSG.PLAYER_CHAR_LIST, myChars, sender)
        end
    end
end

function Comm:HandleSessionJoin(payload, sender)
    self._lastTimerRemaining = nil
    if ns.Session then
        ns.Session:OnSessionJoinReceived(payload, sender)
    end
end

function Comm:HandleTimerTick(payload, sender)
    -- Only accept from session leader
    if not ns.Session or not ns.NamesMatch(ns.Session.leaderName, sender) then return end
    local remaining = payload.remaining or 0
    -- Discard stale ticks: remaining should only decrease, so ignore any tick
    -- that would move the timer forward by more than half a second.
    if self._lastTimerRemaining and remaining > self._lastTimerRemaining + 0.5 then return end
    self._lastTimerRemaining = remaining
    if ns.RollFrame  then ns.RollFrame:OnTimerTick(remaining)  end
    if ns.LeaderFrame then ns.LeaderFrame:OnTimerTick(remaining) end
end

function Comm:HandleChoicesUpdate(payload, sender)
    -- Only accept from session leader
    if not ns.Session or not ns.NamesMatch(ns.Session.leaderName, sender) then return end
    if ns.LargeRollFrame then
        ns.LargeRollFrame:ApplyChoiceDelta(payload)
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
    })
end

------------------------------------------------------------------------
-- Convenience: broadcast session resume with all state
------------------------------------------------------------------------
function Comm:BroadcastSessionResume(settings, rollOptions, sessionId, bosses)
    self:Send(self.MSG.SESSION_RESUME, {
        leaderName  = ns.GetPlayerNameRealm(),
        sessionId   = sessionId,
        bosses      = bosses,
        settings    = settings,
        rollOptions = rollOptions,
        counts      = ns.LootCount:GetCountsTable(),
    })
end

------------------------------------------------------------------------
-- Convenience: broadcast roll result
------------------------------------------------------------------------
function Comm:BroadcastRollResult(itemIdx, winner, roll, tiebreakerRoll, choice, entry)
    self:Send(self.MSG.ROLL_RESULT, {
        itemIdx        = itemIdx,
        winner         = winner,
        roll           = roll,
        tiebreakerRoll = tiebreakerRoll,  -- nil if no tiebreaker occurred
        choice         = choice,
        entry          = entry,           -- loot history entry (with pre-computed rolls); nil in debug mode
    })
end

------------------------------------------------------------------------
-- Convenience: broadcast session takeover
------------------------------------------------------------------------
function Comm:BroadcastSessionTakeover(newLeader, settings, rollOptions, sessionId)
    self:Send(self.MSG.SESSION_TAKEOVER, {
        newLeader   = newLeader,
        sessionId   = sessionId,
        settings    = settings,
        rollOptions = rollOptions,
        counts      = ns.LootCount:GetCountsTable(),
        links       = ns.PlayerLinks:GetLinksTable(),
    })
end
