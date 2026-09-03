------------------------------------------------------------------------
-- OrderedLootList  –  UI/LeaderFrame.lua  (Ledger)
-- Leader session control panel: start/end session, item list,
-- responses, announce/re-roll/reassign, trade queue with Open Trade.
--
-- Layout (840x520):
--   44px title bar   LOOT SESSION · status pill · PARTY / LOG / OPTS · X
--   40px action row  [primary] Manual Roll  Takeover ........ LM ▾  Trade Queue (n)
--    2px timer bar
--   left 290px       boss headers 26px, item rows 42px
--   right            66px item hero, roster table (1fr/88/52/96), waiting chips
--   56px award bar   [ANNOUNCE <winner> · choice roll]  Re-roll  Reassign ... Pass remaining
--
-- All session/comm logic lives in Session.lua; this file only draws.
------------------------------------------------------------------------

local ns                      = _G.OLL_NS

local LeaderFrame             = {}
ns.LeaderFrame                = LeaderFrame

local FRAME_WIDTH             = 840
local FRAME_HEIGHT            = 520
local LEFT_PANEL_WIDTH        = 290
local TITLE_H                 = 44
local ACTION_ROW_H            = 40
local TIMER_H                 = 2
local HEADER_HEIGHT           = TITLE_H + ACTION_ROW_H + TIMER_H   -- 86
local BOSS_HEADER_H           = 26
local ITEM_ROW_HEIGHT         = 42
local PLAYER_ROW_HEIGHT       = 26
local HERO_H                  = 66
local ACTION_BAR_HEIGHT       = 56
local WAIT_HDR_H              = 24
local CHIP_H                  = 20
local INSET                   = 16

LeaderFrame._frame            = nil
LeaderFrame._leftScrollChild  = nil
LeaderFrame._rightScrollChild = nil

-- Selection state: { source="current"|"history", bossKey=string, itemIdx=number }
LeaderFrame._selectedItem     = nil
-- Pool of left-panel item row frames for reuse
LeaderFrame._itemRowPool      = {}
-- Pool of waiting-player chips (right panel)
LeaderFrame._chipPool         = {}
-- Pool of per-roster-row segmented controls (rolling state)
LeaderFrame._segPool          = {}

-- Loot Master popup state
LeaderFrame._lootMasterPopup   = nil

-- Manual Roll popup state
LeaderFrame._manualRollItems   = {}
LeaderFrame._manualRollPopup   = nil
LeaderFrame._manualListChild   = nil
LeaderFrame._manualStartBtn    = nil
LeaderFrame._manualCaptureBox  = nil
LeaderFrame._manualLinkHookInstalled = nil
LeaderFrame._manualItemRowPool = {}
LeaderFrame._manualEmptyText   = nil
LeaderFrame._manualTimerOverride = nil   -- seconds or nil (= session default)

-- Trade Queue popup state
LeaderFrame._tradeQueuePopup   = nil
LeaderFrame._tradeQueueRowPool = {}

------------------------------------------------------------------------
-- End-session confirmation (guards against a stray click on the Leader Frame)
------------------------------------------------------------------------
StaticPopupDialogs["OLL_CONFIRM_END_SESSION"] = {
    text           = "End the current loot session?

Rolls in progress are stopped and members are told the session is over. It can be resumed later this lockout.",
    button1        = "End Session",
    button2        = "Cancel",
    OnAccept       = function()
        if ns.Session and ns.Session:IsActive() then ns.Session:EndSession() end
        if ns.LeaderFrame then ns.LeaderFrame:Refresh() end
    end,
    timeout        = 0,
    whileDead      = true,
    hideOnEscape   = true,
    preferredIndex = 3,
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function StripRealm(name)
    if not name then return name end
    return name:match("^(.-)%-") or name
end

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

-- Get all group member names (Name-Realm format)
local function GetGroupMembers()
    local members = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        tinsert(members, ns.GetPlayerNameRealm())
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                local full = name
                if not name:find("-") then
                    full = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(members, full)
            end
        end
    else
        tinsert(members, ns.GetPlayerNameRealm())
        for i = 1, numMembers - 1 do
            local unit = "party" .. i
            local name = GetUnitName(unit, true)
            if name then
                if not name:find("-") then
                    name = name .. "-" .. (GetNormalizedRealmName() or "")
                end
                tinsert(members, name)
            end
        end
    end
    -- In debug mode, append fake players so they show as pending until they roll
    if ns.Session and ns.Session.debugMode then
        for _, name in ipairs(ns.Session._debugFakePlayers) do
            tinsert(members, name)
        end
    end
    return members
end

-- Set of current WoW raid/party leaders (for the LEAD badge)
local function GetLeaderSet()
    local set = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, rank = GetRaidRosterInfo(i)
            if name and rank == 2 then set[StripRealm(name)] = true end
        end
    elseif IsInGroup() then
        if UnitIsGroupLeader("player") then set[StripRealm(ns.GetPlayerNameRealm())] = true end
        for i = 1, GetNumGroupMembers() - 1 do
            if UnitIsGroupLeader("party" .. i) then
                set[StripRealm(GetUnitName("party" .. i, true) or "")] = true
            end
        end
    else
        set[StripRealm(ns.GetPlayerNameRealm())] = true
    end
    return set
end

-- "Cloth · Shoulder" style meta for an item link (nil if not cached)
local function ItemMeta(link)
    if not link then return nil end
    local _, _, _, _, _, _, itemSubType, _, equipLoc = C_Item.GetItemInfo(link)
    local parts = {}
    local typeLabel = ns.RF_GetItemTypeLabelAndColor and ns.RF_GetItemTypeLabelAndColor(link)
    if typeLabel then tinsert(parts, string.upper(typeLabel))
    elseif itemSubType and itemSubType ~= "" then tinsert(parts, string.upper(itemSubType)) end
    local slot = equipLoc and equipLoc ~= "" and _G[equipLoc]
    if slot and slot ~= "" and string.upper(slot) ~= parts[1] then tinsert(parts, string.upper(slot)) end
    if #parts == 0 then return nil end
    return table.concat(parts, " · ")
end

local function FormatElapsed(startTs)
    if not startTs then return "" end
    local s = math.max(0, time() - startTs)
    local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
    if h > 0 then return string.format("%dH %02dM", h, m) end
    return string.format("%dM", m)
end

------------------------------------------------------------------------
-- Create frame (lazy init)
------------------------------------------------------------------------
function LeaderFrame:GetFrame()
    if self._frame then return self._frame end
    local theme = ns.Theme:GetCurrent()

    local f = ns.MakeLedgerFrame("OLLLeaderFrame", FRAME_WIDTH, FRAME_HEIGHT, "LeaderFrame",
        { strata = "HIGH", x = 200, y = 0 })

    -- ===== Title bar =====
    local header = ns.MakeHeaderBar(f, "Loot Session", {
        { label = "Party", tooltip = "Check Party – who is running OLL and which version",
          onClick = function() if ns.CheckPartyFrame then ns.CheckPartyFrame:Show() end end },
        { label = "Log",   tooltip = "Loot history",
          onClick = function() if ns.HistoryFrame then ns.HistoryFrame:Toggle() end end },
        { label = "Opts",  tooltip = "Settings",
          onClick = function() if ns.Settings then ns.Settings:OpenConfig() end end },
    }, { height = TITLE_H, onClose = function() LeaderFrame:Hide() end })
    f.header = header
    f.checkPartyBtn = header.tools[1]
    f.statusPill = header.pill

    -- ===== Action row =====
    local action = ns.MakeBar(f, ACTION_ROW_H, "barBgColor", "BOTTOM")
    action:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(TITLE_H + 2))
    action:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(TITLE_H + 2))
    f.actionRow = action

    -- contextual primary: Start Session / Start Roll / Stop Roll / End Session
    local primaryBtn = ns.MakeButton(action, "primary", "Start Session", 120, 26)
    primaryBtn:SetPoint("LEFT", action, "LEFT", INSET - 2, 0)
    primaryBtn:SetScript("OnClick", function() LeaderFrame:_OnPrimaryClick() end)
    f.primaryBtn = primaryBtn
    -- legacy field names other modules poke at
    f.sessionBtn  = primaryBtn
    f.stopRollBtn = primaryBtn
    f.startRollBtn = primaryBtn

    local manualRollBtn = ns.MakeButton(action, "outline", "Manual Roll", 110, 26)
    manualRollBtn:SetPoint("LEFT", primaryBtn, "RIGHT", 8, 0)
    manualRollBtn:SetScript("OnClick", function() LeaderFrame:ShowManualRollPopup() end)
    f.manualRollBtn = manualRollBtn

    local takeoverBtn = ns.MakeButton(action, "quiet", "Takeover", 96, 26)
    takeoverBtn:SetPoint("LEFT", manualRollBtn, "RIGHT", 8, 0)
    takeoverBtn:SetScript("OnClick", function() if ns.Session then ns.Session:TakeoverSession() end end)
    f.takeoverBtn = takeoverBtn

    -- right group: End Session (quiet), LM picker, Trade Queue
    local tradeQueueBtn = ns.MakeButton(action, "outline", "Trade Queue", 150, 26)
    tradeQueueBtn:SetPoint("RIGHT", action, "RIGHT", -(INSET - 2), 0)
    tradeQueueBtn:SetScript("OnClick", function() LeaderFrame:ShowTradeQueuePopup() end)
    f.tradeQueueBtn = tradeQueueBtn

    local lootMasterBtn = ns.MakeButton(action, "outline", "LM", 150, 26)
    lootMasterBtn:SetPoint("RIGHT", tradeQueueBtn, "LEFT", -8, 0)
    lootMasterBtn:SetScript("OnClick", function() LeaderFrame:ShowLootMasterPopup() end)
    -- "LM" quiet label + name in accent + caret, laid out inside the button
    lootMasterBtn._text:SetTextColor(C(theme, "textMutedColor"))
    local lmName = lootMasterBtn:CreateFontString(nil, "OVERLAY")
    lmName:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    lmName:SetPoint("LEFT", lootMasterBtn._text, "RIGHT", 8, 0)
    lmName:SetWordWrap(false); lmName:SetMaxLines(1); lmName:SetWidth(84)
    lmName:SetJustifyH("LEFT")
    lootMasterBtn.nameText = lmName
    local lmCaret = lootMasterBtn:CreateFontString(nil, "OVERLAY")
    lmCaret:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    lmCaret:SetPoint("RIGHT", lootMasterBtn, "RIGHT", -10, 0)
    lmCaret:SetText("v")
    lootMasterBtn.caret = lmCaret
    f.lootMasterBtn = lootMasterBtn
    f.lootMasterLabel = lmName
    ns.AttachAltTooltip(lootMasterBtn, function()
        return ns.Session and ns.Session.sessionLootMaster or nil
    end)

    local endSessionBtn = ns.MakeButton(action, "outline", "End Session", 100, 26)
    endSessionBtn:SetPoint("RIGHT", lootMasterBtn, "LEFT", -8, 0)
    endSessionBtn:SetScript("OnClick", function()
        if ns.Session and ns.Session:IsActive() then
            StaticPopup_Show("OLL_CONFIRM_END_SESSION")
        end
    end)
    f.endSessionBtn = endSessionBtn

    -- ===== Timer bar (2px, full width) =====
    local timerBar = ns.MakeTimerBar(f)
    timerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(TITLE_H + ACTION_ROW_H + 2))
    timerBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(TITLE_H + ACTION_ROW_H + 2))
    timerBar:Hide()
    f.timerBar = timerBar

    -- ===== Left panel =====
    local leftPanel = CreateFrame("Frame", nil, f)
    leftPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_HEIGHT + 2))
    leftPanel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
    leftPanel:SetWidth(LEFT_PANEL_WIDTH)
    local leftBg = leftPanel:CreateTexture(nil, "BACKGROUND")
    leftBg:SetTexture(ns.Ledger.TEX.white); leftBg:SetAllPoints()
    f.leftBg = leftBg
    local divider = ns.MakeHairline(f, "dividerColor")
    divider:SetWidth(1); divider:SetHeight(0)
    divider:ClearAllPoints()
    divider:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMRIGHT", 0, 0)
    f.divider = divider

    local leftScroll = CreateFrame("ScrollFrame", "OLLLeaderLeftScroll", leftPanel)
    leftScroll:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, 0)
    leftScroll:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", 0, 0)
    leftScroll:EnableMouseWheel(true)
    leftScroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 40)))
    end)
    local leftChild = CreateFrame("Frame", nil, leftScroll)
    leftChild:SetSize(LEFT_PANEL_WIDTH, 1)
    leftScroll:SetScrollChild(leftChild)
    f.leftScrollChild = leftChild
    self._leftScrollChild = leftChild

    -- ===== Right panel =====
    local rightPanel = CreateFrame("Frame", nil, f)
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 1, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.rightPanel = rightPanel

    -- Award bar pinned to the bottom of the right panel
    local actionBar = ns.MakeBar(rightPanel, ACTION_BAR_HEIGHT, "barBgColorAlt", "TOP")
    actionBar:SetPoint("BOTTOMLEFT", rightPanel, "BOTTOMLEFT", 0, 0)
    actionBar:SetPoint("BOTTOMRIGHT", rightPanel, "BOTTOMRIGHT", 0, 0)
    actionBar.rule._themeKey = "actionSepColor"
    f.actionBar = actionBar

    local announceBtn = ns.MakeButton(actionBar, "primary", "Announce", 220, 32)
    announceBtn:SetPoint("LEFT", actionBar, "LEFT", INSET, 0)
    announceBtn:Hide()
    f.announceBtn = announceBtn
    -- glow texture for the one-shot pulse when a winner resolves
    local glow = announceBtn:CreateTexture(nil, "OVERLAY")
    glow:SetTexture(ns.Ledger.TEX.white)
    glow:SetPoint("TOPLEFT", -2, 2); glow:SetPoint("BOTTOMRIGHT", 2, -2)
    glow:SetBlendMode("ADD"); glow:SetAlpha(0)
    announceBtn.glow = glow

    local rerollBtn = ns.MakeButton(actionBar, "outline", "Re-roll", 88, 32)
    rerollBtn:SetPoint("LEFT", announceBtn, "RIGHT", 10, 0)
    rerollBtn:Hide()
    f.rerollBtn = rerollBtn

    local reassignBtn = ns.MakeButton(actionBar, "outline", "Reassign", 96, 32)
    reassignBtn:SetPoint("LEFT", rerollBtn, "RIGHT", 10, 0)
    reassignBtn:Hide()
    f.reassignBtn = reassignBtn

    local passWaitingBtn = ns.MakeButton(actionBar, "quiet", "Pass remaining", 150, 32)
    passWaitingBtn:SetPoint("RIGHT", actionBar, "RIGHT", -INSET, 0)
    passWaitingBtn:HookScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:SetText("Pass Remaining Players", 1, 1, 1)
        GameTooltip:AddLine("Assigns Pass to all players who have not yet\nmade a choice for the selected item.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    passWaitingBtn:HookScript("OnLeave", GameTooltip_Hide)
    passWaitingBtn:Hide()
    f.passWaitingBtn = passWaitingBtn

    -- Item hero (fixed, top of right panel)
    local hero = CreateFrame("Frame", nil, rightPanel)
    hero:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, 0)
    hero:SetPoint("TOPRIGHT", rightPanel, "TOPRIGHT", 0, 0)
    hero:SetHeight(HERO_H)
    hero.rule = ns.MakeHairline(hero, "dividerColor")
    hero.rule:SetPoint("BOTTOMLEFT", hero, "BOTTOMLEFT", 0, 0)
    hero.rule:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", 0, 0)

    hero.icon = hero:CreateTexture(nil, "ARTWORK")
    hero.icon:SetSize(40, 40)
    hero.icon:SetPoint("LEFT", hero, "LEFT", INSET, 0)
    hero.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    hero.iconGlow = hero:CreateTexture(nil, "BACKGROUND")
    hero.iconGlow:SetTexture(ns.Ledger.TEX.dot)
    hero.iconGlow:SetPoint("CENTER", hero.icon, "CENTER")
    hero.iconGlow:SetSize(64, 64)
    hero.iconGlow:SetBlendMode("ADD")
    hero.iconGlow:SetAlpha(0.18)
    hero.iconEdge = CreateFrame("Frame", nil, hero, "BackdropTemplate")
    hero.iconEdge:SetPoint("TOPLEFT", hero.icon, "TOPLEFT", -1, 1)
    hero.iconEdge:SetPoint("BOTTOMRIGHT", hero.icon, "BOTTOMRIGHT", 1, -1)
    ns.SkinNineSlice(hero.iconEdge, "btn")

    hero.name = hero:CreateFontString(nil, "OVERLAY")
    hero.name:SetFontObject(ns.Ledger.Fonts.OLLFontHero)
    hero.name:SetPoint("TOPLEFT", hero.icon, "TOPRIGHT", 12, -2)
    hero.name:SetWordWrap(false); hero.name:SetMaxLines(1)

    hero.statPill = ns.MakePill(hero, "", nil, { filled = true })
    hero.statPill:SetPoint("TOPLEFT", hero.name, "BOTTOMLEFT", 0, -5)
    hero.statPill:Hide()
    hero.typePill = ns.MakePill(hero, "", nil)
    hero.typePill:SetPoint("LEFT", hero.statPill, "RIGHT", 6, 0)
    hero.typePill:Hide()
    hero.metaText = hero:CreateFontString(nil, "OVERLAY")
    hero.metaText:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    hero.metaText:SetPoint("LEFT", hero.typePill, "RIGHT", 8, 0)

    -- right side: SECONDS | RESPONDED
    hero.respondedNum = hero:CreateFontString(nil, "OVERLAY")
    hero.respondedNum:SetFontObject(ns.Ledger.Fonts.OLLFontNumberBig)
    hero.respondedNum:SetPoint("TOPRIGHT", hero, "TOPRIGHT", -INSET - 30, -8)
    hero.respondedNum:SetJustifyH("RIGHT")
    hero.respondedOf = hero:CreateFontString(nil, "OVERLAY")
    hero.respondedOf:SetFontObject(ns.Ledger.Fonts.OLLFontNumberSmall)
    hero.respondedOf:SetPoint("BOTTOMLEFT", hero.respondedNum, "BOTTOMRIGHT", 1, 3)
    hero.respondedLbl = hero:CreateFontString(nil, "OVERLAY")
    hero.respondedLbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    hero.respondedLbl:SetPoint("TOPRIGHT", hero, "TOPRIGHT", -INSET, -44)
    hero.respondedLbl:SetText(ns.Track("Responded"))

    hero.vRule = ns.MakeHairline(hero, "dividerColor")
    hero.vRule:ClearAllPoints(); hero.vRule:SetSize(1, 34)
    hero.vRule:SetPoint("RIGHT", hero.respondedNum, "LEFT", -22, 2)

    hero.secondsNum = hero:CreateFontString(nil, "OVERLAY")
    hero.secondsNum:SetFontObject(ns.Ledger.Fonts.OLLFontNumberBig)
    hero.secondsNum:SetPoint("RIGHT", hero.vRule, "LEFT", -22, 0)
    hero.secondsLbl = hero:CreateFontString(nil, "OVERLAY")
    hero.secondsLbl:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    hero.secondsLbl:SetPoint("TOPRIGHT", hero.secondsNum, "BOTTOMRIGHT", 0, -2)
    hero.secondsLbl:SetText(ns.Track("Seconds"))

    -- tooltip hitbox over icon + name
    local hit = CreateFrame("Frame", nil, hero)
    hit:SetPoint("TOPLEFT", hero.icon, "TOPLEFT", 0, 0)
    hit:SetPoint("BOTTOMRIGHT", hero.name, "BOTTOMRIGHT", 0, -24)
    ns.AttachItemTooltip(hit, function(h) return h._link end)
    hero.hit = hit
    f.hero = hero
    self._rightItemHit = hit

    -- Roster scroll (between hero and award bar)
    local rightScroll = CreateFrame("ScrollFrame", "OLLLeaderRightScroll", rightPanel)
    rightScroll:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 0, 0)
    rightScroll:SetPoint("BOTTOMRIGHT", actionBar, "TOPRIGHT", 0, 0)
    rightScroll:EnableMouseWheel(true)
    rightScroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 40)))
    end)
    local rightChild = CreateFrame("Frame", nil, rightScroll)
    rightChild:SetSize(FRAME_WIDTH - LEFT_PANEL_WIDTH - 5, 1)
    rightScroll:SetScrollChild(rightChild)
    rightScroll:SetScript("OnSizeChanged", function(sf, w) rightChild:SetWidth(w) end)
    f.rightScrollChild = rightChild
    self._rightScrollChild = rightChild

    -- Roster table
    local roster = ns.MakeTable(rightChild, {
        { key = "player", label = "Player",     width = "1fr" },
        { key = "choice", label = "Choice",     width = 88, dot = true },
        { key = "roll",   label = "Roll",       width = 52, justify = "RIGHT" },
        { key = "count",  label = "Gear Count", width = 96, justify = "RIGHT" },
    }, { rowH = PLAYER_ROW_HEIGHT, headerH = 24 })
    roster:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 0, 0)
    roster:SetPoint("TOPRIGHT", rightChild, "TOPRIGHT", 0, 0)
    roster:SetHeight(24)
    f.roster = roster
    self._roster = roster

    -- Placeholder text (no selection / missing item)
    local placeholder = rightChild:CreateFontString(nil, "OVERLAY")
    placeholder:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    placeholder:SetPoint("TOPLEFT", rightChild, "TOPLEFT", INSET, -12)
    placeholder:Hide()
    f.placeholder = placeholder

    -- Waiting section
    local waitHdr = rightChild:CreateFontString(nil, "OVERLAY")
    waitHdr:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    waitHdr:Hide()
    f.waitHdr = waitHdr

    f:Hide()
    self._frame = f
    self:ApplyTheme(theme)
    return f
end

------------------------------------------------------------------------
-- Apply (or re-apply) the current theme to an already-created frame.
-- Widgets built from Widgets.lua re-tint themselves via Ledger.ApplyTheme;
-- this covers the regions this file owns.
------------------------------------------------------------------------
function LeaderFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()

    f.leftBg:SetVertexColor(C(theme, "panelBgColor"))
    f.divider:SetVertexColor(C(theme, "dividerColor"))
    f.hero.rule:SetVertexColor(C(theme, "dividerColor"))
    f.hero.vRule:SetVertexColor(C(theme, "dividerColor"))
    f.hero.metaText:SetTextColor(C(theme, "textDimColor"))
    f.hero.respondedNum:SetTextColor(C(theme, "timerBarFullColor"))
    f.hero.respondedOf:SetTextColor(C(theme, "textDimColor"))
    f.hero.respondedLbl:SetTextColor(C(theme, "textMutedColor"))
    f.hero.secondsNum:SetTextColor(C(theme, "textColor"))
    f.hero.secondsLbl:SetTextColor(C(theme, "textMutedColor"))
    f.placeholder:SetTextColor(C(theme, "textDimColor"))
    f.waitHdr:SetTextColor(C(theme, "textDimColor"))
    f.lootMasterBtn._text:SetTextColor(C(theme, "textMutedColor"))
    f.lootMasterBtn.nameText:SetTextColor(C(theme, "accentHiColor"))
    f.lootMasterBtn.caret:SetTextColor(C(theme, "textMutedColor"))
    if f.announceBtn.glow then f.announceBtn.glow:SetVertexColor(C(theme, "accentHiColor")) end

    for _, row in ipairs(self._itemRowPool) do row:ApplyTheme(theme) end
    for _, chip in ipairs(self._chipPool) do chip:ApplyTheme(theme) end

    -- Popups
    if ns.CheckPartyFrame then ns.CheckPartyFrame:ApplyTheme(theme) end
    for _, popup in ipairs({ self._lootMasterPopup, self._manualRollPopup, self._tradeQueuePopup,
                             self._pendingRollStartPopup, self._reassignPopup }) do
        if popup and popup.ApplyThemeExtra then popup:ApplyThemeExtra(theme) end
    end
end

------------------------------------------------------------------------
-- Contextual primary button
------------------------------------------------------------------------
function LeaderFrame:_PrimaryMode()
    local session = ns.Session
    if not session or not session:IsActive() then return "start_session" end
    if session._pendingPromptItems ~= nil then return "start_roll" end
    if session.state == session.STATE_ROLLING or session.state == session.STATE_RESOLVING then
        return "stop_roll"
    end
    return "idle"
end

function LeaderFrame:_OnPrimaryClick()
    local mode = self:_PrimaryMode()
    if mode == "start_session" then
        ns.Session:StartSession()
    elseif mode == "start_roll" then
        self:ShowPendingRollStartPopup()
    elseif mode == "stop_roll" then
        ns.Session:StopRoll()
    end
    self:Refresh()
end

------------------------------------------------------------------------
-- Refresh the display
------------------------------------------------------------------------
function LeaderFrame:Refresh()
    local f = self:GetFrame()
    if not f:IsShown() then return end

    local session = ns.Session
    if not session then return end
    local theme = ns.Theme:GetCurrent()

    -- Status pill
    if session:IsActive() then
        local detail = session.activeSessionId and FormatElapsed(session.activeSessionId) or nil
        if session.debugMode then
            f.statusPill:SetStatus("Debug", detail, theme.timerBarMidColor)
        else
            f.statusPill:SetStatus("Active", detail, theme.timerBarFullColor)
        end
        f.statusPill:Show()
    else
        f.statusPill:SetStatus("Inactive", nil, theme.choicePassColor)
        f.statusPill:Show()
    end

    -- Contextual primary
    local mode = self:_PrimaryMode()
    local allowed = session:IsLootMasterActionAllowed()
    if mode == "start_session" then
        f.primaryBtn:SetLabel("Start Session")
        f.primaryBtn:SetWidth(120)
        f.primaryBtn:SetEnabled(ns.IsLeader())
    elseif mode == "start_roll" then
        f.primaryBtn:SetLabel("Start Roll")
        f.primaryBtn:SetWidth(110)
        f.primaryBtn:SetEnabled(allowed)
    elseif mode == "stop_roll" then
        f.primaryBtn:SetLabel("Stop Roll")
        f.primaryBtn:SetWidth(110)
        f.primaryBtn:SetEnabled(allowed)
    else
        f.primaryBtn:SetLabel("Waiting for loot")
        f.primaryBtn:SetWidth(140)
        f.primaryBtn:SetEnabled(false)
    end

    -- Manual Roll: active session, not mid-roll, permitted
    f.manualRollBtn:SetEnabled(session:IsActive() and session.state == session.STATE_ACTIVE and allowed)

    -- Takeover: WoW leader/officer, session active, not the session leader
    f.takeoverBtn:SetEnabled(ns.IsLeader() and session:IsActive() and not ns.IsSessionLeader())

    -- End Session: session leader (or WoW leader) while active.  Outlined so
    -- it reads as available; MakeButton dims it itself when disabled.
    local canEnd = session:IsActive() and (ns.IsSessionLeader() or ns.IsLeader())
    f.endSessionBtn:SetEnabled(canEnd and true or false)

    -- Loot Master picker
    local canAssign = session:IsActive() and (ns.IsSessionLeader()
        or ns.NamesMatch(ns.GetPlayerNameRealm(), session.sessionLootMaster or ""))
    f.lootMasterBtn:SetEnabled(canAssign)
    local lm = session:IsActive() and (session.sessionLootMaster or "") or ""
    f.lootMasterBtn.nameText:SetText(lm ~= "" and StripRealm(lm) or "—")
    f.lootMasterBtn._text:ClearAllPoints()
    f.lootMasterBtn._text:SetPoint("LEFT", f.lootMasterBtn, "LEFT", 12, 0)

    -- Trade Queue
    local tq = session:GetTradeQueue()
    local pending = 0
    for _, e in ipairs(tq or {}) do if not e.awarded then pending = pending + 1 end end
    f.tradeQueueBtn:SetBadge(pending)
    f.tradeQueueBtn:SetEnabled((tq and #tq or 0) > 0)

    -- Check Party tool: only while a session is active
    f.checkPartyBtn:SetEnabled(ns.IsLeader() and session.state ~= session.STATE_IDLE)

    -- Close the manual roll popup if a roll is in progress or session ended
    if self._manualRollPopup and self._manualRollPopup:IsShown() then
        if not session:IsActive() or session.state ~= session.STATE_ACTIVE then
            self._manualRollPopup:Hide()
        end
    end

    -- Roll timer bar
    if session.state == session.STATE_ROLLING and session._rollTimerStart then
        self:StartTimer()
    else
        self:StopTimer()
    end

    if self._tradeQueuePopup and self._tradeQueuePopup:IsShown() then
        self:_RefreshTradeQueuePopup()
    end

    self:_RefreshLeftPanel()
    self:_RefreshRightPanel()
end

------------------------------------------------------------------------
-- Region pools (boss headers etc.).  Regions can only be hidden, never
-- destroyed, so anything created per refresh must be pooled.
------------------------------------------------------------------------
function LeaderFrame:_ResetRegionPools(parent)
    if parent._ollFsPool then
        for _, pool in pairs(parent._ollFsPool) do pool.used = 0 end
    end
    if parent._ollTexPool then
        for _, pool in pairs(parent._ollTexPool) do pool.used = 0 end
    end
end

function LeaderFrame:_AcquireFontString(parent, fontObj)
    parent._ollFsPool = parent._ollFsPool or {}
    local key = fontObj
    local pool = parent._ollFsPool[key]
    if not pool then
        pool = { used = 0 }
        parent._ollFsPool[key] = pool
    end
    pool.used = pool.used + 1
    local fs = pool[pool.used]
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY")
        pool[pool.used] = fs
    end
    if type(fontObj) == "string" then fs:SetFontObject(fontObj) else fs:SetFontObject(fontObj) end
    fs:ClearAllPoints()
    fs:SetWidth(0)
    fs:SetHeight(0)
    fs:SetJustifyH("LEFT")
    fs:SetText("")
    fs:Show()
    return fs
end

function LeaderFrame:_AcquireTexture(parent, layer)
    parent._ollTexPool = parent._ollTexPool or {}
    local pool = parent._ollTexPool[layer]
    if not pool then
        pool = { used = 0 }
        parent._ollTexPool[layer] = pool
    end
    pool.used = pool.used + 1
    local tex = pool[pool.used]
    if not tex then
        tex = parent:CreateTexture(nil, layer)
        pool[pool.used] = tex
    end
    tex:ClearAllPoints()
    tex:SetTexture(nil)
    tex:SetVertexColor(1, 1, 1, 1)
    tex:SetAlpha(1)
    tex:Show()
    return tex
end

------------------------------------------------------------------------
-- LEFT PANEL: boss headers + item rows
------------------------------------------------------------------------
function LeaderFrame:_RefreshLeftPanel()
    local sc = self._leftScrollChild
    if not sc then return end
    local session = ns.Session
    if not session then return end

    self:_RecycleItemRows()
    for _, region in ipairs({ sc:GetRegions() }) do region:Hide() end
    self:_ResetRegionPools(sc)

    local yOffset = 0
    local firstItemKey = nil

    -- === CURRENT BOSS ===
    if session:IsActive() and #session.currentItems > 0 then
        yOffset = self:_DrawSectionHeader(sc, yOffset, session.currentBoss or "Unknown")
        for idx, item in ipairs(session.currentItems) do
            local key = self:_MakeItemKey("current", nil, idx)
            if not firstItemKey then firstItemKey = key end
            yOffset = self:_DrawItemListRow(sc, yOffset, key, item,
                session.results and session.results[idx],
                (session.state == session.STATE_ROLLING or session.state == session.STATE_RESOLVING),
                session.responses and session.responses[idx], 1.0)
        end
    end

    -- === HISTORICAL BOSSES (newest first), dimmed to 72% ===
    local order = session.bossHistoryOrder or {}
    for i = #order, 1, -1 do
        local bossKey = order[i]
        local data = session.bossHistory[bossKey]
        if data and data.items and #data.items > 0 then
            yOffset = yOffset - 6
            yOffset = self:_DrawSectionHeader(sc, yOffset, bossKey)
            for idx, item in ipairs(data.items) do
                local key = self:_MakeItemKey("history", bossKey, idx)
                if not firstItemKey then firstItemKey = key end
                yOffset = self:_DrawItemListRow(sc, yOffset, key, item,
                    data.results and data.results[idx], false,
                    data.responses and data.responses[idx], 0.72)
            end
        end
    end

    if not firstItemKey then
        local empty = self:_AcquireFontString(sc, ns.Ledger.Fonts.OLLFontBodySmall)
        empty:SetPoint("TOPLEFT", sc, "TOPLEFT", INSET, -14)
        empty:SetText(session:IsActive() and "No loot captured yet." or "Start a session to begin.")
        empty:SetTextColor(C(ns.Theme:GetCurrent(), "textDimColor"))
        yOffset = -40
    end

    sc:SetHeight(math.abs(yOffset) + 20)

    if not self._selectedItem and firstItemKey then
        self._selectedItem = firstItemKey
    end
    if self._selectedItem and not self:_ItemKeyExists(self._selectedItem) then
        self._selectedItem = firstItemKey
    end
    self:_UpdateItemHighlights()
end

function LeaderFrame:_DrawSectionHeader(parent, yOffset, text)
    local theme = ns.Theme:GetCurrent()
    local header = self:_AcquireFontString(parent, ns.Ledger.Fonts.OLLFontLabel)
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", INSET, yOffset - 8)
    header:SetText("|cff" .. theme.sectionHeaderHex .. ns.Track(text) .. "|r")
    return yOffset - BOSS_HEADER_H
end

function LeaderFrame:_DrawItemListRow(parent, yOffset, key, item, result, isRolling, responses, alpha)
    local theme = ns.Theme:GetCurrent()
    local row = self:_AcquireItemRow(parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
    row:SetHeight(ITEM_ROW_HEIGHT)
    row._itemKey    = key
    row._winnerName = result and result.winner or nil
    row:SetItem(item, { meta = ItemMeta(item.link) })

    -- right slot: live responded/total while rolling, check when awarded, Queued otherwise
    if result and result.winner then
        row:SetRightCheck(true)
    elseif isRolling then
        local responded = 0
        for _ in pairs(responses or {}) do responded = responded + 1 end
        local total = 0
        for _ in pairs(ns.Session._rollEligiblePlayers or {}) do total = total + 1 end
        if total == 0 then total = #GetGroupMembers() end
        row:SetRight(responded .. "/" .. total, theme.timerBarFullColor)
    else
        row:SetRight("Queued", theme.textDimColor)
    end
    row:SetDimmed(alpha or 1)
    row:Show()
    return yOffset - ITEM_ROW_HEIGHT
end

------------------------------------------------------------------------
-- RIGHT PANEL: hero + roster + waiting chips + award bar state
------------------------------------------------------------------------
function LeaderFrame:_RefreshRightPanel()
    local f = self._frame
    local sc = self._rightScrollChild
    if not f or not sc then return end
    local session = ns.Session
    if not session then return end
    local theme = ns.Theme:GetCurrent()
    local hero, roster = f.hero, self._roster

    roster:ReleaseRows()
    self:_RecycleChips()
    self:_RecycleSegs()
    f.waitHdr:Hide()
    f.placeholder:Hide()

    local sel = self._selectedItem
    local item, result, responses, isCurrent
    if sel then item, result, responses, isCurrent = self:_ResolveSelectedItem() end

    if not item then
        hero:Hide()
        roster:Hide()
        f.placeholder:SetText(sel and "Item no longer available." or "Select an item on the left.")
        f.placeholder:Show()
        sc:SetHeight(40)
        self:_UpdateAwardBar(nil, nil, nil, {}, false)
        return
    end
    hero:Show(); roster:Show()

    -- === Hero ===
    local qr, qg, qb = GetItemQualityColor(item.quality or 1)
    hero.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    hero.iconEdge:SetBackdropBorderColor(qr, qg, qb, 0.7)
    hero.iconGlow:SetVertexColor(qr, qg, qb)
    hero.name:SetText(item.name or "Unknown")
    hero.name:SetTextColor(qr, qg, qb)
    hero.hit._link = item.link

    local stat = ns.RF_GetItemMainStat and ns.RF_GetItemMainStat(item.link)
    if stat and ns.RF_BADGE_COLORS and ns.RF_BADGE_COLORS[stat] then
        hero.statPill:SetText(stat)
        hero.statPill:SetColor(ns.RF_BADGE_COLORS[stat], true)
        hero.statPill:Show()
    else
        hero.statPill:Hide()
    end
    local typeLabel = ns.RF_GetItemTypeLabelAndColor and ns.RF_GetItemTypeLabelAndColor(item.link)
    hero.typePill:ClearAllPoints()
    if hero.statPill:IsShown() then hero.typePill:SetPoint("LEFT", hero.statPill, "RIGHT", 6, 0)
    else hero.typePill:SetPoint("TOPLEFT", hero.name, "BOTTOMLEFT", 0, -5) end
    if typeLabel then
        hero.typePill:SetText(typeLabel); hero.typePill:SetColor(nil, false); hero.typePill:Show()
    else
        hero.typePill:Hide()
    end
    hero.metaText:ClearAllPoints()
    local metaAnchor = hero.typePill:IsShown() and hero.typePill or (hero.statPill:IsShown() and hero.statPill or nil)
    if metaAnchor then hero.metaText:SetPoint("LEFT", metaAnchor, "RIGHT", 8, 0)
    else hero.metaText:SetPoint("TOPLEFT", hero.name, "BOTTOMLEFT", 0, -7) end
    local total = isCurrent and #(session.currentItems or {}) or 0
    if isCurrent and total > 0 then
        hero.metaText:SetText("· item " .. (sel.itemIdx or 0) .. " of " .. total)
    else
        hero.metaText:SetText(sel.bossKey and ("· " .. sel.bossKey) or "")
    end

    -- responded / total
    local isRollingItem = isCurrent
        and (session.state == session.STATE_ROLLING or session.state == session.STATE_RESOLVING)
        and not (result and result.winner)
    local responded = 0
    for _ in pairs(responses or {}) do responded = responded + 1 end
    local eligible = 0
    if isCurrent then
        for _ in pairs(session._rollEligiblePlayers or {}) do eligible = eligible + 1 end
    end
    if eligible == 0 then eligible = #GetGroupMembers() end
    hero.respondedNum:SetText(tostring(responded))
    hero.respondedOf:SetText("/" .. eligible)
    hero.respondedNum:SetTextColor(C(theme, isRollingItem and "timerBarFullColor" or "textMutedColor"))
    if isRollingItem and session._rollTimerStart then
        local remaining = math.max(0, (session._rollTimerDuration or 0) - (GetTime() - session._rollTimerStart))
        hero.secondsNum:SetText(tostring(math.ceil(remaining)))
    else
        hero.secondsNum:SetText("—")
    end

    -- === Roster ===
    local sorted, waiting = self:_BuildSortedPlayerList(responses or {}, result, session, isRollingItem)
    local leaders = GetLeaderSet()
    local maxCount = 1
    for _, e in ipairs(sorted) do if (e.count or 0) > maxCount then maxCount = e.count end end
    for _, e in ipairs(waiting) do if (e.count or 0) > maxCount then maxCount = e.count end end

    for _, entry in ipairs(sorted) do
        local row = roster:AcquireRow()
        self:_FillRosterRow(row, entry, result, isRollingItem, sel.itemIdx, leaders, maxCount, theme)
    end
    roster:SetHeight(roster:GetContentHeight())
    roster:Layout()

    local y = roster:GetContentHeight()

    -- === Waiting chips ===
    if #waiting > 0 then
        f.waitHdr:ClearAllPoints()
        f.waitHdr:SetPoint("TOPLEFT", sc, "TOPLEFT", INSET, -(y + 6))
        f.waitHdr:SetText(ns.Track("Waiting on " .. #waiting))
        f.waitHdr:Show()
        y = y + WAIT_HDR_H + 4
        local x, rowY = INSET, y
        local avail = sc:GetWidth() - INSET * 2
        for _, entry in ipairs(waiting) do
            local chip = self:_AcquireChip(sc)
            chip:SetText(StripRealm(entry.player))
            local w = chip:GetWidth()
            if x + w > INSET + avail and x > INSET then
                x = INSET
                rowY = rowY + CHIP_H + 5
            end
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", sc, "TOPLEFT", x, -rowY)
            chip:Show()
            x = x + w + 5
        end
        y = rowY + CHIP_H
    end
    sc:SetHeight(y + 12)

    self:_UpdateAwardBar(sel, item, result, sorted, isRollingItem, waiting)
end

-- One roster row.  During a roll the LM gets a segmented control to set a
-- player's choice for them; otherwise the choice is a coloured dot + label.
function LeaderFrame:_FillRosterRow(row, entry, result, isRollingItem, itemIdx, leaders, maxCount, theme)
    row._playerName = entry.player
    if not row._altTooltip then
        ns.AttachAltTooltip(row, function() return row._playerName end)
        row._altTooltip = true
    end

    -- Player cell: name + LEAD badge or "alt of X"
    local displayName = StripRealm(entry.player)
    local suffix = ""
    if leaders[displayName] then
        suffix = "  |cff" .. theme.sectionHeaderHex .. ns.Track("lead") .. "|r"
    else
        local mainIdentity = ns.PlayerLinks:ResolveIdentity(entry.player)
        if mainIdentity and mainIdentity ~= entry.player then
            local r, g, b = C(theme, "textDimColor")
            suffix = string.format("  |cff%02x%02x%02xalt of %s|r", r * 255, g * 255, b * 255, StripRealm(mainIdentity))
        end
    end
    row:SetCell("player", displayName .. suffix, theme.textColor)

    -- Choice cell (cross-fades when this player's choice changes; the row
    -- pool hands rows back in the same order, so compare against what the
    -- row showed last refresh)
    local choiceColor, choiceText
    if entry.status == "waiting" then
        choiceColor, choiceText = theme.choiceWaitColor, ns.Track("Waiting")
    elseif entry.choice == "Pass" then
        choiceColor, choiceText = theme.choicePassColor, ns.Track("Pass")
    else
        choiceColor = ns.Theme:ChoiceColor(entry.option or entry.choice, theme)
        choiceText  = ns.Track(entry.choice or "?")
    end
    row:SetCell("choice", choiceText, choiceColor)
    if row._lastPlayer == entry.player and row._lastChoice ~= choiceText and not InCombatLockdown() then
        ns.Ledger.CrossFadeText(row.cells.choice, choiceText, choiceColor, 0.1)
    end
    row._lastPlayer, row._lastChoice = entry.player, choiceText

    -- Roll cell
    if entry.roll then
        row:SetCell("roll", tostring(entry.roll), theme.textColor)
    else
        row:SetCell("roll", "—", theme.textDimColor)
    end

    -- Count cell: number + 38x3 bar to its left
    row:SetCell("count", tostring(entry.count or 0), theme.textColor)
    if not row._countBar then
        local track = row:CreateTexture(nil, "ARTWORK")
        track:SetTexture(ns.Ledger.TEX.white); track:SetSize(38, 3)
        local fill = row:CreateTexture(nil, "ARTWORK", nil, 1)
        fill:SetTexture(ns.Ledger.TEX.white); fill:SetHeight(3)
        fill:SetPoint("LEFT", track, "LEFT", 0, 0)
        row._countBar, row._countFill = track, fill
    end
    row._countBar:ClearAllPoints()
    row._countBar:SetPoint("RIGHT", row.cells.count, "RIGHT", -(row.cells.count:GetStringWidth() + 8), 0)
    row._countBar:SetVertexColor(C(theme, "strokeDimColor"))
    row._countFill:SetVertexColor(0.545, 0.565, 0.608) -- #8b909b
    row._countFill:SetWidth(math.max(1, 38 * math.min(1, (entry.count or 0) / math.max(1, maxCount))))
    row._countBar:Show(); row._countFill:Show()

    -- Passed rows dim to 55%
    row:SetAlpha(entry.choice == "Pass" and 0.55 or 1)

    -- Winner row highlighted
    row:SetSelected(result and result.winner and ns.NamesMatch(result.winner, entry.player) or false)

    -- LM override control while rolling: segmented group over the Choice/Roll columns
    if isRollingItem then
        local seg = self:_AcquireSeg(row)
        seg:SetOptions((ns.Session and ns.Session.rollOptions) or ns.DEFAULT_ROLL_OPTIONS)
        seg:SetSelected(entry.choice)
        seg:ClearAllPoints()
        seg:SetPoint("RIGHT", row.cells.count, "LEFT", -8, 0)
        local capturedPlayer, capturedItemIdx = entry.player, itemIdx
        seg:SetOnPick(function(optName)
            local sess = ns.Session
            if not sess then return end
            sess:OnRollResponseReceived({ itemIdx = capturedItemIdx, choice = optName, player = capturedPlayer }, capturedPlayer)
            if ns.NamesMatch(capturedPlayer, ns.GetPlayerNameRealm()) then
                if ns.RollFrame then ns.RollFrame:SetExternalSelection(capturedItemIdx, optName) end
            else
                ns.Comm:Send(ns.Comm.MSG.PLAYER_SELECTION_UPDATE, { itemIdx = capturedItemIdx, choice = optName }, capturedPlayer)
            end
        end)
        seg:Show()
        row.cells.choice:Hide()
        if row.dots.choice then row.dots.choice:Hide() end
    else
        row.cells.choice:Show()
    end
end

------------------------------------------------------------------------
-- Award bar state
------------------------------------------------------------------------
function LeaderFrame:_UpdateAwardBar(sel, item, result, sortedPlayers, isRollingItem, waiting)
    local f = self._frame
    if not f then return end
    local session = ns.Session
    local theme = ns.Theme:GetCurrent()

    if sel and item and result and result.winner and sel.source == "current" then
        local itemIdx = sel.itemIdx
        f.announceBtn:SetLabel("Announce " .. StripRealm(result.winner))
        local sub = (result.choice or "") .. (result.roll and (" " .. result.roll) or "")
        f.announceBtn:SetSubLabel(sub ~= "" and sub or nil)
        f.announceBtn:SetWidth(math.max(160, f.announceBtn._text:GetStringWidth()
            + (f.announceBtn._sub:IsShown() and (f.announceBtn._sub:GetStringWidth() + 6) or 0) + 32))
        f.announceBtn:SetScript("OnClick", function() session:AnnounceWinner(itemIdx) end)
        f.announceBtn:Show()
        if self._lastResolvedKey ~= (result.winner .. "#" .. itemIdx) then
            self._lastResolvedKey = result.winner .. "#" .. itemIdx
            ns.Ledger.PulseOnce(f.announceBtn.glow, 0.3)
        end
        f.rerollBtn:SetScript("OnClick", function() session:RerollItem(itemIdx) end)
        f.rerollBtn:Show()
        f.reassignBtn:SetScript("OnClick", function() LeaderFrame:ShowReassignPopup(itemIdx, item) end)
        f.reassignBtn:Show()
        f.passWaitingBtn:Hide()
    else
        f.announceBtn:Hide()
        f.rerollBtn:Hide()
        f.reassignBtn:Hide()
        if isRollingItem and waiting and #waiting > 0 then
            local capturedWaiting, capturedItemIdx = waiting, sel.itemIdx
            f.passWaitingBtn:SetLabel("Pass remaining")
            f.passWaitingBtn:SetSubLabel(tostring(#waiting))
            f.passWaitingBtn:SetScript("OnClick", function()
                local sess = ns.Session
                if not sess then return end
                for _, entry in ipairs(capturedWaiting) do
                    sess:OnRollResponseReceived({ itemIdx = capturedItemIdx, choice = "Pass", player = entry.player }, entry.player)
                    if ns.NamesMatch(entry.player, ns.GetPlayerNameRealm()) then
                        if ns.RollFrame then ns.RollFrame:SetExternalSelection(capturedItemIdx, "Pass") end
                    else
                        ns.Comm:Send(ns.Comm.MSG.PLAYER_SELECTION_UPDATE, { itemIdx = capturedItemIdx, choice = "Pass" }, entry.player)
                    end
                end
            end)
            f.passWaitingBtn:Show()
        else
            f.passWaitingBtn:Hide()
        end
    end
end

------------------------------------------------------------------------
-- Build sorted player list for right panel.
-- Returns (responded[], waiting[]).  Same array/sort as before; the only
-- change is that "waiting" players are partitioned out for the chip strip.
------------------------------------------------------------------------
function LeaderFrame:_BuildSortedPlayerList(responses, result, session, isRollingItem)
    local members = GetGroupMembers()
    local playerMap = {}

    local rollLookup = {}
    if result and result.rankedCandidates then
        for _, c in ipairs(result.rankedCandidates) do
            rollLookup[c.player] = c.roll
        end
    end

    for _, name in ipairs(members) do
        if not playerMap[name] then
            playerMap[name] = {
                player = name, choice = nil, roll = nil,
                count = ns.LootCount:GetCount(name),
                priority = 999, status = "waiting",
            }
        end
    end

    for player, data in pairs(responses) do
        local choiceName = data.choice
        local opt = session:_FindRollOption(choiceName)
        local priority = 998
        if choiceName == "Pass" then
            priority = 900
        elseif opt then
            priority = opt.priority or 500
        end
        local roll = rollLookup[player] or data.roll or nil
        playerMap[player] = {
            player = player, choice = choiceName, roll = roll,
            count = data.countAtRoll or ns.LootCount:GetCount(player),
            priority = priority, status = "responded", option = opt,
        }
    end

    local sorted, waiting = {}, {}
    for _, entry in pairs(playerMap) do
        if entry.status == "waiting" then tinsert(waiting, entry) else tinsert(sorted, entry) end
    end

    if isRollingItem then
        table.sort(sorted, function(a, b)
            local ra, rb = a.roll or 0, b.roll or 0
            if ra ~= rb then return ra > rb end
            return (a.player or "") < (b.player or "")
        end)
    else
        table.sort(sorted, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            if a.priority >= 900 then return (a.player or "") < (b.player or "") end
            if a.count ~= b.count then return a.count < b.count end
            local ra, rb = a.roll or 0, b.roll or 0
            if ra ~= rb then return ra > rb end
            return (a.player or "") < (b.player or "")
        end)
    end
    table.sort(waiting, function(a, b) return (a.player or "") < (b.player or "") end)

    return sorted, waiting
end

------------------------------------------------------------------------
-- Item key helpers
------------------------------------------------------------------------
function LeaderFrame:_MakeItemKey(source, bossKey, itemIdx)
    return { source = source, bossKey = bossKey, itemIdx = itemIdx }
end

function LeaderFrame:_ItemKeysEqual(a, b)
    if not a or not b then return false end
    return a.source == b.source and a.bossKey == b.bossKey and a.itemIdx == b.itemIdx
end

function LeaderFrame:_ItemKeyExists(key)
    local session = ns.Session
    if not session then return false end
    if key.source == "current" then
        return session.currentItems and session.currentItems[key.itemIdx] ~= nil
    elseif key.source == "history" then
        local data = session.bossHistory and session.bossHistory[key.bossKey]
        return data and data.items and data.items[key.itemIdx] ~= nil
    end
    return false
end

function LeaderFrame:_ResolveSelectedItem()
    local sel = self._selectedItem
    if not sel then return nil end
    local session = ns.Session
    if not session then return nil end
    if sel.source == "current" then
        local item = session.currentItems and session.currentItems[sel.itemIdx]
        local result = session.results and session.results[sel.itemIdx]
        local responses = session.responses and session.responses[sel.itemIdx]
        return item, result, responses, true
    elseif sel.source == "history" then
        local data = session.bossHistory and session.bossHistory[sel.bossKey]
        if data then
            return data.items and data.items[sel.itemIdx],
                   data.results and data.results[sel.itemIdx],
                   data.responses and data.responses[sel.itemIdx],
                   false
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Pools: item rows (left), chips + segmented controls (right)
------------------------------------------------------------------------
function LeaderFrame:_AcquireItemRow(parent)
    for _, row in ipairs(self._itemRowPool) do
        if not row._inUse then
            row._inUse = true
            row._itemKey = nil
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end
    local row = ns.MakeItemRow(parent, ITEM_ROW_HEIGHT, { iconSize = 28 })
    row:SetScript("OnClick", function(r)
        LeaderFrame._selectedItem = r._itemKey
        LeaderFrame:_UpdateItemHighlights()
        LeaderFrame:_RefreshRightPanel()
    end)
    row:HookScript("OnEnter", function(r)
        if r._link then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            if r._link:find("|H") then GameTooltip:SetHyperlink(r._link) else GameTooltip:SetText(r._link) end
            if r._winnerName then
                local mainIdentity = ns.PlayerLinks:ResolveIdentity(r._winnerName)
                if mainIdentity and mainIdentity ~= r._winnerName then
                    GameTooltip:AddLine("Winner's Main: " .. ns.StripRealm(mainIdentity), 1, 1, 1)
                end
            end
            GameTooltip:Show()
        end
    end)
    row:HookScript("OnLeave", function() GameTooltip:Hide() end)
    row._inUse = true
    tinsert(self._itemRowPool, row)
    return row
end

function LeaderFrame:_RecycleItemRows()
    for _, row in ipairs(self._itemRowPool) do
        row._inUse = false
        row._itemKey = nil
        row:Hide()
    end
end

function LeaderFrame:_UpdateItemHighlights()
    for _, row in ipairs(self._itemRowPool) do
        if row._inUse and row:IsShown() then
            row:SetSelected(self:_ItemKeysEqual(self._selectedItem, row._itemKey))
        end
    end
end

function LeaderFrame:_AcquireChip(parent)
    for _, chip in ipairs(self._chipPool) do
        if not chip._inUse then chip._inUse = true; chip:SetParent(parent); return chip end
    end
    local chip = ns.MakePill(parent, "", nil, { h = CHIP_H })
    chip._text:SetTextColor(0.337, 0.361, 0.404) -- #565c67
    chip._inUse = true
    tinsert(self._chipPool, chip)
    return chip
end

function LeaderFrame:_RecycleChips()
    for _, chip in ipairs(self._chipPool) do chip._inUse = false; chip:Hide() end
end

function LeaderFrame:_AcquireSeg(row)
    for _, seg in ipairs(self._segPool) do
        if not seg._inUse then seg._inUse = true; seg:SetParent(row); return seg end
    end
    local seg = ns.MakeSegmented(row, ns.DEFAULT_ROLL_OPTIONS, nil, { h = 20, defaultW = 46, passW = 40 })
    seg._inUse = true
    tinsert(self._segPool, seg)
    return seg
end

function LeaderFrame:_RecycleSegs()
    for _, seg in ipairs(self._segPool) do seg._inUse = false; seg:Hide() end
end

-- Kept for callers that still reference the old player-row pool API
function LeaderFrame:_RecyclePlayerRows()
    if self._roster then self._roster:ReleaseRows() end
    self:_RecycleSegs()
end

------------------------------------------------------------------------
-- Popup scaffold shared by the four popups
------------------------------------------------------------------------
local function MakePopup(name, w, h, title, x, y)
    local popup = ns.MakeLedgerFrame(name, w, h, nil, { strata = "DIALOG", x = x or 0, y = y or 0 })
    popup.header = ns.MakeHeaderBar(popup, title, nil, { height = 44 })
    popup:Hide()
    return popup
end

------------------------------------------------------------------------
-- Loot Master Popup (picker)
------------------------------------------------------------------------
local function GetGroupLeaders()
    local leaders = {}
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        tinsert(leaders, ns.GetPlayerNameRealm())
    elseif IsInRaid() then
        for i = 1, numMembers do
            local name, rank = GetRaidRosterInfo(i)
            if name and rank and rank >= 1 then
                local full = name
                if not full:find("-") then full = full .. "-" .. (GetNormalizedRealmName() or "") end
                tinsert(leaders, full)
            end
        end
        if #leaders == 0 then tinsert(leaders, ns.GetPlayerNameRealm()) end
    else
        local leaderName
        if UnitIsGroupLeader("player") then
            leaderName = ns.GetPlayerNameRealm()
        else
            for i = 1, numMembers - 1 do
                local unit = "party" .. i
                if UnitIsGroupLeader(unit) then
                    local name = GetUnitName(unit, true)
                    if name and not name:find("-") then name = name .. "-" .. (GetNormalizedRealmName() or "") end
                    leaderName = name
                    break
                end
            end
        end
        tinsert(leaders, leaderName or ns.GetPlayerNameRealm())
    end
    return leaders
end

function LeaderFrame:ShowLootMasterPopup()
    local isLM = ns.NamesMatch(ns.GetPlayerNameRealm(), ns.Session.sessionLootMaster or "")
    if not ns.IsSessionLeader() and not isLM then return end
    if not self._lootMasterPopup then self:_CreateLootMasterPopup() end
    self:_RefreshLootMasterPopup()
    self._lootMasterPopup:Show()
    ns.RaiseFrame(self._lootMasterPopup)
end

function LeaderFrame:_CreateLootMasterPopup()
    local popup = MakePopup("OLLLootMasterPopup", 320, 300, "Assign Loot Master", -200, 0)

    popup.currentLabel = popup:CreateFontString(nil, "OVERLAY")
    popup.currentLabel:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    popup.currentLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, -54)

    local scroll = CreateFrame("ScrollFrame", nil, popup)
    scroll:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -74)
    scroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 54)
    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(316, 1)
    scroll:SetScrollChild(scrollChild)
    popup.scrollChild = scrollChild

    local footer = ns.MakeBar(popup, 52, "barBgColorAlt", "TOP")
    footer:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 2, 2)
    footer:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 2)

    local assignBtn = ns.MakeButton(footer, "primary", "Assign", 100, 28)
    assignBtn:SetPoint("LEFT", footer, "LEFT", INSET - 2, 0)
    assignBtn:SetEnabled(false)
    assignBtn:SetScript("OnClick", function()
        if popup._selectedPlayer then
            ns.Session:UpdateSessionLootMaster(popup._selectedPlayer)
            popup:Hide()
        end
    end)
    popup.assignBtn = assignBtn

    local cancelBtn = ns.MakeButton(footer, "quiet", "Close", 80, 28)
    cancelBtn:SetPoint("RIGHT", footer, "RIGHT", -(INSET - 2), 0)
    cancelBtn:SetScript("OnClick", function() popup:Hide() end)

    popup._selectedPlayer = nil
    popup._rows = {}
    function popup:ApplyThemeExtra(th)
        self.currentLabel:SetTextColor(C(th, "textMutedColor"))
        for _, row in ipairs(self._rows) do
            row.hair:SetVertexColor(C(th, "histSepColor"))
            row.hl:SetVertexColor(C(th, "highlightColor"))
            row.sel:SetVertexColor(C(th, "selectedColor"))
            row.tick:SetVertexColor(C(th, "accentColor"))
        end
    end
    popup:ApplyThemeExtra(ns.Theme:GetCurrent())
    self._lootMasterPopup = popup
end

function LeaderFrame:_RefreshLootMasterPopup()
    local popup = self._lootMasterPopup
    if not popup then return end
    local theme = ns.Theme:GetCurrent()

    local currentLM = (ns.Session and ns.Session.sessionLootMaster) or ""
    popup.currentLabel:SetText("Current loot master: " .. (currentLM ~= "" and StripRealm(currentLM) or "none"))

    for _, row in ipairs(popup._rows) do row._inUse = false; row:Hide() end
    popup._selectedPlayer = nil
    popup.assignBtn:SetEnabled(false)

    local leaders = GetGroupLeaders()
    if currentLM ~= "" then
        local found = false
        for _, name in ipairs(leaders) do if ns.NamesMatch(name, currentLM) then found = true break end end
        if not found then tinsert(leaders, 1, currentLM) end
    end

    local scrollChild = popup.scrollChild
    local rowPool = popup._rows
    local yPos = 0
    for idx, name in ipairs(leaders) do
        local row = rowPool[idx]
        if not row then
            row = CreateFrame("Button", nil, scrollChild)
            row:SetHeight(30)
            row.hair = ns.MakeHairline(row, "histSepColor")
            row.hair:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); row.hair:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
            row.sel = row:CreateTexture(nil, "BACKGROUND"); row.sel:SetTexture(ns.Ledger.TEX.white); row.sel:SetAllPoints(); row.sel:Hide()
            row.hl = row:CreateTexture(nil, "BACKGROUND", nil, 1); row.hl:SetTexture(ns.Ledger.TEX.white); row.hl:SetAllPoints(); row.hl:Hide()
            row.tick = row:CreateTexture(nil, "ARTWORK"); row.tick:SetTexture(ns.Ledger.TEX.white); row.tick:SetWidth(2)
            row.tick:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); row.tick:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0); row.tick:Hide()
            row.nameText = row:CreateFontString(nil, "OVERLAY")
            row.nameText:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
            row.nameText:SetPoint("LEFT", row, "LEFT", INSET, 0)
            row.nameText:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
            row.nameText:SetJustifyH("LEFT")
            row.hint = row:CreateFontString(nil, "OVERLAY")
            row.hint:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
            row.hint:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
            row:SetScript("OnEnter", function(r) r.hl:Show() end)
            row:SetScript("OnLeave", function(r) r.hl:Hide() end)
            rowPool[idx] = row
        end
        local isCurrentLM = ns.NamesMatch(name, currentLM)
        row.nameText:SetText(StripRealm(name))
        row.nameText:SetTextColor(C(theme, "textColor"))
        row.hint:SetText(isCurrentLM and ns.Track("current") or "")
        row.hint:SetTextColor(C(theme, "accentColor"))
        row.sel:SetVertexColor(C(theme, "selectedColor")); row.sel:Hide()
        row.tick:SetVertexColor(C(theme, "accentColor")); row.tick:Hide()
        row.hair:SetVertexColor(C(theme, "histSepColor"))
        row.hl:SetVertexColor(C(theme, "highlightColor")); row.hl:Hide()
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yPos)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, yPos)
        local captureName = name
        row:SetScript("OnClick", function()
            for _, r in ipairs(rowPool) do if r._inUse then r.sel:Hide(); r.tick:Hide() end end
            row.sel:Show(); row.tick:Show()
            popup._selectedPlayer = captureName
            popup.assignBtn:SetEnabled(true)
        end)
        row._inUse = true
        row:Show()
        yPos = yPos - 30
    end
    scrollChild:SetHeight(math.max(1, -yPos))
end

------------------------------------------------------------------------
-- Trade Queue Popup (420x300): grouped by winner, first Open Trade is primary
------------------------------------------------------------------------
function LeaderFrame:ShowTradeQueuePopup()
    if not self._tradeQueuePopup then self:_CreateTradeQueuePopup() end
    self:_RefreshTradeQueuePopup()
    self._tradeQueuePopup:Show()
    ns.RaiseFrame(self._tradeQueuePopup)
end

function LeaderFrame:_RefreshTradeQueuePopupIfShown()
    if self._tradeQueuePopup and self._tradeQueuePopup:IsShown() then
        self:_RefreshTradeQueuePopup()
    end
end

function LeaderFrame:_CreateTradeQueuePopup()
    local popup = MakePopup("OLLTradeQueuePopup", 420, 300, "Trade Queue", 300, 0)

    -- queue-length badge next to the title
    popup.badge = CreateFrame("Frame", nil, popup.header, "BackdropTemplate")
    popup.badge:SetSize(22, 18)
    popup.badge:SetPoint("LEFT", popup.header.title, "RIGHT", 10, 0)
    ns.SkinNineSlice(popup.badge, "pill")
    popup.badge.text = popup.badge:CreateFontString(nil, "OVERLAY")
    popup.badge.text:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    popup.badge.text:SetPoint("CENTER")

    local scroll = CreateFrame("ScrollFrame", nil, popup)
    scroll:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -46)
    scroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 36)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 30)))
    end)
    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(416, 1)
    scroll:SetScrollChild(scrollChild)
    popup._scrollChild = scrollChild

    popup.note = popup:CreateFontString(nil, "OVERLAY")
    popup.note:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    popup.note:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", INSET, 12)
    popup.note:SetText("Items drop off the queue automatically once the trade completes.")

    popup._blocks = {}
    function popup:ApplyThemeExtra(th)
        self.badge:SetBackdropColor(C(th, "accentColor"))
        self.badge:SetBackdropBorderColor(C(th, "accentColor"))
        self.badge.text:SetTextColor(C(th, "primaryBtnTextColor"))
        self.note:SetTextColor(0.337, 0.361, 0.404)
        for _, block in ipairs(self._blocks) do
            block.hair:SetVertexColor(C(th, "histSepColor"))
            block.countFS:SetTextColor(C(th, "textMutedColor"))
            for _, r in ipairs(block.itemRows) do r.hair:SetVertexColor(C(th, "histSepColor")) end
        end
    end
    popup:ApplyThemeExtra(ns.Theme:GetCurrent())
    self._tradeQueuePopup = popup
end

local function ClassColorFor(nameRealm)
    local short = StripRealm(nameRealm)
    for i = 1, GetNumGroupMembers() do
        local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
        local uname = GetUnitName(unit, true)
        if uname and ns.NamesMatch(uname, nameRealm) then
            local _, classFile = UnitClass(unit)
            local c = classFile and RAID_CLASS_COLORS[classFile]
            if c then return { c.r, c.g, c.b } end
        end
    end
    if ns.NamesMatch(ns.GetPlayerNameRealm(), nameRealm) then
        local _, classFile = UnitClass("player")
        local c = classFile and RAID_CLASS_COLORS[classFile]
        if c then return { c.r, c.g, c.b } end
    end
    return nil
end

function LeaderFrame:_RefreshTradeQueuePopup()
    local popup = self._tradeQueuePopup
    if not popup then return end
    local theme = ns.Theme:GetCurrent()
    local scrollChild = popup._scrollChild

    for _, block in ipairs(popup._blocks) do block:Hide() end
    if popup._emptyMsg then popup._emptyMsg:Hide() end

    local session = ns.Session
    local tradeQueue = session and session:GetTradeQueue()
    local pendingCount = 0
    for _, e in ipairs(tradeQueue or {}) do if not e.awarded then pendingCount = pendingCount + 1 end end
    popup.badge.text:SetText(tostring(pendingCount))
    popup.badge:SetWidth(math.max(22, popup.badge.text:GetStringWidth() + 12))
    popup.badge:SetShown(pendingCount > 0)

    if not tradeQueue or #tradeQueue == 0 then
        if not popup._emptyMsg then
            local msg = scrollChild:CreateFontString(nil, "OVERLAY")
            msg:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
            msg:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", INSET, -14)
            msg:SetText("No items in the trade queue.")
            popup._emptyMsg = msg
        end
        popup._emptyMsg:SetTextColor(C(theme, "textDimColor"))
        popup._emptyMsg:Show()
        scrollChild:SetHeight(40)
        return
    end

    -- Group entries by player, preserving order of first appearance
    local playerItems, playerOrder = {}, {}
    for _, entry in ipairs(tradeQueue) do
        if not playerItems[entry.winner] then
            playerItems[entry.winner] = {}
            tinsert(playerOrder, entry.winner)
        end
        tinsert(playerItems[entry.winner], entry)
    end

    local PLAYER_HDR_H, ITEM_H = 38, 26
    local yPos = 0
    local firstPending = true

    for blockIdx, winner in ipairs(playerOrder) do
        local entries = playerItems[winner]
        local block = popup._blocks[blockIdx]
        if not block then
            block = CreateFrame("Frame", nil, scrollChild)
            block.hair = ns.MakeHairline(block, "histSepColor")
            block.hair:SetPoint("BOTTOMLEFT", block, "BOTTOMLEFT", 0, 0); block.hair:SetPoint("BOTTOMRIGHT", block, "BOTTOMRIGHT", 0, 0)

            block.avatar = block:CreateTexture(nil, "ARTWORK")
            block.avatar:SetTexture(ns.Ledger.TEX.dot); block.avatar:SetSize(24, 24)
            block.avatar:SetPoint("TOPLEFT", block, "TOPLEFT", INSET, -7)

            block.playerFS = block:CreateFontString(nil, "OVERLAY")
            block.playerFS:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
            block.playerFS:SetPoint("LEFT", block.avatar, "RIGHT", 10, 0)
            block.countFS = block:CreateFontString(nil, "OVERLAY")
            block.countFS:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
            block.countFS:SetPoint("LEFT", block.playerFS, "RIGHT", 4, 0)

            block.tradeBtn = ns.MakeButton(block, "outline", "Open Trade", 120, 28)
            block.tradeBtn:SetPoint("TOPRIGHT", block, "TOPRIGHT", -INSET, -5)
            block.doneFS = block:CreateFontString(nil, "OVERLAY")
            block.doneFS:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
            block.doneFS:SetPoint("RIGHT", block, "TOPRIGHT", -INSET, -19)
            block.doneFS:SetText(ns.Track("done"))
            block.doneFS:Hide()
            block.itemRows = {}
            ns.AttachAltTooltip(block, function() return block._winner end)
            popup._blocks[blockIdx] = block
        end
        block._winner = winner

        local allAwarded = true
        for _, e in ipairs(entries) do if not e.awarded then allAwarded = false break end end

        local cc = ClassColorFor(winner)
        if cc then block.avatar:SetVertexColor(cc[1] * 0.55, cc[2] * 0.55, cc[3] * 0.55, 1)
        else block.avatar:SetVertexColor(C(theme, "strokeColor")) end
        block.playerFS:SetText(StripRealm(winner))
        block.playerFS:SetTextColor(C(theme, "textColor"))
        block.countFS:SetText("· " .. #entries .. (#entries == 1 and " item" or " items"))
        block.countFS:SetTextColor(C(theme, "textMutedColor"))
        block.hair:SetVertexColor(C(theme, "histSepColor"))
        block.doneFS:SetTextColor(C(theme, "timerBarFullColor"))

        if allAwarded then
            block.tradeBtn:Hide()
            block.doneFS:Show()
        else
            block.doneFS:Hide()
            block.tradeBtn:SetStyle(firstPending and "primary" or "outline")
            firstPending = false
            local captureWinner = winner
            block.tradeBtn:SetScript("OnClick", function()
                local shortName = StripRealm(captureWinner)
                if shortName == "" then return end
                if UnitExists(shortName) then
                    ns.LootHandler._pendingTradeTarget = captureWinner
                    InitiateTrade(shortName)
                    return
                end
                for i = 1, GetNumGroupMembers() do
                    local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
                    local unitName = GetUnitName(unit, true)
                    if unitName and ns.NamesMatch(unitName, captureWinner) then
                        ns.LootHandler._pendingTradeTarget = captureWinner
                        InitiateTrade(unit)
                        return
                    end
                end
                ns.ChatPrint("Normal", "Could not find " .. captureWinner .. " to trade. Are they nearby?")
            end)
            block.tradeBtn:Show()
        end

        for i, entry in ipairs(entries) do
            local itemRow = block.itemRows[i]
            if not itemRow then
                itemRow = CreateFrame("Frame", nil, block)
                itemRow:SetHeight(ITEM_H)
                itemRow:EnableMouse(true)
                itemRow.hair = ns.MakeHairline(itemRow, "histSepColor")
                itemRow.hair:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 0, 0); itemRow.hair:SetPoint("TOPRIGHT", itemRow, "TOPRIGHT", 0, 0)
                itemRow.icon = itemRow:CreateTexture(nil, "ARTWORK")
                itemRow.icon:SetSize(16, 16)
                itemRow.icon:SetPoint("LEFT", itemRow, "LEFT", INSET + 26, 0)
                itemRow.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                itemRow.nameFS = itemRow:CreateFontString(nil, "OVERLAY")
                itemRow.nameFS:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
                itemRow.nameFS:SetPoint("LEFT", itemRow.icon, "RIGHT", 8, 0)
                itemRow.nameFS:SetPoint("RIGHT", itemRow, "RIGHT", -INSET, 0)
                itemRow.nameFS:SetJustifyH("LEFT"); itemRow.nameFS:SetWordWrap(false)
                ns.AttachItemTooltip(itemRow, function(r) return r._link end)
                block.itemRows[i] = itemRow
            end
            itemRow:ClearAllPoints()
            itemRow:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -(PLAYER_HDR_H + (i - 1) * ITEM_H))
            itemRow:SetPoint("TOPRIGHT", block, "TOPRIGHT", 0, -(PLAYER_HDR_H + (i - 1) * ITEM_H))
            itemRow.icon:SetTexture(entry.itemIcon or "Interface\\Icons\\INV_Misc_QuestionMark")
            itemRow._link = entry.itemLink
            itemRow.hair:SetVertexColor(C(theme, "histSepColor"))
            local qr, qg, qb = GetItemQualityColor(entry.itemQuality or 1)
            itemRow.nameFS:SetTextColor(qr, qg, qb)
            itemRow.nameFS:SetText(entry.itemName or "Unknown")
            itemRow:SetAlpha(entry.awarded and 0.55 or 1)
            itemRow:Show()
        end
        for i = #entries + 1, #block.itemRows do block.itemRows[i]:Hide() end

        local blockH = PLAYER_HDR_H + #entries * ITEM_H
        block:SetHeight(blockH)
        block:ClearAllPoints()
        block:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yPos)
        block:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, yPos)
        block:Show()
        yPos = yPos - blockH - 6
    end
    for i = #playerOrder + 1, #popup._blocks do popup._blocks[i]:Hide() end
    scrollChild:SetHeight(math.max(1, -yPos))
end

------------------------------------------------------------------------
-- Reassign popup
------------------------------------------------------------------------
function LeaderFrame:_CreateReassignPopup()
    local popup = MakePopup("OLLReassignPopup", 380, 200, "Reassign", 0, 0)
    popup.header.subtitle:SetPoint("LEFT", popup.header.title, "RIGHT", 10, -1)

    popup.sectionLabel = popup:CreateFontString(nil, "OVERLAY")
    popup.sectionLabel:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    popup.noLabel = popup:CreateFontString(nil, "OVERLAY")
    popup.noLabel:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    popup.noLabel:SetText("No other candidates rolled.")

    popup.candidateBtns = {}
    for i = 1, 8 do
        local btn = ns.MakeButton(popup, "outline", "", 348, 24)
        btn._text:SetJustifyH("LEFT")
        btn:SetScript("OnClick", function(b)
            if b._player then
                ns.Session:ReassignItem(popup._itemIdx, b._player)
                popup:Hide()
            end
        end)
        popup.candidateBtns[i] = btn
    end

    popup.sep = ns.MakeHairline(popup, "dividerColor"); popup.sep:SetWidth(348)
    popup.deLabel = popup:CreateFontString(nil, "OVERLAY")
    popup.deLabel:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    popup.deBtn = ns.MakeButton(popup, "outline", "", 348, 24)
    popup.deBtn._text:SetJustifyH("LEFT")
    popup.deBtn:SetScript("OnClick", function(b)
        if b._player then
            ns.Session:ReassignItem(popup._itemIdx, b._player, true)
            popup:Hide()
        end
    end)
    popup.sep2 = ns.MakeHairline(popup, "dividerColor"); popup.sep2:SetWidth(348)

    popup.manualLabel = popup:CreateFontString(nil, "OVERLAY")
    popup.manualLabel:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    popup.manualLabel:SetText(ns.Track("Or enter manually (Name-Realm)"))

    local editWrap = CreateFrame("Frame", nil, popup, "BackdropTemplate")
    editWrap:SetSize(240, 28)
    ns.SkinNineSlice(editWrap, "btn")
    popup.editWrap = editWrap
    local editBox = CreateFrame("EditBox", "OLLReassignEdit", editWrap)
    editBox:SetPoint("TOPLEFT", 8, 0); editBox:SetPoint("BOTTOMRIGHT", -8, 0)
    editBox:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    editBox:SetAutoFocus(false)
    popup.editBox = editBox

    local confirmBtn = ns.MakeButton(popup, "primary", "Confirm", 96, 28)
    confirmBtn:SetPoint("LEFT", editWrap, "RIGHT", 8, 0)
    confirmBtn:SetScript("OnClick", function()
        local newWinner = editBox:GetText():trim()
        if newWinner ~= "" then
            ns.Session:ReassignItem(popup._itemIdx, newWinner)
            popup:Hide()
        end
    end)
    editBox:SetScript("OnEnterPressed", function() confirmBtn:Click() end)
    editBox:SetScript("OnEscapePressed", function() popup:Hide() end)

    function popup:ApplyThemeExtra(th)
        local r, g, b = tonumber(th.columnHeaderHex:sub(1, 2), 16) / 255, tonumber(th.columnHeaderHex:sub(3, 4), 16) / 255, tonumber(th.columnHeaderHex:sub(5, 6), 16) / 255
        self.sectionLabel:SetTextColor(r, g, b)
        self.deLabel:SetTextColor(r, g, b)
        self.manualLabel:SetTextColor(r, g, b)
        self.noLabel:SetTextColor(C(th, "textDimColor"))
        self.sep:SetVertexColor(C(th, "dividerColor"))
        self.sep2:SetVertexColor(C(th, "dividerColor"))
        self.editWrap:SetBackdropBorderColor(C(th, "strokeColor"))
        self.editBox:SetTextColor(C(th, "textColor"))
    end
    popup:ApplyThemeExtra(ns.Theme:GetCurrent())
    self._reassignPopup = popup
    return popup
end

function LeaderFrame:ShowReassignPopup(itemIdx, item)
    local popup = self._reassignPopup or self:_CreateReassignPopup()
    popup:Hide()
    popup._itemIdx = itemIdx

    local ranked = ns.Session:GetRankedCandidates(itemIdx)
    local currentWinner = ns.Session.results[itemIdx] and ns.Session.results[itemIdx].winner
    local nextCandidates = {}
    for _, c in ipairs(ranked) do
        if c.player ~= currentWinner then tinsert(nextCandidates, c) end
    end

    local disenchanter = ns.db.profile.disenchanter or ""
    local hasDisenchanter = disenchanter ~= ""

    local candidateRows = math.min(#nextCandidates, 8)
    local popupHeight = 44 + 12 + (candidateRows > 0 and (18 + candidateRows * 28) or 26) + 14
                      + (hasDisenchanter and (18 + 28 + 14) or 0) + 18 + 28 + 20
    popup:SetHeight(popupHeight)
    popup.header:SetSubtitle(item and (item.name or "") or "")

    local yPos = -(44 + 12)
    for _, btn in ipairs(popup.candidateBtns) do btn:Hide() end
    if #nextCandidates > 0 then
        popup.noLabel:Hide()
        popup.sectionLabel:ClearAllPoints()
        popup.sectionLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
        popup.sectionLabel:SetText(ns.Track("Reassign to next-place winner"))
        popup.sectionLabel:Show()
        yPos = yPos - 18
        for i = 1, candidateRows do
            local candidate = nextCandidates[i]
            local pos = i + 1
            local ordinal = pos == 2 and "2nd" or (pos == 3 and "3rd" or (pos .. "th"))
            local btn = popup.candidateBtns[i]
            btn._player = candidate.player
            btn._text:SetText(string.format("%s   %s   %s %d   count %d",
                ordinal, StripRealm(candidate.player), string.upper(candidate.choice or "?"),
                candidate.roll or 0, candidate.count or ns.LootCount:GetCount(candidate.player)))
            btn._text:ClearAllPoints(); btn._text:SetPoint("LEFT", btn, "LEFT", 12, 0)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
            btn:Show()
            yPos = yPos - 28
        end
    else
        popup.sectionLabel:Hide()
        popup.noLabel:ClearAllPoints()
        popup.noLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
        popup.noLabel:Show()
        yPos = yPos - 26
    end

    yPos = yPos - 6
    popup.sep:ClearAllPoints(); popup.sep:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
    yPos = yPos - 8

    if hasDisenchanter then
        popup.deLabel:ClearAllPoints()
        popup.deLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
        popup.deLabel:SetText(ns.Track("Disenchant (no count)"))
        popup.deLabel:Show()
        yPos = yPos - 18
        popup.deBtn._player = disenchanter
        popup.deBtn._text:SetText(StripRealm(disenchanter))
        popup.deBtn._text:ClearAllPoints(); popup.deBtn._text:SetPoint("LEFT", popup.deBtn, "LEFT", 12, 0)
        popup.deBtn:ClearAllPoints()
        popup.deBtn:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
        popup.deBtn:Show()
        yPos = yPos - 28 - 6
        popup.sep2:ClearAllPoints(); popup.sep2:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
        popup.sep2:Show()
        yPos = yPos - 8
    else
        popup.deLabel:Hide(); popup.deBtn:Hide(); popup.deBtn._player = nil; popup.sep2:Hide()
    end

    popup.manualLabel:ClearAllPoints()
    popup.manualLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)
    yPos = yPos - 18
    popup.editBox:SetText("")
    popup.editWrap:ClearAllPoints()
    popup.editWrap:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, yPos)

    popup:Show()
end

------------------------------------------------------------------------
-- Manual Roll Popup (440x380)
------------------------------------------------------------------------
local TIMER_CHOICES = { 15, 20, 30, 45, 60, 90 }

function LeaderFrame:ShowManualRollPopup()
    if not ns.Session or not ns.Session:IsLootMasterActionAllowed() then return end
    if not ns.Session:IsActive() then
        ns.ChatPrint("Normal", "Start a session first.")
        return
    end
    if ns.Session.state ~= ns.Session.STATE_ACTIVE then
        ns.ChatPrint("Normal", "A roll is already in progress.")
        return
    end
    if not self._manualRollPopup then self:_CreateManualRollPopup() end
    self:_RefreshManualRollList()
    self._manualRollPopup:Show()
    ns.RaiseFrame(self._manualRollPopup)
end

function LeaderFrame:_CreateManualRollPopup()
    local POPUP_W, POPUP_H = 440, 380
    local popup = MakePopup("OLLManualRollPopup", POPUP_W, POPUP_H, "Manual Roll", -50, 50)

    local instr = popup:CreateFontString(nil, "OVERLAY")
    instr:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    instr:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, -54)
    instr:SetWidth(POPUP_W - INSET * 2)
    instr:SetJustifyH("LEFT")
    instr:SetText("Shift-click items from your bags, or paste a link below.")
    popup.instr = instr

    if not LeaderFrame._manualLinkHookInstalled then
        LeaderFrame._manualLinkHookInstalled = true
        hooksecurefunc("HandleModifiedItemClick", function(link)
            if not (LeaderFrame._manualRollPopup and LeaderFrame._manualRollPopup:IsShown()) then return end
            if not link then return end
            local itemLink = link:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
                          or link:match("(|Hitem:.-|h%[.-%]|h)")
            if not itemLink then return end
            local name, _, quality, _, _, _, _, _, _, iconTexture = GetItemInfo(itemLink)
            if not name then return end
            tinsert(LeaderFrame._manualRollItems, {
                name = name, link = itemLink, quality = quality or 0,
                icon = iconTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
            })
            LeaderFrame:_RefreshManualRollList()
        end)
    end

    -- Paste box: 30px outlined field with placeholder
    local editWrap = CreateFrame("Frame", nil, popup, "BackdropTemplate")
    editWrap:SetPoint("TOPLEFT", popup, "TOPLEFT", INSET, -74)
    editWrap:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -INSET, -74)
    editWrap:SetHeight(30)
    ns.SkinNineSlice(editWrap, "btn")
    popup.editWrap = editWrap

    local captureBox = CreateFrame("EditBox", "OLLManualRollCaptureBox", editWrap)
    captureBox:SetPoint("TOPLEFT", 10, 0); captureBox:SetPoint("BOTTOMRIGHT", -10, 0)
    captureBox:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    captureBox:SetAutoFocus(false)
    captureBox:SetMaxLetters(0)
    local capHint = captureBox:CreateFontString(nil, "OVERLAY")
    capHint:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    capHint:SetPoint("LEFT", captureBox, "LEFT", 0, 0)
    capHint:SetText("Paste an item link   Ctrl+V")
    popup.capHint = capHint
    captureBox:SetScript("OnEditFocusGained", function() capHint:Hide() end)
    captureBox:SetScript("OnEditFocusLost", function() if captureBox:GetText() == "" then capHint:Show() end end)

    local _suppressChange = false
    captureBox:SetScript("OnTextChanged", function(eb)
        if _suppressChange then return end
        local text = eb:GetText()
        if not text or text == "" then return end
        _suppressChange = true
        eb:SetText("")
        _suppressChange = false
        local fullLink = text:match("(|c%x%x%x%x%x%x%x%x|H.-|h%[.-%]|h|r)")
                      or text:match("(|H.-|h%[.-%]|h)")
        if not fullLink then return end
        local name, _, quality, _, _, _, _, _, _, iconTexture = GetItemInfo(fullLink)
        if not name then
            ns.ChatPrint("Normal", "OLL: Item info not cached yet – try again in a moment.")
            return
        end
        tinsert(LeaderFrame._manualRollItems, {
            name = name, link = fullLink, quality = quality or 0,
            icon = iconTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
        })
        LeaderFrame:_RefreshManualRollList()
        eb:SetFocus()
    end)
    captureBox:SetScript("OnEscapePressed", function() popup:Hide() end)
    self._manualCaptureBox = captureBox

    -- Item list
    local scroll = CreateFrame("ScrollFrame", "OLLManualRollScroll", popup)
    scroll:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -114)
    scroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 58)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * 30)))
    end)
    local listChild = CreateFrame("Frame", nil, scroll)
    listChild:SetSize(POPUP_W - 4, 1)
    scroll:SetScrollChild(listChild)
    self._manualListChild = listChild

    local emptyText = listChild:CreateFontString(nil, "OVERLAY")
    emptyText:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    emptyText:SetPoint("TOPLEFT", listChild, "TOPLEFT", INSET, -12)
    emptyText:SetText("No items added yet.")
    emptyText:Hide()
    self._manualEmptyText = emptyText

    -- Footer: Start roll · 30s (primary) + Timer ▾ + Clear all (quiet)
    local footer = ns.MakeBar(popup, 56, "barBgColorAlt", "TOP")
    footer:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 2, 2)
    footer:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 2)

    local startBtn = ns.MakeButton(footer, "primary", "Start roll", 150, 32)
    startBtn:SetPoint("LEFT", footer, "LEFT", INSET - 2, 0)
    startBtn:SetScript("OnClick", function()
        local items = LeaderFrame._manualRollItems
        if not items or #items == 0 then
            ns.ChatPrint("Normal", "No items to roll on.")
            return
        end
        local rollItems = {}
        for _, item in ipairs(items) do tinsert(rollItems, item) end
        LeaderFrame._manualRollItems = {}
        local override = LeaderFrame._manualTimerOverride
        LeaderFrame._manualTimerOverride = nil
        popup:Hide()
        ns.Session:StartManualRoll(rollItems, override)
    end)
    self._manualStartBtn = startBtn

    local timerBtn = ns.MakeButton(footer, "outline", "Timer", 90, 32)
    timerBtn:SetPoint("LEFT", startBtn, "RIGHT", 8, 0)
    timerBtn:SetSubLabel("v")
    timerBtn:SetScript("OnClick", function(b)
        local function pick(secs)
            LeaderFrame._manualTimerOverride = secs
            LeaderFrame:_RefreshManualRollList()
        end
        if MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(b, function(_, root)
                root:CreateTitle("Roll timer for this roll")
                root:CreateButton("Session default (" .. ns.Session:GetRollDuration() .. "s)", function() pick(nil) end)
                for _, secs in ipairs(TIMER_CHOICES) do
                    root:CreateButton(secs .. " seconds", function() pick(secs) end)
                end
            end)
        else
            -- No MenuUtil: cycle through the choices
            local cur = LeaderFrame._manualTimerOverride
            local nextIdx = 1
            for i, secs in ipairs(TIMER_CHOICES) do if secs == cur then nextIdx = i + 1 end end
            pick(TIMER_CHOICES[nextIdx])   -- nil after the last → session default
        end
    end)
    popup.timerBtn = timerBtn

    local clearBtn = ns.MakeButton(footer, "quiet", "Clear all", 90, 32)
    clearBtn:SetPoint("RIGHT", footer, "RIGHT", -(INSET - 2), 0)
    clearBtn:SetScript("OnClick", function()
        LeaderFrame._manualRollItems = {}
        LeaderFrame:_RefreshManualRollList()
        if LeaderFrame._manualCaptureBox then LeaderFrame._manualCaptureBox:SetFocus() end
    end)

    function popup:ApplyThemeExtra(th)
        self.instr:SetTextColor(0.545, 0.565, 0.608)   -- #8b909b
        self.capHint:SetTextColor(C(th, "textDimColor"))
        self.editWrap:SetBackdropBorderColor(C(th, "strokeDimColor"))
        captureBox:SetTextColor(C(th, "textColor"))
        for _, row in ipairs(LeaderFrame._manualItemRowPool) do row:ApplyTheme(th) end
    end
    popup:ApplyThemeExtra(ns.Theme:GetCurrent())
    self._manualRollPopup = popup
end

function LeaderFrame:_RefreshManualRollList()
    for _, row in ipairs(self._manualItemRowPool) do row._inUse = false; row:Hide() end
    local child = self._manualListChild
    if not child then return end
    local popup = self._manualRollPopup
    local items = self._manualRollItems

    -- title count + start label with duration
    if popup then
        popup.header:SetSubtitle(#items > 0 and (#items .. (#items == 1 and " item" or " items")) or "")
        local dur = self._manualTimerOverride or (ns.Session and ns.Session:GetRollDuration()) or 30
        self._manualStartBtn:SetLabel("Start roll")
        self._manualStartBtn:SetSubLabel("· " .. dur .. "s")
        popup.timerBtn:SetLabel(self._manualTimerOverride and (self._manualTimerOverride .. "s") or "Timer")
    end

    if not items or #items == 0 then
        if self._manualEmptyText then self._manualEmptyText:Show() end
        child:SetHeight(30)
        if self._manualStartBtn then self._manualStartBtn:SetEnabled(false) end
        return
    end
    if self._manualEmptyText then self._manualEmptyText:Hide() end

    local ROW_H = 30
    local yOffset = 0
    for i, item in ipairs(items) do
        local row = self:_AcquireManualRow(child)
        row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, yOffset)
        row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, yOffset)
        row:SetItem(item)
        local capturedI = i
        row.removeBtn:SetScript("OnClick", function()
            table.remove(LeaderFrame._manualRollItems, capturedI)
            LeaderFrame:_RefreshManualRollList()
            if LeaderFrame._manualCaptureBox then LeaderFrame._manualCaptureBox:SetFocus() end
        end)
        row:Show()
        yOffset = yOffset - ROW_H
    end
    child:SetHeight(math.abs(yOffset) + 4)
    if self._manualStartBtn then self._manualStartBtn:SetEnabled(true) end
end

function LeaderFrame:_AcquireManualRow(parent)
    for _, row in ipairs(self._manualItemRowPool) do
        if not row._inUse then
            row._inUse = true
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end
    local row = ns.MakeItemRow(parent, 30, { iconSize = 20 })
    row:HookScript("OnEnter", function(r)
        if r._link then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            if r._link:find("|H") then GameTooltip:SetHyperlink(r._link) else GameTooltip:SetText(r._link) end
            GameTooltip:Show()
        end
    end)
    row:HookScript("OnLeave", GameTooltip_Hide)
    -- 20px remove button (✕ drawn as two bars)
    local removeBtn = ns.MakeCloseButton(row.rightSlot, 20)
    removeBtn:SetPoint("RIGHT", row.rightSlot, "RIGHT", 0, 0)
    row.rightSlot:SetWidth(20)
    row.removeBtn = removeBtn
    row._inUse = true
    tinsert(self._manualItemRowPool, row)
    return row
end

------------------------------------------------------------------------
-- Show / Hide / Toggle
------------------------------------------------------------------------
function LeaderFrame:Show()
    local session = ns.Session
    local isSessionLootMaster = session and session:IsActive()
        and session.sessionLootMaster and session.sessionLootMaster ~= ""
        and ns.NamesMatch(ns.GetPlayerNameRealm(), session.sessionLootMaster)
    if not ns.IsLeader() and not isSessionLootMaster then
        ns.ChatPrint("Normal", "Only the group leader, raid assist, or session loot master can open the leader frame.")
        return
    end
    local f = self:GetFrame()
    f:Show()
    self:Refresh()
    -- elapsed-time pill ticks once a minute while shown
    if not self._elapsedTicker then
        self._elapsedTicker = C_Timer.NewTicker(60, function()
            if LeaderFrame._frame and LeaderFrame._frame:IsShown() and ns.Session and ns.Session:IsActive() then
                local th = ns.Theme:GetCurrent()
                LeaderFrame._frame.statusPill:SetStatus(ns.Session.debugMode and "Debug" or "Active",
                    ns.Session.activeSessionId and FormatElapsed(ns.Session.activeSessionId) or nil,
                    ns.Session.debugMode and th.timerBarMidColor or th.timerBarFullColor)
            end
        end)
    end
end

------------------------------------------------------------------------
-- PENDING ROLL START POPUP (promptForStart mode)
------------------------------------------------------------------------
local PENDING_ROW_H = 30

function LeaderFrame:OnPendingRollReady(items, bossName)
    self:Show()
    self:Refresh()
    self:ShowPendingRollStartPopup()
end

function LeaderFrame:ShowPendingRollStartPopup()
    if not ns.Session or not ns.Session._pendingPromptItems then return end
    if not self._pendingRollStartPopup then self:_CreatePendingRollStartPopup() end
    self:_RefreshPendingRollStartPopup(ns.Session._pendingPromptItems, ns.Session._pendingPromptBoss)
    self._pendingRollStartPopup:Show()
    ns.RaiseFrame(self._pendingRollStartPopup)
end

function LeaderFrame:_CreatePendingRollStartPopup()
    local popup = MakePopup("OLLPendingRollStartPopup", 380, 280, "Loot Captured", 0, 80)

    local scroll = CreateFrame("ScrollFrame", nil, popup)
    scroll:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -46)
    scroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 58)
    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(376, 1)
    scroll:SetScrollChild(scrollChild)
    popup._scrollChild = scrollChild
    popup._itemRows = {}

    local footer = ns.MakeBar(popup, 56, "barBgColorAlt", "TOP")
    footer:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 2, 2)
    footer:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 2)

    local startBtn = ns.MakeButton(footer, "primary", "Start roll", 130, 32)
    startBtn:SetPoint("LEFT", footer, "LEFT", INSET - 2, 0)
    startBtn:SetScript("OnClick", function()
        popup:Hide()
        if ns.Session then ns.Session:StartPendingRoll() end
        LeaderFrame:Refresh()
    end)
    local dismissBtn = ns.MakeButton(footer, "quiet", "Dismiss", 96, 32)
    dismissBtn:SetPoint("RIGHT", footer, "RIGHT", -(INSET - 2), 0)
    dismissBtn:SetScript("OnClick", function() popup:Hide(); LeaderFrame:Refresh() end)

    function popup:ApplyThemeExtra(th)
        for _, row in ipairs(self._itemRows) do row:ApplyTheme(th) end
    end
    popup:Hide()
    self._pendingRollStartPopup = popup
end

function LeaderFrame:_RefreshPendingRollStartPopup(items, bossName)
    local popup = self._pendingRollStartPopup
    if not popup then return end
    popup.header:SetSubtitle(bossName or "Unknown Boss")
    local scrollChild = popup._scrollChild
    local rows = popup._itemRows
    for i, item in ipairs(items or {}) do
        local row = rows[i]
        if not row then
            row = ns.MakeItemRow(scrollChild, PENDING_ROW_H, { iconSize = 20 })
            ns.AttachItemTooltip(row, function(r) return r._link end)
            rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * PENDING_ROW_H)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -(i - 1) * PENDING_ROW_H)
        row:SetItem(item, { meta = ItemMeta(item.link) })
        row:SetRight("")
        row:Show()
    end
    for i = #(items or {}) + 1, #rows do rows[i]:Hide() end
    scrollChild:SetHeight(math.max(1, #(items or {}) * PENDING_ROW_H))
end

------------------------------------------------------------------------
-- Hide / Reset
------------------------------------------------------------------------
function LeaderFrame:Hide()
    self:StopTimer()
    if self._elapsedTicker then self._elapsedTicker:Cancel(); self._elapsedTicker = nil end
    if self._frame then self._frame:Hide() end
    for _, popup in ipairs({ self._lootMasterPopup, self._manualRollPopup, self._tradeQueuePopup,
                             self._pendingRollStartPopup, self._reassignPopup }) do
        if popup then popup:Hide() end
    end
    if ns.CheckPartyFrame then ns.CheckPartyFrame:Hide() end
end

function LeaderFrame:Reset()
    self:StopTimer()
    self._selectedItem = nil
    self._lastResolvedKey = nil
    self:Hide()
    self:_RecycleItemRows()
    self:_RecyclePlayerRows()
    self:_RecycleChips()
    if self._leftScrollChild then
        for _, region in ipairs({ self._leftScrollChild:GetRegions() }) do region:Hide() end
    end
end

------------------------------------------------------------------------
-- Roll timer bar management
------------------------------------------------------------------------
function LeaderFrame:StartTimer()
    local f = self:GetFrame()
    local session = ns.Session
    if not session or not session._rollTimerStart then return end
    f.timerBar:SetProgress(session._rollTimerDuration, session._rollTimerDuration)
    f.timerBar:Show()
    -- Display updates are driven by TIMER_TICK broadcasts via OnTimerTick()
end

function LeaderFrame:StopTimer()
    if self._frame and self._frame.timerBar then
        self._frame.timerBar:Hide()
        if self._frame.hero then self._frame.hero.secondsNum:SetText("—") end
    end
end

function LeaderFrame:OnTimerTick(remaining)
    local f = self._frame
    if not f or not f:IsShown() then return end
    self:UpdateTimer(remaining)
    if remaining <= 0 then self:StopTimer() end
end

function LeaderFrame:UpdateTimer(remaining)
    local f = self._frame
    if not f then return end
    local session = ns.Session
    local duration = (session and session._rollTimerDuration) or 30
    f.timerBar:SetProgress(remaining, duration)
    f.hero.secondsNum:SetText(tostring(math.ceil(remaining)))
    local th = ns.Theme:GetCurrent()
    if remaining < 5 then f.hero.secondsNum:SetTextColor(C(th, "timerBarLowColor"))
    elseif remaining < 10 then f.hero.secondsNum:SetTextColor(C(th, "timerBarMidColor"))
    else f.hero.secondsNum:SetTextColor(C(th, "textColor")) end
end

function LeaderFrame:Toggle()
    local f = self:GetFrame()
    if f:IsShown() then self:Hide() else self:Show() end
end
