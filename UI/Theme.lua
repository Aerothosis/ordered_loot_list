------------------------------------------------------------------------
-- OrderedLootList  –  UI/Theme.lua
-- Theme definitions and runtime switching.
-- Themes are player-local (stored in profile, never synced to group).
--
-- Every key listed for "Ledger" exists in all three themes so no frame's
-- ApplyTheme can read a nil.  Colours are { r, g, b [, a] } tables in
-- 0..1; the two *Hex keys are 6-char hex strings for "|cffXXXXXX" markup.
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
        panelBgColor        = { 0.04, 0.04, 0.08, 1.00 },
        headerTopColor      = { 0.10, 0.10, 0.18, 1.00 },
        headerBotColor      = { 0.06, 0.06, 0.12, 1.00 },
        barBgColor          = { 0.07, 0.07, 0.13, 1.00 },
        barBgColorAlt       = { 0.08, 0.08, 0.14, 1.00 },

        -- Item / history row backdrop (RollFrame, HistoryFrame)
        rowBgColor          = { 0.08, 0.08, 0.15, 0.70 },
        rowBorderColor      = { 0.30, 0.30, 0.40, 0.60 },
        strokeColor         = { 0.40, 0.40, 0.50, 1.00 },
        strokeDimColor      = { 0.25, 0.25, 0.32, 1.00 },

        -- Accent / primary button
        accentColor         = { 1.00, 0.82, 0.00 },
        accentHiColor       = { 1.00, 0.90, 0.40 },
        primaryBtnTop       = { 0.95, 0.78, 0.20 },
        primaryBtnBot       = { 0.80, 0.62, 0.10 },
        primaryBtnTextColor = { 0.10, 0.08, 0.02 },

        -- Timer bar
        timerBarBgColor     = { 0.10, 0.10, 0.10, 0.80 },
        timerBarFullColor   = { 0.20, 0.60, 1.00 },
        timerBarMidColor    = { 1.00, 0.60, 0.20 },
        timerBarLowColor    = { 1.00, 0.20, 0.20 },

        -- Roll-choice colours, keyed by roll-option priority (1 = highest)
        choiceColors        = {
            { 0.20, 0.90, 0.20 }, { 1.00, 0.82, 0.00 }, { 1.00, 0.55, 0.20 },
            { 0.30, 0.65, 1.00 }, { 0.70, 0.50, 0.95 }, { 0.95, 0.50, 0.70 },
        },
        choicePassColor     = { 0.60, 0.60, 0.60 },
        choiceWaitColor     = { 0.40, 0.40, 0.40 },

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

        -- Text hierarchy
        textColor           = { 1.00, 1.00, 1.00 },
        textMutedColor      = { 0.70, 0.70, 0.70 },
        textDimColor        = { 0.50, 0.50, 0.50 },

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
        panelBgColor        = { 0.03, 0.02, 0.07, 1.00 },
        headerTopColor      = { 0.09, 0.07, 0.16, 1.00 },
        headerBotColor      = { 0.06, 0.04, 0.11, 1.00 },
        barBgColor          = { 0.05, 0.04, 0.10, 1.00 },
        barBgColorAlt       = { 0.06, 0.05, 0.12, 1.00 },

        -- Item / history row backdrop: low-alpha layering, no saturated hue
        rowBgColor          = { 0.07, 0.05, 0.13, 0.55 },
        rowBorderColor      = { 0.28, 0.22, 0.44, 0.40 },
        strokeColor         = { 0.34, 0.28, 0.52, 1.00 },
        strokeDimColor      = { 0.20, 0.16, 0.30, 1.00 },

        -- Accent / primary button: muted arcane violet
        accentColor         = { 0.56, 0.40, 0.90 },
        accentHiColor       = { 0.78, 0.68, 0.98 },
        primaryBtnTop       = { 0.52, 0.34, 0.86 },
        primaryBtnBot       = { 0.38, 0.22, 0.68 },
        primaryBtnTextColor = { 0.96, 0.94, 1.00 },

        -- Timer bar: void-black bg; arcane hues muted to functional signals
        timerBarBgColor     = { 0.05, 0.04, 0.11, 0.95 },
        timerBarFullColor   = { 0.36, 0.16, 0.76 }, -- deep arcane indigo
        timerBarMidColor    = { 0.60, 0.22, 0.74 }, -- muted violet
        timerBarLowColor    = { 0.80, 0.16, 0.34 }, -- deep crimson — urgent, not neon

        choiceColors        = {
            { 0.45, 0.78, 0.62 }, { 0.82, 0.68, 0.36 }, { 0.82, 0.52, 0.30 },
            { 0.36, 0.62, 0.82 }, { 0.62, 0.48, 0.86 }, { 0.80, 0.48, 0.66 },
        },
        choicePassColor     = { 0.50, 0.48, 0.60 },
        choiceWaitColor     = { 0.30, 0.28, 0.38 },

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

        textColor           = { 0.93, 0.94, 0.98 },
        textMutedColor      = { 0.66, 0.70, 0.82 },
        textDimColor        = { 0.42, 0.44, 0.56 },

        -- Misc text colors: near-white for readability; cool not warm
        bossTextColor       = { 0.84, 0.88, 0.96 }, -- near-white with cool cast
        countTextColor      = { 0.70, 0.78, 0.94 }, -- soft periwinkle silver

        -- DebugWindow background: same family, barely distinct from main
        debugBgColor        = { 0.05, 0.03, 0.10, 0.97 },
    },

    --------------------------------------------------------------------
    -- Ledger – the 1.3 overhaul.  Near-black surfaces, one brass accent,
    -- three-level text hierarchy; item-quality colour only on names and
    -- 2px edge ticks.  Values are the design tokens verbatim.
    --------------------------------------------------------------------
    Ledger = {
        name = "Ledger",

        -- Surfaces
        frameBgColor        = { 0.043, 0.051, 0.063, 0.97 },  -- #0b0d10
        panelBgColor        = { 0.043, 0.051, 0.063, 1.00 },  -- #0b0d10
        headerTopColor      = { 0.086, 0.102, 0.125, 1.00 },  -- #161a20
        headerBotColor      = { 0.067, 0.078, 0.102, 1.00 },  -- #11141a
        barBgColor          = { 0.059, 0.071, 0.086, 1.00 },  -- #0f1216
        barBgColorAlt       = { 0.067, 0.078, 0.102, 1.00 },  -- #11141a
        rowBgColor          = { 0.078, 0.094, 0.118, 1.00 },  -- #14181e
        frameBorderColor    = { 0.788, 0.635, 0.153, 0.35 },  -- #c9a227 @ 35%

        -- Lines
        dividerColor        = { 0.110, 0.125, 0.153, 1.00 },  -- #1c2027
        actionSepColor      = { 0.110, 0.125, 0.153, 1.00 },  -- #1c2027
        histSepColor        = { 0.082, 0.094, 0.118, 1.00 },  -- #15181e
        rowBorderColor      = { 0.169, 0.188, 0.220, 1.00 },  -- #2b3038
        strokeColor         = { 0.169, 0.188, 0.220, 1.00 },  -- #2b3038
        strokeDimColor      = { 0.133, 0.149, 0.176, 1.00 },  -- #22262d

        -- Accent and primary button
        accentColor         = { 0.788, 0.635, 0.153 },        -- #c9a227
        accentHiColor       = { 0.890, 0.741, 0.341 },        -- #e3bd57
        primaryBtnTop       = { 0.851, 0.698, 0.235 },        -- #d9b23c
        primaryBtnBot       = { 0.722, 0.565, 0.122 },        -- #b8901f
        primaryBtnTextColor = { 0.090, 0.075, 0.039 },        -- #17130a — never white

        -- Status and choice
        timerBarBgColor     = { 0.110, 0.125, 0.153, 1.00 },  -- #1c2027
        timerBarFullColor   = { 0.341, 0.788, 0.541 },        -- #57c98a  >10s / Need / Ready
        timerBarMidColor    = { 0.851, 0.647, 0.231 },        -- #d9a53b  5–10s / Greed / Outdated
        timerBarLowColor    = { 0.788, 0.282, 0.247 },        -- #c9483f  <5s / Missing / Delete
        choiceColors        = {
            { 0.341, 0.788, 0.541 },  -- 1 #57c98a
            { 0.851, 0.647, 0.231 },  -- 2 #d9a53b
            { 0.851, 0.498, 0.231 },  -- 3 #d97f3b
            { 0.302, 0.624, 0.780 },  -- 4 #4d9fc7
            { 0.616, 0.482, 0.816 },  -- 5 #9d7bd0
            { 0.780, 0.482, 0.627 },  -- 6 #c77ba0
        },
        choicePassColor     = { 0.435, 0.463, 0.514 },        -- #6f7683
        choiceWaitColor     = { 0.255, 0.275, 0.310 },        -- #41464f

        -- Text
        textColor           = { 0.910, 0.914, 0.925 },        -- #e8e9ec
        textMutedColor      = { 0.435, 0.463, 0.514 },        -- #6f7683
        textDimColor        = { 0.255, 0.275, 0.310 },        -- #41464f
        bossTextColor       = { 0.435, 0.463, 0.514 },        -- #6f7683
        countTextColor      = { 0.890, 0.741, 0.341 },        -- #e3bd57
        sectionHeaderHex    = "c9a227",
        columnHeaderHex     = "565c67",

        -- Selection and hover
        selectedColor       = { 0.788, 0.635, 0.153, 0.07 },  -- #c9a227 @ 7%
        highlightColor      = { 1.000, 1.000, 1.000, 0.04 },  -- white @ 4%
        debugBgColor        = { 0.063, 0.055, 0.043, 0.97 },  -- #100e0b keeps its warm tint
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
-- Returns the current theme table (falls back to Ledger if unset)
------------------------------------------------------------------------
function Theme:GetCurrent()
    local name = (ns.db and ns.db.profile.theme) or "Ledger"
    return THEMES[name] or THEMES.Ledger
end

------------------------------------------------------------------------
-- Colour helper: theme.choiceColors[priority], or the Pass / Wait colour.
-- choice may be a roll-option name, a roll-option table, "Pass" or nil.
------------------------------------------------------------------------
function Theme:ChoiceColor(choice, theme)
    theme = theme or self:GetCurrent()
    if choice == nil or choice == "" then return theme.choiceWaitColor end
    if choice == "Pass" or choice == "Passed" then return theme.choicePassColor end
    local priority
    if type(choice) == "table" then
        priority = choice.priority
    elseif ns.Session and ns.Session._FindRollOption then
        local opt = ns.Session:_FindRollOption(choice)
        priority = opt and opt.priority
    end
    return theme.choiceColors[priority or 1] or theme.choiceColors[1]
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

    -- Shared font objects and primitives first, frames after
    if ns.Ledger and ns.Ledger.ApplyTheme then
        ns.Ledger.ApplyTheme(theme)
    end

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

    if ns.SessionHistoryFrame then
        ns.SessionHistoryFrame:ApplyTheme(theme)
        if ns.SessionHistoryFrame._frame and ns.SessionHistoryFrame._frame:IsShown() then
            ns.SessionHistoryFrame:Refresh()
        end
    end

    if ns.SessionResumeFrame then
        ns.SessionResumeFrame:ApplyTheme(theme)
    end

    if ns.CheckPartyFrame and ns.CheckPartyFrame.ApplyTheme then
        ns.CheckPartyFrame:ApplyTheme(theme)
    end
end
