------------------------------------------------------------------------
-- OrderedLootList  –  UI/Widgets.lua
-- "Ledger" shared UI primitives: font objects, textures, and the six
-- builders every frame is assembled from (frame, header bar, button,
-- segmented control, item row, table), plus small helpers and motion.
--
-- Everything here is theme-driven.  Builders read ns.Theme:GetCurrent()
-- when they create widgets and expose a :ApplyTheme(theme) on each widget
-- so frames can re-tint on a theme switch without rebuilding.
--
-- Platform notes (things the design mocks do that WoW cannot):
--   * no letter-spacing / text-transform  -> ns.Track uppercases only
--   * no border-radius                    -> 9-slice TGAs in Textures/
--   * no CSS gradients                    -> Texture:SetGradient
--   * no colour animation                 -> colours snap; alpha animates
--   * no subtree opacity                  -> frame:SetAlpha on the row
------------------------------------------------------------------------

local ADDON_FOLDER = ...          -- "OrderedLootList" or "OrderedLootList-Dev"
local ns           = _G.OLL_NS

local Ledger = {}
ns.Ledger    = Ledger

local ADDON_PATH  = "Interface\\AddOns\\" .. ADDON_FOLDER .. "\\"
local FONT_PATH   = ADDON_PATH .. "Fonts\\"
local TEX_PATH    = ADDON_PATH .. "Textures\\"
local WHITE8x8    = "Interface\\Buttons\\WHITE8x8"

Ledger.TEX = {
    frameEdge = TEX_PATH .. "frame-edge.tga",   -- 64x64, 6px radius (9-slice corner 8)
    frameFill = TEX_PATH .. "frame-fill.tga",
    btnEdge   = TEX_PATH .. "btn-edge.tga",     -- 32x32, 4px radius (9-slice corner 6)
    btnFill   = TEX_PATH .. "btn-fill.tga",
    pillEdge  = TEX_PATH .. "pill-edge.tga",    -- 32x16, 2px radius (9-slice corner 4)
    pillFill  = TEX_PATH .. "pill-fill.tga",
    chevron   = TEX_PATH .. "resize-chevron.tga",
    dot       = TEX_PATH .. "dot.tga",
    white     = WHITE8x8,
}

-- Spacing scale from the spec: 2, 4, 6, 8, 10, 12, 14, 16
Ledger.INSET       = 16   -- frame content inset left/right
Ledger.INSET_CLOSE = 12   -- right inset of a title bar where the close button sits
Ledger.GUTTER      = 12   -- column gutter in tables
Ledger.NUM_PAD     = 12   -- trailing padding on right-aligned numeric columns

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local function unpackColor(c, alphaOverride)
    if not c then return 1, 1, 1, alphaOverride or 1 end
    return c[1], c[2], c[3], alphaOverride or c[4] or 1
end
Ledger.UnpackColor = unpackColor

-- Labels are uppercase in the string (WoW has no text-transform).  Letter
-- tracking is deliberately NOT applied: the fonts may lack the thin-space
-- glyph, and plain spaces read as broken words.  One place to change.
function ns.Track(s)
    if not s then return "" end
    return string.upper(s)
end

-- Item-quality colour as an {r,g,b} table (canonical, from the client)
function Ledger.QualityColor(quality)
    local r, g, b = ns.GetItemQualityColor(quality or 1)
    return { r, g, b }
end

-- 1px rule.  `layer` defaults to ARTWORK.
function ns.MakeHairline(parent, colorKey, layer)
    local tex = parent:CreateTexture(nil, layer or "ARTWORK")
    tex:SetTexture(WHITE8x8)
    tex._themeKey = colorKey or "dividerColor"
    tex:SetVertexColor(unpackColor(ns.Theme:GetCurrent()[tex._themeKey]))
    tex:SetHeight(1)
    return tex
end

------------------------------------------------------------------------
-- Nine-slice skin.
-- Blizzard's SetBackdrop(edgeFile=...) expects the 8-segment horizontal
-- strip its own border art uses; a rounded-rect image sliced that way
-- renders as dashes.  This builds the 9-slice by hand: four fixed corners,
-- four stretched 1px edge strips and a centre, for both the outline and the
-- solid body, and installs SetBackdropColor / SetBackdropBorderColor on the
-- frame so callers keep using the familiar API.
------------------------------------------------------------------------
local NINE_KINDS = {
    frame = { edge = "frameEdge", fill = "frameFill", w = 64, h = 64, c = 8 },
    btn   = { edge = "btnEdge",   fill = "btnFill",   w = 32, h = 32, c = 6 },
    pill  = { edge = "pillEdge",  fill = "pillFill",  w = 32, h = 16, c = 4 },
}

local function BuildNineSlice(frame, texPath, w, h, c, layer, sublevel)
    local cu, cv = c / w, c / h
    local mu0, mu1 = 0.5 - 0.5 / w, 0.5 + 0.5 / w   -- 1px column at the horizontal middle
    local mv0, mv1 = 0.5 - 0.5 / h, 0.5 + 0.5 / h   -- 1px row at the vertical middle
    local pieces = {}
    local function piece(l, r, t, b)
        local tex = frame:CreateTexture(nil, layer, nil, sublevel)
        tex:SetTexture(texPath)
        tex:SetTexCoord(l, r, t, b)
        tinsert(pieces, tex)
        return tex
    end
    local tl = piece(0, cu, 0, cv);          tl:SetSize(c, c); tl:SetPoint("TOPLEFT")
    local tr = piece(1 - cu, 1, 0, cv);      tr:SetSize(c, c); tr:SetPoint("TOPRIGHT")
    local bl = piece(0, cu, 1 - cv, 1);      bl:SetSize(c, c); bl:SetPoint("BOTTOMLEFT")
    local br = piece(1 - cu, 1, 1 - cv, 1);  br:SetSize(c, c); br:SetPoint("BOTTOMRIGHT")
    local top = piece(mu0, mu1, 0, cv)
    top:SetPoint("TOPLEFT", tl, "TOPRIGHT"); top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
    local bottom = piece(mu0, mu1, 1 - cv, 1)
    bottom:SetPoint("TOPLEFT", bl, "TOPRIGHT"); bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    local left = piece(0, cu, mv0, mv1)
    left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT"); left:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT")
    local right = piece(1 - cu, 1, mv0, mv1)
    right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT"); right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    local centre = piece(mu0, mu1, mv0, mv1)
    centre:SetPoint("TOPLEFT", tl, "BOTTOMRIGHT"); centre:SetPoint("BOTTOMRIGHT", br, "TOPLEFT")
    return pieces
end

-- kind: "frame" | "btn" | "pill".  Returns the frame.
function ns.SkinNineSlice(frame, kind)
    local def = NINE_KINDS[kind] or NINE_KINDS.btn
    if frame._nine then return frame end
    local nine = {
        fill = BuildNineSlice(frame, Ledger.TEX[def.fill], def.w, def.h, def.c, "BACKGROUND", -8),
        edge = BuildNineSlice(frame, Ledger.TEX[def.edge], def.w, def.h, def.c, "BORDER", 7),
    }
    frame._nine = nine
    frame.SetBackdropColor = function(self, r, g, b, a)
        for _, t in ipairs(self._nine.fill) do t:SetVertexColor(r or 0, g or 0, b or 0, a == nil and 1 or a) end
    end
    frame.SetBackdropBorderColor = function(self, r, g, b, a)
        for _, t in ipairs(self._nine.edge) do t:SetVertexColor(r or 1, g or 1, b or 1, a == nil and 1 or a) end
    end
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(1, 1, 1, 1)
    return frame
end

------------------------------------------------------------------------
-- Font objects.  Created once; frames reference them by object.
-- Colours come from the theme and are re-applied by Ledger.ApplyTheme.
------------------------------------------------------------------------
local FONT_DEFS = {
    -- name,               file,                                 size, themeColorKey
    { "OLLFontTitle",      "Spectral-SemiBold.ttf",              14,   "accentHiColor" },
    { "OLLFontHero",       "Spectral-Medium.ttf",                17,   "textColor" },
    { "OLLFontBody",       "BarlowSemiCondensed-SemiBold.ttf",   13,   "textColor" },
    { "OLLFontBodySmall",  "BarlowSemiCondensed-Regular.ttf",    11,   "textMutedColor" },
    { "OLLFontLabel",      "BarlowSemiCondensed-SemiBold.ttf",   10,   "textMutedColor" },
    { "OLLFontNumberBig",  "BarlowSemiCondensed-SemiBold.ttf",   30,   "textColor" },
    -- extra sizes the spec calls out inline
    { "OLLFontNumberMid",  "BarlowSemiCondensed-SemiBold.ttf",   20,   "textColor" },
    { "OLLFontNumberSmall","BarlowSemiCondensed-SemiBold.ttf",   17,   "textColor" },
    { "OLLFontMeta",       "BarlowSemiCondensed-Regular.ttf",    12,   "textMutedColor" },
}

Ledger.Fonts = {}
for _, def in ipairs(FONT_DEFS) do
    local name, file, size, colorKey = def[1], def[2], def[3], def[4]
    local font = _G[name] or CreateFont(name)
    -- NOTE: the client only discovers new files under Interface\AddOns at
    -- startup.  The first time Fonts/ appears, a full client restart (not
    -- /reload) is required or these fontstrings render blank.
    font:SetFont(FONT_PATH .. file, size, "")
    font._colorKey = colorKey
    Ledger.Fonts[name] = font
end

------------------------------------------------------------------------
-- Theme application for everything owned by this file.
-- Widgets register themselves in Ledger._skinned (weak keys) so a theme
-- switch re-tints them without the owning frame having to track each one.
------------------------------------------------------------------------
Ledger._skinned = setmetatable({}, { __mode = "k" })

local function register(widget)
    Ledger._skinned[widget] = true
    return widget
end

function Ledger.ApplyTheme(theme)
    theme = theme or ns.Theme:GetCurrent()
    for _, font in pairs(Ledger.Fonts) do
        font:SetTextColor(unpackColor(theme[font._colorKey]))
    end
    for widget in pairs(Ledger._skinned) do
        if widget.ApplyTheme then widget:ApplyTheme(theme) end
    end
end

------------------------------------------------------------------------
-- ns.MakeLedgerFrame(name, w, h, posKey, opts)
-- Movable, clamped, 9-slice backdrop, position save/restore, RaiseFrame on
-- mouse-down.  opts.resizable = true adds bounds + a chevron grip.
-- opts.minW/minH for the resize bounds.  opts.strata (default "DIALOG").
------------------------------------------------------------------------
function ns.MakeLedgerFrame(name, w, h, posKey, opts)
    opts = opts or {}
    local theme = ns.Theme:GetCurrent()

    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(w, h)
    f._defaultSize = { w, h }
    f:SetPoint(opts.point or "CENTER", UIParent, opts.point or "CENTER", opts.x or 0, opts.y or 0)
    f:SetFrameStrata(opts.strata or "DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self._posKey then ns.SaveFramePosition(self._posKey, self) end
    end)
    f:SetScript("OnMouseDown", function(frm) ns.RaiseFrame(frm) end)
    f._posKey = posKey

    ns.SkinNineSlice(f, "frame")

    function f:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropColor(unpackColor(th.frameBgColor))
        self:SetBackdropBorderColor(unpackColor(th.frameBorderColor))
        if self._grip then self._grip:SetVertexColor(unpackColor(th.textDimColor)) end
    end
    f:ApplyTheme(theme)
    register(f)

    if opts.resizable then
        f:SetResizable(true)
        f:SetResizeBounds(opts.minW or math.floor(w * 0.6), opts.minH or math.floor(h * 0.6),
            math.floor(UIParent:GetWidth()), math.floor(UIParent:GetHeight()))
        local grip = CreateFrame("Button", nil, f)
        grip:SetSize(14, 14)
        grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
        grip._levelOffset = 10
        grip:SetFrameLevel(f:GetFrameLevel() + 10)
        local gt = grip:CreateTexture(nil, "OVERLAY")
        gt:SetAllPoints()
        gt:SetTexture(Ledger.TEX.chevron)
        gt:SetVertexColor(unpackColor(theme.textDimColor))
        f._grip = gt
        grip:SetScript("OnMouseDown", function()
            ns.AnchorTopLeft(f)
            f:StartSizing("BOTTOMRIGHT")
        end)
        grip:SetScript("OnMouseUp", function()
            f:StopMovingOrSizing()
            if f._posKey then ns.SaveFramePosition(f._posKey, f) end
        end)
        grip:SetScript("OnEnter", function() gt:SetVertexColor(unpackColor(ns.Theme:GetCurrent().textMutedColor)) end)
        grip:SetScript("OnLeave", function() gt:SetVertexColor(unpackColor(ns.Theme:GetCurrent().textDimColor)) end)
        f._resizeGrip = grip
    end

    if posKey then ns.RestoreFramePosition(posKey, f) end
    if opts.fadeIn ~= false then Ledger.AttachFadeIn(f) end
    return f
end

------------------------------------------------------------------------
-- Close glyph: two 1px bars rotated ±45° (no font-glyph dependency).
------------------------------------------------------------------------
local function MakeCloseButton(parent, size)
    size = size or 28
    local theme = ns.Theme:GetCurrent()
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    local len = math.floor(size * 0.42)
    local a = b:CreateTexture(nil, "ARTWORK")
    a:SetTexture(WHITE8x8); a:SetSize(len, 1.2); a:SetPoint("CENTER"); a:SetRotation(math.rad(45))
    local c = b:CreateTexture(nil, "ARTWORK")
    c:SetTexture(WHITE8x8); c:SetSize(len, 1.2); c:SetPoint("CENTER"); c:SetRotation(math.rad(-45))
    local hl = b:CreateTexture(nil, "BACKGROUND")
    hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
    b._bars, b._hl = { a, c }, hl
    function b:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        for _, t in ipairs(self._bars) do t:SetVertexColor(unpackColor(th.textMutedColor)) end
        self._hl:SetVertexColor(unpackColor(th.highlightColor))
    end
    b:ApplyTheme(theme)
    b:SetScript("OnEnter", function(self)
        self._hl:Show()
        for _, t in ipairs(self._bars) do t:SetVertexColor(unpackColor(ns.Theme:GetCurrent().textColor)) end
    end)
    b:SetScript("OnLeave", function(self)
        self._hl:Hide()
        self:ApplyTheme()
    end)
    return register(b)
end
ns.MakeCloseButton = MakeCloseButton

------------------------------------------------------------------------
-- ns.MakeButton(parent, style, label, w, h)
-- style: "primary" (brass gradient fill, dark label; max one per frame),
--        "outline" (stroke + label), "quiet" (dim stroke + dim label).
-- Extra API: btn:SetLabel(text), btn:SetSubLabel(text) (60%-alpha suffix),
-- btn:SetBadge(n) (brass count badge, nil hides), btn:SetStyle(style),
-- btn:SetStrokeColor(rgb) (override stroke; e.g. delete buttons).
-- Disabled state dims stroke + label (outline/quiet) or SetAlpha(0.5)
-- (primary); it never greys the fill.
------------------------------------------------------------------------
function ns.MakeButton(parent, style, label, w, h)
    local theme = ns.Theme:GetCurrent()
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 96, h or 26)
    ns.SkinNineSlice(b, "btn")

    -- primary shade: darkens the lower half of the (rounded) brass body
    local fill = b:CreateTexture(nil, "BACKGROUND", nil, -7)
    fill:SetTexture(WHITE8x8)
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    b._fill = fill

    -- hover wash
    local hl = b:CreateTexture(nil, "BORDER")
    hl:SetTexture(WHITE8x8)
    hl:SetPoint("TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", -1, 1)
    hl:Hide()
    b._hl = hl

    -- label + optional sub-label, centred as a group
    local text = b:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(Ledger.Fonts.OLLFontLabel)
    text:SetJustifyH("CENTER")
    text:SetPoint("CENTER")
    b._text = text

    local sub = b:CreateFontString(nil, "OVERLAY")
    sub:SetFontObject(Ledger.Fonts.OLLFontLabel)
    sub:SetPoint("LEFT", text, "RIGHT", 6, 0)
    sub:Hide()
    b._sub = sub

    -- badge (brass count)
    local badge = CreateFrame("Frame", nil, b, "BackdropTemplate")
    badge:SetSize(18, 16)
    badge:SetPoint("LEFT", text, "RIGHT", 8, 0)
    ns.SkinNineSlice(badge, "pill")
    local badgeText = badge:CreateFontString(nil, "OVERLAY")
    badgeText:SetFontObject(Ledger.Fonts.OLLFontLabel)
    badgeText:SetPoint("CENTER")
    badge._text = badgeText
    badge:Hide()
    b._badge = badge

    b._style = style or "outline"
    b._strokeOverride = nil

    local function relayout(self)
        -- Recentre label+sub+badge as a group
        local total = self._text:GetStringWidth()
        if self._sub:IsShown()   then total = total + 6 + self._sub:GetStringWidth() end
        if self._badge:IsShown() then total = total + 8 + self._badge:GetWidth() end
        self._text:ClearAllPoints()
        self._text:SetPoint("LEFT", self, "CENTER", -total / 2, 0)
    end

    function b:SetLabel(txt)
        self._text:SetText(ns.Track(txt))
        relayout(self)
    end
    function b:SetSubLabel(txt)
        if txt and txt ~= "" then self._sub:SetText(txt); self._sub:Show() else self._sub:Hide() end
        relayout(self)
    end
    function b:SetBadge(n)
        if n and n > 0 then
            self._badge._text:SetText(tostring(n))
            self._badge:SetWidth(math.max(18, self._badge._text:GetStringWidth() + 10))
            self._badge:Show()
        else
            self._badge:Hide()
        end
        relayout(self)
    end
    function b:SetStyle(s)
        self._style = s
        self:ApplyTheme()
    end
    function b:SetStrokeColor(rgb)
        self._strokeOverride = rgb
        self:ApplyTheme()
    end

    function b:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        local enabled = self:IsEnabled()
        local style = self._style
        self._hl:SetVertexColor(unpackColor(th.highlightColor))
        self._badge:SetBackdropColor(unpackColor(th.accentColor))
        self._badge:SetBackdropBorderColor(unpackColor(th.accentColor))
        self._badge._text:SetTextColor(unpackColor(th.primaryBtnTextColor))

        if style == "primary" then
            self:SetBackdropColor(unpackColor(th.primaryBtnTop))
            self._fill:Show()
            local br, bg, bb = unpackColor(th.primaryBtnBot)
            self._fill:SetGradient("VERTICAL", CreateColor(br, bg, bb, 1), CreateColor(br, bg, bb, 0))
            self:SetBackdropBorderColor(unpackColor(th.primaryBtnBot))
            self._text:SetTextColor(unpackColor(th.primaryBtnTextColor))
            local r, g, bb = unpackColor(th.primaryBtnTextColor)
            self._sub:SetTextColor(r, g, bb, 0.6)
            self:SetAlpha(enabled and 1 or 0.5)
        else
            self._fill:Hide()
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetAlpha(1)
            local stroke = self._strokeOverride
                or ((style == "quiet" or not enabled) and th.strokeDimColor or th.strokeColor)
            self:SetBackdropBorderColor(unpackColor(stroke))
            if not enabled then
                self._text:SetTextColor(0.337, 0.361, 0.404)          -- #565c67
            elseif self._textOverride then
                self._text:SetTextColor(unpackColor(self._textOverride))
            elseif style == "quiet" then
                self._text:SetTextColor(unpackColor(th.textDimColor))
            else
                self._text:SetTextColor(0.761, 0.780, 0.816)          -- #c2c7d0
            end
            self._sub:SetTextColor(unpackColor(th.textMutedColor))
        end
    end

    -- A custom enabled-state label colour that survives SetEnabled /
    -- ApplyTheme (which recolour _text unconditionally).
    function b:SetTextColorOverride(rgb)
        self._textOverride = rgb
        self:ApplyTheme()
    end

    b:SetScript("OnEnter", function(self) if self:IsEnabled() then self._hl:Show() end end)
    b:SetScript("OnLeave", function(self) self._hl:Hide() end)
    b:SetScript("OnEnable",  function(self) self:ApplyTheme() end)
    b:SetScript("OnDisable", function(self) self._hl:Hide(); self:ApplyTheme() end)

    b:SetLabel(label or "")
    b:ApplyTheme(theme)
    return register(b)
end

------------------------------------------------------------------------
-- ns.MakeSegmented(parent, options, onPick, opts)
-- One rounded group with 1px internal dividers.  `options` is a list of
-- roll options ({name, priority}) — Pass is appended automatically unless
-- opts.noPass.  Segment label colour comes from theme.choiceColors by
-- priority; the selected segment gets a 14%-alpha wash of its own colour.
-- opts.segW = {w1, w2, ...} (defaults 56 each), opts.h (default 30).
-- API: seg:SetOptions(options), seg:SetSelected(name|nil),
--      seg:SetEnabled(bool), seg:GetSelected(), seg:SetOnPick(fn)
-- onPick(name) fires on click.
------------------------------------------------------------------------
function ns.MakeSegmented(parent, options, onPick, opts)
    opts = opts or {}
    local theme = ns.Theme:GetCurrent()
    local g = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ns.SkinNineSlice(g, "btn")
    g._segments  = {}
    g._dividers  = {}
    g._h         = opts.h or 30
    g._segW      = opts.segW or {}
    g._defaultW  = opts.defaultW or 56
    g._passW     = opts.passW or 52
    g._onPick    = onPick
    g._selected  = nil
    g._enabled   = true
    g._noPass    = opts.noPass

    local function acquireSegment(self, i)
        local s = self._segments[i]
        if s then return s end
        s = CreateFrame("Button", nil, self)
        s:SetHeight(self._h - 2)
        local wash = s:CreateTexture(nil, "BACKGROUND")
        wash:SetTexture(WHITE8x8); wash:SetAllPoints(); wash:Hide()
        s._wash = wash
        local hl = s:CreateTexture(nil, "BORDER")
        hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
        s._hl = hl
        local t = s:CreateFontString(nil, "OVERLAY")
        t:SetFontObject(Ledger.Fonts.OLLFontLabel)
        t:SetPoint("CENTER")
        s._text = t
        s:SetScript("OnEnter", function(b) if self._enabled then b._hl:Show() end end)
        s:SetScript("OnLeave", function(b) b._hl:Hide() end)
        s:SetScript("OnClick", function(b)
            if not self._enabled then return end
            self:SetSelected(b._optName)
            if self._onPick then self._onPick(b._optName) end
        end)
        self._segments[i] = s
        if i > 1 then
            local d = self:CreateTexture(nil, "ARTWORK")
            d:SetTexture(WHITE8x8); d:SetWidth(1)
            self._dividers[i] = d
        end
        return s
    end

    function g:SetOptions(list)
        self._options = {}
        for _, o in ipairs(list or ns.DEFAULT_ROLL_OPTIONS) do
            tinsert(self._options, { name = o.name, priority = o.priority })
        end
        if not self._noPass then tinsert(self._options, { name = "Pass", pass = true }) end

        local x = 1
        for i, opt in ipairs(self._options) do
            local s = acquireSegment(self, i)
            local w = self._segW[i] or (opt.pass and self._passW or self._defaultW)
            s._optName = opt.name
            s._opt     = opt
            s:SetWidth(w)
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", self, "TOPLEFT", x, -1)
            s._text:SetText(ns.Track(opt.name))
            s:Show()
            if i > 1 then
                local d = self._dividers[i]
                d:ClearAllPoints()
                d:SetPoint("TOPLEFT", self, "TOPLEFT", x - 1, -1)
                d:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x - 1, 1)
                d:Show()
            end
            x = x + w
            if i < #self._options then x = x + 1 end
        end
        for i = #self._options + 1, #self._segments do
            self._segments[i]:Hide()
            if self._dividers[i] then self._dividers[i]:Hide() end
        end
        self:SetSize(x + 1, self._h)
        self:ApplyTheme()
    end

    function g:SetSelected(name)
        self._selected = name
        self:ApplyTheme()
    end
    function g:GetSelected() return self._selected end
    function g:SetEnabled(on)
        self._enabled = on and true or false
        self:ApplyTheme()
    end
    function g:SetOnPick(fn) self._onPick = fn end

    function g:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self:SetBackdropBorderColor(unpackColor(self._enabled and th.strokeColor or th.strokeDimColor))
        for i, s in ipairs(self._segments) do
            if s:IsShown() then
                local c = s._opt.pass and th.choicePassColor or ns.Theme:ChoiceColor(s._opt, th)
                local r, gg, b = unpackColor(c)
                local sel = (self._selected ~= nil and s._optName == self._selected)
                if sel then
                    s._wash:SetVertexColor(r, gg, b, 0.14); s._wash:Show()
                    s._text:SetTextColor(r, gg, b, 1)
                else
                    s._wash:Hide()
                    s._text:SetTextColor(r, gg, b, self._enabled and 0.85 or 0.45)
                end
                s._hl:SetVertexColor(unpackColor(th.highlightColor))
                if self._dividers[i] then self._dividers[i]:SetVertexColor(unpackColor(th.strokeColor)) end
            end
        end
    end

    g:SetOptions(options)
    g:ApplyTheme(theme)
    return register(g)
end

------------------------------------------------------------------------
-- ns.MakePill(parent, text, rgb, opts)
-- Outlined pill: 2px-radius edge, optional 16% fill tint.  For stat /
-- armour-type pills.  opts.filled=true tints the fill; opts.h default 16.
-- API: pill:SetText(text), pill:SetColor(rgb, filled)
------------------------------------------------------------------------
function ns.MakePill(parent, text, rgb, opts)
    opts = opts or {}
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetHeight(opts.h or 16)
    ns.SkinNineSlice(p, "pill")
    local t = p:CreateFontString(nil, "OVERLAY")
    t:SetFontObject(Ledger.Fonts.OLLFontLabel)
    t:SetPoint("CENTER", 0, 0)
    p._text = t
    p._rgb, p._filled = rgb, opts.filled
    function p:SetText(txt)
        self._text:SetText(ns.Track(txt))
        self:SetWidth(self._text:GetStringWidth() + 12)
    end
    function p:SetColor(c, filled)
        self._rgb, self._filled = c, filled
        self:ApplyTheme()
    end
    function p:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        local c = self._rgb or th.strokeColor
        local r, g, b = unpackColor(c)
        if self._filled then
            self:SetBackdropColor(r, g, b, 0.16)
            self:SetBackdropBorderColor(r, g, b, 0.50)
            self._text:SetTextColor(r, g, b, 1)
        else
            self:SetBackdropColor(0, 0, 0, 0)
            self:SetBackdropBorderColor(unpackColor(th.strokeColor))
            self._text:SetTextColor(unpackColor(th.textMutedColor))
        end
    end
    p:SetText(text or "")
    p:ApplyTheme()
    return register(p)
end

------------------------------------------------------------------------
-- ns.MakeStatusPill(parent) — the header "● ACTIVE 1H 24M" pill.
-- API: pill:SetStatus(label, detail, rgb)
------------------------------------------------------------------------
function ns.MakeStatusPill(parent)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetHeight(22)
    ns.SkinNineSlice(p, "pill")
    local dot = p:CreateTexture(nil, "OVERLAY")
    dot:SetTexture(Ledger.TEX.dot); dot:SetSize(6, 6); dot:SetPoint("LEFT", 9, 0)
    local label = p:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(Ledger.Fonts.OLLFontLabel); label:SetPoint("LEFT", dot, "RIGHT", 6, 0)
    local detail = p:CreateFontString(nil, "OVERLAY")
    detail:SetFontObject(Ledger.Fonts.OLLFontLabel); detail:SetPoint("LEFT", label, "RIGHT", 6, 0)
    p._dot, p._label, p._detail = dot, label, detail
    function p:SetStatus(lbl, det, rgb)
        self._rgb = rgb
        self._label:SetText(ns.Track(lbl))
        self._detail:SetText(det or "")
        local w = 9 + 6 + 6 + self._label:GetStringWidth() + (det and det ~= "" and (6 + self._detail:GetStringWidth()) or 0) + 9
        self:SetWidth(w)
        self:ApplyTheme()
    end
    function p:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        local r, g, b = unpackColor(self._rgb or th.timerBarFullColor)
        self:SetBackdropColor(r, g, b, 0.10)
        self:SetBackdropBorderColor(r, g, b, 0.28)
        self._dot:SetVertexColor(r, g, b, 1)
        self._label:SetTextColor(r, g, b, 1)
        self._detail:SetTextColor(unpackColor(th.textMutedColor))
    end
    p:ApplyTheme()
    return register(p)
end

------------------------------------------------------------------------
-- ns.MakeHeaderBar(frame, title, tools, opts)
-- Gradient title bar across the top of `frame`.  opts.height (44),
-- opts.noClose, opts.onClose, opts.subtitle.
-- `tools` = list of { label, onClick, tooltip } rendered as 28px text
-- buttons right-aligned before the close button.
-- Returns bar with: .title, .subtitle, .pill (MakeStatusPill, hidden),
-- .tools[i] (buttons), .closeBtn, .rule, and :SetTitle / :SetSubtitle.
-- Anything the frame wants centred/right in the bar can anchor to
-- bar.toolsAnchor (left edge of the tool group).
------------------------------------------------------------------------
function ns.MakeHeaderBar(frame, title, tools, opts)
    opts = opts or {}
    local h = opts.height or 44
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    bar:SetHeight(h)

    local grad = bar:CreateTexture(nil, "BACKGROUND")
    grad:SetTexture(WHITE8x8)
    grad:SetAllPoints()
    bar._grad = grad

    bar.rule = ns.MakeHairline(bar, "dividerColor")
    bar.rule:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    bar.rule:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)

    bar.title = bar:CreateFontString(nil, "OVERLAY")
    bar.title:SetFontObject(Ledger.Fonts.OLLFontTitle)
    bar.title:SetPoint("LEFT", bar, "LEFT", Ledger.INSET - 2, 0)
    bar.title:SetText(ns.Track(title or ""))

    bar.subtitle = bar:CreateFontString(nil, "OVERLAY")
    bar.subtitle:SetFontObject(Ledger.Fonts.OLLFontBodySmall)
    bar.subtitle:SetPoint("LEFT", bar.title, "RIGHT", 10, -1)
    bar.subtitle:SetText(opts.subtitle or "")

    bar.pill = ns.MakeStatusPill(bar)
    bar.pill:SetPoint("LEFT", bar.title, "RIGHT", 12, 0)
    bar.pill:Hide()

    -- right side: close, then tools leftwards
    local anchor
    if not opts.noClose then
        bar.closeBtn = MakeCloseButton(bar, 28)
        bar.closeBtn:SetPoint("RIGHT", bar, "RIGHT", -(Ledger.INSET_CLOSE - 2), 0)
        bar.closeBtn:SetScript("OnClick", function()
            if opts.onClose then opts.onClose() else frame:Hide() end
        end)
        anchor = bar.closeBtn
    end
    bar.tools = {}
    for i = #(tools or {}), 1, -1 do
        local def = tools[i]
        local b = ns.MakeButton(bar, "outline", def.label, nil, 28)
        b:SetWidth(b._text:GetStringWidth() + 24)
        if anchor then b:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
        else b:SetPoint("RIGHT", bar, "RIGHT", -(Ledger.INSET - 2), 0) end
        b:SetScript("OnClick", function() if def.onClick then def.onClick() end end)
        if def.tooltip then
            b:HookScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:SetText(def.tooltip, 1, 1, 1)
                GameTooltip:Show()
            end)
            b:HookScript("OnLeave", GameTooltip_Hide)
        end
        bar.tools[i] = b
        anchor = b
    end
    bar.toolsAnchor = anchor or bar

    function bar:SetTitle(t) self.title:SetText(ns.Track(t)) end
    function bar:SetSubtitle(t) self.subtitle:SetText(t or "") end
    function bar:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self._grad:SetGradient("VERTICAL",
            CreateColor(unpackColor(th.headerBotColor)),
            CreateColor(unpackColor(th.headerTopColor)))
        self.rule:SetVertexColor(unpackColor(th.dividerColor))
        self.title:SetTextColor(unpackColor(th.accentHiColor))
        self.subtitle:SetTextColor(unpackColor(th.textMutedColor))
    end
    bar:ApplyTheme()
    return register(bar)
end

------------------------------------------------------------------------
-- ns.MakeBar(parent, height, colorKey) — a flat strip (action row, award
-- bar, footer) with a top or bottom hairline.  opts.ruleSide "TOP"/"BOTTOM".
------------------------------------------------------------------------
function ns.MakeBar(parent, height, colorKey, ruleSide)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(height)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE8x8); bg:SetAllPoints()
    bar._bg, bar._colorKey = bg, colorKey or "barBgColor"
    bar.rule = ns.MakeHairline(bar, "dividerColor")
    if ruleSide == "TOP" then
        bar.rule:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0); bar.rule:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    else
        bar.rule:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0); bar.rule:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    end
    function bar:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self._bg:SetVertexColor(unpackColor(th[self._colorKey]))
        self.rule:SetVertexColor(unpackColor(th.dividerColor))
    end
    bar:ApplyTheme()
    return register(bar)
end

------------------------------------------------------------------------
-- ns.MakeTimerBar(parent) — the 2px timer track + fill.
-- API: tb:SetProgress(remaining, duration) tints full/mid/low (snap).
------------------------------------------------------------------------
function ns.MakeTimerBar(parent)
    local tb = CreateFrame("StatusBar", nil, parent)
    tb:SetHeight(2)
    tb:SetStatusBarTexture(WHITE8x8)
    tb:SetMinMaxValues(0, 1)
    tb:SetValue(1)
    local bg = tb:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(WHITE8x8); bg:SetAllPoints()
    tb._bg = bg
    tb._state = "full"
    function tb:SetProgress(remaining, duration)
        duration = (duration and duration > 0) and duration or 1
        self:SetMinMaxValues(0, duration)
        self:SetValue(math.max(0, remaining or 0))
        local th = ns.Theme:GetCurrent()
        local st = (remaining or 0) > 10 and "full" or ((remaining or 0) > 5 and "mid" or "low")
        self._state = st
        local c = st == "full" and th.timerBarFullColor or (st == "mid" and th.timerBarMidColor or th.timerBarLowColor)
        self:SetStatusBarColor(unpackColor(c))
    end
    function tb:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self._bg:SetVertexColor(unpackColor(th.timerBarBgColor))
        local c = self._state == "full" and th.timerBarFullColor or (self._state == "mid" and th.timerBarMidColor or th.timerBarLowColor)
        self:SetStatusBarColor(unpackColor(c))
    end
    tb:ApplyTheme()
    return register(tb)
end

------------------------------------------------------------------------
-- ns.MakeItemRow(parent, h)
-- Row: 2px left quality tick, icon, name (quality-coloured, ellipsis),
-- meta sub-line, right slot text, top hairline, hover + selected washes.
-- API: row:SetItem(item, opts) — item {link,name,icon,quality}; opts.meta
--      row:SetRight(text, rgb) / row:SetRightCheck(bool)
--      row:SetSelected(bool), row:SetDimmed(alpha|nil)
--      row.rightSlot is a Frame for custom content (badges, segmented).
-- Pool these exactly like the existing _AcquireItemRow does.
------------------------------------------------------------------------
function ns.MakeItemRow(parent, h, opts)
    opts = opts or {}
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(h or 42)
    local iconSize = opts.iconSize or 28

    local hair = ns.MakeHairline(row, "histSepColor")
    hair:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); hair:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row._hair = hair

    local selBg = row:CreateTexture(nil, "BACKGROUND")
    selBg:SetTexture(WHITE8x8); selBg:SetAllPoints(); selBg:Hide()
    row._selBg = selBg

    local hl = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
    row._hl = hl

    local tick = row:CreateTexture(nil, "ARTWORK")
    tick:SetTexture(WHITE8x8); tick:SetWidth(2)
    tick:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); tick:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row._tick = tick

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("LEFT", row, "LEFT", Ledger.INSET, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.icon = icon
    if opts.noIcon then icon:Hide() end

    local iconEdge = CreateFrame("Frame", nil, row, "BackdropTemplate")
    iconEdge:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    iconEdge:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    ns.SkinNineSlice(iconEdge, "pill")
    row._iconEdge = iconEdge
    if opts.noIcon then iconEdge:Hide() end

    local name = row:CreateFontString(nil, "OVERLAY")
    name:SetFontObject(Ledger.Fonts.OLLFontBody)
    name:SetJustifyH("LEFT"); name:SetWordWrap(false); name:SetMaxLines(1)
    row.name = name

    local meta = row:CreateFontString(nil, "OVERLAY")
    meta:SetFontObject(Ledger.Fonts.OLLFontBodySmall)
    meta:SetJustifyH("LEFT"); meta:SetWordWrap(false); meta:SetMaxLines(1)
    row.meta = meta

    local rightSlot = CreateFrame("Frame", nil, row)
    rightSlot:SetPoint("RIGHT", row, "RIGHT", -Ledger.INSET_CLOSE, 0)
    rightSlot:SetSize(1, h or 42)
    row.rightSlot = rightSlot

    local rightText = rightSlot:CreateFontString(nil, "OVERLAY")
    rightText:SetFontObject(Ledger.Fonts.OLLFontLabel)
    rightText:SetPoint("RIGHT", rightSlot, "RIGHT", 0, 0)
    row.rightText = rightText

    local check = rightSlot:CreateTexture(nil, "OVERLAY")
    check:SetSize(14, 14); check:SetPoint("RIGHT", rightSlot, "RIGHT", 0, 0)
    -- SetAtlas returns nothing; ask the atlas registry instead.
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("common-icon-checkmark") then
        check:SetAtlas("common-icon-checkmark")
    else
        check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    end
    check:Hide()
    row.check = check

    local function layoutText(self)
        local left = self.icon:IsShown() and (Ledger.INSET + iconSize + 10) or Ledger.INSET
        self.name:ClearAllPoints(); self.meta:ClearAllPoints()
        if self.meta:GetText() and self.meta:GetText() ~= "" then
            self.name:SetPoint("TOPLEFT", self, "TOPLEFT", left, -(math.floor((self:GetHeight() - 30) / 2)))
            self.meta:SetPoint("TOPLEFT", self.name, "BOTTOMLEFT", 0, -3)
            self.meta:SetPoint("RIGHT", self.rightSlot, "LEFT", -8, 0)
        else
            self.name:SetPoint("LEFT", self, "LEFT", left, 0)
        end
        self.name:SetPoint("RIGHT", self.rightSlot, "LEFT", -8, 0)
    end

    function row:SetItem(item, o)
        o = o or {}
        item = item or {}
        local q = item.quality or 1
        local qc = Ledger.QualityColor(q)
        self._quality = q
        self.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        self._iconEdge:SetBackdropBorderColor(qc[1], qc[2], qc[3], 0.6)
        self.name:SetText(item.name or (item.link and item.link:match("%[(.-)%]")) or "Unknown")
        self.name:SetTextColor(qc[1], qc[2], qc[3])
        self.meta:SetText(o.meta or "")
        self._link = item.link
        layoutText(self)
        self:ApplyTheme()
    end
    function row:SetRight(text, rgb)
        self.check:Hide()
        self.rightText:SetText(text or "")
        if rgb then self.rightText:SetTextColor(unpackColor(rgb))
        else self.rightText:SetTextColor(unpackColor(ns.Theme:GetCurrent().textDimColor)) end
        self.rightSlot:SetWidth(math.max(1, self.rightText:GetStringWidth()))
        self.rightText:Show()
    end
    function row:SetRightCheck(on)
        self.rightText:Hide()
        if on then
            self.check:SetVertexColor(unpackColor(ns.Theme:GetCurrent().timerBarFullColor))
            self.check:Show(); self.rightSlot:SetWidth(14)
        else
            self.check:Hide()
        end
    end
    function row:SetSelected(on)
        self._selected = on and true or false
        self:ApplyTheme()
    end
    function row:SetDimmed(alpha) self:SetAlpha(alpha or 1) end

    function row:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        self._hair:SetVertexColor(unpackColor(th.histSepColor))
        self._hl:SetVertexColor(unpackColor(th.highlightColor))
        if self._selected then
            self._selBg:SetVertexColor(unpackColor(th.rowBgColor)); self._selBg:Show()
            self._tick:SetVertexColor(unpackColor(th.accentColor)); self._tick:Show()
        else
            self._selBg:Hide()
            local qc = Ledger.QualityColor(self._quality or 1)
            self._tick:SetVertexColor(qc[1], qc[2], qc[3], 0.9)
            self._tick:SetShown(not opts.noQualityTick)
        end
        self.meta:SetTextColor(unpackColor(th.textMutedColor))
    end

    row:SetScript("OnEnter", function(self) self._hl:Show() end)
    row:SetScript("OnLeave", function(self) self._hl:Hide() end)
    row:ApplyTheme()
    return register(row)
end

------------------------------------------------------------------------
-- ns.MakeTable(parent, columns, opts)
-- columns: list of { key, label, width, justify }
--   width: number (px) or "1fr" (shares leftover width; several allowed)
--   justify: "LEFT" (default) | "RIGHT" | "CENTER"
-- Renders a 24px header row + hairline, then pooled 26px data rows.
-- Right-aligned columns get Ledger.NUM_PAD trailing padding; columns are
-- separated by Ledger.GUTTER.  Widths re-resolve on OnSizeChanged.
-- API:
--   tbl:AcquireRow() -> row with row.cells[key] (FontString) and
--                       row.dots[key] (5px dot texture, hidden) and
--                       row:SetSelected(bool); rows anchor themselves
--                       below the previous acquired row.
--   tbl:ReleaseRows()   hide all rows, reset cursor
--   tbl:SetSortIndicator(key|nil)  accent colour + ▼ on that header
--   tbl:GetContentHeight()
--   tbl.header (Frame), tbl.body (Frame, anchor rows/other content here)
------------------------------------------------------------------------
function ns.MakeTable(parent, columns, opts)
    opts = opts or {}
    local t = CreateFrame("Frame", nil, parent)
    t._cols     = columns
    t._rowH     = opts.rowH or 26
    t._hdrH     = opts.headerH or 24
    t._inset    = opts.inset or Ledger.INSET
    t._rows     = {}
    t._used     = 0
    t._sortKey  = nil

    t.header = CreateFrame("Frame", nil, t)
    t.header:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
    t.header:SetPoint("TOPRIGHT", t, "TOPRIGHT", 0, 0)
    t.header:SetHeight(t._hdrH)
    t.header.labels = {}
    for _, col in ipairs(columns) do
        local fs = t.header:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject(Ledger.Fonts.OLLFontLabel)
        fs:SetJustifyH(col.justify or "LEFT")
        fs:SetWordWrap(false)
        fs:SetText(ns.Track(col.label or col.key))
        t.header.labels[col.key] = fs
    end
    t.header.rule = ns.MakeHairline(t.header, "dividerColor")
    t.header.rule:SetPoint("BOTTOMLEFT", t.header, "BOTTOMLEFT", 0, 0)
    t.header.rule:SetPoint("BOTTOMRIGHT", t.header, "BOTTOMRIGHT", 0, 0)
    if opts.noHeader then t.header:Hide(); t.header:SetHeight(0.001) end

    t.body = CreateFrame("Frame", nil, t)
    t.body:SetPoint("TOPLEFT", t.header, "BOTTOMLEFT", 0, 0)
    t.body:SetPoint("TOPRIGHT", t.header, "BOTTOMRIGHT", 0, 0)
    t.body:SetHeight(1)

    -- Resolve column x/width from the current frame width
    function t:_Resolve()
        local total = self:GetWidth()
        if not total or total <= 0 then return end
        local avail = total - self._inset * 2 - Ledger.GUTTER * (#self._cols - 1)
        local fixed, flex = 0, 0
        for _, c in ipairs(self._cols) do
            if c.width == "1fr" then flex = flex + 1 else fixed = fixed + (tonumber(c.width) or 0) end
        end
        local flexW = flex > 0 and math.max(40, (avail - fixed) / flex) or 0
        local x = self._inset
        self._layout = {}
        for _, c in ipairs(self._cols) do
            local w = (c.width == "1fr") and flexW or c.width
            self._layout[c.key] = { x = x, w = w }
            x = x + w + Ledger.GUTTER
        end
    end

    local function placeCell(self, fs, col, parentFrame)
        local L = self._layout and self._layout[col.key]
        if not L then return end
        fs:ClearAllPoints()
        local pad = (col.justify == "RIGHT") and Ledger.NUM_PAD or 0
        fs:SetPoint("LEFT",  parentFrame, "LEFT", L.x, 0)
        fs:SetWidth(math.max(1, L.w - pad))
        fs:SetJustifyH(col.justify or "LEFT")
    end

    function t:Layout()
        self:_Resolve()
        if not self._layout then return end
        for _, col in ipairs(self._cols) do
            placeCell(self, self.header.labels[col.key], col, self.header)
        end
        for _, row in ipairs(self._rows) do
            for _, col in ipairs(self._cols) do
                placeCell(self, row.cells[col.key], col, row)
                local d = row.dots[col.key]
                if d then
                    d:ClearAllPoints()
                    d:SetPoint("RIGHT", row.cells[col.key], "LEFT", -6, 0)
                end
            end
        end
    end

    function t:AcquireRow()
        self._used = self._used + 1
        local row = self._rows[self._used]
        if not row then
            row = CreateFrame("Button", nil, self.body)
            row:SetHeight(self._rowH)
            row.cells, row.dots = {}, {}
            local hair = ns.MakeHairline(row, "histSepColor")
            hair:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); hair:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
            row._hair = hair
            local sel = row:CreateTexture(nil, "BACKGROUND"); sel:SetTexture(WHITE8x8); sel:SetAllPoints(); sel:Hide()
            row._sel = sel
            local tick = row:CreateTexture(nil, "ARTWORK"); tick:SetTexture(WHITE8x8); tick:SetWidth(2)
            tick:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); tick:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0); tick:Hide()
            row._tick = tick
            local hl = row:CreateTexture(nil, "BACKGROUND", nil, 1); hl:SetTexture(WHITE8x8); hl:SetAllPoints(); hl:Hide()
            row._hl = hl
            for _, col in ipairs(self._cols) do
                local fs = row:CreateFontString(nil, "OVERLAY")
                fs:SetFontObject(Ledger.Fonts.OLLFontBody)
                fs:SetWordWrap(false); fs:SetMaxLines(1)
                row.cells[col.key] = fs
                if col.dot then
                    local d = row:CreateTexture(nil, "OVERLAY")
                    d:SetTexture(Ledger.TEX.dot); d:SetSize(5, 5); d:Hide()
                    row.dots[col.key] = d
                end
            end
            row:SetScript("OnEnter", function(r) r._hl:Show() end)
            row:SetScript("OnLeave", function(r) r._hl:Hide() end)
            function row:SetSelected(on)
                local th = ns.Theme:GetCurrent()
                if on then
                    self._sel:SetVertexColor(unpackColor(th.selectedColor)); self._sel:Show()
                    self._tick:SetVertexColor(unpackColor(th.accentColor)); self._tick:Show()
                else
                    self._sel:Hide(); self._tick:Hide()
                end
            end
            function row:SetCell(key, text, rgb)
                local fs = self.cells[key]
                if not fs then return end
                fs:SetText(text or "")
                fs:SetTextColor(unpackColor(rgb or ns.Theme:GetCurrent().textColor))
                local d = self.dots[key]
                if d then
                    if rgb and text and text ~= "" then d:SetVertexColor(unpackColor(rgb)); d:Show() else d:Hide() end
                end
            end
            self._rows[self._used] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self.body, "TOPLEFT", 0, -((self._used - 1) * self._rowH))
        row:SetPoint("TOPRIGHT", self.body, "TOPRIGHT", 0, -((self._used - 1) * self._rowH))
        row:SetAlpha(1)
        row:SetSelected(false)
        row._hl:Hide()
        for key, fs in pairs(row.cells) do fs:SetText(""); if row.dots[key] then row.dots[key]:Hide() end end
        row:Show()
        for _, col in ipairs(self._cols) do
            placeCell(self, row.cells[col.key], col, row)
            local d = row.dots[col.key]
            if d then d:ClearAllPoints(); d:SetPoint("RIGHT", row.cells[col.key], "LEFT", -6, 0) end
        end
        self.body:SetHeight(math.max(1, self._used * self._rowH))
        return row
    end

    function t:ReleaseRows()
        for _, row in ipairs(self._rows) do row:Hide() end
        self._used = 0
        self.body:SetHeight(1)
    end

    function t:GetContentHeight()
        return (self.header:IsShown() and self._hdrH or 0) + self._used * self._rowH
    end

    function t:SetSortIndicator(key)
        self._sortKey = key
        self:ApplyTheme()
    end

    function t:ApplyTheme(th)
        th = th or ns.Theme:GetCurrent()
        local hex = th.columnHeaderHex or "8b909b"
        local r, g, b = tonumber(hex:sub(1, 2), 16) / 255,
                        tonumber(hex:sub(3, 4), 16) / 255,
                        tonumber(hex:sub(5, 6), 16) / 255
        for _, col in ipairs(self._cols) do
            local fs = self.header.labels[col.key]
            if self._sortKey == col.key then
                fs:SetText(ns.Track(col.label or col.key) .. " |TInterface\\Buttons\\Arrow-Down-Up:8:8|t")
                fs:SetTextColor(unpackColor(th.accentColor))
            else
                fs:SetText(ns.Track(col.label or col.key))
                fs:SetTextColor(r, g, b)
            end
        end
        self.header.rule:SetVertexColor(unpackColor(th.dividerColor))
        for _, row in ipairs(self._rows) do
            row._hair:SetVertexColor(unpackColor(th.histSepColor))
            row._hl:SetVertexColor(unpackColor(th.highlightColor))
        end
    end

    t:SetScript("OnSizeChanged", function(self) self:Layout() end)
    t:ApplyTheme()
    return register(t)
end

------------------------------------------------------------------------
-- Motion (AnimationGroup only; nothing loops)
------------------------------------------------------------------------
-- Frame shown: alpha 0 -> 1 over 120ms
function Ledger.AttachFadeIn(frame, duration)
    if frame._fadeIn then return end
    local ag = frame:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0); a:SetToAlpha(1); a:SetDuration(duration or 0.12)
    frame._fadeIn = ag
    frame:HookScript("OnShow", function(f) f._fadeIn:Stop(); f._fadeIn:Play() end)
end

-- One-shot glow pulse on a texture (award primary when a winner resolves)
function Ledger.PulseOnce(texture, duration)
    if not texture._pulse then
        local ag = texture:CreateAnimationGroup()
        local up = ag:CreateAnimation("Alpha")
        up:SetFromAlpha(0); up:SetToAlpha(0.6); up:SetDuration((duration or 0.3) / 2); up:SetOrder(1)
        local dn = ag:CreateAnimation("Alpha")
        dn:SetFromAlpha(0.6); dn:SetToAlpha(0); dn:SetDuration((duration or 0.3) / 2); dn:SetOrder(2)
        ag:SetScript("OnFinished", function() texture:SetAlpha(0) end)
        texture._pulse = ag
    end
    texture:SetAlpha(0)
    texture._pulse:Stop()
    texture._pulse:Play()
end

-- Cross-fade a fontstring's text change (roster choice cell)
function Ledger.CrossFadeText(fs, newText, rgb, duration)
    if not fs._xfade then
        local ag = fs:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0.2); a:SetToAlpha(1); a:SetDuration(duration or 0.1)
        fs._xfade = ag
    end
    fs:SetText(newText or "")
    if rgb then fs:SetTextColor(unpackColor(rgb)) end
    fs._xfade:Stop(); fs._xfade:Play()
end

-- Initial colour pass for fonts at load (db may not exist yet; Theme falls back)
Ledger.ApplyTheme(ns.Theme:GetCurrent())
