------------------------------------------------------------------------
-- OrderedLootList  –  Core.lua
-- Addon bootstrap: AceAddon creation, shared namespace, AceDB, slash cmds
------------------------------------------------------------------------

---@class OrderedLootList : AceAddon-3.0, AceConsole-3.0, AceEvent-3.0, AceComm-3.0, AceSerializer-3.0, AceTimer-3.0, AceHook-3.0

local ADDON_NAME        = "OrderedLootList"
local OrderedLootList   = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceConsole-3.0",
    "AceEvent-3.0",
    "AceComm-3.0",
    "AceSerializer-3.0",
    "AceTimer-3.0",
    "AceHook-3.0"
)

-- Shared namespace accessible by all modules -------------------------
local ns                = {}
ns.addon                = OrderedLootList
ns.ADDON_NAME           = ADDON_NAME
ns.COMM_PREFIX          = "OLL"
ns.VERSION              = "0.1"

-- Make the namespace available through the addon object
OrderedLootList.ns      = ns

-- LibStub references --------------------------------------------------
ns.AConfig              = LibStub("AceConfig-3.0")
ns.ACDiag               = LibStub("AceConfigDialog-3.0")
ns.AGUI                 = LibStub("AceGUI-3.0")

-- Default roll options ------------------------------------------------
ns.DEFAULT_ROLL_OPTIONS = {
    {
        name = "Need",
        priority = 1,
        countsForLoot = true,
        colorR = 0.0,
        colorG = 0.8,
        colorB = 0.0, -- green
    },
    {
        name = "Greed",
        priority = 2,
        countsForLoot = true,
        colorR = 1.0,
        colorG = 0.82,
        colorB = 0.0, -- yellow
    },
    -- Pass is handled specially (always present, not a "roll")
}

------------------------------------------------------------------------
-- Saved Variables defaults
------------------------------------------------------------------------
local defaults          = {
    profile = {
        -- General settings
        lootThreshold   = 3, -- Rare
        rollTimer       = 30,
        autoPassBOE     = true,
        announceChannel = "RAID",
        rollOptions     = nil, -- nil ⇒ use DEFAULT_ROLL_OPTIONS

        -- Minimap button
        minimap         = {
            hide = false,
        },

        -- Saved window positions: { ["frameName"] = { point, x, y } }
        framePositions  = {},
    },
    global = {
        -- Loot counts: { ["Name-Realm"] = count }
        lootCounts         = {},
        lastResetTimestamp = 0,

        -- Player links: { ["Main-Realm"] = { "Alt1-Realm", … } }
        playerLinks        = {},

        -- Loot history: array of entry tables
        lootHistory        = {},
    },
}

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
function OrderedLootList:OnInitialize()
    -- Database
    self.db = LibStub("AceDB-3.0"):New("OrderedLootListDB", defaults, true)
    ns.db = self.db

    -- Register comm prefix
    self:RegisterComm(ns.COMM_PREFIX)

    -- Slash commands
    self:RegisterChatCommand("oll", "SlashHandler")

    -- Register settings panel (after db is ready)
    if ns.Settings then
        ns.Settings:Register()
    end

    self:Print(ADDON_NAME .. " v" .. ns.VERSION .. " loaded.  /oll for help.")
end

function OrderedLootList:OnEnable()
    -- Check weekly loot count reset
    if ns.LootCount then
        ns.LootCount:CheckWeeklyReset()
    end
end

function OrderedLootList:OnDisable()
    -- Cleanup if needed
end

------------------------------------------------------------------------
-- Slash command router
------------------------------------------------------------------------
function OrderedLootList:SlashHandler(input)
    input = (input or ""):trim():lower()

    if input == "start" then
        if ns.Session then ns.Session:StartSession() end
    elseif input == "stop" then
        if ns.Session then ns.Session:EndSession() end
    elseif input == "config" or input == "settings" or input == "options" then
        if ns.Settings then ns.Settings:OpenConfig() end
    elseif input == "history" then
        if ns.HistoryFrame then ns.HistoryFrame:Toggle() end
    elseif input == "links" then
        if ns.Settings then ns.Settings:OpenConfig("playerLinks") end
    else
        self:Print("Usage:")
        self:Print("  /oll start   – Start a loot session (leader)")
        self:Print("  /oll stop    – End the current loot session")
        self:Print("  /oll config  – Open settings")
        self:Print("  /oll history – Open loot history")
        self:Print("  /oll links   – Manage character links")
    end
end

------------------------------------------------------------------------
-- AceComm incoming message router
------------------------------------------------------------------------
function OrderedLootList:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= ns.COMM_PREFIX then return end
    if ns.Comm then
        ns.Comm:OnMessageReceived(message, distribution, sender)
    end
end

------------------------------------------------------------------------
-- Helper: get current player name with realm
------------------------------------------------------------------------
function ns.GetPlayerNameRealm()
    local name, realm = UnitFullName("player")
    realm = realm or GetNormalizedRealmName() or ""
    if realm == "" then
        realm = GetNormalizedRealmName() or ""
    end
    return name .. "-" .. realm
end

------------------------------------------------------------------------
-- Helper: is the player the group/raid leader?
------------------------------------------------------------------------
function ns.IsLeader()
    if IsInRaid() then
        return UnitIsGroupLeader("player")
    elseif IsInGroup() then
        return UnitIsGroupLeader("player")
    end
    return true -- solo = leader
end

------------------------------------------------------------------------
-- Helper: get communication channel
------------------------------------------------------------------------
function ns.GetCommChannel()
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return "WHISPER" -- fallback (solo testing – whisper self)
end

------------------------------------------------------------------------
-- Helper: compare two player names, ignoring realm suffix differences.
-- AceComm sender may be "Name" (same realm) while stored names are
-- always "Name-Realm".  This strips the realm from both before comparing.
------------------------------------------------------------------------
function ns.NamesMatch(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local nameA = a:match("^(.-)%-") or a
    local nameB = b:match("^(.-)%-") or b
    return nameA == nameB
end

------------------------------------------------------------------------
-- Helper: bring a frame and ALL its children above other addon windows.
-- Uses a shared counter so each focus click assigns a higher base level.
-- The gap (100) ensures child frames don't interleave with other windows.
------------------------------------------------------------------------
local _topFrameLevel = 100

local function SetFrameLevelRecursive(frame, baseLevel)
    frame:SetFrameLevel(baseLevel)
    local children = { frame:GetChildren() }
    for _, child in ipairs(children) do
        SetFrameLevelRecursive(child, baseLevel + 1)
    end
end

function ns.RaiseFrame(frame)
    _topFrameLevel = _topFrameLevel + 100
    SetFrameLevelRecursive(frame, _topFrameLevel)
end

------------------------------------------------------------------------
-- Helper: save a frame's position to the DB
------------------------------------------------------------------------
function ns.SaveFramePosition(key, frame)
    if not ns.db or not frame then return end
    local point, _, _, x, y = frame:GetPoint()
    if not ns.db.profile.framePositions then
        ns.db.profile.framePositions = {}
    end
    ns.db.profile.framePositions[key] = { point = point, x = x, y = y }
end

------------------------------------------------------------------------
-- Helper: restore a frame's position from the DB
------------------------------------------------------------------------
function ns.RestoreFramePosition(key, frame)
    if not ns.db or not frame then return end
    local pos = ns.db.profile.framePositions and ns.db.profile.framePositions[key]
    if pos and pos.point then
        frame:ClearAllPoints()
        frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
    end
end

------------------------------------------------------------------------
-- Expose globals for other modules
------------------------------------------------------------------------
_G.OrderedLootList = OrderedLootList
_G.OLL_NS = ns
