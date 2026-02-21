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
Session.state            = Session.STATE_IDLE
Session.leaderName       = nil
Session.rollOptions      = nil -- synced from leader

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

-- Roll timer handle
Session._timerHandle     = nil

-- Debug mode
Session.debugMode        = false
Session._savedState      = nil -- saved session state before debug

------------------------------------------------------------------------
-- Is the session active?
------------------------------------------------------------------------
function Session:IsActive()
    return self.state ~= self.STATE_IDLE
end

------------------------------------------------------------------------
-- START SESSION (Leader only)
------------------------------------------------------------------------
function Session:StartSession()
    if not ns.IsLeader() then
        ns.addon:Print("Only the group leader can start a loot session.")
        return
    end

    if self:IsActive() then
        ns.addon:Print("A session is already active.")
        return
    end

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
    self.rollOptions = ns.Settings:GetRollOptions()

    -- Broadcast to group
    ns.Comm:BroadcastSessionStart(
        {
            lootThreshold   = ns.db.profile.lootThreshold,
            rollTimer       = ns.db.profile.rollTimer,
            autoPassBOE     = ns.db.profile.autoPassBOE,
            announceChannel = ns.db.profile.announceChannel,
        },
        self.rollOptions
    )

    -- Sync counts, links, history
    ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })
    ns.Comm:Send(ns.Comm.MSG.LINKS_SYNC, { links = ns.PlayerLinks:GetLinksTable() })

    ns.addon:Print("Loot session started.")

    -- Show leader frame
    if ns.LeaderFrame then
        ns.LeaderFrame:Show()
    end
end

------------------------------------------------------------------------
-- END SESSION (Leader only)
------------------------------------------------------------------------
function Session:EndSession()
    if not ns.IsLeader() and self.leaderName ~= ns.GetPlayerNameRealm() then
        ns.addon:Print("Only the session leader can end the session.")
        return
    end

    -- Cancel any active timer
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end

    self.state = self.STATE_IDLE

    -- Broadcast end
    ns.Comm:Send(ns.Comm.MSG.SESSION_END, {})

    ns.addon:Print("Loot session ended.")

    -- Hide frames
    if ns.LeaderFrame then ns.LeaderFrame:Hide() end
    if ns.RollFrame then ns.RollFrame:Hide() end
end

------------------------------------------------------------------------
-- ON SESSION START RECEIVED (Members)
------------------------------------------------------------------------
function Session:OnSessionStartReceived(payload, sender)
    self.state = self.STATE_ACTIVE
    self.leaderName = payload.leaderName or sender
    self.rollOptions = payload.rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self.currentItems = {}
    self.responses = {}
    self.results = {}
    self.bossHistory = {}
    self.bossHistoryOrder = {}
    self.tradeQueue = {}

    -- Apply synced settings
    if payload.settings then
        -- Store session settings locally (don't overwrite profile)
        self.sessionSettings = payload.settings
    end
    if payload.counts then
        ns.LootCount:SetCountsTable(payload.counts)
    end
    if payload.links then
        ns.PlayerLinks:SetLinksTable(payload.links)
    end

    ns.addon:Print("Loot session started by " .. self.leaderName .. ".")
end

------------------------------------------------------------------------
-- ON SESSION END RECEIVED
------------------------------------------------------------------------
function Session:OnSessionEndReceived(payload, sender)
    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end

    self.state = self.STATE_IDLE
    ns.addon:Print("Loot session ended by leader.")

    if ns.RollFrame then ns.RollFrame:Hide() end
end

------------------------------------------------------------------------
-- ON ITEMS CAPTURED (Leader – from LootHandler)
------------------------------------------------------------------------
function Session:OnItemsCaptured(items, bossName)
    if self.state ~= self.STATE_ACTIVE then return end

    self.currentItems = items
    self.currentBoss = bossName or "Unknown"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}

    -- Broadcast loot table
    -- Strip functions / metatables for serialization
    local serializableItems = {}
    for _, item in ipairs(items) do
        tinsert(serializableItems, {
            icon    = item.icon,
            name    = item.name,
            link    = item.link,
            quality = item.quality,
        })
    end

    ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE, {
        items    = serializableItems,
        bossName = bossName,
    })

    -- Start rolling on all items at once
    self:StartAllRolls()
end

------------------------------------------------------------------------
-- ON LOOT TABLE RECEIVED (Members)
------------------------------------------------------------------------
function Session:OnLootTableReceived(payload, sender)
    if not ns.NamesMatch(sender, self.leaderName) then return end

    self.currentItems = payload.items or {}
    self.currentBoss = payload.bossName or "Unknown"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}

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
        ns.addon:Print("No items to roll on.")
        return
    end

    self.state = self.STATE_ROLLING

    -- Initialize responses for all items
    for idx = 1, #self.currentItems do
        self.responses[idx] = {}
    end

    -- Show roll frame with ALL items at once
    if ns.RollFrame then
        ns.RollFrame:ShowAllItems(self.currentItems, self.rollOptions)
    end

    -- Start single shared timer
    local duration = ns.db.profile.rollTimer or 30
    if self.sessionSettings then
        duration = self.sessionSettings.rollTimer or duration
    end

    self._rollTimerStart    = GetTime()
    self._rollTimerDuration = duration

    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
    end
    self._timerHandle = ns.addon:ScheduleTimer(function()
        self:OnTimerExpired()
    end, duration)

    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- Player submits a roll response
------------------------------------------------------------------------
function Session:SubmitResponse(itemIdx, choice)
    local playerName = ns.GetPlayerNameRealm()

    if ns.IsLeader() or self.leaderName == ns.GetPlayerNameRealm() then
        -- Leader's own response: handle locally
        self:OnRollResponseReceived({
            itemIdx = itemIdx,
            choice  = choice,
            player  = playerName,
        }, playerName)
    else
        -- Send to leader
        ns.Comm:Send(ns.Comm.MSG.ROLL_RESPONSE, {
            itemIdx = itemIdx,
            choice  = choice,
            player  = playerName,
        })
    end
end

------------------------------------------------------------------------
-- ON ROLL RESPONSE RECEIVED (Leader)
------------------------------------------------------------------------
function Session:OnRollResponseReceived(payload, sender)
    if self.state ~= self.STATE_ROLLING then return end

    local itemIdx = payload.itemIdx
    local choice  = payload.choice
    local player  = payload.player or sender

    if not self.responses[itemIdx] then
        self.responses[itemIdx] = {}
    end

    self.responses[itemIdx][player] = {
        choice = choice,
    }

    -- Update leader frame
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end

    -- Check if all items have all responses → resolve all at once
    if ns.IsLeader() and self:AllItemsAllResponded() then
        self:ResolveAllItems()
    end
end

------------------------------------------------------------------------
-- Check if all group members responded for a single item
------------------------------------------------------------------------
function Session:AllResponded(itemIdx)
    local responses = self.responses[itemIdx] or {}
    local groupSize = GetNumGroupMembers()
    if groupSize == 0 then groupSize = 1 end -- solo

    local count = 0
    for _ in pairs(responses) do count = count + 1 end

    return count >= groupSize
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
-- Timer expired – resolve ALL unresolved items
------------------------------------------------------------------------
function Session:OnTimerExpired()
    if self.state ~= self.STATE_ROLLING then return end
    self:ResolveAllItems()
end

------------------------------------------------------------------------
-- Resolve all items at once
------------------------------------------------------------------------
function Session:ResolveAllItems()
    if not ns.IsLeader() then return end

    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end
    self._rollTimerStart    = nil
    self._rollTimerDuration = nil

    for idx = 1, #self.currentItems do
        if not self.results[idx] then
            self:ResolveItem(idx)
        end
    end

    -- All items done – save boss history
    self:_SaveBossHistory()
    self.state = self.STATE_ACTIVE
    ns.addon:Print("All rolls complete for " .. self.currentBoss .. ".")
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- RESOLVE a single item roll
------------------------------------------------------------------------
function Session:ResolveItem(itemIdx)
    if not ns.IsLeader() then return end

    self.state = self.STATE_RESOLVING

    if self._timerHandle then
        ns.addon:CancelTimer(self._timerHandle)
        self._timerHandle = nil
    end

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

    local winner, winnerRoll, winnerChoice, winnerOpt
    if #rankedCandidates > 0 then
        local w = rankedCandidates[1]
        winner = w.player
        winnerRoll = w.roll
        winnerChoice = w.choice
        winnerOpt = w.option
    end

    -- Store result
    if winner then
        -- Increment loot count if this option counts (skip in debug)
        local newCount = ns.LootCount:GetCount(winner)
        if not self.debugMode and winnerOpt and winnerOpt.countsForLoot then
            newCount = ns.LootCount:IncrementCount(winner)
        end

        self.results[itemIdx] = {
            winner           = winner,
            roll             = winnerRoll,
            choice           = winnerChoice,
            newCount         = newCount,
            rankedCandidates = rankedCandidates,
        }

        local item = self.currentItems[itemIdx]

        if not self.debugMode then
            -- Add to trade queue (skip in debug)
            if item then
                tinsert(self.tradeQueue, {
                    winner   = winner,
                    itemLink = item.link,
                    itemName = item.name,
                    itemIcon = item.icon,
                    awarded  = false,
                })
            end

            -- Add to history (skip in debug)
            ns.LootHistory:AddEntry({
                itemLink       = item and item.link or "Unknown",
                itemId         = item and item.id or 0,
                player         = winner,
                lootCountAtWin = newCount - (winnerOpt and winnerOpt.countsForLoot and 1 or 0),
                bossName       = self.currentBoss,
                rollType       = winnerChoice,
                rollValue      = winnerRoll,
            })

            -- Sync updated counts
            ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })
        end

        -- Broadcast result
        ns.Comm:BroadcastRollResult(itemIdx, winner, winnerRoll, winnerChoice, newCount)

        -- Announce
        self:AnnounceWinner(itemIdx)
    else
        self.results[itemIdx] = {
            winner = nil,
            roll   = 0,
            choice = "No rolls",
        }
        ns.addon:Print("No one rolled on item " .. itemIdx .. ". Skipping.")
    end

    -- Update UI
    if ns.RollFrame then ns.RollFrame:ShowResult(itemIdx, self.results[itemIdx]) end
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
end

------------------------------------------------------------------------
-- Rank all candidates within a single tier (returns full ordered list).
-- Ordering: loot count ASC → random roll DESC (ties re-rolled).
------------------------------------------------------------------------
function Session:_RankInTier(candidates)
    -- Assign loot counts
    for _, c in ipairs(candidates) do
        c.count = ns.LootCount:GetCount(c.player)
    end

    -- Assign random rolls to everyone
    for _, c in ipairs(candidates) do
        c.roll = math.random(1, 100)
    end

    -- Sort: loot count ASC first, then roll DESC
    table.sort(candidates, function(a, b)
        if a.count ~= b.count then
            return a.count < b.count
        end
        return a.roll > b.roll
    end)

    -- Break ties (same count AND same roll) by re-rolling tied groups
    local i = 1
    while i < #candidates do
        local j = i
        while j < #candidates
            and candidates[j + 1].count == candidates[i].count
            and candidates[j + 1].roll == candidates[i].roll do
            j = j + 1
        end
        if j > i then
            -- Re-roll this tied group until unique
            local attempts = 0
            repeat
                for k = i, j do
                    candidates[k].roll = math.random(1, 100)
                end
                table.sort(candidates, function(a, b)
                    if a.count ~= b.count then return a.count < b.count end
                    return a.roll > b.roll
                end)
                attempts = attempts + 1
            until candidates[i].roll ~= candidates[i + 1].roll or attempts > 20
        end
        i = j + 1
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
-- Announce winner in chat
------------------------------------------------------------------------
function Session:AnnounceWinner(itemIdx)
    local result = self.results[itemIdx]
    if not result or not result.winner then return end

    local item = self.currentItems[itemIdx]
    local itemLink = item and item.link or "Unknown Item"

    local prefix = self.debugMode and "[OLL DEBUG] " or "[OLL] "
    local channel = ns.db.profile.announceChannel or "RAID"
    local msg = string.format("%s won by %s (%s roll: %d, Loot Count: %d)",
        itemLink, result.winner, result.choice, result.roll, result.newCount or 0)

    -- In debug mode or not in group, just print locally
    if self.debugMode or not (IsInRaid() or IsInGroup()) then
        ns.addon:Print(prefix .. msg)
    else
        SendChatMessage(prefix .. msg, channel)
    end
end

------------------------------------------------------------------------
-- Save current boss data to session history (for dropdown)
------------------------------------------------------------------------
function Session:_SaveBossHistory()
    local key = self.currentBoss
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
function Session:ReassignItem(itemIdx, newWinner)
    if not ns.IsLeader() then return end

    local result = self.results[itemIdx]
    if not result or not result.winner then
        ns.addon:Print("No winner to reassign from for item " .. itemIdx .. ".")
        return
    end

    local oldWinner = result.winner
    if oldWinner == newWinner then
        ns.addon:Print("New winner is the same as current winner.")
        return
    end

    local item = self.currentItems[itemIdx]
    local opt = self:_FindRollOption(result.choice)
    local countsForLoot = opt and opt.countsForLoot or false

    -- Adjust loot counts
    if countsForLoot then
        -- Decrement old winner
        local oldCount = ns.LootCount:GetCount(oldWinner)
        ns.LootCount:SetCount(oldWinner, math.max(0, oldCount - 1))

        -- Increment new winner
        ns.LootCount:IncrementCount(newWinner)
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
            e.lootCountAtWin = countsForLoot and (newCount - 1) or newCount
            break
        end
    end

    -- Broadcast updated result to group
    ns.Comm:BroadcastRollResult(itemIdx, newWinner, result.roll, result.choice, newCount)

    -- Sync counts
    ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })

    -- Announce reassignment
    local itemLink = item and item.link or "Unknown Item"
    local channel = ns.db.profile.announceChannel or "RAID"
    local msg = string.format("%s reassigned: %s → %s (Loot Count: %d)",
        itemLink, oldWinner, newWinner, newCount)

    if IsInRaid() or IsInGroup() then
        SendChatMessage("[OLL] " .. msg, channel)
    else
        ns.addon:Print(msg)
    end

    ns.addon:Print("Reassigned " .. (item and item.link or "item") .. " from " .. oldWinner .. " to " .. newWinner)

    -- Refresh UI
    if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
    if ns.RollFrame then ns.RollFrame:ShowResult(itemIdx, self.results[itemIdx]) end
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
    if not ns.NamesMatch(sender, self.leaderName) then return end

    local itemIdx = payload.itemIdx
    self.results[itemIdx] = {
        winner   = payload.winner,
        roll     = payload.roll,
        choice   = payload.choice,
        newCount = payload.newCount,
    }

    if ns.RollFrame then ns.RollFrame:ShowResult(itemIdx, self.results[itemIdx]) end
end

------------------------------------------------------------------------
-- DEBUG MODE: Start debug session
------------------------------------------------------------------------
function Session:StartDebugSession()
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
        }
        -- Silently end the current session
        if self._timerHandle then
            ns.addon:CancelTimer(self._timerHandle)
            self._timerHandle = nil
        end
        self.state = self.STATE_IDLE
    end

    -- Start fresh debug session
    self.debugMode = true
    self.state = self.STATE_ACTIVE
    self.leaderName = ns.GetPlayerNameRealm()
    self.currentItems = {}
    self.currentBoss = "Debug Boss"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}
    self.bossHistory = {}
    self.tradeQueue = {}
    self.rollOptions = ns.Settings:GetRollOptions()

    -- Broadcast debug session start to group
    ns.Comm:BroadcastSessionStart(
        {
            lootThreshold   = ns.db.profile.lootThreshold,
            rollTimer       = ns.db.profile.rollTimer,
            autoPassBOE     = ns.db.profile.autoPassBOE,
            announceChannel = ns.db.profile.announceChannel,
        },
        self.rollOptions
    )

    ns.addon:Print("|cffff4444[DEBUG]|r Debug session started. Loot counts and history will not be affected.")

    if ns.LeaderFrame then ns.LeaderFrame:Show() end
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

    self.debugMode = false
    self.state = self.STATE_IDLE

    -- Broadcast end
    ns.Comm:Send(ns.Comm.MSG.SESSION_END, {})

    ns.addon:Print("|cffff4444[DEBUG]|r Debug session ended. No data was saved.")

    -- Hide frames
    if ns.LeaderFrame then ns.LeaderFrame:Reset() end
    if ns.RollFrame then ns.RollFrame:Reset() end

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
        self._savedState      = nil

        ns.addon:Print("Previous session restored.")
        if ns.LeaderFrame then ns.LeaderFrame:Show() end
    end
end

------------------------------------------------------------------------
-- DEBUG MODE: Inject fake loot into the session
------------------------------------------------------------------------
function Session:InjectDebugLoot(items, bossName)
    if not self.debugMode then return end
    if self.state ~= self.STATE_ACTIVE then return end

    self.currentItems = items
    self.currentBoss = bossName or "Test Boss"
    self.currentItemIdx = 0
    self.responses = {}
    self.results = {}

    -- Broadcast loot table to group
    local serializableItems = {}
    for _, item in ipairs(items) do
        tinsert(serializableItems, {
            icon    = item.icon,
            name    = item.name,
            link    = item.link,
            quality = item.quality,
        })
    end

    ns.Comm:Send(ns.Comm.MSG.LOOT_TABLE, {
        items    = serializableItems,
        bossName = bossName,
    })

    -- Start rolling on all items at once
    self:StartAllRolls()
end
