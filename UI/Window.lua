--[[
  The main window. Three views in one frame: the lobby (open games, start a
  game), setup (title, squares, audience), and the game (board, standings,
  call log). Movable, resizable, closes on Escape, dims in combat.

  The window never reaches into Host or Mirror directly: it renders a view
  model from Core/View and calls back into App for every action.
]]

local ADDON, ns = ...
local Logic, Theme, W, Board, View, Quips = ns.Logic, ns.Theme, ns.W, ns.Board, ns.View, ns.Quips

local Window = {}
ns.Window = Window

-- Below this the 24 edit boxes of the setup grid shrink past legibility.
Window.MIN_W, Window.MIN_H = 720, 560

local RAIL = 290
local PAD = 14
local HEADER = 54
local TABS = 32
local TOP = HEADER + TABS   -- where every view starts
local FOOTER = 44

local win   -- the single frame
local app   -- callbacks: app.lobby(), app.view(), app.join(gid), app.open(gid), app.create(opts), app.call(idx, undo), app.grant(name, on), app.close(), app.leaveToLobby(), app.savePosition(pos), app.position(), app.itemSets(), app.presets()

----------------------------------------------------------------- helpers

local function hideAll(views)
  for _, v in pairs(views) do v:Hide() end
end

-- A scrolling list of rows built by `makeRow`, re-filled by :Fill(items, fill).
local function scrollList(parent, rowHeight, makeRow)
  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  scroll.rows = {}
  scroll.child = child
  -- Blizzard's scrollbar chrome does not belong on a stone panel: hide it
  -- and scroll with the wheel, with a thin fel thumb as the only indicator.
  if scroll.ScrollBar then scroll.ScrollBar:Hide(); scroll.ScrollBar:SetScript("OnShow", function(sb) sb:Hide() end) end
  scroll.thumb = scroll:CreateTexture(nil, "OVERLAY")
  Theme.register(scroll.thumb, "lineStrong", "bg")
  scroll.thumb:SetWidth(W.px(2))
  scroll.thumb:Hide()
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, self.child:GetHeight() - self:GetHeight())
    local target = math.min(max, math.max(0, (self:GetVerticalScroll() or 0) - delta * rowHeight * 3))
    self:SetVerticalScroll(target)
    self:UpdateThumb()
  end)
  function scroll:UpdateThumb()
    local total, visible = self.child:GetHeight(), self:GetHeight()
    if total <= visible + 1 then self.thumb:Hide(); return end
    local trackH = visible - 4
    local thumbH = math.max(18, trackH * visible / total)
    local offset = ((self:GetVerticalScroll() or 0) / (total - visible)) * (trackH - thumbH)
    self.thumb:ClearAllPoints()
    self.thumb:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -(2 + offset))
    self.thumb:SetHeight(thumbH)
    self.thumb:Show()
  end
  -- The rows are as wide as the frame less the thumb gutter. The width comes
  -- from OnSizeChanged, not from GetWidth at fill time: the window resizes
  -- under the list, and while the window's own OnSizeChanged runs this
  -- frame's width still reads as 0.
  function scroll:SetInnerWidth(w)
    if not w or w <= 0 then return end
    local width = w - 20
    self.innerWidth = width
    child:SetWidth(width)
    for _, row in ipairs(self.rows) do row:SetWidth(width) end
  end
  scroll:SetScript("OnSizeChanged", function(self, w)
    self:SetInnerWidth(w)
    local max = math.max(0, self.child:GetHeight() - self:GetHeight())
    if (self:GetVerticalScroll() or 0) > max then self:SetVerticalScroll(max) end
    self:UpdateThumb()
  end)
  function scroll:Fill(items, fill)
    local width = self.innerWidth or math.max(1, self:GetWidth() - 20)
    child:SetWidth(width)
    -- rows are frames and frames are never freed: never build more than this
    if #items > 200 then local cut = {} for i = 1, 200 do cut[i] = items[i] end items = cut end
    for i, item in ipairs(items) do
      local row = self.rows[i]
      if not row then
        row = makeRow(child)
        row:SetHeight(rowHeight)
        self.rows[i] = row
      end
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
      row:SetWidth(width)
      row:Show()
      fill(row, item, i)
    end
    for i = #items + 1, #self.rows do self.rows[i]:Hide() end
    child:SetHeight(math.max(1, #items * rowHeight))
    local max = math.max(0, child:GetHeight() - self:GetHeight())
    if (self:GetVerticalScroll() or 0) > max then self:SetVerticalScroll(max) end
    self:UpdateThumb()
  end
  return scroll
end

------------------------------------------------------------------- build

local function buildHeader(f)
  local h = CreateFrame("Frame", nil, f)
  h:SetPoint("TOPLEFT"); h:SetPoint("TOPRIGHT"); h:SetHeight(HEADER)
  h.bg = W.rect(h, "surface"); h.bg:SetAllPoints()
  h.rule = h:CreateTexture(nil, "BORDER"); Theme.register(h.rule, "line", "bg")
  h.rule:SetPoint("BOTTOMLEFT"); h.rule:SetPoint("BOTTOMRIGHT"); h.rule:SetHeight(W.px(1))

  h.crest = W.crest(h, 40)
  h.crest:SetPoint("LEFT", PAD - 2, 0)
  h.wordmark = W.text(h, W.fonts().eyebrow, "inkFaint")
  h.wordmark:SetPoint("TOPLEFT", PAD + 46, -11)
  h.wordmark:SetText("DEA BINGO")
  h.title = W.text(h, W.fonts().heading, "ink")
  h.title:SetPoint("BOTTOMLEFT", PAD + 46, 9)
  h.title:SetText("")
  h.status = W.text(h, W.fonts().body, "inkDim", "RIGHT")
  h.status:SetPoint("RIGHT", -44, -2)
  h.close = W.closeButton(h, function() f:Hide() end)
  h.close:SetPoint("TOPRIGHT", -8, -8)
  return h
end

-- The tab strip: Game (while in one), Games, History, Options.
local TAB_DEFS = {
  { key = "game", label = "GAME" },
  { key = "lobby", label = "GAMES" },
  { key = "history", label = "HISTORY" },
  { key = "options", label = "OPTIONS" },
}

local function buildTabs(f)
  local t = CreateFrame("Frame", nil, f)
  t:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER)
  t:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -HEADER)
  t:SetHeight(TABS)
  t.bg = W.rect(t, "surface"); t.bg:SetAllPoints()
  t.rule = t:CreateTexture(nil, "BORDER"); Theme.register(t.rule, "line", "bg")
  t.rule:SetPoint("BOTTOMLEFT"); t.rule:SetPoint("BOTTOMRIGHT"); t.rule:SetHeight(W.px(1))
  t.tabs = {}
  for _, def in ipairs(TAB_DEFS) do
    local b = CreateFrame("Button", nil, t)
    b:SetHeight(TABS)
    b.label = W.text(b, W.fonts().eyebrow, "inkDim", "CENTER")
    b.label:SetPoint("CENTER", 0, 1)
    b.label:SetText(def.label)
    b.under = b:CreateTexture(nil, "ARTWORK"); Theme.register(b.under, "fel", "bg")
    b.under:SetPoint("BOTTOMLEFT", 0, 0); b.under:SetPoint("BOTTOMRIGHT", 0, 0); b.under:SetHeight(W.px(2))
    b.under:Hide()
    b.key = def.key
    b:SetScript("OnEnter", function(self) if not self.active then Theme.set(self.label, "ink") end end)
    b:SetScript("OnLeave", function(self) if not self.active then Theme.set(self.label, "inkDim") end end)
    b:SetScript("OnClick", function(self) win.historyGid = nil; Window.show(self.key) end)   -- a tab always leaves a history board
    t.tabs[def.key] = b
  end
  -- lay out left to right; the Game tab may be hidden
  function t:Layout(showGame)
    local x = PAD - 6
    for _, def in ipairs(TAB_DEFS) do
      local b = self.tabs[def.key]
      if def.key == "game" and not showGame then
        b:Hide()
      else
        b:Show()
        local w = (b.label:GetStringWidth() or 60) + 28
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
        b:SetWidth(w)
        x = x + w
      end
    end
  end
  function t:SetActive(key)
    for k, b in pairs(self.tabs) do
      b.active = (k == key)
      Theme.set(b.label, b.active and "ink" or "inkDim")
      if b.active then b.under:Show() else b.under:Hide() end
    end
  end
  return t
end

local function buildFooter(f)
  local b = CreateFrame("Frame", nil, f)
  b:SetPoint("BOTTOMLEFT"); b:SetPoint("BOTTOMRIGHT"); b:SetHeight(FOOTER)
  b.bg = W.rect(b, "surface"); b.bg:SetAllPoints()
  b.rule = b:CreateTexture(nil, "BORDER"); Theme.register(b.rule, "line", "bg")
  b.rule:SetPoint("TOPLEFT"); b.rule:SetPoint("TOPRIGHT"); b.rule:SetHeight(W.px(1))
  b.text = W.text(b, W.fonts().body, "inkDim")
  b.text:SetPoint("LEFT", PAD, 0)
  b.text:SetPoint("RIGHT", -160, 0)
  b.action = W.button(b, "", nil, { width = 130, height = 26 })
  b.action:SetPoint("RIGHT", -(PAD + 24), 0)   -- room for the resize grip
  b.action:Hide()
  -- The one-liners: on while a view has nothing of its own to say in the
  -- footer. The first shows at once, then another every Quips.EVERY seconds.
  b.quip = nil
  b.elapsed = 0
  function b:ShowQuip()
    self.quip = Quips.next(self.quip)
    self.elapsed = 0
    self.text:SetText(Quips.LIST[self.quip] or "")
  end
  function b:Quip(on)
    if on then self:ShowQuip() else self.quipping = nil; return end
    self.quipping = true
  end
  b:SetScript("OnUpdate", function(self, elapsed)
    if not self.quipping then return end
    self.elapsed = self.elapsed + (elapsed or 0)
    if self.elapsed >= Quips.EVERY then self:ShowQuip() end
  end)
  return b
end

-- Game view: board on the left, rail on the right.
local function buildGame(f)
  local g = CreateFrame("Frame", nil, f)
  g:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -TOP)
  g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, FOOTER)

  g.boardHolder = CreateFrame("Frame", nil, g)
  g.boardHolder:SetPoint("TOPLEFT", PAD, -PAD)
  g.boardHolder:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -(RAIL + PAD * 2), PAD)
  g.board = Board.new(g.boardHolder)
  g.board.frame:SetPoint("TOPLEFT")
  g.board.frame:SetPoint("BOTTOMRIGHT")
  -- A caller's click calls the square, or undoes a called one. A call can be
  -- undone and redone at will, so there is nothing to confirm (#42). Anyone
  -- else gets the sheet with the full square text.
  g.board.onCellClick = function(idx)
    if idx == nil then return end
    local v = win.currentView
    if not v then return end
    if v.canCall and v.state == "open" then
      app.call(idx, v.called[idx] == true)
      return
    end
    Window.sheet(idx)
  end

  g.rail = CreateFrame("Frame", nil, g)
  g.rail:SetPoint("TOPRIGHT", -PAD, -PAD)
  g.rail:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  g.rail:SetWidth(RAIL)

  -- standings
  g.standings = W.panel(g.rail)
  g.standings:SetPoint("TOPLEFT"); g.standings:SetPoint("TOPRIGHT")
  g.standings:SetPoint("BOTTOM", g.rail, "CENTER", 0, 6)
  g.standings.head = W.text(g.standings, W.fonts().eyebrow, "inkFaint")
  g.standings.head:SetPoint("TOPLEFT", 10, -9)
  g.standings.head:SetText("STANDINGS")
  g.standings.count = W.text(g.standings, W.fonts().small, "inkFaint", "RIGHT")
  g.standings.count:SetPoint("TOPRIGHT", -10, -8)
  -- Two lines a player: the whole name (Forever names are two words) with
  -- the bingo time at the right, then the meter and the CALLER flag under it.
  g.standings.list = scrollList(g.standings, 38, function(parent)
    local row = CreateFrame("Button", nil, parent)
    row.rank = W.text(row, W.fonts().bodyBold, "gold", "RIGHT"); row.rank:SetPoint("TOPLEFT", 0, -5); row.rank:SetWidth(18)
    row.name = W.text(row, W.fonts().body, "ink"); row.name:SetPoint("TOPLEFT", 24, -5); row.name:SetPoint("RIGHT", -56, 0)
    row.name:SetWordWrap(false)
    row.time = W.text(row, W.fonts().small, "fel", "RIGHT"); row.time:SetPoint("TOPRIGHT", -2, -6); row.time:SetWidth(50)
    row.meter = W.meter(row); row.meter:SetPoint("BOTTOMLEFT", 24, 7)
    row.flag = W.text(row, W.fonts().eyebrow, "inkFaint"); row.flag:SetPoint("LEFT", row.meter, "RIGHT", 10, 0); row.flag:SetWidth(60)
    row:RegisterForClicks("RightButtonUp")
    row:SetScript("OnClick", function(self)
      local v = win.currentView
      if not (v and v.isHost and self.player and self.player.name ~= v.owner) then return end
      if IsShiftKeyDown() then
        local who = self.player.name
        Window.confirm("HAND OVER THE GAME",
          ("%s becomes the host: they call, grant calling and close. You keep your board and play on. This cannot be taken back without them handing it to you."):format(Logic.escape(self.player.shortName)),
          "Hand it over", function() app.transfer(who) end)
      else
        app.grant(self.player.name, not self.player.canCall)
      end
    end)
    row:SetScript("OnEnter", function(self) g:Peek(self) end)
    row:SetScript("OnLeave", function() g.peek:Hide() end)
    return row
  end)
  g.standings.list:SetPoint("TOPLEFT", 8, -30)
  g.standings.list:SetPoint("BOTTOMRIGHT", -6, 8)

  -- Hover a player: a card beside the row with their grid as dots, like
  -- the chip's, and the lines the tooltip used to carry. Positions only;
  -- another player's squares are never shown. Over the window, so it can
  -- hang out to the left of the rail.
  local pk = W.panel(f, "raised")
  pk:SetFrameLevel((f:GetFrameLevel() or 0) + 25)
  pk:SetWidth(240)
  pk.name = W.text(pk, W.fonts().bodyBold, "ink"); pk.name:SetPoint("TOPLEFT", 12, -10); pk.name:SetPoint("RIGHT", -12, 0)
  pk.name:SetWordWrap(false)
  pk.grid = W.dotGrid(pk, 9, 3); pk.grid:SetPoint("TOPLEFT", 12, -34)
  pk.info = W.text(pk, W.fonts().small, "inkDim"); pk.info:SetPoint("TOPLEFT", pk.grid, "TOPRIGHT", 12, 0); pk.info:SetPoint("RIGHT", -12, 0)
  pk.hints = W.text(pk, W.fonts().small, "inkFaint"); pk.hints:SetPoint("TOPLEFT", pk.grid, "BOTTOMLEFT", 0, -8); pk.hints:SetPoint("RIGHT", -12, 0)
  pk:Hide()
  g.peek = pk
  function g:Peek(row)
    local v, p = win.currentView, row.player
    if not (v and p and p.board) then pk:Hide(); return end
    pk.row = row
    pk.name:SetText(Logic.escape(p.shortName))
    pk.grid:Paint(p.board, v.called, p.winning)
    local info = { p.bingoAt and ("Bingo at " .. W.clock(p.bingoAt)) or ("Best line %d of 5"):format(p.bestLine) }
    if p.canCall then info[#info + 1] = "Can call squares" end
    pk.info:SetText(table.concat(info, "\n"))
    local hints = {}
    if v.isHost and p.name ~= v.owner then
      hints[#hints + 1] = p.canCall and "Right-click to revoke calling" or "Right-click to let them call"
      hints[#hints + 1] = "Shift-right-click to hand them the game"
    end
    pk.hints:SetText(table.concat(hints, "\n"))
    pk:SetHeight(34 + pk.grid:GetHeight() + (#hints > 0 and (8 + #hints * 15) or 0) + 12)
    pk:ClearAllPoints()
    pk:SetPoint("TOPRIGHT", row, "TOPLEFT", -10, 4)
    pk:Show()
  end

  -- call log
  g.log = W.panel(g.rail)
  g.log:SetPoint("BOTTOMLEFT"); g.log:SetPoint("BOTTOMRIGHT")
  g.log:SetPoint("TOP", g.rail, "CENTER", 0, -6)
  g.log.head = W.text(g.log, W.fonts().eyebrow, "inkFaint")
  g.log.head:SetPoint("TOPLEFT", 10, -9)
  g.log.head:SetText("CALLS")
  g.log.count = W.text(g.log, W.fonts().small, "inkFaint", "RIGHT")
  g.log.count:SetPoint("TOPRIGHT", -10, -8)
  g.log.list = scrollList(g.log, 20, function(parent)
    local row = CreateFrame("Frame", nil, parent)
    row.time = W.text(row, W.fonts().small, "inkFaint"); row.time:SetPoint("LEFT", 0, 0); row.time:SetWidth(40)
    row.text = W.text(row, W.fonts().body, "ink"); row.text:SetPoint("LEFT", 44, 0); row.text:SetPoint("RIGHT", 0, 0)
    row.text:SetWordWrap(false)
    return row
  end)
  g.log.list:SetPoint("TOPLEFT", 8, -30)
  g.log.list:SetPoint("BOTTOMRIGHT", -6, 8)
  g.log.empty = W.text(g.log, W.fonts().body, "inkFaint", "CENTER")
  g.log.empty:SetPoint("CENTER", 0, -6)
  g.log.empty:SetText("Nothing called yet")

  -- Mode switch, callers only: LOG shows what was called, CALL is the
  -- alphabetical list the caller works from. Alphabetical beats board
  -- order because the caller is hunting a phrase they just heard.
  g.railMode = "log"
  g.log.modeLog = W.text(g.log, W.fonts().eyebrow, "ink")
  g.log.modeCall = W.text(g.log, W.fonts().eyebrow, "inkFaint")
  g.log.modeLog:SetText("LOG"); g.log.modeCall:SetText("CALL A SQUARE")
  g.log.modeLog:SetPoint("TOPLEFT", 10, -9)
  g.log.modeCall:SetPoint("LEFT", g.log.modeLog, "RIGHT", 14, 0)
  g.log.modeLog:Hide(); g.log.modeCall:Hide()
  local function modeButton(fs, mode)
    local b = CreateFrame("Button", nil, g.log)
    b:SetAllPoints(fs)
    b:SetScript("OnClick", function() g.railMode = mode; Window.refresh() end)
    return b
  end
  g.log.modeLogBtn = modeButton(g.log.modeLog, "log")
  g.log.modeCallBtn = modeButton(g.log.modeCall, "call")

  g.log.filter = W.editBox(g.log, 100, W.fonts().small)
  g.log.filter:SetPoint("TOPLEFT", 8, -28); g.log.filter:SetPoint("TOPRIGHT", -8, -28)
  g.log.filter:SetHeight(22)
  g.log.filter:SetScript("OnTextChanged", function() Window.refresh() end)
  g.log.filter:Hide()
  g.log.filterHint = W.text(g.log, W.fonts().small, "inkFaint")
  g.log.filterHint:SetPoint("LEFT", g.log.filter, "LEFT", 8, 0)
  g.log.filterHint:SetText("Type to filter")
  g.log.filterHint:Hide()

  g.recentCall = {}
  g.log.caller = scrollList(g.log, 22, function(parent)
    local row = CreateFrame("Button", nil, parent)
    row.hover = W.rect(row, "raised", "BACKGROUND"); row.hover:SetAllPoints(); row.hover:Hide()
    row.mark = W.diamond(row, 8, "fel", "ARTWORK"); row.mark:SetPoint("LEFT", 3, 0); row.mark:Hide()
    row.text = W.text(row, W.fonts().body, "ink"); row.text:SetPoint("LEFT", 16, 0); row.text:SetPoint("RIGHT", -46, 0)
    row.text:SetWordWrap(false)
    row.time = W.text(row, W.fonts().small, "fel", "RIGHT"); row.time:SetPoint("RIGHT", -2, 0); row.time:SetWidth(42)
    row:SetScript("OnEnter", function(self) self.hover:Show() end)
    row:SetScript("OnLeave", function(self) self.hover:Hide() end)
    row:SetScript("OnClick", function(self)
      if self.idx == nil then return end
      local now = GetTime()
      if g.recentCall[self.idx] and now - g.recentCall[self.idx] < 1.5 then return end
      g.recentCall[self.idx] = now
      app.call(self.idx, self.called)
    end)
    return row
  end)
  g.log.caller:SetPoint("TOPLEFT", 8, -54)
  g.log.caller:SetPoint("BOTTOMRIGHT", -6, 8)
  g.log.caller:Hide()
  return g
end

-- Lobby: open games and a start button.
local function buildLobby(f)
  local l = CreateFrame("Frame", nil, f)
  l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -TOP)
  l:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, FOOTER)
  l.head = W.text(l, W.fonts().eyebrow, "inkFaint")
  l.head:SetPoint("TOPLEFT", PAD + 2, -PAD - 4)
  l.head:SetText("GAMES AROUND YOU")

  l.empty = W.text(l, W.fonts().body, "inkDim", "CENTER")
  l.empty:SetPoint("CENTER", 0, 20)
  l.empty:SetWidth(420)
  l.empty:SetText("No open game yet. Start one for the guild, or wait for a host to open theirs.")
  l.list = scrollList(l, 64, function(parent)
    local row = W.panel(parent, "raised")
    row.title = W.text(row, W.fonts().title, "ink"); row.title:SetPoint("TOPLEFT", 12, -10); row.title:SetPoint("RIGHT", -150, 0)
    row.meta = W.text(row, W.fonts().small, "inkDim"); row.meta:SetPoint("BOTTOMLEFT", 12, 10); row.meta:SetPoint("RIGHT", -150, 0)
    row.button = W.button(row, "Join", function(self) local r = self:GetParent(); if r.game then if r.game.mine or r.game.joined then app.open(r.game.gid) else app.join(r.game.gid) end end end, { width = 110, height = 28, primary = true })
    row.button:SetPoint("RIGHT", -12, 0)
    return row
  end)
  l.list:SetPoint("TOPLEFT", PAD, -(PAD + 24))
  l.list:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  return l
end

-- Setup: title, 24 squares, audience, open.
local function buildSetup(f)
  local s = CreateFrame("Frame", nil, f)
  s:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -TOP)
  s:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, FOOTER)

  s.titleLabel = W.text(s, W.fonts().eyebrow, "inkFaint"); s.titleLabel:SetPoint("TOPLEFT", PAD + 2, -PAD - 2); s.titleLabel:SetText("TITLE")
  s.title = W.editBox(s, 300); s.title:SetPoint("TOPLEFT", PAD, -(PAD + 16))
  s.title:SetMaxLetters(Logic.TITLE_MAX)

  s.audienceLabel = W.text(s, W.fonts().eyebrow, "inkFaint"); s.audienceLabel:SetPoint("LEFT", s.title, "RIGHT", 24, 14); s.audienceLabel:SetText("WHO CAN JOIN")
  s.audience = "G"
  s.guildBtn = W.button(s, "Guild", function() s.audience = "G"; s:Refresh() end, { width = 86, height = 26 })
  s.guildBtn:SetPoint("TOPLEFT", s.audienceLabel, "BOTTOMLEFT", 0, -4)
  s.raidBtn = W.button(s, "Raid", function() s.audience = "R"; s:Refresh() end, { width = 86, height = 26 })
  s.raidBtn:SetPoint("LEFT", s.guildBtn, "RIGHT", 6, 0)
  s.audienceHint = W.text(s, W.fonts().small, "inkFaint"); s.audienceHint:SetPoint("LEFT", s.raidBtn, "RIGHT", 10, 0); s.audienceHint:SetPoint("RIGHT", -PAD, 0)

  s.fromLabel = W.text(s, W.fonts().eyebrow, "inkFaint"); s.fromLabel:SetPoint("TOPLEFT", s.title, "BOTTOMLEFT", 2, -12); s.fromLabel:SetText("START FROM")
  s.fromButtons = {}
  s.pasteBtn = W.button(s, "Paste a list…", function() s:OpenPaste() end, { width = 150, height = 26, font = W.fonts().small })

  -- Paste card: a multi-line box, one square per line, numbering stripped.
  local pc = CreateFrame("Button", nil, s)
  pc:SetAllPoints(f)
  pc:SetFrameLevel((s:GetFrameLevel() or 0) + 30)
  pc.scrim = W.rect(pc, "scrim"); pc.scrim:SetAllPoints()
  pc:SetScript("OnClick", function() pc:Hide() end)
  pc.card = W.panel(pc, "raised")
  pc.card:SetSize(520, 420)
  pc.card:SetPoint("CENTER", 0, 10)
  pc.card:EnableMouse(true)
  pc.card.eyebrow = W.text(pc.card, W.fonts().eyebrow, "inkFaint"); pc.card.eyebrow:SetPoint("TOPLEFT", 18, -16); pc.card.eyebrow:SetText("PASTE A LIST")
  pc.card.hint = W.text(pc.card, W.fonts().small, "inkDim"); pc.card.hint:SetPoint("TOPLEFT", 18, -34); pc.card.hint:SetPoint("RIGHT", -18, 0)
  pc.card.hint:SetText("One square per line. Numbers and bullets at the start of a line are dropped; so are duplicates and blank lines.")
  pc.card.box = CreateFrame("ScrollFrame", nil, pc.card, "UIPanelScrollFrameTemplate")
  pc.card.box:SetPoint("TOPLEFT", 18, -66); pc.card.box:SetPoint("BOTTOMRIGHT", -18, 58)
  if pc.card.box.ScrollBar then pc.card.box.ScrollBar:Hide(); pc.card.box.ScrollBar:SetScript("OnShow", function(sb) sb:Hide() end) end
  pc.card.boxBg = W.rect(pc.card, "sunk"); pc.card.boxBg:SetPoint("TOPLEFT", pc.card.box, -6, 6); pc.card.boxBg:SetPoint("BOTTOMRIGHT", pc.card.box, 6, -6)
  pc.card.edit = CreateFrame("EditBox", nil, pc.card.box)
  pc.card.edit:SetMultiLine(true)
  pc.card.edit:SetAutoFocus(false)
  pc.card.edit:SetFontObject(W.fonts().body)
  pc.card.edit:SetWidth(470)
  pc.card.edit:SetTextInsets(4, 4, 4, 4)
  Theme.register(pc.card.edit, "ink", "text")
  pc.card.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  pc.card.edit:SetScript("OnTextChanged", function(self)
    local n = #Window.parseList(self:GetText())
    pc.card.count:SetText(n == 0 and "" or (n .. " of 24 squares"))
    pc.card.use:SetEnabledState(n > 0)
  end)
  pc.card.box:SetScrollChild(pc.card.edit)
  -- A scroll frame made in Lua ignores the mouse unless told otherwise;
  -- clicking the blank area below the text must still focus the box.
  pc.card.box:EnableMouse(true)
  pc.card.box:SetScript("OnMouseDown", function() pc.card.edit:SetFocus() end)
  -- Keep the cursor in view as a long paste grows past the visible lines.
  pc.card.edit:SetScript("OnCursorChanged", function(self, x, y, w, h)
    local box = pc.card.box
    local view = box:GetHeight() or 0
    local scroll = box:GetVerticalScroll() or 0
    local top, bottom = -y, -y + h
    if top < scroll then scroll = top
    elseif bottom > scroll + view then scroll = bottom - view end
    box:SetVerticalScroll(math.max(0, scroll))
  end)
  -- the edit box is at least as tall as its frame, so the blank area is part of it
  pc.card.box:SetScript("OnSizeChanged", function(self, w, h)
    pc.card.edit:SetWidth((w or 470) - 8)
    if (pc.card.edit:GetHeight() or 0) < (h or 0) then pc.card.edit:SetHeight(h) end
  end)
  pc.card.count = W.text(pc.card, W.fonts().small, "inkDim"); pc.card.count:SetPoint("BOTTOMLEFT", 18, 22)
  pc.card.use = W.button(pc.card, "Use these squares", function()
    s:SetItems(Window.parseList(pc.card.edit:GetText()))
    pc:Hide()
  end, { width = 170, height = 30, primary = true })
  pc.card.use:SetPoint("BOTTOMRIGHT", -16, 14)
  pc.card.cancel = W.button(pc.card, "Cancel", function() pc:Hide() end, { width = 100, height = 30 })
  pc.card.cancel:SetPoint("RIGHT", pc.card.use, "LEFT", -8, 0)
  pc:Hide()
  s.pasteCard = pc

  -- Previous games: a scrolling picker, since a row of buttons grows
  -- without bound and two nights can share a title.
  local pk = CreateFrame("Button", nil, s)
  pk:SetAllPoints(f)
  pk:SetFrameLevel((s:GetFrameLevel() or 0) + 30)
  pk.scrim = W.rect(pk, "scrim"); pk.scrim:SetAllPoints()
  pk:SetScript("OnClick", function() pk:Hide() end)
  pk.card = W.panel(pk, "raised")
  pk.card:SetSize(560, 440)
  pk.card:SetPoint("CENTER", 0, 10)
  pk.card:EnableMouse(true)
  pk.card.eyebrow = W.text(pk.card, W.fonts().eyebrow, "inkFaint"); pk.card.eyebrow:SetPoint("TOPLEFT", 18, -16); pk.card.eyebrow:SetText("PREVIOUS GAMES")
  pk.card.hint = W.text(pk.card, W.fonts().small, "inkDim"); pk.card.hint:SetPoint("TOPLEFT", 18, -34); pk.card.hint:SetPoint("RIGHT", -18, 0)
  pk.card.hint:SetText("Every set of squares this character has hosted or played, most recent first. Pick one to start from it.")
  pk.card.list = scrollList(pk.card, 58, function(parent)
    local row = CreateFrame("Button", nil, parent)
    row.hover = W.rect(row, "surface", "BACKGROUND"); row.hover:SetAllPoints(); row.hover:Hide()
    row.rule = row:CreateTexture(nil, "BORDER"); Theme.register(row.rule, "line", "bg")
    row.rule:SetPoint("BOTTOMLEFT"); row.rule:SetPoint("BOTTOMRIGHT"); row.rule:SetHeight(W.px(1))
    row.title = W.text(row, W.fonts().bodyBold, "ink"); row.title:SetPoint("TOPLEFT", 6, -9); row.title:SetPoint("RIGHT", -120, 0)
    row.when = W.text(row, W.fonts().small, "inkFaint", "RIGHT"); row.when:SetPoint("TOPRIGHT", -6, -10); row.when:SetWidth(110)
    row.preview = W.text(row, W.fonts().small, "inkDim"); row.preview:SetPoint("BOTTOMLEFT", 6, 9); row.preview:SetPoint("RIGHT", -6, 0)
    row.preview:SetWordWrap(false)
    row:SetScript("OnEnter", function(self) self.hover:Show() end)
    row:SetScript("OnLeave", function(self) self.hover:Hide() end)
    row:SetScript("OnClick", function(self)
      if not self.set then return end
      s:SetItems(self.set.items)
      if self.set.titleHint and (s.title:GetText() == "" or s.title:GetText():match("^%a+ raid$")) then s.title:SetText(self.set.titleHint) end
      pk:Hide()
    end)
    return row
  end)
  pk.card.list:SetPoint("TOPLEFT", 12, -66); pk.card.list:SetPoint("BOTTOMRIGHT", -8, 56)
  pk.card.cancel = W.button(pk.card, "Cancel", function() pk:Hide() end, { width = 100, height = 30 })
  pk.card.cancel:SetPoint("BOTTOMRIGHT", -16, 14)
  pk:Hide()
  s.pickerCard = pk
  function s:OpenPicker()
    local saved = {}
    for _, src in ipairs(app.itemSets()) do if src.saved then saved[#saved + 1] = src end end
    pk.card.list:Fill(saved, function(row, set)
      row.set = set
      row.title:SetText(Logic.escape(set.name or ""))
      row.when:SetText(set.usedAt and set.usedAt > 0 and date("%a %d %b", set.usedAt) or "")
      local bits = {}
      for i = 1, math.min(4, #set.items) do bits[i] = set.items[i] end
      row.preview:SetText(Logic.escape(table.concat(bits, "  ·  ")))
    end)
    pk:Show()
  end
  s.previousBtn = W.button(s, "Previous games…", function() s:OpenPicker() end, { width = 170, height = 26, font = W.fonts().small })

  function s:OpenPaste()
    pc.card.edit:SetText("")
    pc.card.count:SetText("")
    pc.card.use:SetEnabledState(false)
    pc:Show()
    pc.card.edit:SetFocus()
  end

  s.squaresLabel = W.text(s, W.fonts().eyebrow, "inkFaint"); s.squaresLabel:SetPoint("TOPLEFT", s.fromLabel, "BOTTOMLEFT", 0, -36); s.squaresLabel:SetText("24 SQUARES")
  s.squaresHint = W.text(s, W.fonts().small, "inkFaint"); s.squaresHint:SetPoint("LEFT", s.squaresLabel, "RIGHT", 10, 0)
  s.squaresHint:SetText("Every player gets these in a different order. Up to 60 characters each.")

  s.grid = CreateFrame("Frame", nil, s)
  s.grid:SetPoint("TOPLEFT", s.squaresLabel, "BOTTOMLEFT", -2, -6)
  s.grid:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  s.boxes = {}
  for i = 1, Logic.ITEM_COUNT do
    local num = W.text(s.grid, W.fonts().eyebrow, "inkFaint", "RIGHT"); num:SetWidth(22); num:SetText(tostring(i))
    local box = W.editBox(s.grid, 100, W.fonts().small)
    box:SetMaxLetters(Logic.ITEM_MAX)
    box:SetScript("OnTextChanged", function() s:Validate() end)
    box:SetScript("OnTabPressed", function()
      local nextBox = s.boxes[i % Logic.ITEM_COUNT + 1]
      nextBox.box:SetFocus()
    end)
    s.boxes[i] = { num = num, box = box }
  end
  s.grid:SetScript("OnSizeChanged", function() s:LayoutGrid() end)

  function s:LayoutGrid()
    local w, h = self.grid:GetWidth(), self.grid:GetHeight()
    if w < 100 or h < 100 then return end
    local cols = w > 640 and 3 or 2   -- three columns from the minimum width up, so rows stay tall
    local rows = math.ceil(Logic.ITEM_COUNT / cols)
    local rowH = math.min(26, math.floor(h / rows))
    local colW = math.floor(w / cols)
    for i, b in ipairs(self.boxes) do
      local col, row = math.floor((i - 1) / rows), (i - 1) % rows
      b.num:ClearAllPoints(); b.num:SetPoint("TOPLEFT", col * colW, -(row * rowH) - 5)
      b.box:ClearAllPoints(); b.box:SetPoint("TOPLEFT", col * colW + 26, -(row * rowH)); b.box:SetSize(colW - 36, rowH - 3)
    end
  end

  function s:Items()
    local items = {}
    for i, b in ipairs(self.boxes) do items[i] = b.box:GetText() end
    return items
  end

  function s:SetItems(items)
    for i, b in ipairs(self.boxes) do b.box:SetText(items and items[i] or "") end
    self:Validate()
  end

  function s:Validate()
    local check = Logic.checkItems(self:Items())
    local bad = {}
    for _, p in ipairs(check.problems) do bad[p.index + 1] = p.kind end
    local warn = {}
    for _, p in ipairs(check.warnings) do warn[p.index + 1] = true end
    for i, b in ipairs(self.boxes) do
      if bad[i] == "duplicate" or bad[i] == "too-long" then W.borderRole(b.box.border, "gold")
      elseif b.box:HasFocus() then W.borderRole(b.box.border, "gold")
      else W.borderRole(b.box.border, "line") end
      Theme.set(b.num, warn[i] and "gold" or "inkFaint")
    end
    self.valid = check.ok and Logic.validateTitle(self.title:GetText()).ok
    local footer = win.footer
    if win.view == "setup" then
      footer.action:SetEnabledState(self.valid)
      if not check.ok then
        local empties = 0
        for _, p in ipairs(check.problems) do if p.kind == "empty" then empties = empties + 1 end end
        if empties > 0 then footer.text:SetText(("%d of 24 squares filled"):format(check.filled))
        else footer.text:SetText(check.problems[1].message) end
      elseif not Logic.validateTitle(self.title:GetText()).ok then
        footer.text:SetText("Give the game a title.")
      else
        if self.audience == "G" then
          footer.text:SetText("Opens for everyone online in the guild.")
        else
          local strangers = app.nonGuildInGroup and app.nonGuildInGroup() or 0
          if strangers > 0 then
            footer.text:SetText(("Opens for everyone in your group. %d of them %s not in your guild and will see the squares."):format(strangers, strangers == 1 and "is" or "are"))
          else
            footer.text:SetText("Opens for everyone in your group, guests included.")
          end
        end
      end
    end
    return check
  end

  function s:Refresh()
    local inGuild = not app.inGuild or app.inGuild()
    if not inGuild and self.audience == "G" then self.audience = "R" end
    self.guildBtn:SetEnabledState(inGuild)
    self.guildBtn:SetSelected(self.audience == "G")
    self.raidBtn:SetSelected(self.audience == "R")
    if not inGuild then
      self.audienceHint:SetText("You are not in a guild, so the game is for your group.")
    else
      self.audienceHint:SetText(self.audience == "G" and "Guild members anywhere, no strangers." or "Anyone grouped with you, pugs included.")
    end
    -- start-from row: paste, the shipped presets, and one button for the picker
    local sources = app.itemSets()
    for _, b in ipairs(self.fromButtons) do b:Hide() end
    self.pasteBtn:ClearAllPoints()
    self.pasteBtn:SetPoint("TOPLEFT", self.fromLabel, "BOTTOMLEFT", 0, -4)
    local x, n, saved = 156, 0, 0
    for _, src in ipairs(sources) do
      if src.saved then
        saved = saved + 1
      else
        n = n + 1
        local b = self.fromButtons[n]
        if not b then
          b = W.button(self, "", function(btn) self:SetItems(btn.items) end, { width = 150, height = 26, font = W.fonts().small })
          self.fromButtons[n] = b
        end
        b.items = src.items
        b:SetLabel(src.name)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", self.fromLabel, "BOTTOMLEFT", x, -4)
        b:Show()
        x = x + 156
      end
    end
    self.previousBtn:ClearAllPoints()
    self.previousBtn:SetPoint("TOPLEFT", self.fromLabel, "BOTTOMLEFT", x, -4)
    self.previousBtn:SetLabel(saved == 0 and "Previous games" or ("Previous games (" .. saved .. ")…"))
    self.previousBtn:SetEnabledState(saved > 0)
    self:Validate()
  end

  s.title:SetScript("OnTextChanged", function() s:Validate() end)
  return s
end

-- Turn pasted text into up to 24 clean, distinct squares.
function Window.parseList(text)
  local out, seen = {}, {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    line = line:gsub("^%s*[%d]+[%.%)%-:]%s*", ""):gsub("^%s*[%-%*•]%s*", "")
    line = Logic.cleanText(line)
    if line ~= "" and not seen[line:lower()] and #out < Logic.ITEM_COUNT then
      seen[line:lower()] = true
      out[#out + 1] = line
    end
  end
  return out
end

-- History: finished games, newest first; each opens read-only.
local function buildHistory(f)
  local h = CreateFrame("Frame", nil, f)
  h:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -TOP)
  h:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, FOOTER)
  h.head = W.text(h, W.fonts().eyebrow, "inkFaint")
  h.head:SetPoint("TOPLEFT", PAD + 2, -PAD - 4)
  h.head:SetText("PAST GAMES")
  h.empty = W.text(h, W.fonts().body, "inkDim", "CENTER")
  h.empty:SetPoint("CENTER", 0, 20)
  h.empty:SetText("No finished games on this character yet.")
  h.list = scrollList(h, 64, function(parent)
    local row = W.panel(parent, "raised")
    row.title = W.text(row, W.fonts().title, "ink"); row.title:SetPoint("TOPLEFT", 12, -10); row.title:SetPoint("RIGHT", -150, 0)
    row.meta = W.text(row, W.fonts().small, "inkDim"); row.meta:SetPoint("BOTTOMLEFT", 12, 10); row.meta:SetPoint("RIGHT", -150, 0)
    row.button = W.button(row, "Open", function(self) local r = self:GetParent(); if r.entry then win.historyGid = r.entry.gid; Window.show("game") end end, { width = 110, height = 28 })
    row.button:SetPoint("RIGHT", -12, 0)
    return row
  end)
  h.list:SetPoint("TOPLEFT", PAD, -(PAD + 24))
  h.list:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  return h
end

-- Options: a few toggles, no slash commands needed.
-- There is no "Chad mode". It was considered. It would just be light mode with more complaints.
local OPTIONS = {
  { key = "theme", label = "Theme", kind = "choice", choices = { { "dark", "Dark" }, { "light", "Light" } }, default = "dark",
    hint = "Dark is deep stone, light is aged vellum, both from the website." },
  { key = "sounds", label = "Sounds", kind = "bool", default = true, hint = "A soft tick on a call, a chime for your bingo." },
  { key = "quietInCombat", label = "Quiet in combat", kind = "bool", default = true, hint = "No sounds while you are fighting. Calls still show on the chip." },
  { key = "chipHidden", label = "Hide the chip", kind = "bool", default = false, invert = true, hint = "The one-line board at the top of the screen while a game is open." },
  { key = "minimapHidden", label = "Hide the minimap button", kind = "bool", default = false, hint = "Click it to open the board, right-click for options. Drag it around the minimap." },
  { key = "chipLocked", label = "Lock the chip", kind = "bool", default = false, hint = "Stops the chip from being dragged." },
  { key = "reducedMotion", label = "Reduce motion", kind = "bool", default = false, hint = "No chip flash or badge pulse; toasts still appear." },
  { key = "clearHistory", label = "Clear history", kind = "action", button = "Clear",
    hint = "Forgets every finished game kept on this character. Item sets stay.",
    confirm = { "CLEAR HISTORY", "Every finished game kept on this character is forgotten. Live games and your saved squares are not touched.", "Clear it" } },
}

local function buildOptions(f)
  local o = CreateFrame("Frame", nil, f)
  o:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -TOP)
  o:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, FOOTER)
  o.head = W.text(o, W.fonts().eyebrow, "inkFaint")
  o.head:SetPoint("TOPLEFT", PAD + 2, -PAD - 4)
  o.head:SetText("OPTIONS")
  -- The installed version, top right; gold with the newer one when a newer release was heard.
  o.version = W.text(o, W.fonts().small, "inkFaint", "RIGHT")
  o.version:SetPoint("TOPRIGHT", -PAD - 2, -PAD - 4)
  -- The rows scroll: at the minimum window height they are taller than the panel.
  o.list = scrollList(o, 58, function(parent)
    local row = CreateFrame("Frame", nil, parent)
    row.rule = row:CreateTexture(nil, "BORDER"); Theme.register(row.rule, "line", "bg")
    row.rule:SetPoint("BOTTOMLEFT"); row.rule:SetPoint("BOTTOMRIGHT"); row.rule:SetHeight(W.px(1))
    row.label = W.text(row, W.fonts().bodyBold, "ink"); row.label:SetPoint("TOPLEFT", 2, -10)
    row.hint = W.text(row, W.fonts().small, "inkFaint"); row.hint:SetPoint("BOTTOMLEFT", 2, 10); row.hint:SetPoint("RIGHT", -220, 0)
    row.actionButton = W.button(row, "", function()
      local def = row.def
      local run = function() app.action(def.key); Window.refresh() end
      if def.confirm then Window.confirm(def.confirm[1], def.confirm[2], def.confirm[3], run) else run() end
    end, { width = 110, height = 26 })
    row.actionButton:SetPoint("RIGHT", 0, 0)
    row.values = {}     -- value buttons, made as needed
    row.buttons = {}    -- the value buttons in use for this row's option
    return row
  end)
  o.list:SetPoint("TOPLEFT", PAD, -(PAD + 30))
  o.list:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  local function fill(row, def)
    row.def = def
    row.label:SetText(def.label)
    row.hint:SetText(def.hint)
    row.actionButton:Hide(); row.action = nil
    for _, b in ipairs(row.values) do b:Hide() end
    row.buttons = {}
    if def.kind == "action" then
      row.actionButton:SetLabel(def.button); row.actionButton:Show()
      row.action = row.actionButton
    else
      local choices = def.kind == "choice" and def.choices or { { true, "On" }, { false, "Off" } }
      local x = 0
      for j = #choices, 1, -1 do
        local k = #choices - j + 1
        local b = row.values[k]
        if not b then
          b = W.button(row, "", function(self) app.setOption(row.def.key, self.value); Window.refresh() end, { width = 86, height = 26 })
          row.values[k] = b
        end
        b:SetLabel(choices[j][2]); b.value = choices[j][1]
        b:ClearAllPoints(); b:SetPoint("RIGHT", -x, 0); b:Show()
        row.buttons[#row.buttons + 1] = b
        x = x + 92
      end
    end
    local current = app.option(def.key)
    if current == nil then current = def.default end
    for _, b in ipairs(row.buttons) do b:SetSelected(b.value == current) end
  end
  o.rows = {}
  function o:Refresh()
    self.list:Fill(OPTIONS, fill)
    self.rows = self.list.rows
    local mine = app.version and app.version()
    local newer = app.newerVersion and app.newerVersion()
    if mine and newer then
      self.version:SetText(("%s  ·  %s available"):format(mine, newer))
      Theme.set(self.version, "gold")
    else
      self.version:SetText(mine or "")
      Theme.set(self.version, "inkFaint")
    end
  end
  return o
end

------------------------------------------------------------------ window

function Window.init(callbacks)
  app = callbacks
  if win then return win end
  W.updatePixel()

  win = CreateFrame("Frame", "DEABingoFrame", UIParent)
  win:SetFrameStrata("MEDIUM")
  win:SetSize(880, 620)
  win:SetResizable(true)
  if win.SetResizeBounds then win:SetResizeBounds(Window.MIN_W, Window.MIN_H) end
  win.bg = W.rect(win, "bg"); win.bg:SetAllPoints()
  win.border = W.border(win, "lineStrong")
  win.shadow = win:CreateTexture(nil, "BACKGROUND", nil, -1)
  Theme.register(win.shadow, "shadow", "bg")
  win.shadow:SetPoint("TOPLEFT", -1, 1); win.shadow:SetPoint("BOTTOMRIGHT", 3, -4)
  W.draggable(win, app.savePosition)
  W.restorePosition(win, app.position(), { point = "CENTER" })
  tinsert(UISpecialFrames, "DEABingoFrame")

  win.header = buildHeader(win)
  win.tabs = buildTabs(win)
  win.footer = buildFooter(win)
  win.views = { game = buildGame(win), lobby = buildLobby(win), setup = buildSetup(win), history = buildHistory(win), options = buildOptions(win) }
  hideAll(win.views)

  -- resize grip: a generous corner target with two diagonal hairlines
  win.grip = CreateFrame("Button", nil, win)
  win.grip:SetSize(26, 26)
  win.grip:SetPoint("BOTTOMRIGHT", -2, 2)
  win.grip.lines = {
    W.line(win.grip, -8, -8, 8, 8, "inkFaint", 2, "OVERLAY"),
    W.line(win.grip, -2, -8, 8, 2, "inkFaint", 2, "OVERLAY"),
  }
  win.grip:SetScript("OnEnter", function(self) for _, t in ipairs(self.lines) do Theme.set(t, "gold") end end)
  win.grip:SetScript("OnLeave", function(self) for _, t in ipairs(self.lines) do Theme.set(t, "inkFaint") end end)
  W.tooltip(win.grip, function() return { "Drag to resize" } end)
  -- Manual sizing: the grip tracks the cursor itself, so the window grows
  -- only right and down from its pinned top-left, whatever it was anchored
  -- to and whatever the UI scale.
  local MIN_W, MIN_H = Window.MIN_W, Window.MIN_H
  win.grip:SetScript("OnMouseDown", function(self)
    local left, top = win:GetLeft(), win:GetTop()
    if left and top then
      win:ClearAllPoints()
      win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    local cx, cy = GetCursorPosition()
    local scale = win:GetEffectiveScale()
    self.sizing = { cx = cx / scale, cy = cy / scale, w = win:GetWidth(), h = win:GetHeight() }
    self:SetScript("OnUpdate", function(grip)
      local s = grip.sizing
      if not s then return end
      local x, y = GetCursorPosition()
      x, y = x / scale, y / scale
      win:SetSize(math.max(MIN_W, s.w + (x - s.cx)), math.max(MIN_H, s.h - (y - s.cy)))
    end)
  end)
  win.grip:SetScript("OnMouseUp", function(self)
    self.sizing = nil
    self:SetScript("OnUpdate", nil)
    local point, _, relPoint, x, y = win:GetPoint(1)
    app.savePosition({ point = point, relPoint = relPoint, x = x, y = y, w = win:GetWidth(), h = win:GetHeight() })
  end)
  win:SetScript("OnSizeChanged", function()
    if win.views.game:IsShown() then win.views.game.board:Layout() end
    if win.views.setup:IsShown() then win.views.setup:LayoutGrid() end
    -- the lists (lobby, history, options) follow the width on their own
  end)

  -- The sheet: a modal card over the window with one square's full text,
  -- for players who cannot call. Callers act on the board itself.
  local sh = CreateFrame("Button", nil, win)
  sh:SetAllPoints(win)
  sh:SetFrameLevel((win:GetFrameLevel() or 0) + 20)
  sh.scrim = W.rect(sh, "scrim"); sh.scrim:SetAllPoints()
  sh:SetScript("OnClick", function() sh:Hide() end)
  sh.card = W.panel(sh, "raised")
  sh.card:SetSize(420, 220)
  sh.card:SetPoint("CENTER", 0, 20)
  sh.card:EnableMouse(true)
  sh.card.eyebrow = W.text(sh.card, W.fonts().eyebrow, "inkFaint")
  sh.card.eyebrow:SetPoint("TOPLEFT", 18, -16)
  sh.card.phrase = W.text(sh.card, W.fonts().phrase, "ink", "CENTER")
  sh.card.phrase:SetPoint("TOPLEFT", 18, -40); sh.card.phrase:SetPoint("TOPRIGHT", -18, -40)
  sh.card.phrase:SetHeight(90)
  sh.card.phrase:SetJustifyV("MIDDLE")
  sh.card.phrase:SetWordWrap(true)
  sh.card.cancel = W.button(sh.card, "Close", function() sh:Hide() end, { width = 100, height = 30 })
  sh.card.cancel:SetPoint("BOTTOMRIGHT", -16, 14)
  sh:Hide()
  win.sheetFrame = sh

  -- A generic confirmation card for actions that cannot be taken back.
  local cf = CreateFrame("Button", nil, win)
  cf:SetAllPoints(win)
  cf:SetFrameLevel((win:GetFrameLevel() or 0) + 22)
  cf.scrim = W.rect(cf, "scrim"); cf.scrim:SetAllPoints()
  cf:SetScript("OnClick", function() cf:Hide() end)
  cf.card = W.panel(cf, "raised")
  cf.card:SetSize(440, 190)
  cf.card:SetPoint("CENTER", 0, 20)
  cf.card:EnableMouse(true)
  cf.card.eyebrow = W.text(cf.card, W.fonts().eyebrow, "inkFaint"); cf.card.eyebrow:SetPoint("TOPLEFT", 18, -16)
  cf.card.text = W.text(cf.card, W.fonts().body, "ink"); cf.card.text:SetPoint("TOPLEFT", 18, -38); cf.card.text:SetPoint("TOPRIGHT", -18, -38)
  cf.card.text:SetHeight(80); cf.card.text:SetJustifyV("TOP"); cf.card.text:SetWordWrap(true)
  cf.card.confirm = W.button(cf.card, "", function() if cf.onConfirm then cf.onConfirm() end; cf:Hide() end, { width = 160, height = 30, primary = true })
  cf.card.confirm:SetPoint("BOTTOMRIGHT", -16, 14)
  cf.card.cancel = W.button(cf.card, "Cancel", function() cf:Hide() end, { width = 100, height = 30 })
  cf.card.cancel:SetPoint("RIGHT", cf.card.confirm, "LEFT", -8, 0)
  cf:Hide()
  win.confirmFrame = cf

  win:SetScript("OnShow", function() Window.refresh(); if app.onShown then app.onShown() end end)
  win:SetScript("OnHide", function() sh:Hide() end)
  win:Hide()
  return win
end

-- Open the sheet for item idx (0-based) in the current game.
function Window.confirm(eyebrow, text, label, fn)
  if not win then return end
  local cf = win.confirmFrame
  cf.card.eyebrow:SetText(eyebrow)
  cf.card.text:SetText(text)
  cf.card.confirm:SetLabel(label)
  cf.onConfirm = fn
  cf:Show()
end

function Window.sheet(idx)
  local v = win and win.currentView
  if not v then return end
  local sh = win.sheetFrame
  local called = v.called[idx] == true
  local text = v.items and v.items[idx + 1] or ("Square #" .. (idx + 1))
  sh.idx = idx
  sh.card.phrase:SetText(Logic.escape(text))
  local when
  for _, c in ipairs(v.calls) do if c.idx == idx then when = c.t end end
  sh.card.eyebrow:SetText(called and ("CALLED AT " .. W.clock(when)) or "SQUARE")
  sh:Show()
end

function Window.toggle()
  if not win then return end
  if win:IsShown() then win:Hide() else win:Show() end
end

function Window.show(view)
  if not win then return end
  if view then win.view = view end
  if view ~= "game" then win.historyGid = nil end
  win:Show()
  Window.refresh()
end

function Window.isShown() return win and win:IsShown() end
function Window.frame() return win end

-- In combat the window dims and takes no clicks. EnableMouse(false) on a
-- parent does not reach its children, so a mouse-enabled scrim does it.
function Window.setCombat(inCombat)
  if not win then return end
  win:SetAlpha(inCombat and 0.4 or 1)
  if not win.combatScrim then
    local sc = CreateFrame("Button", nil, win)
    sc:SetAllPoints(win)
    sc:SetFrameLevel((win:GetFrameLevel() or 0) + 40)
    sc:EnableMouse(true)
    sc:RegisterForClicks("AnyUp")
    sc:SetScript("OnClick", function() end)   -- swallow
    sc:Hide()
    win.combatScrim = sc
  end
  if inCombat then win.combatScrim:Show() else win.combatScrim:Hide() end
end

-------------------------------------------------------------------- views

local function renderLobby()
  local l = win.views.lobby
  local rows = app.lobby()
  win.header.title:SetText("Raid Bingo")
  win.header.status:SetText(#rows == 0 and "" or (#rows == 1 and "1 open game" or (#rows .. " open games")))
  l.list:Fill(rows, function(row, g)
    row.game = g
    row.title:SetText(Logic.escape(g.title))
    local bits = { "by " .. g.ownerShort, g.players == 1 and "1 player" or (g.players .. " players"), g.calls == 1 and "1 call" or (g.calls .. " calls") }
    if g.hostAway then bits[#bits + 1] = "host away" end
    if g.audience == "R" then bits[#bits + 1] = "raid" end
    row.meta:SetText(table.concat(bits, "  ·  "))
    row.button:SetLabel(g.mine and (g.state == "drafting" and "Continue" or "Open") or (g.joined and "Open" or "Join"))
  end)
  if #rows == 0 then l.empty:Show() else l.empty:Hide() end
  win.footer:Quip(true)
  win.footer.action:Show()
  win.footer.action:SetLabel("Start a game")
  win.footer.action:SetEnabledState(true)
  win.footer.action:SetScript("OnClick", function() Window.show("setup") end)
end

local function renderSetup()
  win.footer:Quip(false)
  local s = win.views.setup
  win.header.title:SetText("New game")
  win.header.status:SetText("")
  if not s.populated then
    s.populated = true
    s.title:SetText(date("%A") .. " raid")
    s.audience = app.defaultAudience and app.defaultAudience() or "G"
    s:SetItems(nil)
  end
  s:Refresh()
  s:LayoutGrid()
  win.footer.action:Show()
  win.footer.action:SetLabel("Open the game")
  win.footer.action:SetScript("OnClick", function()
    local check = s:Validate()
    if not s.valid then return end
    local okay, err = app.create({ title = s.title:GetText(), items = check.items, audience = s.audience })
    if okay then s.populated = false; Window.show("game") else win.footer.text:SetText(tostring(err)) end
  end)
end

local function renderGame(v)
  win.footer:Quip(false)
  local g = win.views.game
  win.currentView = v
  win.header.title:SetText(Logic.escape(v.title))
  local status
  if v.state == "closed" then status = "Closed"
  elseif v.hostAway then status = "Host away"
  else status = "Live" end
  status = status .. ("  ·  %d/24 called"):format(v.callCount)
  if v.board then
    if v.hasBingo then status = status .. "  ·  BINGO" else status = status .. ("  ·  %d away"):format(v.away) end
  end
  win.header.status:SetText(status)

  g.board:SetView(v)

  g.standings.count:SetText(v.players == 1 and "1 player" or (v.players .. " players"))
  g.standings.list:Fill(v.standings, function(row, p)
    row.player = p
    row.rank:SetText(p.rank and tostring(p.rank) or "")
    row.name:SetText(Logic.escape(p.shortName))
    Theme.set(row.name, p.isMe and "gold" or "ink")
    row.meter:Set(p.bestLine, p.bingoAt ~= nil)
    row.time:SetText(p.bingoAt and W.clock(p.bingoAt) or "")
    row.flag:SetText(p.canCall and "CALLER" or "")
  end)
  if g.peek:IsShown() then
    if g.peek.row and g.peek.row:IsShown() then g:Peek(g.peek.row) else g.peek:Hide() end
  end

  g.log.count:SetText(v.callCount == 0 and "" or tostring(v.callCount))
  local canCall = v.canCall and v.state == "open" and v.items ~= nil
  if not canCall then g.railMode = "log" end
  if canCall then
    g.log.head:Hide(); g.log.modeLog:Show(); g.log.modeCall:Show()
    Theme.set(g.log.modeLog, g.railMode == "log" and "ink" or "inkFaint")
    Theme.set(g.log.modeCall, g.railMode == "call" and "ink" or "inkFaint")
  else
    g.log.head:Show(); g.log.modeLog:Hide(); g.log.modeCall:Hide()
  end
  if g.railMode == "call" then
    g.log.list:Hide(); g.log.empty:Hide()
    g.log.filter:Show(); g.log.caller:Show()
    local needle = (g.log.filter:GetText() or ""):lower()
    if needle == "" then g.log.filterHint:Show() else g.log.filterHint:Hide() end
    local rows = {}
    for i, text in ipairs(v.items) do
      if needle == "" or text:lower():find(needle, 1, true) then
        rows[#rows + 1] = { idx = i - 1, text = text, called = v.called[i - 1] == true }
      end
    end
    table.sort(rows, function(a, b) return a.text:lower() < b.text:lower() end)
    local when = {}
    for _, c in ipairs(v.calls) do when[c.idx] = c.t end
    g.log.caller:Fill(rows, function(row, r)
      row.idx, row.called = r.idx, r.called
      row.text:SetText(Logic.escape(r.text))
      Theme.set(row.text, r.called and "fel" or "ink")
      row.time:SetText(r.called and W.clock(when[r.idx]) or "")
      if r.called then row.mark:Show() else row.mark:Hide() end
    end)
  else
    g.log.filter:Hide(); g.log.filterHint:Hide(); g.log.caller:Hide()
    g.log.list:Show()
    g.log.list:Fill(v.calls, function(row, c)
      row.time:SetText(W.clock(c.t))
      row.text:SetText(Logic.escape(c.text or ("#" .. (c.idx + 1))))
    end)
    if v.callCount == 0 then g.log.empty:Show() else g.log.empty:Hide() end
  end

  local f = win.footer
  if v.history then
    f.text:SetText(("Closed %s. Hosted by %s."):format(v.closedAt and date("%a %d %b, %H:%M", v.closedAt) or "", v.ownerShort))
    f.action:Show(); f.action:SetLabel("Back to history"); f.action:SetEnabledState(true)
    f.action:SetScript("OnClick", function() Window.show("history") end)
  elseif v.state == "closed" then
    f.text:SetText("This game is closed. It stays readable under History.")
    f.action:Hide()
  elseif v.canCall then
    f.text:SetText(v.isHost and "You are calling. Click a square to call it; click a called square to undo. Right-click a name to let them call."
                              or "You can call. Click a square to call it; click a called square to undo.")
    if v.isHost then
      f.action:Show(); f.action:SetLabel("Close game"); f.action:SetEnabledState(true)
      f.action:SetScript("OnClick", function()
        if f.confirmClose then app.close(); f.confirmClose = nil
        else
          f.confirmClose = true
          f.action:SetLabel("Really close?")
          C_Timer.After(4, function()
            f.confirmClose = nil
            -- only if the footer still belongs to this live, hosted game
            local cur = win.currentView
            if win.view == "game" and not win.historyGid and cur and cur.isHost and cur.state == "open" and f.action:IsShown() then
              f.action:SetLabel("Close game")
            end
          end)
        end
      end)
    else
      f.action:Hide()
    end
  else
    f.text:SetText(v.ownerShort .. " is calling.")
    f.action:Hide()
  end
end

local function renderHistory()
  local h = win.views.history
  local rows = app.history()
  win.header.title:SetText("History")
  win.header.status:SetText(#rows == 0 and "" or (#rows .. " kept"))
  h.list:Fill(rows, function(row, e)
    row.entry = e
    row.title:SetText(Logic.escape(e.title or ""))
    local winners = {}
    for name, p in pairs(e.roster or {}) do if p.bingoAt then winners[#winners + 1] = { name = View.shortName(name), t = p.bingoAt } end end
    table.sort(winners, function(a, b) return a.t < b.t end)
    local names = {}
    for i = 1, math.min(3, #winners) do names[i] = winners[i].name end
    local players = 0 for _ in pairs(e.roster or {}) do players = players + 1 end
    local calls = 0 for _ in pairs(e.calls or {}) do calls = calls + 1 end
    local bits = { e.closedAt and date("%a %d %b", e.closedAt) or "", players .. (players == 1 and " player" or " players"), calls .. (calls == 1 and " call" or " calls") }
    if #winners > 0 then bits[#bits + 1] = "bingo: " .. table.concat(names, ", ") .. (#winners > 3 and (" +" .. (#winners - 3)) or "") end
    row.meta:SetText(Logic.escape(table.concat(bits, "  ·  ")))
  end)
  if #rows == 0 then h.empty:Show() else h.empty:Hide() end
  win.footer:Quip(true)
  win.footer.action:Hide()
end

local function renderOptions()
  win.header.title:SetText("Options")
  win.header.status:SetText("")
  win.views.options:Refresh()
  win.footer:Quip(true)
  win.footer.action:Hide()
end

function Window.refresh()
  if not win or not win:IsShown() then return end
  win.footer.confirmClose = nil   -- a half-finished "Really close?" never survives a re-render
  local v
  if win.historyGid then
    v = app.historyView(win.historyGid)
    if not v then win.historyGid = nil end
  end
  v = v or app.view()
  local view = win.view
  if not view then view = v and "game" or "lobby" end
  if view == "game" and not v then view = "lobby" end
  win.view = view
  hideAll(win.views)
  win.views[view]:Show()
  -- tabs: the Game tab exists only while in a live game; a history entry
  -- shown as a board belongs to the History tab
  local live = app.view()
  win.tabs:Layout(live ~= nil)
  local active = view
  if view == "setup" then active = "lobby" end
  if view == "game" and win.historyGid then active = "history" end
  win.tabs:SetActive(active)
  if view == "lobby" then renderLobby()
  elseif view == "setup" then renderSetup()
  elseif view == "history" then renderHistory()
  elseif view == "options" then renderOptions()
  else renderGame(v) end
end
