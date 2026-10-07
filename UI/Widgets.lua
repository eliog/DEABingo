--[[
  Small building blocks shared by every window: pixel-exact hairlines,
  themed rectangles and borders, fonts with fallbacks, flat buttons, panels.
  Everything is colour textures; no Blizzard art.
]]

local ADDON, ns = ...
local Theme = ns.Theme

local W = {}
ns.W = W

------------------------------------------------------------------- pixels

-- Multiplier that turns "1 pixel" into UI units at the current scale.
W.PX = 1
function W.updatePixel()
  local okay, _, h = pcall(GetPhysicalScreenSize)
  if okay and h and h > 0 then
    W.PX = 768 / h / UIParent:GetEffectiveScale()
  end
end

function W.px(n) return (n or 1) * W.PX end

-------------------------------------------------------------------- fonts

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Fonts\\"
local LATIN = { enUS = true, enGB = true, deDE = true, frFR = true, esES = true, esMX = true, itIT = true, ptBR = true }

-- The client has no glyph fallback: a Cyrillic or CJK client gets Blizzard's
-- fonts for everything, so no text ever renders as boxes.
local function useShipped()
  local okay, locale = pcall(GetLocale)
  return okay and LATIN[locale] == true
end

W.fontPaths = {
  heading = useShipped() and (MEDIA .. "Cinzel-Bold.ttf") or STANDARD_TEXT_FONT,
  body = useShipped() and (MEDIA .. "AlegreyaSans-Regular.ttf") or STANDARD_TEXT_FONT,
  bodyBold = useShipped() and (MEDIA .. "AlegreyaSans-Bold.ttf") or STANDARD_TEXT_FONT,
}

-- SetFont returns false when the file is not loadable (missing, or added
-- since the client started); fall back rather than render nothing.
function W.setFont(fs, which, size, flags)
  local okay = fs:SetFont(W.fontPaths[which] or STANDARD_TEXT_FONT, size, flags or "")
  if not okay then
    W.fontPaths[which] = STANDARD_TEXT_FONT
    fs:SetFont(STANDARD_TEXT_FONT, size, flags or "")
  end
end

local fontObjects = {}
local function fontObject(name, which, size, flags)
  if fontObjects[name] then return fontObjects[name] end
  local f = CreateFont("DEABingo" .. name)
  local okay = f:SetFont(W.fontPaths[which], size, flags or "")
  if not okay then f:SetFont(STANDARD_TEXT_FONT, size, flags or "") end
  fontObjects[name] = f
  return f
end

function W.fonts()
  return {
    heading = fontObject("Heading", "heading", 18),
    title = fontObject("Title", "heading", 15),
    eyebrow = fontObject("Eyebrow", "heading", 10),
    body = fontObject("Body", "body", 13),
    bodyBold = fontObject("BodyBold", "bodyBold", 13),
    small = fontObject("Small", "body", 11.5),
    big = fontObject("Big", "heading", 26),
    phrase = fontObject("Phrase", "body", 18),
  }
end

-------------------------------------------------------------- primitives

function W.rect(parent, role, layer, alpha)
  local t = parent:CreateTexture(nil, layer or "BACKGROUND")
  Theme.register(t, role, "bg", alpha)
  return t
end

-- Four hairlines around a frame. Returns a table so a state change can
-- recolour them with W.borderRole.
function W.border(frame, role, thickness)
  local px = W.px(thickness or 1)
  local b = {}
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local t = frame:CreateTexture(nil, "BORDER")
    Theme.register(t, role, "bg")
    if side == "TOP" or side == "BOTTOM" then
      t:SetPoint(side .. "LEFT"); t:SetPoint(side .. "RIGHT"); t:SetHeight(px)
    else
      t:SetPoint("TOP" .. side); t:SetPoint("BOTTOM" .. side); t:SetWidth(px)
    end
    t:SetSnapToPixelGrid(true)
    t:SetTexelSnappingBias(1)
    b[#b + 1] = t
  end
  return b
end

function W.borderRole(border, role)
  for _, t in ipairs(border) do Theme.set(t, role) end
end

function W.text(parent, font, role, justifyH, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  fs:SetFontObject(font)
  fs:SetJustifyH(justifyH or "LEFT")
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.55)
  Theme.register(fs, role or "ink", "text")
  return fs
end

function W.panel(parent, role)
  local f = CreateFrame("Frame", nil, parent)
  f.bg = W.rect(f, role or "surface")
  f.bg:SetAllPoints()
  f.border = W.border(f, "line")
  return f
end

-- Flat button in the web app's style. opts.primary gives the fel fill.
function W.button(parent, label, onClick, opts)
  opts = opts or {}
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(opts.width or 120, opts.height or 28)
  b.face = W.rect(b, opts.primary and "fel" or "raised")
  b.face:SetAllPoints()
  b.border = W.border(b, opts.primary and "fel" or "lineStrong")
  b.label = W.text(b, opts.font or W.fonts().bodyBold, opts.primary and "felInk" or "ink", "CENTER")
  b.label:SetPoint("CENTER", 0, 0)
  b.label:SetText(label)
  b:SetScript("OnEnter", function(self)
    if self.disabled then return end
    Theme.set(self.face, opts.primary and "fel" or "surface")
    W.borderRole(self.border, opts.primary and "ink" or "gold")
  end)
  b:SetScript("OnLeave", function(self)
    Theme.set(self.face, opts.primary and "fel" or "raised")
    W.borderRole(self.border, opts.primary and "fel" or "lineStrong")
  end)
  b:SetScript("OnClick", function(self, button) if not self.disabled and onClick then onClick(self, button) end end)
  function b:SetLabel(text) self.label:SetText(text) end
  function b:SetEnabledState(on)
    self.disabled = not on
    self:SetAlpha(on and 1 or 0.45)
  end
  return b
end

-- A small square "X" close button drawn with two hairlines.
function W.closeButton(parent, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(22, 22)
  local a = b:CreateTexture(nil, "ARTWORK"); Theme.register(a, "inkDim", "bg")
  local c = b:CreateTexture(nil, "ARTWORK"); Theme.register(c, "inkDim", "bg")
  a:SetSize(14, W.px(2)); c:SetSize(14, W.px(2))
  a:SetPoint("CENTER"); c:SetPoint("CENTER")
  a:SetRotation(math.rad(45)); c:SetRotation(math.rad(-45))
  b:SetScript("OnEnter", function() Theme.set(a, "ink"); Theme.set(c, "ink") end)
  b:SetScript("OnLeave", function() Theme.set(a, "inkDim"); Theme.set(c, "inkDim") end)
  b:SetScript("OnClick", onClick)
  return b
end

-- A one-line edit box with the flat look.
function W.editBox(parent, width, font)
  local e = CreateFrame("EditBox", nil, parent)
  e:SetSize(width or 200, 26)
  e:SetAutoFocus(false)
  e:SetFontObject(font or W.fonts().body)
  e:SetTextInsets(8, 8, 0, 0)
  e.bg = W.rect(e, "sunk"); e.bg:SetAllPoints()
  e.border = W.border(e, "line")
  Theme.register(e, "ink", "text")
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEditFocusGained", function(self) W.borderRole(self.border, "gold") end)
  e:SetScript("OnEditFocusLost", function(self) W.borderRole(self.border, "line") end)
  return e
end

-- Five-dot meter for bestLine. Returns a frame with :Set(n, winner).
function W.meter(parent)
  local f = CreateFrame("Frame", nil, parent)
  local size = 7
  f:SetSize(size * 5 + 4 * 3, size)
  f.dots = {}
  for i = 1, 5 do
    local d = f:CreateTexture(nil, "ARTWORK")
    d:SetSize(size, size)
    d:SetPoint("LEFT", (i - 1) * (size + 3), 0)
    Theme.register(d, "line", "bg")
    f.dots[i] = d
  end
  function f:Set(n, winner)
    for i = 1, 5 do Theme.set(self.dots[i], i <= n and (winner and "fel" or (n >= 4 and "gold" or "inkDim")) or "line") end
  end
  return f
end

-- Make a frame draggable and remember where it lands.
function W.draggable(frame, save)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if save then
      local point, _, relPoint, x, y = self:GetPoint(1)
      save({ point = point, relPoint = relPoint, x = x, y = y, w = self:GetWidth(), h = self:GetHeight() })
    end
  end)
end

function W.restorePosition(frame, pos, default)
  frame:ClearAllPoints()
  if pos and pos.point then
    frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    if pos.w and pos.h and frame:IsResizable() then frame:SetSize(pos.w, pos.h) end
  else
    frame:SetPoint(default.point or "CENTER", UIParent, default.point or "CENTER", default.x or 0, default.y or 0)
  end
end

-- Hover tooltip with wrapped text.
function W.tooltip(frame, build)
  frame:SetScript("OnEnter", function(self)
    local lines = build(self)
    if not lines then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(lines[1] or "", 0.91, 0.87, 0.78, 1, true)
    for i = 2, #lines do GameTooltip:AddLine(lines[i], 0.64, 0.58, 0.67, true) end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Short clock from a server timestamp.
function W.clock(t)
  if not t then return "" end
  return date("%H:%M", t)
end
