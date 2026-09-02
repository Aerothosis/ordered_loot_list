------------------------------------------------------------------------
-- OrderedLootList  –  LootHandler.lua
-- Hooks LOOT_READY / LOOT_OPENED to intercept the loot window.
-- Leader: auto-Need (or Greed) gear, capture items.
-- Members: auto-pass everything.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local LootHandler = {}
ns.LootHandler = LootHandler

-- Item classes that are "gear"  (equipment & weapons)
-- Enum.ItemClass.Armor = 4,  Enum.ItemClass.Weapon = 2
local GEAR_CLASSES = {
    [Enum.ItemClass.Armor]  = true,
    [Enum.ItemClass.Weapon] = true,
}

------------------------------------------------------------------------
-- Register events
------------------------------------------------------------------------
function LootHandler:Init()
    ns.addon:RegisterEvent("LOOT_READY", function(_, autoLoot)
        self:OnLootReady(autoLoot)
    end)

    ns.addon:RegisterEvent("LOOT_OPENED", function(_, autoLoot, isFromItem)
        self:OnLootOpened(autoLoot, isFromItem)
    end)

    -- For auto-placing items in trade window
    ns.addon:RegisterEvent("TRADE_SHOW", function()
        self:OnTradeShow()
    end)

    -- For detecting completed trades (item left bags → mark as awarded)
    ns.addon:RegisterEvent("TRADE_CLOSED", function()
        self:OnTradeClosed()
    end)

    -- Cache target name in a non-secure context to avoid taint in TRADE_SHOW.
    -- GetUnitName() called inside TRADE_SHOW (triggered by secure UI) returns a
    -- "secret" tainted string that cannot be compared with ==.
    ns.addon:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        self._cachedTargetName = GetUnitName("target", true)
    end)
end

------------------------------------------------------------------------
-- LOOT_READY handler
------------------------------------------------------------------------
function LootHandler:OnLootReady(autoLoot)
    if not ns.Session or not ns.Session:IsActive() then return end

    -- Only the loot authority (session loot master, else session leader)
    -- captures items and drives the roll; everyone else, including the raid
    -- leader and assistants, is a plain member here.
    if ns.Session:IsLootAuthority() then
        self:LeaderHandleLoot()
    else
        self:MemberAutoPass()
    end
end

------------------------------------------------------------------------
-- LOOT_OPENED handler (fires after LOOT_READY)
------------------------------------------------------------------------
function LootHandler:OnLootOpened(autoLoot, isFromItem)
    if not ns.Session or not ns.Session:IsActive() then return end

    -- If session is active, close the default loot frame quickly
    -- (we've already handled the loot in LOOT_READY)
    if not ns.Session:IsLootAuthority() then
        CloseLoot()
    end
end

------------------------------------------------------------------------
-- Leader: capture loot info, auto-need/greed gear, broadcast table
------------------------------------------------------------------------
function LootHandler:LeaderHandleLoot()
    local numItems = GetNumLootItems()
    if numItems == 0 then return end

    local capturedItems = {}
    local threshold = ns.db.profile.lootThreshold or 3

    for i = 1, numItems do
        local lootIcon, lootName, lootQuantity, currencyID, lootQuality,
        locked, isQuestItem, questID, isActive = GetLootSlotInfo(i)
        local lootLink = GetLootSlotLink(i)
        -- GetLootSlotLink can return a "secret string" in certain loot contexts,
        -- which AceSerializer cannot serialize. Force to a plain string safely.
        if lootLink then
            local ok, plain = pcall(tostring, lootLink)
            lootLink = ok and plain or nil
        end
        local slotType = GetLootSlotType(i)

        if lootLink and lootQuality and lootQuality >= threshold then
            -- Gear, tier token or recipe goes to the OLL roll; nil (cache
            -- miss) is included rather than silently dropped.
            local kind = self:ClassifyItem(lootLink)

            if kind ~= false then
                tinsert(capturedItems, {
                    index    = i,
                    icon     = lootIcon,
                    name     = lootName,
                    link     = lootLink,
                    quality  = lootQuality,
                    quantity = lootQuantity,
                    kind     = kind or "gear",
                })
            end
        end

        -- Loot everything (leader takes all)
        -- For group loot, the leader will roll need/greed via
        -- the confirmation dialogs that fire
        LootSlot(i)
    end

    -- Store captured items for the session.  The boss name / GUIDs come from
    -- ENCOUNTER_START and are consumed here so that later trash or chest loot
    -- is not tagged with a stale boss (which would make members fail the
    -- CanLootUnit eligibility check and be auto-passed).
    if #capturedItems > 0 and ns.Session then
        local bossName, bossGUIDs = self:_ConsumeEncounterContext()
        ns.Session:OnItemsCaptured(capturedItems, bossName, bossGUIDs)
    end
end

------------------------------------------------------------------------
-- Member: auto-pass everything and close loot
------------------------------------------------------------------------
function LootHandler:MemberAutoPass()
    local numItems = GetNumLootItems()
    for i = 1, numItems do
        -- In group loot, passing is done through the roll frames
        -- We close the loot window; the actual group loot roll frames
        -- will be handled by ConfirmLootRoll hooks
        LootSlot(i)
    end
    CloseLoot()
end

-- Miscellaneous sub-classes that hold tier / catalyst tokens.  Mounts,
-- companion pets, holiday items and reagents are excluded on purpose; the
-- loot master handles those manually.
local TOKEN_MISC_SUBCLASSES = {
    [Enum.ItemMiscellaneousSubclass and Enum.ItemMiscellaneousSubclass.Junk  or 0] = true,
    [Enum.ItemMiscellaneousSubclass and Enum.ItemMiscellaneousSubclass.Other or 4] = true,
}

------------------------------------------------------------------------
-- Classify an item link for the OLL roll.
-- Returns "gear"   – equippable weapon / armor
--         "token"  – armor-class item with no equip slot (class-set tokens)
--                    or a Miscellaneous Junk/Other item (catalyst tokens)
--         "recipe" – profession recipe
--         false    – anything else (mounts, pets, consumables, quest items...)
--         nil      – item data not in the client cache yet; callers decide
--                    whether to defer or include the item
------------------------------------------------------------------------
function LootHandler:ClassifyItem(itemLink)
    if not itemLink then return false end

    local _, _, _, _, _, _, _, _, equipLoc, _, _, itemClassID, itemSubClassID =
        C_Item.GetItemInfo(itemLink)

    if itemClassID == nil then return nil end

    if GEAR_CLASSES[itemClassID] then
        if equipLoc and equipLoc ~= "" then
            return "gear"
        end
        -- Armor / weapon class with no equip slot: class-set tokens
        return "token"
    end

    if itemClassID == Enum.ItemClass.Recipe then
        return "recipe"
    end

    if itemClassID == Enum.ItemClass.Miscellaneous and TOKEN_MISC_SUBCLASSES[itemSubClassID] then
        return "token"
    end

    return false
end

-- Backwards-compatible boolean form of ClassifyItem.
function LootHandler:IsGearItem(itemLink)
    local kind = self:ClassifyItem(itemLink)
    if kind == nil then return nil end
    return kind ~= false
end

-- State for tracking in-flight WoW group loot rolls so we can trigger the
-- OLL roll frame once all WoW rolls have concluded.
LootHandler._pendingRolls      = {}  -- { [rollID] = true }
LootHandler._capturedRollItems = {}  -- { [rollID] = item-table }
LootHandler._rollBossName      = "Unknown"

-- Encounter context: set at ENCOUNTER_START (or recovered at login while an
-- encounter is in progress), consumed by the first loot capture after the
-- kill, and cleared on a wipe.  Only GUIDs from this context are ever sent as
-- bossGUIDs; loot with no context (trash, chests, reload after the kill)
-- carries none, so members skip the eligibility check for it.
LootHandler._encounterBossGUIDs = {}
LootHandler._encounterBossName  = "Unknown"

------------------------------------------------------------------------
-- Return the current encounter boss name and GUID list, then clear them.
------------------------------------------------------------------------
function LootHandler:_ConsumeEncounterContext()
    local name  = self._encounterBossName
    local guids = self._encounterBossGUIDs
    self._encounterBossName  = "Unknown"
    self._encounterBossGUIDs = {}
    return name, guids
end

function LootHandler:_ClearEncounterContext()
    self._encounterBossName  = "Unknown"
    self._encounterBossGUIDs = {}
end

------------------------------------------------------------------------
-- Hook group loot roll frames to auto-need/greed/pass
------------------------------------------------------------------------
function LootHandler:HookGroupLootRolls()
    ns.addon:RegisterEvent("START_LOOT_ROLL", function(_, rollID, rollTime)
        self:OnStartLootRoll(rollID, rollTime)
    end)

    -- Cache boss unit GUIDs when an encounter begins.  boss1-boss5 tokens are
    -- only valid during an active encounter; capturing them here ensures they
    -- are available when START_LOOT_ROLL fires after the fight ends.
    ns.addon:RegisterEvent("ENCOUNTER_START", function(_, encounterID, encounterName)
        self._encounterBossGUIDs = {}
        self._encounterBossName  = encounterName or "Unknown"
        for i = 1, 5 do
            local guid = UnitGUID("boss" .. i)
            if guid then
                tinsert(self._encounterBossGUIDs, guid)
            end
        end
    end)

    -- A wipe leaves no loot; drop the context so the next trash pull is not
    -- tagged with this boss.  On a kill the context stays until consumed by
    -- the loot capture.
    ns.addon:RegisterEvent("ENCOUNTER_END", function(_, _, _, _, _, success)
        if success == 0 then
            self:_ClearEncounterContext()
        end
    end)

    -- No WoW event fires when a roll timer expires, so each roll schedules
    -- its own C_Timer to call OnLootRollStopped after rollTime seconds.
end

------------------------------------------------------------------------
-- Auto-roll on group loot roll frames
------------------------------------------------------------------------
function LootHandler:OnStartLootRoll(rollID, rollTime)
    if not ns.Session or not ns.Session:IsActive() then return end

    local texture, name, count, quality, bop, canNeed, canGreed, canDisenchant,
    reasonNeed, reasonGreed, reasonDisenchant, deSkillRequired, canTransmog =
        GetLootRollItemInfo(rollID)

    -- Only the loot authority (session loot master, else session leader)
    -- auto-needs; everyone else passes.
    local isLootMaster = ns.Session:IsLootAuthority()

    -- Capture gear items for OLL roll (loot master only; they broadcast to members).
    -- If _pendingRolls was empty before this roll we're starting a new encounter —
    -- reset accumulated state and snapshot the boss name.
    if isLootMaster then
        if not next(self._pendingRolls) then
            self._capturedRollItems = {}
            -- Use the encounter name cached at ENCOUNTER_START rather than
            -- UnitName("target"), which is unreliable by the time loot rolls fire.
            self._rollBossName = self._encounterBossName
        end

        local threshold = ns.db and ns.db.profile and ns.db.profile.lootThreshold or 3
        local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
        -- Capture by quality threshold only here; the item cache is frequently
        -- not yet populated when START_LOOT_ROLL fires, so IsGearItem would
        -- return nil/false and silently drop the item.  The gear check is
        -- deferred to OnLootRollStopped where the 3-second delay gives the
        -- cache time to populate.
        if link and quality and quality >= threshold then
            self._capturedRollItems[rollID] = {
                rollID   = rollID,
                icon     = texture,
                name     = name,
                link     = link,
                quality  = quality,
                quantity = count or 1,
            }
        end
    end

    -- Track this roll so OnLootRollStopped knows when all are done.
    -- All players roll immediately (need or pass), so use a short fixed buffer
    -- rather than waiting the full rollTime for the server to resolve the roll.
    self._pendingRolls[rollID] = true
    C_Timer.After(3, function()
        self:OnLootRollStopped(rollID)
    end)

    if isLootMaster then
        -- Loot Master: Need if possible, else Greed, else Disenchant, else Transmog.
        -- If none are available, leave the roll window open for manual handling.
        if canNeed then
            RollOnLoot(rollID, 1) -- 1 = Need
        elseif canGreed then
            RollOnLoot(rollID, 2) -- 2 = Greed
        elseif canDisenchant then
            RollOnLoot(rollID, 3) -- 3 = Disenchant
        elseif canTransmog then
            RollOnLoot(rollID, 4) -- 4 = Transmog
        end
    else
        -- Everyone else (including other leaders): always pass
        RollOnLoot(rollID, 0) -- 0 = Pass
    end
end

------------------------------------------------------------------------
-- Called when a WoW group loot roll concludes.
-- Once all pending rolls are done the loot master triggers the OLL roll.
------------------------------------------------------------------------
function LootHandler:OnLootRollStopped(rollID)
    self._pendingRolls[rollID] = nil

    -- Only the loot authority drives the OLL session; members receive via LOOT_TABLE.
    if not ns.Session or not ns.Session:IsActive() then return end
    if not ns.Session:IsLootAuthority() then return end

    -- Still waiting for other rolls to finish.
    if next(self._pendingRolls) then return end

    -- All WoW rolls are done — build the item list and start the OLL roll.
    -- Classify now; the 3-second delay gives the item cache time to
    -- populate.  ClassifyItem returns nil when data is still not cached —
    -- include those items (as gear) rather than silently dropping them.
    local items = {}
    for _, item in pairs(self._capturedRollItems) do
        local kind = self:ClassifyItem(item.link)
        if kind ~= false then
            item.kind = kind or "gear"
            tinsert(items, item)
        end
    end
    -- Sort by rollID so item.num assignments are deterministic across runs
    table.sort(items, function(a, b) return a.rollID < b.rollID end)
    self._capturedRollItems = {}

    if #items > 0 then
        local _, bossGUIDs = self:_ConsumeEncounterContext()
        ns.Session:OnItemsCaptured(items, self._rollBossName, bossGUIDs)
    end
end

------------------------------------------------------------------------
-- Trade window: auto-place won items
------------------------------------------------------------------------
function LootHandler:OnTradeShow()
    if not ns.Session or not ns.Session:IsActive() then return end
    -- The trade queue lives on the loot authority's client (filled by ResolveItem)
    if not ns.Session:IsLootAuthority() then return end

    -- UnitName("NPC") is for NPC interactions and returns nil for player trades.
    -- Try the stored pending target first (set by the trade queue button), then
    -- fall back to the current target and the trade frame's recipient label.
    local tradeName = self._pendingTradeTarget
    self._pendingTradeTarget = nil  -- consume it

    if not tradeName or tradeName == "" then
        -- Use the name cached in PLAYER_TARGET_CHANGED (non-secure context) to
        -- avoid taint: GetUnitName() called directly here would return a secret
        -- string when TRADE_SHOW fires from a secure UI action (right-click Trade).
        tradeName = self._cachedTargetName
    end
    if not tradeName or tradeName == "" then
        if TradeFrameRecipientNameText then
            tradeName = TradeFrameRecipientNameText:GetText()
        end
    end
    if not tradeName or tradeName == "" then
        self._currentTradeTarget = nil
        return
    end
    self._currentTradeTarget = tradeName  -- remember for OnTradeClosed

    -- Check if this person has items to receive
    local tradeQueue = ns.Session:GetTradeQueue()
    if not tradeQueue then return end

    for _, entry in ipairs(tradeQueue) do
        if not entry.awarded then
            local entryShortName = entry.winner:match("^(.-)%-") or entry.winner
            if entryShortName == tradeName or ns.NamesMatch(entry.winner, tradeName) then
                -- Place all items this player won; the trade frame accepts up to 6 slots
                self:PlaceItemInTrade(entry.itemLink)
            end
        end
    end
end

------------------------------------------------------------------------
-- Find item in bags and place in trade window
------------------------------------------------------------------------
function LootHandler:PlaceItemInTrade(itemLink)
    if not itemLink then return false end

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            -- Bag links differ from loot-window links in context fields, so
            -- compare by item identity rather than raw string.
            if info and ns.ItemLinksMatch(info.hyperlink, itemLink) then
                -- Find the first empty player-side trade slot (1–6)
                local freeSlot
                for i = 1, 6 do
                    local slotName = GetTradePlayerItemInfo(i)
                    if not slotName or slotName == "" then
                        freeSlot = i
                        break
                    end
                end
                if not freeSlot then return false end  -- all 6 trade slots occupied

                -- Pick up the item onto the cursor, then drop it into the trade slot.
                -- UseContainerItem equips gear; PickupContainerItem + ClickTradeButton
                -- is the correct way to route a bag item into the trade frame.
                C_Container.PickupContainerItem(bag, slot)
                ClickTradeButton(freeSlot)
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Trade closed: scan pending entries and mark awarded if item left bags
------------------------------------------------------------------------
function LootHandler:OnTradeClosed()
    if not ns.Session or not ns.Session:IsActive() then return end
    if not ns.Session:IsLootAuthority() then return end

    local tradeQueue = ns.Session:GetTradeQueue()
    if not tradeQueue then return end

    local tradedWith = self._currentTradeTarget
    self._currentTradeTarget = nil

    -- Group un-awarded entries by item identity and compare against how many
    -- copies are still in the bags.  If a player won two copies of the same
    -- item, trading one must mark exactly one entry awarded.
    local pendingByKey = {}
    for _, entry in ipairs(tradeQueue) do
        if not entry.awarded and entry.itemLink then
            local key = ns.GetItemKey(entry.itemLink) or entry.itemLink
            pendingByKey[key] = pendingByKey[key] or { link = entry.itemLink, entries = {} }
            tinsert(pendingByKey[key].entries, entry)
        end
    end

    local changed = false
    for _, group in pairs(pendingByKey) do
        local inBags  = self:_CountItemInBags(group.link)
        local missing = #group.entries - inBags
        if missing > 0 then
            -- Prefer the entries for the player we just traded with
            table.sort(group.entries, function(a, b)
                local am = tradedWith and ns.NamesMatch(a.winner, tradedWith) and 1 or 0
                local bm = tradedWith and ns.NamesMatch(b.winner, tradedWith) and 1 or 0
                return am > bm
            end)
            for i = 1, missing do
                local entry = group.entries[i]
                if entry and (not tradedWith or ns.NamesMatch(entry.winner, tradedWith)) then
                    entry.awarded = true
                    changed = true
                end
            end
        end
    end

    if changed then
        ns.Session:_SchedulePersist()
        if ns.LeaderFrame then
            ns.LeaderFrame:_RefreshTradeQueuePopupIfShown()
            ns.LeaderFrame:Refresh()
        end
    end
end

------------------------------------------------------------------------
-- Count how many copies of an item are in the player's bags
-- (stack sizes included).
------------------------------------------------------------------------
function LootHandler:_CountItemInBags(itemLink)
    if not itemLink then return 0 end
    local count = 0
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and ns.ItemLinksMatch(info.hyperlink, itemLink) then
                count = count + (info.stackCount or 1)
            end
        end
    end
    return count
end

function LootHandler:_IsItemInBags(itemLink)
    return self:_CountItemInBags(itemLink) > 0
end

------------------------------------------------------------------------
-- Init on load
------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    LootHandler:Init()
    LootHandler:HookGroupLootRolls()

    -- If the UI was reloaded during an active encounter, ENCOUNTER_START was
    -- missed and _encounterBossGUIDs is empty.  Recover by capturing boss GUIDs
    -- now while the boss unit tokens are still valid.
    if IsEncounterInProgress() then
        for i = 1, 5 do
            local guid = UnitGUID("boss" .. i)
            if guid then
                tinsert(LootHandler._encounterBossGUIDs, guid)
                if LootHandler._encounterBossName == "Unknown" then
                    LootHandler._encounterBossName = UnitName("boss" .. i) or "Unknown"
                end
            end
        end
    end
end)
