--[[
  Toasts: small cards that stack near the top of the screen, never in the
  centre, each with a line of text, an optional action, and a dismiss.
  They time out on their own. Nothing here plays sounds or steals focus;
  the caller decides whether a toast is appropriate right now.

    Toast.show({ text = "...", sub = "...", action = { label = "Join", fn = function() end }, ttl = 20 })
]]

local _, ns = ...
local Theme, W = ns.Theme, ns.W

local Toast = {}
ns.Toast = Toast

Toast.MAX = 3
Toast.WIDTH = 340
Toast.HEIGHT = 58
Toast.GAP = 6

local pool, live = {}, {}
local anchor
local app   -- savePosition(pos), position()

local function layout()
  for i, t in ipairs(live) do
    t:ClearAllPoints()
    t:SetPoint("TOP", anchor, "TOP", 0, -(i - 1) * (Toast.HEIGHT + Toast.GAP))
  end
end

local function dismiss(t)
  for i, x in ipairs(live) do if x == t then table.remove(live, i); break end end
  t:Hide()
  pool[#pool + 1] = t
  layout()
end

local function newToast()
  local t = CreateFrame("Frame", nil, UIParent)
  t:SetSize(Toast.WIDTH, Toast.HEIGHT)
  t:SetFrameStrata("HIGH")
  t.bg = W.rect(t, "scrim"); t.bg:SetAllPoints()
  t.border = W.border(t, "lineStrong")
  t.accent = t:CreateTexture(nil, "ARTWORK"); Theme.register(t.accent, "fel", "bg")
  t.accent:SetPoint("TOPLEFT"); t.accent:SetPoint("BOTTOMLEFT"); t.accent:SetWidth(W.px(3))
  t.text = W.text(t, W.fonts().bodyBold, "ink"); t.text:SetPoint("TOPLEFT", 12, -10); t.text:SetPoint("RIGHT", -120, 0)
  t.text:SetWordWrap(false)
  t.sub = W.text(t, W.fonts().small, "inkDim"); t.sub:SetPoint("BOTTOMLEFT", 12, 10); t.sub:SetPoint("RIGHT", -120, 0)
  t.sub:SetWordWrap(false)
  t.action = W.button(t, "", function(self) if t.onAction then t.onAction() end; dismiss(t) end, { width = 80, height = 26, primary = true })
  t.action:SetPoint("RIGHT", -34, 0)
  t.close = W.closeButton(t, function() dismiss(t) end)
  t.close:SetPoint("RIGHT", -4, 0)
  -- Dragging any toast moves the stack: the anchor follows the toast's
  -- top edge, offset by its place in the stack, and the spot is remembered.
  t:SetMovable(true)
  t:EnableMouse(true)
  t:RegisterForDrag("LeftButton")
  t:SetScript("OnDragStart", function(self) self:StartMoving() end)
  t:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local index = 1
    for i, x in ipairs(live) do if x == self then index = i end end
    local cx = self:GetCenter()
    local top = self:GetTop()
    if cx and top then
      local scale = anchor:GetEffectiveScale()
      local pos = { point = "TOP", relPoint = "BOTTOMLEFT", x = cx, y = top + (index - 1) * (Toast.HEIGHT + Toast.GAP) }
      anchor:ClearAllPoints()
      anchor:SetPoint("TOP", UIParent, "BOTTOMLEFT", pos.x, pos.y)
      if app and app.savePosition then app.savePosition(pos) end
    end
    layout()
  end)
  t:SetScript("OnUpdate", function(self, elapsed)
    self.ttl = self.ttl - elapsed
    if self.ttl <= 0 then dismiss(self) end
    if self.ttl < 1 then self:SetAlpha(math.max(0, self.ttl)) end
  end)
  return t
end

-- Default: low centre, above the action bars, clear of the raid-warning
-- and error text that Blizzard puts near the top.
function Toast.init(callbacks)
  app = callbacks
  if anchor then return end
  anchor = CreateFrame("Frame", "DEABingoToasts", UIParent)
  anchor:SetSize(Toast.WIDTH, 1)
  W.restorePosition(anchor, app and app.position and app.position(), { point = "BOTTOM", y = 230 })
end

function Toast.show(opts)
  if not anchor then return end
  while #live >= Toast.MAX do dismiss(live[1]) end
  local t = table.remove(pool) or newToast()
  t.text:SetText(opts.text or "")
  t.sub:SetText(opts.sub or "")
  Theme.set(t.accent, opts.accent or "fel")
  if opts.action then
    t.action:Show()
    t.action:SetLabel(opts.action.label)
    t.onAction = opts.action.fn
    t.text:SetPoint("RIGHT", -120, 0); t.sub:SetPoint("RIGHT", -120, 0)
  else
    t.action:Hide()
    t.onAction = nil
    t.text:SetPoint("RIGHT", -34, 0); t.sub:SetPoint("RIGHT", -34, 0)
  end
  t.ttl = opts.ttl or 12
  t:SetAlpha(1)
  live[#live + 1] = t
  layout()
  t:Show()
  return t
end

function Toast.clear()
  while #live > 0 do dismiss(live[1]) end
end
