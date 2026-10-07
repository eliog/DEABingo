--[[
  The 5x5 board: pooled cell buttons, one fitted font size across the grid,
  called and winning states that carry three signals each, the free centre
  drawn as our own chamfered-stone glyph in colour textures.

    local board = Board.new(parent)
    board.onCellClick = function(idx, button) ... end   -- idx 0..23, nil for the centre
    board:SetView(view)       -- items, board, called, winning from Core/View
    board:Layout()            -- on size change
]]

local _, ns = ...
local Logic, Theme, W = ns.Logic, ns.Theme, ns.W

local Board = {}
Board.__index = Board
ns.Board = Board

Board.GAP = 4
Board.MIN_FONT = 9.5
Board.MAX_FONT = 15
Board.INSET = 7

local ruler   -- hidden FontString used to measure text

local function measureFits(items, size, width, height)
  ruler:SetWidth(width - Board.INSET * 2)
  W.setFont(ruler, "body", size, "")
  for _, item in ipairs(items) do
    ruler:SetText(Logic.escape(item))
    if ruler:GetStringHeight() > height - Board.INSET * 2 then return false end
  end
  return true
end

-- The largest size at which every item fits a cell of these dimensions.
local function fitSize(items, width, height)
  local lo, hi = Board.MIN_FONT, Board.MAX_FONT
  if not measureFits(items, lo, width, height) then return nil end
  while hi - lo > 0.5 do
    local mid = (lo + hi) / 2
    if measureFits(items, mid, width, height) then lo = mid else hi = mid end
  end
  return lo
end

------------------------------------------------------------------- cells

local function newCell(board, position)
  local c = CreateFrame("Button", nil, board.frame)
  c.position = position
  c:RegisterForClicks("AnyUp")

  c.face = W.rect(c, "raised"); c.face:SetAllPoints()
  c.sheen = c:CreateTexture(nil, "BACKGROUND", nil, 1)
  c.sheen:SetAllPoints()
  c.sheen:SetColorTexture(1, 1, 1, 1)
  c.sheen:SetGradient("VERTICAL", CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 0.05))
  c.border = W.border(c, "line")
  c.topbar = c:CreateTexture(nil, "ARTWORK")
  Theme.register(c.topbar, "fel", "bg")
  c.topbar:SetPoint("TOPLEFT", W.px(1), -W.px(1)); c.topbar:SetPoint("TOPRIGHT", -W.px(1), -W.px(1))
  c.topbar:SetHeight(W.px(2))
  c.topbar:Hide()

  c.text = c:CreateFontString(nil, "OVERLAY")
  c.text:SetFontObject(W.fonts().body)   -- a font before any SetText, or the client errors
  c.text:SetPoint("TOPLEFT", Board.INSET, -Board.INSET)
  c.text:SetPoint("BOTTOMRIGHT", -Board.INSET, Board.INSET)
  c.text:SetJustifyH("CENTER"); c.text:SetJustifyV("MIDDLE")
  c.text:SetWordWrap(true); c.text:SetNonSpaceWrap(true)
  c.text:SetShadowOffset(1, -1); c.text:SetShadowColor(0, 0, 0, 0.5)
  Theme.register(c.text, "ink", "text")

  c.strike = c:CreateTexture(nil, "OVERLAY", nil, 2)
  Theme.register(c.strike, "fel", "bg")
  c.strike:SetHeight(W.px(1))
  c.strike:SetPoint("LEFT", Board.INSET + 2, 0); c.strike:SetPoint("RIGHT", -(Board.INSET + 2), 0)
  c.strike:Hide()

  -- The third signal of a called square: a small diamond in the corner.
  -- A texture, not a glyph: the shipped fonts have no check mark.
  c.check = W.diamond(c, 9, "fel", "OVERLAY")
  c.check:SetPoint("BOTTOMRIGHT", -5, 5)
  c.check:Hide()

  c:SetScript("OnEnter", function(self)
    if not self.called then W.borderRole(self.border, "lineStrong") end
    local v = board.view
    if v and self.item ~= nil and v.items then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(Logic.escape(v.items[self.item + 1] or ""), 0.91, 0.87, 0.78, 1, true)
      if self.called then
        local when
        for _, call in ipairs(v.calls) do if call.idx == self.item then when = call.t end end
        GameTooltip:AddLine("Called at " .. W.clock(when), 0.56, 0.85, 0.29)
      elseif v.canCall then
        GameTooltip:AddLine("Ctrl-click to call", 0.64, 0.58, 0.67)
      end
      GameTooltip:Show()
    end
  end)
  c:SetScript("OnLeave", function(self)
    if not self.called then W.borderRole(self.border, "line") end
    GameTooltip:Hide()
  end)
  c:SetScript("OnMouseDown", function(self) if not self.called then Theme.set(self.face, "sunk") end end)
  c:SetScript("OnMouseUp", function(self) if not self.called then Theme.set(self.face, "raised") end end)
  c:SetScript("OnClick", function(self, button)
    if board.onCellClick then board.onCellClick(self.item, button, IsControlKeyDown()) end
  end)
  return c
end

-- The free centre: the guild crest. The one square everyone starts with
-- carries the guild's mark, with the gold dashed bar so it never reads as
-- a called square.
local function newCentre(board)
  local c = CreateFrame("Frame", nil, board.frame)
  c.face = W.rect(c, "sunk"); c.face:SetAllPoints()
  c.border = W.border(c, "line")
  c.dash = c:CreateTexture(nil, "ARTWORK")
  Theme.register(c.dash, "gold", "bg", 0.6)
  c.dash:SetPoint("TOPLEFT", W.px(1), -W.px(1)); c.dash:SetPoint("TOPRIGHT", -W.px(1), -W.px(1))
  c.dash:SetHeight(W.px(2))
  c.crest = W.crest(c, 256, "ARTWORK")
  c.crest:SetPoint("CENTER", 0, 0)

  function c:Resize(w, h)
    local s = math.floor(math.min(w, h) * 0.86)
    self.crest:SetSize(s, s)
  end
  return c
end

------------------------------------------------------------------- board

function Board.new(parent)
  local self = setmetatable({}, Board)
  self.frame = CreateFrame("Frame", nil, parent)
  if not ruler then
    ruler = UIParent:CreateFontString(nil, "ARTWORK")
    ruler:Hide()
    ruler:SetWordWrap(true); ruler:SetNonSpaceWrap(true)
    ruler:SetJustifyH("CENTER")
  end
  self.cells = {}
  for p = 1, Logic.BOARD_CELLS do
    if p == Logic.FREE_CELL then
      self.cells[p] = newCentre(self)
    else
      self.cells[p] = newCell(self, p)
    end
  end
  self.fontSize = 12
  self.frame:SetScript("OnSizeChanged", function()
    if self.laidOut then self.laidOut = nil; return end   -- our own SetHeight from Layout
    self:Layout()
  end)
  return self
end

function Board:SetView(view)
  self.view = view
  local items = view and view.items
  local board = view and view.board
  local called = view and view.called or {}
  local winning = view and view.winning or {}
  local itemsChanged = items ~= self.lastItems
  self.lastItems = items
  for p, c in ipairs(self.cells) do
    if p ~= Logic.FREE_CELL then
      local item = board and board[p] or nil
      c.item = item
      local text = (items and item ~= nil) and items[item + 1] or (item ~= nil and ("#" .. (item + 1)) or "")
      local isCalled = item ~= nil and called[item] == true
      local isWinning = winning[p] == true
      local isPending = item ~= nil and view and view.pending and view.pending[item] ~= nil
      c.called = isCalled
      W.setFont(c.text, isCalled and "bodyBold" or "body", self.fontSize)
      c.text:SetText(Logic.escape(text))   -- player text: a pipe must never become an escape code
      if isWinning then
        Theme.set(c.face, "fel"); W.borderRole(c.border, "fel")
        Theme.set(c.text, "felInk"); Theme.set(c.strike, "felInk"); Theme.set(c.check, "felInk")
        c.topbar:Hide(); c.strike:Show(); c.check:Show()
      elseif isCalled then
        Theme.set(c.face, "felWash"); W.borderRole(c.border, "fel")
        Theme.set(c.text, "ink"); Theme.set(c.strike, "fel"); Theme.set(c.check, "fel")
        c.topbar:Show(); c.strike:Show(); c.check:Show()
      elseif isPending then
        -- asked the host, no answer yet: a gold edge, nothing else changes
        Theme.set(c.face, "raised"); W.borderRole(c.border, "gold")
        Theme.set(c.text, "ink")
        c.topbar:Hide(); c.strike:Hide(); c.check:Hide()
      else
        Theme.set(c.face, "raised"); W.borderRole(c.border, "line")
        Theme.set(c.text, "ink")
        c.topbar:Hide(); c.strike:Hide(); c.check:Hide()
      end
    end
  end
  if itemsChanged then self:Layout() end
end

-- Lay the grid out for the frame's current size: cells share the width,
-- rows grow before any text is allowed to clip.
function Board:Layout()
  local f = self.frame
  local width, height = f:GetWidth(), f:GetHeight()
  if width < 50 or height < 50 then return end
  local gap = Board.GAP
  local cellW = math.floor((width - gap * 4) / 5)
  local cellH = math.floor((height - gap * 4) / 5)
  local items = self.view and self.view.items
  local size = Board.MIN_FONT
  if items then
    -- Rows grow before any text is allowed to clip: the grown height is
    -- the one the cells are laid out at, and the frame grows with them.
    local fitted = fitSize(items, cellW, cellH)
    local grow = 0
    while not fitted and grow < 4 do
      grow = grow + 1
      fitted = fitSize(items, cellW, cellH + grow * 6)
    end
    size = fitted or Board.MIN_FONT
    cellH = cellH + grow * 6
  end
  self.fontSize = size
  local needed = cellH * 5 + gap * 4
  if needed > height then
    self.laidOut = true
    f:SetHeight(needed)   -- fires OnSizeChanged once more; the fit below then holds
  end
  for p, c in ipairs(self.cells) do
    local row, col = math.floor((p - 1) / 5), (p - 1) % 5
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", f, "TOPLEFT", col * (cellW + gap), -(row * (cellH + gap)))
    c:SetSize(cellW, cellH)
    if p == Logic.FREE_CELL then
      c:Resize(cellW, cellH)
    else
      W.setFont(c.text, c.called and "bodyBold" or "body", size)
    end
  end
end
