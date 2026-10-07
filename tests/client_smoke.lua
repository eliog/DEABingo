-- Headless client smoke: two fake clients in one process load the real TOC files against
-- tests/widget_stub.lua and a loopback AceComm, then play a game and exercise every UI view.
-- Run with scripts/test.sh (it runs after the busted suite) or: luajit tests/client_smoke.lua
local chat = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat+1] = m; print("  chat> " .. m:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end }
_G.GetBuildInfo = function() return "1.60.1", "70245", "Oct 1 2026", 16001 end
_G.C_ChatInfo = { InChatMessagingLockdown = function() return false end }
_G.issecretvalue = function() return false end
_G.C_AddOns = { GetAddOnMetadata = function() return "@project-version@" end }
_G.strlenutf8 = function(s) local _, n = s:gsub("[^\128-\191]", ""); return n end
_G.GetTime = function() return 123.456 end
local clock = 1700000000
_G.GetServerTime = function() return clock end
_G.date = function(fmt, t) return "Tuesday" end
_G.LE_PARTY_CATEGORY_INSTANCE = 2
_G.IsInGuild = function() return true end
_G.IsInRaid = function() return true end
_G.IsInGroup = function(cat) return cat ~= 2 end
_G.GetNumGuildMembers = function() return 2 end
_G.GetGuildRosterInfo = function(i) return ({ "Dea One", "Dea Two" })[i] end
_G.GetNumGroupMembers = function() return 2 end
_G.GetNormalizedRealmName = function() return "ClassicBetaPvE2" end
_G.GetRealmName = function() return "Classic Beta PvE 2" end
_G.RegionalUniqueNamesEnabled = function() return true end
_G.UnitGUID = function() return "Player-4620-015DBDBD" end
_G.C_PlayerInfo = { ShouldDisplaySurname = function() return true end }
local timers = {}
_G.C_Timer = { NewTicker = function(_, fn) timers[#timers+1] = fn; return {} end, After = function(_, fn) fn() end }
_G.SlashCmdList = {}
local frames = {}

-- loopback AceComm shared by both clients
local inbox = {}
local handlers = {}
_G.LibStub = function(name, silent)
  if name ~= "AceComm-3.0" then return nil end
  return {
    RegisterComm = function(_, prefix, fn) handlers[#handlers+1] = fn end,
    SendCommMessage = function(_, prefix, text, dist, target, prio) inbox[#inbox+1] = { text = text, dist = dist, target = target } end,
  }
end

package.path = "./?.lua;" .. package.path
require("tests.widget_stub").install()
local files = { "Core/Logic.lua", "Core/Codec.lua", "Core/Host.lua", "Core/Mirror.lua", "Core/Net.lua", "Core/Store.lua", "Core/View.lua", "Core/Presets.lua", "Core/Compat.lua", "UI/Theme.lua", "UI/Widgets.lua", "UI/Board.lua", "UI/Window.lua", "UI/Chip.lua", "UI/Toast.lua", "Core/Init.lua" }

local function boot(myName, seedDB)
  local first = { Alpha = "Dea", Beta = "Dea" }
  local sur = { Alpha = "One", Beta = "Two" }
  local function who(unit) if unit == "player" then return myName end return ({ "Alpha", "Beta" })[tonumber(unit:match("%d+"))] end
  _G.UnitFullName = function(unit) local w = who(unit); return first[w], sur[w] end
  _G.UnitName = _G.UnitFullName
  _G.GetUnitName = function(unit, full) local w = who(unit); return first[w] .. " " .. sur[w] end
  _G.DEABingoDB, _G.DEABingoCharDB = seedDB, nil
  _G.SlashCmdList = {}
  frames, handlers = {}, {}
  -- capture event frames created during load
  local realCreate = CreateFrame
  _G.CreateFrame = function(kind, name, parent, template)
    local f = realCreate(kind, name, parent, template)
    f.events = {}
    f.RegisterEvent = function(self, e) self.events[e] = true end
    f.UnregisterEvent = function(self, e) self.events[e] = nil end
    frames[#frames+1] = f
    return f
  end
  local ns = {}
  for _, file in ipairs(files) do assert(loadfile(file))("DEABingo", ns) end
  _G.CreateFrame = realCreate
  local function fire(ev, ...) for _, f in ipairs(frames) do if f.events[ev] and f.__scripts and f.__scripts.OnEvent then f.__scripts.OnEvent(f, ev, ...) end end end
  fire("ADDON_LOADED", "DEABingo"); fire("PLAYER_LOGIN"); fire("PLAYER_ENTERING_WORLD")
  assert(ns.App.ready, myName .. " not ready")
  return { ns = ns, slash = SlashCmdList.DEABINGO, handler = handlers[1], name = first[myName] .. " " .. sur[myName], full = first[myName] .. " " .. sur[myName] .. "-ClassicBetaPvE2" }
end

-- #16: a game saved under an earlier form of the host's name resumes under the current one
local seededBoard = {} for i = 0, 23 do seededBoard[#seededBoard + 1] = i end table.insert(seededBoard, 13, -1)
local seedItems = {} for i = 1, 24 do seedItems[i] = "Seed " .. i end
local seeded = { hosted = { seeded1 = {
  gid = "seeded1", gen = 1, seq = 1, state = "open", title = "Seeded night", owner = "Dea One-ClassicBetaPvE2", audience = "R",
  createdAt = 1699999000, lastActivity = 1699999000, lastHeartbeat = 0, items = seedItems, itemsHash = "seed01", frozen = false,
  roster = { ["Dea One-ClassicBetaPvE2"] = { board = seededBoard, canCall = false, bingoAt = nil, joinedAt = 1699999000 } }, calls = {},
} } }
local alpha = boot("Alpha", seeded)
do
  local h = alpha.ns.App.hosts.seeded1
  assert(h, "seeded game did not resume for the short name")
  assert(h.record.owner == "Dea One", "owner not renamed: " .. tostring(h.record.owner))
  assert(h.record.roster["Dea One"], "roster key not renamed")
  assert(DEABingoCharDB.me == "Dea One", "learned name not remembered: " .. tostring(DEABingoCharDB.me))
  h:close()   -- out of the way for the rest of the run
  alpha.ns.App.current = nil
end
local beta = boot("Beta")
local clients = { alpha, beta }

local function pump()
  for _ = 1, 20 do
    local batch = inbox; inbox = {}
    if #batch == 0 then return end
    for _, m in ipairs(batch) do
      for _, c in ipairs(clients) do
        local hears = (m.dist == "WHISPER" and m.target == c.name) or (m.dist ~= "WHISPER")
        if hears then c.handler("DEABINGO", m.text, m.dist, (m.from or "?")) end
      end
    end
  end
end
-- stamp the sender like the server would
local rawSend = LibStub("AceComm-3.0").SendCommMessage
local current
_G.LibStub = function() return { RegisterComm = function() end, SendCommMessage = function(_, p, text, dist, target) inbox[#inbox+1] = { text = text, dist = dist, target = target, from = current } end } end

-- Rewire each client's transport to stamp its own name: simplest is to run commands with `current` set.
local function run(c, cmd) current = c.name; print("[" .. c.name .. "] /dea " .. cmd); c.slash(cmd); pump() end
local function tickAll(n) for _ = 1, n do clock = clock + 1; for _, c in ipairs(clients) do current = c.name; c.ns.App.tick(); pump() end end end

-- The AceComm object captured at load keeps the first LibStub's SendCommMessage; patch it to stamp senders.
for _, c in ipairs(clients) do
  -- reach the transport via Net deps
  c.ns.App.net.deps.transport.send = function(payload, channel, target, prio) inbox[#inbox+1] = { text = payload, dist = channel, target = target, from = c.name } end
end

run(alpha, "status")
run(alpha, "new Tuesday MC")
run(alpha, "item 3 Someone forgets the buff")
run(alpha, "item 4 Fake |cff00ff00link|r here")   -- a pipe is legal text; it must render literally
run(alpha, "open")
run(beta, "list")
-- beta should have been offered the game by a toast with a Join button
do
  local toast = beta.ns.Toast
  assert(toast, "toast module missing")
  local t = toast.show({ text = "probe", action = { label = "Join", fn = function() end } })
  assert(t and t.__shown, "toast did not show")
  -- #21: dragging a toast saves the stack's anchor
  t.GetCenter = function() return 640, 300 end
  t.GetTop = function() return 330 end
  t.__scripts.OnDragStop(t)
  local saved = beta.ns.App.store.db.options.toasts
  assert(saved and saved.point == "TOP" and saved.x == 640, "toast anchor not saved")
  t.action.__scripts.OnClick(t.action)
end
run(beta, "join 1")
tickAll(4)
run(beta, "status")
run(alpha, "status")
run(beta, "status")
run(beta, "board")
run(alpha, "call 3")
tickAll(1)
run(beta, "board")
run(alpha, "grant Dea Two")
tickAll(1)
run(beta, "call 5")
tickAll(1)
run(alpha, "standings")
-- #14: hand the game over through the client glue, then the new host calls
run(alpha, "transfer Dea Two")
tickAll(2)
do
  local gid = beta.ns.App.current
  assert(gid and beta.ns.App.hosts[gid], "beta did not become host")
  assert(alpha.ns.App.hosts[gid] == nil, "alpha still hosts the transferred game")
  assert(alpha.ns.App.mirror.games[gid] and alpha.ns.App.mirror.games[gid].joined, "alpha did not become a follower")
  run(beta, "call 6")
  tickAll(1)
  assert(alpha.ns.App.currentView().called[5], "old host did not see the new host's call")
end
run(beta, "undo 5")
tickAll(1)
-- UI exercise on both clients: window views, board, chip, setup validation, combat dim
for _, c in ipairs(clients) do
  current = c.name
  local Window, Chip, App = c.ns.Window, c.ns.Chip, c.ns.App
  Window.show("lobby"); Window.refresh()
  Window.show("setup"); Window.refresh()
  local setup = Window.frame().views.setup
  setup:SetItems(c.ns.PRESETS[1].items); setup.title:SetText("UI test"); setup:Validate(); setup:LayoutGrid()
  Window.show("game"); Window.refresh()
  local v = App.currentView()
  assert(v, c.name .. " has no view")
  Window.frame().views.game.board:SetView(v); Window.frame().views.game.board:Layout()
  -- #8: item text reaches the board escaped
  for _, cell in ipairs(Window.frame().views.game.board.cells) do
    if cell.item == 3 then
      assert(cell.text.__text == "Fake ||cff00ff00link||r here", "board cell text not escaped: " .. tostring(cell.text.__text))
    end
  end
  Chip.update(v); Chip.flash()
  -- hover + click a cell
  local cell = Window.frame().views.game.board.cells[1]
  cell.__scripts.OnEnter(cell); cell.__scripts.OnLeave(cell); cell.__scripts.OnClick(cell, "LeftButton")
  -- the sheet opened; confirm it, then open and cancel another
  local sh = Window.frame().sheetFrame
  assert(sh.__shown, "sheet did not open on click")
  sh.card.confirm.__scripts.OnClick(sh.card.confirm); pump()
  Window.sheet(cell.item); sh.card.cancel.__scripts.OnClick(sh.card.cancel)
  Window.setCombat(true)
  assert(Window.frame().combatScrim and Window.frame().combatScrim.__shown, "combat scrim not shown")
  Window.setCombat(false)
  assert(not Window.frame().combatScrim.__shown, "combat scrim still shown")
  -- #9: toasts queued during combat are capped
  _G.UnitAffectingCombat = function() return true end
  for i = 1, 12 do App.toast({ text = "queued " .. i }) end
  assert(#App.pendingToasts <= App.MAX_PENDING_TOASTS, "toast queue not capped: " .. #App.pendingToasts)
  _G.UnitAffectingCombat = function() return false end
  App.flushToasts()
  -- history and options views, and the paste parser
  -- #22: start closing, switch tabs, let the timer fire: the lobby button keeps its label
  do
    local vcur = App.currentView()
    if vcur and vcur.isHost and vcur.state == "open" then
      Window.show("game"); Window.refresh()
      local act = Window.frame().footer.action
      local fired
      local realAfter = C_Timer.After
      C_Timer.After = function(_, fn) fired = fn end
      act.__scripts.OnClick(act)
      assert(act.label.__text == "Really close?", "confirm label missing")
      C_Timer.After = realAfter
      Window.show("lobby"); Window.refresh()
      assert(Window.frame().footer.confirmClose == nil, "confirmClose survived a view change")
      fired()
      assert(act.label.__text == "Start a game", "timer relabelled the lobby button: " .. tostring(act.label.__text))
    end
  end
  Window.show("history"); Window.refresh()
  -- #19: a history board open, then the GAME tab: the live game shows, not the history one
  do
    local entries = App.ui.history()
    local hist = entries[1]
    if hist then
      Window.frame().historyGid = hist.gid; Window.show("game"); Window.refresh()
      assert(Window.frame().historyGid == hist.gid, "history board did not open")
      local gameTab = Window.frame().tabs.tabs.game
      gameTab.__scripts.OnClick(gameTab)
      assert(Window.frame().historyGid == nil, "GAME tab left the history board open")
      assert(Window.frame().view == "game", "GAME tab did not show the game")
    end
  end
  Window.show("options"); Window.refresh()
  local opt = Window.frame().views.options.rows[1].buttons[1]
  opt.__scripts.OnClick(opt)
  local parsed = Window.parseList("1. Alpha\n2) Beta\n- Gamma\n\nalpha\n• Delta")
  assert(#parsed == 4 and parsed[1] == "Alpha" and parsed[4] == "Delta", "paste parser")
  Window.show("setup"); Window.refresh()
  local st = Window.frame().views.setup
  st:OpenPaste(); st.pasteCard.card.edit:SetText("one\ntwo\nthree"); st.pasteCard.card.edit.__scripts.OnTextChanged(st.pasteCard.card.edit)
  -- #23: the cursor-follow handler scrolls a cursor below the visible area into view
  do
    local box, ed = st.pasteCard.card.box, st.pasteCard.card.edit
    box.__h = 100
    ed.__scripts.OnCursorChanged(ed, 0, -400, 10, 16)   -- cursor 400 px down, 16 px tall
    assert(box:GetVerticalScroll() == 316, "cursor not scrolled into view: " .. tostring(box:GetVerticalScroll()))
    ed.__scripts.OnCursorChanged(ed, 0, -10, 10, 16)
    assert(box:GetVerticalScroll() == 10, "cursor above view not scrolled back: " .. tostring(box:GetVerticalScroll()))
  end
  st.pasteCard.card.use.__scripts.OnClick(st.pasteCard.card.use)
  assert(st.boxes[3].box:GetText() == "three", "paste did not fill the squares")
  -- #20: the grid keeps legible rows at the minimum window height
  Window.frame():SetSize(Window.MIN_W, Window.MIN_H)
  st.grid.__h = Window.MIN_H - 54 - 32 - 44 - 190   -- roughly what the grid gets at the minimum
  st.grid.__w = Window.MIN_W - 28
  st:LayoutGrid()
  assert(st.boxes[1].box.__h >= 20, "setup rows too small at the minimum size: " .. tostring(st.boxes[1].box.__h))
  Window.frame():SetSize(880, 620)
  st:OpenPicker()
  local prow = st.pickerCard.card.list.rows[1]
  if prow and prow.set then prow.__scripts.OnClick(prow); assert(st.boxes[1].box:GetText() ~= "", "picker did not fill") end
  st.pickerCard:Hide()
  Window.show("game"); Window.refresh()
  -- caller panel: switch mode, filter, click a row (calls or undoes through App)
  local game = Window.frame().views.game
  if v.canCall then
    game.railMode = "call"; Window.refresh()
    game.log.filter:SetText("wipe"); Window.refresh()
    local row = game.log.caller.rows[1]
    assert(row and row.idx ~= nil, "caller row missing")
    row.__scripts.OnClick(row); pump()
    game.log.filter:SetText(""); game.railMode = "log"; Window.refresh()
  end
  c.ns.Theme.apply("light"); c.ns.Theme.apply("dark")
  pump()
end
run(alpha, "items")
run(alpha, "close")
tickAll(1)
run(beta, "status")
run(alpha, "net")

-- the footer's "Start a game" and setup create path
current = alpha.name
alpha.ns.Window.show("setup")
local AF = alpha.ns.Window.frame()
local setup = AF.views.setup
setup:SetItems(alpha.ns.PRESETS[1].items); setup.title:SetText("From the UI"); setup.audience = "R"; setup:Validate()
AF.footer.action.__scripts.OnClick(AF.footer.action)
pump()
local n = 0 for _ in pairs(alpha.ns.App.hosts) do n = n + 1 end

assert(alpha.ns.App.currentView().title == "From the UI", "setup did not create the game")
print("client smoke OK: protocol and UI executed headlessly")
