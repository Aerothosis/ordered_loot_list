------------------------------------------------------------------------
-- OrderedLootList  –  Core.lua
-- Addon bootstrap: AceAddon creation, shared namespace, AceDB, slash cmds
------------------------------------------------------------------------

---@class OrderedLootList : AceAddon-3.0, AceConsole-3.0, AceEvent-3.0, AceComm-3.0, AceSerializer-3.0, AceTimer-3.0, AceHook-3.0

-- The folder name: "OrderedLootList" for the packaged addon, or whatever
-- the dev checkout is called, so both can be installed side by side.
local ADDON_NAME        = ... or "OrderedLootList"
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
local _tocVersion       = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
ns.VERSION              = (_tocVersion and _tocVersion:sub(1, 1) ~= "@") and _tocVersion or "dev"

-- Make the namespace available through the addon object
OrderedLootList.ns      = ns

-- API aliases: prefer the namespaced 12.0 functions, fall back to the
-- legacy globals where a client still has them.
ns.GetItemInfo           = (C_Item and C_Item.GetItemInfo) or GetItemInfo
ns.GetItemQualityColor   = (C_Item and C_Item.GetItemQualityColor) or GetItemQualityColor
ns.GetSpecialization     = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
ns.GetSpecializationInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
ns.GetLootSpecialization = (C_SpecializationInfo and C_SpecializationInfo.GetLootSpecialization) or GetLootSpecialization

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
        -- Auto-pass features are opt-in; every toggle defaults to off.
        autoPassBOE          = false,
        autoPassOffSpec      = false,
        autoPassUnequippable = false,
        holdWMode            = false,

        -- Bumped when a one-time profile migration is added (see OnInitialize)
        settingsVersion      = 0,
        showStatBadge        = true,
        -- "Pass all" closes the roll window afterwards (all frame sizes)
        closeOnPassAll       = true,
        announceChannel = "RAID",
        disenchanter    = "",  -- Name-Realm of designated disenchanter
        rollOptions     = nil, -- nil ⇒ use DEFAULT_ROLL_OPTIONS

        -- Minimap button
        minimap         = {
            hide = false,
        },

        -- UI theme ("Ledger", "Basic" or "Midnight") – player-local, never synced.
        -- Ledger is the default for new installs; existing profiles keep theirs.
        theme           = "Ledger",

        -- Loot roll frame size: "small" | "medium" | "large"
        lootFrameSize   = "medium",

        -- Chat message verbosity: "Normal" | "Leader" | "Debug"
        chatMessages    = "Normal",

        -- Join session restrictions: only join sessions from friends / guildmates
        joinRestrictions = {
            friends = false,
            guild   = false,
        },

        -- Loot master restriction: who may trigger manual rolls and stop rolls
        -- "anyLeader"      = any raid leader or officer (default)
        -- "onlyLootMaster" = only the designated loot master
        lootMasterRestriction = "anyLeader",

        -- Loot roll triggering mode: "automatic" | "promptForStart"
        lootRollTriggering = "automatic",

        -- Loot count system: enabled (true) or disabled (false)
        lootCountEnabled = true,

        -- Loot count identity mode: true = shared across linked alts (locked to main), false = per character
        lootCountLockedToMain = true,

        -- Tier tokens and recipes go through the OLL roll like gear; these
        -- decide whether winning one increments the winner's loot count.
        tokensCountAsLoot  = false,
        recipesCountAsLoot = false,

        -- Loot count reset schedule: "weekly" / "monthly" / "manual"
        resetSchedule = "weekly",

        -- Which region's reset time to use: "auto" (detect from the client),
        -- "NA" (Tuesday 15:00 UTC) or "EU" (Wednesday 04:00 UTC)
        resetRegion   = "auto",

        -- Saved window positions: { ["frameName"] = { point, x, y } }
        framePositions  = {},

        -- Settings window: last-viewed section and Roster sub-tab (UI only)
        settingsSection   = "general",
        settingsRosterTab = "counts",
    },
    global = {
        -- Bumped when a one-time global data migration is added (see MigrateGlobal)
        dataVersion        = 0,
        -- Loot counts: { ["Name-Realm"] = count }
        lootCounts         = {},
        lastResetTimestamp = 0,

        -- Player links: { ["Main-Realm"] = { "Alt1-Realm", … } }
        playerLinks        = {},

        -- Player's own character list and main designation
        myCharacters       = {
            main  = "",   -- "Name-Realm" of designated main
            chars = {},   -- list of "Name-Realm" strings (all their characters)
        },

        -- Loot history: array of entry tables.  Rows (and closed session
        -- records) older than historyRetentionDays are pruned at login and
        -- when the setting is lowered (Settings > History).
        lootHistory        = {},
        historyRetentionDays = 365,

        -- Session history: array of session records
        sessionHistory     = {},

        -- Pending roll snapshot for /reload persistence (promptForStart mode)
        -- { items = {...}, bossName = "..." } — cleared when the roll is started or session ends
        pendingRoll        = nil,

        -- Live mirror of the session this account is leading, for restore
        -- after /reload, crash or disconnect.  nil when no session is active.
        activeSession      = nil,
        -- Live mirror of the roll a non-leader loot master on this account
        -- is running (items, choices, results), for restore after /reload.
        authorityRoll      = nil,
    },
}

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
function OrderedLootList:OnInitialize()
    -- Database
    self.db = LibStub("AceDB-3.0"):New("OrderedLootListDB", defaults, true)
    ns.db = self.db

    self:MigrateProfile()
    self:MigrateGlobal()

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

------------------------------------------------------------------------
-- One-time profile migrations, keyed on profile.settingsVersion.
-- AceDB never returns nil for a key that has a default, so "if x == nil"
-- checks can not detect an old profile; a version number can.
------------------------------------------------------------------------
local SETTINGS_VERSION = 1

function OrderedLootList:MigrateProfile()
    local p = ns.db.profile
    local v = p.settingsVersion or 0

    -- v1: auto-pass toggles used to default to ON (autoPassBOE, autoPassOffSpec)
    -- while the Settings UI had them disabled, so players were silently
    -- auto-passing off-stat items with no way to turn it off.  Force every
    -- auto-pass toggle off once; players can opt back in from Settings.
    if v < 1 then
        p.autoPassBOE          = false
        p.autoPassOffSpec      = false
        p.autoPassUnequippable = false
        p.holdWMode            = false
    end

    p.settingsVersion = SETTINGS_VERSION
end

------------------------------------------------------------------------
-- One-time account-wide data migrations, keyed on global.dataVersion.
------------------------------------------------------------------------
local DATA_VERSION = 1

-- "Name-Realm" with the realm part normalised the way GetNormalizedRealmName
-- does it: spaces, apostrophes and hyphens removed, every other byte kept
-- (Cyrillic and accented realm names must survive untouched).
local function _NormalizeKey(name)
    if type(name) ~= "string" then return name end
    local n, r = name:match("^([^-]+)%-(.+)$")
    if not r then return name end
    return n .. "-" .. (r:gsub("[ '%-]", ""))
end

function OrderedLootList:MigrateGlobal()
    local g = ns.db.global
    if (g.dataVersion or 0) >= DATA_VERSION then return end

    -- v1: Settings built some keys from GetRealmName():gsub(" ", ""), which
    -- kept apostrophes and hyphens, while everything else used
    -- GetNormalizedRealmName.  On such realms one player had two identities.
    -- Merge them onto the normalised key.
    local counts = {}
    for k, v in pairs(g.lootCounts or {}) do
        local nk = _NormalizeKey(k)
        counts[nk] = math.max(counts[nk] or 0, tonumber(v) or 0)
    end
    g.lootCounts = counts

    local links = {}
    for main, alts in pairs(g.playerLinks or {}) do
        local nm = _NormalizeKey(main)
        links[nm] = links[nm] or {}
        for _, a in ipairs(type(alts) == "table" and alts or {}) do
            local na = _NormalizeKey(a)
            if na ~= nm and not tContains(links[nm], na) then tinsert(links[nm], na) end
        end
    end
    g.playerLinks = (ns.PlayerLinks and ns.PlayerLinks._Sanitize)
        and ns.PlayerLinks:_Sanitize(links) or links

    local mc = g.myCharacters
    if mc then
        mc.main = _NormalizeKey(mc.main)
        local seen, out = {}, {}
        for _, c in ipairs(mc.chars or {}) do
            local nc = _NormalizeKey(c)
            if not seen[nc] then seen[nc] = true; tinsert(out, nc) end
        end
        mc.chars = out
    end

    for _, e in ipairs(g.lootHistory or {}) do
        e.player = _NormalizeKey(e.player)
    end

    g.dataVersion = DATA_VERSION
end

------------------------------------------------------------------------
-- Chat message filtering helper
-- level: "Normal" | "Leader" | "Debug"
-- Prints only when the player's chatMessages setting >= the given level.
------------------------------------------------------------------------
do
    local _order = { Normal = 1, Leader = 2, Debug = 3 }
    ns.ChatPrint = function(level, msg)
        local setting = (ns.db and ns.db.profile and ns.db.profile.chatMessages) or "Normal"
        if (_order[level] or 1) <= (_order[setting] or 1) then
            ns.addon:Print(msg)
        end
    end
end

function OrderedLootList:OnEnable()
    -- Check weekly loot count reset
    if ns.LootCount then
        ns.LootCount:CheckWeeklyReset()
    end

    -- Drop loot-history rows and closed session records past the retention
    -- window (Settings > History).
    if ns.LootHistory and ns.LootHistory.Prune then
        ns.LootHistory:Prune()
    end

    -- Auto-register the current character into the player's character list
    if ns.PlayerLinks then
        ns.PlayerLinks:AddMyCharacter(ns.GetPlayerNameRealm())
    end

    -- Item data arriving after a frame was drawn (cold cache on a first
    -- kill): redraw whatever is showing so icons, quality colours and the
    -- auto-pass rules see the real item.  Debounced; answered items keep
    -- their choice (see Session:_RefreshRollFrames).
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, _, success)
        if not success or ns._itemInfoRefreshPending then return end
        ns._itemInfoRefreshPending = true
        C_Timer.After(0.25, function()
            ns._itemInfoRefreshPending = false
            local sess = ns.Session
            if sess and ns.RollFrame and ns.RollFrame:IsVisible()
                    and not (ns.RollFrame._active and ns.RollFrame._active._viewingHistory)
                    and sess.currentItems and #sess.currentItems > 0 then
                sess:_RefreshRollFrames()
            end
            if ns.LeaderFrame and ns.LeaderFrame._frame and ns.LeaderFrame._frame:IsShown() then
                ns.LeaderFrame:Refresh()
            end
            if ns.HistoryFrame and ns.HistoryFrame:IsVisible() then ns.HistoryFrame:Refresh() end
            if ns.SessionHistoryFrame and ns.SessionHistoryFrame:IsVisible() then
                ns.SessionHistoryFrame:Refresh()
            end
        end)
    end)

    -- Shared font objects were tinted with the Ledger palette at file load
    -- (before the DB existed); re-tint everything with the saved theme.
    if ns.Theme and ns.Theme.ApplyToAll then
        ns.Theme:ApplyToAll()
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
    elseif input == "stop" or input == "stop force" then
        if ns.Session and ns.Session:IsActive() then
            -- Same confirmation as the Leader Frame button; "stop force" skips it
            if input == "stop" and StaticPopupDialogs["OLL_CONFIRM_END_SESSION"] then
                StaticPopup_Show("OLL_CONFIRM_END_SESSION")
            else
                ns.Session:EndSession()
            end
        else
            self:Print("No active loot session.")
        end
    elseif input == "config" or input == "settings" or input == "options" then
        if ns.Settings then ns.Settings:OpenConfig() end
    elseif input == "history" then
        if ns.HistoryFrame then ns.HistoryFrame:Toggle() end
    elseif input == "sessions" then
        if ns.SessionHistoryFrame then ns.SessionHistoryFrame:Toggle() end
    elseif input == "takeover" then
        if ns.Session then ns.Session:TakeoverSession() end
    elseif input == "links" then
        if ns.Settings then ns.Settings:OpenConfig("roster.links") end
    elseif input == "loot" then
        if ns.RollFrame then ns.RollFrame:Toggle() end
    elseif input == "resetframes" then
        ns.ResetAllFramePositions()
    else
        self:Print("Usage:")
        self:Print("  /oll start        – Start a loot session (leader)")
        self:Print("  /oll stop         – End the current loot session (asks first; 'stop force' skips)")
        self:Print("  /oll config       – Open settings")
        self:Print("  /oll history      – Open loot history")
        self:Print("  /oll sessions     – Open session history")
        self:Print("  /oll takeover     – Assume session control (officers only)")
        self:Print("  /oll links        – View synced character links")
        self:Print("  /oll loot         – Toggle the roll frame")
        self:Print("  /oll resetframes  – Reset all loot frames to default positions")
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
    name = name or UnitName("player") or "Unknown"
    if not realm or realm == "" then realm = GetNormalizedRealmName() end
    -- Before PLAYER_LOGIN the realm can be unknown; never mint a "Name-" key.
    if not realm or realm == "" then return name end
    return name .. "-" .. realm
end

------------------------------------------------------------------------
-- Helper: is the player the group/raid leader?
------------------------------------------------------------------------
function ns.IsLeader()
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsRaidOfficer("player")
    elseif IsInGroup() then
        return UnitIsGroupLeader("player")
    end
    return true -- solo = leader
end

------------------------------------------------------------------------
-- Helper: total players in the current group, including the local player.
-- Returns 0 when solo (not in any group).
------------------------------------------------------------------------
function ns.GetGroupSize()
    return GetNumGroupMembers()
end

------------------------------------------------------------------------
-- Helper: is the player the session leader (session owner only, not officers)?
------------------------------------------------------------------------
function ns.IsSessionLeader()
    return ns.NamesEqual(ns.GetPlayerNameRealm(), ns.Session.leaderName)
end

------------------------------------------------------------------------
-- Helper: get communication channel
------------------------------------------------------------------------
function ns.GetCommChannel()
    -- Dungeon Finder / Raid Finder groups are "instance" groups: RAID and
    -- PARTY addon messages are silently dropped there, INSTANCE_CHAT works.
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return "WHISPER" -- fallback (solo testing – whisper self)
end

------------------------------------------------------------------------
-- Helper: map the profile's announce channel to one SendChatMessage will
-- accept for the current group type.  RAID / RAID_WARNING throw in a
-- 5-man party; instance groups need INSTANCE_CHAT for everything.
------------------------------------------------------------------------
function ns.GetAnnounceChannel(preferred)
    preferred = preferred or ns.db.profile.announceChannel or "RAID"
    if preferred == "SAY" then return "SAY" end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        if preferred == "RAID_WARNING"
                and not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
            return "RAID"
        end
        return preferred
    elseif IsInGroup() then
        return "PARTY"
    end
    return "SAY"
end

------------------------------------------------------------------------
-- Helper: compare two player names, ignoring realm suffix differences.
-- AceComm sender may be "Name" (same realm) while stored names are
-- always "Name-Realm".  This strips the realm from both before comparing.
-- Display / legacy use only: for trust decisions use ns.NamesEqual.
------------------------------------------------------------------------
function ns.NamesMatch(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local nameA = a:match("^(.-)%-") or a
    local nameB = b:match("^(.-)%-") or b
    return nameA == nameB
end

------------------------------------------------------------------------
-- Helper: canonical "Name-Realm" form.  AceComm and the roster APIs report
-- same-realm players as bare "Name"; append the local normalized realm so
-- every stored key and every trust comparison sees one shape.
------------------------------------------------------------------------
function ns.CanonicalName(name)
    if not name or name == "" then return name end
    if name:find("-", 1, true) then return name end
    local realm = GetNormalizedRealmName()
    if not realm or realm == "" then return name end
    return name .. "-" .. realm
end

------------------------------------------------------------------------
-- Helper: realm-aware identity comparison for trust checks.  Unlike
-- NamesMatch, Bob-RealmA never equals Bob-RealmB.
------------------------------------------------------------------------
function ns.NamesEqual(a, b)
    if not a or not b then return false end
    return ns.CanonicalName(a) == ns.CanonicalName(b)
end

------------------------------------------------------------------------
-- Helper: bring a frame and ALL its children above other addon windows.
-- Uses a shared counter so each focus click assigns a higher base level.
-- The gap (100) ensures child frames don't interleave with other windows.
------------------------------------------------------------------------
local _topFrameLevel = 100
-- Frame levels are capped by the client; wrap well before that.  After a
-- wrap the next click on any other window raises it above this one again.
local FRAME_LEVEL_CEILING = 9000

local function SetFrameLevelRecursive(frame, baseLevel)
    frame:SetFrameLevel(baseLevel)
    local children = { frame:GetChildren() }
    for _, child in ipairs(children) do
        -- child._levelOffset lets a widget (the resize grip) stay above its
        -- siblings across raises.
        SetFrameLevelRecursive(child, baseLevel + (child._levelOffset or 1))
    end
end

function ns.RaiseFrame(frame)
    if _topFrameLevel >= FRAME_LEVEL_CEILING then _topFrameLevel = 100 end
    _topFrameLevel = _topFrameLevel + 100
    SetFrameLevelRecursive(frame, _topFrameLevel)
end

------------------------------------------------------------------------
-- Helper: save a frame's position to the DB
------------------------------------------------------------------------
function ns.SaveFramePosition(key, frame)
    if not ns.db or not frame then return end
    local point, _, _, x, y = frame:GetPoint()
    local w, h = frame:GetWidth(), frame:GetHeight()
    if not ns.db.profile.framePositions then
        ns.db.profile.framePositions = {}
    end
    ns.db.profile.framePositions[key] = { point = point, x = x, y = y, w = w, h = h }
end

------------------------------------------------------------------------
-- Helper: restore a frame's position from the DB
------------------------------------------------------------------------
-- Pin a frame by its top-left corner (screen coordinates) so a resize from
-- the bottom-right grip grows it in one direction.  A CENTER-anchored frame
-- grows symmetrically under StartSizing and, clamped to the screen, snaps
-- to full height on the first click.
-- Anchors TOPLEFT -> UIParent TOPLEFT so SaveFramePosition (which stores
-- point + offsets and restores them against the same UIParent point)
-- round-trips correctly.
function ns.AnchorTopLeft(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return end
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left * scale, top * scale - UIParent:GetHeight())
end

function ns.RestoreFramePosition(key, frame)
    if not ns.db or not frame then return end
    local pos = ns.db.profile.framePositions and ns.db.profile.framePositions[key]
    if pos and pos.point then
        frame:ClearAllPoints()
        frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
        if pos.w and pos.h and pos.w > 0 and pos.h > 0 and frame:IsResizable() then
            frame:SetSize(pos.w, pos.h)
        end
        -- A saved offset that puts the frame entirely off screen (e.g. from a
        -- bad anchor in an earlier build) is discarded.
        local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
        local x, y = pos.x or 0, pos.y or 0
        if math.abs(x) > sw or math.abs(y) > sh then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            ns.db.profile.framePositions[key] = nil
        end
    end
end

------------------------------------------------------------------------
-- Reset all loot-frame positions to defaults and clear saved positions.
-- Callable via /oll resetframes.
------------------------------------------------------------------------
function ns.ResetAllFramePositions()
    -- Default anchors for each frame
    local defaults = {
        RollFrame        = { point = "CENTER", x = 0,   y = 100 },
        SmallRollFrame   = { point = "CENTER", x = 0,   y = 100 },
        LargeRollFrame   = { point = "CENTER", x = 0,   y = 0   },
    }

    -- Clear saved positions from DB
    if ns.db and ns.db.profile.framePositions then
        for key in pairs(defaults) do
            ns.db.profile.framePositions[key] = nil
        end
    end

    -- Apply defaults to any already-created frame objects
    local frameObjects = {
        RollFrame      = ns.MediumRollFrame and ns.MediumRollFrame._frame,
        SmallRollFrame = ns.SmallRollFrame  and ns.SmallRollFrame._frame,
        LargeRollFrame = ns.LargeRollFrame  and ns.LargeRollFrame._frame,
    }
    for key, f in pairs(frameObjects) do
        if f then
            local d = defaults[key]
            f:ClearAllPoints()
            f:SetPoint(d.point, UIParent, d.point, d.x, d.y)
            if f._defaultSize then f:SetSize(f._defaultSize[1], f._defaultSize[2]) end
        end
    end

    print("|cff00ff00[OLL]|r All loot frame positions reset to defaults.")
end

------------------------------------------------------------------------
-- Weekly reset schedule, by region.  All times are UTC; every helper below
-- works in UTC arithmetic so the client's local timezone never matters.
------------------------------------------------------------------------
ns.RESET_SPECS = {
    -- wday: 1=Sun, 2=Mon, 3=Tue, 4=Wed ...
    NA = { wday = 3, hourUTC = 15, label = "Tuesday 15:00 UTC (8am PT / 11am ET)" },
    EU = { wday = 4, hourUTC = 4,  label = "Wednesday 04:00 UTC (5am CET / 6am CEST)" },
}

-- Effective region: the profile setting, or detected from the client when
-- set to "auto".  GetCurrentRegion(): 1 US, 2 KR, 3 EU, 4 TW, 5 CN.
function ns.GetResetRegion()
    local r = ns.db and ns.db.profile and ns.db.profile.resetRegion
    if r == "NA" or r == "EU" then return r end
    local id = GetCurrentRegion and GetCurrentRegion()
    return (id == 3) and "EU" or "NA"
end

function ns.GetResetSpec()
    return ns.RESET_SPECS[ns.GetResetRegion()] or ns.RESET_SPECS.NA
end

------------------------------------------------------------------------
-- Helper: Unix timestamp for a UTC date table {year, month, day, hour, ...}.
-- os.time() interprets tables as local time, so correct by the client's
-- current UTC offset.
------------------------------------------------------------------------
function ns.TimeUTC(tbl)
    local asLocal = time(tbl)
    local offset  = time(date("!*t", asLocal)) - asLocal   -- (-utcOffset)
    return asLocal - offset
end

------------------------------------------------------------------------
-- Helper: most recent weekly reset at or before `at` (default now).
------------------------------------------------------------------------
function ns.GetLastWeeklyReset(at)
    local spec = ns.GetResetSpec()
    at = at or time()
    local d          = date("!*t", at)
    local daySecs    = d.hour * 3600 + d.min * 60 + d.sec
    local daysSince  = (d.wday - spec.wday) % 7
    local candidate  = at - daysSince * 86400 - (daySecs - spec.hourUTC * 3600)
    if candidate > at then candidate = candidate - 7 * 86400 end
    return candidate
end

------------------------------------------------------------------------
-- Helper: first weekly reset strictly after `after`.
------------------------------------------------------------------------
function ns.GetNextWeeklyReset(after)
    return ns.GetLastWeeklyReset(after) + 7 * 86400
end

-- Kept for existing callers: most recent weekly reset before now.
function ns.GetCurrentWeeklyResetTime()
    return ns.GetLastWeeklyReset(time())
end

------------------------------------------------------------------------
-- Helper: strip realm suffix from "Name-Realm" → "Name".
------------------------------------------------------------------------
function ns.StripRealm(name)
    if not name then return name end
    return name:match("^([^-]+)") or name
end

------------------------------------------------------------------------
-- Helper: numeric item id from an item hyperlink (nil if not an item link).
------------------------------------------------------------------------
function ns.GetItemIdFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

------------------------------------------------------------------------
-- Helper: stable identity key for an item hyperlink.
-- Item links carry context-dependent fields (uniqueID, linkLevel,
-- specializationID) that differ between the loot window and the bag, so two
-- links for the same physical item are often not string-equal.  This reduces
-- a link to "itemID:bonusID,bonusID,..." (bonus IDs sorted) which is stable
-- across those contexts and still distinguishes difficulty/warforged/socket
-- variants.  Returns nil if the string is not an item link.
------------------------------------------------------------------------
function ns.GetItemKey(link)
    if type(link) ~= "string" then return nil end
    local payload = link:match("|Hitem:([^|]+)|h") or link:match("^item:(.+)$")
    if not payload then return nil end

    local fields = {}
    for f in (payload .. ":"):gmatch("([^:]*):") do
        fields[#fields + 1] = f
    end
    local itemID = fields[1]
    if not itemID or itemID == "" then return nil end

    -- Field 13 is numBonusIDs, followed by that many bonus IDs.
    local numBonus = tonumber(fields[13]) or 0
    local bonus = {}
    for i = 1, numBonus do
        local b = fields[13 + i]
        if b and b ~= "" then bonus[#bonus + 1] = b end
    end
    table.sort(bonus)
    return itemID .. ":" .. table.concat(bonus, ",")
end

------------------------------------------------------------------------
-- Helper: do two item hyperlinks refer to the same item?
-- Compares by ns.GetItemKey; falls back to string equality when either
-- side cannot be parsed.
------------------------------------------------------------------------
function ns.ItemLinksMatch(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local ka, kb = ns.GetItemKey(a), ns.GetItemKey(b)
    if ka and kb then return ka == kb end
    return false
end

------------------------------------------------------------------------
-- Helper: attach a WoW item tooltip to a frame.
-- getLinkFn(frame) should return the item hyperlink string (or nil/false).
-- The frame will have EnableMouse(true) called automatically.
------------------------------------------------------------------------
function ns.AttachItemTooltip(frame, getLinkFn)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(f)
        local link = getLinkFn(f)
        if link then
            GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
            if link:find("|H") then
                GameTooltip:SetHyperlink(link)
            else
                GameTooltip:SetText(link)
            end
            GameTooltip:Show()
        end
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

------------------------------------------------------------------------
-- Helper: attach an alt/main tooltip to a frame.
-- getNameFn can be a string or a function() returning a name string.
-- Shows "Main: X" if the name is an alt linked to a main; no-ops otherwise.
-- Uses HookScript to avoid overwriting existing OnEnter/OnLeave handlers.
------------------------------------------------------------------------
function ns.AttachAltTooltip(frame, getNameFn)
    frame:EnableMouse(true)
    frame:HookScript("OnEnter", function(f)
        local name = type(getNameFn) == "function" and getNameFn() or getNameFn
        if not name then return end
        local mainIdentity = ns.PlayerLinks:ResolveIdentity(name)
        if not mainIdentity or mainIdentity == name then return end
        GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Main: " .. ns.StripRealm(mainIdentity), 1, 1, 1)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function(f)
        if GameTooltip:GetOwner() == f then
            GameTooltip_Hide()
        end
    end)
end

------------------------------------------------------------------------
-- Expose globals for other modules
------------------------------------------------------------------------
_G.OrderedLootList = OrderedLootList
_G.OLL_NS = ns
