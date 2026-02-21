------------------------------------------------------------------------
-- OrderedLootList  –  UI/DebugWindow.lua
-- Debug/Test mode window for simulating loot sessions
------------------------------------------------------------------------

local ns = _G.OLL_NS

local DebugWindow = {}
ns.DebugWindow = DebugWindow

------------------------------------------------------------------------
-- Fake item pool (icon IDs are real texture file IDs from common items)
------------------------------------------------------------------------
local FAKE_ITEMS = {
    { name = "Blazefury, Reborn",                            quality = 4, icon = 135269, id = 999001 },
    { name = "Crown of Eternal Winter",                      quality = 4, icon = 133117, id = 999002 },
    { name = "Dreadplate of Decimation",                     quality = 4, icon = 133072, id = 999003 },
    { name = "Ashen Band of Destruction",                    quality = 4, icon = 133345, id = 999004 },
    { name = "Voidforged Legguards",                         quality = 4, icon = 134583, id = 999005 },
    { name = "Stormbreaker Pauldrons",                       quality = 4, icon = 135039, id = 999006 },
    { name = "Starweave Vestments",                          quality = 4, icon = 135008, id = 999007 },
    { name = "Obsidian Edge Cloak",                          quality = 3, icon = 133762, id = 999008 },
    { name = "Ironveil Gauntlets",                           quality = 3, icon = 132949, id = 999009 },
    { name = "Moonstone Signet",                             quality = 3, icon = 133347, id = 999010 },
    { name = "Sunforged Breastplate",                        quality = 4, icon = 132740, id = 999011 },
    { name = "Wraithbone Greathelm",                         quality = 4, icon = 133073, id = 999012 },
    { name = "Thunderfury, Blessed Blade of the Windseeker", quality = 5, icon = 134585, id = 19019 },
    { name = "Sulfuras, Hand of Ragnaros",                   quality = 5, icon = 132347, id = 17182 },
    { name = "Warglaive of Azzinoth",                        quality = 5, icon = 135553, id = 32837 },
    { name = "Thori'dal, the Stars' Fury",                   quality = 5, icon = 135502, id = 34334 },
    { name = "Val'anyr, Hammer of Ancient Kings",            quality = 5, icon = 132866, id = 46017 },
    { name = "Shadowmourne",                                 quality = 5, icon = 133485, id = 49623 },
    { name = "Dragonwrath, Tarecgosa's Rest",                quality = 5, icon = 133313, id = 71086 },
    { name = "Fangs of the Father",                          quality = 5, icon = 133480, id = 77949 },
}

-- Quality colors (matches WoW quality color codes)
local QUALITY_COLORS = {
    [2] = "|cff1eff00", -- Uncommon
    [3] = "|cff0070dd", -- Rare
    [4] = "|cffa335ee", -- Epic
    [5] = "|cffff8000", -- Legendary
}

------------------------------------------------------------------------
-- Build a fake item link (colored text, no real hyperlink)
------------------------------------------------------------------------
local function MakeFakeLink(item)
    local color = QUALITY_COLORS[item.quality] or "|cffffffff"
    return color .. "[" .. item.name .. "]|r"
end

------------------------------------------------------------------------
-- Pick N random unique items from the pool
------------------------------------------------------------------------
local function PickRandomItems(count)
    local pool = {}
    for i, item in ipairs(FAKE_ITEMS) do
        pool[i] = item
    end

    local picked = {}
    for i = 1, math.min(count, #pool) do
        local idx = math.random(1, #pool)
        local item = pool[idx]
        tinsert(picked, {
            icon    = item.icon,
            name    = item.name,
            link    = MakeFakeLink(item),
            quality = item.quality,
            id      = item.id,
        })
        table.remove(pool, idx)
    end
    return picked
end

------------------------------------------------------------------------
-- Random boss name generator
------------------------------------------------------------------------
local BOSS_PREFIXES = {
    "Shadow", "Flame", "Void", "Storm", "Iron", "Blood", "Frost",
    "Doom", "Dread", "Dark", "Chaos", "Nether", "Fel", "Ancient",
    "Corrupted", "Enraged", "Cursed", "Infernal", "Primordial",
}
local BOSS_SUFFIXES = {
    "lord", "maw", "bane", "fang", "claw", "heart", "walker",
    "reaver", "weaver", "caller", "bringer", "render", "warden",
    "crusher", "howl", "wraith", "shade", "fiend", "terror",
}
local BOSS_TITLES = {
    "the Unyielding", "the Devourer", "the Eternal", "the Fallen",
    "the Relentless", "the Corrupted", "the Unbound", "the Mad",
    "of the Abyss", "of the Void", "the Merciless", "the Forgotten",
}

local _usedBossNames = {}

local function GenerateBossName()
    -- Try up to 20 times to get a unique name
    for _ = 1, 20 do
        local prefix = BOSS_PREFIXES[math.random(#BOSS_PREFIXES)]
        local suffix = BOSS_SUFFIXES[math.random(#BOSS_SUFFIXES)]
        local title  = BOSS_TITLES[math.random(#BOSS_TITLES)]
        local name   = prefix .. suffix .. " " .. title
        if not _usedBossNames[name] then
            _usedBossNames[name] = true
            return name
        end
    end
    -- Fallback: append a number
    local n = 1
    local base = BOSS_PREFIXES[math.random(#BOSS_PREFIXES)] .. BOSS_SUFFIXES[math.random(#BOSS_SUFFIXES)]
    while _usedBossNames[base .. " " .. n] do n = n + 1 end
    local name = base .. " " .. n
    _usedBossNames[name] = true
    return name
end

------------------------------------------------------------------------
-- CREATE THE FRAME
------------------------------------------------------------------------
local frame

local function EnsureFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "OLLDebugWindow", UIParent, "BackdropTemplate")
    frame:SetSize(320, 220)
    frame:SetPoint("CENTER", UIParent, "CENTER", 200, 100)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    frame:SetBackdropColor(0.1, 0.05, 0.05, 0.97)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetScript("OnMouseDown", function(self) ns.RaiseFrame(self) end)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SaveFramePosition("DebugWindow", self)
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() DebugWindow:Hide() end)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("|cffff4444Debug Mode|r")

    -- Warning label
    local warn = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    warn:SetPoint("TOP", title, "BOTTOM", 0, -6)
    warn:SetText("|cffff8800No loot counted. No history saved. No trading.|r")

    -- Status
    local status = frame:CreateFontString("OLLDebugStatus", "OVERLAY", "GameFontNormal")
    status:SetPoint("TOP", warn, "BOTTOM", 0, -14)
    status:SetText("|cff00ff00Debug Session Active|r")
    frame.statusText = status

    -- Loot count slider label
    local countLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -110)
    countLabel:SetText("Items to drop:")

    -- Loot count slider
    local slider = CreateFrame("Slider", "OLLDebugSlider", frame, "OptionsSliderTemplate")
    slider:SetPoint("LEFT", countLabel, "RIGHT", 10, 0)
    slider:SetSize(140, 17)
    slider:SetMinMaxValues(1, 5)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(2)
    slider.Low:SetText("1")
    slider.High:SetText("5")
    slider.Text:SetText("2")
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        self.Text:SetText(tostring(value))
    end)
    frame.slider = slider

    -- Drop Loot button
    local dropBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    dropBtn:SetSize(200, 30)
    dropBtn:SetPoint("TOP", slider, "BOTTOM", -40, -20)
    dropBtn:SetText("|cffff6600Drop Fake Loot|r")
    dropBtn:SetScript("OnClick", function()
        local count = math.floor(frame.slider:GetValue() + 0.5)
        DebugWindow:DropLoot(count)
    end)
    frame.dropBtn = dropBtn

    -- Info text
    local info = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("BOTTOM", frame, "BOTTOM", 0, 16)
    info:SetText("|cff666666Close window to end debug session.|r")

    -- OnHide — end debug session
    frame:SetScript("OnHide", function()
        ns.Session:EndDebugSession()
    end)

    ns.RestoreFramePosition("DebugWindow", frame)

    return frame
end

------------------------------------------------------------------------
-- SHOW
------------------------------------------------------------------------
function DebugWindow:Show()
    local f = EnsureFrame()

    -- Reset used boss names for new debug session
    _usedBossNames = {}

    -- Start debug session
    ns.Session:StartDebugSession()

    f.statusText:SetText("|cff00ff00Debug Session Active|r")
    f:Show()
end

------------------------------------------------------------------------
-- HIDE
------------------------------------------------------------------------
function DebugWindow:Hide()
    if frame and frame:IsShown() then
        frame:Hide() -- triggers OnHide → EndDebugSession
    end
end

------------------------------------------------------------------------
-- DROP LOOT
------------------------------------------------------------------------
function DebugWindow:DropLoot(count)
    if not ns.Session:IsActive() or not ns.Session.debugMode then
        ns.addon:Print("No debug session running.")
        return
    end

    count = count or 2
    local items = PickRandomItems(count)
    local bossName = GenerateBossName()

    -- Inject into session
    ns.Session:InjectDebugLoot(items, bossName)

    if frame then
        frame.statusText:SetText("|cff00ff00Dropped " .. #items .. " item(s) from " .. bossName .. "|r")
    end
end
