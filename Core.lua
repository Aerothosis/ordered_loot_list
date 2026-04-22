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
local _tocVersion       = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
ns.VERSION              = (_tocVersion and _tocVersion:sub(1, 1) ~= "@") and _tocVersion or "dev"

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
        autoPassBOE          = true,
        autoPassOffSpec      = true,
        autoPassUnequippable = false,
        holdWMode            = false,
        showStatBadge        = true,
        announceChannel = "RAID",
        disenchanter    = "",  -- Name-Realm of designated disenchanter
        rollOptions     = nil, -- nil ⇒ use DEFAULT_ROLL_OPTIONS

        -- Minimap button
        minimap         = {
            hide = false,
        },

        -- UI theme ("Basic" or "Midnight") – player-local, never synced
        theme           = "Basic",

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

        -- Loot count reset schedule: "weekly" / "monthly" / "manual"
        resetSchedule = "weekly",

        -- Saved window positions: { ["frameName"] = { point, x, y } }
        framePositions  = {},
    },
    global = {
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

        -- Loot history: array of entry tables
        lootHistory        = {},

        -- Session history: array of session records
        sessionHistory     = {},

        -- Pending roll snapshot for /reload persistence (promptForStart mode)
        -- { items = {...}, bossName = "..." } — cleared when the roll is started or session ends
        pendingRoll        = nil,
    },
}

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
function OrderedLootList:OnInitialize()
    -- Database
    self.db = LibStub("AceDB-3.0"):New("OrderedLootListDB", defaults, true)
    ns.db = self.db

    -- Startup migration: force auto-pass toggles to false so rolling works normally
    do
        local db = ns.db
        if db.profile.autoPassBOE == nil then db.profile.autoPassBOE = false end
        if db.profile.autoPassOffSpec == nil then db.profile.autoPassOffSpec = false end
        if db.profile.autoPassUnequippable == nil then db.profile.autoPassUnequippable = false end
        if db.profile.holdWMode == nil then db.profile.holdWMode = false end
    end

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

    -- Auto-register the current character into the player's character list
    if ns.PlayerLinks then
        ns.PlayerLinks:AddMyCharacter(ns.GetPlayerNameRealm())
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
    elseif input == "sessions" then
        if ns.SessionHistoryFrame then ns.SessionHistoryFrame:Toggle() end
    elseif input == "takeover" then
        if ns.Session then ns.Session:TakeoverSession() end
    elseif input == "links" then
        if ns.Settings then ns.Settings:OpenConfig("playerLinks") end
    elseif input == "loot" then
        if ns.RollFrame then ns.RollFrame:Toggle() end
    elseif input == "resetframes" then
        ns.ResetAllFramePositions()
    else
        self:Print("Usage:")
        self:Print("  /oll start        – Start a loot session (leader)")
        self:Print("  /oll stop         – End the current loot session")
        self:Print("  /oll config       – Open settings")
        self:Print("  /oll history      – Open loot history")
        self:Print("  /oll sessions     – Open session history")
        self:Print("  /oll takeover     – Assume session control (officers only)")
        self:Print("  /oll links        – Manage character links")
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
    return ns.NamesMatch(ns.GetPlayerNameRealm(), ns.Session.leaderName)
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
    local w, h = frame:GetWidth(), frame:GetHeight()
    if not ns.db.profile.framePositions then
        ns.db.profile.framePositions = {}
    end
    ns.db.profile.framePositions[key] = { point = point, x = x, y = y, w = w, h = h }
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
        if pos.w and pos.h and pos.w > 0 and pos.h > 0 then
            frame:SetSize(pos.w, pos.h)
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
        end
    end

    print("|cff00ff00[OLL]|r All loot frame positions reset to defaults.")
end

------------------------------------------------------------------------
-- Internal: update scrollbar visibility/ranges for a resizable frame
------------------------------------------------------------------------
local function _UpdateResizableScrollBars(f)
    local sf      = f._scrollViewport
    local vBar    = f._vBar
    local hBar    = f._hBar
    local content = f._contentPanel
    if not (sf and vBar and hBar and content) then return end

    local fw = f:GetWidth()
    local fh = f:GetHeight()
    local cw = content:GetWidth()
    local ch = content:GetHeight()

    local needsV = ch > fh + 0.5
    local needsH = cw > fw + 0.5
    -- Re-check after accounting for the other scrollbar eating into the viewport
    local vpW = fw - (needsV and 16 or 0)
    local vpH = fh - (needsH and 16 or 0)
    if not needsV and ch > vpH + 0.5 then needsV = true; vpW = fw - 16 end
    if not needsH and cw > vpW + 0.5 then needsH = true; vpH = fh - 16 end

    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     0, 0)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(needsV and 16 or 0), (needsH and 16 or 0))

    if needsV then
        local vMax = math.max(0, ch - vpH)
        vBar:SetMinMaxValues(0, vMax)
        vBar:SetValue(math.min(vBar:GetValue(), vMax))
        vBar:ClearAllPoints()
        vBar:SetPoint("TOPRIGHT",    f, "TOPRIGHT",    0, 0)
        vBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, needsH and 16 or 0)
        vBar:Show()
    else
        sf:SetVerticalScroll(0)
        vBar:SetValue(0)
        vBar:Hide()
    end

    if needsH then
        local hMax = math.max(0, cw - vpW)
        hBar:SetMinMaxValues(0, hMax)
        hBar:SetValue(math.min(hBar:GetValue(), hMax))
        hBar:ClearAllPoints()
        hBar:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, 0)
        hBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", needsV and -16 or 0, 0)
        hBar:Show()
    else
        sf:SetHorizontalScroll(0)
        hBar:SetValue(0)
        hBar:Hide()
    end
end

------------------------------------------------------------------------
-- Helper: make a frame resizable with a 2-D-scrollable fixed content panel.
-- Call this inside GetFrame() right after the backdrop / movement setup and
-- before creating any child widgets.  Parent ALL child widgets to the returned
-- content frame instead of the outer frame.
-- contentW/contentH  – fixed size of the inner content panel
-- Returns: contentPanel (Frame)
------------------------------------------------------------------------
function ns.MakeResizableScrollFrame(f, contentW, contentH)
    local minW = math.max(150, math.floor(contentW * 0.35))
    local minH = math.max(120, math.floor(contentH * 0.35))
    f:SetResizable(true)
    f:SetResizeBounds(minW, minH)

    -- Outer scroll frame (viewport)
    local sf = CreateFrame("ScrollFrame", nil, f)
    sf:SetAllPoints(f)   -- initial full-cover; adjusted by _UpdateResizableScrollBars
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur  = self:GetVerticalScroll()
        local maxV = self:GetVerticalScrollRange()
        local newV = math.max(0, math.min(maxV, cur - delta * 20))
        self:SetVerticalScroll(newV)
        if f._vBar then f._vBar:SetValue(newV) end
    end)

    -- Fixed-size content panel – all UI lives here
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(contentW, contentH)
    sf:SetScrollChild(content)

    f._scrollViewport = sf
    f._contentPanel   = content

    -- Vertical scrollbar
    local vBar = CreateFrame("Slider", nil, f)
    vBar:SetOrientation("VERTICAL")
    vBar:SetWidth(16)
    local vBg = vBar:CreateTexture(nil, "BACKGROUND")
    vBg:SetAllPoints()
    vBg:SetColorTexture(0.05, 0.05, 0.08, 0.85)
    local vThumb = vBar:CreateTexture(nil, "OVERLAY")
    vThumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    vThumb:SetSize(16, 22)
    vBar:SetThumbTexture(vThumb)
    vBar:SetMinMaxValues(0, 0)
    vBar:SetValue(0)
    vBar:SetValueStep(10)
    vBar:SetObeyStepOnDrag(true)
    vBar:SetScript("OnValueChanged", function(self, val)
        sf:SetVerticalScroll(val)
    end)
    vBar:Hide()
    f._vBar = vBar

    -- Horizontal scrollbar
    local hBar = CreateFrame("Slider", nil, f)
    hBar:SetOrientation("HORIZONTAL")
    hBar:SetHeight(16)
    local hBg = hBar:CreateTexture(nil, "BACKGROUND")
    hBg:SetAllPoints()
    hBg:SetColorTexture(0.05, 0.05, 0.08, 0.85)
    local hThumb = hBar:CreateTexture(nil, "OVERLAY")
    hThumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    hThumb:SetSize(22, 16)
    hBar:SetThumbTexture(hThumb)
    hBar:SetMinMaxValues(0, 0)
    hBar:SetValue(0)
    hBar:SetValueStep(10)
    hBar:SetObeyStepOnDrag(true)
    hBar:SetScript("OnValueChanged", function(self, val)
        sf:SetHorizontalScroll(val)
    end)
    hBar:Hide()
    f._hBar = hBar

    -- Resize grip (bottom-right corner)
    -- Single-click+drag: resize; double-click: reset to default content size
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    grip:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then
            f:StartSizing("BOTTOMRIGHT")
        end
    end)
    grip:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then
            -- Right-click: reset to default content size
            f:SetSize(contentW, contentH)
            _UpdateResizableScrollBars(f)
            if f._posKey then ns.SaveFramePosition(f._posKey, f) end
        end
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        _UpdateResizableScrollBars(f)
        if f._posKey then ns.SaveFramePosition(f._posKey, f) end
    end)
    f._resizeGrip = grip

    f:HookScript("OnSizeChanged", function() _UpdateResizableScrollBars(f) end)
    f:HookScript("OnShow",        function() _UpdateResizableScrollBars(f) end)

    return content
end

------------------------------------------------------------------------
-- Helper: returns the Unix timestamp of the most recent WoW weekly reset.
-- WoW weekly reset occurs every Tuesday at 15:00 UTC (8:00 AM Pacific).
------------------------------------------------------------------------
function ns.GetCurrentWeeklyResetTime()
    local RESET_WDAY     = 3   -- Tuesday (wday: 1=Sun, 2=Mon, 3=Tue, ...)
    local RESET_HOUR_UTC = 15  -- 15:00 UTC
    local now  = time()
    local d    = date("!*t", now)
    local todaySecs        = d.hour * 3600 + d.min * 60 + d.sec
    local daysSinceTuesday = (d.wday - RESET_WDAY) % 7
    -- Candidate: daysSinceTuesday days ago, at RESET_HOUR_UTC:00:00 UTC
    local candidate = now - (daysSinceTuesday * 86400) - (todaySecs - RESET_HOUR_UTC * 3600)
    -- If it's Tuesday but before reset time, the reset was 7 days ago
    if candidate > now then candidate = candidate - 7 * 86400 end
    return candidate
end

------------------------------------------------------------------------
-- Helper: strip realm suffix from "Name-Realm" → "Name".
------------------------------------------------------------------------
function ns.StripRealm(name)
    if not name then return name end
    return name:match("^([^-]+)") or name
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
