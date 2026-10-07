--[[
  The main window. Three views in one frame: the lobby (open games, start a
  game), setup (title, squares, audience), and the game (board, standings,
  call log). Movable, resizable, closes on Escape, dims in combat.

  The window never reaches into Host or Mirror directly: it renders a view
  model from Core/View and calls back into App for every action.
]]

local ADDON, ns = ...
local Logic, Theme, W, Board, View = ns.Logic, ns.Theme, ns.W, ns.Board, ns.View

local Window = {}
ns.Window = Window

local RAIL = 290
local PAD = 14
local HEADER = 54
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
    local target = math.min(max, math.max(0, self:GetVerticalScroll() - delta * rowHeight * 3))
    self:SetVerticalScroll(target)
    self:UpdateThumb()
  end)
  function scroll:UpdateThumb()
    local total, visible = self.child:GetHeight(), self:GetHeight()
    if total <= visible + 1 then self.thumb:Hide(); return end
    local trackH = visible - 4
    local thumbH = math.max(18, trackH * visible / total)
    local offset = (self:GetVerticalScroll() / (total - visible)) * (trackH - thumbH)
    self.thumb:ClearAllPoints()
    self.thumb:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -(2 + offset))
    self.thumb:SetHeight(thumbH)
    self.thumb:Show()
  end
  function scroll:Fill(items, fill)
    local width = self:GetWidth() - 20
    child:SetWidth(width)
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
    if self:GetVerticalScroll() > max then self:SetVerticalScroll(max) end
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

  h.wordmark = W.text(h, W.fonts().eyebrow, "inkFaint")
  h.wordmark:SetPoint("TOPLEFT", PAD, -11)
  h.wordmark:SetText("DEA BINGO")
  h.title = W.text(h, W.fonts().heading, "ink")
  h.title:SetPoint("BOTTOMLEFT", PAD, 9)
  h.title:SetText("")
  h.status = W.text(h, W.fonts().body, "inkDim", "RIGHT")
  h.status:SetPoint("RIGHT", -44, -2)
  h.close = W.closeButton(h, function() f:Hide() end)
  h.close:SetPoint("TOPRIGHT", -8, -8)
  return h
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
  b.action:SetPoint("RIGHT", -PAD, 0)
  b.action:Hide()
  return b
end

-- Game view: board on the left, rail on the right.
local function buildGame(f)
  local g = CreateFrame("Frame", nil, f)
  g:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER)
  g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, FOOTER)

  g.boardHolder = CreateFrame("Frame", nil, g)
  g.boardHolder:SetPoint("TOPLEFT", PAD, -PAD)
  g.boardHolder:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -(RAIL + PAD * 2), PAD)
  g.board = Board.new(g.boardHolder)
  g.board.frame:SetPoint("TOPLEFT")
  g.board.frame:SetPoint("BOTTOMRIGHT")
  g.board.onCellClick = function(idx, button, ctrl)
    if idx == nil then return end
    local v = win.currentView
    if not v or not v.canCall or v.state ~= "open" then return end
    if ctrl or button == "RightButton" then
      app.call(idx, v.called[idx] == true)
    end
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
  g.standings.list = scrollList(g.standings, 22, function(parent)
    local row = CreateFrame("Button", nil, parent)
    row.rank = W.text(row, W.fonts().bodyBold, "gold", "RIGHT"); row.rank:SetPoint("LEFT", 0, 0); row.rank:SetWidth(18)
    row.name = W.text(row, W.fonts().body, "ink"); row.name:SetPoint("LEFT", 24, 0); row.name:SetPoint("RIGHT", -120, 0)
    row.meter = W.meter(row); row.meter:SetPoint("RIGHT", -56, 0)
    row.time = W.text(row, W.fonts().small, "fel", "RIGHT"); row.time:SetPoint("RIGHT", -2, 0); row.time:SetWidth(50)
    row.flag = W.text(row, W.fonts().eyebrow, "inkFaint"); row.flag:SetPoint("RIGHT", row.meter, "LEFT", -6, 0)
    row:RegisterForClicks("RightButtonUp")
    row:SetScript("OnClick", function(self)
      local v = win.currentView
      if v and v.isHost and self.player and self.player.name ~= v.owner then
        app.grant(self.player.name, not self.player.canCall)
      end
    end)
    W.tooltip(row, function(self)
      local v = win.currentView
      if not self.player then return nil end
      local lines = { self.player.shortName }
      if self.player.bingoAt then lines[#lines + 1] = "Bingo at " .. W.clock(self.player.bingoAt) end
      lines[#lines + 1] = ("Best line %d of 5"):format(self.player.bestLine)
      if self.player.canCall then lines[#lines + 1] = "Can call squares" end
      if v and v.isHost and self.player.name ~= v.owner then
        lines[#lines + 1] = self.player.canCall and "Right-click to revoke calling" or "Right-click to let them call"
      end
      return lines
    end)
    return row
  end)
  g.standings.list:SetPoint("TOPLEFT", 8, -30)
  g.standings.list:SetPoint("BOTTOMRIGHT", -6, 8)

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
  return g
end

-- Lobby: open games and a start button.
local function buildLobby(f)
  local l = CreateFrame("Frame", nil, f)
  l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER)
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
  s:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -HEADER)
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
    local cols = w > 700 and 3 or 2
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
        footer.text:SetText(self.audience == "G" and "Opens for everyone online in the guild." or "Opens for everyone in your group, guests included.")
      end
    end
    return check
  end

  function s:Refresh()
    Theme.set(self.guildBtn.face, self.audience == "G" and "felWash" or "raised")
    W.borderRole(self.guildBtn.border, self.audience == "G" and "fel" or "lineStrong")
    Theme.set(self.raidBtn.face, self.audience == "R" and "felWash" or "raised")
    W.borderRole(self.raidBtn.border, self.audience == "R" and "fel" or "lineStrong")
    self.audienceHint:SetText(self.audience == "G" and "Guild members anywhere, no strangers." or "Anyone grouped with you, pugs included.")
    -- start-from buttons: presets and saved sets
    local sources = app.itemSets()
    for _, b in ipairs(self.fromButtons) do b:Hide() end
    local x = 0
    for i, src in ipairs(sources) do
      local b = self.fromButtons[i]
      if not b then
        b = W.button(self, "", function(btn) self:SetItems(btn.items); if self.title:GetText() == "" and btn.titleHint then self.title:SetText(btn.titleHint) end end, { width = 150, height = 26, font = W.fonts().small })
        self.fromButtons[i] = b
      end
      b.items = src.items
      b.titleHint = src.titleHint
      b:SetLabel(src.name)
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", self.fromLabel, "BOTTOMLEFT", x, -4)
      b:Show()
      x = x + 156
      if x > 760 then break end
    end
    self:Validate()
  end

  s.title:SetScript("OnTextChanged", function() s:Validate() end)
  return s
end

------------------------------------------------------------------ window

function Window.init(callbacks)
  app = callbacks
  if win then return win end
  W.updatePixel()

  win = CreateFrame("Frame", "DEABingoFrame", UIParent)
  win:SetFrameStrata("MEDIUM")
  win:SetSize(860, 580)
  win:SetResizable(true)
  if win.SetResizeBounds then win:SetResizeBounds(700, 470) end
  win.bg = W.rect(win, "bg"); win.bg:SetAllPoints()
  win.border = W.border(win, "lineStrong")
  win.shadow = win:CreateTexture(nil, "BACKGROUND", nil, -1)
  Theme.register(win.shadow, "shadow", "bg")
  win.shadow:SetPoint("TOPLEFT", -1, 1); win.shadow:SetPoint("BOTTOMRIGHT", 3, -4)
  W.draggable(win, app.savePosition)
  W.restorePosition(win, app.position(), { point = "CENTER" })
  tinsert(UISpecialFrames, "DEABingoFrame")

  win.header = buildHeader(win)
  win.footer = buildFooter(win)
  win.views = { game = buildGame(win), lobby = buildLobby(win), setup = buildSetup(win) }
  hideAll(win.views)

  -- resize grip
  win.grip = CreateFrame("Button", nil, win)
  win.grip:SetSize(16, 16)
  win.grip:SetPoint("BOTTOMRIGHT", -3, 3)
  win.grip.tex = win.grip:CreateTexture(nil, "OVERLAY"); Theme.register(win.grip.tex, "inkFaint", "bg")
  win.grip.tex:SetSize(10, W.px(2)); win.grip.tex:SetPoint("BOTTOMRIGHT", -1, 4); win.grip.tex:SetRotation(math.rad(-45))
  win.grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
  win.grip:SetScript("OnMouseUp", function()
    win:StopMovingOrSizing()
    local point, _, relPoint, x, y = win:GetPoint(1)
    app.savePosition({ point = point, relPoint = relPoint, x = x, y = y, w = win:GetWidth(), h = win:GetHeight() })
  end)
  win:SetScript("OnSizeChanged", function()
    if win.views.game:IsShown() then win.views.game.board:Layout() end
    if win.views.setup:IsShown() then win.views.setup:LayoutGrid() end
  end)

  win:SetScript("OnShow", function() Window.refresh() end)
  win:Hide()
  return win
end

function Window.toggle()
  if not win then return end
  if win:IsShown() then win:Hide() else win:Show() end
end

function Window.show(view)
  if not win then return end
  if view then win.view = view end
  win:Show()
  Window.refresh()
end

function Window.isShown() return win and win:IsShown() end
function Window.frame() return win end

function Window.setCombat(inCombat)
  if not win then return end
  win:SetAlpha(inCombat and 0.4 or 1)
  win:EnableMouse(not inCombat)
  for _, v in pairs(win.views) do v:EnableMouse(not inCombat) end
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
  win.footer.text:SetText("")
  win.footer.action:Show()
  win.footer.action:SetLabel("Start a game")
  win.footer.action:SetEnabledState(true)
  win.footer.action:SetScript("OnClick", function() Window.show("setup") end)
end

local function renderSetup()
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

  g.log.count:SetText(v.callCount == 0 and "" or tostring(v.callCount))
  g.log.list:Fill(v.calls, function(row, c)
    row.time:SetText(W.clock(c.t))
    row.text:SetText(Logic.escape(c.text or ("#" .. (c.idx + 1))))
  end)
  if v.callCount == 0 then g.log.empty:Show() else g.log.empty:Hide() end

  local f = win.footer
  if v.state == "closed" then
    f.text:SetText("This game is closed. The board stays readable.")
    f.action:Show(); f.action:SetLabel("Back to games"); f.action:SetEnabledState(true)
    f.action:SetScript("OnClick", function() app.leaveToLobby(); Window.show("lobby") end)
  elseif v.canCall then
    f.text:SetText(v.isHost and "You are calling. Ctrl-click a square to call it, Ctrl-click again to undo. Right-click a name to let them call."
                              or "You can call. Ctrl-click a square to call it, Ctrl-click again to undo.")
    if v.isHost then
      f.action:Show(); f.action:SetLabel("Close game"); f.action:SetEnabledState(true)
      f.action:SetScript("OnClick", function()
        if f.confirmClose then app.close(); f.confirmClose = nil
        else f.confirmClose = true; f.action:SetLabel("Really close?"); C_Timer.After(4, function() f.confirmClose = nil; if f.action:IsShown() then f.action:SetLabel("Close game") end end) end
      end)
    else
      f.action:Show(); f.action:SetLabel("Games"); f.action:SetEnabledState(true)
      f.action:SetScript("OnClick", function() Window.show("lobby") end)
    end
  else
    f.text:SetText(v.ownerShort .. " is calling.")
    f.action:Show(); f.action:SetLabel("Games"); f.action:SetEnabledState(true)
    f.action:SetScript("OnClick", function() Window.show("lobby") end)
  end
end

function Window.refresh()
  if not win or not win:IsShown() then return end
  local v = app.view()
  local view = win.view
  if not view then view = v and "game" or "lobby" end
  if view == "game" and not v then view = "lobby" end
  win.view = view
  hideAll(win.views)
  win.views[view]:Show()
  if view == "lobby" then renderLobby()
  elseif view == "setup" then renderSetup()
  else renderGame(v) end
end
