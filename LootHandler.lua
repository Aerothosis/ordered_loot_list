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
end

------------------------------------------------------------------------
-- LOOT_READY handler
------------------------------------------------------------------------
function LootHandler:OnLootReady(autoLoot)
    if not ns.Session or not ns.Session:IsActive() then return end

    local isLeader = ns.IsLeader()

    if isLeader then
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
    if not ns.IsLeader() then
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

    -- Try to detect boss name
    local bossName = "Unknown"
    if UnitExists("target") and UnitIsDead("target") then
        bossName = UnitName("target") or "Unknown"
    end

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
            -- Check if this is actual gear (not toy, mount, pet, cosmetic)
            local isGear = self:IsGearItem(lootLink)

            if isGear then
                tinsert(capturedItems, {
                    index    = i,
                    icon     = lootIcon,
                    name     = lootName,
                    link     = lootLink,
                    quality  = lootQuality,
                    quantity = lootQuantity,
                })
            end
        end

        -- Loot everything (leader takes all)
        -- For group loot, the leader will roll need/greed via
        -- the confirmation dialogs that fire
        LootSlot(i)
    end

    -- Store captured items for the session
    if #capturedItems > 0 and ns.Session then
        ns.Session:OnItemsCaptured(capturedItems, bossName)
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

------------------------------------------------------------------------
-- Check if an item link is actual gear (weapon/armor, not toy/cosmetic)
------------------------------------------------------------------------
function LootHandler:IsGearItem(itemLink)
    if not itemLink then return false end

    local _, _, _, _, _, itemType, itemSubType, _, equipLoc, _, _, itemClassID, itemSubClassID =
        C_Item.GetItemInfo(itemLink)

    -- Must be weapon or armor
    if not GEAR_CLASSES[itemClassID] then
        return false
    end

    -- Filter out cosmetic items (check if equippable)
    if equipLoc == "" or equipLoc == nil then
        return false
    end

    return true
end

-- State for tracking in-flight WoW group loot rolls so we can trigger the
-- OLL roll frame once all WoW rolls have concluded.
LootHandler._pendingRolls      = {}  -- { [rollID] = true }
LootHandler._capturedRollItems = {}  -- { [rollID] = item-table }
LootHandler._rollBossName      = "Unknown"

------------------------------------------------------------------------
-- Hook group loot roll frames to auto-need/greed/pass
------------------------------------------------------------------------
function LootHandler:HookGroupLootRolls()
    -- Hook into START_LOOT_ROLL to auto-handle group loot rolls
    ns.addon:RegisterEvent("START_LOOT_ROLL", function(_, rollID, rollTime)
        self:OnStartLootRoll(rollID, rollTime)
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

    -- Only the designated Loot Master auto-needs; everyone else passes.
    -- If no loot master has been set yet, fall back to the group leader.
    local lootMaster  = ns.Session.sessionLootMaster
    local isLootMaster
    if lootMaster and lootMaster ~= "" then
        isLootMaster = ns.NamesMatch(ns.GetPlayerNameRealm(), lootMaster)
    else
        isLootMaster = ns.IsLeader()
    end

    -- Capture gear items for OLL roll (loot master only; they broadcast to members).
    -- If _pendingRolls was empty before this roll we're starting a new encounter —
    -- reset accumulated state and snapshot the boss name.
    if isLootMaster then
        if not next(self._pendingRolls) then
            self._capturedRollItems = {}
            self._rollBossName = "Unknown"
            if UnitExists("target") and UnitIsDead("target") then
                self._rollBossName = UnitName("target") or "Unknown"
            end
        end

        local threshold = ns.db and ns.db.profile and ns.db.profile.lootThreshold or 3
        local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
        if link and quality and quality >= threshold and self:IsGearItem(link) then
            self._capturedRollItems[rollID] = {
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

    -- Only the loot master drives the OLL session; members receive via LOOT_TABLE.
    if not ns.Session or not ns.Session:IsActive() then return end

    local lootMaster = ns.Session.sessionLootMaster
    local isLootMaster
    if lootMaster and lootMaster ~= "" then
        isLootMaster = ns.NamesMatch(ns.GetPlayerNameRealm(), lootMaster)
    else
        isLootMaster = ns.IsLeader()
    end
    if not isLootMaster then return end

    -- Still waiting for other rolls to finish.
    if next(self._pendingRolls) then return end

    -- All WoW rolls are done — build the item list and start the OLL roll.
    local items = {}
    for _, item in pairs(self._capturedRollItems) do
        tinsert(items, item)
    end
    self._capturedRollItems = {}

    if #items > 0 then
        ns.Session:OnItemsCaptured(items, self._rollBossName)
    end
end

------------------------------------------------------------------------
-- Trade window: auto-place won items
------------------------------------------------------------------------
function LootHandler:OnTradeShow()
    if not ns.Session or not ns.Session:IsActive() then return end
    if not ns.IsLeader() then return end

    -- UnitName("NPC") is for NPC interactions and returns nil for player trades.
    -- Try the stored pending target first (set by the trade queue button), then
    -- fall back to the current target and the trade frame's recipient label.
    local tradeName = self._pendingTradeTarget
    self._pendingTradeTarget = nil  -- consume it

    if not tradeName or tradeName == "" then
        tradeName = GetUnitName("target", true) or UnitName("target")
    end
    if not tradeName or tradeName == "" then
        if TradeFrameRecipientNameText then
            tradeName = TradeFrameRecipientNameText:GetText()
        end
    end
    if not tradeName or tradeName == "" then return end

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
            if info and info.hyperlink == itemLink then
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
    if not ns.IsLeader() then return end

    local tradeQueue = ns.Session:GetTradeQueue()
    if not tradeQueue then return end

    local changed = false
    for _, entry in ipairs(tradeQueue) do
        if not entry.awarded and not self:_IsItemInBags(entry.itemLink) then
            entry.awarded = true
            changed = true
        end
    end

    if changed and ns.LeaderFrame then
        ns.LeaderFrame:_RefreshTradeQueuePopupIfShown()
        ns.LeaderFrame:Refresh()
    end
end

------------------------------------------------------------------------
-- Check whether an item hyperlink exists anywhere in the player's bags
------------------------------------------------------------------------
function LootHandler:_IsItemInBags(itemLink)
    if not itemLink then return false end
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink == itemLink then
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Init on load
------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    LootHandler:Init()
    LootHandler:HookGroupLootRolls()
end)
