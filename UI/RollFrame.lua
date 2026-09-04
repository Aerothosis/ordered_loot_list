------------------------------------------------------------------------
-- OrderedLootList  –  UI/RollFrame.lua  (Ledger)
-- Medium roll window shown to every player during a loot roll: all items
-- at once, a segmented Need/Greed/Pass control per item, shared 2px
-- timer, boss-history menu in the header, Pass All + gear count footer.
--
-- Also home of the item-inspection helpers (ns.RF_*) that SmallRollFrame
-- and LargeRollFrame share, and of the ns.RollFrame router that picks the
-- frame size from profile.lootFrameSize.
------------------------------------------------------------------------

local ns                  = _G.OLL_NS

------------------------------------------------------------------------
-- Item-inspection helpers (unchanged behaviour)
------------------------------------------------------------------------
local _SPEC_MAIN_STAT = {
    [71] = "STR", [72] = "STR", [73] = "STR",
    [65] = "INT", [66] = "STR", [70] = "STR",
    [253] = "AGI", [254] = "AGI", [255] = "AGI",
    [259] = "AGI", [260] = "AGI", [261] = "AGI",
    [256] = "INT", [257] = "INT", [258] = "INT",
    [250] = "STR", [251] = "STR", [252] = "STR",
    [262] = "INT", [263] = "AGI", [264] = "INT",
    [62] = "INT", [63] = "INT", [64] = "INT",
    [265] = "INT", [266] = "INT", [267] = "INT",
    [268] = "AGI", [269] = "AGI", [270] = "INT",
    [102] = "INT", [103] = "AGI", [104] = "AGI", [105] = "INT",
    [577] = "AGI", [581] = "AGI", [1480] = "INT",
    [1467] = "INT", [1468] = "INT", [1473] = "INT",
}

local function _GetPlayerMainStat()
    local specID = ns.GetLootSpecialization and ns.GetLootSpecialization()
    if not specID or specID == 0 then
        local specIndex = ns.GetSpecialization and ns.GetSpecialization()
        if not specIndex or specIndex == 0 then return nil end
        specID = ns.GetSpecializationInfo and ns.GetSpecializationInfo(specIndex)
    end
    if not specID then return nil end
    return _SPEC_MAIN_STAT[specID]
end

local function _GetItemMainStat(link)
    if not link then return nil end
    local stats = C_Item.GetItemStats(link)
    if not stats then return nil end
    local found, count = nil, 0
    if (stats["ITEM_MOD_STRENGTH_SHORT"]  or 0) > 0 then found = "STR"; count = count + 1 end
    if (stats["ITEM_MOD_AGILITY_SHORT"]   or 0) > 0 then found = "AGI"; count = count + 1 end
    if (stats["ITEM_MOD_INTELLECT_SHORT"] or 0) > 0 then found = "INT"; count = count + 1 end
    if count == 1 then return found end
    return nil
end

local _BADGE_H      = 16
local _BADGE_W      = 44
local _TYPE_BADGE_W = 76
local _BADGE_COLORS = {
    STR = { 0.85, 0.15, 0.15 },
    AGI = { 0.10, 0.78, 0.18 },
    INT = { 0.15, 0.42, 0.95 },
}
local _TYPE_BADGE_COLOR_RED     = { 0.85, 0.15, 0.15 }
local _TYPE_BADGE_COLOR_NEUTRAL = { 0.28, 0.28, 0.28 }

local _ARMOR_LABELS = { [1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate" }
local _WEAPON_LABELS = {
    [0] = "1H Axe",   [1] = "2H Axe",    [2] = "Bow",       [3] = "Gun",
    [4] = "1H Mace",  [5] = "2H Mace",   [6] = "Polearm",
    [7] = "1H Sword", [8] = "2H Sword",  [9] = "Warglaive",
    [10] = "Staff",   [13] = "Fist",     [15] = "Dagger",
    [17] = "Thrown",  [18] = "Crossbow", [19] = "Wand",
}
local _SLOT_LABELS = {
    ["INVTYPE_NECK"]     = "Neck",
    ["INVTYPE_FINGER"]   = "Ring",
    ["INVTYPE_TRINKET"]  = "Trinket",
    ["INVTYPE_CLOAK"]    = "Cloak",
    ["INVTYPE_HOLDABLE"] = "Off-hand",
    ["INVTYPE_SHIELD"]   = "Shield",
}
local _CLASS_ARMOR_TYPE = {
    [1] = 4, [2] = 4, [3] = 3, [4] = 2, [5] = 1, [6] = 4,
    [7] = 3, [8] = 1, [9] = 1, [10] = 2, [11] = 2, [12] = 2, [13] = 3,
}
local _CLASS_WEAPON_PROF = {
    [1]  = {[0]=true,[1]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true,[13]=true,[15]=true},
    [2]  = {[0]=true,[1]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true},
    [3]  = {[0]=true,[1]=true,[2]=true,[3]=true,[4]=true,[6]=true,[7]=true,[8]=true,[10]=true,[13]=true,[15]=true,[18]=true},
    [4]  = {[0]=true,[2]=true,[3]=true,[4]=true,[7]=true,[13]=true,[15]=true,[17]=true,[18]=true},
    [5]  = {[4]=true,[10]=true,[15]=true,[19]=true},              -- Priest: mace, staff, dagger, wand
    [6]  = {[0]=true,[1]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true,[13]=true,[15]=true},
    [7]  = {[0]=true,[1]=true,[4]=true,[5]=true,[10]=true,[13]=true,[15]=true},
    [8]  = {[7]=true,[10]=true,[15]=true,[19]=true},
    [9]  = {[7]=true,[10]=true,[15]=true,[19]=true},
    [10] = {[0]=true,[4]=true,[6]=true,[7]=true,[10]=true,[13]=true,[15]=true},
    [11] = {[4]=true,[5]=true,[6]=true,[10]=true,[13]=true,[15]=true},
    [12] = {[0]=true,[4]=true,[7]=true,[9]=true,[13]=true,[15]=true},
    [13] = {[0]=true,[4]=true,[7]=true,[10]=true,[13]=true,[15]=true},
}

-- Returns (label, isRed)
local function _GetItemTypeLabelAndColor(link)
    if not link then return nil, false end
    local _, _, _, _, _, _, _, _, equipLoc, _, _, itemClassID, itemSubClassID =
        C_Item.GetItemInfo(link)
    if not itemClassID then return nil, false end
    local slotLabel = _SLOT_LABELS[equipLoc]
    if slotLabel then return slotLabel, false end
    local _, _, classID = UnitClass("player")
    if itemClassID == 2 then
        local label = _WEAPON_LABELS[itemSubClassID]
        if not label then return nil, false end
        local canUse = _CLASS_WEAPON_PROF[classID] and _CLASS_WEAPON_PROF[classID][itemSubClassID]
        return label, not canUse
    elseif itemClassID == 4 then
        local label = _ARMOR_LABELS[itemSubClassID]
        if not label then return nil, false end
        return label, (_CLASS_ARMOR_TYPE[classID] ~= itemSubClassID)
    end
    return nil, false
end

-- Compatibility wrapper: the old three-texture pill is now a Ledger outline
-- pill (MakePill).  Kept so any external caller keeps working.
local function _CreateBadge(parent, text, color, width)
    if not text or not color then return nil end
    local pill = ns.MakePill(parent, text, color, { filled = true, h = _BADGE_H })
    if width then pill:SetWidth(width) end
    return pill
end

ns.RF_GetPlayerMainStat        = _GetPlayerMainStat
ns.RF_GetItemMainStat          = _GetItemMainStat
ns.RF_GetItemTypeLabelAndColor = _GetItemTypeLabelAndColor
ns.RF_CreateBadge              = _CreateBadge
ns.RF_BADGE_COLORS             = _BADGE_COLORS
ns.RF_TYPE_BADGE_COLOR_RED     = _TYPE_BADGE_COLOR_RED
ns.RF_TYPE_BADGE_COLOR_NEUTRAL = _TYPE_BADGE_COLOR_NEUTRAL
ns.RF_BADGE_W                  = _BADGE_W
ns.RF_TYPE_BADGE_W             = _TYPE_BADGE_W

------------------------------------------------------------------------
-- Shared: apply stat / type pills to a row that has .statPill/.typePill
-- (used by Medium and Large).  Returns true if any pill is shown.
------------------------------------------------------------------------
function ns.RF_ApplyPills(row, link, anchorTo, yOff)
    local theme = ns.Theme:GetCurrent()
    local shown = false
    local stat = (ns.db.profile.showStatBadge ~= false) and _GetItemMainStat(link) or nil
    row.statPill:ClearAllPoints()
    row.typePill:ClearAllPoints()
    if stat then
        row.statPill:SetText(stat)
        row.statPill:SetColor(_BADGE_COLORS[stat], true)
        row.statPill:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff or -4)
        row.statPill:Show()
        shown = true
    else
        row.statPill:Hide()
    end
    local typeLabel, typeIsRed = _GetItemTypeLabelAndColor(link)
    if typeLabel then
        row.typePill:SetText(typeLabel)
        if typeIsRed then row.typePill:SetColor(theme.timerBarLowColor, true)
        else row.typePill:SetColor(nil, false) end
        if stat then row.typePill:SetPoint("LEFT", row.statPill, "RIGHT", 6, 0)
        else row.typePill:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff or -4) end
        row.typePill:Show()
        shown = true
    else
        row.typePill:Hide()
    end
    return shown
end

-- Shared: run the auto-pass rules over items; calls onPass(idx, reason)
local _BIND_ON_EQUIP = (Enum and Enum.ItemBind and Enum.ItemBind.OnEquip) or 2

function ns.RF_AutoPassScan(items, alreadyResponded, onPass)
    -- Items the player already answered (frame rebuilt after a re-roll or
    -- late item data) are never auto-passed over that answer.
    local pre = ns._rfPreAnswered
    if pre and next(pre) then
        local merged = {}
        for idx in pairs(alreadyResponded) do merged[idx] = true end
        for idx in pairs(pre) do merged[idx] = true end
        alreadyResponded = merged
    end
    if ns.db.profile.autoPassBOE == true then
        for idx, item in ipairs(items) do
            if not alreadyResponded[idx] and item.link then
                local bindType = select(14, C_Item.GetItemInfo(item.link))
                if bindType == _BIND_ON_EQUIP then onPass(idx, "Bind on Equip") end
            end
        end
    end
    if ns.db.profile.autoPassOffSpec == true then
        local playerStat = _GetPlayerMainStat()
        if playerStat then
            for idx, item in ipairs(items) do
                if not alreadyResponded[idx] then
                    local itemStat = _GetItemMainStat(item.link)
                    if itemStat and itemStat ~= playerStat then onPass(idx, "Not your stat") end
                end
            end
        end
    end
    if ns.db.profile.autoPassUnequippable then
        for idx, item in ipairs(items) do
            if not alreadyResponded[idx] then
                local _, typeIsRed = _GetItemTypeLabelAndColor(item.link)
                if typeIsRed then onPass(idx, "Can't equip") end
            end
        end
    end
end

-- Hold 'W' Mode: pass every item we have not answered yet without showing
-- a frame.  Returns the number of items passed.
function ns.RF_HoldWAutoPass(items)
    local s = ns.Session
    if not s or not items then return 0 end
    local me = ns.GetPlayerNameRealm()
    local n = 0
    for idx = 1, #items do
        local answered = s.results and s.results[idx]
            or (s.responses and s.responses[idx] and s.responses[idx][me])
        if not answered then
            s:SubmitResponse(idx, "Pass")
            n = n + 1
        end
    end
    if n > 0 then
        ns.ChatPrint("Normal", "Hold 'W' Mode: passed on " .. n
            .. (n == 1 and " item" or " items") .. ". /oll loot opens the roll frame.")
    end
    return n
end

-- Shared: boss-history menu (replaces UIDropDownMenuTemplate)
function ns.RF_OpenHistoryMenu(owner, onCurrent, onBoss)
    if not ns.Session then return end
    local keys = ns.Session:GetBossHistoryKeys()
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateButton("Current roll", onCurrent)
            if #keys == 0 then
                root:CreateTitle("No history yet")
            else
                root:CreateDivider()
                for _, key in ipairs(keys) do
                    root:CreateButton(key, function() onBoss(key) end)
                end
            end
        end)
    else
        -- Fallback without MenuUtil: cycle current → each boss → current
        owner._cycle = ((owner._cycle or 0) + 1) % (#keys + 1)
        if owner._cycle == 0 then onCurrent() else onBoss(keys[owner._cycle]) end
    end
end

------------------------------------------------------------------------
-- Medium roll frame
------------------------------------------------------------------------
local RollFrame           = {}
ns.MediumRollFrame        = RollFrame

local FRAME_WIDTH         = 440
local ITEM_ROW_HEIGHT     = 58
local HEADER_HEIGHT       = 38
local TIMER_HEIGHT        = 2
local FOOTER_HEIGHT       = 40
local MAX_VISIBLE_ROWS    = 5
local INSET               = 16

RollFrame._frame          = nil
RollFrame._timerBar       = nil
RollFrame._timerDuration  = 30
RollFrame._respondedItems = {}
RollFrame._itemRows       = {}   -- [itemIdx] = row (from the pool)
RollFrame._rowPool        = {}
RollFrame._viewingHistory = false
RollFrame._rollOptions    = nil
RollFrame._hiddenForCombat = false
RollFrame._historyLocked  = false

local function C(theme, key) return ns.Ledger.UnpackColor(theme[key]) end

function RollFrame:GetFrame()
    if self._frame then return self._frame end

    local f = ns.MakeLedgerFrame("OLLRollFrame", FRAME_WIDTH, 300, "RollFrame", { strata = "HIGH", y = 100 })

    -- Header: LOOT ROLL · boss · [HISTORY ▾] · 19 · X
    local header = ns.MakeHeaderBar(f, "Loot Roll", {
        { label = "History", tooltip = "Show a previous boss's rolls",
          onClick = function(btn) RollFrame:_OpenHistoryMenu() end },
    }, { height = HEADER_HEIGHT, onClose = function() RollFrame:Hide() end })
    f.header = header
    f.historyBtn = header.tools[1]
    f.historyBtn:SetScript("OnClick", function() RollFrame:_OpenHistoryMenu() end)

    local countdown = header:CreateFontString(nil, "OVERLAY")
    countdown:SetFontObject(ns.Ledger.Fonts.OLLFontNumberMid)
    countdown:SetPoint("RIGHT", header.toolsAnchor, "LEFT", -12, 0)
    countdown:SetText("")
    f.countdown = countdown

    -- Timer bar
    local timerBar = ns.MakeTimerBar(f)
    timerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_HEIGHT + 2))
    timerBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(HEADER_HEIGHT + 2))
    f.timerBar = timerBar
    self._timerBar = timerBar

    -- Footer: Pass all · Your gear count N
    local footer = ns.MakeBar(f, FOOTER_HEIGHT, "barBgColor", "TOP")
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    f.footer = footer

    local passAllBtn = ns.MakeButton(footer, "outline", "Pass all", 96, 28)
    passAllBtn:SetPoint("LEFT", footer, "LEFT", INSET - 2, 0)
    passAllBtn:SetScript("OnClick", function()
        RollFrame:AutoPassAll()
        if ns.db.profile.closeOnPassAll ~= false then RollFrame:Hide() end
    end)
    passAllBtn:HookScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:SetText("Pass All Loot", 1, 1, 1)
        GameTooltip:AddLine("Passes on all items you have not already\nmade a choice for. Closing the window afterwards\nis a General setting.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    passAllBtn:HookScript("OnLeave", GameTooltip_Hide)
    f.passAllBtn = passAllBtn

    local countNum = footer:CreateFontString(nil, "OVERLAY")
    countNum:SetFontObject(ns.Ledger.Fonts.OLLFontBody)
    countNum:SetPoint("RIGHT", footer, "RIGHT", -(INSET - 2), 0)
    f.countNum = countNum
    local countLbl = footer:CreateFontString(nil, "OVERLAY")
    countLbl:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    countLbl:SetPoint("RIGHT", countNum, "LEFT", -6, 0)
    countLbl:SetText("Your gear count")
    f.countLbl = countLbl
    f.countText = countNum  -- legacy name

    -- Item list scroll (between timer and footer)
    local scrollFrame = CreateFrame("ScrollFrame", "OLLRollScrollFrame", f)
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -(HEADER_HEIGHT + TIMER_HEIGHT + 2))
    scrollFrame:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 0)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
        local cur, maxV = sf:GetVerticalScroll(), sf:GetVerticalScrollRange()
        sf:SetVerticalScroll(math.max(0, math.min(maxV, cur - delta * ITEM_ROW_HEIGHT)))
    end)
    f.scrollFrame = scrollFrame
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 4, 1)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild

    -- Combat hide/show
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:HookScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if f:IsShown() then RollFrame._hiddenForCombat = true; f:Hide() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if RollFrame._hiddenForCombat then RollFrame._hiddenForCombat = false; f._skipFadeOnce = true; f:Show() end
        end
    end)

    f:Hide()
    self._frame = f
    self:ApplyTheme()
    return f
end

function RollFrame:ApplyTheme(theme)
    local f = self._frame
    if not f then return end
    theme = theme or ns.Theme:GetCurrent()
    f.countdown:SetTextColor(C(theme, "textColor"))
    f.countNum:SetTextColor(C(theme, "countTextColor"))
    f.countLbl:SetTextColor(C(theme, "textDimColor"))
    for _, row in ipairs(self._rowPool) do
        row:ApplyTheme(theme)
        row.reason:SetTextColor(C(theme, "textMutedColor"))
    end
end

------------------------------------------------------------------------
-- Row pool
------------------------------------------------------------------------
function RollFrame:_AcquireRow(parent)
    for _, row in ipairs(self._rowPool) do
        if not row._inUse then
            row._inUse = true
            row:SetParent(parent)
            row:ClearAllPoints()
            return row
        end
    end
    local row = ns.MakeItemRow(parent, ITEM_ROW_HEIGHT, { iconSize = 36 })
    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", row, "LEFT", 14, 0)
    row.statPill = ns.MakePill(row, "", nil, { filled = true })
    row.typePill = ns.MakePill(row, "", nil)
    row.statPill:Hide(); row.typePill:Hide()

    -- segmented control on the right
    row.seg = ns.MakeSegmented(row, ns.DEFAULT_ROLL_OPTIONS, nil, { h = 30, segW = { 56, 56 }, passW = 52, defaultW = 56 })
    row.seg:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)

    -- reason text (auto-pass) / status text
    row.reason = row:CreateFontString(nil, "OVERLAY")
    row.reason:SetFontObject(ns.Ledger.Fonts.OLLFontLabel)
    row.reason:SetPoint("RIGHT", row, "RIGHT", -INSET, 0)
    row.reason:Hide()
    row.statusText = row.reason   -- legacy name used by callers

    -- winner sub-line (green) + big check
    row.resultText = row:CreateFontString(nil, "OVERLAY")
    row.resultText:SetFontObject(ns.Ledger.Fonts.OLLFontBodySmall)
    row.resultText:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
    row.resultText:Hide()
    row.bigCheck = row:CreateTexture(nil, "OVERLAY")
    row.bigCheck:SetSize(22, 22)
    row.bigCheck:SetPoint("RIGHT", row, "RIGHT", -INSET - 4, 0)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("common-icon-checkmark") then
        row.bigCheck:SetAtlas("common-icon-checkmark")
    else
        row.bigCheck:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    end
    row.bigCheck:Hide()

    -- tooltip (item + winner's main)
    row:HookScript("OnEnter", function(r)
        if r._link then
            GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
            if r._link:find("|H") then GameTooltip:SetHyperlink(r._link) else GameTooltip:SetText(r._link) end
            if r._winnerName then
                local mainIdentity = ns.PlayerLinks:ResolveIdentity(r._winnerName)
                if mainIdentity and mainIdentity ~= r._winnerName then
                    GameTooltip:AddLine("Main: " .. ns.StripRealm(mainIdentity), 1, 1, 1)
                end
            end
            GameTooltip:Show()
        end
    end)
    row:HookScript("OnLeave", GameTooltip_Hide)
    row._inUse = true
    tinsert(self._rowPool, row)
    return row
end

function RollFrame:_RecycleRows()
    for _, row in ipairs(self._rowPool) do
        row._inUse = false
        row._winnerName = nil
        row:Hide()
    end
    self._itemRows = {}
end

-- Put a row into one of its states: "open" | "chosen" | "passed" | "result"
function RollFrame:_SetRowState(row, state, text, rgb)
    local theme = ns.Theme:GetCurrent()
    row.seg:Hide(); row.reason:Hide(); row.resultText:Hide(); row.bigCheck:Hide()
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -2)
    row.name:SetPoint("RIGHT", row.rightSlot, "LEFT", -8, 0)
    row:SetDimmed(1)
    if state == "open" then
        row.seg:SetEnabled(true)
        row.seg:SetSelected(nil)
        row.seg:Show()
        row.rightSlot:SetWidth(row.seg:GetWidth())
    elseif state == "chosen" then
        row.seg:SetEnabled(false)
        row.seg:SetSelected(text)
        row.seg:Show()
        row.rightSlot:SetWidth(row.seg:GetWidth())
    elseif state == "passed" then
        row.reason:SetText(ns.Track("Passed · " .. (text or "")))
        row.reason:SetTextColor(C(theme, "textMutedColor"))
        row.reason:Show()
        row.rightSlot:SetWidth(row.reason:GetStringWidth())
        row:SetDimmed(0.6)
    elseif state == "result" then
        row.statPill:Hide(); row.typePill:Hide()
        row.resultText:SetText(text or "")
        row.resultText:SetTextColor(C(theme, rgb and "timerBarFullColor" or "textMutedColor"))
        row.resultText:Show()
        if rgb then
            row.bigCheck:SetVertexColor(C(theme, "timerBarFullColor"))
            row.bigCheck:Show()
        end
        row.rightSlot:SetWidth(26)
    end
end

------------------------------------------------------------------------
-- Show all items at once for rolling
------------------------------------------------------------------------
function RollFrame:ShowAllItems(items, rollOptions)
    -- A short list after a long one must not start scrolled past its end.
    if self._frame and self._frame.scrollFrame then self._frame.scrollFrame:SetVerticalScroll(0) end
    local f = self:GetFrame()
    local theme = ns.Theme:GetCurrent()

    self._rollOptions = rollOptions or ns.DEFAULT_ROLL_OPTIONS
    self._respondedItems = {}
    self._previewMode = false
    self._viewingHistory = false
    self:LockBossDropdown()
    self:_RecycleRows()

    f.header:SetSubtitle(ns.Session and ns.Session.currentBoss or "Unknown")
    f.countNum:SetText(tostring(ns.LootCount:GetCount(ns.GetPlayerNameRealm())))

    -- Timer
    local duration = (ns.Session and ns.Session.GetRollDuration and ns.Session:GetRollDuration())
        or ns.db.profile.rollTimer or 30
    self._timerDuration = duration
    f.timerBar:SetProgress(duration, duration)
    f.timerBar:Show()
    f.countdown:SetText(tostring(math.ceil(duration)))
    f.countdown:SetTextColor(C(theme, "textColor"))

    -- Rows
    local sc = f.scrollChild
    local yOffset = 0
    for idx, item in ipairs(items) do
        local row = self:_AcquireRow(sc)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)
        row:SetItem(item)
        ns.RF_ApplyPills(row, item.link, row.name, -4)
        local capturedIdx = idx
        row.seg:SetOptions(self._rollOptions)
        row.seg:SetOnPick(function(choice) RollFrame:OnRollChoice(capturedIdx, choice) end)
        self:_SetRowState(row, "open")
        row:Show()
        self._itemRows[idx] = row
        yOffset = yOffset - ITEM_ROW_HEIGHT
    end
    sc:SetHeight(math.abs(yOffset) + 2)

    -- Auto-pass rules (off-spec / unequippable), with a visible state
    ns.RF_AutoPassScan(items, self._respondedItems, function(idx, reason)
        self:OnRollChoice(idx, "Pass")
        local row = self._itemRows[idx]
        if row then self:_SetRowState(row, "passed", reason) end
    end)

    -- Size: header + timer + up to 5 rows + footer
    local numRows = math.min(#items, MAX_VISIBLE_ROWS)
    local totalHeight = HEADER_HEIGHT + TIMER_HEIGHT + numRows * ITEM_ROW_HEIGHT + FOOTER_HEIGHT + 4
    f:SetSize(FRAME_WIDTH, totalHeight)

    ns.RaiseFrame(f)
    f:Show()
end

------------------------------------------------------------------------
-- Player roll choice for a specific item
------------------------------------------------------------------------
function RollFrame:OnRollChoice(itemIdx, choice)
    if self._respondedItems[itemIdx] then return end
    self._respondedItems[itemIdx] = true

    local row = (not self._viewingHistory) and self._itemRows[itemIdx] or nil
    if row then self:_SetRowState(row, "chosen", choice) end

    if ns.Session and not self._previewMode then ns.Session:SubmitResponse(itemIdx, choice) end

    if ns.Session and ns.Session.currentItems then
        local allDone = true
        for idx = 1, #ns.Session.currentItems do
            if not self._respondedItems[idx] then allDone = false break end
        end
        if allDone and self._timerBar then
            self._timerBar:Hide()
            if self._frame then self._frame.countdown:SetText("") end
        end
    end
end

function RollFrame:SetExternalSelection(itemIdx, choice)
    self._respondedItems[itemIdx] = nil
    self:OnRollChoice(itemIdx, choice)
end

-- Lock a row on a choice that already stands with the authority (after a
-- single-item re-roll rebuilt the list); nothing is submitted.
function RollFrame:MarkResponded(itemIdx, choice)
    self._respondedItems[itemIdx] = true
    local row = self._itemRows[itemIdx]
    if row then self:_SetRowState(row, "chosen", choice) end
end

function RollFrame:ResetItemChoice(itemIdx)
    self._respondedItems[itemIdx] = nil
    if self._viewingHistory then return end
    local row = self._itemRows[itemIdx]
    if row then self:_SetRowState(row, "open") end
end

function RollFrame:AutoPassAll()
    if not ns.Session then return end
    for idx = 1, #(ns.Session.currentItems or {}) do
        if not self._respondedItems[idx] then self:OnRollChoice(idx, "Pass") end
    end
end

------------------------------------------------------------------------
-- Timer
------------------------------------------------------------------------
function RollFrame:OnTimerTick(remaining)
    if not self._frame or not self._frame:IsShown() then return end
    if self._viewingHistory then
        -- Browsing history does not excuse the player from the timer.
        if remaining <= 0 then self:AutoPassAll() end
        return
    end
    self:UpdateTimer(remaining)
end

function RollFrame:UpdateTimer(remaining)
    local f = self._frame
    if remaining <= 0 then
        remaining = 0
        self:AutoPassAll()
        -- AutoPassAll hides the bar once everything is answered.
        if not f.timerBar:IsShown() then return end
    end
    f.timerBar:SetProgress(remaining, self._timerDuration)
    f.countdown:SetText(tostring(math.ceil(remaining)))
    local theme = ns.Theme:GetCurrent()
    if remaining < 5 then f.countdown:SetTextColor(C(theme, "timerBarLowColor"))
    elseif remaining < 10 then f.countdown:SetTextColor(C(theme, "timerBarMidColor"))
    else f.countdown:SetTextColor(C(theme, "textColor")) end
end

------------------------------------------------------------------------
-- Result on a specific row
------------------------------------------------------------------------
function RollFrame:ShowResult(itemIdx, result)
    if self._viewingHistory then return end
    local row = self._itemRows[itemIdx]
    if not row then return end
    if result and result.winner then
        row._winnerName = result.winner
        self:_SetRowState(row, "result",
            ns.StripRealm(result.winner) .. " won · " .. (result.choice or "?") .. " " .. (result.roll or 0), true)
    else
        row._winnerName = nil
        self:_SetRowState(row, "result", "No winner", false)
    end
end

------------------------------------------------------------------------
-- Boss history (header menu)
------------------------------------------------------------------------
function RollFrame:_OpenHistoryMenu()
    if self._historyLocked then return end
    local f = self:GetFrame()
    ns.RF_OpenHistoryMenu(f.historyBtn, function()
        RollFrame._viewingHistory = false
        -- Rebuild the current roll (results and standing choices included)
        -- whatever the session state, so "Current roll" always leaves history.
        local items = ns.Session and ns.Session.currentItems
        if items and #items > 0 then ns.Session:_RefreshRollFrames() end
    end, function(key) RollFrame:ShowBossHistory(key) end)
end

-- Legacy API kept for the router/callers; the menu handles population now.
function RollFrame:PopulateBossDropdown() end

function RollFrame:ShowBossHistory(bossKey)
    if self._frame and self._frame.scrollFrame then self._frame.scrollFrame:SetVerticalScroll(0) end
    local data = ns.Session and ns.Session:GetBossHistory(bossKey)
    if not data then return end
    self._viewingHistory = true
    local f = self:GetFrame()
    f.header:SetSubtitle(bossKey)
    f.timerBar:Hide()
    f.countdown:SetText("")
    self:_RecycleRows()

    local sc = f.scrollChild
    local yOffset = 0
    for idx, item in ipairs(data.items or {}) do
        local result = data.results and data.results[idx]
        local row = self:_AcquireRow(sc)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOffset)
        row:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, yOffset)
        row:SetItem(item)
        row.statPill:Hide(); row.typePill:Hide()
        if result and result.winner then
            row._winnerName = result.winner
            self:_SetRowState(row, "result",
                ns.StripRealm(result.winner) .. " won · " .. (result.choice or "?") .. " " .. (result.roll or 0), true)
        else
            self:_SetRowState(row, "result", "No winner", false)
        end
        row:Show()
        self._itemRows[idx] = row
        yOffset = yOffset - ITEM_ROW_HEIGHT
    end
    sc:SetHeight(math.abs(yOffset) + 2)
    local numRows = math.min(#(data.items or {}), MAX_VISIBLE_ROWS)
    f:SetHeight(math.max(HEADER_HEIGHT + TIMER_HEIGHT + numRows * ITEM_ROW_HEIGHT + FOOTER_HEIGHT + 4, 160))
    f:Show()
end

function RollFrame:LockBossDropdown()
    self._historyLocked = true
    if self._frame then self._frame.historyBtn:SetEnabled(false) end
end

function RollFrame:UnlockBossDropdown()
    self._historyLocked = false
    if self._frame then self._frame.historyBtn:SetEnabled(true) end
end

------------------------------------------------------------------------
-- Visibility / reset
------------------------------------------------------------------------
function RollFrame:Toggle()
    local f = self:GetFrame()
    if f:IsShown() then f:Hide() else f:Show() end
end

function RollFrame:IsVisible()
    return self._frame and self._frame:IsShown()
end

function RollFrame:Hide()
    self._hiddenForCombat = false
    if self._frame then self._frame:Hide() end
end

function RollFrame:Show()
    self:GetFrame():Show()
end

function RollFrame:Reset()
    self._hiddenForCombat = false
    self:Hide()
    self:UnlockBossDropdown()
    self._respondedItems = {}
    self._previewMode = false
    self._viewingHistory = false
    self._rollOptions = nil
    self._timerDuration = 0
    self:_RecycleRows()
    if self._frame then
        self._frame.timerBar:SetProgress(0, 1)
        self._frame.countdown:SetText("")
    end
end

-- Legacy compatibility: ShowForItem redirects to ShowAllItems
function RollFrame:ShowForItem(_, _, rollOptions)
    if ns.Session and ns.Session.currentItems and #ns.Session.currentItems > 0 then
        self:ShowAllItems(ns.Session.currentItems, rollOptions)
    end
end

------------------------------------------------------------------------
-- RollFrame router — sits at ns.RollFrame and delegates to the frame
-- selected by ns.db.profile.lootFrameSize ("small"/"medium"/"large").
------------------------------------------------------------------------
local _Router = {}
ns.RollFrame  = _Router

local function _ActiveFrame()
    local size = ns.db and ns.db.profile.lootFrameSize or "medium"
    if size == "small" then return ns.SmallRollFrame
    elseif size == "large" then return ns.LargeRollFrame
    else return ns.MediumRollFrame end
end

function _Router:ShowAllItems(items, rollOptions, force)
    if ns.SmallRollFrame  then ns.SmallRollFrame:Hide()  end
    if ns.MediumRollFrame then ns.MediumRollFrame:Hide() end
    if ns.LargeRollFrame  then ns.LargeRollFrame:Hide()  end
    -- Hold 'W' Mode is re-read on every roll so it can be switched off
    -- mid-session.  The frame stays hidden and everything is passed.
    if not force and ns.db and ns.db.profile.holdWMode == true then
        self._active = nil
        ns.RF_HoldWAutoPass(items)
        return
    end
    local active = _ActiveFrame()
    self._active = active
    self._lastShownSize = ns.db and ns.db.profile.lootFrameSize or "medium"
    if active then active:ShowAllItems(items, rollOptions) end
end

function _Router:MarkResponded(itemIdx, choice)
    local active = self._active or _ActiveFrame()
    if active and active.MarkResponded then active:MarkResponded(itemIdx, choice) end
end

function _Router:SetExternalSelection(itemIdx, choice)
    local active = self._active or _ActiveFrame()
    if active then active:SetExternalSelection(itemIdx, choice) end
end

function _Router:OnTimerTick(remaining)
    local active = self._active or _ActiveFrame()
    if active then active:OnTimerTick(remaining) end
end

function _Router:ResetItemChoice(itemIdx)
    local active = self._active or _ActiveFrame()
    if active and active.ResetItemChoice then active:ResetItemChoice(itemIdx) end
end

function _Router:Hide()
    if ns.SmallRollFrame  then ns.SmallRollFrame:Hide()  end
    if ns.MediumRollFrame then ns.MediumRollFrame:Hide() end
    if ns.LargeRollFrame  then ns.LargeRollFrame:Hide()  end
    self._active = nil
end

function _Router:IsVisible()
    return (ns.SmallRollFrame  and ns.SmallRollFrame:IsVisible())
        or (ns.MediumRollFrame and ns.MediumRollFrame:IsVisible())
        or (ns.LargeRollFrame  and ns.LargeRollFrame:IsVisible())
end

function _Router:Reset()
    if ns.SmallRollFrame  and ns.SmallRollFrame.Reset  then ns.SmallRollFrame:Reset()  end
    if ns.MediumRollFrame and ns.MediumRollFrame.Reset then ns.MediumRollFrame:Reset() end
    if ns.LargeRollFrame  and ns.LargeRollFrame.Reset  then ns.LargeRollFrame:Reset()  end
    self._active = nil
end

function _Router:ApplyTheme(theme)
    if ns.SmallRollFrame  and ns.SmallRollFrame.ApplyTheme  then ns.SmallRollFrame:ApplyTheme(theme)  end
    if ns.MediumRollFrame and ns.MediumRollFrame.ApplyTheme then ns.MediumRollFrame:ApplyTheme(theme) end
    if ns.LargeRollFrame  and ns.LargeRollFrame.ApplyTheme  then ns.LargeRollFrame:ApplyTheme(theme)  end
end

function _Router:UnlockBossDropdown()
    if ns.SmallRollFrame  and ns.SmallRollFrame.UnlockBossDropdown  then ns.SmallRollFrame:UnlockBossDropdown()  end
    if ns.MediumRollFrame and ns.MediumRollFrame.UnlockBossDropdown then ns.MediumRollFrame:UnlockBossDropdown() end
    if ns.LargeRollFrame  and ns.LargeRollFrame.UnlockBossDropdown  then ns.LargeRollFrame:UnlockBossDropdown()  end
end

function _Router:ShowResult(itemIdx, result)
    local active = self._active or _ActiveFrame()
    if active and active.ShowResult then active:ShowResult(itemIdx, result) end
end

function _Router:Toggle()
    local desired = _ActiveFrame()
    local active  = self._active
    if desired and active and desired ~= active then
        active:Hide()
        if ns.Session and ns.Session.currentItems and #ns.Session.currentItems > 0 then
            self:ShowAllItems(ns.Session.currentItems, ns.Session.rollOptions, true)
        end
        return
    end
    if not active then active = desired end
    if not active then return end
    if active:IsVisible() then
        active:Hide()
    else
        local sess = ns.Session
        if sess and sess.currentItems and #sess.currentItems > 0 then
            if sess._suspendedRoll then
                -- SuspendRoll hid the frame; it comes back on ROLL_RESUMED.
                ns.ChatPrint("Normal", "The loot roll is paused for a cinematic; the window returns when it resumes.")
                return
            end
            if self._active == nil and sess.state == sess.STATE_ROLLING then
                -- Hold 'W' Mode kept the frame hidden for this roll; build it now.
                self:ShowAllItems(sess.currentItems, sess.rollOptions, true)
            else
                active:Show()
            end
        end
    end
end
