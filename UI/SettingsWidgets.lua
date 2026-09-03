------------------------------------------------------------------------
-- OrderedLootList  –  UI/SettingsWidgets.lua  (Ledger)
-- Primitives the Settings window is assembled from, next to the six in
-- UI/Widgets.lua: sidebar nav, setting row, toggle, stepper, plus the
-- small helpers the sections share (generic segmented control, checkbox,
-- edit box, slider, group header, consequence box).
--
-- Every widget exposes :ApplyTheme(theme) and registers with the Ledger
-- skin table, so a theme switch re-tints it without the owning frame
-- tracking each one.  Widgets that show a saved value expose :Refresh()
-- which re-reads it through the `get` closure they were built with.
------------------------------------------------------------------------

local ns     = _G.OLL_NS
local Ledger = ns.Ledger

local WHITE8x8 = "Interface\\Buttons\\WHITE8x8"

local unpackColor = Ledger.UnpackColor
local function register(w) Ledger._skinned[w] = true; return w end
local function hex(h)
    return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
end

-- Fixed greys from the mocks (not theme-driven in the spec)
local GREY_8B = { hex("8b909b") }   -- inactive nav / secondary labels
local GREY_56 = { hex("565c67") }   -- hints, version
local GREY_6F = { hex("6f7683") }   -- knob off, PROFILE label
local DARK_26 = { hex("262a33") }   -- toggle track off, checkbox off
local DARK_1C = { hex("1c2027") }   -- badge fill, slider track
local KNOB_ON = { hex("f2e2b0") }
Ledger.SettingsGreys = { g8b = GREY_8B, g56 = GREY_56, g6f = GREY_6F, d26 = DARK_26, d1c = DARK_1C }

------------------------------------------------------------------------
-- Class colour for a Name-Realm, from the group roster or the player.
-- Returns {r,g,b} or nil when the class is unknown.
------------------------------------------------------------------------
function ns.ClassColorFor(nameRealm)
    if not nameRealm then return nil end
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
    -- guild roster (offline members included) as a last resort
    if IsInGuild() and GetNumGuildMembers then
        local short = ns.StripRealm(nameRealm)
        for i = 1, GetNumGuildMembers() do
            local gname, _, _, _, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
            if gname and (gname == nameRealm or ns.StripRealm(gname) == short) then
                local c = classFile and RAID_CLASS_COLORS[classFile]
                if c then return { c.r, c.g, c.b } end
            end
        end
    end
    return nil
end

------------------------------------------------------------------------
-- ns.MakeGroupHeader(parent, text)
-- OLLFontLabel/accentColor caption with a 1px hairline under it.
-- Height 22 (label 16 + 6 bottom margin).
------------------------------------------------------------------------
function ns.MakeGroupHeader(parent, text)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(24)
    h.text = h:CreateFontString(nil, "OVERLAY")
    h.text:SetFontObject(Ledger.Fonts.OLLFontLabel)
    h.text:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", 0, 7)
    h.text:SetText(ns.Track(text))
    h.rule = ns.MakeHairline(h, "histSepColor")
    h.rule:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", 0, 0)
    h.rule:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", 0, 0)
    function h:SetText(t) self.text:SetText(ns.Track(t)) end
    function h:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self.text:SetTextColor(unpackColor(th.accentColor))
        self.rule:SetVertexColor(unpackColor(th.histSepColor))
    end
    h:ApplyTheme()
    return register(h)
end

------------------------------------------------------------------------
-- ns.MakeConsequenceBox(parent)
-- panelBgColor box, 4px radius, histSepColor stroke, 8/10 padding,
-- OLLFontBodySmall/#8b909b text.  :SetText(t) resizes the height.
------------------------------------------------------------------------
function ns.MakeConsequenceBox(parent)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SkinNineSlice(b, "btn")
    b:SetHeight(32)
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetFontObject(Ledger.Fonts.OLLFontBodySmall)
    b.text:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -8)
    b.text:SetPoint("RIGHT", b, "RIGHT", -10, 0)
    b.text:SetJustifyH("LEFT")
    b.text:SetSpacing(4)
    function b:SetText(t)
        self.text:SetText(t or "")
        self:SetHeight(math.max(32, self.text:GetStringHeight() + 16))
    end
    function b:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropColor(unpackColor(th.panelBgColor))
        self:SetBackdropBorderColor(unpackColor(th.histSepColor))
        self.text:SetTextColor(GREY_8B[1], GREY_8B[2], GREY_8B[3])
    end
    b:ApplyTheme()
    return register(b)
end

------------------------------------------------------------------------
-- ns.MakeToggle(parent, get, set)
-- 38x20 pill switch.  Off: #262a33 track, 14px #6f7683 knob at left+3.
-- On: primaryBtnBot track, #f2e2b0 knob at right+3.  120ms knob slide.
-- `set(v)` may return false to veto the flip (confirm popups); the knob
-- then stays put and the caller refreshes once the popup resolves.
-- API: :Refresh(), :SetEnabled(bool), :ApplyTheme()
------------------------------------------------------------------------
local TOG_W, TOG_H, KNOB = 38, 20, 14
function ns.MakeToggle(parent, get, set)
    local t = CreateFrame("Button", nil, parent, "BackdropTemplate")
    t:SetSize(TOG_W, TOG_H)
    ns.SkinNineSlice(t, "pill")
    t._get, t._set, t._enabled = get, set, true

    local knob = t:CreateTexture(nil, "OVERLAY")
    knob:SetTexture(Ledger.TEX.dot)
    knob:SetSize(KNOB, KNOB)
    knob:SetPoint("LEFT", t, "LEFT", 3, 0)
    t._knob = knob

    local ag = knob:CreateAnimationGroup()
    local slide = ag:CreateAnimation("Translation")
    slide:SetDuration(0.12)
    slide:SetSmoothing("IN_OUT")
    t._slide = slide
    ag:SetScript("OnFinished", function() t:_Place(t._on) end)
    t._ag = ag

    function t:_Place(on)
        self._knob:ClearAllPoints()
        if on then self._knob:SetPoint("RIGHT", self, "RIGHT", -3, 0)
        else       self._knob:SetPoint("LEFT",  self, "LEFT",   3, 0) end
    end

    function t:_Paint()
        local th = ns.Theme:GetCurrent()
        if self._on then
            self:SetBackdropColor(unpackColor(th.primaryBtnBot))
            self:SetBackdropBorderColor(unpackColor(th.primaryBtnBot))
            self._knob:SetVertexColor(KNOB_ON[1], KNOB_ON[2], KNOB_ON[3])
        else
            self:SetBackdropColor(DARK_26[1], DARK_26[2], DARK_26[3])
            self:SetBackdropBorderColor(DARK_26[1], DARK_26[2], DARK_26[3])
            self._knob:SetVertexColor(GREY_6F[1], GREY_6F[2], GREY_6F[3])
        end
        self:SetAlpha(self._enabled and 1 or 0.45)
    end

    -- Re-read the value; animate only when it actually changed on screen.
    function t:Refresh(animate)
        local on = self._get() and true or false
        local changed = (self._on ~= nil) and (on ~= self._on)
        self._on = on
        self:_Paint()
        if changed and animate and not InCombatLockdown() then
            self._ag:Stop()
            self:_Place(not on)
            self._slide:SetOffset(on and (TOG_W - KNOB - 6) or -(TOG_W - KNOB - 6), 0)
            self._ag:Play()
        else
            self._ag:Stop()
            self:_Place(on)
        end
    end

    function t:SetEnabled(on)
        self._enabled = on and true or false
        if self._enabled then self:Enable() else self:Disable() end
        self:_Paint()
    end
    function t:ApplyTheme() self:_Paint() end

    t:SetScript("OnClick", function(self)
        if not self._enabled then return end
        local want = not self._on
        local ok = self._set(want)
        if ok == false then return end
        self:Refresh(true)
    end)
    t:Refresh(false)
    return register(t)
end

------------------------------------------------------------------------
-- ns.MakeCheckbox(parent, label, get, set)
-- 16px square, 3px radius; primaryBtnBot fill + primaryBtnTextColor check
-- when on, #262a33 when off.  Label in OLLFontBody to the right.
------------------------------------------------------------------------
function ns.MakeCheckbox(parent, label, get, set)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(18)
    local box = CreateFrame("Frame", nil, c, "BackdropTemplate")
    box:SetSize(16, 16)
    box:SetPoint("LEFT", c, "LEFT", 0, 0)
    ns.SkinNineSlice(box, "pill")
    c._box = box
    local check = box:CreateFontString(nil, "OVERLAY")
    check:SetFontObject(Ledger.Fonts.OLLFontLabel)
    check:SetPoint("CENTER", box, "CENTER", 0, 0)
    check:SetText("v")
    c._check = check
    local text = c:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(Ledger.Fonts.OLLFontBody)
    text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    text:SetText(label or "")
    c._text = text
    c:SetWidth(16 + 8 + text:GetStringWidth())
    c._get, c._set = get, set

    function c:Refresh()
        local th = ns.Theme:GetCurrent()
        self._on = self._get() and true or false
        if self._on then
            self._box:SetBackdropColor(unpackColor(th.primaryBtnBot))
            self._box:SetBackdropBorderColor(unpackColor(th.primaryBtnBot))
            self._check:SetTextColor(unpackColor(th.primaryBtnTextColor))
            self._check:Show()
        else
            self._box:SetBackdropColor(DARK_26[1], DARK_26[2], DARK_26[3])
            self._box:SetBackdropBorderColor(DARK_26[1], DARK_26[2], DARK_26[3])
            self._check:Hide()
        end
        self._text:SetTextColor(unpackColor(th.textColor))
    end
    function c:ApplyTheme() self:Refresh() end
    c:SetScript("OnClick", function(self) self._set(not self._on); self:Refresh() end)
    c:Refresh()
    return register(c)
end

------------------------------------------------------------------------
-- ns.MakeStepper(parent, min, max, step, get, set)
-- 88x24, btn-edge outline, "-" / "+" 24px hit areas in #8b909b, value in
-- OLLFontBody/textColor.  Click-and-hold repeats at 8/s after 400ms.
-- API: :Refresh(), :SetEnabled(bool), :SetStrokeColor(rgb|nil)
------------------------------------------------------------------------
function ns.MakeStepper(parent, minV, maxV, step, get, set)
    local s = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    s:SetSize(88, 24)
    ns.SkinNineSlice(s, "btn")
    s._min, s._max, s._step, s._get, s._set = minV, maxV, step or 1, get, set
    s._enabled = true

    s.value = s:CreateFontString(nil, "OVERLAY")
    s.value:SetFontObject(Ledger.Fonts.OLLFontBody)
    s.value:SetPoint("CENTER", s, "CENTER", 0, 0)

    local function makeBtn(glyph, side)
        local b = CreateFrame("Button", nil, s)
        b:SetSize(24, 22)
        b:SetPoint(side, s, side, side == "LEFT" and 1 or -1, 0)
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetFontObject(Ledger.Fonts.OLLFontBody)
        b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.text:SetText(glyph)
        local hl = b:CreateTexture(nil, "BACKGROUND"); hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
        b._hl = hl
        b:SetScript("OnEnter", function(x) if s._enabled then x._hl:Show() end end)
        b:SetScript("OnLeave", function(x) x._hl:Hide() end)
        return b
    end
    s.minus = makeBtn("-", "LEFT")
    s.plus  = makeBtn("+", "RIGHT")

    local function bump(dir)
        if not s._enabled then return end
        local cur = tonumber(s._get()) or 0
        local nv = math.max(s._min, math.min(s._max, cur + dir * s._step))
        if nv ~= cur then s._set(nv) end
        s:Refresh()
    end
    local function armRepeat(btn, dir)
        btn:SetScript("OnMouseDown", function()
            if not s._enabled then return end
            bump(dir)
            btn._held, btn._next = GetTime() + 0.4, nil
            btn:SetScript("OnUpdate", function(b)
                if not IsMouseButtonDown("LeftButton") then b:SetScript("OnUpdate", nil); return end
                local now = GetTime()
                if now >= b._held and (not b._next or now >= b._next) then
                    bump(dir); b._next = now + 0.125
                end
            end)
        end)
        btn:SetScript("OnMouseUp", function(b) b:SetScript("OnUpdate", nil) end)
    end
    armRepeat(s.minus, -1)
    armRepeat(s.plus, 1)

    function s:Refresh()
        self.value:SetText(tostring(tonumber(self._get()) or 0))
    end
    function s:SetEnabled(on)
        self._enabled = on and true or false
        self:SetAlpha(self._enabled and 1 or 0.5)
    end
    function s:SetStrokeColor(rgb)
        self._strokeOverride = rgb
        self:ApplyTheme()
    end
    function s:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(unpackColor(self._strokeOverride or th.strokeColor))
        self.value:SetTextColor(unpackColor(th.textColor))
        for _, b in ipairs({ self.minus, self.plus }) do
            b.text:SetTextColor(GREY_8B[1], GREY_8B[2], GREY_8B[3])
            b._hl:SetVertexColor(unpackColor(th.highlightColor))
        end
    end
    s:ApplyTheme()
    s:Refresh()
    return register(s)
end

------------------------------------------------------------------------
-- ns.MakeChoiceSegmented(parent, items, opts)
-- Generic segmented control for settings values (the roll-frame
-- MakeSegmented is bound to roll options).  items = { {value, label,
-- color?}, ... }.  Segments 26px, 11px padding, OLLFontLabel; unselected
-- labels #8b909b (or the item colour at 40%); the selected segment takes
-- the brass primary fill with primaryBtnTextColor, or its own colour as
-- fill when the item supplies one.
-- API: :SetValue(v), :GetValue(), :SetOnPick(fn(v)), :SetEnabled(bool),
--      :SetItems(items), :Refresh() (re-reads opts.get if given)
------------------------------------------------------------------------
function ns.MakeChoiceSegmented(parent, items, opts)
    opts = opts or {}
    local g = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SkinNineSlice(g, "btn")
    g._h, g._pad = opts.h or 26, opts.pad or 11
    g._segments, g._dividers = {}, {}
    g._enabled, g._get, g._onPick = true, opts.get, opts.onPick

    local function acquire(i)
        local s = g._segments[i]
        if s then return s end
        s = CreateFrame("Button", nil, g)
        s:SetHeight(g._h - 2)
        local fill = s:CreateTexture(nil, "BACKGROUND")
        fill:SetTexture(WHITE8x8); fill:SetAllPoints(); fill:Hide()
        s._fill = fill
        local shade = s:CreateTexture(nil, "BACKGROUND", nil, 1)
        shade:SetTexture(WHITE8x8); shade:SetAllPoints(); shade:Hide()
        s._shade = shade
        local hl = s:CreateTexture(nil, "BORDER")
        hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
        s._hl = hl
        local t = s:CreateFontString(nil, "OVERLAY")
        t:SetFontObject(Ledger.Fonts.OLLFontLabel)
        t:SetPoint("CENTER")
        s._text = t
        s:SetScript("OnEnter", function(b) if g._enabled and g._value ~= b._value then b._hl:Show() end end)
        s:SetScript("OnLeave", function(b) b._hl:Hide() end)
        s:SetScript("OnClick", function(b)
            if not g._enabled then return end
            if g._value == b._value then return end
            g._value = b._value
            g:ApplyTheme()
            if g._onPick then g._onPick(b._value) end
        end)
        g._segments[i] = s
        if i > 1 then
            local d = g:CreateTexture(nil, "ARTWORK")
            d:SetTexture(WHITE8x8); d:SetWidth(1)
            g._dividers[i] = d
        end
        return s
    end

    function g:SetItems(list)
        self._items = list or {}
        local x = 1
        for i, it in ipairs(self._items) do
            local s = acquire(i)
            s._value, s._item = it.value, it
            s._text:SetText(ns.Track(it.label or tostring(it.value)))
            local w = it.w or (s._text:GetStringWidth() + self._pad * 2)
            s:SetWidth(w)
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", self, "TOPLEFT", x, -1)
            s:Show()
            if i > 1 then
                local d = self._dividers[i]
                d:ClearAllPoints()
                d:SetPoint("TOPLEFT", self, "TOPLEFT", x - 1, -1)
                d:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x - 1, 1)
                d:Show()
            end
            x = x + w
            if i < #self._items then x = x + 1 end
        end
        for i = #self._items + 1, #self._segments do
            self._segments[i]:Hide()
            if self._dividers[i] then self._dividers[i]:Hide() end
        end
        self:SetSize(x + 1, self._h)
        self:ApplyTheme()
    end
    function g:SetValue(v) self._value = v; self:ApplyTheme() end
    function g:GetValue() return self._value end
    function g:SetOnPick(fn) self._onPick = fn end
    function g:SetEnabled(on) self._enabled = on and true or false; self:ApplyTheme() end
    function g:Refresh() if self._get then self:SetValue(self._get()) end end

    function g:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(unpackColor(self._enabled and th.strokeColor or th.strokeDimColor))
        for i, s in ipairs(self._segments) do
            if s:IsShown() then
                local sel = (self._value ~= nil and s._value == self._value)
                local c = s._item and s._item.color
                if sel then
                    if c then
                        s._fill:SetVertexColor(c[1], c[2], c[3], 1); s._fill:Show()
                        s._shade:Hide()
                        s._text:SetTextColor(unpackColor(th.primaryBtnTextColor))
                    else
                        s._fill:SetVertexColor(unpackColor(th.primaryBtnTop)); s._fill:Show()
                        local br, bg, bb = unpackColor(th.primaryBtnBot)
                        s._shade:SetGradient("VERTICAL", CreateColor(br, bg, bb, 1), CreateColor(br, bg, bb, 0))
                        s._shade:Show()
                        s._text:SetTextColor(unpackColor(th.primaryBtnTextColor))
                    end
                else
                    s._fill:Hide(); s._shade:Hide()
                    if c then
                        s._text:SetTextColor(c[1] * 0.6 + 0.08, c[2] * 0.6 + 0.08, c[3] * 0.6 + 0.08, self._enabled and 1 or 0.5)
                    else
                        s._text:SetTextColor(GREY_8B[1], GREY_8B[2], GREY_8B[3], self._enabled and 1 or 0.5)
                    end
                end
                s._hl:SetVertexColor(unpackColor(th.highlightColor))
                if self._dividers[i] then self._dividers[i]:SetVertexColor(unpackColor(th.strokeColor)) end
            end
        end
    end

    g:SetItems(items)
    if g._get then g._value = g._get() end
    g:ApplyTheme()
    return register(g)
end

------------------------------------------------------------------------
-- ns.MakeLedgerEditBox(parent, w, h, placeholder)
-- btn-edge outline, panelBgColor fill, OLLFontBody text, textDimColor
-- placeholder.  API: :SetPlaceholder(t), :FlashError(), :SetTextColorRGB(c)
------------------------------------------------------------------------
function ns.MakeLedgerEditBox(parent, w, h, placeholder)
    local wrap = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    wrap:SetSize(w or 200, h or 26)
    ns.SkinNineSlice(wrap, "btn")
    local eb = CreateFrame("EditBox", nil, wrap)
    eb:SetPoint("TOPLEFT", wrap, "TOPLEFT", 10, 0)
    eb:SetPoint("BOTTOMRIGHT", wrap, "BOTTOMRIGHT", -10, 0)
    eb:SetFontObject(Ledger.Fonts.OLLFontBody)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(0)
    wrap.edit = eb
    local ph = wrap:CreateFontString(nil, "OVERLAY")
    ph:SetFontObject(Ledger.Fonts.OLLFontBody)
    ph:SetPoint("LEFT", wrap, "LEFT", 10, 0)
    ph:SetText(placeholder or "")
    wrap.placeholder = ph
    local function updatePH() if eb:GetText() == "" and not eb:HasFocus() then ph:Show() else ph:Hide() end end
    eb:HookScript("OnTextChanged", updatePH)
    eb:HookScript("OnEditFocusGained", updatePH)
    eb:HookScript("OnEditFocusLost", updatePH)
    eb:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)

    function wrap:SetPlaceholder(t) self.placeholder:SetText(t or ""); updatePH() end
    function wrap:GetText() return self.edit:GetText() end
    function wrap:SetText(t) self.edit:SetText(t or ""); updatePH() end
    function wrap:SetTextColorRGB(c)
        self._textOverride = c
        self.edit:SetTextColor(unpackColor(c or ns.Theme:GetCurrent().textColor))
    end
    function wrap:FlashError()
        local th = ns.Theme:GetCurrent()
        self:SetBackdropBorderColor(unpackColor(th.timerBarLowColor))
        C_Timer.After(0.2, function() self:ApplyTheme() end)
    end
    function wrap:SetEnabled(on)
        self.edit:SetEnabled(on)
        self:SetAlpha(on and 1 or 0.5)
    end
    function wrap:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropColor(unpackColor(th.panelBgColor))
        self:SetBackdropBorderColor(unpackColor(th.strokeColor))
        self.edit:SetTextColor(unpackColor(self._textOverride or th.textColor))
        self.placeholder:SetTextColor(unpackColor(th.textDimColor))
    end
    wrap:ApplyTheme()
    updatePH()
    return register(wrap)
end

------------------------------------------------------------------------
-- ns.MakeLedgerSlider(parent, min, max, step, get, set, opts)
-- 4px #1c2027 track with accentColor fill to the value, 12px accentHiColor
-- knob ringed in frameBgColor, plus a 62px editable readout box with the
-- number and a unit label (opts.unit, default "SEC").  opts.w total width.
-- API: :Refresh(), :SetEnabled(bool)
------------------------------------------------------------------------
function ns.MakeLedgerSlider(parent, minV, maxV, step, get, set, opts)
    opts = opts or {}
    local w = opts.w or 360
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, 26)
    f._min, f._max, f._step, f._get, f._set = minV, maxV, step or 1, get, set
    f._enabled = true

    local readout = CreateFrame("Frame", nil, f, "BackdropTemplate")
    readout:SetSize(62, 26)
    readout:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    ns.SkinNineSlice(readout, "btn")
    f.readout = readout
    local unit = readout:CreateFontString(nil, "OVERLAY")
    unit:SetFontObject(Ledger.Fonts.OLLFontLabel)
    unit:SetPoint("RIGHT", readout, "RIGHT", -8, 0)
    unit:SetText(ns.Track(opts.unit or "SEC"))
    f.unit = unit
    local eb = CreateFrame("EditBox", nil, readout)
    eb:SetPoint("LEFT", readout, "LEFT", 8, 0)
    eb:SetPoint("RIGHT", unit, "LEFT", -4, 0)
    eb:SetHeight(24)
    eb:SetFontObject(Ledger.Fonts.OLLFontBody)
    eb:SetJustifyH("RIGHT")
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(4)
    f.edit = eb

    local slider = CreateFrame("Slider", nil, f)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("LEFT", f, "LEFT", 6, 0)
    slider:SetPoint("RIGHT", readout, "LEFT", -18, 0)
    slider:SetHeight(20)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step or 1)
    slider:SetObeyStepOnDrag(true)
    slider:EnableMouseWheel(false)
    f.slider = slider
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetTexture(WHITE8x8); track:SetHeight(4)
    track:SetPoint("LEFT", slider, "LEFT", 0, 0); track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
    f.track = track
    local fill = slider:CreateTexture(nil, "BORDER")
    fill:SetTexture(WHITE8x8); fill:SetHeight(4)
    fill:SetPoint("LEFT", slider, "LEFT", 0, 0)
    f.fill = fill
    local ring = slider:CreateTexture(nil, "ARTWORK")
    ring:SetTexture(Ledger.TEX.dot); ring:SetSize(16, 16)
    f.ring = ring
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(Ledger.TEX.dot); thumb:SetSize(12, 12)
    slider:SetThumbTexture(thumb)
    f.thumb = thumb
    ring:SetPoint("CENTER", thumb, "CENTER", 0, 0)

    local function paintFill()
        local v = slider:GetValue()
        local frac = (v - minV) / math.max(1, (maxV - minV))
        fill:SetWidth(math.max(1, slider:GetWidth() * frac))
    end
    slider:SetScript("OnSizeChanged", paintFill)

    local function snap(v)
        v = math.max(minV, math.min(maxV, v))
        local st = f._step
        return math.floor((v - minV) / st + 0.5) * st + minV
    end

    f._suppress = false
    slider:SetScript("OnValueChanged", function(_, v, user)
        if f._suppress then return end
        v = snap(v)
        eb:SetText(tostring(v))
        paintFill()
        if user and f._enabled then f._set(v) end
    end)

    eb:SetScript("OnEnterPressed", function(e)
        local v = tonumber(e:GetText())
        if v then v = snap(v); f._set(v) end
        e:ClearFocus()
        f:Refresh()
    end)
    eb:SetScript("OnEscapePressed", function(e) e:ClearFocus(); f:Refresh() end)

    function f:Refresh()
        local v = snap(tonumber(self._get()) or minV)
        self._suppress = true
        self.slider:SetValue(v)
        self._suppress = false
        self.edit:SetText(tostring(v))
        paintFill()
    end
    function f:SetEnabled(on)
        self._enabled = on and true or false
        self.slider:SetEnabled(self._enabled)
        self.edit:SetEnabled(self._enabled)
        self:SetAlpha(self._enabled and 1 or 0.5)
    end
    function f:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self.track:SetVertexColor(DARK_1C[1], DARK_1C[2], DARK_1C[3])
        self.fill:SetVertexColor(unpackColor(th.accentColor))
        self.thumb:SetVertexColor(unpackColor(th.accentHiColor))
        self.ring:SetVertexColor(unpackColor(th.frameBgColor))
        self.readout:SetBackdropColor(unpackColor(th.panelBgColor))
        self.readout:SetBackdropBorderColor(unpackColor(th.strokeColor))
        self.edit:SetTextColor(unpackColor(th.textColor))
        self.unit:SetTextColor(unpackColor(th.textMutedColor))
    end
    f:ApplyTheme()
    f:Refresh()
    return register(f)
end

------------------------------------------------------------------------
-- ns.MakeSettingRow(parent, opts)
-- One row: label (OLLFontBody/textColor), optional sub-line 3px below
-- (OLLFontBodySmall/textMutedColor), right-aligned control slot, 1px
-- histSepColor TOP hairline, 11px vertical padding.
--   opts.label, opts.sub, opts.control (frame), opts.tooltip (long text),
--   opts.locked (bool), opts.refresh (fn) -> called by row:Refresh()
-- API: row:SetControl(f), row:SetLocked(bool), row:SetSub(t), row:Refresh(),
--      row:SetDimmed(bool), row:Layout() (recomputes height)
------------------------------------------------------------------------
function ns.MakeSettingRow(parent, opts)
    opts = opts or {}
    local r = CreateFrame("Frame", nil, parent)
    r._locked, r._refresh, r._tooltip = opts.locked, opts.refresh, opts.tooltip

    r.hair = ns.MakeHairline(r, "histSepColor")
    r.hair:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.hair:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)

    r.label = r:CreateFontString(nil, "OVERLAY")
    r.label:SetFontObject(Ledger.Fonts.OLLFontBody)
    r.label:SetJustifyH("LEFT")
    r.label:SetText(opts.label or "")

    r.sub = r:CreateFontString(nil, "OVERLAY")
    r.sub:SetFontObject(Ledger.Fonts.OLLFontBodySmall)
    r.sub:SetJustifyH("LEFT")
    r.sub:SetPoint("TOPLEFT", r.label, "BOTTOMLEFT", 0, -3)
    r.sub:SetText(opts.sub or "")
    if not opts.sub or opts.sub == "" then r.sub:Hide() end

    r.lock = r:CreateFontString(nil, "OVERLAY")
    r.lock:SetFontObject(Ledger.Fonts.OLLFontLabel)
    r.lock:SetText("|TInterface\\PetBattles\\PetBattle-LockIcon:12:12|t")
    r.lock:Hide()

    -- hover target for the long-form tooltip
    r.hover = CreateFrame("Frame", nil, r)
    r.hover:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.hover:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
    r.hover:SetWidth(1)
    r.hover:EnableMouse(true)
    r.hover:SetScript("OnEnter", function(h)
        if not r._tooltip then return end
        GameTooltip:SetOwner(h, "ANCHOR_TOPLEFT")
        GameTooltip:SetText(opts.label or "", 1, 1, 1)
        GameTooltip:AddLine(r._tooltip, 0.76, 0.78, 0.82, true)
        GameTooltip:Show()
    end)
    r.hover:SetScript("OnLeave", GameTooltip_Hide)

    function r:SetControl(c)
        self._control = c
        if c then
            c:SetParent(self)
            c:ClearAllPoints()
            c:SetPoint("RIGHT", self, "RIGHT", 0, 0)
        end
        self:Layout()
    end
    function r:SetSub(t)
        self.sub:SetText(t or "")
        if t and t ~= "" then self.sub:Show() else self.sub:Hide() end
        self:Layout()
    end
    function r:SetLocked(on)
        self._locked = on and true or false
        self:Refresh()
    end
    function r:SetDimmed(on) self:SetAlpha(on and 0.45 or 1) end
    function r:Layout()
        local textH = self.label:GetStringHeight()
        if self.sub:IsShown() then textH = textH + 3 + self.sub:GetStringHeight() end
        local ctlH = self._control and self._control:GetHeight() or 0
        local h = math.max(ctlH, textH) + 22
        self:SetHeight(h)
        self.label:ClearAllPoints()
        if self.sub:IsShown() then
            self.label:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -11)
        else
            self.label:SetPoint("LEFT", self, "LEFT", 0, 0)
        end
        local ctlW = self._control and self._control:GetWidth() or 0
        self.label:SetWidth(math.max(60, self:GetWidth() - ctlW - 40))
        self.sub:SetWidth(math.max(60, self:GetWidth() - ctlW - 40))
        self.hover:SetWidth(math.max(60, self:GetWidth() - ctlW - 40))
        self.lock:ClearAllPoints()
        if self._control then
            self.lock:SetPoint("RIGHT", self._control, "LEFT", -8, 0)
        else
            self.lock:SetPoint("RIGHT", self, "RIGHT", 0, 0)
        end
    end
    -- Lock rule: a locked row dims its control while a session is active.
    function r:Refresh()
        local active = ns.Session and ns.Session:IsActive()
        local lockNow = self._locked and active
        if self._locked then self.lock:Show() else self.lock:Hide() end
        self.lock:SetAlpha(lockNow and 1 or 0.35)
        if self._control and self._control.SetEnabled then
            self._control:SetEnabled(not lockNow and not self._forceDisabled)
        end
        if self._refresh then self._refresh(self) end
    end
    function r:SetForceDisabled(on)
        self._forceDisabled = on and true or false
        self:Refresh()
    end
    function r:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self.hair:SetVertexColor(unpackColor(th.histSepColor))
        self.label:SetTextColor(unpackColor(th.textColor))
        self.sub:SetTextColor(unpackColor(th.textMutedColor))
        self.lock:SetTextColor(unpackColor(th.textDimColor))
    end
    r:SetScript("OnSizeChanged", function(self) self:Layout() end)
    r:ApplyTheme()
    if opts.control then r:SetControl(opts.control) else r:Layout() end
    return register(r)
end

------------------------------------------------------------------------
-- ns.MakeSettingsNav(parent, w, groups, onPick)
-- The sidebar.  groups = { { header = "YOU", items = { {key, label,
-- badge}, ... } }, ... }.  Group headers 26px (OLLFontLabel; the active
-- group's header is accentColor, others textMutedColor).  Rows 34px,
-- OLLFontBody, #8b909b inactive; active = rowBgColor fill + 2px accent
-- tick + textColor.  Roster-style count badge right-aligned.
-- nav.footer is a frame at the bottom for the caller to fill.
-- API: nav:Select(key), nav:SetBadge(key, n), nav:GetSelected()
------------------------------------------------------------------------
function ns.MakeSettingsNav(parent, w, groups, onPick)
    local nav = CreateFrame("Frame", nil, parent)
    nav:SetWidth(w)
    nav._rows, nav._headers, nav._groups, nav._onPick = {}, {}, groups, onPick

    local bg = nav:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE8x8); bg:SetAllPoints()
    nav._bg = bg
    local rule = nav:CreateTexture(nil, "ARTWORK")
    rule:SetTexture(WHITE8x8); rule:SetWidth(1)
    rule:SetPoint("TOPRIGHT", nav, "TOPRIGHT", 0, 0)
    rule:SetPoint("BOTTOMRIGHT", nav, "BOTTOMRIGHT", 0, 0)
    nav._rule = rule

    local y = -8
    for gi, grp in ipairs(groups) do
        if gi > 1 then y = y - 14 end
        local hdr = nav:CreateFontString(nil, "OVERLAY")
        hdr:SetFontObject(Ledger.Fonts.OLLFontLabel)
        hdr:SetPoint("TOPLEFT", nav, "TOPLEFT", 16, y - 8)
        hdr:SetText(ns.Track(grp.header))
        hdr._group = gi
        nav._headers[gi] = hdr
        y = y - 26
        for _, it in ipairs(grp.items) do
            local row = CreateFrame("Button", nil, nav)
            row:SetHeight(34)
            row:SetPoint("TOPLEFT", nav, "TOPLEFT", 0, y)
            row:SetPoint("TOPRIGHT", nav, "TOPRIGHT", -1, y)
            row._key, row._group = it.key, gi
            local fill = row:CreateTexture(nil, "BACKGROUND")
            fill:SetTexture(WHITE8x8); fill:SetAllPoints(); fill:Hide()
            row._fill = fill
            local tick = row:CreateTexture(nil, "ARTWORK")
            tick:SetTexture(WHITE8x8); tick:SetWidth(2)
            tick:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); tick:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            tick:Hide()
            row._tick = tick
            local hl = row:CreateTexture(nil, "BACKGROUND", nil, 1)
            hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
            row._hl = hl
            local label = row:CreateFontString(nil, "OVERLAY")
            label:SetFontObject(Ledger.Fonts.OLLFontBody)
            label:SetPoint("LEFT", row, "LEFT", 16, 0)
            label:SetText(it.label)
            row._label = label
            local badge = CreateFrame("Frame", nil, row, "BackdropTemplate")
            badge:SetHeight(16)
            badge:SetPoint("RIGHT", row, "RIGHT", -16, 0)
            ns.SkinNineSlice(badge, "pill")
            local bt = badge:CreateFontString(nil, "OVERLAY")
            bt:SetFontObject(Ledger.Fonts.OLLFontLabel)
            bt:SetPoint("CENTER")
            badge._text = bt
            badge:Hide()
            row._badge = badge
            row:SetScript("OnEnter", function(b) if nav._selected ~= b._key then b._hl:Show() end end)
            row:SetScript("OnLeave", function(b) b._hl:Hide() end)
            row:SetScript("OnClick", function(b)
                nav:Select(b._key)
                if nav._onPick then nav._onPick(b._key) end
            end)
            nav._rows[it.key] = row
            if it.badge then nav:SetBadge(it.key, it.badge) end
            y = y - 34
        end
    end
    nav._contentBottom = y

    -- footer: 1px histSepColor top rule, 10/16/14 padding
    local footer = CreateFrame("Frame", nil, nav)
    footer:SetPoint("BOTTOMLEFT", nav, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", nav, "BOTTOMRIGHT", -1, 0)
    footer:SetHeight(76)
    footer.rule = ns.MakeHairline(footer, "histSepColor")
    footer.rule:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 0)
    footer.rule:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0)
    nav.footer = footer

    function nav:SetBadge(key, n)
        local row = self._rows[key]
        if not row then return end
        if n and n > 0 then
            row._badge._text:SetText(tostring(n))
            row._badge:SetWidth(row._badge._text:GetStringWidth() + 10)
            row._badge:Show()
        else
            row._badge:Hide()
        end
        self:ApplyTheme()
    end
    function nav:Select(key)
        self._selected = key
        self:ApplyTheme()
    end
    function nav:GetSelected() return self._selected end
    function nav:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self._bg:SetVertexColor(unpackColor(th.panelBgColor))
        self._rule:SetVertexColor(unpackColor(th.dividerColor))
        self.footer.rule:SetVertexColor(unpackColor(th.histSepColor))
        local activeGroup = self._selected and self._rows[self._selected] and self._rows[self._selected]._group
        for gi, hdr in ipairs(self._headers) do
            if gi == activeGroup then hdr:SetTextColor(unpackColor(th.accentColor))
            else hdr:SetTextColor(unpackColor(th.textMutedColor)) end
        end
        for key, row in pairs(self._rows) do
            local active = (key == self._selected)
            row._hl:SetVertexColor(unpackColor(th.highlightColor))
            if active then
                row._fill:SetVertexColor(unpackColor(th.rowBgColor)); row._fill:Show()
                row._tick:SetVertexColor(unpackColor(th.accentColor)); row._tick:Show()
                row._label:SetTextColor(unpackColor(th.textColor))
                row._badge:SetBackdropColor(th.accentColor[1], th.accentColor[2], th.accentColor[3], 0.16)
                row._badge:SetBackdropBorderColor(th.accentColor[1], th.accentColor[2], th.accentColor[3], 0.16)
                row._badge._text:SetTextColor(unpackColor(th.accentHiColor))
            else
                row._fill:Hide(); row._tick:Hide()
                row._label:SetTextColor(GREY_8B[1], GREY_8B[2], GREY_8B[3])
                row._badge:SetBackdropColor(DARK_1C[1], DARK_1C[2], DARK_1C[3], 1)
                row._badge:SetBackdropBorderColor(DARK_1C[1], DARK_1C[2], DARK_1C[3], 1)
                row._badge._text:SetTextColor(GREY_8B[1], GREY_8B[2], GREY_8B[3])
            end
        end
    end
    nav:ApplyTheme()
    return register(nav)
end

------------------------------------------------------------------------
-- ns.MakeGlyphButton(parent, glyph, size)
-- Small text-glyph button (x, v, drag handle) in #8b909b with a hover wash.
-- API: :SetColorRGB(c), :SetInert(bool)
------------------------------------------------------------------------
function ns.MakeGlyphButton(parent, glyph, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 22, size or 22)
    local hl = b:CreateTexture(nil, "BACKGROUND"); hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
    b._hl = hl
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetFontObject(Ledger.Fonts.OLLFontBody)
    b.text:SetPoint("CENTER")
    b.text:SetText(glyph)
    b:SetScript("OnEnter", function(x) if not x._inert then x._hl:Show() end end)
    b:SetScript("OnLeave", function(x) x._hl:Hide() end)
    function b:SetColorRGB(c) self._rgb = c; self:ApplyTheme() end
    function b:SetInert(on)
        self._inert = on and true or false
        self:ApplyTheme()
    end
    function b:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self._hl:SetVertexColor(unpackColor(th.highlightColor))
        if self._inert then self.text:SetTextColor(unpackColor(th.textDimColor))
        elseif self._rgb then self.text:SetTextColor(unpackColor(self._rgb))
        else self.text:SetTextColor(GREY_8B[1], GREY_8B[2], GREY_8B[3]) end
    end
    b:ApplyTheme()
    return register(b)
end

------------------------------------------------------------------------
-- ns.MakeBadge(parent, text) — 2px-radius tag (MAIN / EDITED): accent @14%
-- fill, accent @35% stroke, accentHiColor label.
------------------------------------------------------------------------
function ns.MakeBadge(parent, text)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetHeight(16)
    ns.SkinNineSlice(b, "pill")
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetFontObject(Ledger.Fonts.OLLFontLabel)
    b.text:SetPoint("CENTER")
    function b:SetText(t)
        self.text:SetText(ns.Track(t))
        self:SetWidth(self.text:GetStringWidth() + 12)
    end
    function b:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        local a = th.accentColor
        self:SetBackdropColor(a[1], a[2], a[3], 0.14)
        self:SetBackdropBorderColor(a[1], a[2], a[3], 0.35)
        self.text:SetTextColor(unpackColor(th.accentHiColor))
    end
    b:SetText(text or "")
    b:ApplyTheme()
    return register(b)
end
