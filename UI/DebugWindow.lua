------------------------------------------------------------------------
-- OrderedLootList  –  UI/DebugWindow.lua  (Ledger)
-- Debug/Test mode window for simulating loot sessions.  Keeps its warm
-- debugBgColor tint so it is visually distinct from the real frames.
------------------------------------------------------------------------

local ns = _G.OLL_NS

local DebugWindow = {}
ns.DebugWindow = DebugWindow

local FRAME_W  = 340
local FRAME_H  = 280
local HEADER_H = 44
local INSET    = 16

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

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

local QUALITY_COLORS = {
    [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee", [5] = "|cffff8000",
}

local function MakeFakeLink(item)
    local color = QUALITY_COLORS[item.quality] or "|cffffffff"
    return color .. "[" .. item.name .. "]|r"
end

local function PickRandomItems(count)
    local pool = {}
    for _, item in ipairs(FAKE_ITEMS) do tinsert(pool, item) end
    local picked = {}
    for _ = 1, math.min(count, #pool) do
        local idx = math.random(1, #pool)
        local item = pool[idx]
        tinsert(picked, {
            icon = item.icon, name = item.name, link = MakeFakeLink(item),
            quality = item.quality, id = item.id,
        })
        table.remove(pool, idx)
    end
    return picked
end

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
    for _ = 1, 20 do
        local name = BOSS_PREFIXES[math.random(#BOSS_PREFIXES)] .. BOSS_SUFFIXES[math.random(#BOSS_SUFFIXES)]
            .. " " .. BOSS_TITLES[math.random(#BOSS_TITLES)]
        if not _usedBossNames[name] then
            _usedBossNames[name] = true
            return name
        end
    end
    local n = 1
    local base = BOSS_PREFIXES[math.random(#BOSS_PREFIXES)] .. BOSS_SUFFIXES[math.random(#BOSS_SUFFIXES)]
    while _usedBossNames[base .. " " .. n] do n = n + 1 end
    local name = base .. " " .. n
    _usedBossNames[name] = true
    return name
end

function DebugWindow:PickRandomItems(count)
    return PickRandomItems(count)
end

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
local frame

local function MakeSliderRow(parent, label, minV, maxV, default, y)
    local theme = ns.Theme:GetCurrent()
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", INSET, y)
    lbl:SetText(ns.Track(label))
    lbl:SetTextColor(C(theme, "textMutedColor"))

    local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    slider:SetPoint("LEFT", parent, "LEFT", INSET + 110, 0)
    slider:SetPoint("TOP", lbl, "TOP", 0, 4)
    slider:SetSize(150, 17)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(default)
    slider.Low:SetText(tostring(minV))
    slider.High:SetText(tostring(maxV))
    slider.Text:SetText(tostring(default))
    slider:SetScript("OnValueChanged", function(s, value)
        value = math.floor(value + 0.5)
        s.Text:SetText(tostring(value))
    end)

    local val = parent:CreateFontString(nil, "OVERLAY")
    val:SetFontObject(ns.Ledger.Fonts.OLLFontNumberSmall)
    val:SetPoint("LEFT", slider, "RIGHT", 14, 0)
    val:SetText(tostring(default))
    val:SetTextColor(C(theme, "accentHiColor"))
    slider:HookScript("OnValueChanged", function(_, value) val:SetText(tostring(math.floor(value + 0.5))) end)
    slider.valueText, slider.label = val, lbl
    return slider
end

local function EnsureFrame()
    if frame then return frame end
    local theme = ns.Theme:GetCurrent()

    frame = ns.MakeLedgerFrame("OLLDebugWindow", FRAME_W, FRAME_H, "DebugWindow", { strata = "HIGH", x = 200, y = 100 })
    -- warm tint instead of the standard body colour
    function frame:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropColor(C(th, "debugBgColor"))
        self:SetBackdropBorderColor(C(th, "timerBarLowColor"))
    end
    frame:ApplyTheme(theme)

    frame.header = ns.MakeHeaderBar(frame, "Debug Mode", nil, { height = HEADER_H, onClose = function() DebugWindow:Hide() end })
    frame.header.pill:SetStatus("Debug", nil, theme.timerBarMidColor)
    frame.header.pill:Show()

    local warn = frame:CreateFontString(nil, "OVERLAY")
    warn:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    warn:SetPoint("TOPLEFT", frame, "TOPLEFT", INSET, -(HEADER_H + 12))
    warn:SetPoint("RIGHT", frame, "RIGHT", -INSET, 0)
    warn:SetJustifyH("LEFT")
    warn:SetText("No loot counted. No history saved. No trading.")
    frame.warn = warn

    local status = frame:CreateFontString("OLLDebugStatus", "OVERLAY")
    status:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    status:SetPoint("TOPLEFT", warn, "BOTTOMLEFT", 0, -6)
    status:SetPoint("RIGHT", frame, "RIGHT", -INSET, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)
    status:SetText("Debug session active")
    frame.statusText = status

    frame.slider     = MakeSliderRow(frame, "Items to drop", 1, 5, 2, -(HEADER_H + 62))
    frame.fakeSlider = MakeSliderRow(frame, "Fake players",  0, 5, 0, -(HEADER_H + 100))

    local footer = ns.MakeBar(frame, 56, "barBgColorAlt", "TOP")
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 2)
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    local dropBtn = ns.MakeButton(footer, "primary", "Drop fake loot", 160, 32)
    dropBtn:SetPoint("LEFT", footer, "LEFT", INSET - 2, 0)
    dropBtn:SetScript("OnClick", function()
        DebugWindow:DropLoot(math.floor(frame.slider:GetValue() + 0.5))
    end)
    frame.dropBtn = dropBtn
    local info = footer:CreateFontString(nil, "OVERLAY")
    info:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    info:SetPoint("RIGHT", footer, "RIGHT", -(INSET - 2), 0)
    info:SetText("Close to end the debug session")
    frame.info = info

    -- OnHide: end the debug session on an explicit close only.  OnHide also
    -- fires on every descendant when UIParent hides (cinematics, pet
    -- battles); the frame comes back with UIParent, so the session must too.
    frame:SetScript("OnHide", function()
        if not UIParent:IsShown() then return end
        ns.Session:EndDebugSession()
    end)

    DebugWindow:ApplyTheme(theme)
    return frame
end

------------------------------------------------------------------------
-- Theme
------------------------------------------------------------------------
function DebugWindow:ApplyTheme(theme)
    if not frame then return end
    theme = theme or ns.Theme:GetCurrent()
    frame:ApplyTheme(theme)
    frame.warn:SetTextColor(C(theme, "timerBarMidColor"))
    frame.statusText:SetTextColor(C(theme, "timerBarFullColor"))
    frame.info:SetTextColor(C(theme, "textDimColor"))
    for _, s in ipairs({ frame.slider, frame.fakeSlider }) do
        s.label:SetTextColor(C(theme, "textMutedColor"))
        s.valueText:SetTextColor(C(theme, "accentHiColor"))
    end
end

------------------------------------------------------------------------
-- Show / Hide
------------------------------------------------------------------------
function DebugWindow:Show()
    local f = EnsureFrame()
    if f:IsShown() then ns.RaiseFrame(f); return end
    _usedBossNames = {}
    ns.Session:StartDebugSession()
    if not ns.Session.debugMode then return end   -- refused (not leader)
    f.statusText:SetText("Debug session active")
    f:Show()
    ns.RaiseFrame(f)
end

function DebugWindow:Hide()
    if frame and frame:IsShown() then
        frame:Hide() -- triggers OnHide → EndDebugSession
    end
end

------------------------------------------------------------------------
-- Drop loot
------------------------------------------------------------------------
function DebugWindow:DropLoot(count)
    if not ns.Session:IsActive() or not ns.Session.debugMode then
        ns.ChatPrint("Normal", "No debug session running.")
        return
    end
    count = count or 2
    local items = PickRandomItems(count)
    local bossName = GenerateBossName()
    local fakeCount = frame and math.floor(frame.fakeSlider:GetValue() + 0.5) or 0
    ns.Session:InjectDebugLoot(items, bossName, fakeCount)
    if frame then
        frame.statusText:SetText("Dropped " .. #items .. (#items == 1 and " item" or " items") .. " from " .. bossName)
    end
end
