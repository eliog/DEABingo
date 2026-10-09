--[[
  The chip: the one-line state the addon lives in during a raid. Title,
  "14/24", "1 away" and a 5x5 dot grid of the player's board. Click opens
  the window. Movable. Shown only while in an open game.
]]

local _, ns = ...
local Logic, Theme, W, Window = ns.Logic, ns.Theme, ns.W, ns.Window

local Chip = {}
ns.Chip = Chip

local chip
local app

function Chip.init(callbacks)
  app = callbacks
  if chip then return chip end
  chip = CreateFrame("Button", "DEABingoChip", UIParent)
  chip:SetFrameStrata("MEDIUM")
  chip:SetSize(230, 34)
  chip.bg = W.rect(chip, "scrim"); chip.bg:SetAllPoints()
  chip.border = W.border(chip, "lineStrong")
  chip.accent = chip:CreateTexture(nil, "ARTWORK"); Theme.register(chip.accent, "fel", "bg")
  chip.accent:SetPoint("TOPLEFT"); chip.accent:SetPoint("BOTTOMLEFT"); chip.accent:SetWidth(W.px(3))

  chip.title = W.text(chip, W.fonts().eyebrow, "inkDim")
  chip.title:SetPoint("LEFT", 10, 6)
  chip.title:SetWidth(120)
  chip.title:SetWordWrap(false)
  chip.count = W.text(chip, W.fonts().bodyBold, "ink")
  chip.count:SetPoint("LEFT", 10, -7)
  chip.away = W.text(chip, W.fonts().small, "gold")
  chip.away:SetPoint("LEFT", chip.count, "RIGHT", 8, 0)

  chip.grid = W.dotGrid(chip, 5, 1)
  chip.grid:SetPoint("RIGHT", -8, 0)
  chip.dots = chip.grid.dots

  chip.flash = chip:CreateTexture(nil, "OVERLAY")
  chip.flash:SetAllPoints()
  chip.flash:SetColorTexture(0.56, 0.85, 0.29, 0)
  chip.flashAlpha = 0

  W.draggable(chip, app.savePosition)
  W.restorePosition(chip, app.position(), { point = "TOP", y = -40 })   -- above the raid-warning area
  chip:SetScript("OnDragStart", function(self) if not self.locked then self:StartMoving() end end)
  chip:SetScript("OnClick", function() Window.toggle() end)
  W.tooltip(chip, function()
    return { "DEA Bingo", "Click to open the board. Drag to move." }
  end)
  chip:SetScript("OnUpdate", function(self, elapsed)
    if self.flashAlpha > 0 then
      self.flashAlpha = math.max(0, self.flashAlpha - elapsed * 1.6)
      self.flash:SetColorTexture(0.56, 0.85, 0.29, self.flashAlpha * 0.35)
    end
  end)
  chip:Hide()
  return chip
end

function Chip.flash()
  if chip and not chip.reducedMotion then chip.flashAlpha = 1 end
end

function Chip.applyOptions(o)
  if not chip then return end
  chip.locked = o.chipLocked == true
  chip.hidden = o.chipHidden == true
  chip.reducedMotion = o.reducedMotion == true
  -- redraw from the last state so un-hiding brings it straight back
  Chip.update(chip.lastView)
end

-- v is the view model, or nil to hide.
function Chip.update(v)
  if not chip then return end
  chip.lastView = v
  if chip.hidden or not v or v.state ~= "open" or not v.board then chip:Hide(); return end
  chip:Show()
  chip.title:SetText(Logic.escape(v.title):upper())
  chip.count:SetText(("%d/24"):format(v.callCount))
  if v.hasBingo then
    chip.away:SetText("BINGO"); Theme.set(chip.away, "fel")
  else
    chip.away:SetText(v.away == 1 and "1 away" or (v.away .. " away")); Theme.set(chip.away, v.away == 1 and "gold" or "inkDim")
  end
  chip.grid:Paint(v.board, v.called, v.winning)
  Theme.set(chip.accent, v.hostAway and "inkFaint" or "fel")
end
