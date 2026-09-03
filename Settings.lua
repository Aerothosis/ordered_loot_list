------------------------------------------------------------------------
-- OrderedLootList  –  Settings.lua  (Ledger)
-- The addon's own settings window: 860x600, 196px sidebar, five sections
-- (General, My Characters, Session Rules, Roll Options, Roster).  Built
-- lazily on first Open(); every control re-reads its saved value through
-- a Refresh path instead of rebuilding the window.
--
-- The Blizzard AddOns panel is reduced to a launcher.  AceDBOptions still
-- backs the profile picker in the title bar.
--
-- No functional change from the AceConfig version: every saved key and
-- every set-handler side effect (session sync calls, COUNT_SYNC, pending
-- flags) is preserved verbatim; only the widgets and layout differ.
------------------------------------------------------------------------

local ns       = _G.OLL_NS

local Settings = {}
ns.Settings    = Settings

-- Runtime-only state (lifetimes unchanged from the AceConfig version)
Settings._lootCountSortField   = "count"
Settings._lootCountSortAsc     = false
Settings._csvExportPopup       = nil   -- lazy-created CSV export popup
Settings._pendingLootCountSync = false -- true if manual edits made during session
Settings._addCharName          = nil
Settings._editedRows           = {}    -- [name] = true, edited locally since last sync
Settings._addLootCountPlayer   = nil   -- Add-player picker selection (Roster)

Settings._frame   = nil
Settings._panes   = {}
Settings._section = nil

local SECTIONS   = { "general", "characters", "session", "rollOptions", "roster" }
local ROSTER_TABS = { "counts", "links", "rules" }

local WHITE8x8 = "Interface\\Buttons\\WHITE8x8"
local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end
local function hexrgb(h)
    return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
end

------------------------------------------------------------------------
-- Shared predicates (watch-out #4: one helper per gate so rows never drift)
------------------------------------------------------------------------
local function IsSessionActive()
    return ns.Session and ns.Session:IsActive() or false
end
local function IsRolling()
    return ns.Session and (ns.Session.state == ns.Session.STATE_ROLLING
        or ns.Session.state == ns.Session.STATE_RESOLVING) or false
end
-- Loot-count edits: anyone when idle, only the session leader while active
local function CanEditCounts()
    return not IsSessionActive() or ns.IsSessionLeader()
end

------------------------------------------------------------------------
-- Roll options access (unchanged)
------------------------------------------------------------------------
function Settings:GetRollOptions()
    return ns.db.profile.rollOptions or ns.DEFAULT_ROLL_OPTIONS
end

function Settings:SetRollOptions(opts)
    ns.db.profile.rollOptions = opts
end

-- Ensure we have a mutable copy of roll options (watch-out #7)
function Settings:_EnsureCustomOpts()
    if not ns.db.profile.rollOptions then
        ns.db.profile.rollOptions = {}
        for _, o in ipairs(ns.DEFAULT_ROLL_OPTIONS) do
            tinsert(ns.db.profile.rollOptions, {
                name = o.name,
                priority = o.priority,
                countsForLoot = o.countsForLoot,
                colorR = o.colorR,
                colorG = o.colorG,
                colorB = o.colorB,
            })
        end
    end
    return ns.db.profile.rollOptions
end

------------------------------------------------------------------------
-- Static popups
------------------------------------------------------------------------
StaticPopupDialogs["OLL_HOLDW_CONFIRM"] = {
    text         = "Enable Hold 'W' Mode?\n\nAll loot will be silently auto-passed and the roll frame will not appear until you disable this setting.",
    button1      = "Enable",
    button2      = "Cancel",
    OnAccept     = function()
        ns.db.profile.holdWMode = true
        Settings:RefreshSection("general")
    end,
    OnCancel     = function() Settings:RefreshSection("general") end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["OLL_SETTINGS_REMOVE_CHAR"] = {
    text         = "Remove %s from your characters?\n\nThis character currently holds loot count %d.",
    button1      = "Remove",
    button2      = "Cancel",
    OnAccept     = function(_, data)
        ns.PlayerLinks:RemoveMyCharacter(data)
        Settings:RefreshSection("characters")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["OLL_SETTINGS_DELETE_TIER"] = {
    text         = "Delete the roll option \"%s\"?",
    button1      = "Delete",
    button2      = "Cancel",
    OnAccept     = function(_, idx)
        table.remove(Settings:_EnsureCustomOpts(), idx)
        Settings:_RenumberRollOptions()
        Settings:RefreshSection("rollOptions")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["OLL_SETTINGS_RESTORE_TIERS"] = {
    text         = "Restore the default roll options?\n\nYour custom tiers, labels and colours are discarded.",
    button1      = "Restore",
    button2      = "Cancel",
    OnAccept     = function()
        ns.db.profile.rollOptions = nil
        Settings:RefreshSection("rollOptions")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["OLL_SETTINGS_REMOVE_COUNT"] = {
    text         = "Remove %s from the loot count list?",
    button1      = "Remove",
    button2      = "Cancel",
    OnAccept     = function(_, name)
        local counts = ns.db.global.lootCounts
        counts[name] = nil
        if IsSessionActive() then
            Settings._pendingLootCountSync = true
            Settings._editedRows[name] = nil
        end
        Settings:RefreshSection("roster")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["OLL_SETTINGS_RESET_ALL_COUNTS"] = {
    text         = "Are you sure you want to reset all loot counts?",
    button1      = "Reset all",
    button2      = "Cancel",
    OnAccept     = function()
        ns.LootCount:ResetAll()
        ns.ChatPrint("Normal", "All loot counts have been reset.")
        if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
            ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC,
                { counts = ns.LootCount:GetCountsTable() })
        end
        Settings._pendingLootCountSync = false
        wipe(Settings._editedRows)
        Settings:RefreshSection("roster")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["OLL_SETTINGS_NEW_PROFILE"] = {
    text         = "New profile name:",
    button1      = "Create",
    button2      = "Cancel",
    hasEditBox   = true,
    OnAccept     = function(self)
        local name = self.editBox:GetText():trim()
        if name ~= "" then ns.db:SetProfile(name) end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        local name = parent.editBox:GetText():trim()
        if name ~= "" then ns.db:SetProfile(name) end
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["OLL_SETTINGS_RESET_PROFILE"] = {
    text         = "Reset the profile \"%s\" to defaults?\n\nEvery setting in this window returns to its default value.",
    button1      = "Reset",
    button2      = "Cancel",
    OnAccept     = function() ns.db:ResetProfile() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

------------------------------------------------------------------------
-- Public entry points
------------------------------------------------------------------------
-- section: "general" | "characters" | "session" | "rollOptions" | "roster"
--          optionally "roster.counts" | "roster.links" | "roster.rules"
function Settings:OpenConfig(section)
    self:Open(section)
end

function Settings:Open(section)
    local f = self:GetFrame()
    if section then
        local base, sub = section:match("^(%w+)%.(%w+)$")
        if base then
            section = base
            if base == "roster" then ns.db.profile.settingsRosterTab = sub end
        end
    end
    section = section or ns.db.profile.settingsSection or "general"
    if not self._panes[section] then section = "general" end
    ns.RaiseFrame(f)
    f:Show()
    self:SelectSection(section)
end

function Settings:Toggle()
    if self._frame and self._frame:IsShown() then self._frame:Hide() else self:Open() end
end

function Settings:Hide()
    if self._frame then self._frame:Hide() end
end

function Settings:IsShown()
    return self._frame and self._frame:IsShown()
end

-- Re-read every row of one section.  Cheap: no frames are created.
function Settings:RefreshSection(key)
    if not self._frame or not self._frame:IsShown() then return end
    local pane = self._panes[key]
    if not pane then return end
    if key ~= self._section then return end
    pane:Refresh()
    self:_Restack()
end

-- Re-read one Roster row (count, badges, stepper stroke)
function Settings:RefreshRow(name)
    if not self._frame or not self._frame:IsShown() then return end
    local pane = self._panes.roster
    if pane and pane.RefreshRow then pane:RefreshRow(name) end
end

function Settings:RefreshAll()
    if not self._frame or not self._frame:IsShown() then return end
    self:_RefreshChrome()
    self:RefreshSection(self._section)
end

------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------
local FRAME_W, FRAME_H = 860, 600
local SIDEBAR_W        = 196
local HEADER_H         = 44
local PANE_PAD_TOP     = 18
local PANE_PAD_SIDE    = 24
local PANE_PAD_BOTTOM  = 24

function Settings:GetFrame()
    if self._frame then return self._frame end
    local theme = ns.Theme:GetCurrent()

    local f = ns.MakeLedgerFrame("OLLSettingsFrame", FRAME_W, FRAME_H, "SettingsFrame",
        { resizable = true, minW = 680, minH = 460 })
    tinsert(UISpecialFrames, "OLLSettingsFrame")
    self._frame = f

    -- Title bar with the profile picker
    local header = ns.MakeHeaderBar(f, "Settings", nil, { height = HEADER_H, onClose = function() f:Hide() end })
    f.header = header
    self:_BuildProfilePicker(header)

    -- Sidebar
    local nav = ns.MakeSettingsNav(f, SIDEBAR_W, {
        { header = "You", items = {
            { key = "general",    label = "General" },
            { key = "characters", label = "My Characters" },
        } },
        { header = "Session leader only", items = {
            { key = "session",     label = "Session Rules" },
            { key = "rollOptions", label = "Roll Options" },
            { key = "roster",      label = "Roster", badge = 0 },
        } },
    }, function(key) Settings:SelectSection(key) end)
    nav:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_H + 2))
    nav:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
    f.nav = nav

    -- Sidebar footer: Debug / Test Mode + version
    local dbg = ns.MakeButton(nav.footer, "outline", "Debug / Test Mode", SIDEBAR_W - 33, 26)
    dbg:SetPoint("TOPLEFT", nav.footer, "TOPLEFT", 16, -10)
    dbg:SetScript("OnClick", function() if ns.DebugWindow then ns.DebugWindow:Show() end end)
    f.debugBtn = dbg
    local ver = nav.footer:CreateFontString(nil, "OVERLAY")
    ver:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    ver:SetPoint("TOPLEFT", dbg, "BOTTOMLEFT", 0, -10)
    ver:SetText("V" .. (C_AddOns.GetAddOnMetadata(ns.ADDON_NAME, "Version") or ns.VERSION or "?"))
    f.versionText = ver

    -- Content area (right of the sidebar)
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.content = content

    -- Roster sub-tab strip (fixed) and action bar (fixed); the pane scrolls between them
    self:_BuildRosterChrome(content)

    local sf = CreateFrame("ScrollFrame", nil, content)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(s, delta)
        local cur, maxV = s:GetVerticalScroll(), s:GetVerticalScrollRange()
        s:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 40)))
    end)
    f.scroll = sf
    local sc = CreateFrame("Frame", nil, sf)
    sc:SetSize(1, 1)
    sf:SetScrollChild(sc)
    f.scrollChild = sc
    sf:SetScript("OnSizeChanged", function(s, w)
        sc:SetWidth(math.max(1, w))
        Settings:_Restack()
    end)
    -- Section cross-fade (100ms)
    local ag = sc:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0); a:SetToAlpha(1); a:SetDuration(0.10)
    sc._fade = ag

    -- Panes
    self._panes.general     = self:_BuildGeneralPane(sc)
    self._panes.characters  = self:_BuildCharactersPane(sc)
    self._panes.session     = self:_BuildSessionPane(sc)
    self._panes.rollOptions = self:_BuildRollOptionsPane(sc)
    self._panes.roster      = self:_BuildRosterPane(sc)
    for _, key in ipairs(SECTIONS) do
        local p = self._panes[key]
        p:SetPoint("TOPLEFT", sc, "TOPLEFT", PANE_PAD_SIDE, -PANE_PAD_TOP)
        p:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -PANE_PAD_SIDE, -PANE_PAD_TOP)
        p:Hide()
    end

    self:_LayoutContent()

    f:HookScript("OnShow", function()
        Settings:_InstallLiveHooks()
        Settings:RefreshAll()
    end)

    function f:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropColor(C(th, "frameBgColor"))
        self:SetBackdropBorderColor(C(th, "frameBorderColor"))
        if self._grip then self._grip:SetVertexColor(C(th, "textDimColor")) end
        Settings:ApplyTheme(th)
    end

    self:ApplyTheme(theme)
    return f
end

-- Anchors the scroll frame between the (optional) strip and action bar
function Settings:_LayoutContent()
    local f = self._frame
    local top = f.rosterStrip:IsShown() and 34 or 0
    local bottom = f.rosterBar:IsShown() and 52 or 0
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -top)
    f.scroll:SetPoint("BOTTOMRIGHT", f.content, "BOTTOMRIGHT", 0, bottom)
    f.scrollChild:SetWidth(math.max(1, f.scroll:GetWidth()))
end

function Settings:SelectSection(key)
    local f = self._frame
    local changed = (self._section ~= key)
    self._section = key
    ns.db.profile.settingsSection = key
    f.nav:Select(key)
    for k, p in pairs(self._panes) do
        if k == key then p:Show() else p:Hide() end
    end
    local roster = (key == "roster")
    f.rosterStrip:SetShown(roster)
    self:_LayoutContent()
    f.scroll:SetVerticalScroll(0)
    self:_RefreshChrome()
    self._panes[key]:Refresh()
    self:_Restack()
    if changed and not InCombatLockdown() then
        f.scrollChild._fade:Stop(); f.scrollChild._fade:Play()
    end
end

-- Stack the active pane's blocks and size the scroll child
function Settings:_Restack()
    local f = self._frame
    if not f or not self._section then return end
    local pane = self._panes[self._section]
    if not pane then return end
    local w = f.scroll:GetWidth() - PANE_PAD_SIDE * 2
    if w <= 0 then return end
    pane:SetWidth(w)
    local h = pane:Stack(w)
    f.scrollChild:SetHeight(h + PANE_PAD_TOP + PANE_PAD_BOTTOM)
end

-- Title-bar profile picker, nav badge, roster action bar state
function Settings:_RefreshChrome()
    local f = self._frame
    if not f then return end
    f.profileBtn.value:SetText(ns.db:GetCurrentProfile() or "Default")
    f.profileBtn:SetWidth(f.profileBtn.label:GetStringWidth() + f.profileBtn.value:GetStringWidth() + 46)
    local counts = ns.db.global.lootCounts or {}
    local n = 0
    for _ in pairs(counts) do n = n + 1 end
    f.nav:SetBadge("roster", n)
    if self._panes.roster and self._panes.roster.RefreshChrome then self._panes.roster:RefreshChrome() end
end

function Settings:ApplyTheme(theme)
    theme = theme or ns.Theme:GetCurrent()
    local f = self._frame
    if not f then return end
    f.versionText:SetTextColor(hexrgb("565c67"))
    f.debugBtn:SetStrokeColor({ theme.timerBarLowColor[1], theme.timerBarLowColor[2], theme.timerBarLowColor[3], 0.35 })
    f.debugBtn._text:SetTextColor(C(theme, "timerBarLowColor"))
    if f.profileBtn and f.profileBtn.ApplyThemeExtra then f.profileBtn:ApplyThemeExtra(theme) end
    for _, p in pairs(self._panes) do
        if p.ApplyTheme then p:ApplyTheme(theme) end
    end
    if f.rosterStrip and f.rosterStrip.ApplyTheme then f.rosterStrip:ApplyTheme(theme) end
    if f.rosterBar and f.rosterBar.ApplyTheme then f.rosterBar:ApplyTheme(theme) end
    if self._csvExportPopup and self._csvExportPopup.ApplyThemeExtra then self._csvExportPopup:ApplyThemeExtra(theme) end
end

------------------------------------------------------------------------
-- Live external changes: COUNT_SYNC, session start/end, profile switch.
-- LeaderFrame:Refresh already fires on every session transition, so a
-- post-hook on it (and on Comm:HandleCountSync) is the cheapest signal.
------------------------------------------------------------------------
function Settings:_InstallLiveHooks()
    if self._hooksInstalled then return end
    self._hooksInstalled = true
    if ns.LeaderFrame and ns.LeaderFrame.Refresh then
        hooksecurefunc(ns.LeaderFrame, "Refresh", function() Settings:_ScheduleLiveRefresh() end)
    end
    if ns.Comm and ns.Comm.HandleCountSync then
        hooksecurefunc(ns.Comm, "HandleCountSync", function() Settings:_ScheduleLiveRefresh() end)
    end
    if ns.db and ns.db.RegisterCallback then
        local function onProfile()
            if ns.Theme then ns.Theme:ApplyToAll() end
            Settings:RefreshAll()
        end
        ns.db.RegisterCallback(Settings, "OnProfileChanged", onProfile)
        ns.db.RegisterCallback(Settings, "OnProfileCopied",  onProfile)
        ns.db.RegisterCallback(Settings, "OnProfileReset",   onProfile)
    end
end

function Settings:_ScheduleLiveRefresh()
    if not self._frame or not self._frame:IsShown() or self._liveRefreshPending then return end
    self._liveRefreshPending = true
    C_Timer.After(0.15, function()
        Settings._liveRefreshPending = false
        Settings:RefreshAll()
    end)
end

------------------------------------------------------------------------
-- Profile picker (title bar): PROFILE <name> v  -> menu
------------------------------------------------------------------------
function Settings:_BuildProfilePicker(header)
    local b = ns.MakeButton(header, "outline", "", 160, 26)
    b:SetPoint("RIGHT", header.closeBtn, "LEFT", -10, 0)
    b._text:Hide()
    b.label = b:CreateFontString(nil, "OVERLAY")
    b.label:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    b.label:SetPoint("LEFT", b, "LEFT", 10, 0)
    b.label:SetText(ns.Track("Profile"))
    b.value = b:CreateFontString(nil, "OVERLAY")
    b.value:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    b.value:SetPoint("LEFT", b.label, "RIGHT", 8, 0)
    b.caret = b:CreateFontString(nil, "OVERLAY")
    b.caret:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    b.caret:SetPoint("RIGHT", b, "RIGHT", -10, 0)
    b.caret:SetText("v")
    function b:ApplyThemeExtra(th)
        self.label:SetTextColor(hexrgb("6f7683"))
        self.value:SetTextColor(hexrgb("c2c7d0"))
        self.caret:SetTextColor(C(th, "textMutedColor"))
    end
    b:SetScript("OnClick", function(btn)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        MenuUtil.CreateContextMenu(btn, function(_, root)
            local current = ns.db:GetCurrentProfile()
            local profiles = ns.db:GetProfiles()
            table.sort(profiles)
            for _, name in ipairs(profiles) do
                root:CreateRadio(name, function() return ns.db:GetCurrentProfile() == name end,
                    function() ns.db:SetProfile(name) end)
            end
            root:CreateDivider()
            root:CreateButton("New profile...", function() StaticPopup_Show("OLL_SETTINGS_NEW_PROFILE") end)
            local copy = root:CreateButton("Copy from...")
            local any = false
            for _, name in ipairs(profiles) do
                if name ~= current then
                    any = true
                    copy:CreateButton(name, function() ns.db:CopyProfile(name) end)
                end
            end
            if not any then copy:CreateTitle("No other profiles") end
            root:CreateButton("Reset profile", function()
                StaticPopup_Show("OLL_SETTINGS_RESET_PROFILE", ns.db:GetCurrentProfile())
            end)
        end)
    end)
    self._frame.profileBtn = b
    b:ApplyThemeExtra(ns.Theme:GetCurrent())
end

------------------------------------------------------------------------
-- Pane scaffolding: a frame that stacks blocks vertically.
--   pane:Add(block, gapBefore)   block is any frame; block.Layout(w) and
--                                block:GetHeight() are used when stacking
--   pane:Stack(w) -> height
--   pane._refreshers: list of fns run by pane:Refresh()
------------------------------------------------------------------------
local function MakePane(parent)
    local p = CreateFrame("Frame", nil, parent)
    p._blocks, p._refreshers, p._themed = {}, {}, {}
    function p:Add(block, gap)
        block:SetParent(self)
        tinsert(self._blocks, { f = block, gap = gap or 0 })
        return block
    end
    function p:OnRefresh(fn) tinsert(self._refreshers, fn) end
    function p:Themed(w) tinsert(self._themed, w); return w end
    function p:Refresh()
        for _, fn in ipairs(self._refreshers) do fn() end
    end
    function p:Stack(w)
        local y = 0
        local prev
        for _, b in ipairs(self._blocks) do
            local fr = b.f
            if fr:IsShown() then
                fr:ClearAllPoints()
                fr:SetWidth(w)
                if fr.Layout then fr:Layout(w) end
                y = y - b.gap
                fr:SetPoint("TOPLEFT", self, "TOPLEFT", 0, y)
                fr:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, y)
                y = y - fr:GetHeight()
                prev = fr
            end
        end
        local h = math.max(1, -y)
        self:SetHeight(h)
        return h
    end
    function p:ApplyTheme(th)
        for _, w in ipairs(self._themed) do
            if w.ApplyTheme then w:ApplyTheme(th) end
        end
    end
    return p
end

-- Intro line: OLLFontBodySmall/#8b909b, wraps to maxW
local function MakeIntro(parent, text, maxW)
    local f = CreateFrame("Frame", nil, parent)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    f.text:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetSpacing(4)
    f.text:SetText(text)
    f._maxW = maxW or 520
    function f:Layout(w)
        self.text:SetWidth(math.min(self._maxW, w))
        self:SetHeight(self.text:GetStringHeight() + 4)
    end
    function f:ApplyTheme() self.text:SetTextColor(hexrgb("8b909b")) end
    f:ApplyTheme()
    return f
end

-- Horizontal group of controls (segmented + button etc.) sized to content
local function MakeHGroup(parent, gap)
    local g = CreateFrame("Frame", nil, parent)
    g._items, g._gap = {}, gap or 8
    function g:Add(w)
        w:SetParent(self)
        tinsert(self._items, w)
        self:Relayout()
        return w
    end
    function g:Relayout()
        local x, h = 0, 0
        for i, w in ipairs(self._items) do
            if w:IsShown() then
                w:ClearAllPoints()
                w:SetPoint("LEFT", self, "LEFT", x, 0)
                x = x + w:GetWidth() + (i < #self._items and self._gap or 0)
                h = math.max(h, w:GetHeight())
            end
        end
        self:SetSize(math.max(1, x), math.max(1, h))
    end
    return g
end

-- Fade-out then hide (200ms) for badges
local function FadeOutHide(frame)
    if not frame:IsShown() then return end
    if InCombatLockdown() then frame:Hide(); return end
    if not frame._fadeOut then
        local ag = frame:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(1); a:SetToAlpha(0); a:SetDuration(0.2)
        ag:SetScript("OnFinished", function() frame:Hide(); frame:SetAlpha(1) end)
        frame._fadeOut = ag
    end
    frame._fadeOut:Stop(); frame._fadeOut:Play()
end

------------------------------------------------------------------------
-- Section 1 — General
------------------------------------------------------------------------
local FRAME_SIZE_TEXT = {
    small  = "One compact row per item: name and roll buttons. Icon, stat and gear-type labels are hidden.",
    medium = "The standard roll frame: each item with its icon, gear-type badge and primary stat label.",
    large  = "Two panels: items on the left, every eligible player's choice, roll and loot count on the right, live.",
}
local CHAT_TEXT = {
    Normal = "Session joins and anything that affects you directly. Leader adds loot outcomes and reassignments.",
    Leader = "Everything in Normal, plus loot outcomes and reassignment confirmations.",
    Debug  = "Everything in Leader, plus developer and test-mode messages.",
}

function Settings:_BuildGeneralPane(parent)
    local pane = MakePane(parent)

    -- APPEARANCE
    pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "Appearance")))

    local themeItems = {}
    for _, name in ipairs(ns.Theme:GetNames()) do tinsert(themeItems, { value = name, label = name }) end
    local themeSeg = ns.MakeChoiceSegmented(pane, themeItems, {
        get = function() return ns.db.profile.theme or "Ledger" end,
        onPick = function(v) if ns.Theme then ns.Theme:Set(v) end end,
    })
    local themeRow = ns.MakeSettingRow(pane, {
        label = "Theme", sub = "Applies instantly to every OLL frame. Saved per character.",
        control = themeSeg,
        tooltip = "Visual style for all OLL frames. Applies immediately and is saved per-character.",
        refresh = function() themeSeg:Refresh() end,
    })
    pane:Add(themeRow)
    pane:OnRefresh(function() themeRow:Refresh() end)

    -- Roll window size + Preview + consequence box
    local sizeGroup = MakeHGroup(pane, 8)
    local sizeSeg = ns.MakeChoiceSegmented(sizeGroup, {
        { value = "small", label = "Small" }, { value = "medium", label = "Medium" }, { value = "large", label = "Large" },
    }, {
        get = function() return ns.db.profile.lootFrameSize or "medium" end,
        onPick = function(v) ns.db.profile.lootFrameSize = v; Settings:RefreshSection("general") end,
    })
    sizeGroup:Add(sizeSeg)
    local previewBtn = ns.MakeButton(sizeGroup, "outline", "Preview", 84, 26)
    previewBtn:SetScript("OnClick", function()
        local items = ns.Session and ns.Session.currentItems
        if not items or #items == 0 then
            items = (ns.DebugWindow and ns.DebugWindow.PickRandomItems) and ns.DebugWindow:PickRandomItems(2) or {}
        end
        if ns.RollFrame then
            ns.RollFrame:ShowAllItems(items, (ns.Session and ns.Session.rollOptions) or Settings:GetRollOptions(), true)
        end
    end)
    sizeGroup:Add(previewBtn)
    local sizeRow = ns.MakeSettingRow(pane, {
        label = "Roll window size", control = sizeGroup,
        tooltip = "Choose how the loot roll window is displayed. Small shows a compact single-row list. Medium is the standard frame with icons and stat badges. Large is a two-panel frame showing all players' choices in real time. Cannot be changed while a roll is in progress.",
        refresh = function()
            sizeSeg:Refresh()
            local rolling = IsRolling()
            sizeSeg:SetEnabled(not rolling)
            previewBtn:SetEnabled(not rolling)
        end,
    })
    pane:Add(sizeRow)
    local sizeBox = ns.MakeConsequenceBox(pane)
    pane:Add(sizeBox, 0)
    pane:OnRefresh(function()
        sizeRow:Refresh()
        sizeBox:SetText(FRAME_SIZE_TEXT[ns.db.profile.lootFrameSize or "medium"])
    end)
    function sizeBox:Layout() self:SetText(self.text:GetText()) end

    local statTog = ns.MakeToggle(pane,
        function() return ns.db.profile.showStatBadge ~= false end,
        function(v) ns.db.profile.showStatBadge = v end)
    local statRow = ns.MakeSettingRow(pane, {
        label = "Primary stat label", sub = "Shows STR / AGI / INT on each item.", control = statTog,
        tooltip = "Show the STR / AGI / INT badge on each item in the roll frame.",
        refresh = function() statTog:Refresh(false) end,
    })
    pane:Add(statRow)
    pane:OnRefresh(function() statRow:Refresh() end)

    -- CHAT
    pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "Chat")), 22)
    local chatSeg = ns.MakeChoiceSegmented(pane, {
        { value = "Normal", label = "Normal" }, { value = "Leader", label = "Leader" }, { value = "Debug", label = "Debug" },
    }, {
        get = function() return ns.db.profile.chatMessages or "Normal" end,
        onPick = function(v) ns.db.profile.chatMessages = v; Settings:RefreshSection("general") end,
    })
    local chatRow = ns.MakeSettingRow(pane, {
        label = "Message detail", control = chatSeg,
        tooltip = "Controls which OLL messages appear in your chat frame.\n\nNormal: session join/leave and messages that directly affect you.\nLeader: adds loot outcomes and reassignment confirmations.\nDebug: adds developer and test-mode messages.",
        refresh = function() chatSeg:Refresh() end,
    })
    pane:Add(chatRow)
    local chatBox = ns.MakeConsequenceBox(pane)
    pane:Add(chatBox, 0)
    function chatBox:Layout() self:SetText(self.text:GetText()) end
    pane:OnRefresh(function()
        chatRow:Refresh()
        chatBox:SetText(CHAT_TEXT[ns.db.profile.chatMessages or "Normal"])
    end)

    -- AUTO-PASS
    pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "Auto-pass")), 22)
    local function autoRow(label, sub, key, tooltip)
        local tog = ns.MakeToggle(pane,
            function() return ns.db.profile[key] == true end,
            function(v) ns.db.profile[key] = v end)
        local row = ns.MakeSettingRow(pane, {
            label = label, sub = sub, control = tog, tooltip = tooltip,
            refresh = function() tog:Refresh(false) end,
        })
        pane:Add(row)
        pane:OnRefresh(function() row:Refresh() end)
    end
    autoRow("Off-spec loot", "Primary stat doesn't match your current spec.", "autoPassOffSpec",
        "Automatically pass on items whose primary stat (Strength, Agility, or Intellect) does not match your current specialization.")
    autoRow("Items my class can't equip", "Wrong armor type or unusable weapon.", "autoPassUnequippable",
        "Automatically pass on items your class cannot use: wrong armor type (e.g. Plate for a Priest) or a weapon type your class cannot equip.")
    autoRow("Bind on Equip items", "Passes on anything tradeable that binds when equipped.", "autoPassBOE",
        "Automatically pass on Bind on Equip items.")

    -- Hold 'W' Mode: value is set only in the popup's OnAccept, so the knob
    -- must not move until the player confirms (set returns false to veto).
    local holdTog = ns.MakeToggle(pane,
        function() return ns.db.profile.holdWMode == true end,
        function(v)
            if v then
                StaticPopup_Show("OLL_HOLDW_CONFIRM")
                return false
            end
            ns.db.profile.holdWMode = false
        end)
    local holdRow = ns.MakeSettingRow(pane, {
        label = "Hold 'W' Mode", sub = "Passes on everything silently; no roll frame. /oll loot still opens it.",
        control = holdTog,
        tooltip = "Auto-passes ALL gear silently. The loot frame will not appear. You can still open the frame manually at any time with /oll loot. Checked each time a loot roll triggers, so you can disable it mid-session.",
        refresh = function() holdTog:Refresh(true) end,
    })
    pane:Add(holdRow)
    pane:OnRefresh(function() holdRow:Refresh() end)

    return pane
end

------------------------------------------------------------------------
-- Section 2 — My Characters
------------------------------------------------------------------------
local function CurrentCharName()
    return UnitName("player") .. "-" .. GetRealmName():gsub(" ", "")
end

function Settings:_BuildCharactersPane(parent)
    local pane = MakePane(parent)
    pane:Add(MakeIntro(pane,
        "Add every character you raid on. Your list is sent to the loot master when you join, so loot lands on one name.", 520))
    pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "My Characters")), 16)

    -- character list (pooled 38px rows)
    local list = CreateFrame("Frame", nil, pane)
    list._rows = {}
    local ROW_H = 38
    local function acquireRow(i)
        local r = list._rows[i]
        if r then r:Show(); return r end
        r = CreateFrame("Frame", nil, list)
        r:SetHeight(ROW_H)
        r.hair = ns.MakeHairline(r, "histSepColor")
        r.hair:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0); r.hair:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)
        r.fill = r:CreateTexture(nil, "BACKGROUND"); r.fill:SetTexture(WHITE8x8); r.fill:SetAllPoints(); r.fill:Hide()
        r.tick = r:CreateTexture(nil, "ARTWORK"); r.tick:SetTexture(WHITE8x8); r.tick:SetWidth(2)
        r.tick:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0); r.tick:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0); r.tick:Hide()
        r.name = r:CreateFontString(nil, "OVERLAY")
        r.name:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        r.name:SetPoint("LEFT", r, "LEFT", 10, 0)
        r.x = ns.MakeGlyphButton(r, "x", 22)
        r.x:SetPoint("RIGHT", r, "RIGHT", -6, 0)
        r.badge = ns.MakeBadge(r, "Main")
        r.badge:SetPoint("RIGHT", r.x, "LEFT", -14, 0)
        r.setMain = ns.MakeButton(r, "outline", "Set main", 84, 22)
        r.setMain:SetPoint("RIGHT", r.x, "LEFT", -14, 0)
        r.setMain:SetStrokeColor({ hexrgb("262a33") })
        r.setMain._text:SetTextColor(hexrgb("8b909b"))
        list._rows[i] = r
        return r
    end
    function list:Rebuild()
        local chars = ns.PlayerLinks:GetMyCharacters() or {}
        local main = ns.PlayerLinks:GetMyMain()
        local th = ns.Theme:GetCurrent()
        local y = 0
        for i, name in ipairs(chars) do
            local r = acquireRow(i)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", self, "TOPLEFT", 0, y)
            r:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, y)
            r.name:SetText(name)
            local cc = ns.ClassColorFor(name)
            if cc then r.name:SetTextColor(cc[1], cc[2], cc[3]) else r.name:SetTextColor(C(th, "textColor")) end
            r.hair:SetVertexColor(C(th, "histSepColor"))
            local isMain = (name == main)
            if isMain then
                r.fill:SetVertexColor(C(th, "rowBgColor")); r.fill:Show()
                r.tick:SetVertexColor(C(th, "accentColor")); r.tick:Show()
                r.badge:Show(); r.setMain:Hide()
                r.x:SetInert(true)
                r.x:SetScript("OnClick", nil)
            else
                r.fill:Hide(); r.tick:Hide()
                r.badge:Hide(); r.setMain:Show()
                r.setMain:SetScript("OnClick", function()
                    ns.PlayerLinks:SetMyMain(name)
                    Settings:RefreshSection("characters")
                end)
                r.x:SetInert(false)
                r.x:SetScript("OnClick", function()
                    local count = ns.LootCount:GetCount(name)
                    if count and count > 0 then
                        local d = StaticPopup_Show("OLL_SETTINGS_REMOVE_CHAR", name, count)
                        if d then d.data = name end
                    else
                        ns.PlayerLinks:RemoveMyCharacter(name)
                        Settings:RefreshSection("characters")
                    end
                end)
            end
            y = y - ROW_H
        end
        for i = #chars + 1, #self._rows do self._rows[i]:Hide() end
        self:SetHeight(math.max(1, -y))
    end
    pane:Add(list)

    -- Add row: edit box (flex to 280) + Add + Use current
    local addRow = CreateFrame("Frame", nil, pane)
    addRow:SetHeight(44)
    addRow.hair = ns.MakeHairline(addRow, "histSepColor")
    addRow.hair:SetPoint("TOPLEFT", addRow, "TOPLEFT", 0, 0); addRow.hair:SetPoint("TOPRIGHT", addRow, "TOPRIGHT", 0, 0)
    local nameBox = ns.MakeLedgerEditBox(addRow, 280, 26, "Name-Realm")
    nameBox:SetPoint("LEFT", addRow, "LEFT", 10, 0)
    local addBtn = ns.MakeButton(addRow, "outline", "Add", 52, 26)
    addBtn:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
    local useBtn = ns.MakeButton(addRow, "outline", "Use current", 104, 26)
    useBtn:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
    local function tryAdd(name)
        name = name and name:trim() or ""
        if name == "" then nameBox:FlashError(); return end
        if not name:match("^[^%s%-]+%-[^%s%-]+$") then nameBox:FlashError(); return end
        ns.PlayerLinks:AddMyCharacter(name)
        Settings._addCharName = ""
        nameBox:SetText("")
        Settings:RefreshSection("characters")
    end
    nameBox.edit:SetScript("OnEnterPressed", function(e) tryAdd(e:GetText()); e:ClearFocus() end)
    nameBox.edit:HookScript("OnTextChanged", function(e) Settings._addCharName = e:GetText() end)
    addBtn:SetScript("OnClick", function() tryAdd(nameBox:GetText()) end)
    useBtn:SetScript("OnClick", function() tryAdd(CurrentCharName()) end)
    function addRow:Layout(w)
        nameBox:SetWidth(math.max(120, math.min(280, w - 10 - 8 - 52 - 8 - 104)))
    end
    function addRow:ApplyTheme(th) self.hair:SetVertexColor(C(th, "histSepColor")) end
    pane:Themed(addRow)
    pane:Add(addRow)

    -- SESSIONS I'LL JOIN
    pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "Sessions I'll join")), 22)
    local joinRow = CreateFrame("Frame", nil, pane)
    joinRow:SetHeight(64)
    local friends = ns.MakeCheckbox(joinRow, "Friends",
        function() local r = ns.db.profile.joinRestrictions; return r and r.friends or false end,
        function(v) ns.db.profile.joinRestrictions.friends = v; Settings:RefreshSection("characters") end)
    friends:SetPoint("TOPLEFT", joinRow, "TOPLEFT", 0, -8)
    local guild = ns.MakeCheckbox(joinRow, "Guild",
        function() local r = ns.db.profile.joinRestrictions; return r and r.guild or false end,
        function(v) ns.db.profile.joinRestrictions.guild = v; Settings:RefreshSection("characters") end)
    guild:SetPoint("LEFT", friends, "RIGHT", 18, 0)
    local status = joinRow:CreateFontString(nil, "OVERLAY")
    status:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    status:SetPoint("TOPLEFT", friends, "BOTTOMLEFT", 0, -12)
    status:SetJustifyH("LEFT")
    joinRow.status = status
    function joinRow:Layout(w) status:SetWidth(w) end
    function joinRow:ApplyTheme(th) status:SetTextColor(C(th, "textMutedColor")) end
    pane:Themed(joinRow)
    pane:Add(joinRow)

    pane:OnRefresh(function()
        list:Rebuild()
        nameBox:SetText(Settings._addCharName or "")
        useBtn:SetEnabled(not tContains(ns.PlayerLinks:GetMyCharacters() or {}, CurrentCharName()))
        friends:Refresh(); guild:Refresh()
        local r = ns.db.profile.joinRestrictions or {}
        local txt
        if r.friends and r.guild then
            txt = "Currently joining sessions hosted by friends or guildmates only. Uncheck both to join any session."
        elseif r.friends then
            txt = "Currently joining sessions hosted by friends only. Uncheck to join any session."
        elseif r.guild then
            txt = "Currently joining sessions hosted by guildmates only. Uncheck to join any session."
        else
            txt = "Joining any session, from anyone."
        end
        status:SetText(txt)
    end)
    return pane
end

------------------------------------------------------------------------
-- Section 3 — Session Rules
------------------------------------------------------------------------
function Settings:_BuildSessionPane(parent)
    local pane = MakePane(parent)

    -- Active-session banner
    local banner = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    ns.SkinNineSlice(banner, "btn")
    banner:SetHeight(36)
    banner.dot = banner:CreateTexture(nil, "OVERLAY")
    banner.dot:SetTexture(ns.Ledger.TEX.dot); banner.dot:SetSize(6, 6)
    banner.dot:SetPoint("LEFT", banner, "LEFT", 12, 0)
    banner.label = banner:CreateFontString(nil, "OVERLAY")
    banner.label:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    banner.label:SetPoint("LEFT", banner.dot, "RIGHT", 10, 0)
    banner.label:SetText(ns.Track("Session active"))
    banner.text = banner:CreateFontString(nil, "OVERLAY")
    banner.text:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    banner.text:SetPoint("LEFT", banner.label, "RIGHT", 8, 0)
    banner.text:SetText("- changes marked with a lock apply from the next session.")
    function banner:ApplyTheme(th)
        local g = th.timerBarFullColor
        self:SetBackdropColor(g[1], g[2], g[3], 0.07)
        self:SetBackdropBorderColor(g[1], g[2], g[3], 0.24)
        self.dot:SetVertexColor(g[1], g[2], g[3])
        self.label:SetTextColor(g[1], g[2], g[3])
        self.text:SetTextColor(hexrgb("8b909b"))
    end
    pane:Themed(banner)
    pane:Add(banner)
    local rollingHdr = pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "Rolling")), 14)

    -- Loot threshold: quality-coloured segments
    local thrItems = {}
    for _, q in ipairs({ 2, 3, 4, 5 }) do
        tinsert(thrItems, { value = q, label = _G["ITEM_QUALITY" .. q .. "_DESC"] or tostring(q), color = ns.Ledger.QualityColor(q) })
    end
    local thrSeg = ns.MakeChoiceSegmented(pane, thrItems, {
        get = function() return ns.db.profile.lootThreshold end,
        onPick = function(v) ns.db.profile.lootThreshold = v end,
    })
    local thrRow = ns.MakeSettingRow(pane, {
        label = "Loot threshold", sub = "Minimum quality that opens a roll.", control = thrSeg,
        tooltip = "Minimum item quality to trigger the roll window.",
        refresh = function() thrSeg:Refresh() end,
    })
    pane:Add(thrRow)

    -- Roll timer slider (10-300 step 5)
    local timer = ns.MakeLedgerSlider(pane, 10, 300, 5,
        function() return ns.db.profile.rollTimer end,
        function(v) ns.db.profile.rollTimer = v end, { w = 360, unit = "sec" })
    local timerRow = ns.MakeSettingRow(pane, {
        label = "Roll timer", control = timer,
        tooltip = "Time players have to respond to a roll. Click the number to type an exact value (10-300, steps of 5).",
        refresh = function() timer:Refresh() end,
    })
    pane:Add(timerRow)

    local trigSeg = ns.MakeChoiceSegmented(pane, {
        { value = "automatic", label = "Automatic" }, { value = "promptForStart", label = "Prompt me" },
    }, {
        get = function() return ns.db.profile.lootRollTriggering or "automatic" end,
        onPick = function(v) ns.db.profile.lootRollTriggering = v end,
    })
    local trigRow = ns.MakeSettingRow(pane, {
        label = "Start rolls", sub = "Prompt lets you review items before players see them.", control = trigSeg,
        tooltip = "Controls when loot rolls begin after items are captured.\n\nAutomatic: rolls start immediately.\nPrompt me: a confirmation popup appears and the roll waits until the Loot Master clicks Start.",
        refresh = function() trigSeg:Refresh() end,
    })
    pane:Add(trigRow)

    local annSeg = ns.MakeChoiceSegmented(pane, {
        { value = "RAID", label = "Raid" }, { value = "RAID_WARNING", label = "Warning" },
        { value = "PARTY", label = "Party" }, { value = "SAY", label = "Say" },
    }, {
        get = function() return ns.db.profile.announceChannel end,
        onPick = function(v) ns.db.profile.announceChannel = v end,
    })
    local annRow = ns.MakeSettingRow(pane, {
        label = "Announce winners in", control = annSeg,
        tooltip = "Chat channel used to announce roll winners.",
        refresh = function() annSeg:Refresh() end,
    })
    pane:Add(annRow)

    -- PERMISSIONS
    pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "Permissions")), 22)
    local lmSeg = ns.MakeChoiceSegmented(pane, {
        { value = "anyLeader", label = "Any leader / assist" }, { value = "onlyLootMaster", label = "Loot master only" },
    }, {
        get = function() return ns.db.profile.lootMasterRestriction or "anyLeader" end,
        onPick = function(v)
            ns.db.profile.lootMasterRestriction = v
            if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
                ns.Session:UpdateSessionLootMasterRestriction(v)
            end
        end,
    })
    local lmRow = ns.MakeSettingRow(pane, {
        label = "Who can start & stop rolls", control = lmSeg,
        tooltip = "Controls who is allowed to trigger a Manual Roll or stop a roll in progress. \"Loot master only\" restricts these actions to the designated loot master. \"Any leader / assist\" allows any raid leader or raid assist to perform them.",
        refresh = function() lmSeg:Refresh() end,
    })
    pane:Add(lmRow)

    local deGroup = MakeHGroup(pane, 8)
    local deBox = ns.MakeLedgerEditBox(deGroup, 170, 26, "Name-Realm")
    deGroup:Add(deBox)
    local deTarget = ns.MakeButton(deGroup, "outline", "Use target", 96, 26)
    deGroup:Add(deTarget)
    local function commitDE(v)
        ns.db.profile.disenchanter = v
        if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
            ns.Session:UpdateSessionDisenchanter(v)
        end
    end
    deBox.edit:SetScript("OnEnterPressed", function(e) commitDE(e:GetText():trim()); e:ClearFocus(); Settings:RefreshSection("session") end)
    deBox.edit:HookScript("OnEditFocusLost", function(e)
        local v = e:GetText():trim()
        if v ~= (ns.db.profile.disenchanter or "") then commitDE(v); Settings:RefreshSection("session") end
    end)
    deTarget:SetScript("OnClick", function()
        local name, realm = UnitName("target")
        if not name then
            ns.ChatPrint("Normal", "No target selected.")
            return
        end
        if not realm or realm == "" then
            realm = GetRealmName():gsub(" ", "")
        end
        local fullName = name .. "-" .. realm
        ns.db.profile.disenchanter = fullName
        if ns.Session and ns.Session:IsActive() and ns.IsLeader() then
            ns.Session:UpdateSessionDisenchanter(fullName)
        end
        Settings:RefreshSection("session")
    end)
    local deRow = ns.MakeSettingRow(pane, {
        label = "Disenchanter", sub = "Offered in the reassign popup when everyone passes.", control = deGroup,
        tooltip = "The designated player who receives items that all players passed on. They appear as an option in the Reassign popup when resolving loot. Leave blank to skip disenchanter logic.",
        refresh = function()
            local v = ns.db.profile.disenchanter or ""
            if not deBox.edit:HasFocus() then deBox:SetText(v) end
            deBox:SetTextColorRGB(ns.ClassColorFor(v))
        end,
    })
    pane:Add(deRow)

    pane:OnRefresh(function()
        local active = IsSessionActive()
        banner:SetShown(active)
        for _, r in ipairs({ thrRow, timerRow, trigRow, annRow, lmRow, deRow }) do r:Refresh() end
    end)
    return pane
end

------------------------------------------------------------------------
-- Section 4 — Roll Options
------------------------------------------------------------------------
function Settings:_RenumberRollOptions()
    local opts = self:_EnsureCustomOpts()
    for i, o in ipairs(opts) do o.priority = i end
end

function Settings:_BuildRollOptionsPane(parent)
    local pane = MakePane(parent)
    pane:Add(MakeIntro(pane,
        "Drag to reorder. The top tier wins outright - lower tiers only win when nobody above them rolled. Pass is always last and can't be removed.", 540))

    local ROW_H = 42
    local tbl = ns.MakeTable(pane, {
        { key = "drag",   label = "",               width = 24 },
        { key = "tier",   label = "Tier",           width = 34 },
        { key = "name",   label = "Button label",   width = "1fr" },
        { key = "counts", label = "Counts for loot", width = 130 },
        { key = "color",  label = "Color",          width = 92 },
        { key = "del",    label = "",               width = 28 },
    }, { rowH = ROW_H, headerH = 24, inset = 8 })
    pane:Add(tbl, 18)
    pane._tbl = tbl

    -- per-row controls, created once per pooled row
    local function ensureControls(row)
        if row._ctl then return row._ctl end
        local c = {}
        c.handle = ns.MakeGlyphButton(row, "::", 22)
        c.handle:RegisterForDrag("LeftButton")
        c.lock = row:CreateFontString(nil, "OVERLAY")
        c.lock:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
        c.lock:SetText("|TInterface\\PetBattles\\PetBattle-LockIcon:12:12|t")
        c.lock:Hide()
        c.edit = ns.MakeLedgerEditBox(row, 220, 26, "")
        c.passName = row:CreateFontString(nil, "OVERLAY")
        c.passName:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        c.passName:SetText("Pass"); c.passName:Hide()
        c.toggle = ns.MakeToggle(row, function() return row._opt and row._opt.countsForLoot end, function(v)
            local i = row._idx
            if i then Settings:_EnsureCustomOpts()[i].countsForLoot = v; pane:RefreshPreview() end
        end)
        c.word = row:CreateFontString(nil, "OVERLAY")
        c.word:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
        c.swatch = CreateFrame("Button", nil, row, "BackdropTemplate")
        c.swatch:SetSize(44, 20)
        ns.SkinNineSlice(c.swatch, "pill")
        c.x = ns.MakeGlyphButton(row, "x", 22)
        row._ctl = c
        return c
    end

    local function placeControls(row)
        local L = tbl._layout
        if not L then return end
        local c = row._ctl
        c.handle:ClearAllPoints();  c.handle:SetPoint("LEFT", row, "LEFT", L.drag.x, 0)
        c.lock:ClearAllPoints();    c.lock:SetPoint("LEFT", row, "LEFT", L.drag.x + 5, 0)
        c.edit:ClearAllPoints();    c.edit:SetPoint("LEFT", row, "LEFT", L.name.x, 0)
        c.edit:SetWidth(math.max(80, math.min(220, L.name.w)))
        c.passName:ClearAllPoints(); c.passName:SetPoint("LEFT", row, "LEFT", L.name.x + 10, 0)
        c.toggle:ClearAllPoints();  c.toggle:SetPoint("LEFT", row, "LEFT", L.counts.x, 0)
        c.word:ClearAllPoints()
        if row._isPass then c.word:SetPoint("LEFT", row, "LEFT", L.counts.x, 0)
        else c.word:SetPoint("LEFT", c.toggle, "RIGHT", 10, 0) end
        c.swatch:ClearAllPoints();  c.swatch:SetPoint("LEFT", row, "LEFT", L.color.x, 0)
        c.x:ClearAllPoints();       c.x:SetPoint("LEFT", row, "LEFT", L.del.x + 3, 0)
    end
    local baseLayout = tbl.Layout
    tbl.Layout = function(self)
        baseLayout(self)
        for _, row in ipairs(self._rows) do if row._ctl then placeControls(row) end end
    end

    -- drag-to-reorder
    local drag = { idx = nil }
    local function stopDrag()
        drag.idx = nil
        pane:SetScript("OnUpdate", nil)
    end
    local function beginDrag(idx)
        drag.idx = idx
        pane:SetScript("OnUpdate", function()
            if not IsMouseButtonDown("LeftButton") then stopDrag(); return end
            local _, cy = GetCursorPosition()
            cy = cy / tbl.body:GetEffectiveScale()
            local top = tbl.body:GetTop()
            if not top then return end
            local opts = Settings:GetRollOptions()
            local hover = math.floor((top - cy) / ROW_H) + 1
            hover = math.max(1, math.min(#opts, hover))
            if hover ~= drag.idx then
                local list = Settings:_EnsureCustomOpts()
                local item = table.remove(list, drag.idx)
                tinsert(list, hover, item)
                Settings:_RenumberRollOptions()
                drag.idx = hover
                pane:Rebuild()
            end
        end)
    end

    function pane:Rebuild()
        local th = ns.Theme:GetCurrent()
        local opts = Settings:GetRollOptions()
        tbl:ReleaseRows()
        for i, o in ipairs(opts) do
            local row = tbl:AcquireRow()
            row._idx, row._opt, row._isPass = i, o, false
            local c = ensureControls(row)
            row:SetAlpha(1)
            row:EnableMouse(false)
            row:SetScript("OnEnter", nil); row:SetScript("OnLeave", nil)
            row._hl:Hide()
            row:SetSelected(i == 1)
            if i == 1 then row._sel:SetVertexColor(C(th, "rowBgColor")) end
            row:SetCell("tier", tostring(o.priority or i), (i == 1) and th.accentHiColor or { hexrgb("8b909b") })
            c.handle:Show(); c.lock:Hide()
            c.handle:SetScript("OnDragStart", function() beginDrag(row._idx) end)
            c.handle:SetScript("OnDragStop", stopDrag)
            c.handle:SetScript("OnMouseDown", function() beginDrag(row._idx) end)
            c.edit:Show(); c.passName:Hide()
            if not c.edit.edit:HasFocus() then c.edit:SetText(o.name or "") end
            c.edit:SetTextColorRGB(nil)
            c.edit.edit:SetScript("OnEnterPressed", function(e)
                Settings:_EnsureCustomOpts()[row._idx].name = e:GetText()
                e:ClearFocus(); pane:RefreshPreview()
            end)
            c.edit.edit:SetScript("OnEditFocusLost", function(e)
                local v = e:GetText()
                if row._idx and Settings:GetRollOptions()[row._idx] and v ~= Settings:GetRollOptions()[row._idx].name then
                    Settings:_EnsureCustomOpts()[row._idx].name = v
                    pane:RefreshPreview()
                end
            end)
            c.toggle:Show(); c.toggle:SetEnabled(true); c.toggle:Refresh(false)
            c.word:SetText(o.countsForLoot and "Yes" or "No")
            c.word:SetTextColor(C(th, "textMutedColor"))
            c.swatch:Show()
            c.swatch:SetBackdropColor(o.colorR or 0.5, o.colorG or 0.5, o.colorB or 0.5, 1)
            c.swatch:SetBackdropBorderColor(1, 1, 1, 0.2)
            c.swatch:SetScript("OnClick", function()
                local idx = row._idx
                local cur = Settings:GetRollOptions()[idx]
                if not cur then return end
                local prevR, prevG, prevB = cur.colorR, cur.colorG, cur.colorB
                local function apply()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    local o2 = Settings:_EnsureCustomOpts()[idx]
                    if o2 then o2.colorR, o2.colorG, o2.colorB = r, g, b end
                    c.swatch:SetBackdropColor(r, g, b, 1)
                    pane:RefreshPreview()
                end
                local function cancel()
                    local o2 = Settings:_EnsureCustomOpts()[idx]
                    if o2 then o2.colorR, o2.colorG, o2.colorB = prevR, prevG, prevB end
                    c.swatch:SetBackdropColor(prevR, prevG, prevB, 1)
                    pane:RefreshPreview()
                end
                if ColorPickerFrame.SetupColorPickerAndShow then
                    ColorPickerFrame:SetupColorPickerAndShow({
                        r = cur.colorR, g = cur.colorG, b = cur.colorB, hasOpacity = false,
                        swatchFunc = apply, cancelFunc = cancel,
                    })
                else
                    ColorPickerFrame.func, ColorPickerFrame.cancelFunc = apply, cancel
                    ColorPickerFrame.hasOpacity = false
                    ColorPickerFrame:SetColorRGB(cur.colorR, cur.colorG, cur.colorB)
                    ColorPickerFrame:Show()
                end
            end)
            c.x:Show(); c.x:SetInert(false)
            c.x:SetScript("OnClick", function()
                local d = StaticPopup_Show("OLL_SETTINGS_DELETE_TIER", Settings:GetRollOptions()[row._idx].name or "")
                if d then d.data = row._idx end
            end)
            placeControls(row)
        end
        -- Pass row: 60% alpha, lock instead of handle, flat swatch, no delete
        local prow = tbl:AcquireRow()
        prow._idx, prow._opt, prow._isPass = nil, nil, true
        local c = ensureControls(prow)
        prow:EnableMouse(false)
        prow._hl:Hide()
        prow:SetSelected(false)
        prow:SetAlpha(0.6)
        prow:SetCell("tier", "", nil)
        c.handle:Hide(); c.lock:Show(); c.lock:SetTextColor(C(th, "textDimColor"))
        c.edit:Hide(); c.passName:Show(); c.passName:SetTextColor(hexrgb("8b909b"))
        c.toggle:Hide()
        c.word:SetText("No"); c.word:SetTextColor(C(th, "textMutedColor"))
        c.word:ClearAllPoints()
        c.swatch:Show()
        c.swatch:SetBackdropColor(hexrgb("4a4f58")); c.swatch:SetBackdropBorderColor(hexrgb("4a4f58"))
        c.swatch:SetScript("OnClick", nil)
        c.x:Hide()
        placeControls(prow)
        tbl:SetHeight(tbl:GetContentHeight())
        tbl:Layout()
        pane:RefreshPreview()
        if pane._focusNew then
            local target = tbl._rows[pane._focusNew]
            pane._focusNew = nil
            if target and target._ctl then
                target._ctl.edit.edit:SetFocus()
                target._ctl.edit.edit:HighlightText()
            end
        end
    end
    -- Buttons
    local btnRow = MakeHGroup(pane, 8)
    local addBtn = ns.MakeButton(btnRow, "primary", "Add tier", 100, 28)
    addBtn:SetScript("OnClick", function()
        local opts = Settings:_EnsureCustomOpts()
        tinsert(opts, {
            name = "New Option",
            priority = #opts + 1,
            countsForLoot = false,
            colorR = 0.5, colorG = 0.5, colorB = 0.5,
        })
        pane._focusNew = #opts
        Settings:RefreshSection("rollOptions")
    end)
    btnRow:Add(addBtn)
    local restoreBtn = ns.MakeButton(btnRow, "outline", "Restore defaults", 140, 28)
    restoreBtn:SetScript("OnClick", function() StaticPopup_Show("OLL_SETTINGS_RESTORE_TIERS") end)
    btnRow:Add(restoreBtn)
    pane:Add(btnRow, 14)

    -- PREVIEW
    pane:Add(pane:Themed(ns.MakeGroupHeader(pane, "Preview")), 26)
    local box = CreateFrame("Frame", nil, pane, "BackdropTemplate")
    ns.SkinNineSlice(box, "btn")
    box:SetHeight(28 + 24)
    local seg = ns.MakeSegmented(box, Settings:GetRollOptions(), nil, { h = 28, defaultW = 96, passW = 72 })
    seg:SetPoint("LEFT", box, "LEFT", 12, 0)
    seg:SetEnabled(true)
    seg:SetOnPick(function(name) seg:SetSelected(name) end)
    box.seg = seg
    function box:ApplyTheme(th)
        self:SetBackdropColor(C(th, "panelBgColor"))
        self:SetBackdropBorderColor(C(th, "histSepColor"))
    end
    pane:Themed(box)
    pane:Add(box, 6)
    function pane:RefreshPreview()
        seg:SetOptions(Settings:GetRollOptions())
        seg:SetSelected(nil)
    end

    pane:OnRefresh(function() pane:Rebuild() end)
    return pane
end

------------------------------------------------------------------------
-- Section 5 — Roster (sub-tab strip + action bar live in the content
-- frame; the pane holds the three sub-tab bodies)
------------------------------------------------------------------------
function Settings:_BuildRosterChrome(content)
    local f = self._frame
    -- Sub-tab strip
    local strip = CreateFrame("Frame", nil, content)
    strip:SetHeight(34)
    strip:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    strip.rule = ns.MakeHairline(strip, "dividerColor")
    strip.rule:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0); strip.rule:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", 0, 0)
    strip.tabs = {}
    local defs = { { "counts", "Loot counts" }, { "links", "Character links" }, { "rules", "Counting rules" } }
    local x = 24
    for _, d in ipairs(defs) do
        local t = CreateFrame("Button", nil, strip)
        t:SetHeight(26)
        t:SetPoint("LEFT", strip, "LEFT", x, 0)
        t.fill = t:CreateTexture(nil, "BACKGROUND"); t.fill:SetTexture(WHITE8x8); t.fill:SetAllPoints(); t.fill:Hide()
        t.text = t:CreateFontString(nil, "OVERLAY")
        t.text:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
        t.text:SetPoint("CENTER")
        t.text:SetText(ns.Track(d[2]))
        t:SetWidth(t.text:GetStringWidth() + 20)
        t._key = d[1]
        t:SetScript("OnClick", function(b)
            ns.db.profile.settingsRosterTab = b._key
            Settings:_RefreshChrome()
            Settings:RefreshSection("roster")
        end)
        strip.tabs[d[1]] = t
        x = x + t:GetWidth() + 2
    end
    local search = ns.MakeLedgerEditBox(strip, 160, 24, "Search player")
    search:SetPoint("RIGHT", strip, "RIGHT", -24, 0)
    search.edit:HookScript("OnTextChanged", function(e, user)
        if user then Settings._rosterSearch = e:GetText(); Settings:RefreshSection("roster") end
    end)
    strip.search = search
    function strip:ApplyTheme(th)
        self.rule:SetVertexColor(C(th, "dividerColor"))
        self.search.placeholder:SetTextColor(hexrgb("565c67"))
        local active = ns.db.profile.settingsRosterTab or "counts"
        for key, t in pairs(self.tabs) do
            if key == active then
                t.fill:SetVertexColor(C(th, "rowBgColor")); t.fill:Show()
                t.text:SetTextColor(C(th, "accentHiColor"))
            else
                t.fill:Hide()
                t.text:SetTextColor(hexrgb("8b909b"))
            end
        end
    end
    strip:Hide()
    f.rosterStrip = strip

    -- Action bar (Loot counts only)
    local bar = ns.MakeBar(content, 52, "barBgColor", "TOP")
    bar:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    local sync = ns.MakeButton(bar, "primary", "Sync to group", 150, 28)
    sync:SetPoint("LEFT", bar, "LEFT", 24, 0)
    sync:SetScript("OnClick", function()
        ns.Comm:Send(ns.Comm.MSG.COUNT_SYNC, { counts = ns.LootCount:GetCountsTable() })
        Settings._pendingLootCountSync = false
        ns.ChatPrint("Normal", "Loot counts synced to group.")
        Settings._justSynced = true
        wipe(Settings._editedRows)
        Settings:RefreshSection("roster")
    end)
    bar.sync = sync
    local export = ns.MakeButton(bar, "outline", "Export CSV", 110, 28)
    export:SetPoint("LEFT", sync, "RIGHT", 8, 0)
    export:SetScript("OnClick", function() Settings:_ShowExportCSVPopup() end)
    bar.export = export
    local resetAll = ns.MakeButton(bar, "outline", "Reset all", 96, 28)
    resetAll:SetPoint("RIGHT", bar, "RIGHT", -24, 0)
    resetAll:SetScript("OnClick", function() StaticPopup_Show("OLL_SETTINGS_RESET_ALL_COUNTS") end)
    bar.resetAll = resetAll
    local nextReset = bar:CreateFontString(nil, "OVERLAY")
    nextReset:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    nextReset:SetPoint("RIGHT", resetAll, "LEFT", -14, 0)
    bar.nextReset = nextReset
    local baseApply = bar.ApplyTheme
    function bar:ApplyTheme(th)
        if baseApply then baseApply(self, th) end
        th = th or ns.Theme:GetCurrent()
        local red = th.timerBarLowColor
        self.resetAll:SetStrokeColor({ red[1], red[2], red[3], 0.35 })
        self.resetAll._text:SetTextColor(red[1], red[2], red[3])
        self.nextReset:SetTextColor(C(th, "textMutedColor"))
    end
    bar:Hide()
    f.rosterBar = bar
end

local function NextResetText()
    local sched = ns.db.profile.resetSchedule or "weekly"
    if sched == "manual" then return nil end
    local ts
    if sched == "monthly" then
        ts = ns.LootCount:_GetNextMonthlyResetTime(time())
    else
        ts = ns.GetNextWeeklyReset(time())
    end
    if not ts then return nil end
    return "Next reset " .. date("%a %H:%M", ts)
end

local function MatchesSearch(name)
    local q = Settings._rosterSearch
    if not q or q == "" then return true end
    return name:lower():find(q:lower(), 1, true) ~= nil
end

function Settings:_BuildRosterPane(parent)
    local pane = MakePane(parent)
    local f = self._frame

    ------------------------------------------------------------------ 5a
    local counts = CreateFrame("Frame", nil, pane)
    counts._pane = pane
    local ROW_H = 36
    local tbl = ns.MakeTable(counts, {
        { key = "player", label = "Player", width = "1fr" },
        { key = "count",  label = "Count",  width = 96 },
        { key = "reset",  label = "",       width = 78 },
        { key = "del",    label = "",       width = 28 },
    }, { rowH = ROW_H, headerH = 24, inset = 8 })
    tbl:SetPoint("TOPLEFT", counts, "TOPLEFT", 0, 0)
    tbl:SetPoint("TOPRIGHT", counts, "TOPRIGHT", 0, 0)
    counts.tbl = tbl
    counts._rowsByName = {}

    -- clickable sort headers
    for _, key in ipairs({ "player", "count" }) do
        local hb = CreateFrame("Button", nil, tbl.header)
        hb:SetHeight(24)
        hb:SetScript("OnClick", function()
            local field = (key == "player") and "name" or "count"
            if Settings._lootCountSortField == field then
                Settings._lootCountSortAsc = not Settings._lootCountSortAsc
            else
                Settings._lootCountSortField = field
                Settings._lootCountSortAsc = (field == "name")
            end
            counts:Rebuild()
        end)
        tbl.header["btn_" .. key] = hb
    end
    local function placeHeaderButtons()
        local L = tbl._layout
        if not L then return end
        for _, key in ipairs({ "player", "count" }) do
            local hb = tbl.header["btn_" .. key]
            hb:ClearAllPoints()
            hb:SetPoint("LEFT", tbl.header, "LEFT", L[key].x, 0)
            hb:SetWidth(math.max(20, L[key].w))
        end
    end

    local function ensureControls(row)
        if row._ctl then return row._ctl end
        local c = {}
        c.sub = row:CreateFontString(nil, "OVERLAY")
        c.sub:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
        c.badge = ns.MakeBadge(row, "Edited")
        c.stepper = ns.MakeStepper(row, 0, 999, 1,
            function() return row._name and ns.LootCount:GetCount(row._name) or 0 end,
            function(v)
                if not row._name then return end
                ns.LootCount:SetCount(row._name, v)
                if IsSessionActive() then
                    Settings._pendingLootCountSync = true
                    Settings._editedRows[row._name] = true
                end
                Settings:RefreshRow(row._name)
                Settings:_RefreshChrome()
            end)
        c.dash = row:CreateFontString(nil, "OVERLAY")
        c.dash:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        c.dash:SetText("-")
        c.reset = ns.MakeButton(row, "outline", "Reset", 72, 22)
        c.reset._text:SetTextColor(hexrgb("8b909b"))
        c.x = ns.MakeGlyphButton(row, "x", 22)
        row._ctl = c
        return c
    end
    local function placeControls(row)
        local L = tbl._layout
        if not L or not row._ctl then return end
        local c = row._ctl
        c.sub:ClearAllPoints();     c.sub:SetPoint("LEFT", row.cells.player, "LEFT", row.cells.player:GetStringWidth() + 10, 0)
        c.badge:ClearAllPoints();   c.badge:SetPoint("LEFT", c.sub, "RIGHT", c.sub:IsShown() and 8 or 0, 0)
        c.stepper:ClearAllPoints(); c.stepper:SetPoint("LEFT", row, "LEFT", L.count.x, 0)
        c.dash:ClearAllPoints();    c.dash:SetPoint("CENTER", c.stepper, "CENTER", 0, 0)
        c.reset:ClearAllPoints();   c.reset:SetPoint("LEFT", row, "LEFT", L.reset.x, 0)
        c.x:ClearAllPoints();       c.x:SetPoint("LEFT", row, "LEFT", L.del.x + 3, 0)
    end
    local baseLayout = tbl.Layout
    tbl.Layout = function(self)
        baseLayout(self)
        placeHeaderButtons()
        for _, row in ipairs(self._rows) do placeControls(row) end
    end

    local function paintRow(row, th)
        local c = row._ctl
        local name = row._name
        if row._isAlt then return end
        c.stepper:Refresh()
        local edited = Settings._editedRows[name]
        if edited then
            c.badge:Show()
            c.stepper:SetStrokeColor({ th.accentColor[1], th.accentColor[2], th.accentColor[3], 0.45 })
        else
            if Settings._justSynced and c.badge:IsShown() then FadeOutHide(c.badge) else c.badge:Hide() end
            c.stepper:SetStrokeColor(nil)
        end
        local canEdit = CanEditCounts()
        c.stepper:SetEnabled(canEdit)
        c.reset:SetEnabled(canEdit)
        c.x:SetInert(not canEdit)
    end

    function counts:Rebuild()
        local th = ns.Theme:GetCurrent()
        local raw = ns.db.global.lootCounts or {}
        local locked = ns.db.profile.lootCountLockedToMain ~= false
        local entries = {}
        for name, count in pairs(raw) do
            if MatchesSearch(name) then tinsert(entries, { name = name, count = count }) end
        end
        if locked then
            for name in pairs(raw) do
                for _, alt in ipairs(ns.PlayerLinks:GetAlts(name)) do
                    if alt ~= name and raw[alt] == nil and MatchesSearch(alt) then
                        tinsert(entries, { name = alt, count = raw[name] or 0, alt = true, main = name })
                    end
                end
            end
        end
        local field, asc = Settings._lootCountSortField or "count", Settings._lootCountSortAsc
        table.sort(entries, function(a, b)
            if field == "name" then
                if asc then return a.name < b.name end
                return a.name > b.name
            else -- "count"
                if a.count ~= b.count then
                    if asc then return a.count < b.count end
                    return a.count > b.count
                end
                return a.name < b.name
            end
        end)
        tbl:SetSortIndicator(field == "name" and "player" or "count")
        tbl:ReleaseRows()
        wipe(self._rowsByName)
        for _, e in ipairs(entries) do
            local row = tbl:AcquireRow()
            local c = ensureControls(row)
            row._name, row._isAlt = e.name, e.alt
            row:EnableMouse(false)
            row._hl:Hide()
            self._rowsByName[e.name] = row
            local cc = ns.ClassColorFor(e.name)
            row:SetCell("player", ns.StripRealm(e.name), cc or th.textColor)
            local alts = ns.PlayerLinks:GetAlts(e.name)
            local nAlts = 0
            for _, a in ipairs(alts) do if a ~= e.name then nAlts = nAlts + 1 end end
            if e.alt then
                c.sub:SetText(ns.Track("alt of " .. ns.StripRealm(e.main))); c.sub:Show()
            elseif nAlts > 0 then
                c.sub:SetText(ns.Track("+" .. nAlts .. (nAlts == 1 and " alt" or " alts"))); c.sub:Show()
            else
                c.sub:SetText(""); c.sub:Hide()
            end
            c.sub:SetTextColor(hexrgb("565c67"))
            if e.alt then
                row:SetAlpha(0.5)
                c.stepper:Hide(); c.dash:Show(); c.dash:SetTextColor(C(th, "textMutedColor"))
                c.reset:Hide(); c.x:Hide(); c.badge:Hide()
            else
                row:SetAlpha(1)
                c.stepper:Show(); c.dash:Hide(); c.reset:Show(); c.x:Show()
                c.reset:SetScript("OnClick", function()
                    if not CanEditCounts() then return end
                    ns.LootCount:ResetCount(e.name)
                    if IsSessionActive() then
                        Settings._pendingLootCountSync = true
                        Settings._editedRows[e.name] = true
                    end
                    Settings:RefreshRow(e.name)
                    Settings:_RefreshChrome()
                end)
                c.x:SetScript("OnClick", function()
                    if not CanEditCounts() then return end
                    local d = StaticPopup_Show("OLL_SETTINGS_REMOVE_COUNT", e.name)
                    if d then d.data = e.name end
                end)
                paintRow(row, th)
            end
            placeControls(row)
        end
        Settings._justSynced = false

        -- Add row
        local addRow = self.addRow
        addRow:ClearAllPoints()
        addRow:SetPoint("TOPLEFT", tbl, "BOTTOMLEFT", 8, 0)
        addRow:SetPoint("TOPRIGHT", tbl, "BOTTOMRIGHT", -8, 0)
        addRow.picker:SetLabel(Settings._addLootCountPlayer and ns.StripRealm(Settings._addLootCountPlayer) or "Add player")
        addRow.picker._text:ClearAllPoints()
        addRow.picker._text:SetPoint("LEFT", addRow.picker, "LEFT", 12, 0)
        addRow.picker._text:SetTextColor(Settings._addLootCountPlayer and C(th, "textColor") or C(th, "textMutedColor"))
        addRow.addBtn:SetEnabled(Settings._addLootCountPlayer ~= nil and CanEditCounts())
        addRow.picker:SetEnabled(CanEditCounts())

        tbl:SetHeight(tbl:GetContentHeight())
        tbl:Layout()
        self:SetHeight(tbl:GetContentHeight() + 36)
        if #entries == 0 then
            self.empty:Show()
            self.empty:SetText(Settings._rosterSearch and Settings._rosterSearch ~= "" and "No players match." or "No loot counts recorded.")
            self:SetHeight(tbl:GetContentHeight() + 36 + 30)
            addRow:SetPoint("TOPLEFT", tbl, "BOTTOMLEFT", 8, -30)
            addRow:SetPoint("TOPRIGHT", tbl, "BOTTOMRIGHT", -8, -30)
        else
            self.empty:Hide()
        end
    end
    function counts:RefreshRow(name)
        local row = self._rowsByName[name]
        if row then paintRow(row, ns.Theme:GetCurrent()) end
    end

    counts.empty = counts:CreateFontString(nil, "OVERLAY")
    counts.empty:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    counts.empty:SetPoint("TOPLEFT", tbl, "BOTTOMLEFT", 8, -10)
    counts.empty:Hide()

    -- Add row: picker over untracked mains + "Add at 0"
    local addRow = CreateFrame("Frame", nil, counts)
    addRow:SetHeight(36)
    local picker = ns.MakeButton(addRow, "outline", "Add player", 200, 24)
    picker:SetPoint("LEFT", addRow, "LEFT", 0, 0)
    picker.caret = picker:CreateFontString(nil, "OVERLAY")
    picker.caret:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    picker.caret:SetPoint("RIGHT", picker, "RIGHT", -10, 0)
    picker.caret:SetText("v")
    picker:SetScript("OnClick", function(b)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        local tracked = ns.db.global.lootCounts or {}
        MenuUtil.CreateContextMenu(b, function(_, root)
            local any = false
            for _, name in ipairs(ns.PlayerLinks:GetAllMains()) do
                if tracked[name] == nil then
                    any = true
                    root:CreateButton(name, function()
                        Settings._addLootCountPlayer = name
                        Settings:RefreshSection("roster")
                    end)
                end
            end
            if not any then root:CreateTitle("Every known player is already tracked") end
        end)
    end)
    addRow.picker = picker
    local addBtn = ns.MakeButton(addRow, "outline", "Add at 0", 84, 24)
    addBtn:SetPoint("LEFT", picker, "RIGHT", 8, 0)
    addBtn:SetScript("OnClick", function()
        local name = Settings._addLootCountPlayer
        if name then
            ns.LootCount:SetCount(name, 0)
            Settings._addLootCountPlayer = nil
            if ns.Session and ns.Session:IsActive() then
                Settings._pendingLootCountSync = true
                Settings._editedRows[name] = true
            end
            Settings:_RefreshChrome()
            Settings:RefreshSection("roster")
        end
    end)
    addRow.addBtn = addBtn
    counts.addRow = addRow
    function counts:ApplyTheme(th) picker.caret:SetTextColor(C(th, "textMutedColor")) end
    pane:Themed(counts)
    pane:Add(counts)

    ------------------------------------------------------------------ 5b
    local links = CreateFrame("Frame", nil, pane)
    links._rows = {}
    links.intro = MakeIntro(links,
        "Character links arrive automatically when players register their characters and join a session. This is everything synced to your client.", 560)
    links.intro:SetPoint("TOPLEFT", links, "TOPLEFT", 0, 0)
    links.empty1 = links:CreateFontString(nil, "OVERLAY")
    links.empty1:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    links.empty1:SetText("No character links synced yet.")
    links.empty2 = links:CreateFontString(nil, "OVERLAY")
    links.empty2:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    links.empty2:SetText("Links appear when players with OLL installed join your session.")
    links.empty2:SetPoint("TOP", links.empty1, "BOTTOM", 0, -6)
    local function acquireLinkRow(i)
        local r = links._rows[i]
        if r then r:Show(); return r end
        r = CreateFrame("Frame", nil, links)
        r.hair = ns.MakeHairline(r, "histSepColor")
        r.hair:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0); r.hair:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)
        r.name = r:CreateFontString(nil, "OVERLAY")
        r.name:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.meta = r:CreateFontString(nil, "OVERLAY")
        r.meta:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
        r.meta:SetPoint("LEFT", r.name, "RIGHT", 8, 0)
        r.count = r:CreateFontString(nil, "OVERLAY")
        r.count:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
        r.count:SetPoint("RIGHT", r, "RIGHT", -8, 0)
        links._rows[i] = r
        return r
    end
    function links:Rebuild(w)
        local th = ns.Theme:GetCurrent()
        self.intro:Layout(w)
        local y = -(self.intro:GetHeight() + 14)
        local n = 0
        local groups = 0
        for _, main in ipairs(ns.PlayerLinks:GetAllMains()) do
            local alts = {}
            for _, alt in ipairs(ns.PlayerLinks:GetAlts(main)) do
                if alt ~= main then tinsert(alts, alt) end
            end
            local show = #alts > 0 and (MatchesSearch(main) or (function()
                for _, a in ipairs(alts) do if MatchesSearch(a) then return true end end
                return false
            end)())
            if show then
                groups = groups + 1
                n = n + 1
                local r = acquireLinkRow(n)
                r:SetHeight(32)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", self, "TOPLEFT", 0, y)
                r:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, y)
                r.hair:Show(); r.hair:SetVertexColor(C(th, "histSepColor"))
                r.name:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
                r.name:SetText(main)
                local cc = ns.ClassColorFor(main)
                if cc then r.name:SetTextColor(cc[1], cc[2], cc[3], 1) else r.name:SetTextColor(C(th, "textColor")) end
                r.meta:SetText(ns.Track("- " .. (#alts + 1) .. " characters"))
                r.meta:SetTextColor(C(th, "textMutedColor")); r.meta:Show()
                r.count:SetText(tostring(ns.LootCount:GetCount(main)))
                r.count:SetTextColor(C(th, "countTextColor")); r.count:Show()
                r.name:ClearAllPoints(); r.name:SetPoint("LEFT", r, "LEFT", 0, 0)
                y = y - 32
                for _, alt in ipairs(alts) do
                    n = n + 1
                    local ar = acquireLinkRow(n)
                    ar:SetHeight(26)
                    ar:ClearAllPoints()
                    ar:SetPoint("TOPLEFT", self, "TOPLEFT", 0, y)
                    ar:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, y)
                    ar.hair:Hide()
                    ar.name:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
                    ar.name:SetText(alt)
                    local ac = ns.ClassColorFor(alt)
                    if ac then ar.name:SetTextColor(ac[1], ac[2], ac[3], 0.8)
                    else local t = th.textColor; ar.name:SetTextColor(t[1], t[2], t[3], 0.8) end
                    ar.name:ClearAllPoints(); ar.name:SetPoint("LEFT", ar, "LEFT", 26, 0)
                    ar.meta:Hide(); ar.count:Hide()
                    y = y - 26
                end
            end
        end
        for i = n + 1, #self._rows do self._rows[i]:Hide() end
        if groups == 0 then
            self.empty1:ClearAllPoints()
            self.empty1:SetPoint("TOP", self, "TOP", 0, y - 40)
            self.empty1:SetTextColor(C(th, "textDimColor"))
            self.empty2:SetTextColor(hexrgb("565c67"))
            self.empty1:Show(); self.empty2:Show()
            y = y - 100
        else
            self.empty1:Hide(); self.empty2:Hide()
        end
        self:SetHeight(math.max(1, -y))
    end
    pane:Add(links)

    ------------------------------------------------------------------ 5c
    local rules = CreateFrame("Frame", nil, pane)
    rules._blocks = {}
    local function addRule(block, gap) tinsert(rules._blocks, { f = block, gap = gap or 0 }); block:SetParent(rules); return block end

    local enabledTog = ns.MakeToggle(rules,
        function() return ns.db.profile.lootCountEnabled ~= false end,
        function(v) ns.db.profile.lootCountEnabled = v; Settings:RefreshSection("roster") end)
    local enabledRow = addRule(ns.MakeSettingRow(rules, {
        label = "Track loot counts", sub = "Turns the whole counting system on or off.", control = enabledTog, locked = true,
        tooltip = "Enable or disable the loot count tracking system. Cannot be changed during an active session.",
        refresh = function() enabledTog:Refresh(false) end,
    }))
    local attrSeg = ns.MakeChoiceSegmented(rules, {
        { value = "lockedToMain", label = "Shared" }, { value = "perCharacter", label = "Per character" },
    }, {
        get = function() return ns.db.profile.lootCountLockedToMain ~= false and "lockedToMain" or "perCharacter" end,
        onPick = function(v) ns.db.profile.lootCountLockedToMain = (v == "lockedToMain"); Settings:RefreshSection("roster") end,
    })
    local attrRow = addRule(ns.MakeSettingRow(rules, {
        label = "Attribution", control = attrSeg, locked = true,
        tooltip = "Determines how loot counts are attributed when a player has linked characters. Shared consolidates all counts to the player's main: alts share the same count pool. Per character tracks each character independently, regardless of any links. Cannot be changed during an active session.",
        refresh = function() attrSeg:Refresh() end,
    }))
    local attrBox = addRule(ns.MakeConsequenceBox(rules), 0)
    function attrBox:Layout() self:SetText(self.text:GetText()) end
    local tokTog = ns.MakeToggle(rules,
        function() return ns.db.profile.tokensCountAsLoot == true end,
        function(v) ns.db.profile.tokensCountAsLoot = v end)
    local tokRow = addRule(ns.MakeSettingRow(rules, {
        label = "Tier tokens count", sub = "Winning a tier or catalyst token adds to the loot count.", control = tokTog, locked = true,
        tooltip = "Tier / catalyst tokens are rolled through OLL like gear. When enabled, winning one increments the winner's loot count. Cannot be changed during an active session.",
        refresh = function() tokTog:Refresh(false) end,
    }))
    local recTog = ns.MakeToggle(rules,
        function() return ns.db.profile.recipesCountAsLoot == true end,
        function(v) ns.db.profile.recipesCountAsLoot = v end)
    local recRow = addRule(ns.MakeSettingRow(rules, {
        label = "Recipes count", sub = "Winning a profession recipe adds to the loot count.", control = recTog, locked = true,
        tooltip = "Profession recipes are rolled through OLL like gear. When enabled, winning one increments the winner's loot count. Cannot be changed during an active session.",
        refresh = function() recTog:Refresh(false) end,
    }))
    local schedSeg = ns.MakeChoiceSegmented(rules, {
        { value = "weekly", label = "Weekly" }, { value = "monthly", label = "Monthly" }, { value = "manual", label = "Manual" },
    }, {
        get = function() return ns.db.profile.resetSchedule or "weekly" end,
        onPick = function(v) ns.db.profile.resetSchedule = v; Settings:RefreshSection("roster") end,
    })
    local schedRow = addRule(ns.MakeSettingRow(rules, {
        label = "Reset", control = schedSeg, locked = true,
        tooltip = "Select when the loot count should be reset for the group.",
        refresh = function() schedSeg:Refresh() end,
    }))
    local regionSeg = ns.MakeChoiceSegmented(rules, {
        { value = "auto", label = "Auto" }, { value = "NA", label = "NA" }, { value = "EU", label = "EU" },
    }, {
        get = function() return ns.db.profile.resetRegion or "auto" end,
        onPick = function(v) ns.db.profile.resetRegion = v; Settings:RefreshSection("roster") end,
    })
    local regionRow = addRule(ns.MakeSettingRow(rules, {
        label = "Reset region", control = regionSeg, locked = true,
        tooltip = "Which region's weekly reset time to use. Auto detects it from the game client.",
        refresh = function()
            local detected = ns.RESET_SPECS[ns.GetResetRegion()] and ns.GetResetRegion() or "NA"
            regionSeg:SetItems({
                { value = "auto", label = "Auto (" .. detected .. ")" }, { value = "NA", label = "NA" }, { value = "EU", label = "EU" },
            })
            regionSeg:Refresh()
        end,
    }))
    local schedBox = addRule(ns.MakeConsequenceBox(rules), 0)
    function schedBox:Layout() self:SetText(self.text:GetText()) end

    function rules:Rebuild(w)
        local on = ns.db.profile.lootCountEnabled ~= false
        regionRow:SetShown(ns.db.profile.resetSchedule ~= "manual")
        local y = 0
        for _, b in ipairs(self._blocks) do
            local fr = b.f
            if fr:IsShown() then
                fr:ClearAllPoints()
                fr:SetWidth(w)
                if fr.Layout then fr:Layout(w) end
                y = y - b.gap
                fr:SetPoint("TOPLEFT", self, "TOPLEFT", 0, y)
                fr:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, y)
                y = y - fr:GetHeight()
            end
        end
        self:SetHeight(math.max(1, -y))
        for _, r in ipairs({ enabledRow, attrRow, tokRow, recRow, schedRow, regionRow }) do r:Refresh() end
        for _, r in ipairs({ attrRow, tokRow, recRow, schedRow, regionRow }) do
            r:SetDimmed(not on)
            r:SetForceDisabled(not on)
        end
        attrBox:SetAlpha(on and 1 or 0.45)
        schedBox:SetAlpha(on and 1 or 0.45)
        attrBox:SetText(ns.db.profile.lootCountLockedToMain ~= false
            and "Counts consolidate to each player's main - alts share one pool."
            or  "Every character is counted on its own, links ignored.")
        local v = ns.db.profile.resetSchedule or "weekly"
        local spec = ns.GetResetSpec()
        local txt
        if v == "monthly" then
            txt = "Resets on the 1st of the month at " .. string.format("%02d:00 UTC", spec.hourUTC)
                .. " (" .. ns.GetResetRegion() .. " reset hour), whatever weekday that is."
        elseif v == "manual" then
            txt = "Automatic loot count reset is off."
        else
            txt = "Resets every week at the " .. ns.GetResetRegion() .. " raid reset: " .. spec.label .. "."
        end
        schedBox:SetText(txt)
    end
    function rules:Layout(w) self:Rebuild(w) end
    pane:Add(rules)

    -- Sub-tab switching: only one body is shown; strip + bar are chrome
    function pane:RefreshChrome()
        local tab = ns.db.profile.settingsRosterTab or "counts"
        f.rosterStrip:ApplyTheme(ns.Theme:GetCurrent())
        local showBar = (Settings._section == "roster" and tab == "counts")
        if f.rosterBar:IsShown() ~= showBar then
            f.rosterBar:SetShown(showBar)
            Settings:_LayoutContent()
        end
        if showBar then
            local active = IsSessionActive()
            local pending = Settings._pendingLootCountSync
            local n = 0
            for _ in pairs(Settings._editedRows) do n = n + 1 end
            local canSync = active and ns.IsSessionLeader() and pending
            f.rosterBar.sync:SetEnabled(canSync)
            if not pending then
                f.rosterBar.sync:SetLabel("Synced"); f.rosterBar.sync:SetBadge(nil); f.rosterBar.sync:SetAlpha(0.5)
            else
                f.rosterBar.sync:SetLabel("Sync to group"); f.rosterBar.sync:SetBadge(n > 0 and n or nil)
                f.rosterBar.sync:SetAlpha(canSync and 1 or 0.5)
            end
            f.rosterBar.resetAll:SetEnabled(not (active and not ns.IsSessionLeader()))
            local nr = NextResetText()
            f.rosterBar.nextReset:SetText(nr or "")
        end
    end
    function pane:RefreshRow(name) counts:RefreshRow(name) end
    function pane:Refresh()
        local tab = ns.db.profile.settingsRosterTab or "counts"
        counts:SetShown(tab == "counts"); links:SetShown(tab == "links"); rules:SetShown(tab == "rules")
        self:RefreshChrome()
    end
    -- Stack builds whichever body is visible
    local baseStack = pane.Stack
    function pane:Stack(w)
        if counts:IsShown() then counts:SetWidth(w); counts:Rebuild() end
        if links:IsShown()  then links:SetWidth(w);  links:Rebuild(w) end
        return baseStack(self, w)
    end
    return pane
end

------------------------------------------------------------------------
-- CSV (unchanged data path; Ledger chrome)
------------------------------------------------------------------------
function Settings:_BuildLootCountCSV()
    local counts = ns.db.global.lootCounts or {}
    local entries = {}

    for name, count in pairs(counts) do
        tinsert(entries, { name = name, count = count })
    end

    local field = self._lootCountSortField or "count"
    local asc   = self._lootCountSortAsc

    table.sort(entries, function(a, b)
        if field == "name" then
            if asc then return a.name < b.name end
            return a.name > b.name
        else -- "count"
            if a.count ~= b.count then
                if asc then return a.count < b.count end
                return a.count > b.count
            end
            return a.name < b.name
        end
    end)

    local lines = { "Player name,Loot count" }
    for _, e in ipairs(entries) do
        tinsert(lines, string.format("%s,%d", e.name, e.count))
    end
    return table.concat(lines, "\n")
end

function Settings:_ShowExportCSVPopup()
    if not self._csvExportPopup then
        local popup = ns.MakeLedgerFrame("OLLExportCSVPopup", 440, 340, "ExportCSVPopup", { strata = "DIALOG" })
        local header = ns.MakeHeaderBar(popup, "Export loot counts", nil,
            { height = 44, subtitle = "CSV", onClose = function() popup:Hide() end })
        popup.header = header

        local hint = popup:CreateFontString(nil, "OVERLAY")
        hint:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
        hint:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, -54)
        hint:SetText("Ctrl+A then Ctrl+C to copy")
        popup.hint = hint

        local wrap = CreateFrame("Frame", nil, popup, "BackdropTemplate")
        wrap:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, -74)
        wrap:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -16, 16)
        ns.SkinNineSlice(wrap, "btn")
        popup.wrap = wrap

        local scroll = CreateFrame("ScrollFrame", nil, wrap)
        scroll:SetPoint("TOPLEFT", wrap, "TOPLEFT", 8, -6)
        scroll:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -8, 6)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(s, delta)
            local cur, maxV = s:GetVerticalScroll(), s:GetVerticalScrollRange()
            s:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 20)))
        end)

        local editBox = CreateFrame("EditBox", "OLLExportCSVEditBox", scroll)
        editBox:SetWidth(scroll:GetWidth() > 0 and scroll:GetWidth() or 380)
        -- The scroll frame has no size until the popup is laid out; follow it.
        scroll:SetScript("OnSizeChanged", function(_, w)
            if w and w > 0 then editBox:SetWidth(w) end
        end)
        editBox:SetHeight(2000)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
        editBox:SetMaxLetters(0)
        editBox:SetScript("OnEscapePressed", function() popup:Hide() end)
        scroll:SetScrollChild(editBox)
        popup.editBox = editBox

        function popup:ApplyThemeExtra(th)
            th = th or ns.Theme:GetCurrent()
            self.hint:SetTextColor(C(th, "textMutedColor"))
            self.wrap:SetBackdropColor(C(th, "panelBgColor"))
            self.wrap:SetBackdropBorderColor(C(th, "strokeColor"))
            self.editBox:SetTextColor(C(th, "textColor"))
        end
        popup:ApplyThemeExtra()
        popup:Hide()
        self._csvExportPopup = popup
    end

    local csv = self:_BuildLootCountCSV()
    self._csvExportPopup.editBox:SetText(csv)
    self._csvExportPopup:Show()
    self._csvExportPopup.editBox:SetFocus()
    self._csvExportPopup.editBox:SetCursorPosition(0)
    self._csvExportPopup.editBox:HighlightText()
end

------------------------------------------------------------------------
-- Blizzard AddOns panel: a launcher card, nothing else.
------------------------------------------------------------------------
function Settings:Register()
    local panel = CreateFrame("Frame", "OLLBlizzardOptionsPanel")
    panel.name = ns.ADDON_NAME
    panel:Hide()
    panel:SetScript("OnShow", function(p)
        if not p._built then Settings:_BuildBlizzardStub(p) end
        p.footerRight:SetText(ns.Track("Profile - " .. (ns.db:GetCurrentProfile() or "Default")))
    end)
    self.optionsFrame = panel

    local S = _G.Settings
    if S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory then
        local category = S.RegisterCanvasLayoutCategory(panel, ns.ADDON_NAME)
        category.ID = ns.ADDON_NAME
        S.RegisterAddOnCategory(category)
        self._blizCategory = category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function Settings:_BuildBlizzardStub(panel)
    panel._built = true
    local theme = ns.Theme:GetCurrent()

    local card = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    card:SetSize(460, 300)
    card:SetPoint("CENTER", panel, "CENTER", 0, 20)
    ns.SkinNineSlice(card, "frame")
    card:SetBackdropColor(C(theme, "frameBgColor"))
    card:SetBackdropBorderColor(C(theme, "frameBorderColor"))
    panel.card = card

    local header = ns.MakeHeaderBar(card, ns.ADDON_NAME, nil, { height = 44, noClose = true })
    panel.cardHeader = header

    local body = card:CreateFontString(nil, "OVERLAY")
    body:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    body:SetPoint("TOP", card, "TOP", 0, -74)
    body:SetWidth(320)
    body:SetJustifyH("CENTER")
    body:SetSpacing(5)
    body:SetText("OrderedLootList uses its own settings window so options stay readable next to the loot frames.")
    body:SetTextColor(hexrgb("c2c7d0"))

    local open = ns.MakeButton(card, "primary", "Open Settings", 0, 32)
    open:SetWidth(open._text:GetStringWidth() + 40)
    open:SetPoint("TOP", body, "BOTTOM", 0, -26)
    open:SetScript("OnClick", function()
        if SettingsPanel and HideUIPanel then HideUIPanel(SettingsPanel) end
        ns.Settings:Open()
    end)

    local hint = card:CreateFontString(nil, "OVERLAY")
    hint:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    hint:SetPoint("TOP", open, "BOTTOM", 0, -18)
    hint:SetText("or type |cffc2c7d0/oll config|r")
    hint:SetTextColor(hexrgb("565c67"))

    local rule = ns.MakeHairline(card, "histSepColor")
    rule:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 40)
    rule:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -16, 40)
    local fl = card:CreateFontString(nil, "OVERLAY")
    fl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    fl:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 14)
    fl:SetText(ns.Track("Version " .. (C_AddOns.GetAddOnMetadata(ns.ADDON_NAME, "Version") or ns.VERSION or "?")))
    fl:SetTextColor(hexrgb("565c67"))
    local fr = card:CreateFontString(nil, "OVERLAY")
    fr:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    fr:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -16, 14)
    fr:SetTextColor(hexrgb("565c67"))
    panel.footerRight = fr
end
