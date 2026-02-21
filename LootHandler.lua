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

------------------------------------------------------------------------
-- Hook group loot roll frames to auto-need/greed/pass
------------------------------------------------------------------------
function LootHandler:HookGroupLootRolls()
    -- Hook into START_LOOT_ROLL to auto-handle group loot rolls
    ns.addon:RegisterEvent("START_LOOT_ROLL", function(_, rollID, rollTime)
        self:OnStartLootRoll(rollID, rollTime)
    end)
end

------------------------------------------------------------------------
-- Auto-roll on group loot roll frames
------------------------------------------------------------------------
function LootHandler:OnStartLootRoll(rollID, rollTime)
    if not ns.Session or not ns.Session:IsActive() then return end

    local texture, name, count, quality, bop, canNeed, canGreed, canDisenchant,
    reasonNeed, reasonGreed, reasonDisenchant, deSkillRequired, canTransmog =
        GetLootRollItemInfo(rollID)

    if ns.IsLeader() then
        -- Leader: Need if possible, else Greed
        if canNeed then
            RollOnLoot(rollID, 1) -- 1 = Need
        elseif canGreed then
            RollOnLoot(rollID, 2) -- 2 = Greed
        else
            RollOnLoot(rollID, 0) -- 0 = Pass
        end
    else
        -- Members: always pass
        RollOnLoot(rollID, 0) -- 0 = Pass
    end
end

------------------------------------------------------------------------
-- Trade window: auto-place won items
------------------------------------------------------------------------
function LootHandler:OnTradeShow()
    if not ns.Session or not ns.Session:IsActive() then return end
    if not ns.IsLeader() then return end

    local tradeName = UnitName("NPC") or GetUnitName("NPC", true)
    if not tradeName then return end

    -- Check if this person has items to receive
    local tradeQueue = ns.Session:GetTradeQueue()
    if not tradeQueue then return end

    for _, entry in ipairs(tradeQueue) do
        -- Match by name (might need realm handling)
        local entryShortName = entry.winner:match("^(.-)%-") or entry.winner
        if entryShortName == tradeName or entry.winner == tradeName then
            -- Try to find the item in bags and place it
            self:PlaceItemInTrade(entry.itemLink)
            break -- one item at a time
        end
    end
end

------------------------------------------------------------------------
-- Find item in bags and place in trade window
------------------------------------------------------------------------
function LootHandler:PlaceItemInTrade(itemLink)
    if not itemLink then return end

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink == itemLink then
                -- Pick up and place in trade
                C_Container.UseContainerItem(bag, slot)
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
