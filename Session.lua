------------------------------------------------------------------------
-- OrderedLootList  –  Session.lua
-- Loot session state machine: start, roll, resolve, end
-- Tracks per-boss loot tables within the session
------------------------------------------------------------------------

local ns                 = _G.OLL_NS

local Session            = {}
ns.Session               = Session

------------------------------------------------------------------------
-- State constants
------------------------------------------------------------------------
Session.STATE_IDLE       = "IDLE"
Session.STATE_ACTIVE     = "ACTIVE"
Session.STATE_ROLLING    = "ROLLING"
Session.STATE_RESOLVING  = "RESOLVING"

------------------------------------------------------------------------
-- Session state
------------------------------------------------------------------------
Session.state                = Session.STATE_IDLE
Session.leaderName           = nil
Session.rollOptions          = nil -- synced from leader
Session.sessionDisenchanter        = nil -- disenchanter for this session (not the local profile value)
Session.sessionLootMaster          = nil -- loot master for this session; defaults to the session starter
Session.sessionLootMasterRestriction = nil -- "anyLeader" or "onlyLootMaster"; synced from leader
Session.sessionLootCountEnabled      = nil -- synced from leader; nil falls back to profile
Session.sessionLootCountLockedToMain = nil -- synced from leader; nil falls back to profile

-- Current loot table being rolled on
Session.currentItems     = {} -- { {index, icon, name, link, quality}, ... }
Session.currentBoss      = "Unknown"
Session.currentItemIdx   = 0  -- which item is being rolled on

-- Per-item roll responses: { [itemIdx] = { [playerName] = { choice, roll } } }
Session.responses        = {}

-- Per-item results: { [itemIdx] = { winner, roll, choice, newCount } }
Session.results          = {}

-- Historical per-boss data for current session (for roll frame dropdown)
-- { [bossName] = { items = {}, results = {} } }
Session.bossHistory      = {}
Session.bossHistoryOrder = {} -- ordered list of boss keys (insertion order)

-- Trade queue: { { winner = "Name-Realm", itemLink = "...", awarded = false } }
Session.tradeQueue       = {}

-- Active session ID (time() at session start); nil when idle
Session.activeSessionId  = nil

-- Roll timer handle
Session._timerHandle          = nil
-- 1-second repeating ticker that broadcasts TIMER_TICK to the group (leader-only)
Session._tickBroadcastHandle  = nil

-- Cinematic gating (shared: LM + member)
Session._inCinematic            = false  -- true while a cinematic/movie is playing
Session._readyForLootTable      = true   -- false while in cinematic (member side)
Session._pendingLTRCLeader      = nil    -- member: leader to ack once cinematic ends
Session._pendingLootTable       = nil    -- member: LOOT_TABLE payload that arrived mid-cinematic

-- LM: items captured while LM was in a cinematic (queued for after CINEMATIC_STOP)
Session._pendingCapturedItems   = nil
Session._pendingCapturedBoss    = nil

-- Per-roll timer override in seconds (Manual Roll "Timer" dropdown).  Set by
-- the authority when items are captured and carried in LOOT_TABLE so every
-- member's countdown matches; nil means "use the session's rollTimer".
Session._rollTimerOverride      = nil

-- True while a roll is paused because the loot authority entered a
-- cinematic.  Resolved items keep their results; unresolved items are
-- re-opened with a fresh timer when the cinematic ends.
Session._suspendedRoll          = false

-- LM: items waiting for manual "Start Roll" confirmation (promptForStart mode)
Session._pendingPromptItems = nil
Session._pendingPromptBoss  = nil

-- LM: per-player LOOT_TABLE delivery tracking during an active roll
Session._readyCheckPlayers      = {}    -- { [playerName] = true(delivered)/false(waiting) }
Session._readyCheckAttempts     = {}    -- { [playerName] = number of LTRC whispers sent }
Session._readyCheckTimer        = nil   -- AceTimer handle for 1s retry
-- Stop re-whispering LOOT_TABLE_READY_CHECK after this many attempts per
-- player.  Players without the addon never ack; without a cap they would be
-- whispered every second for the whole roll.
Session.READY_CHECK_MAX_ATTEMPTS = 5
Session._readyCheckSerializable = nil   -- serialized items for per-player whispers
Session._currentBossGUIDs       = {}    -- boss unit GUIDs for this roll (sent in LOOT_TABLE)

-- Resume prompt state
Session._pendingResumableSession  = nil   -- set when exactly one resumable session found
Session._pendingResumableSessions = nil   -- set when multiple resumable sessions found


-- Eligible players for the current loot roll (leader-only).
-- Snapshot of group members at the time LOOT_TABLE is sent.
-- Players who join after the roll starts are excluded; players who leave
-- are auto-passed so AllResponded() is not permanently blocked.
Session._rollEligiblePlayers = {}  -- { ["Name-Realm"] = true }

-- Debug mode
Session.debugMode           = false
Session._testLootMode       = false  -- true during a one-shot test loot from CheckPartyFrame
Session._remoteDebug        = false  -- member side: the leader's session is a debug / test session
Session._leaderLeftNotified = false  -- "session leader left" notice printed once per absence
Session._currentHistoryKey  = nil    -- bossHistory key the current loot table was saved under
Session._savedState         = nil  -- saved session state before debug
Session._debugFakePlayers   = {}   -- ordered list of fake player Name-Realm strings
Session._debugFakePlayerSet = {}   -- set for O(1) lookup { [name] = true }

------------------------------------------------------------------------
-- Helper: is nameRealm a current WoW group leader or officer?
-- Used to verify SESSION_TAKEOVER sender without trusting self.leaderName.
------------------------------------------------------------------------
function Session.IsGroupLeaderOrOfficer(nameRealm)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local rName, rank = GetRaidRosterInfo(i)
            if rName and ns.NamesEqual(rName, nameRealm) and rank >= 1 then
                return true
            end
        end
        return false
    elseif IsInGroup() then
        -- Party: the leader can be any slot, including the local player.
        if UnitIsGroupLeader("player")
                and ns.NamesEqual(ns.GetPlayerNameRealm(), nameRealm) then
            return true
        end
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            if UnitIsGroupLeader(unit)
                    and ns.NamesEqual(GetUnitName(unit, true) or "", nameRealm) then
                return true
            end
        end
        return false
    end
    -- Solo: only our own self-whisper (debug / test sessions) is "leader".
    -- Anyone can whisper us while we are solo; they must not pass this gate.
    return ns.Comm:IsSelf(nameRealm)
end

------------------------------------------------------------------------
-- Resume-session confirmation popup (single resumable session found)
------------------------------------------------------------------------
-- Shown to the raid group leader: can resume OR start fresh
StaticPopupDialogs["OLL_RESUME_SESSION"] = {
    text           = "A session from this week was found (%s).\nBosses: %s\n\nResume it or start fresh?",
    button1        = "Resume",
    button2        = "Start Fresh",
    OnAccept       = function() ns.Session:_ExecuteResume() end,
    OnCancel       = function() ns.Session:_ExecuteStartFresh() end,
    timeout        = 0,
    whileDead      = true,
    hideOnEscape   = true,
    preferredIndex = 3,
}

-- Shown to a previous LM who is not the current raid leader: can only resume
StaticPopupDialogs["OLL_RESUME_SESSION_LM"] = {
    text           = "A session from this week was found (%s).\nBosses: %s\n\nWould you like to resume it?",
    button1        = "Resume",
    button2        = "Cancel",
    OnAccept       = function() ns.Session:_ExecuteResume() end,
    OnCancel       = function() ns.Session._pendingResumableSession = nil end,
    timeout        = 0,
    whileDead      = true,
    hideOnEscape   = true,
    preferredIndex = 3,
}

------------------------------------------------------------------------
-- Interrupted-session restore prompt (leader logged back in after a
-- /reload or disconnect while their session was active).
------------------------------------------------------------------------
StaticPopupDialogs["OLL_RESTORE_SESSION"] = {
    text           = "An OLL loot session you were leading was interrupted (%s, last boss: %s).\n\nRestore it and re-sync the group?",
    button1        = "Restore",
    button2        = "Discard",
    OnAccept       = function() ns.Session:_RestoreInterruptedSession() end,
    OnCancel       = function() ns.Session:_DiscardInterruptedSession() end,
    timeout        = 0,
    whileDead      = true,
    hideOnEscape   = false,
    preferredIndex = 3,
}

------------------------------------------------------------------------
-- SESSION PERSISTENCE (leader only)
-- The session leader mirrors the live session into
-- ns.db.global.activeSession so a /reload, crash or disconnect does not
-- lose it.  Written on PLAYER_LOGOUT (covers /reload) and, debounced,
-- after every state change (covers crashes).  Cleared by EndSession.
------------------------------------------------------------------------
function Session:_PersistActiveSession()
    self:_PersistAuthorityRoll()
    if not self:IsActive() or self.debugMode or self._testLootMode then return end
    if not ns.NamesMatch(ns.GetPlayerNameRealm(), self.leaderName) then return end
    if not self.activeSessionId then return end

    ns.db.global.activeSession = {
        id               = self.activeSessionId,
        leaderName       = self.leaderName,
        savedAt          = time(),
        state            = self.state,
        sessionSettings  = self.sessionSettings,
        rollOptions      = self.rollOptions,
        currentItems     = self.currentItems,
        currentBoss      = self.currentBoss,
        bossGUIDs        = self._currentBossGUIDs,
        responses        = self.responses,
        results          = self.results,
        bossHistory      = self.bossHistory,
        bossHistoryOrder = self.bossHistoryOrder,
        historyKey       = self._currentHistoryKey,
        tradeQueue       = self.tradeQueue,
        pendingPrompt    = self._pendingPromptItems and {
            items = self._pendingPromptItems, bossName = self._pendingPromptBoss } or nil,
    }
end

------------------------------------------------------------------------
-- LOOT-MASTER ROLL PERSISTENCE
-- A loot master who is not the session leader owns the roll in flight
-- (items, choices, rolls, results) but nothing else about the session, so
-- only that is mirrored, into ns.db.global.authorityRoll.  Written through
-- the same debounced path as the leader mirror; consumed on rejoin by
-- _MaybeRestoreAuthorityRoll once SESSION_JOIN has re-established the
-- session and confirmed this player is still the loot authority.
------------------------------------------------------------------------
function Session:_PersistAuthorityRoll()
    local me = ns.GetPlayerNameRealm()
    local rolling = self:IsActive() and not self.debugMode and not self._testLootMode
        and self.activeSessionId ~= nil
        and self:IsLootAuthority()
        and not ns.NamesMatch(me, self.leaderName)
        and (self.state == self.STATE_ROLLING or self.state == self.STATE_RESOLVING)
        and #(self.currentItems or {}) > 0
    if not rolling then
        -- Only drop our own stale mirror while we know the session state;
        -- at login (session not yet re-joined) it must survive for restore.
        local saved = ns.db.global.authorityRoll
        if self:IsActive() and saved and ns.NamesMatch(saved.authority, me) then
            ns.db.global.authorityRoll = nil
        end
        return
    end
    ns.db.global.authorityRoll = {
        sessionId         = self.activeSessionId,
        authority         = me,
        savedAt           = time(),
        currentItems      = self.currentItems,
        currentBoss       = self.currentBoss,
        bossGUIDs         = self._currentBossGUIDs,
        responses         = self.responses,
        results           = self.results,
        rollTimerOverride = self._rollTimerOverride,
    }
end

-- Called from OnSessionJoinReceived: if this player was the loot authority
-- of the session just re-joined and a roll was in flight, load it back and
-- re-open the unresolved items for the group.
function Session:_MaybeRestoreAuthorityRoll()
    local saved = ns.db.global.authorityRoll
    if not saved then return end
    local me = ns.GetPlayerNameRealm()
    if not ns.NamesMatch(saved.authority or "", me) then return end
    if saved.sessionId ~= self.activeSessionId or not self:IsLootAuthority() then
        ns.db.global.authorityRoll = nil
        return
    end
    ns.db.global.authorityRoll = nil

    self.currentItems       = saved.currentItems or {}
    self.currentBoss        = saved.currentBoss or "Unknown"
    self.currentItemIdx     = 0
    self._currentBossGUIDs  = saved.bossGUIDs or {}
    self.responses          = saved.responses or {}
    self.results            = saved.results or {}
    self._rollTimerOverride = saved.rollTimerOverride
    for idx = 1, #self.currentItems do
        self.responses[idx] = self.responses[idx] or {}
    end

    if self:_ReopenUnresolvedRoll() then
        ns.ChatPrint("Normal", "Interrupted loot roll for " .. self.currentBoss
            .. " restored; unresolved items re-opened for the group.")
        if ns.LeaderFrame then ns.LeaderFrame:Show(); ns.LeaderFrame:Refresh() end
    end
    self:_PersistActiveSession()
end

------------------------------------------------------------------------
-- Re-open a roll loaded from a saved mirror: unresolved items get a fresh
-- timer, members receive the item table, the already-decided results and
-- authoritative counts.  Returns true if anything was re-opened.
-- Shared by the leader restore and the loot-master restore.
------------------------------------------------------------------------
function Session:_ReopenUnresolvedRoll()
    local unresolved = false
    for idx = 1, #self.currentItems do
        if not self.results[idx] then unresolved = true break end
    end
    if #self.currentItems == 0 or not unresolved then return false end

    self.state = self.STATE_ROLLING
    self._rollEligiblePlayers = self:_SnapshotGroupMembers()
    self:_ClearUnresolvedResponses()

    -- Members: full item table, then the already-decided results, then
    -- authoritative counts (members self-increment on ROLL_RESULT).
    local serializable = {}
    for i, item in ipairs(self.currentItems) do
        tinsert(serializable, {
            num = i, rollID = item.rollID, icon = item.icon, name = item.name,
            link = item.link, quality = item.quality, kind = item.kind,
        })
    end
    ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE, {
        items = serializable, bossName = self.currentBoss, bossGUIDs = self._currentBossGUIDs,
        rollTimer = self._rollTimerOverride,
    })
    for idx = 1, #self.currentItems do
        local r = self.results[idx]
        if r then
            ns.Comm:BroadcastRollResult(idx, r.winner, r.roll, r.tiebreakerRoll, r.choice, nil)
        end
    end
    ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })

    self:_StartRollTimer()
    self:_RefreshRollFrames()
    return true
end

-- Debounced persist: many state changes arrive in bursts (one per response).
function Session:_SchedulePersist()
    if self._persistTimer then return end
    self._persistTimer = C_Timer.NewTimer(1, function()
        self._persistTimer = nil
        self:_PersistActiveSession()
    end)
end

function Session:_ClearPersistedSession()
    if self._persistTimer then
        self._persistTimer:Cancel()
        self._persistTimer = nil
    end
    ns.db.global.activeSession = nil
    ns.db.global.authorityRoll = nil
end

------------------------------------------------------------------------
-- LOGIN: offer to restore an interrupted session this character led.
------------------------------------------------------------------------
function Session:_CheckInterruptedSession()
    local saved = ns.db.global.activeSession
    if not saved or not saved.id then return end
    if self:IsActive() then return end

    -- Saved by another character on this account: leave it for them.
    if not ns.NamesMatch(saved.leaderName, ns.GetPlayerNameRealm()) then return end

    -- Older than the current lockout: stale, drop it.
    if saved.id < ns.GetCurrentWeeklyResetTime() then
        self:_DiscardInterruptedSession(saved)
        return
    end

    self._pendingInterrupted = saved
    StaticPopup_Show("OLL_RESTORE_SESSION",
        date("%b %d %H:%M", saved.id),
        saved.currentBoss or "none")
end

------------------------------------------------------------------------
-- LOGIN (members): a /reload does not change the roster, so the leader
-- never notices we dropped out.  Ask the group; the session leader whispers
-- SESSION_JOIN back and, if we were the loot master mid-roll, the roll is
-- restored from ns.db.global.authorityRoll on receipt.
------------------------------------------------------------------------
function Session:_RequestSessionState()
    if self:IsActive() or self._pendingInterrupted then return end
    if not (IsInGroup() or IsInRaid()) then return end

    -- Drop a loot-master mirror from a previous lockout.
    local saved = ns.db.global.authorityRoll
    if saved and (not saved.sessionId or saved.sessionId < ns.GetCurrentWeeklyResetTime()) then
        ns.db.global.authorityRoll = nil
    end

    ns.Comm:Send(ns.Comm.MSG.SESSION_REQUEST, { v = ns.VERSION })
end

function Session:OnSessionRequestReceived(payload, sender)
    if not self:IsActive() then return end
    if not ns.NamesMatch(ns.GetPlayerNameRealm(), self.leaderName) then return end
    if ns.Comm:IsSelf(sender) then return end
    self:_SendSessionJoin(sender)
end

-- Whisper the full late-join bootstrap to one player.
function Session:_SendSessionJoin(player)
    ns.Comm:Send(ns.Comm.MSG.SESSION_JOIN, {
        leaderName  = ns.GetPlayerNameRealm(),
        sessionId   = self.activeSessionId,
        settings    = self.sessionSettings,
        rollOptions = self.rollOptions,
        counts      = ns.LootCount:GetCountsTable(),
        debug       = self.debugMode and true or nil,
    }, player)
end

-- Discard: close the session record so it can still be resumed the normal
-- way (via /oll start) later this lockout.
function Session:_DiscardInterruptedSession(saved)
    saved = saved or self._pendingInterrupted
    self._pendingInterrupted = nil
    if saved and saved.id then
        for _, rec in ipairs(ns.db.global.sessionHistory) do
            if rec.id == saved.id and not rec.endTime then
                rec.endTime = saved.savedAt or time()
                rec.savedSettings = rec.savedSettings or saved.sessionSettings
                break
            end
        end
    end
    ns.db.global.activeSession = nil
end

------------------------------------------------------------------------
-- Restore the interrupted session, re-sync the group, and if a roll was
-- in flight re-open its unresolved items with a fresh timer.
------------------------------------------------------------------------
function Session:_RestoreInterruptedSession()
    local saved = self._pendingInterrupted
    self._pendingInterrupted = nil
    if not saved then return end
    if self:IsActive() then
        ns.ChatPrint("Normal", "A session is already active; interrupted session discarded.")
        ns.db.global.activeSession = nil
        return
    end

    local me = ns.GetPlayerNameRealm()
    self:_ResetRollState()
    self.state           = self.STATE_ACTIVE
    self.leaderName      = me
    self.activeSessionId = saved.id
    self.rollOptions     = saved.rollOptions or ns.Settings:GetRollOptions()

    local ss = saved.sessionSettings or {}
    self.sessionSettings              = saved.sessionSettings
    self.sessionDisenchanter          = ss.disenchanter or ""
    self.sessionLootMaster            = (ss.lootMaster and ss.lootMaster ~= "") and ss.lootMaster or me
    self.sessionLootMasterRestriction = ss.lootMasterRestriction or "anyLeader"
    self.sessionLootCountEnabled      = ss.lootCountEnabled ~= false
    self.sessionLootCountLockedToMain = ss.lootCountLockedToMain ~= false

    self.currentItems      = saved.currentItems or {}
    self.currentBoss       = saved.currentBoss or "Unknown"
    self.currentItemIdx    = 0
    self.responses         = saved.responses or {}
    self.results           = saved.results or {}
    self.bossHistory       = saved.bossHistory or {}
    self.bossHistoryOrder  = saved.bossHistoryOrder or {}
    self._currentHistoryKey = saved.historyKey
    self.tradeQueue        = saved.tradeQueue or {}
    self._currentBossGUIDs = saved.bossGUIDs or {}
    for idx = 1, #self.currentItems do
        self.responses[idx] = self.responses[idx] or {}
    end

    -- Re-open the session record
    self:_UpsertSessionStub(saved.id, me, self.sessionLootMaster)

    self._lastGroupSnapshot = self:_SnapshotGroupMembers()
    ns.PlayerLinks:MergePlayerCharList(ns.PlayerLinks:GetMyCharactersPayload())

    -- Re-sync the group: same messages ResumeSession sends
    ns.Comm:BroadcastSessionResume(self.sessionSettings or {}, self.rollOptions, saved.id, self.bossHistoryOrder)
    ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })
    ns.Comm:Send(ns.Comm.MSG.LINKS_SYNC, { links = ns.PlayerLinks:GetLinksTable() })

    -- Pending "Start Roll" prompt (promptForStart mode)
    if saved.pendingPrompt and saved.pendingPrompt.items then
        self._pendingPromptItems = saved.pendingPrompt.items
        self._pendingPromptBoss  = saved.pendingPrompt.bossName
        if ns.LeaderFrame then
            ns.LeaderFrame:OnPendingRollReady(self._pendingPromptItems, self._pendingPromptBoss)
        end
    end

    -- Roll in flight (leader is the loot authority): re-open unresolved
    -- items with a fresh timer.  A roll owned by a different loot master is
    -- theirs to restore (see _MaybeRestoreAuthorityRoll).
    if self:IsLootAuthority() then
        self:_ReopenUnresolvedRoll()
    end

    if ns.LeaderFrame then ns.LeaderFrame:Show() end
    self:_PersistActiveSession()
    ns.ChatPrint("Normal", "Interrupted loot session restored and re-synced to the group.")
end

------------------------------------------------------------------------
-- Fake player name pool (used only in debug mode)
------------------------------------------------------------------------
local FAKE_PLAYER_FIRST = {
    "Arendal", "Bryndis", "Caelar", "Dorthia", "Elowen",
    "Faendal", "Gwyndar", "Halvath", "Ilindra", "Jorath",
    "Kyara",   "Lyrath",  "Maldra", "Nythis",  "Orfin",
}
local FAKE_PLAYER_REALM = "Falanaar"

------------------------------------------------------------------------
-- Is the session active?
------------------------------------------------------------------------
function Session:IsActive()
    return self.state ~= self.STATE_IDLE
end

------------------------------------------------------------------------
-- Is loot count enabled for the current session?
-- Uses the synced session value when active; falls back to the local
-- profile when idle (e.g. for Settings UI display).
------------------------------------------------------------------------
function Session:IsLootCountEnabled()
    if self:IsActive() and self.sessionLootCountEnabled ~= nil then
        return self.sessionLootCountEnabled
    end
    return ns.db.profile.lootCountEnabled ~= false
end

------------------------------------------------------------------------
-- Are loot counts locked to a player's main (shared across linked alts)?
-- Uses the synced session value when active; falls back to the local
-- profile when idle (e.g. for Settings UI display).
------------------------------------------------------------------------
function Session:IsLootCountLockedToMain()
    if self:IsActive() and self.sessionLootCountLockedToMain ~= nil then
        return self.sessionLootCountLockedToMain
    end
    return ns.db.profile.lootCountLockedToMain ~= false
end

------------------------------------------------------------------------
-- START SESSION (Leader only)
------------------------------------------------------------------------
function Session:StartSession()
    local isSolo       = not IsInGroup() and not IsInRaid()
    local isGroupLeader = isSolo or UnitIsGroupLeader("player")

    if self:IsActive() and not isGroupLeader then
        ns.ChatPrint("Normal", "A session is already active.")
        return
    end
    -- A group leader may force-start over a running session.  The running
    -- session is closed only when a fresh start or resume actually executes
    -- (see _CloseForRestart), so dismissing the prompt leaves it intact.

    -- Only the raid group leader can start a fresh session.
    -- A previous LM (non-leader) may resume a session but not start fresh.
    local resumables    = self:_GetResumableSessions()

    if not isGroupLeader and #resumables == 0 then
        ns.ChatPrint("Normal", "Only the raid leader can start a loot session.")
        return
    end

    -- Show resume prompt if sessions from this lockout are available
    if #resumables == 1 then
        self._pendingResumableSession = resumables[1]
        local dateStr = date("%b %d %H:%M", resumables[1].startTime)
        local bossStr = #resumables[1].bosses > 0
            and table.concat(resumables[1].bosses, ", ") or "None"
        if #bossStr > 80 then bossStr = bossStr:sub(1, 77) .. "..." end
        -- Raid leader gets a "Start Fresh" option; LM-only gets "Cancel"
        local popup = isGroupLeader and "OLL_RESUME_SESSION" or "OLL_RESUME_SESSION_LM"
        StaticPopup_Show(popup, dateStr, bossStr)
        return
    elseif #resumables > 1 then
        self._pendingResumableSessions = resumables
        if ns.SessionResumeFrame then
            ns.SessionResumeFrame:Show(resumables, isGroupLeader)
        end
        return
    end

    -- Raid leader, no resumable sessions: start fresh immediately
    self:_ExecuteStartFresh()
end

------------------------------------------------------------------------
-- Reset all per-roll state left over from a previous session or roll.
-- Called when a session starts or resumes so nothing stale (eligible
-- players, lockout flag, timer bookkeeping) leaks into the new session.
------------------------------------------------------------------------
function Session:_ResetRollState()
    self:_CleanupReadyCheck()
    self._rollEligiblePlayers    = {}
    self._lockedOutOfCurrentBoss = false
    self._timerExpired           = false
    self._rollTimerStart         = nil
    self._rollTimerDuration      = nil
    self._currentBossGUIDs       = {}
    self._pendingLootTable       = nil
    self._pendingLTRCLeader      = nil
    self._pendingCapturedItems   = nil
    self._pendingCapturedBoss    = nil
    self._pendingCapturedGUIDs   = nil
    self._suspendedRoll          = false
    self._rollTimerOverride      = nil
    if ns.Comm then ns.Comm._lastTimerRemaining = nil end
end

------------------------------------------------------------------------
-- EXECUTE START FRESH (extracted body of the original StartSession)
------------------------------------------------------------------------
------------------------------------------------------------------------
-- Close whatever session is running on this client before a fresh start
-- or a resume replaces it: closes the old record, tells the group, and
-- drops the /reload mirror.  No-op when idle.
------------------------------------------------------------------------
function Session:_CloseForRestart()
    if not self:IsActive() then return end
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    if self.activeSessionId then
        for _, s in ipairs(ns.db.global.sessionHistory) do
            if s.id == self.activeSessionId then
                s.endTime = s.endTime or time()
                break
            end
        end
    end
    self.state           = self.STATE_IDLE
    self.activeSessionId = nil
    self._suspendedRoll  = false
    if not self.debugMode then
        ns.Comm:Send(ns.Comm.MSG.SESSION_END, {})
    end
    self:_ClearPersistedSession()
end

function Session:_ExecuteStartFresh()
    self:_CloseForRestart()
    -- A stale member-side debug overlay (lost SESSION_END) must not swallow
    -- a real session's counts.
    self:_SetRemoteDebug(false)
    -- Cancel any lingering roll timer from a previous or rogue session.
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    -- Clear any pending WoW group loot roll tracking in LootHandler.
    if ns.LootHandler then
        ns.LootHandler._pendingRolls      = {}
        ns.LootHandler._capturedRollItems = {}
    end

    self._pendingResumableSession  = nil
    self._pendingResumableSessions = nil
    if ns.SessionResumeFrame then ns.SessionResumeFrame:Hide() end

    self.state = self.STATE_ACTIVE
    self.leaderName = ns.GetPlayerNameRealm()
    self.currentItems = {}
    self.currentBoss = "Unknown"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}
    self.bossHistory = {}
    self.bossHistoryOrder = {}
    self.tradeQueue = {}
    self._pendingPromptItems = nil
    self._pendingPromptBoss  = nil
    ns.db.global.pendingRoll = nil  -- discard any leftover pending roll from a previous session
    self:_ResetRollState()
    self.rollOptions           = ns.Settings:GetRollOptions()
    self.sessionDisenchanter         = ns.db.profile.disenchanter or ""
    self.sessionLootMaster           = ns.GetPlayerNameRealm() -- default: session starter is loot master
    self.sessionLootMasterRestriction = ns.db.profile.lootMasterRestriction or "anyLeader"
    self.sessionLootCountEnabled      = ns.db.profile.lootCountEnabled ~= false
    self.sessionLootCountLockedToMain = ns.db.profile.lootCountLockedToMain ~= false

    -- Record session in persistent history.  Ids are timestamps; two
    -- sessions in the same second must still get distinct keys.
    local sid = time()
    local taken = true
    while taken do
        taken = false
        for _, s in ipairs(ns.db.global.sessionHistory) do
            if s.id == sid then taken = true; sid = sid + 1; break end
        end
    end
    self.activeSessionId = sid
    table.insert(ns.db.global.sessionHistory, {
        id          = sid,
        startTime   = sid,
        endTime     = nil,
        leader      = self.leaderName,
        bosses      = {},
        lootMasters = { self.sessionLootMaster },
    })

    -- Everyone currently in the group receives SESSION_START; only players who
    -- join later need a SESSION_JOIN whisper (see OnGroupRosterUpdate).
    self._lastGroupSnapshot = self:_SnapshotGroupMembers()

    -- Apply leader's own character list to playerLinks before broadcasting
    ns.PlayerLinks:MergePlayerCharList(ns.PlayerLinks:GetMyCharactersPayload())

    -- The leader keeps the same settings table it broadcasts.  Our own
    -- SESSION_START is no longer echoed back, so this is the only place the
    -- leader's sessionSettings is populated.
    self.sessionSettings = {
        lootThreshold         = ns.db.profile.lootThreshold,
        rollTimer             = ns.db.profile.rollTimer,
        autoPassBOE           = ns.db.profile.autoPassBOE,
        announceChannel       = ns.db.profile.announceChannel,
        disenchanter          = self.sessionDisenchanter,
        lootMaster            = self.sessionLootMaster,
        lootMasterRestriction = self.sessionLootMasterRestriction,
        lootCountEnabled      = self.sessionLootCountEnabled,
        lootCountLockedToMain = self.sessionLootCountLockedToMain,
        tokensCountAsLoot     = ns.db.profile.tokensCountAsLoot  == true,
        recipesCountAsLoot    = ns.db.profile.recipesCountAsLoot == true,
    }

    -- Broadcast to group
    ns.Comm:BroadcastSessionStart(self.sessionSettings, self.rollOptions, self.activeSessionId)

    -- counts are included in SESSION_START; links are exchanged peer-to-peer via PLAYER_CHAR_LIST

    self:_PersistActiveSession()
    ns.ChatPrint("Normal", "Loot session started.")
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
    self:_MaybeShowHoldWPopup()
end

------------------------------------------------------------------------
-- EXECUTE RESUME (popup OnAccept callback — single session case)
------------------------------------------------------------------------
function Session:_ExecuteResume()
    local rec = self._pendingResumableSession
    self._pendingResumableSession = nil
    if rec then
        self:_CloseForRestart()
        self:ResumeSession(rec)
    end
end

------------------------------------------------------------------------
-- EXECUTE RESUME FROM LIST (SessionResumeFrame row button callback)
------------------------------------------------------------------------
function Session:_ExecuteResumeFromList(rec)
    self._pendingResumableSessions = nil
    if ns.SessionResumeFrame then ns.SessionResumeFrame:Hide() end
    self:_CloseForRestart()
    self:ResumeSession(rec)
end

------------------------------------------------------------------------
-- END SESSION (Leader only)
------------------------------------------------------------------------
function Session:EndSession()
    if not self:IsActive() then
        ns.ChatPrint("Normal", "No loot session is active.")
        return
    end
    if not ns.IsLeader() and not ns.NamesEqual(self.leaderName, ns.GetPlayerNameRealm()) then
        ns.ChatPrint("Normal", "Only the session leader can end the session.")
        return
    end

    -- Cancel any active timer
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end

    self.state                        = self.STATE_IDLE
    self._suspendedRoll               = false
    self.sessionSettings              = nil
    self.sessionDisenchanter          = nil
    self.sessionLootMaster            = nil
    self.sessionLootMasterRestriction = nil
    self.sessionLootCountEnabled      = nil
    self.sessionLootCountLockedToMain = nil
    self._pendingPromptItems          = nil
    self._pendingPromptBoss           = nil
    ns.db.global.pendingRoll          = nil

    -- Close the active session record and broadcast final snapshot to members
    if self.activeSessionId then
        local sid = self.activeSessionId
        for _, s in ipairs(ns.db.global.sessionHistory) do
            if s.id == sid then
                -- Save current session settings so the session can be resumed later
                s.savedSettings = {
                    lootMaster            = self.sessionLootMaster,
                    lootMasterRestriction = self.sessionLootMasterRestriction,
                    lootCountEnabled      = self.sessionLootCountEnabled,
                    lootCountLockedToMain = self.sessionLootCountLockedToMain,
                    tokensCountAsLoot     = self.sessionSettings and self.sessionSettings.tokensCountAsLoot  == true,
                    recipesCountAsLoot    = self.sessionSettings and self.sessionSettings.recipesCountAsLoot == true,
                    disenchanter          = self.sessionDisenchanter,
                    rollOptions           = self.rollOptions,
                    rollTimer             = ns.db.profile.rollTimer,
                    lootThreshold         = ns.db.profile.lootThreshold,
                    autoPassBOE           = ns.db.profile.autoPassBOE,
                    announceChannel       = ns.db.profile.announceChannel,
                }
                s.endTime = time()
                break
            end
        end
        local snap = self:_GetSessionSnapshot()
        if snap then ns.Comm:Send(ns.Comm.MSG.SESSION_SYNC, { session = snap }) end
        self.activeSessionId = nil
    end

    -- Broadcast end
    ns.Comm:Send(ns.Comm.MSG.SESSION_END, {})
    self:_ClearPersistedSession()

    ns.ChatPrint("Normal", "Loot session ended.")

    -- Hide frames
    if ns.LeaderFrame then ns.LeaderFrame:Hide() end
    if ns.RollFrame then ns.RollFrame:Hide() end
    if ns.DebugWindow then ns.DebugWindow:Hide() end
    if ns.LeaderFrame and ns.LeaderFrame._reassignPopup then
        ns.LeaderFrame._reassignPopup:Hide()
    end
end

------------------------------------------------------------------------
-- TAKE OVER SESSION (any current WoW leader/officer, not already leader)
------------------------------------------------------------------------
function Session:TakeoverSession()
    if not ns.IsLeader() then
        ns.ChatPrint("Normal", "Only a group leader or officer can take over a session.")
        return
    end

    if not self:IsActive() then
        ns.ChatPrint("Normal", "No active session to take over.")
        return
    end

    local me = ns.GetPlayerNameRealm()
    if ns.NamesMatch(me, self.leaderName) then
        ns.ChatPrint("Normal", "You are already the session leader.")
        return
    end

    if self.state == self.STATE_ROLLING or self.state == self.STATE_RESOLVING then
        ns.ChatPrint("Normal", "Cannot take over during an active roll. Wait for the current roll to finish.")
        return
    end

    -- Find the most recent open session record to inherit its ID
    local inheritId = nil
    local latestStart = 0
    for _, s in ipairs(ns.db.global.sessionHistory) do
        if not s.endTime and s.startTime > latestStart then
            inheritId  = s.id
            latestStart = s.startTime
        end
    end

    local oldLeader = self.leaderName
    self.leaderName      = me
    self.activeSessionId = inheritId  -- EndSession handles nil gracefully if history missing
    -- The loot master role follows the leader only when the old leader held
    -- it by default; an explicitly assigned loot master keeps it.
    if not self.sessionLootMaster or self.sessionLootMaster == ""
            or ns.NamesEqual(self.sessionLootMaster, oldLeader) then
        self.sessionLootMaster = me
        if self.sessionSettings then self.sessionSettings.lootMaster = me end
    end
    -- Current members already hold the session; only later joiners get SESSION_JOIN.
    self._lastGroupSnapshot = self:_SnapshotGroupMembers()

    ns.Comm:BroadcastSessionTakeover(me, self.sessionSettings, self.rollOptions, inheritId)

    self:_PersistActiveSession()
    ns.ChatPrint("Normal", "You have assumed session control.")

    -- Announce the leadership change to the group
    local channel = ns.GetAnnounceChannel()
    local meName = ns.StripRealm(me)
    SendChatMessage("[OLL] " .. meName .. " has taken over as session leader.", channel)

    if ns.LeaderFrame and ns.LeaderFrame._frame and ns.LeaderFrame._frame:IsShown() then
        ns.LeaderFrame:Refresh()
    end
end

------------------------------------------------------------------------
-- Hold W Mode session popup
-- Shown when a player (leader or member) joins any session while
-- Hold W Mode is enabled. Offers to keep it active or disable it.
------------------------------------------------------------------------
StaticPopupDialogs["OLL_HOLDW_SESSION"] = {
    text         = "Hold 'W' Mode is enabled.\n\nKeep it active for this session? All loot will be silently auto-passed.",
    button1      = "Keep Active",
    button2      = "Disable",
    OnCancel     = function()
        ns.db.profile.holdWMode = false
        if ns.Settings then ns.Settings:RefreshSection("general") end
        ns.ChatPrint("Normal", "Hold 'W' Mode disabled.")
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = false,
}

-- Ask once per session whether Hold 'W' Mode should stay on.
function Session:_MaybeShowHoldWPopup()
    if ns.db.profile.holdWMode ~= true then return end
    local sid = self.activeSessionId or 0
    if self._holdWPromptedFor == sid then return end
    self._holdWPromptedFor = sid
    StaticPopup_Show("OLL_HOLDW_SESSION")
end

------------------------------------------------------------------------
-- Join-restriction helpers (used by OnSessionStartReceived)
------------------------------------------------------------------------
local function _IsFriend(nameRealm)
    local name = nameRealm:match("^(.-)%-") or nameRealm

    -- Check regular (in-game) friends list
    local numFriends = C_FriendList.GetNumFriends()
    for i = 1, numFriends do
        local info = C_FriendList.GetFriendInfo(i)
        if info and info.name and info.name:lower() == name:lower() then
            return true
        end
    end

    -- Check Battle.net friends (all their WoW game accounts / characters)
    local numBNFriends = select(1, BNGetNumFriends())
    for i = 1, numBNFriends do
        local numAccounts = C_BattleNet.GetFriendNumGameAccounts(i)
        for j = 1, numAccounts do
            local gameAccountInfo = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if gameAccountInfo and gameAccountInfo.characterName then
                local charName = gameAccountInfo.characterName
                local realmName = gameAccountInfo.realmName
                local fullName = realmName and realmName ~= "" and (charName .. "-" .. realmName) or charName
                if ns.NamesMatch(fullName, nameRealm) then
                    return true
                end
            end
        end
    end

    return false
end

local function _IsGuildMember(nameRealm)
    if not IsInGuild() then return false end
    if ns.NamesEqual(ns.GetPlayerNameRealm(), nameRealm) then return true end
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then return false end
    -- party1..N-1 (the local player is not a partyN unit); raid1..N
    local last = IsInRaid() and numMembers or (numMembers - 1)
    for i = 1, last do
        local unitID = (IsInRaid() and "raid" or "party") .. i
        local unitName = GetUnitName(unitID, true) -- true = include realm
        if unitName and ns.NamesEqual(unitName, nameRealm) then
            return UnitIsInMyGuild(unitID)
        end
    end
    return false
end

------------------------------------------------------------------------
-- Ensure a session record with this id exists in local history so that a
-- non-leader loot master can append bosses / build SESSION_SYNC snapshots,
-- and so a former loot master can later resume the session.
------------------------------------------------------------------------
function Session:_UpsertSessionStub(sid, leader, lootMaster)
    if not sid then return end
    for _, s in ipairs(ns.db.global.sessionHistory) do
        if s.id == sid then
            s.endTime = nil
            if leader then s.leader = leader end
            if lootMaster and lootMaster ~= "" then
                s.lootMasters = s.lootMasters or {}
                if s.lootMasters[#s.lootMasters] ~= lootMaster then
                    table.insert(s.lootMasters, lootMaster)
                end
            end
            return
        end
    end
    table.insert(ns.db.global.sessionHistory, {
        id          = sid,
        startTime   = sid,
        endTime     = nil,
        leader      = leader,
        bosses      = {},
        lootMasters = (lootMaster and lootMaster ~= "") and { lootMaster } or {},
    })
end

------------------------------------------------------------------------
-- Member side of a debug / test-loot session.  The leader flags the
-- SESSION_START / SESSION_JOIN payload; while the flag is on, LootCount
-- routes every read and write into its shadow overlay so the counts this
-- session hands out never reach the real table.  The overlay is not
-- persisted, so a /reload or a lost SESSION_END cannot leak it either.
------------------------------------------------------------------------
function Session:_SetRemoteDebug(on)
    on = on and true or false
    if on == self._remoteDebug then return end
    self._remoteDebug = on
    if on then
        ns.LootCount:StartDebug()
    elseif not self.debugMode then
        ns.LootCount:EndDebug()
    end
end

------------------------------------------------------------------------
-- ON SESSION START RECEIVED (Members)
------------------------------------------------------------------------
function Session:OnSessionStartReceived(payload, sender)
    -- Only a current WoW group leader/officer may start a session on this
    -- client: SESSION_START replaces our loot counts and player links.  Same
    -- gate as SESSION_RESUME / SESSION_TAKEOVER.  The sender is the leader;
    -- payload.leaderName is informational and must agree with it.
    if not Session.IsGroupLeaderOrOfficer(sender) then return end
    if payload.leaderName and not ns.NamesEqual(payload.leaderName, sender) then return end

    -- Enforce join restrictions (friends / guild) on the leader.
    local restrictions = ns.db.profile.joinRestrictions
    if restrictions and (restrictions.friends or restrictions.guild)
            and not ns.Comm:IsSelf(sender) then
        local allowed = false
        if restrictions.friends and _IsFriend(sender) then
            allowed = true
        end
        if not allowed and restrictions.guild and _IsGuildMember(sender) then
            allowed = true
        end
        if not allowed then
            ns.ChatPrint("Normal", "|cffff4444OLL: Session from " .. sender
                .. " blocked by join restrictions.|r")
            return
        end
    end

    -- Cancel any active roll timer before applying new session state.
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    -- Clear any pending WoW group loot roll tracking in LootHandler.
    if ns.LootHandler then
        ns.LootHandler._pendingRolls      = {}
        ns.LootHandler._capturedRollItems = {}
    end

    self.state = self.STATE_ACTIVE
    self.leaderName = sender
    self.activeSessionId = payload.sessionId   -- nil for debug/test sessions
    self.rollOptions = payload.rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self.currentItems = {}
    self.responses = {}
    self.results = {}
    self.bossHistory = {}
    self.bossHistoryOrder = {}
    self.tradeQueue = {}
    self:_ClearPendingAcks()
    self:_SetRemoteDebug(payload.debug)

    -- Apply synced settings
    if payload.settings then
        -- Store session settings locally (don't overwrite profile)
        self.sessionSettings              = payload.settings
        self.sessionDisenchanter          = payload.settings.disenchanter or ""
        self.sessionLootMaster            = payload.settings.lootMaster or ""
        self.sessionLootMasterRestriction = payload.settings.lootMasterRestriction or "anyLeader"
        self.sessionLootCountEnabled      = payload.settings.lootCountEnabled ~= false
        self.sessionLootCountLockedToMain = payload.settings.lootCountLockedToMain ~= false
    end
    if payload.counts then
        ns.LootCount:SetCountsTable(payload.counts)
    end
    if payload.links then
        ns.PlayerLinks:SetLinksTable(payload.links)
    end
    self:_UpsertSessionStub(self.activeSessionId, self.leaderName, self.sessionLootMaster)

    -- Broadcast our own character list to the group so everyone can merge it.
    -- No wantResponse flag here: all members broadcast simultaneously, so each
    -- player will receive everyone else's broadcast without needing whisper-backs.
    local myChars = ns.PlayerLinks:GetMyCharactersPayload()
    if #myChars.chars > 0 then
        ns.Comm:Send(ns.Comm.MSG.PLAYER_CHAR_LIST, myChars)
    end

    if self._remoteDebug then
        ns.ChatPrint("Normal", "|cffff4444[DEBUG]|r Debug loot session started by " .. self.leaderName
            .. ". Your loot counts and history will not be affected.")
    else
        ns.ChatPrint("Normal", "Loot session started by " .. self.leaderName .. ".")
    end
    self:_MaybeShowHoldWPopup()
end

------------------------------------------------------------------------
-- ON SESSION JOIN RECEIVED (late-join whisper from leader)
------------------------------------------------------------------------
function Session:OnSessionJoinReceived(payload, sender)
    -- Same trust as SESSION_START: a group leader/officer, or the leader /
    -- loot master of the session we already know about.  A whisper naming
    -- the sender as leader is not evidence of anything.
    if not (Session.IsGroupLeaderOrOfficer(sender) or self:_IsTrustedSender(sender)) then
        return
    end
    if payload.leaderName and not ns.NamesEqual(payload.leaderName, sender) then return end

    -- Same teardown SESSION_START does: a rejoining member must not keep a
    -- live timer and expiry closure for a roll that is over.
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    self._suspendedRoll = false
    if ns.LootHandler then
        ns.LootHandler._pendingRolls      = {}
        ns.LootHandler._capturedRollItems = {}
    end

    -- Apply session state (same fields as SESSION_START, without links)
    self.leaderName      = sender
    self.activeSessionId = payload.sessionId
    self.state           = self.STATE_ACTIVE

    if payload.settings then
        self.sessionSettings              = payload.settings
        self.sessionDisenchanter          = payload.settings.disenchanter or ""
        self.sessionLootMaster            = payload.settings.lootMaster or ""
        self.sessionLootMasterRestriction = payload.settings.lootMasterRestriction or "anyLeader"
        self.sessionLootCountEnabled      = payload.settings.lootCountEnabled ~= false
        self.sessionLootCountLockedToMain = payload.settings.lootCountLockedToMain ~= false
    end
    if payload.rollOptions then
        self.rollOptions = payload.rollOptions
    end
    self:_SetRemoteDebug(payload.debug)
    if payload.counts then
        ns.LootCount:SetCountsTable(payload.counts)
    end
    self:_UpsertSessionStub(self.activeSessionId, self.leaderName, self.sessionLootMaster)

    -- Broadcast our char list and ask everyone to whisper theirs back so we
    -- can build a complete links picture without a full LINKS_SYNC rebroadcast.
    local myChars = ns.PlayerLinks:GetMyCharactersPayload()
    if #myChars.chars > 0 then
        myChars.wantResponse = true
        ns.Comm:Send(ns.Comm.MSG.PLAYER_CHAR_LIST, myChars)
    end

    ns.ChatPrint("Normal", "Joined loot session led by " .. self.leaderName .. ".")
    self:_MaybeShowHoldWPopup()
    self:_MaybeRestoreAuthorityRoll()
end

------------------------------------------------------------------------
-- ON SESSION END RECEIVED
------------------------------------------------------------------------
function Session:OnSessionEndReceived(payload, sender)
    -- Only the session's own leader / loot master or a current WoW group
    -- leader/officer may end the session on this client.
    if not (self:_IsTrustedSender(sender) or Session.IsGroupLeaderOrOfficer(sender)) then
        return
    end

    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end

    self.state                        = self.STATE_IDLE
    self.activeSessionId              = nil
    self._suspendedRoll               = false
    self.sessionSettings              = nil
    self.sessionDisenchanter          = nil
    self.sessionLootMaster            = nil
    self.sessionLootMasterRestriction = nil
    self.sessionLootCountEnabled      = nil
    self.sessionLootCountLockedToMain = nil
    self:_ClearPendingAcks()
    ns.db.global.authorityRoll = nil
    local wasDebug = self._remoteDebug
    self:_SetRemoteDebug(false)
    if wasDebug then
        ns.ChatPrint("Normal", "|cffff4444[DEBUG]|r Debug loot session ended. Your loot counts were not changed.")
    else
        ns.ChatPrint("Normal", "Loot session ended by leader.")
    end

    if ns.RollFrame then ns.RollFrame:Hide() end
    if ns.LeaderFrame then
        if ns.LeaderFrame._lootMasterPopup then ns.LeaderFrame._lootMasterPopup:Hide() end
        if ns.LeaderFrame._reassignPopup    then ns.LeaderFrame._reassignPopup:Hide()    end
        ns.LeaderFrame:Refresh()
    end
end

------------------------------------------------------------------------
-- SESSION SETTINGS SYNC (Members) – mid-session update from leader
------------------------------------------------------------------------
function Session:OnSettingsSyncReceived(payload, sender)
    if payload.rollTimer ~= nil and self.sessionSettings then
        self.sessionSettings.rollTimer = payload.rollTimer
    end
    if payload.lootThreshold ~= nil and self.sessionSettings then
        self.sessionSettings.lootThreshold = payload.lootThreshold
    end
    if payload.disenchanter ~= nil then
        self.sessionDisenchanter = payload.disenchanter
    end
    if payload.lootMaster ~= nil then
        self.sessionLootMaster = payload.lootMaster
    end
    if payload.lootMasterRestriction ~= nil then
        self.sessionLootMasterRestriction = payload.lootMasterRestriction
    end
end

------------------------------------------------------------------------
-- UPDATE SESSION ROLL TIMER / LOOT THRESHOLD (Leader only)
-- The session snapshot wins over the profile for the whole group; an edit
-- mid-session updates the snapshot and syncs it, applying from the next
-- roll / capture.
------------------------------------------------------------------------
function Session:UpdateSessionRollTimer(seconds)
    if not self.sessionSettings then return end
    self.sessionSettings.rollTimer = seconds
    if self:IsActive() then
        ns.Comm:Send(ns.Comm.MSG.SETTINGS_SYNC, { rollTimer = seconds })
        self:_SchedulePersist()
    end
end

function Session:UpdateSessionLootThreshold(quality)
    if not self.sessionSettings then return end
    self.sessionSettings.lootThreshold = quality
    if self:IsActive() then
        ns.Comm:Send(ns.Comm.MSG.SETTINGS_SYNC, { lootThreshold = quality })
        self:_SchedulePersist()
    end
end

------------------------------------------------------------------------
-- UPDATE SESSION DISENCHANTER (Leader only)
-- Called when the leader changes their disenchanter setting mid-session.
-- Updates the local session value and broadcasts to group members.
-- Never touches any player's profile DB.
------------------------------------------------------------------------
function Session:UpdateSessionDisenchanter(name)
    self.sessionDisenchanter = name or ""
    if self.sessionSettings then self.sessionSettings.disenchanter = self.sessionDisenchanter end
    if self:IsActive() then
        ns.Comm:Send(ns.Comm.MSG.SETTINGS_SYNC, { disenchanter = self.sessionDisenchanter })
        self:_SchedulePersist()
    end
end

------------------------------------------------------------------------
-- UPDATE SESSION LOOT MASTER (Leader only)
-- Updates the local session value and broadcasts to group members.
-- The loot master is the only player who auto-needs on group loot rolls.
------------------------------------------------------------------------
function Session:UpdateSessionLootMaster(name)
    self.sessionLootMaster = name or ""
    if self.sessionSettings then self.sessionSettings.lootMaster = self.sessionLootMaster end
    if self:IsActive() then
        ns.Comm:Send(ns.Comm.MSG.SETTINGS_SYNC, { lootMaster = self.sessionLootMaster })
        self:_SchedulePersist()
    end
    -- Track loot master changes in session record
    if self.activeSessionId and name and name ~= "" then
        local sid = self.activeSessionId
        for _, s in ipairs(ns.db.global.sessionHistory) do
            if s.id == sid then
                local last = s.lootMasters[#s.lootMasters]
                if last ~= name then
                    table.insert(s.lootMasters, name)
                end
                break
            end
        end
    end
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- UPDATE SESSION LOOT MASTER RESTRICTION (Leader only)
-- Updates the local session value and broadcasts to group members.
-- Never touches any player's profile DB.
------------------------------------------------------------------------
function Session:UpdateSessionLootMasterRestriction(value)
    self.sessionLootMasterRestriction = value or "anyLeader"
    if self.sessionSettings then self.sessionSettings.lootMasterRestriction = self.sessionLootMasterRestriction end
    if self:IsActive() then
        ns.Comm:Send(ns.Comm.MSG.SETTINGS_SYNC,
            { lootMasterRestriction = self.sessionLootMasterRestriction })
        self:_SchedulePersist()
    end
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- ON ITEMS CAPTURED (Leader – from LootHandler)
------------------------------------------------------------------------
function Session:OnItemsCaptured(items, bossName, bossGUIDs, rollTimer)
    if self.state ~= self.STATE_ACTIVE then return end

    self.currentItems = items
    self.currentBoss = bossName or "Unknown"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}
    self._currentHistoryKey = nil
    self._currentBossGUIDs = bossGUIDs or {}
    self._rollTimerOverride = (type(rollTimer) == "number" and rollTimer > 0) and rollTimer or nil

    -- Append boss to active session record (if not already present)
    if self.activeSessionId then
        local sid = self.activeSessionId
        for _, s in ipairs(ns.db.global.sessionHistory) do
            if s.id == sid then
                local found = false
                for _, b in ipairs(s.bosses) do if b == self.currentBoss then found = true; break end end
                if not found then table.insert(s.bosses, self.currentBoss) end
                break
            end
        end
    end

    -- Assign stable display numbers to items (leader-side)
    for i, item in ipairs(items) do
        item.num = i
    end

    -- If LM is in a cinematic, queue items and wait for CINEMATIC_STOP
    if self._inCinematic then
        self._pendingCapturedItems = items
        self._pendingCapturedBoss  = bossName
        self._pendingCapturedGUIDs = bossGUIDs
        self._pendingCapturedTimer = self._rollTimerOverride
        return
    end

    -- If "Prompt for Start" mode, pause and wait for LM to manually start the roll
    if ns.db.profile.lootRollTriggering == "promptForStart" then
        -- Build a serializable snapshot to persist across /reload
        local savedItems = {}
        for i, item in ipairs(items) do
            tinsert(savedItems, {
                num     = i,
                rollID  = item.rollID,
                icon    = item.icon,
                name    = item.name,
                link    = item.link,
                quality = item.quality,
                kind    = item.kind,
            })
        end
        ns.db.global.pendingRoll = { items = savedItems, bossName = bossName }

        self._pendingPromptItems = items
        self._pendingPromptBoss  = bossName
        if ns.LeaderFrame then
            ns.LeaderFrame:OnPendingRollReady(items, bossName)
        end
        self:_SchedulePersist()
        return
    end

    -- Strip functions / metatables for serialization
    local serializableItems = {}
    for i, item in ipairs(items) do
        tinsert(serializableItems, {
            num     = i,
            rollID  = item.rollID,
            icon    = item.icon,
            name    = item.name,
            link    = item.link,
            quality = item.quality,
            kind    = item.kind,
        })
    end

    -- Snapshot group before broadcast so AllResponded() is stable even if
    -- players leave after LOOT_TABLE is sent.
    self._rollEligiblePlayers = self:_SnapshotGroupMembers()

    -- Store serializable copy for per-player ready-check delivery
    self._readyCheckSerializable = serializableItems

    -- Start roll (timer + leader UI) immediately, then begin per-player delivery handshake
    self:_StartReadyCheck()
end

------------------------------------------------------------------------
-- START PENDING ROLL (Leader) — called by LeaderFrame when LM clicks
-- "Start Roll". currentItems/currentBoss are already set by OnItemsCaptured.
------------------------------------------------------------------------
function Session:StartPendingRoll()
    if not self._pendingPromptItems then return end

    local items = self._pendingPromptItems
    self._pendingPromptItems = nil
    self._pendingPromptBoss  = nil

    -- Build serializable copy (same as the normal OnItemsCaptured path)
    local serializableItems = {}
    for i, item in ipairs(items) do
        tinsert(serializableItems, {
            num     = i,
            rollID  = item.rollID,
            icon    = item.icon,
            name    = item.name,
            link    = item.link,
            quality = item.quality,
            kind    = item.kind,
        })
    end

    self._rollEligiblePlayers    = self:_SnapshotGroupMembers()
    self._readyCheckSerializable = serializableItems
    ns.db.global.pendingRoll     = nil  -- clear DB cache now that the roll is starting
    self:_StartReadyCheck()
end

------------------------------------------------------------------------
-- READY CHECK: Start per-player loot table delivery handshake (Leader)
-- Called after items are captured and the LM is confirmed out of a cinematic.
-- Starts the roll timer immediately, then whispers LTRC to each eligible
-- player. LOOT_TABLE is whispered to each player as they ack they are ready.
------------------------------------------------------------------------
function Session:_StartReadyCheck()
    -- Start the roll immediately for the LM (sets timer, shows LeaderFrame/RollFrame)
    if self:IsLootAuthority() and ns.LeaderFrame then ns.LeaderFrame:Show() end
    self:StartAllRolls()
    self:_SchedulePersist()

    -- Solo: no other players to notify
    if not IsInGroup() and not IsInRaid() then return end

    -- Broadcast item data to the group once.  All players cache the payload
    -- immediately; the ready-check handshake below gates when each client
    -- actually starts showing the roll UI (cinematic protection).
    ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE, {
        items     = self._readyCheckSerializable,
        bossName  = self.currentBoss,
        bossGUIDs = self._currentBossGUIDs,
        rollTimer = self._rollTimerOverride,
    })

    -- Build per-player delivery table; exclude the LM (already has currentItems)
    local me = ns.GetPlayerNameRealm()
    self._readyCheckPlayers  = {}
    self._readyCheckAttempts = {}
    for name in pairs(self._rollEligiblePlayers) do
        if not ns.NamesMatch(name, me) then
            self._readyCheckPlayers[name]  = false
            self._readyCheckAttempts[name] = 0
        end
    end

    -- Whisper ready-check to every eligible player
    for name in pairs(self._readyCheckPlayers) do
        self:_SendReadyCheck(name)
    end

    -- Start 1-second retry timer
    if self._readyCheckTimer then
        ns.addon:CancelTimer(self._readyCheckTimer)
    end
    self._readyCheckTimer = ns.addon:ScheduleRepeatingTimer(function()
        self:_ReadyCheckTick()
    end, 1)
end

------------------------------------------------------------------------
-- READY CHECK SEND: whisper one LTRC and count the attempt (Leader)
------------------------------------------------------------------------
function Session:_SendReadyCheck(name)
    self._readyCheckAttempts[name] = (self._readyCheckAttempts[name] or 0) + 1
    ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE_READY_CHECK, {}, name)
end

------------------------------------------------------------------------
-- READY CHECK TICK: Retry unacked players every second (Leader)
-- Gives up on a player after READY_CHECK_MAX_ATTEMPTS; once every player
-- has either acked or been given up on, the retry timer is cancelled.
------------------------------------------------------------------------
function Session:_ReadyCheckTick()
    -- Stop once the roll is no longer active
    if self.state ~= self.STATE_ROLLING and self.state ~= self.STATE_RESOLVING then
        self:_CleanupReadyCheck()
        return
    end
    local outstanding = false
    for name, delivered in pairs(self._readyCheckPlayers) do
        if not delivered then
            if (self._readyCheckAttempts[name] or 0) < self.READY_CHECK_MAX_ATTEMPTS then
                self:_SendReadyCheck(name)
                outstanding = true
            end
        end
    end
    if not outstanding then
        self:_CleanupReadyCheck()
    end
end

------------------------------------------------------------------------
-- READY CHECK CLEANUP: Cancel retry timer and clear state (Leader)
------------------------------------------------------------------------
function Session:_CleanupReadyCheck()
    if self._readyCheckTimer then
        ns.addon:CancelTimer(self._readyCheckTimer)
        self._readyCheckTimer = nil
    end
    self._readyCheckPlayers      = {}
    self._readyCheckAttempts     = {}
    self._readyCheckSerializable = nil
end

------------------------------------------------------------------------
-- TRUSTED SENDER CHECK
-- Returns true if sender is the session leader or the current loot master.
------------------------------------------------------------------------
function Session:_IsTrustedSender(sender)
    if not sender then return false end
    if ns.NamesEqual(sender, self.leaderName) then return true end
    if self.sessionLootMaster and self.sessionLootMaster ~= ""
            and ns.NamesEqual(sender, self.sessionLootMaster) then
        return true
    end
    return false
end

------------------------------------------------------------------------
-- LOOT TABLE READY CHECK RECEIVED (Members)
-- Leader is asking if this player is ready to receive the loot table.
------------------------------------------------------------------------
function Session:OnLootTableReadyCheckReceived(sender)
    if self._readyForLootTable then
        ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE_READY_ACK, {}, sender)
    else
        -- Will ack when cinematic ends; last sender wins (re-check is idempotent)
        self._pendingLTRCLeader = sender
    end
end

------------------------------------------------------------------------
-- LOOT TABLE READY ACK RECEIVED (Leader)
-- A player has confirmed they are ready; deliver the loot table to them.
------------------------------------------------------------------------
function Session:OnLootTableReadyAckReceived(sender)
    if self.state ~= self.STATE_ROLLING and self.state ~= self.STATE_RESOLVING then return end

    for name in pairs(self._readyCheckPlayers) do
        if ns.NamesEqual(name, sender) then
            -- LOOT_TABLE was already broadcast to the group; just mark as confirmed
            self._readyCheckPlayers[name] = true
            break
        end
    end

    -- If all players have confirmed, clean up the ready-check
    for _, delivered in pairs(self._readyCheckPlayers) do
        if not delivered then return end
    end
    self:_CleanupReadyCheck()
end

------------------------------------------------------------------------
-- ON LOOT TABLE RECEIVED (Members)
------------------------------------------------------------------------
function Session:OnLootTableReceived(payload, sender)
    if not self:_IsTrustedSender(sender) then return end

    -- If we're in a cinematic, cache the payload and process it when ready.
    -- LOOT_TABLE is now broadcast to the group before the ready-check, so it
    -- can arrive while a cinematic is still playing.
    if not self._readyForLootTable then
        self._pendingLootTable = payload
        return
    end

    self.currentItems = payload.items or {}
    self.currentBoss = payload.bossName or "Unknown"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}
    self._rollTimerOverride = (type(payload.rollTimer) == "number" and payload.rollTimer > 0) and payload.rollTimer or nil
    self:_ClearPendingAcks()

    -- Check loot eligibility using the boss GUIDs provided by the loot master in
    -- the LOOT_TABLE payload.  This is more reliable than the locally-cached result
    -- from ENCOUNTER_START, which could be stale or missing for late-joiners/reloads.
    -- No GUIDs = benefit of the doubt (e.g. debug session or old leader version).
    local bossGUIDs = payload.bossGUIDs or {}
    if #bossGUIDs > 0 then
        local eligible = false
        for _, guid in ipairs(bossGUIDs) do
            local _, canLoot = CanLootUnit(guid)
            if canLoot then
                eligible = true
                break
            end
        end
        self._lockedOutOfCurrentBoss = not eligible
    else
        self._lockedOutOfCurrentBoss = false
    end

    -- Start rolling on all items at once
    self:StartAllRolls()
end

------------------------------------------------------------------------
-- Start rolling on ALL items at once
------------------------------------------------------------------------
function Session:StartAllRolls()
    if #self.currentItems == 0 then
        self:_SaveBossHistory()
        self.state = self.STATE_ACTIVE
        ns.ChatPrint("Normal", "No items to roll on.")
        return
    end

    -- If the player is locked out of this boss, auto-pass every item silently
    -- without showing the roll frame, then stop.
    if self._lockedOutOfCurrentBoss then
        self.state = self.STATE_ROLLING
        for idx = 1, #self.currentItems do
            self.responses[idx] = {}
            self:SubmitResponse(idx, "Pass")
        end
        ns.ChatPrint("Normal",
            "|cffff4444You are locked out of " ..
            (self.currentBoss or "this boss") ..
            " — auto-passing all items.|r")
        return
    end

    self.state = self.STATE_ROLLING
    self._timerExpired = false

    -- Initialize responses for all items
    for idx = 1, #self.currentItems do
        self.responses[idx] = {}
    end

    -- Show roll frame with ALL items at once
    if ns.RollFrame then
        ns.RollFrame:ShowAllItems(self.currentItems, self.rollOptions)
    end

    self:_StartRollTimer()

    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- Effective roll duration for the next roll (override > session > profile)
------------------------------------------------------------------------
function Session:GetRollDuration()
    if self._rollTimerOverride then return self._rollTimerOverride end
    if self.sessionSettings and self.sessionSettings.rollTimer then
        return self.sessionSettings.rollTimer
    end
    return ns.db.profile.rollTimer or 30
end

------------------------------------------------------------------------
-- Effective loot quality threshold (session snapshot > profile).  The
-- leader syncs it in sessionSettings so every capture path agrees.
------------------------------------------------------------------------
function Session:GetLootThreshold()
    if self.sessionSettings and self.sessionSettings.lootThreshold then
        return self.sessionSettings.lootThreshold
    end
    return ns.db.profile.lootThreshold or 3
end

------------------------------------------------------------------------
-- (Re)start the single shared roll timer and the 1-second tick broadcaster.
------------------------------------------------------------------------
function Session:_StartRollTimer()
    local duration = self:GetRollDuration()

    self._rollTimerStart    = GetTime()
    self._rollTimerDuration = duration
    self._timerExpired      = false

    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
    end
    self._timerHandle = ns.addon:ScheduleTimer(function()
        self:OnTimerExpired()
    end, duration)

    -- Start 1-second broadcast ticker so all clients share the same countdown
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
    end
    self._tickBroadcastHandle = ns.addon:ScheduleRepeatingTimer(function()
        self:_BroadcastTimerTick()
    end, 1)
    -- Fire immediately so displays update without waiting for the first second
    self:_BroadcastTimerTick()
end

------------------------------------------------------------------------
-- Redraw the roll frame for the current boss: all items, with results
-- overlaid on the ones already resolved.  Used after a single-item re-roll
-- so the other items keep their state instead of being re-opened.
-- @param rerolledIdx number? item whose Large-frame choices should be dropped
------------------------------------------------------------------------
function Session:_RefreshRollFrames(rerolledIdx)
    if not ns.RollFrame then return end
    -- LargeRollFrame:ShowAllItems wipes its per-item choice cache; keep the
    -- entries for items that were not re-rolled.
    local savedChoices = ns.LargeRollFrame and ns.LargeRollFrame._choices
    ns.RollFrame:ShowAllItems(self.currentItems, self.rollOptions)
    if savedChoices and ns.LargeRollFrame and ns.LargeRollFrame._choices then
        for idx, c in pairs(savedChoices) do
            if idx ~= rerolledIdx then
                ns.LargeRollFrame._choices[idx] = c
            end
        end
    end
    for idx, r in pairs(self.results) do
        ns.RollFrame:ShowResult(idx, r)
    end
    -- ShowAllItems re-opens every row; only the re-rolled item is open
    -- again.  Answered, unresolved items stay locked on the standing choice.
    local me = ns.GetPlayerNameRealm()
    for idx = 1, #(self.currentItems or {}) do
        if idx ~= rerolledIdx and not self.results[idx] then
            local mine = self.responses[idx] and self.responses[idx][me]
            if mine and mine.choice then
                ns.RollFrame:MarkResponded(idx, mine.choice)
            end
        end
    end
end

------------------------------------------------------------------------
-- Does a roll choice count toward the loot count under current settings?
------------------------------------------------------------------------
function Session:_ChoiceCountsForLoot(choice, itemIdx)
    if not self:IsLootCountEnabled() then return false end
    local opt = self:_FindRollOption(choice)
    if not (opt and opt.countsForLoot) then return false end
    local item = itemIdx and self.currentItems and self.currentItems[itemIdx]
    return self:_KindCountsForLoot(item and item.kind)
end

------------------------------------------------------------------------
-- Does an item of this kind ("gear" / "token" / "recipe") count toward the
-- loot count?  Gear always does; tokens and recipes follow the session
-- settings synced from the leader (profile when no session is active).
------------------------------------------------------------------------
function Session:_KindCountsForLoot(kind)
    local ss = self.sessionSettings or ns.db.profile
    if kind == "token"  then return ss.tokensCountAsLoot  == true end
    if kind == "recipe" then return ss.recipesCountAsLoot == true end
    return true
end

------------------------------------------------------------------------
-- Undo the bookkeeping of a resolved item so it can be rolled again:
-- loot count (if it was counted), trade-queue entry, loot-history row.
-- Runs on every client; each side reverts what it recorded locally.
------------------------------------------------------------------------
function Session:_RevertResult(itemIdx)
    local result = self.results[itemIdx]
    if not result or not result.winner then return end
    local item = self.currentItems[itemIdx]

    -- Loot count: the authority stored _countedForLoot; members derive it.
    local counted = result._countedForLoot
    if counted == nil then counted = self:_ChoiceCountsForLoot(result.choice, itemIdx) end
    if counted then
        local c = ns.LootCount:GetCount(result.winner)
        ns.LootCount:SetCount(result.winner, math.max(0, c - 1))
    end

    if self.debugMode then return end

    -- Trade queue (authority only has entries; harmless elsewhere)
    for i = #self.tradeQueue, 1, -1 do
        local e = self.tradeQueue[i]
        if e.winner == result.winner and item and e.itemLink == item.link then
            table.remove(self.tradeQueue, i)
            break
        end
    end

    -- Loot history: newest row for this item/winner in this session
    local winnerId = ns.PlayerLinks:ResolveIdentity(result.winner)
    local history  = ns.LootHistory:GetAll()
    for i = #history, 1, -1 do
        local e = history[i]
        if e.player == winnerId
                and item and e.itemLink == item.link
                and (e.sessionId == nil or e.sessionId == self.activeSessionId) then
            table.remove(history, i)
            break
        end
    end
end

------------------------------------------------------------------------
-- RE-ROLL a single resolved item (loot authority only).
-- Reverts the previous result, re-opens just that item for everyone, and
-- restarts the shared timer.  Other items keep their state.
------------------------------------------------------------------------
function Session:RerollItem(itemIdx)
    if not self:IsLootMasterActionAllowed() then return end
    local item = self.currentItems[itemIdx]
    if not item then return end
    if not self.results[itemIdx] then
        ns.ChatPrint("Normal", "Item " .. itemIdx .. " has not been resolved; nothing to re-roll.")
        return
    end

    self:_RevertResult(itemIdx)
    self.results[itemIdx]   = nil
    self.responses[itemIdx] = {}

    -- Eligible players are re-snapshotted so leavers/joiners are handled
    self._rollEligiblePlayers = self:_SnapshotGroupMembers()
    self.state = self.STATE_ROLLING

    -- Tell members before starting the timer so TIMER_TICKs land on a fresh roll
    ns.Comm:Send(ns.Comm.MSG.ITEM_REROLL, { itemIdx = itemIdx })
    -- Counts may have been reverted; give members the authoritative table
    ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })

    self:_StartRollTimer()
    self:_RefreshRollFrames(itemIdx)
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end

    local displayName = (item.link or ""):match("|h(%[.-%])|h") or item.name or ("item #" .. itemIdx)
    local msg = "[OLL] Re-rolling " .. displayName
    if self.debugMode or not (IsInRaid() or IsInGroup()) then
        ns.ChatPrint("Normal", msg)
    else
        SendChatMessage(msg, ns.GetAnnounceChannel())
    end
    self:_SchedulePersist()
end

------------------------------------------------------------------------
-- ON ITEM REROLL RECEIVED (members)
------------------------------------------------------------------------
function Session:OnItemRerollReceived(payload, sender)
    if not self:_IsTrustedSender(sender) then return end
    local itemIdx = payload.itemIdx
    if not itemIdx or not self.currentItems[itemIdx] then return end

    self:_RevertResult(itemIdx)
    self.results[itemIdx]   = nil
    self.responses[itemIdx] = {}
    self:_ClearPendingAcks()
    if ns.LargeRollFrame and ns.LargeRollFrame._choices then
        ns.LargeRollFrame._choices[itemIdx] = nil
    end

    if self._lockedOutOfCurrentBoss then
        self.state = self.STATE_ROLLING
        self:SubmitResponse(itemIdx, "Pass")
        return
    end

    self.state = self.STATE_ROLLING
    self:_StartRollTimer()
    self:_RefreshRollFrames(itemIdx)
end

------------------------------------------------------------------------
-- Broadcast one timer tick to the group and notify local UI directly
-- (group channel messages do not loop back to the sender)
------------------------------------------------------------------------
function Session:_BroadcastTimerTick()
    if not self._rollTimerStart then return end
    local elapsed    = GetTime() - self._rollTimerStart
    local remaining  = math.max(0, self._rollTimerDuration - elapsed)

    -- Update leader's own UI frames directly
    if ns.LeaderFrame then ns.LeaderFrame:OnTimerTick(remaining) end
    if ns.RollFrame   then ns.RollFrame:OnTimerTick(remaining)   end

    -- Broadcast to group members.  Every client runs this ticker for its own
    -- UI; only the loot authority's countdown goes on the wire (receivers
    -- drop the rest anyway, and 20 clients ticking saturates the throttle).
    if self:IsLootAuthority() then
        ns.Comm:Send(ns.Comm.MSG.TIMER_TICK, { remaining = remaining })
    end

    if remaining <= 0 then
        if self._tickBroadcastHandle then
            ns.addon:CancelTimer(self._tickBroadcastHandle)
            self._tickBroadcastHandle = nil
        end
    end
end

------------------------------------------------------------------------
-- Player submits a roll response
------------------------------------------------------------------------
function Session:SubmitResponse(itemIdx, choice)
    local playerName = ns.GetPlayerNameRealm()

    if IsInGroup() or IsInRaid() then
        -- In a group: all players (including leader) send via Comm.  Comm:Send
        -- dispatches ROLL_RESPONSE locally as well, so the leader processes
        -- its own response through OnRollResponseReceived like everyone else's.
        ns.Comm:Send(ns.Comm.MSG.ROLL_RESPONSE, {
            itemIdx = itemIdx,
            choice  = choice,
            player  = playerName,
        })
        -- Everyone except the loot authority waits for an ACK whisper; if it
        -- doesn't arrive within 2 s the response is resent (up to 3 retries).
        if not self:IsLootAuthority() then
            self:_StartRollResponseAckTimer(itemIdx, choice)
        end
    else
        -- Solo / debug mode: no group channel available, handle locally.
        self:OnRollResponseReceived({
            itemIdx = itemIdx,
            choice  = choice,
            player  = playerName,
        }, playerName)
    end
end

------------------------------------------------------------------------
-- ON ROLL RESPONSE RECEIVED (Leader)
------------------------------------------------------------------------
function Session:OnRollResponseReceived(payload, sender)
    local itemIdx = payload.itemIdx
    local choice  = payload.choice
    -- The response belongs to whoever sent it.  payload.player is ignored:
    -- honouring it let any member submit a choice in another player's name.
    -- Local callers (own submit, LeaderFrame override, debug fake players)
    -- pass the player as `sender`.
    local player  = ns.CanonicalName(sender)
    if not player or not itemIdx then return end

    -- ACK the response back to the sender so their retry timer is cancelled.
    -- Always send the ACK (even if the item is already resolved) so the member
    -- doesn't keep retrying after the roll phase ends.  Our own response is
    -- dispatched locally by Comm:Send and needs no ACK.
    local isAuthority = self:IsLootAuthority()
    if isAuthority and (IsInGroup() or IsInRaid()) and not ns.Comm:IsSelf(player) then
        ns.Comm:Send(ns.Comm.MSG.ROLL_RESPONSE_ACK, { itemIdx = itemIdx, success = true }, player)
    end

    if self.state ~= self.STATE_ROLLING and self.state ~= self.STATE_RESOLVING then return end
    if self._suspendedRoll then return end   -- paused for a cinematic; players re-choose on resume

    -- Don't accept responses for items that are already resolved
    if self.results[itemIdx] then return end

    if not self.responses[itemIdx] then
        self.responses[itemIdx] = {}
    end

    -- A player's random roll is assigned once per item.  A resent response
    -- (ACK retry) or a changed choice keeps the same number, so what
    -- CHOICES_UPDATE already showed everyone stays true.
    local existing = self.responses[itemIdx][player]
    local roll
    if isAuthority then
        roll = (existing and existing.roll) or math.random(1, 100)
    end
    local unchanged = existing and existing.choice == choice and existing.roll == roll

    self.responses[itemIdx][player] = {
        choice       = choice,
        countAtRoll  = self:IsLootCountEnabled() and ns.LootCount:GetCount(player) or 0,
        roll         = roll,
    }

    -- Broadcast this single response as a delta so the Large roll frame
    -- on every client stays up-to-date in real time.  Sending only the new
    -- entry keeps the message size constant (~80 bytes) regardless of how
    -- many total responses have accumulated.  A pure retry is not rebroadcast.
    if isAuthority and not unchanged then
        local resp = self.responses[itemIdx][player]
        ns.Comm:Send(ns.Comm.MSG.CHOICES_UPDATE, {
            itemIdx     = itemIdx,
            player      = player,
            choice      = resp.choice,
            countAtRoll = resp.countAtRoll,
            roll        = resp.roll,
        })
    end

    -- Update leader frame
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end

    if isAuthority then self:_SchedulePersist() end

    -- In debug mode: once all real players have responded, submit deferred fake players
    if self.debugMode and #self._debugFakePlayers > 1
            and not self._debugFakePlayerSet[player] then
        if self:_AllRealPlayersResponded(itemIdx) then
            self:_SubmitDeferredFakePlayers(itemIdx)
        end
    end

    -- Per-item resolution: if this item has all responses and all prior items
    -- are resolved, resolve it now; otherwise it will be unblocked later via
    -- _TryResolveNext when its predecessor finishes.
    if isAuthority and self:AllResponded(itemIdx) and self:_AllPreviousResolved(itemIdx) then
        self:ResolveItem(itemIdx)
    end
end

------------------------------------------------------------------------
-- Roll-response ACK helpers (member side)
------------------------------------------------------------------------

-- Cancel all pending ACK timers and clear the table.
function Session:_ClearPendingAcks()
    if self._pendingAcks then
        for _, pending in pairs(self._pendingAcks) do
            if pending.timer then pending.timer:Cancel() end
        end
    end
    self._pendingAcks = {}
end

-- Start (or restart) a 2 s ACK-wait timer for itemIdx.
-- If no ACK arrives in time the ROLL_RESPONSE is resent; gives up after 3 retries.
function Session:_StartRollResponseAckTimer(itemIdx, choice, retryCount)
    retryCount = retryCount or 0
    if not self._pendingAcks then self._pendingAcks = {} end

    -- Cancel any existing timer for this item before starting a fresh one
    if self._pendingAcks[itemIdx] and self._pendingAcks[itemIdx].timer then
        self._pendingAcks[itemIdx].timer:Cancel()
    end

    self._pendingAcks[itemIdx] = {
        choice = choice,
        timer  = C_Timer.NewTimer(2, function()
            self._pendingAcks[itemIdx] = nil
            if retryCount >= 3 then
                -- All retries exhausted — reset the UI so the player can resubmit.
                local itemName = self.currentItems and self.currentItems[itemIdx]
                    and (self.currentItems[itemIdx].link or self.currentItems[itemIdx].name)
                    or "item #" .. itemIdx
                ns.ChatPrint("Normal", "|cffff4444Error type: Timeout — Failed to send loot choice for " .. itemName .. ". Try again.|r")
                if ns.RollFrame then
                    ns.RollFrame:ResetItemChoice(itemIdx)
                end
                return
            end
            ns.Comm:Send(ns.Comm.MSG.ROLL_RESPONSE, {
                itemIdx = itemIdx,
                choice  = choice,
                player  = ns.GetPlayerNameRealm(),
            })
            self:_StartRollResponseAckTimer(itemIdx, choice, retryCount + 1)
        end),
    }
end

-- Called when the leader's ACK whisper arrives — cancel the retry timer.
function Session:OnRollResponseAckReceived(payload, sender)
    local itemIdx = payload.itemIdx
    if self._pendingAcks and self._pendingAcks[itemIdx] then
        if self._pendingAcks[itemIdx].timer then
            self._pendingAcks[itemIdx].timer:Cancel()
        end
        self._pendingAcks[itemIdx] = nil
    end

    -- If the leader received the message but failed to handle it, notify the player.
    if payload.success == false then
        local itemName = self.currentItems and self.currentItems[itemIdx]
            and (self.currentItems[itemIdx].link or self.currentItems[itemIdx].name)
            or "item #" .. itemIdx
        ns.ChatPrint("Normal", "|cffff4444Error type: Failure — Loot choice for " .. itemName .. " was received but could not be processed. Try again.|r")
        if ns.RollFrame then
            ns.RollFrame:ResetItemChoice(itemIdx)
        end
    end
end

------------------------------------------------------------------------
-- Check if all group members responded for a single item
------------------------------------------------------------------------
function Session:AllResponded(itemIdx)
    local responses = self.responses[itemIdx] or {}

    -- Use the eligible-player snapshot taken at LOOT_TABLE send time.
    -- This prevents a shrinking group from permanently blocking resolution
    -- (handled by auto-passing leavers in OnGroupRosterUpdate) and
    -- prevents late-joining players from being counted.
    local eligibleCount
    if next(self._rollEligiblePlayers) then
        eligibleCount = 0
        for _ in pairs(self._rollEligiblePlayers) do eligibleCount = eligibleCount + 1 end
    else
        eligibleCount = ns.GetGroupSize()
    end

    -- With a snapshot, every eligible player (and every debug fake) must
    -- have answered; a stray key from a late joiner or a forced choice for
    -- someone outside the snapshot must not stand in for a missing answer.
    if next(self._rollEligiblePlayers) then
        for player in pairs(self._rollEligiblePlayers) do
            if not responses[player] then return false end
        end
        if self.debugMode then
            for _, fake in ipairs(self._debugFakePlayers) do
                if not responses[fake] then return false end
            end
        end
        return true
    end

    -- No snapshot (solo / legacy): fall back to a head count.
    if self.debugMode then
        eligibleCount = eligibleCount + #self._debugFakePlayers
    end
    local count = 0
    for _ in pairs(responses) do count = count + 1 end
    return count >= eligibleCount
end

------------------------------------------------------------------------
-- Check if ALL items have all responses
------------------------------------------------------------------------
function Session:AllItemsAllResponded()
    for idx = 1, #self.currentItems do
        if not self:AllResponded(idx) then
            return false
        end
    end
    return true
end

------------------------------------------------------------------------
-- Returns true if all items before itemIdx are resolved
------------------------------------------------------------------------
function Session:_AllPreviousResolved(itemIdx)
    for i = 1, itemIdx - 1 do
        if not self.results[i] then
            return false
        end
    end
    return true
end

------------------------------------------------------------------------
-- After resolving item afterIdx, try to resolve the next blocked item
-- if it is now unblocked and ready (all responses in or timer expired)
------------------------------------------------------------------------
function Session:_TryResolveNext(afterIdx)
    for idx = afterIdx + 1, #self.currentItems do
        if not self.results[idx] then
            if self:AllResponded(idx) or self._timerExpired then
                self:ResolveItem(idx)
            end
            return -- only attempt one at a time; it will chain if needed
        end
    end
end

------------------------------------------------------------------------
-- Timer expired – force-pass absent players, then resolve ALL unresolved
------------------------------------------------------------------------
function Session:OnTimerExpired()
    if self.state ~= self.STATE_ROLLING and self.state ~= self.STATE_RESOLVING then return end
    if self._suspendedRoll then return end
    self:_CleanupReadyCheck()
    self._timerExpired = true
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    -- Only the loot authority resolves.  A member's own countdown just
    -- stops; its roll frame auto-passed on the last tick and the results
    -- arrive as ROLL_RESULT.  Fabricating Pass rows here showed players as
    -- passed whom the authority resolved differently.
    if not self:IsLootAuthority() then return end

    -- Build the current group member list (same logic as LeaderFrame).
    local members = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        tinsert(members, ns.GetPlayerNameRealm())
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                if not name:find("-") then
                    name = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(members, name)
            end
        end
    else
        tinsert(members, ns.GetPlayerNameRealm())
        for i = 1, numMembers - 1 do
            local unit = "party" .. i
            local name = GetUnitName(unit, true)
            if name then
                if not name:find("-") then
                    name = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(members, name)
            end
        end
    end

    -- For every unresolved item, insert a "Pass" response for any player
    -- who has not yet made a choice, so they show as Pass in the UI and
    -- AllResponded() returns true to unblock resolution.
    for idx = 1, #self.currentItems do
        if not self.results[idx] then
            local resp = self.responses[idx]
            if not resp then
                resp = {}
                self.responses[idx] = resp
            end
            for _, memberName in ipairs(members) do
                -- Use NamesMatch to handle same-name across realms
                local alreadyResponded = false
                for respPlayer in pairs(resp) do
                    if ns.NamesMatch(respPlayer, memberName) then
                        alreadyResponded = true
                        break
                    end
                end
                if not alreadyResponded then
                    resp[memberName] = { choice = "Pass", countAtRoll = 0 }
                end
            end
        end
    end

    self:ResolveAllItems()
end

------------------------------------------------------------------------
-- Resolve all items at once
------------------------------------------------------------------------
function Session:ResolveAllItems()
    if not self:IsLootMasterActionAllowed() then return end

    -- Resolve any remaining unresolved items (timer expired fallback)
    for idx = 1, #self.currentItems do
        if not self.results[idx] then
            self:ResolveItem(idx)
        end
    end

    -- _CheckAllItemsResolved will handle finalization
    self:_CheckAllItemsResolved()
end

------------------------------------------------------------------------
-- LOOT AUTHORITY
-- Exactly one client drives the loot flow for a session: it captures
-- drops, records and ACKs roll responses, broadcasts choices/timer ticks
-- and resolves rolls.  That client is the session loot master when one is
-- set, otherwise the session leader.  Raid leader/assistant status is
-- irrelevant here; use ns.IsLeader() only for leader-role actions such as
-- starting, ending or taking over a session.
------------------------------------------------------------------------
function Session:GetLootAuthorityName()
    if self.sessionLootMaster and self.sessionLootMaster ~= "" then
        return self.sessionLootMaster
    end
    return self.leaderName
end

function Session:IsLootAuthority()
    if not self:IsActive() then return false end
    local authority = self:GetLootAuthorityName()
    if not authority then return false end
    return ns.NamesEqual(ns.GetPlayerNameRealm(), authority)
end

------------------------------------------------------------------------
-- LOOT MASTER ACTION CHECK
-- Returns true if the local player may trigger manual rolls, stop a roll,
-- reassign items or start a pending roll.  While a session is active this
-- is the loot authority only (see IsLootAuthority); when idle it falls
-- back to the WoW group leader check so the Leader Frame stays usable.
------------------------------------------------------------------------
function Session:IsLootMasterActionAllowed()
    if self:IsActive() then
        return self:IsLootAuthority()
    end
    -- No active session: fall back to group leader check
    return ns.IsLeader()
end

------------------------------------------------------------------------
-- STOP ROLL (Leader only) – cancel the active roll and force all
-- pending items to Pass (already-resolved items are unaffected).
------------------------------------------------------------------------
function Session:StopRoll()
    if not self:IsLootMasterActionAllowed() then return end
    if self.state ~= self.STATE_ROLLING and self.state ~= self.STATE_RESOLVING then return end
    self:_CleanupReadyCheck()
    self._suspendedRoll = false

    -- Cancel the roll timer
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end

    -- Force every recorded response on unresolved items to Pass,
    -- regardless of what the player originally chose
    for idx = 1, #self.currentItems do
        if not self.results[idx] then
            local resp = self.responses[idx] or {}
            for _, data in pairs(resp) do
                data.choice = "Pass"
            end
            self.responses[idx] = resp
        end
    end

    -- Resolve all remaining items (all-Pass → awarded to leader)
    self:ResolveAllItems()

    -- Close the roll frame locally and tell all members to close theirs
    if ns.RollFrame then ns.RollFrame:Hide() end
    ns.Comm:Send(ns.Comm.MSG.ROLL_CANCELLED, {})
    self:_SchedulePersist()
end

------------------------------------------------------------------------
-- SUSPEND ROLL (loot authority) – pause the active roll without awarding
-- anything.  Used when the authority enters a cinematic.  Items already
-- resolved keep their results; unresolved items lose their responses and
-- will be re-opened by ResumeSuspendedRoll.
------------------------------------------------------------------------
function Session:SuspendRoll()
    if not self:IsLootAuthority() then return end
    if self.state ~= self.STATE_ROLLING and self.state ~= self.STATE_RESOLVING then return end
    if self._suspendedRoll then return end

    self:_CleanupReadyCheck()
    self:_StopRollTimer()
    self:_ClearUnresolvedResponses()
    self._suspendedRoll = true

    ns.Comm:Send(ns.Comm.MSG.ROLL_SUSPENDED, {})

    if ns.RollFrame then ns.RollFrame:Hide() end
    if ns.LeaderFrame then
        if ns.LeaderFrame.StopTimer then ns.LeaderFrame:StopTimer() end
        ns.LeaderFrame:Refresh()
    end
    ns.ChatPrint("Normal", "Loot roll paused for a cinematic; it will restart when the cinematic ends.")
    self:_SchedulePersist()
end

------------------------------------------------------------------------
-- RESUME SUSPENDED ROLL (loot authority) – re-open every unresolved item
-- with a fresh timer once the cinematic is over.
------------------------------------------------------------------------
function Session:ResumeSuspendedRoll()
    if not self:IsLootAuthority() then return end
    if not self._suspendedRoll then return end
    self._suspendedRoll = false

    if #self.currentItems == 0 then
        self.state = self.STATE_ACTIVE
        return
    end

    self.state = self.STATE_ROLLING
    self._rollEligiblePlayers = self:_SnapshotGroupMembers()

    ns.Comm:Send(ns.Comm.MSG.ROLL_RESUMED, {})

    self:_StartRollTimer()
    self:_RefreshRollFrames()
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end

    local msg = "[OLL] Loot roll for " .. (self.currentBoss or "Unknown") .. " resumed."
    if self.debugMode or not (IsInRaid() or IsInGroup()) then
        ns.ChatPrint("Normal", msg)
    else
        SendChatMessage(msg, ns.GetAnnounceChannel())
    end
    self:_SchedulePersist()
end

------------------------------------------------------------------------
-- ON ROLL SUSPENDED RECEIVED (members)
------------------------------------------------------------------------
function Session:OnRollSuspendedReceived(payload, sender)
    if not self:_IsTrustedSender(sender) then return end
    if self.state ~= self.STATE_ROLLING and self.state ~= self.STATE_RESOLVING then return end

    self:_StopRollTimer()
    self:_ClearUnresolvedResponses()
    self:_ClearPendingAcks()
    self._suspendedRoll = true

    if ns.RollFrame then ns.RollFrame:Hide() end
    ns.ChatPrint("Normal", "Loot roll paused for a cinematic; it will restart when the cinematic ends.")
    self:_SchedulePersist()
end

------------------------------------------------------------------------
-- ON ROLL RESUMED RECEIVED (members)
------------------------------------------------------------------------
function Session:OnRollResumedReceived(payload, sender)
    if not self:_IsTrustedSender(sender) then return end
    if not self._suspendedRoll then return end
    self._suspendedRoll = false
    if #self.currentItems == 0 then return end

    self.state = self.STATE_ROLLING

    if self._lockedOutOfCurrentBoss then
        for idx = 1, #self.currentItems do
            if not self.results[idx] then
                self:SubmitResponse(idx, "Pass")
            end
        end
        return
    end

    self:_StartRollTimer()
    self:_RefreshRollFrames()
end

------------------------------------------------------------------------
-- Helpers shared by suspend / resume
------------------------------------------------------------------------
function Session:_StopRollTimer()
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    self._rollTimerStart    = nil
    self._rollTimerDuration = nil
end

-- Drop recorded responses (and Large-frame choices) for items that have
-- not resolved yet; players choose again when the roll resumes.
function Session:_ClearUnresolvedResponses()
    for idx = 1, #self.currentItems do
        if not self.results[idx] then
            self.responses[idx] = {}
            if ns.LargeRollFrame and ns.LargeRollFrame._choices then
                ns.LargeRollFrame._choices[idx] = nil
            end
        end
    end
end

------------------------------------------------------------------------
-- ON ROLL CANCELLED RECEIVED (Members)
------------------------------------------------------------------------
function Session:OnRollCancelledReceived(payload, sender)
    if not self:_IsTrustedSender(sender) then return end
    if ns.RollFrame then
        ns.RollFrame:UnlockBossDropdown()
        ns.RollFrame:Hide()
    end
end

------------------------------------------------------------------------
-- RESOLVE a single item roll
------------------------------------------------------------------------
function Session:ResolveItem(itemIdx)
    if not self:IsLootMasterActionAllowed() then return end
    if self.results[itemIdx] then return end -- already resolved

    self.state = self.STATE_RESOLVING

    local responses = self.responses[itemIdx] or {}
    local rollOptions = self.rollOptions or ns.DEFAULT_ROLL_OPTIONS

    -- Separate responses by tier (excluding Pass)
    -- Build tier → players mapping
    local tiers = {} -- { [priority] = { {player, choice, optionData}, ... } }

    for player, data in pairs(responses) do
        local choiceName = data.choice
        if choiceName ~= "Pass" then
            local opt = self:_FindRollOption(choiceName)
            if opt then
                if not tiers[opt.priority] then
                    tiers[opt.priority] = {}
                end
                tinsert(tiers[opt.priority], {
                    player = player,
                    choice = choiceName,
                    option = opt,
                    roll   = data.roll,
                })
            end
        end
    end

    -- Find the highest-priority (lowest number) tier with players
    local sortedPriorities = {}
    for p in pairs(tiers) do tinsert(sortedPriorities, p) end
    table.sort(sortedPriorities)

    -- Build a full ranked list across all tiers
    local rankedCandidates = {}
    for _, priority in ipairs(sortedPriorities) do
        local candidates = tiers[priority]
        if #candidates > 0 then
            local ranked = self:_RankInTier(candidates)
            for _, c in ipairs(ranked) do
                tinsert(rankedCandidates, c)
            end
        end
    end

    local winner, winnerRoll, winnerTiebreakerRoll, winnerChoice, winnerOpt
    if #rankedCandidates > 0 then
        local w = rankedCandidates[1]
        winner               = w.player
        winnerRoll           = w.originalRoll or w.roll
        winnerTiebreakerRoll = w.tiebreakerRoll
        winnerChoice         = w.choice
        winnerOpt            = w.option
    end

    -- Store result
    if winner then
        -- Increment loot count if this option counts
        -- (in debug mode, LootCount routes to the isolated overlay table)
        local counted  = self:_ChoiceCountsForLoot(winnerChoice, itemIdx)
        local newCount = ns.LootCount:GetCount(winner)
        if counted then
            newCount = ns.LootCount:IncrementCount(winner)
        end

        self.results[itemIdx] = {
            winner           = winner,
            roll             = winnerRoll,
            tiebreakerRoll   = winnerTiebreakerRoll,
            choice           = winnerChoice,
            newCount         = newCount,
            rankedCandidates = rankedCandidates,  -- kept locally for bossHistory; not broadcast
            _countedForLoot  = counted,
        }

        local item = self.currentItems[itemIdx]

        local histEntry = nil
        if not self.debugMode then
            -- Add to trade queue (skip in debug)
            if item then
                tinsert(self.tradeQueue, {
                    winner      = winner,
                    itemLink    = item.link,
                    itemName    = item.name,
                    itemIcon    = item.icon,
                    itemQuality = item.quality,
                    awarded     = false,
                })
            end

            -- Build history entry with pre-computed rolls so members don't need
            -- rankedCandidates in the broadcast to reconstruct them.
            histEntry = {
                itemLink       = item and item.link or "Unknown",
                itemId         = ns.GetItemIdFromLink(item and item.link) or 0,
                player         = winner,
                lootCountAtWin = newCount - (self.results[itemIdx]._countedForLoot and 1 or 0),
                bossName       = self.currentBoss,
                rollType       = winnerChoice,
                rollValue      = winnerRoll,
                sessionId      = self.activeSessionId,
                rolls          = {},
            }
            for _, c in ipairs(rankedCandidates) do
                tinsert(histEntry.rolls, {
                    player         = c.player,
                    choice         = c.choice,
                    roll           = c.originalRoll or c.roll,
                    count          = c.count or 0,
                    tiebreakerRoll = c.tiebreakerRoll,
                })
            end
            ns.LootHistory:AddEntry(histEntry)
        end

        -- Broadcast winner only; rankedCandidates and newCount are no longer sent.
        -- COUNT_SYNC is deferred to _CheckAllItemsResolved as a single delta.
        ns.Comm:BroadcastRollResult(itemIdx, winner, winnerRoll, winnerTiebreakerRoll, winnerChoice, histEntry)

        -- Announce
        self:AnnounceWinner(itemIdx)
    else
        -- All players passed (or no responses)
        -- If a disenchanter is configured and present in the group, send to them (no count).
        -- Otherwise fall back to awarding to the leader.
        local item         = self.currentItems[itemIdx]
        local disenchanter = self.sessionDisenchanter or ""
        local recipient, rollType

        if disenchanter ~= "" and self:_IsPlayerInGroup(disenchanter) then
            recipient = disenchanter
            rollType  = "Disenchant"
        else
            recipient = self.leaderName or ns.GetPlayerNameRealm()
            rollType  = "Passed"
        end

        local recipientCount = ns.LootCount:GetCount(recipient)

        self.results[itemIdx] = {
            winner           = recipient,
            roll             = 0,
            choice           = rollType,
            newCount         = recipientCount,
            rankedCandidates = {},
        }

        local histEntry = nil
        if not self.debugMode then
            if item then
                tinsert(self.tradeQueue, {
                    winner      = recipient,
                    itemLink    = item.link,
                    itemName    = item.name,
                    itemIcon    = item.icon,
                    itemQuality = item.quality,
                    awarded     = false,
                })
            end

            -- Save entry to include in broadcast
            histEntry = {
                itemLink       = item and item.link or "Unknown",
                itemId         = ns.GetItemIdFromLink(item and item.link) or 0,
                player         = recipient,
                lootCountAtWin = recipientCount,
                bossName       = self.currentBoss,
                rollType       = rollType,
                rollValue      = 0,
                sessionId      = self.activeSessionId,
            }
            ns.LootHistory:AddEntry(histEntry)
        end

        -- Broadcast winner only; COUNT_SYNC deferred to _CheckAllItemsResolved.
        ns.Comm:BroadcastRollResult(itemIdx, recipient, 0, nil, rollType, histEntry)

        if rollType == "Disenchant" then
            ns.ChatPrint("Leader", "All players passed on item " .. itemIdx .. ". Sending to disenchanter (" .. recipient .. ").")
        else
            ns.ChatPrint("Leader", "All players passed on item " .. itemIdx .. ". Awarded to leader (" .. recipient .. ").")
        end
    end

    -- Update UI
    if ns.RollFrame then ns.RollFrame:ShowResult(itemIdx, self.results[itemIdx]) end
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end

    -- Resolve the next item if it was waiting on this one
    self:_SchedulePersist()
    self:_TryResolveNext(itemIdx)

    -- Check if all items are now resolved
    self:_CheckAllItemsResolved()
end

------------------------------------------------------------------------
-- Check if all items are resolved; if so, finalize the boss
------------------------------------------------------------------------
function Session:_CheckAllItemsResolved()
    if self.state ~= self.STATE_RESOLVING then return end
    for idx = 1, #self.currentItems do
        if not self.results[idx] then
            return -- still items pending
        end
    end

    -- All items resolved – cancel timer and finalize
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    self._rollTimerStart    = nil
    self._rollTimerDuration = nil

    self:_SaveBossHistory()
    self.state = self.STATE_ACTIVE

    -- Broadcast delta of loot counts for players whose count changed this roll.
    -- Always sent (including debug mode) so the message path can be tested;
    -- in a debug session members apply it to their shadow overlay (see
    -- _SetRemoteDebug), never to their real counts.
    local delta = {}
    for idx = 1, #self.currentItems do
        local r = self.results[idx]
        if r and r.winner and r._countedForLoot then
            -- Key by the identity the count is stored under (the main when
            -- counts are locked to main); ApplyDelta writes keys verbatim.
            delta[ns.LootCount:ResolveName(r.winner)] = ns.LootCount:GetCount(r.winner)
        end
    end
    if next(delta) then
        ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { delta = delta })
    end

    -- Broadcast session record snapshot to members (skip in debug/test-loot mode)
    if not self.debugMode and not self._testLootMode then
        local snap = self:_GetSessionSnapshot()
        if snap then ns.Comm:Send(ns.Comm.MSG.SESSION_SYNC, { session = snap }) end
    end

    -- If this was a one-shot test loot, end it automatically
    if self._testLootMode then
        self:_EndTestLoot()
        return
    end

    if ns.RollFrame then ns.RollFrame:UnlockBossDropdown() end
    ns.ChatPrint("Leader", "All rolls complete for " .. self.currentBoss .. ".")
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- Rank all candidates within a single tier (returns full ordered list).
-- Ordering: loot count ASC → random roll DESC (ties re-rolled).
------------------------------------------------------------------------
function Session:_RankInTier(candidates)
    -- Assign loot counts
    for _, c in ipairs(candidates) do
        c.count = self:IsLootCountEnabled() and ns.LootCount:GetCount(c.player) or 0
    end

    -- Use pre-assigned roll from response (assigned at submission time) or generate one
    for _, c in ipairs(candidates) do
        if not c.roll then
            c.roll = math.random(1, 100)
        end
    end

    -- Save original rolls before any tiebreaker re-rolling
    for _, c in ipairs(candidates) do
        c.originalRoll = c.roll
    end

    -- Sort: loot count ASC first, then roll DESC
    table.sort(candidates, function(a, b)
        if a.count ~= b.count then
            return a.count < b.count
        end
        return a.roll > b.roll
    end)

    -- Break ties (same count AND same roll) by re-rolling every tied group,
    -- then re-sorting and scanning the whole list again until a full pass
    -- finds no tie.  Only entries that were actually re-rolled carry a
    -- tiebreakerRoll.  The pass cap only guards against pathological luck.
    local function sortCandidates()
        table.sort(candidates, function(a, b)
            if a.count ~= b.count then return a.count < b.count end
            return a.roll > b.roll
        end)
    end
    local passes, tied = 0, true
    while tied and passes < 20 do
        passes = passes + 1
        tied = false
        local i = 1
        while i < #candidates do
            local j = i
            while j < #candidates
                and candidates[j + 1].count == candidates[i].count
                and candidates[j + 1].roll == candidates[i].roll do
                j = j + 1
            end
            if j > i then
                tied = true
                for k = i, j do
                    candidates[k].roll = math.random(1, 100)
                    candidates[k].tiebreakerRoll = candidates[k].roll
                end
            end
            i = j + 1
        end
        if tied then sortCandidates() end
    end

    return candidates
end

------------------------------------------------------------------------
-- Get ranked candidates for an item (for reassign popup)
------------------------------------------------------------------------
function Session:GetRankedCandidates(itemIdx)
    local result = self.results[itemIdx]
    if result and result.rankedCandidates then
        return result.rankedCandidates
    end
    return {}
end

------------------------------------------------------------------------
-- Find roll option by name
------------------------------------------------------------------------
function Session:_FindRollOption(name)
    local opts = self.rollOptions or ns.DEFAULT_ROLL_OPTIONS
    for _, opt in ipairs(opts) do
        if opt.name == name then return opt end
    end
    return nil
end

------------------------------------------------------------------------
-- Returns true if nameRealm is currently in the player's raid/party
------------------------------------------------------------------------
function Session:_IsPlayerInGroup(nameRealm)
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then return false end
    local last = IsInRaid() and numMembers or (numMembers - 1)
    for i = 1, last do
        local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
        local name = GetUnitName(unit, true)
        if name and ns.NamesMatch(name, nameRealm) then
            return true
        end
    end
    -- Also check the player themselves (leader counts as a group member)
    local playerName = GetUnitName("player", true)
    if playerName and ns.NamesMatch(playerName, nameRealm) then
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Announce winner in chat
------------------------------------------------------------------------
function Session:AnnounceWinner(itemIdx)
    local result = self.results[itemIdx]
    if not result or not result.winner then return end

    local item = self.currentItems[itemIdx]
    local itemLink = item and item.link or "Unknown Item"
    local displayName = itemLink:match("|h(%[.-%])|h") or itemLink

    local prefix = self.debugMode and "[OLL DEBUG] " or "[OLL] "
    local channel = ns.GetAnnounceChannel()
    local msg
    if result.tiebreakerRoll then
        msg = string.format("%s won by %s (%s roll: %d, tiebreaker: %d, Loot Count: %d)",
            displayName, result.winner, result.choice, result.roll, result.tiebreakerRoll, result.newCount or 0)
    else
        msg = string.format("%s won by %s (%s roll: %d, Loot Count: %d)",
            displayName, result.winner, result.choice, result.roll, result.newCount or 0)
    end

    -- In debug mode or not in group, just print locally
    if self.debugMode or not (IsInRaid() or IsInGroup()) then
        ns.ChatPrint("Normal", prefix .. msg)
    else
        SendChatMessage(prefix .. msg, channel)
    end
end

------------------------------------------------------------------------
-- Build a lightweight session record snapshot for broadcasting.
-- Returns only metadata (no loot entries) or nil if no active session.
------------------------------------------------------------------------
function Session:_GetSessionSnapshot()
    if not self.activeSessionId then return nil end
    for _, s in ipairs(ns.db.global.sessionHistory) do
        if s.id == self.activeSessionId then
            return {
                id            = s.id,
                startTime     = s.startTime,
                endTime       = s.endTime,
                leader        = s.leader,
                bosses        = s.bosses,
                lootMasters   = s.lootMasters,
                savedSettings = s.savedSettings,
            }
        end
    end
end

------------------------------------------------------------------------
-- Save current boss data to session history (for dropdown)
------------------------------------------------------------------------
function Session:_SaveBossHistory()
    local key = self.currentBoss
    -- Already saved for this loot table (e.g. finalized again after a
    -- single-item re-roll): refresh the stored tables instead of adding a
    -- duplicate "Boss (2)" entry.  The key is remembered (and persisted)
    -- rather than matched by table identity, which a /reload breaks.
    local saved = self._currentHistoryKey and self.bossHistory[self._currentHistoryKey]
    if saved then
        saved.items     = self.currentItems
        saved.results   = self.results
        saved.responses = self.responses
        return
    end
    -- Make unique if same boss killed twice
    if self.bossHistory[key] then
        local i = 2
        while self.bossHistory[key .. " (" .. i .. ")"] do i = i + 1 end
        key = key .. " (" .. i .. ")"
    end

    self.bossHistory[key] = {
        items     = self.currentItems,
        results   = self.results,
        responses = self.responses,
    }
    tinsert(self.bossHistoryOrder, key)
    self._currentHistoryKey = key
end

------------------------------------------------------------------------
-- Get eligible players for the current loot roll (snapshot taken at
-- LOOT_TABLE send time).  Returns a shallow copy of the internal set.
------------------------------------------------------------------------
function Session:GetEligiblePlayers()
    local out = {}
    for name, v in pairs(self._rollEligiblePlayers) do
        out[name] = v
    end
    return out
end

------------------------------------------------------------------------
-- Get boss history keys (for dropdown)
------------------------------------------------------------------------
function Session:GetBossHistoryKeys()
    local keys = {}
    for k in pairs(self.bossHistory or {}) do
        tinsert(keys, k)
    end
    table.sort(keys)
    return keys
end

------------------------------------------------------------------------
-- Get boss history data
------------------------------------------------------------------------
function Session:GetBossHistory(key)
    return self.bossHistory and self.bossHistory[key]
end

------------------------------------------------------------------------
-- REASSIGN an already-won item to a different player (Leader only)
-- Removes count from old winner, adds to new, updates history & trade.
------------------------------------------------------------------------
function Session:ReassignItem(itemIdx, newWinner, skipCount)
    if not self:IsLootMasterActionAllowed() then return end

    local result = self.results[itemIdx]
    if not result or not result.winner then
        ns.ChatPrint("Normal", "No winner to reassign from for item " .. itemIdx .. ".")
        return
    end

    -- A typed name is only accepted for someone actually in the group (or a
    -- debug fake player); a typo must not create a phantom identity that
    -- gets a count, a history row and a broadcast.
    newWinner = ns.CanonicalName(newWinner)
    if not newWinner or newWinner == "" then return end
    if not self:_IsPlayerInGroup(newWinner) and not self._debugFakePlayerSet[newWinner] then
        ns.ChatPrint("Normal", newWinner .. " is not in the group; item not reassigned.")
        return
    end

    local oldWinner = result.winner
    if ns.NamesEqual(oldWinner, newWinner) then
        ns.ChatPrint("Normal", "New winner is the same as current winner.")
        return
    end

    local item = self.currentItems[itemIdx]
    -- true only if the win was (and the reassignment will be) counted
    local countsForLoot = self:_ChoiceCountsForLoot(result.choice, itemIdx)

    -- Adjust loot counts
    if countsForLoot then
        -- Decrement old winner
        local oldCount = ns.LootCount:GetCount(oldWinner)
        ns.LootCount:SetCount(oldWinner, math.max(0, oldCount - 1))

        -- Increment new winner (skipped for disenchant reassignments)
        if not skipCount then
            ns.LootCount:IncrementCount(newWinner)
        end
    end

    local newCount = ns.LootCount:GetCount(newWinner)

    -- Update result
    self.results[itemIdx].winner = newWinner
    self.results[itemIdx].newCount = newCount

    -- Update trade queue: change winner on matching entry
    for _, entry in ipairs(self.tradeQueue) do
        if entry.itemLink == (item and item.link) and entry.winner == oldWinner then
            entry.winner = newWinner
            entry.awarded = false
            break
        end
    end

    -- Update history: find the matching entry and update it
    local history = ns.LootHistory:GetAll()
    for i = #history, 1, -1 do -- search newest first
        local e = history[i]
        if e.itemLink == (item and item.link) and e.player == ns.PlayerLinks:ResolveIdentity(oldWinner) then
            e.player = ns.PlayerLinks:ResolveIdentity(newWinner)
            e.lootCountAtWin = (countsForLoot and not skipCount) and (newCount - 1) or newCount
            break
        end
    end

    -- Broadcast updated result to group
    ns.Comm:BroadcastRollResult(itemIdx, newWinner, result.roll, result.tiebreakerRoll, result.choice, nil, oldWinner)

    -- Sync counts
    ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })

    -- Announce reassignment
    local itemLink = item and item.link or "Unknown Item"
    local displayName = itemLink:match("|h(%[.-%])|h") or itemLink
    local channel = ns.GetAnnounceChannel()
    local msg = string.format("%s reassigned: %s → %s (Loot Count: %d)",
        displayName, oldWinner, newWinner, newCount)

    if IsInRaid() or IsInGroup() then
        SendChatMessage("[OLL] " .. msg, channel)
    else
        ns.ChatPrint("Leader", msg)
    end

    ns.ChatPrint("Leader", "Reassigned " .. (item and item.link or "item") .. " from " .. oldWinner .. " to " .. newWinner)

    -- Refresh UI
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
    if ns.RollFrame then ns.RollFrame:ShowResult(itemIdx, self.results[itemIdx]) end
    self:_SchedulePersist()
end

------------------------------------------------------------------------
-- Get trade queue
------------------------------------------------------------------------
function Session:GetTradeQueue()
    return self.tradeQueue
end

------------------------------------------------------------------------
-- ON ROLL RESULT RECEIVED (Members)
------------------------------------------------------------------------
function Session:OnRollResultReceived(payload, sender)
    if not self:_IsTrustedSender(sender) then return end

    local itemIdx = payload.itemIdx
    local existing = self.results[itemIdx]

    -- Build rankedCandidates from locally-tracked choices (populated by CHOICES_UPDATE
    -- deltas in real time) so that the boss history view shows the full ranked list
    -- without needing rankedCandidates in the broadcast payload.
    -- The leader echo guard reuses the locally-computed list from ResolveItem.
    local rankedCandidates = (existing and existing.rankedCandidates) or {}
    if not (existing and existing.rankedCandidates) then
        if ns.LargeRollFrame and ns.LargeRollFrame._choices then
            local choices = ns.LargeRollFrame._choices[itemIdx] or {}
            local rollOptions = self.rollOptions or ns.DEFAULT_ROLL_OPTIONS
            local optPriority = {}
            for _, opt in ipairs(rollOptions) do
                optPriority[opt.name] = opt.priority or 999
            end
            for player, data in pairs(choices) do
                tinsert(rankedCandidates, {
                    player = player,
                    choice = data.choice,
                    roll   = data.roll,
                    count  = data.countAtRoll or ns.LootCount:GetCount(player),
                })
            end
            table.sort(rankedCandidates, function(a, b)
                local pa = (a.choice and optPriority[a.choice]) or 999
                local pb = (b.choice and optPriority[b.choice]) or 999
                if pa ~= pb then return pa < pb end
                return (a.roll or 0) > (b.roll or 0)
            end)
        end
    end

    self.results[itemIdx] = {
        winner           = payload.winner,
        roll             = payload.roll,
        tiebreakerRoll   = payload.tiebreakerRoll,
        choice           = payload.choice,
        rankedCandidates = rankedCandidates,
    }

    -- Reassignment: update the existing history row instead of adding one.
    -- Counts are not touched here; the leader sends a full COUNT_SYNC right after.
    if payload.reassignFrom then
        local item     = self.currentItems and self.currentItems[itemIdx]
        local itemLink = item and item.link
        local oldId    = ns.PlayerLinks:ResolveIdentity(payload.reassignFrom)
        local newId    = ns.PlayerLinks:ResolveIdentity(payload.winner)
        local history  = ns.LootHistory:GetAll()
        for i = #history, 1, -1 do
            local e = history[i]
            if e.itemLink == itemLink and e.player == oldId then
                e.player = newId
                break
            end
        end
        if ns.RollFrame then ns.RollFrame:ShowResult(itemIdx, self.results[itemIdx]) end
        return
    end

    -- Self-increment the winner's loot count so the UI stays accurate for
    -- subsequent items in this roll. The final COUNT_SYNC delta authoritatively
    -- reconciles after all items resolve.
    if payload.winner and payload.choice
            and self:_ChoiceCountsForLoot(payload.choice, itemIdx) then
        ns.LootCount:IncrementCount(payload.winner)
    end

    -- History entry includes pre-computed rolls; no reconstruction needed.
    if payload.entry then
        ns.LootHistory:AddEntry(payload.entry)
    end

    if ns.RollFrame then ns.RollFrame:ShowResult(itemIdx, self.results[itemIdx]) end

    -- Check if all items are resolved
    local allResolved = true
    for i = 1, #(self.currentItems or {}) do
        if not self.results[i] then allResolved = false; break end
    end
    -- (an empty item list means we never received this boss's LOOT_TABLE;
    -- saving would just add a bogus "Unknown" entry per result)
    if allResolved and #(self.currentItems or {}) > 0 then
        -- Save boss history locally so the history view is populated for members
        self:_SaveBossHistory()
        if ns.RollFrame then ns.RollFrame:UnlockBossDropdown() end
    end
end

------------------------------------------------------------------------
-- ON SESSION SYNC RECEIVED (members)
-- Upserts the session record broadcast by the leader into local history.
------------------------------------------------------------------------
function Session:OnSessionSyncReceived(payload, sender)
    if not self:_IsTrustedSender(sender) then return end
    local rec = payload.session
    if not rec or not rec.id then return end
    for _, s in ipairs(ns.db.global.sessionHistory) do
        if s.id == rec.id then
            s.endTime     = rec.endTime
            s.bosses      = rec.bosses
            s.lootMasters = rec.lootMasters
            if rec.savedSettings then s.savedSettings = rec.savedSettings end
            return
        end
    end
    table.insert(ns.db.global.sessionHistory, rec)
end

------------------------------------------------------------------------
-- IS OWNER OF SESSION
-- Returns true if the current player (or any of their linked alts /
-- characters stored in myCharacters) matches the session's leader or
-- any of its loot masters.  Used for resume eligibility checks.
------------------------------------------------------------------------
function Session:_IsOwnerOfSession(rec)
    local me = ns.GetPlayerNameRealm()
    -- Build a list of all character names for this account
    local myNames = { me }
    for _, c in ipairs(ns.db.global.myCharacters.chars or {}) do
        myNames[#myNames + 1] = c
    end
    local mainId = ns.PlayerLinks:ResolveIdentity(me)
    if mainId ~= me then myNames[#myNames + 1] = mainId end

    for _, name in ipairs(myNames) do
        if ns.NamesMatch(name, rec.leader) then return true end
        for _, lm in ipairs(rec.lootMasters or {}) do
            if ns.NamesMatch(name, lm) then return true end
        end
    end
    return false
end

------------------------------------------------------------------------
-- GET RESUMABLE SESSIONS
-- Returns an array of session records from this week's lockout that the
-- current player owns (newest-first).  Empty table if none qualify.
------------------------------------------------------------------------
function Session:_GetResumableSessions()
    local resetTime = ns.GetCurrentWeeklyResetTime()
    local sessions  = ns.db.global.sessionHistory or {}
    local result    = {}
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if s.startTime >= resetTime       -- within current weekly lockout
        and s.endTime ~= nil              -- has been ended (not currently active)
        and s.id ~= self.activeSessionId  -- not the session already running
        and self:_IsOwnerOfSession(s) then
            result[#result + 1] = s
        end
    end
    return result
end

------------------------------------------------------------------------
-- RESUME SESSION (Leader only)
-- Reopens a previous session from this weekly lockout.
-- Restores settings, boss history stubs, and broadcasts to the group.
-- Trade queue is NOT restored.
------------------------------------------------------------------------
function Session:ResumeSession(rec)
    -- Allow if the player is the current raid leader OR owns the session as LM/leader
    if not UnitIsGroupLeader("player") and not self:_IsOwnerOfSession(rec) then
        ns.ChatPrint("Normal", "You do not have permission to resume this session.")
        return
    end
    if self:IsActive() then
        ns.ChatPrint("Normal", "A session is already active.")
        return
    end

    self.state           = self.STATE_ACTIVE
    self.leaderName      = ns.GetPlayerNameRealm()
    self.activeSessionId = rec.id   -- preserve the original session ID

    -- Clear per-roll state; do NOT restore trade queue
    self.currentItems     = {}
    self.currentBoss      = "Unknown"
    self.currentItemIdx   = 0
    self.responses        = {}
    self.results          = {}
    self.bossHistory      = {}
    self.bossHistoryOrder = {}
    self.tradeQueue       = {}
    self._pendingPromptItems = nil
    self._pendingPromptBoss  = nil
    self:_ResetRollState()

    -- Restore boss name stubs so the dropdown shows prior-night bosses
    for _, bossName in ipairs(rec.bosses or {}) do
        self.bossHistory[bossName] = { items = {}, results = {}, responses = {} }
        tinsert(self.bossHistoryOrder, bossName)
    end

    -- Restore session settings (savedSettings may be nil on legacy records)
    local sv = rec.savedSettings
    if sv then
        self.rollOptions                  = sv.rollOptions or ns.Settings:GetRollOptions()
        self.sessionDisenchanter          = sv.disenchanter or ""
        self.sessionLootMaster            = sv.lootMaster or self.leaderName
        self.sessionLootMasterRestriction = sv.lootMasterRestriction or "anyLeader"
        self.sessionLootCountEnabled      = sv.lootCountEnabled ~= false
        self.sessionLootCountLockedToMain = sv.lootCountLockedToMain ~= false
    else
        -- Legacy record: use current profile defaults (same as StartSession)
        self.rollOptions                  = ns.Settings:GetRollOptions()
        self.sessionDisenchanter          = ns.db.profile.disenchanter or ""
        self.sessionLootMaster            = self.leaderName
        self.sessionLootMasterRestriction = ns.db.profile.lootMasterRestriction or "anyLeader"
        self.sessionLootCountEnabled      = ns.db.profile.lootCountEnabled ~= false
        self.sessionLootCountLockedToMain = ns.db.profile.lootCountLockedToMain ~= false
    end

    -- Re-open the session record (clear endTime to mark it active again)
    rec.endTime = nil

    -- Current members receive SESSION_RESUME; only later joiners get SESSION_JOIN.
    self._lastGroupSnapshot = self:_SnapshotGroupMembers()

    -- Restore pending roll from DB if present (survives /reload in promptForStart mode)
    if ns.db.profile.lootRollTriggering == "promptForStart"
            and ns.db.global.pendingRoll
            and ns.db.global.pendingRoll.items then
        local saved = ns.db.global.pendingRoll
        self.currentItems        = saved.items
        self.currentBoss         = saved.bossName or "Unknown"
        self.currentItemIdx      = 0
        self.responses           = {}
        self.results             = {}
        self._pendingPromptItems = saved.items
        self._pendingPromptBoss  = saved.bossName
        if ns.LeaderFrame then
            ns.LeaderFrame:OnPendingRollReady(saved.items, saved.bossName)
        end
    end

    -- Merge leader's own character list into playerLinks before broadcasting
    ns.PlayerLinks:MergePlayerCharList(ns.PlayerLinks:GetMyCharactersPayload())

    -- Broadcast SESSION_RESUME to the group (leader keeps the same table)
    local tokensCount = sv and sv.tokensCountAsLoot
    if tokensCount == nil then tokensCount = ns.db.profile.tokensCountAsLoot == true end
    local recipesCount = sv and sv.recipesCountAsLoot
    if recipesCount == nil then recipesCount = ns.db.profile.recipesCountAsLoot == true end
    local settings = {
        lootThreshold         = sv and sv.lootThreshold         or ns.db.profile.lootThreshold,
        rollTimer             = sv and sv.rollTimer             or ns.db.profile.rollTimer,
        autoPassBOE           = sv and sv.autoPassBOE           or ns.db.profile.autoPassBOE,
        announceChannel       = sv and sv.announceChannel       or ns.db.profile.announceChannel,
        disenchanter          = self.sessionDisenchanter,
        lootMaster            = self.sessionLootMaster,
        lootMasterRestriction = self.sessionLootMasterRestriction,
        lootCountEnabled      = self.sessionLootCountEnabled,
        lootCountLockedToMain = self.sessionLootCountLockedToMain,
        tokensCountAsLoot     = tokensCount,
        recipesCountAsLoot    = recipesCount,
    }
    self.sessionSettings = settings
    ns.Comm:BroadcastSessionResume(settings, self.rollOptions, rec.id, rec.bosses or {})
    ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })
    ns.Comm:Send(ns.Comm.MSG.LINKS_SYNC, { links = ns.PlayerLinks:GetLinksTable() })

    self:_PersistActiveSession()
    ns.ChatPrint("Normal", "Loot session resumed.")
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
    self:_MaybeShowHoldWPopup()

    -- Show (or refresh if already visible) the leader frame
    if ns.IsLeader() and ns.LeaderFrame then
        ns.LeaderFrame:Show()
    end
end

------------------------------------------------------------------------
-- ON SESSION RESUME RECEIVED (members)
-- Mirrors OnSessionStartReceived but also restores sessionId and boss
-- stubs, then upserts/re-opens the session record in local history.
------------------------------------------------------------------------
function Session:OnSessionResumeReceived(payload, sender)
    -- Accept only from a current WoW group leader/officer
    if not Session.IsGroupLeaderOrOfficer(sender) then return end

    -- Enforce join restrictions (same as OnSessionStartReceived)
    local restrictions = ns.db.profile.joinRestrictions
    if restrictions and (restrictions.friends or restrictions.guild) then
        local leader  = payload.leaderName or sender
        local allowed = false
        if restrictions.friends and _IsFriend(leader)      then allowed = true end
        if not allowed and restrictions.guild and _IsGuildMember(leader) then allowed = true end
        if not allowed then
            ns.ChatPrint("Normal", "|cffff4444OLL: Session from " .. leader
                .. " blocked by join restrictions.|r")
            return
        end
    end

    self.state           = self.STATE_ACTIVE
    self.leaderName      = payload.leaderName or sender
    self.activeSessionId = payload.sessionId
    self.rollOptions     = payload.rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self.currentItems    = {}
    self.responses       = {}
    self.results         = {}
    self.bossHistory     = {}
    self.bossHistoryOrder = {}
    self.tradeQueue      = {}
    self:_ClearPendingAcks()

    -- Restore boss stubs for the dropdown
    for _, bossName in ipairs(payload.bosses or {}) do
        self.bossHistory[bossName] = { items = {}, results = {}, responses = {} }
        tinsert(self.bossHistoryOrder, bossName)
    end

    -- Apply synced settings
    if payload.settings then
        self.sessionSettings              = payload.settings
        self.sessionDisenchanter          = payload.settings.disenchanter or ""
        self.sessionLootMaster            = payload.settings.lootMaster or ""
        self.sessionLootMasterRestriction = payload.settings.lootMasterRestriction or "anyLeader"
        self.sessionLootCountEnabled      = payload.settings.lootCountEnabled ~= false
        self.sessionLootCountLockedToMain = payload.settings.lootCountLockedToMain ~= false
    end
    if payload.counts then ns.LootCount:SetCountsTable(payload.counts) end
    if payload.links  then ns.PlayerLinks:SetLinksTable(payload.links)  end

    -- Upsert the session record in local history (re-open it)
    local found = false
    for _, s in ipairs(ns.db.global.sessionHistory) do
        if s.id == payload.sessionId then
            s.endTime = nil
            if payload.bosses then s.bosses = payload.bosses end
            found = true; break
        end
    end
    if not found and payload.sessionId then
        table.insert(ns.db.global.sessionHistory, {
            id          = payload.sessionId,
            startTime   = payload.sessionId,
            endTime     = nil,
            leader      = payload.leaderName or sender,
            bosses      = payload.bosses or {},
            lootMasters = payload.settings and { payload.settings.lootMaster or "" } or {},
        })
    end

    -- Broadcast our character list to the group (same peer exchange as SESSION_START).
    local myChars = ns.PlayerLinks:GetMyCharactersPayload()
    if #myChars.chars > 0 then
        ns.Comm:Send(ns.Comm.MSG.PLAYER_CHAR_LIST, myChars)
    end

    ns.ChatPrint("Normal", "Loot session resumed by " .. self.leaderName .. ".")
    self:_MaybeShowHoldWPopup()
end

------------------------------------------------------------------------
-- ON SESSION DELETE RECEIVED (members)
-- Removes the session record and its loot entries, then refreshes the
-- session history frame silently if it is open.
------------------------------------------------------------------------
function Session:OnSessionDeleteReceived(payload, sender)
    -- Deletions usually happen while no session is active, when leaderName
    -- is stale; accept from the session leader or any current group
    -- leader/officer.
    local fromSessionLeader = self:IsActive() and ns.NamesEqual(sender, self.leaderName)
    if not fromSessionLeader and not Session.IsGroupLeaderOrOfficer(sender) then return end
    local sid = payload.sessionId
    if not sid then return end

    local sessions = ns.db.global.sessionHistory or {}
    for i = #sessions, 1, -1 do
        if sessions[i].id == sid then table.remove(sessions, i); break end
    end

    local history = ns.db.global.lootHistory or {}
    for i = #history, 1, -1 do
        if history[i].sessionId == sid then table.remove(history, i) end
    end

    if ns.SessionHistoryFrame then
        ns.SessionHistoryFrame:OnSessionDeleted(sid)
    end
end

------------------------------------------------------------------------
-- ON SESSION TAKEOVER RECEIVED (all members except the new leader)
------------------------------------------------------------------------
function Session:OnSessionTakeoverReceived(payload, sender)
    -- Verify sender is an actual WoW group leader/officer (not just anyone)
    if not Session.IsGroupLeaderOrOfficer(sender) then return end

    local newLeader = payload.newLeader
    if not newLeader then return end

    -- Ignore our own broadcast (TakeoverSession already set our state)
    if ns.NamesMatch(ns.GetPlayerNameRealm(), newLeader) then return end

    if not self:IsActive() then return end

    self.leaderName = newLeader

    if payload.rollOptions then self.rollOptions = payload.rollOptions end
    if payload.settings then
        self.sessionSettings              = payload.settings
        self.sessionDisenchanter          = payload.settings.disenchanter or ""
        self.sessionLootMaster            = payload.settings.lootMaster or ""
        self.sessionLootMasterRestriction = payload.settings.lootMasterRestriction or "anyLeader"
        self.sessionLootCountEnabled      = payload.settings.lootCountEnabled ~= false
        self.sessionLootCountLockedToMain = payload.settings.lootCountLockedToMain ~= false
    end
    if payload.counts then ns.LootCount:SetCountsTable(payload.counts) end
    if payload.links  then ns.PlayerLinks:SetLinksTable(payload.links) end

    ns.ChatPrint("Normal", "Session control assumed by " .. newLeader .. ".")
    local saved = ns.db.global.activeSession
    if saved and ns.NamesMatch(saved.leaderName, ns.GetPlayerNameRealm()) then
        self:_ClearPersistedSession()
    end
end

------------------------------------------------------------------------
-- Returns a set { ["Name-Realm"] = true } of all current group members.
-- Includes the local player. Used to snapshot eligible players at the
-- start of a loot roll.
------------------------------------------------------------------------
function Session:_SnapshotGroupMembers()
    local players = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        players[ns.GetPlayerNameRealm()] = true
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                if not name:find("-") then
                    name = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                players[name] = true
            end
        end
    else
        players[ns.GetPlayerNameRealm()] = true
        for i = 1, numMembers - 1 do
            local unit = "party" .. i
            local name = GetUnitName(unit, true)
            if name then
                if not name:find("-") then
                    name = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                players[name] = true
            end
        end
    end
    return players
end

------------------------------------------------------------------------
-- CINEMATIC START
-- Fired for both in-engine cinematics (CINEMATIC_START) and video cutscenes
-- (PLAY_MOVIE). Sets the local cinematic flag on all clients.
-- LM: stops any active roll; items captured before _StartReadyCheck runs
-- are re-queued via _pendingCapturedItems and retried on CINEMATIC_STOP.
------------------------------------------------------------------------
function Session:OnCinematicStart()
    self._inCinematic       = true
    self._readyForLootTable = false

    if not self:IsLootAuthority() then return end

    if self.state == self.STATE_ROLLING or self.state == self.STATE_RESOLVING then
        -- Roll in progress: pause it (nothing is awarded) and re-open the
        -- unresolved items when the cinematic ends.
        self:SuspendRoll()
    end
    -- If items arrived while _inCinematic was already true they are already
    -- sitting in _pendingCapturedItems; no extra action needed here.
end

------------------------------------------------------------------------
-- CINEMATIC STOP
-- Fired when a cinematic or video finishes (CINEMATIC_STOP / STOP_MOVIE).
-- Members send any deferred ready-ack; the LM processes any queued items.
------------------------------------------------------------------------
function Session:OnCinematicStop()
    self._inCinematic       = false
    self._readyForLootTable = true

    -- Member: if a ready-check arrived while we were in the cinematic, ack now
    if self._pendingLTRCLeader then
        local leader = self._pendingLTRCLeader
        self._pendingLTRCLeader = nil
        ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE_READY_ACK, {}, leader)
    end

    -- Member: if the LOOT_TABLE broadcast arrived while in the cinematic, process it now
    if self._pendingLootTable then
        local payload = self._pendingLootTable
        self._pendingLootTable = nil
        self:OnLootTableReceived(payload, self.leaderName)
    end

    -- LM: restart a roll that was paused by the cinematic
    if self:IsLootAuthority() and self._suspendedRoll then
        self:ResumeSuspendedRoll()
    end

    -- LM: if items were queued during the cinematic, kick off the roll now
    if self:IsLootAuthority() and self._pendingCapturedItems then
        local items     = self._pendingCapturedItems
        local bossName  = self._pendingCapturedBoss
        local bossGUIDs = self._pendingCapturedGUIDs
        local rollTimer = self._pendingCapturedTimer
        self._pendingCapturedItems = nil
        self._pendingCapturedBoss  = nil
        self._pendingCapturedGUIDs = nil
        self._pendingCapturedTimer = nil
        self:OnItemsCaptured(items, bossName, bossGUIDs, rollTimer)
    end
end

------------------------------------------------------------------------
-- GROUP ROSTER CHANGED
------------------------------------------------------------------------
function Session:OnGroupRosterUpdate()
    if not self:IsActive() then return end

    -- (1) Loot authority: auto-pass any eligible players who left during
    --     an active roll so AllResponded() is not permanently blocked.
    if self:IsLootAuthority()
            and (self.state == self.STATE_ROLLING or self.state == self.STATE_RESOLVING)
            and next(self._rollEligiblePlayers) then

        local currentGroup = self:_SnapshotGroupMembers()
        for playerName in pairs(self._rollEligiblePlayers) do
            if not currentGroup[playerName]
                    and not ns.NamesMatch(playerName, ns.GetPlayerNameRealm()) then
                -- Player was eligible but has left — auto-pass all unresolved items
                local passedAny = false
                for idx = 1, #self.currentItems do
                    if not self.results[idx] then
                        local resp = self.responses[idx]
                        if not resp then
                            resp = {}
                            self.responses[idx] = resp
                        end
                        local alreadyResponded = false
                        for respPlayer in pairs(resp) do
                            if ns.NamesMatch(respPlayer, playerName) then
                                alreadyResponded = true
                                break
                            end
                        end
                        if not alreadyResponded then
                            resp[playerName] = { choice = "Pass", countAtRoll = 0, roll = math.random(1, 100) }
                            passedAny = true
                        end
                    end
                end
                if passedAny then
                    ns.ChatPrint("Normal", playerName .. " left the group and has been auto-passed.")
                end
            end
        end

        -- Re-check resolution for any item that is now fully responded
        if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
        for idx = 1, #self.currentItems do
            if not self.results[idx] and self:AllResponded(idx) and self:_AllPreviousResolved(idx) then
                self:ResolveItem(idx)
                break  -- _TryResolveNext will chain the rest
            end
        end
    end

    -- (2) OLL session leader: bootstrap any players who joined mid-session.
    --     SESSION_START already carries counts/links; the late joiner's
    --     _rollEligiblePlayers exclusion is handled by the snapshot taken at
    --     LOOT_TABLE send time, so no change is needed to roll eligibility.
    if ns.NamesMatch(ns.GetPlayerNameRealm(), self.leaderName) then
        local currentGroup = self:_SnapshotGroupMembers()
        local prev = self._lastGroupSnapshot or {}
        for player in pairs(currentGroup) do
            if not prev[player] and not ns.NamesMatch(player, ns.GetPlayerNameRealm()) then
                self:_SendSessionJoin(player)
            end
        end
        self._lastGroupSnapshot = currentGroup
    end

    -- (3) WoW group leader/officer (but not the OLL session leader): notify
    --     that the OLL session leader may have left.
    if not ns.IsLeader() then return end
    if ns.NamesMatch(ns.GetPlayerNameRealm(), self.leaderName) then return end

    local leaderFound = false
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local rName = GetRaidRosterInfo(i)
            if rName and ns.NamesMatch(rName, self.leaderName) then
                leaderFound = true
                break
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local pName = UnitName("party" .. i)
            if pName and ns.NamesMatch(pName, self.leaderName) then
                leaderFound = true
                break
            end
        end
    end

    if leaderFound then
        self._leaderLeftNotified = false
    elseif not self._leaderLeftNotified then
        self._leaderLeftNotified = true
        ns.ChatPrint("Normal", "|cffff8000[OLL]|r Session leader is no longer in the group. Use |cffffffff/oll takeover|r to assume session control.")
    end
end

------------------------------------------------------------------------
-- DEBUG MODE: Start debug session
------------------------------------------------------------------------
function Session:StartDebugSession()
    if not ns.IsLeader() then
        ns.ChatPrint("Normal", "Only the group leader can start a debug session.")
        return
    end
    -- Re-entering would overwrite _savedState with the debug session itself
    -- and later "restore" it as real.
    if self.debugMode then return end

    -- Save current state if a session is running
    if self:IsActive() then
        self._savedState = {
            state            = self.state,
            leaderName       = self.leaderName,
            rollOptions      = self.rollOptions,
            currentItems     = self.currentItems,
            currentBoss      = self.currentBoss,
            currentItemIdx   = self.currentItemIdx,
            responses        = self.responses,
            results          = self.results,
            bossHistory      = self.bossHistory,
            bossHistoryOrder = self.bossHistoryOrder,
            tradeQueue       = self.tradeQueue,
            sessionSettings  = self.sessionSettings,
        }
        -- Silently end the current session
        if self._timerHandle then
            ns.addon:CancelTimer(self._timerHandle)
            self._timerHandle = nil
        end
        if self._tickBroadcastHandle then
            ns.addon:CancelTimer(self._tickBroadcastHandle)
            self._tickBroadcastHandle = nil
        end
        self.state = self.STATE_IDLE
    end

    -- Start fresh debug session
    self.debugMode              = true
    self._debugFakePlayers      = {}
    self._debugFakePlayerSet    = {}
    ns.LootCount:StartDebug()
    self.sessionLootCountEnabled      = ns.db.profile.lootCountEnabled ~= false
    self.sessionLootCountLockedToMain = ns.db.profile.lootCountLockedToMain ~= false
    self.state = self.STATE_ACTIVE
    self.leaderName = ns.GetPlayerNameRealm()
    self.currentItems = {}
    self.currentBoss = "Debug Boss"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}
    self.bossHistory = {}
    self.bossHistoryOrder = {}
    self.tradeQueue = {}
    self.rollOptions = ns.Settings:GetRollOptions()
    self:_ResetRollState()

    -- Broadcast debug session start to group
    self.sessionSettings = {
        lootThreshold      = ns.db.profile.lootThreshold,
        rollTimer          = ns.db.profile.rollTimer,
        autoPassBOE        = ns.db.profile.autoPassBOE,
        announceChannel    = ns.db.profile.announceChannel,
        tokensCountAsLoot  = ns.db.profile.tokensCountAsLoot  == true,
        recipesCountAsLoot = ns.db.profile.recipesCountAsLoot == true,
    }
    ns.Comm:BroadcastSessionStart(self.sessionSettings, self.rollOptions)

    ns.ChatPrint("Debug", "|cffff4444[DEBUG]|r Debug session started. Loot counts and history will not be affected.")

    if ns.LeaderFrame then ns.LeaderFrame:Show(); ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- DEBUG MODE: End debug session
------------------------------------------------------------------------
function Session:EndDebugSession()
    if not self.debugMode then return end

    -- Cancel any active timer
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end

    self.debugMode           = false
    self._testLootMode       = false
    self._debugFakePlayers   = {}
    self._debugFakePlayerSet = {}
    ns.LootCount:EndDebug()
    self.sessionLootCountEnabled      = nil
    self.sessionLootCountLockedToMain = nil
    self.sessionSettings              = nil
    self.state = self.STATE_IDLE

    -- Broadcast end
    ns.Comm:Send(ns.Comm.MSG.SESSION_END, {})

    ns.ChatPrint("Debug", "|cffff4444[DEBUG]|r Debug session ended. No data was saved.")

    -- Hide frames
    if ns.LeaderFrame then ns.LeaderFrame:Reset() end
    if ns.RollFrame then ns.RollFrame:Reset() end
    if ns.LeaderFrame and ns.LeaderFrame._reassignPopup then
        ns.LeaderFrame._reassignPopup:Hide()
    end

    -- Restore saved state if one existed
    if self._savedState then
        local s               = self._savedState
        self.state            = s.state
        self.leaderName       = s.leaderName
        self.rollOptions      = s.rollOptions
        self.currentItems     = s.currentItems
        self.currentBoss      = s.currentBoss
        self.currentItemIdx   = s.currentItemIdx
        self.responses        = s.responses
        self.results          = s.results
        self.bossHistory      = s.bossHistory
        self.bossHistoryOrder = s.bossHistoryOrder or {}
        self.tradeQueue       = s.tradeQueue
        self.sessionSettings  = s.sessionSettings
        self._savedState      = nil

        ns.ChatPrint("Normal", "Previous session restored.")
        self:_SchedulePersist()
    end
end

------------------------------------------------------------------------
-- DEBUG MODE: Build fake player roster for a loot drop
------------------------------------------------------------------------
function Session:_SetupFakePlayers(count)
    self._debugFakePlayers   = {}
    self._debugFakePlayerSet = {}

    local used = {}
    for i = 1, count do
        local name, attempts = nil, 0
        repeat
            name = FAKE_PLAYER_FIRST[math.random(#FAKE_PLAYER_FIRST)]
            attempts = attempts + 1
        until not used[name] or attempts > 20
        if attempts > 20 then name = "FakePlayer" .. i end
        used[name] = true

        local fullName = name .. "-" .. FAKE_PLAYER_REALM
        self._debugFakePlayers[i]       = fullName
        self._debugFakePlayerSet[fullName] = true
    end
end

------------------------------------------------------------------------
-- DEBUG MODE: Submit a single fake player's random roll response
------------------------------------------------------------------------
function Session:_SubmitFakePlayerResponse(player, itemIdx)
    local opts   = self.rollOptions or ns.DEFAULT_ROLL_OPTIONS
    local choice = opts[math.random(#opts)].name
    self:OnRollResponseReceived({ itemIdx = itemIdx, choice = choice, player = player }, player)
end

------------------------------------------------------------------------
-- DEBUG MODE: True when every non-fake player has responded for itemIdx
------------------------------------------------------------------------
function Session:_AllRealPlayersResponded(itemIdx)
    local responses = self.responses[itemIdx] or {}

    local realExpected
    if next(self._rollEligiblePlayers) then
        realExpected = 0
        for _ in pairs(self._rollEligiblePlayers) do realExpected = realExpected + 1 end
    else
        realExpected = ns.GetGroupSize()
    end

    if next(self._rollEligiblePlayers) then
        for player in pairs(self._rollEligiblePlayers) do
            if not responses[player] then return false end
        end
        return true
    end
    local realCount = 0
    for player in pairs(responses) do
        if not self._debugFakePlayerSet[player] then
            realCount = realCount + 1
        end
    end
    return realCount >= realExpected
end

------------------------------------------------------------------------
-- DEBUG MODE: Submit deferred responses for fake players 2..N
------------------------------------------------------------------------
function Session:_SubmitDeferredFakePlayers(itemIdx)
    for i = 2, #self._debugFakePlayers do
        local player = self._debugFakePlayers[i]
        if not (self.responses[itemIdx] and self.responses[itemIdx][player]) then
            self:_SubmitFakePlayerResponse(player, itemIdx)
        end
    end
end

------------------------------------------------------------------------
-- MANUAL ROLL: Push a manually assembled item list as a new loot roll
------------------------------------------------------------------------
-- @param rollTimer number? per-roll countdown override in seconds
function Session:StartManualRoll(items, rollTimer)
    if not self:IsLootMasterActionAllowed() then
        ns.ChatPrint("Normal", "You are not permitted to start a manual roll.")
        return
    end
    if self.state ~= self.STATE_ACTIVE then
        ns.ChatPrint("Normal", "Cannot start a manual roll while a roll is already in progress.")
        return
    end
    if not items or #items == 0 then
        ns.ChatPrint("Normal", "No items to roll on.")
        return
    end

    local bossName = "Manual " .. date("%H:%M:%S")
    self:OnItemsCaptured(items, bossName, nil, rollTimer)
end

------------------------------------------------------------------------
-- TEST LOOT: One-shot test roll from the CheckParty frame.
-- Works like a debug session (no counts, no history, no trades), but
-- auto-ends when all items are resolved and restores any prior session.
------------------------------------------------------------------------
function Session:StartTestLoot()
    if not ns.IsLeader() then
        ns.ChatPrint("Normal", "Only the group leader can start a test loot.")
        return
    end
    if self.state == self.STATE_ROLLING or self.state == self.STATE_RESOLVING then
        ns.ChatPrint("Normal", "Cannot start test loot while a roll is in progress.")
        return
    end
    if self.debugMode then
        ns.ChatPrint("Normal", "Cannot start test loot while already in debug/test mode.")
        return
    end
    if not ns.DebugWindow then
        ns.ChatPrint("Debug", "DebugWindow not loaded.")
        return
    end

    -- Save current state if a session is running
    if self:IsActive() then
        self._savedState = {
            state            = self.state,
            leaderName       = self.leaderName,
            rollOptions      = self.rollOptions,
            currentItems     = self.currentItems,
            currentBoss      = self.currentBoss,
            currentItemIdx   = self.currentItemIdx,
            responses        = self.responses,
            results          = self.results,
            bossHistory      = self.bossHistory,
            bossHistoryOrder = self.bossHistoryOrder,
            tradeQueue       = self.tradeQueue,
            sessionSettings  = self.sessionSettings,
        }
        if self._timerHandle then
            ns.addon:CancelTimer(self._timerHandle)
            self._timerHandle = nil
        end
        if self._tickBroadcastHandle then
            ns.addon:CancelTimer(self._tickBroadcastHandle)
            self._tickBroadcastHandle = nil
        end
        self.state = self.STATE_IDLE
    end

    -- Set up test mode
    self._testLootMode       = true
    self.debugMode           = true
    self._debugFakePlayers   = {}
    self._debugFakePlayerSet = {}
    ns.LootCount:StartDebug()
    self.sessionLootCountEnabled      = ns.db.profile.lootCountEnabled ~= false
    self.sessionLootCountLockedToMain = ns.db.profile.lootCountLockedToMain ~= false
    self.state               = self.STATE_ACTIVE
    self.leaderName          = ns.GetPlayerNameRealm()
    self.currentItems        = {}
    self.currentBoss         = "Test Boss"
    self.currentItemIdx      = 0
    self.responses           = {}
    self.results             = {}
    self.bossHistory         = {}
    self.bossHistoryOrder    = {}
    self.tradeQueue          = {}
    self.rollOptions         = ns.Settings:GetRollOptions()
    self:_ResetRollState()

    -- Broadcast session start so members get roll options / counts
    self.sessionSettings = {
        lootThreshold      = ns.db.profile.lootThreshold,
        rollTimer          = ns.db.profile.rollTimer,
        autoPassBOE        = ns.db.profile.autoPassBOE,
        announceChannel    = ns.db.profile.announceChannel,
        tokensCountAsLoot  = ns.db.profile.tokensCountAsLoot  == true,
        recipesCountAsLoot = ns.db.profile.recipesCountAsLoot == true,
    }
    ns.Comm:BroadcastSessionStart(self.sessionSettings, self.rollOptions)

    ns.ChatPrint("Debug", "|cff00ccff[OLL]|r Test loot started. No data will be saved.")

    -- Inject 5 random fake items (0 fake players = only real players roll)
    local items    = ns.DebugWindow:PickRandomItems(5)
    local bossName = "Test Loot " .. date("%H:%M:%S")
    self:InjectDebugLoot(items, bossName, 0)
end

------------------------------------------------------------------------
-- TEST LOOT: Automatically called when all items resolve in test mode.
------------------------------------------------------------------------
function Session:_EndTestLoot()
    self._testLootMode       = false
    self.debugMode           = false
    self._debugFakePlayers   = {}
    self._debugFakePlayerSet = {}
    ns.LootCount:EndDebug()
    self.sessionLootCountEnabled      = nil
    self.sessionLootCountLockedToMain = nil

    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    if self._tickBroadcastHandle then
        ns.addon:CancelTimer(self._tickBroadcastHandle)
        self._tickBroadcastHandle = nil
    end
    self._rollTimerStart    = nil
    self._rollTimerDuration = nil
    self.sessionSettings    = nil

    self.state = self.STATE_IDLE

    -- Tell group the session ended
    ns.Comm:Send(ns.Comm.MSG.SESSION_END, {})

    ns.ChatPrint("Debug", "|cff00ccff[OLL]|r Test loot complete. No data was saved.")

    -- Hide UI
    if ns.RollFrame then ns.RollFrame:Hide() end
    if ns.LeaderFrame then ns.LeaderFrame:Reset() end
    if ns.LeaderFrame and ns.LeaderFrame._reassignPopup then
        ns.LeaderFrame._reassignPopup:Hide()
    end

    -- Restore prior session if one was saved
    if self._savedState then
        local s               = self._savedState
        self.state            = s.state
        self.leaderName       = s.leaderName
        self.rollOptions      = s.rollOptions
        self.currentItems     = s.currentItems
        self.currentBoss      = s.currentBoss
        self.currentItemIdx   = s.currentItemIdx
        self.responses        = s.responses
        self.results          = s.results
        self.bossHistory      = s.bossHistory
        self.bossHistoryOrder = s.bossHistoryOrder or {}
        self.tradeQueue       = s.tradeQueue
        self.sessionSettings  = s.sessionSettings
        self._savedState      = nil

        ns.ChatPrint("Normal", "Previous session restored.")
        self:_SchedulePersist()
        if ns.LeaderFrame then ns.LeaderFrame:Show() end
    end
end

------------------------------------------------------------------------
-- DEBUG MODE: Inject fake loot into the session
------------------------------------------------------------------------
function Session:InjectDebugLoot(items, bossName, fakePlayerCount)
    if not self.debugMode then return end
    if self.state ~= self.STATE_ACTIVE then return end

    self.currentItems = items
    self.currentBoss = bossName or "Test Boss"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}

    -- Generate fake player roster for this loot drop
    self:_SetupFakePlayers(fakePlayerCount or 0)

    -- Broadcast loot table to group
    local serializableItems = {}
    for _, item in ipairs(items) do
        tinsert(serializableItems, {
            icon    = item.icon,
            name    = item.name,
            link    = item.link,
            quality = item.quality,
            kind    = item.kind,
        })
    end

    -- Snapshot real group members (fake players tracked separately)
    self._rollEligiblePlayers = self:_SnapshotGroupMembers()

    ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE, {
        items    = serializableItems,
        bossName = bossName,
    })

    -- Show leader frame for the leader
    if ns.LeaderFrame then ns.LeaderFrame:Show() end

    -- Start rolling on all items at once
    self:StartAllRolls()

    -- Fake player 1 responds immediately for every item
    if #self._debugFakePlayers >= 1 then
        local fp1 = self._debugFakePlayers[1]
        for itemIdx = 1, #items do
            self:_SubmitFakePlayerResponse(fp1, itemIdx)
        end
    end
end

------------------------------------------------------------------------
-- Register GROUP_ROSTER_UPDATE to detect session leader disconnect
------------------------------------------------------------------------
local _sessionInitFrame = CreateFrame("Frame")
_sessionInitFrame:RegisterEvent("PLAYER_LOGIN")
_sessionInitFrame:RegisterEvent("PLAYER_LOGOUT")
_sessionInitFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        -- Fires before SavedVariables are written, including on /reload
        Session:_PersistActiveSession()
        return
    end
    ns.addon:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        Session:OnGroupRosterUpdate()
    end)
    ns.addon:RegisterEvent("CINEMATIC_START", function()
        Session:OnCinematicStart()
    end)
    ns.addon:RegisterEvent("CINEMATIC_STOP", function()
        Session:OnCinematicStop()
    end)
    ns.addon:RegisterEvent("PLAY_MOVIE", function()
        Session:OnCinematicStart()
    end)
    ns.addon:RegisterEvent("STOP_MOVIE", function()
        Session:OnCinematicStop()
    end)

    -- Give the roster and saved variables a moment to settle, then offer to
    -- restore a session this character was leading when it was interrupted,
    -- or ask the group for the running session we dropped out of.
    C_Timer.After(3, function()
        Session:_CheckInterruptedSession()
        Session:_RequestSessionState()
    end)
end)
