------------------------------------------------------------------------
-- OrderedLootList  –  UI/Theme.lua
-- Theme definitions and runtime switching.
-- Themes are player-local (stored in profile, never synced to group).
------------------------------------------------------------------------

local ns    = _G.OLL_NS
local Theme = {}
ns.Theme    = Theme

------------------------------------------------------------------------
-- Theme definitions
------------------------------------------------------------------------
local THEMES = {
    --------------------------------------------------------------------
    -- Basic – the original look
    --------------------------------------------------------------------
    Basic = {
        name = "Basic",

        -- Main frame backdrop
        frameBgColor        = { 0.05, 0.05, 0.10, 0.95 },
        frameBorderColor    = { 1.00, 1.00, 1.00, 1.00 }, -- natural gold

        -- Item / history row backdrop (RollFrame, HistoryFrame)
        rowBgColor          = { 0.08, 0.08, 0.15, 0.70 },
        rowBorderColor      = { 0.30, 0.30, 0.40, 0.60 },

        -- Timer bar
        timerBarBgColor     = { 0.10, 0.10, 0.10, 0.80 },
        timerBarFullColor   = { 0.20, 0.60, 1.00 },
        timerBarMidColor    = { 1.00, 0.60, 0.20 },
        timerBarLowColor    = { 1.00, 0.20, 0.20 },

        -- Dividers / separators
        dividerColor        = { 0.40, 0.40, 0.40, 0.60 },
        actionSepColor      = { 0.40, 0.40, 0.40, 0.50 },
        histSepColor        = { 0.40, 0.40, 0.40, 0.60 },

        -- LeaderFrame pool-row selection / hover textures
        selectedColor       = { 0.20, 0.50, 1.00, 0.25 },
        highlightColor      = { 1.00, 1.00, 1.00, 0.10 },

        -- Text markup hex colors (used in "|cffXXXXXX...|r" strings)
        sectionHeaderHex    = "ffd100",
        columnHeaderHex     = "ffd100",

        -- Misc text colors
        bossTextColor       = { 0.70, 0.70, 0.70 },
        countTextColor      = { 1.00, 0.82, 0.00 },

        -- DebugWindow background (distinct warm tint)
        debugBgColor        = { 0.10, 0.05, 0.05, 0.97 },
    },

    --------------------------------------------------------------------
    -- Midnight – Plumber-language interpretation of the Midnight expansion
    --
    -- Clean, high-contrast, restrained.  Backgrounds are near-void black
    -- with the barest ghost of indigo — structure is conveyed through
    -- value contrast, not saturated color.  Arcane purple exists only as
    -- a whisper in borders and interactive states.  Text is crisp and
    -- close to white.  Separators are ghost lines.  Timer colors are
    -- functional rather than decorative.
    --------------------------------------------------------------------
    Midnight = {
        name = "Midnight",

        -- Main frame backdrop: near-black, barely-there indigo cast
        frameBgColor        = { 0.04, 0.03, 0.09, 0.97 },
        frameBorderColor    = { 0.36, 0.30, 0.58, 0.88 }, -- muted slate-violet; present, not glowing

        -- Item / history row backdrop: low-alpha layering, no saturated hue
        rowBgColor          = { 0.07, 0.05, 0.13, 0.55 },
        rowBorderColor      = { 0.28, 0.22, 0.44, 0.40 },

        -- Timer bar: void-black bg; arcane hues muted to functional signals
        timerBarBgColor     = { 0.05, 0.04, 0.11, 0.95 },
        timerBarFullColor   = { 0.36, 0.16, 0.76 }, -- deep arcane indigo
        timerBarMidColor    = { 0.60, 0.22, 0.74 }, -- muted violet
        timerBarLowColor    = { 0.80, 0.16, 0.34 }, -- deep crimson — urgent, not neon

        -- Dividers / separators: ghost lines — barely-perceptible structure
        dividerColor        = { 0.32, 0.26, 0.50, 0.35 },
        actionSepColor      = { 0.28, 0.22, 0.44, 0.30 },
        histSepColor        = { 0.32, 0.26, 0.50, 0.35 },

        -- LeaderFrame pool-row selection / hover: understated feedback
        selectedColor       = { 0.26, 0.14, 0.54, 0.26 },
        highlightColor      = { 0.36, 0.28, 0.64, 0.08 },

        -- Text hex colors: high-contrast cool silver — clear hierarchy
        sectionHeaderHex    = "d4dff5",  -- crisp near-white with cool cast — primary level
        columnHeaderHex     = "9aaecc",  -- muted blue-gray — secondary level

        -- Misc text colors: near-white for readability; cool not warm
        bossTextColor       = { 0.84, 0.88, 0.96 }, -- near-white with cool cast
        countTextColor      = { 0.70, 0.78, 0.94 }, -- soft periwinkle silver

        -- DebugWindow background: same family, barely distinct from main
        debugBgColor        = { 0.05, 0.03, 0.10, 0.97 },
    },
}

------------------------------------------------------------------------
-- Returns a sorted list of all theme names (for UI dropdowns)
------------------------------------------------------------------------
function Theme:GetNames()
    local names = {}
    for k in pairs(THEMES) do
        tinsert(names, k)
    end
    table.sort(names)
    return names
end

------------------------------------------------------------------------
-- Returns the current theme table (falls back to Basic if unset)
------------------------------------------------------------------------
function Theme:GetCurrent()
    local name = (ns.db and ns.db.profile.theme) or "Basic"
    return THEMES[name] or THEMES.Basic
end

------------------------------------------------------------------------
-- Set the active theme by name, persist it, then apply to all frames
------------------------------------------------------------------------
function Theme:Set(name)
    if not THEMES[name] then return end
    if ns.db then
        ns.db.profile.theme = name
    end
    self:ApplyToAll()
end

------------------------------------------------------------------------
-- Push the current theme to every already-created frame
------------------------------------------------------------------------
function Theme:ApplyToAll()
    local theme = self:GetCurrent()

    if ns.LeaderFrame then
        ns.LeaderFrame:ApplyTheme(theme)
        if ns.LeaderFrame._frame and ns.LeaderFrame._frame:IsShown() then
            ns.LeaderFrame:Refresh()
        end
    end

    if ns.RollFrame then
        ns.RollFrame:ApplyTheme(theme)
    end

    if ns.HistoryFrame then
        ns.HistoryFrame:ApplyTheme(theme)
        if ns.HistoryFrame._frame and ns.HistoryFrame._frame:IsShown() then
            ns.HistoryFrame:Refresh()
        end
    end

    if ns.DebugWindow then
        ns.DebugWindow:ApplyTheme(theme)
    end
end
