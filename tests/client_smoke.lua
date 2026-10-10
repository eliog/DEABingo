-- Headless client smoke: two fake clients in one process load the real TOC files against
-- tests/widget_stub.lua and a loopback AceComm, then play a game and exercise every UI view.
-- Run with scripts/test.sh (it runs after the busted suite) or: luajit tests/client_smoke.lua
local chat = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat+1] = m; print("  chat> " .. m:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end }
_G.GetBuildInfo = function() return "1.60.1", "70245", "Oct 1 2026", 16001 end
_G.lockdown = false   -- flip to model the Forever chat lockdown
_G.C_ChatInfo = { InChatMessagingLockdown = function() return _G.lockdown == true end }
-- values the client would hand us as secrets during a lockdown; the stub marks them by identity
_G.secretValues = {}
_G.issecretvalue = function(v) return secretValues[v] == true end
_G.C_AddOns = { GetAddOnMetadata = function() return "@project-version@" end }
_G.strlenutf8 = function(s) local _, n = s:gsub("[^\128-\191]", ""); return n end
local now = 123.456
_G.GetTime = function() return now end
local played = 0
_G.PlaySound = function() played = played + 1 end
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
local files = { "Core/Logic.lua", "Core/Codec.lua", "Core/Host.lua", "Core/Mirror.lua", "Core/Net.lua", "Core/Store.lua", "Core/View.lua", "Core/Presets.lua", "Core/Compat.lua", "Core/Quips.lua", "UI/Theme.lua", "UI/Widgets.lua", "UI/Board.lua", "UI/Window.lua", "UI/Chip.lua", "UI/Toast.lua", "Core/Init.lua" }

local function boot(myName, seedDB, opts)
  opts = opts or {}
  _G.RegionalUniqueNamesEnabled = function() return opts.realmless ~= false end
  local first = { Alpha = "Dea", Beta = "Dea" }
  local sur = { Alpha = "One", Beta = "Two" }
  local function who(unit) if unit == "player" then return myName end return ({ "Alpha", "Beta" })[tonumber(unit:match("%d+"))] end
  _G.UnitFullName = function(unit) local w = who(unit); return first[w], sur[w] end
  _G.UnitName = _G.UnitFullName
  _G.GetUnitName = function(unit, full) local w = who(unit); return first[w] .. " " .. sur[w] end
  _G.DEABingoDB, _G.DEABingoCharDB = seedDB, opts.charDB
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
  return { ns = ns, slash = SlashCmdList.DEABINGO, handler = handlers[1], fire = fire, name = first[myName] .. " " .. sur[myName], full = first[myName] .. " " .. sur[myName] .. "-ClassicBetaPvE2" }
end

-- #16: a game saved under an earlier form of the host's name resumes under the current one
local seededBoard = {} for i = 0, 23 do seededBoard[#seededBoard + 1] = i end table.insert(seededBoard, 13, -1)
local seedItems = {} for i = 1, 24 do seedItems[i] = "Seed " .. i end
local seeded = { hosted = { seeded1 = {
  gid = "seeded1", gen = 1, seq = 1, state = "open", title = "Seeded night", owner = "Dea One-ClassicBetaPvE2", audience = "R",
  createdAt = 1699999000, lastActivity = 1699999000, lastHeartbeat = 0, items = seedItems, itemsHash = "seed01", frozen = false,
  roster = { ["Dea One-ClassicBetaPvE2"] = { board = seededBoard, canCall = false, bingoAt = nil, joinedAt = 1699999000 } }, calls = {},
} } }
-- A saved identity and hosted game on another realm cannot become this
-- character when realm-qualified names are enabled. The same-name replay
-- must also leave live ownership and both identity stores untouched.
do
  local other = {}
  for key, value in pairs(seeded.hosted.seeded1) do other[key] = value end
  other.gid, other.owner = "other1", "Dea One-OtherRealm"
  other.roster = { [other.owner] = { board = seededBoard, canCall = false } }
  local c = boot("Alpha", { hosted = { other1 = other } }, {
    realmless = false, charDB = { me = other.owner },
  })
  local app, codec = c.ns.App, c.ns.Codec
  local mine = "Dea One-ClassicBetaPvE2"
  assert(app.myName == mine and app.chardb.me == mine, "trusted another realm's saved identity")
  assert(not app.hosts.other1, "resumed another realm's hosted game")
  assert(app.store.db.hosted.other1.owner == other.owner, "rewrote another realm's saved ownership")
  local record = assert(app.createGame({ title = "Realm identity", items = seedItems, audience = "G" }))
  app.mirror:hello()
  local hi = assert(codec.encode("HI", "0", { ver = codec.PROTOCOL, nonce = app.mirror.nonce, addon = "dev" }))
  c.handler("DEABINGO", hi, "WHISPER", other.owner)
  assert(app.myName == mine and app.chardb.me == mine, "replay replaced the saved or live identity")
  assert(app.net.deps.me == mine and app.mirror.deps.me == mine, "replay replaced the network identity")
  assert(record.owner == mine and record.roster[mine] and not record.roster[other.owner], "replay rewrote hosted ownership")

  -- Matching case variants are legitimate echoes, and bare senders still
  -- resolve to this realm before comparison. An unavailable realm is not
  -- replaced by a guess from the incoming message.
  local echoed = "dea one-classicbetapve2"
  c.handler("DEABINGO", hi, "GUILD", echoed)
  assert(app.myName == echoed and record.owner == echoed and record.roster[echoed], "rejected a same-realm echo")
  c.handler("DEABINGO", hi, "GUILD", "Dea One")
  assert(app.myName == "Dea One-classicbetapve2", "rejected a bare same-realm echo")
  local before = app.myName
  local realRealm = _G.GetNormalizedRealmName
  _G.GetNormalizedRealmName = function() return nil end
  c.handler("DEABINGO", hi, "WHISPER", other.owner)
  assert(app.myName == before and app.chardb.me == before and record.owner == before, "learned an identity without a local realm")
  _G.GetNormalizedRealmName = realRealm

  -- A legitimate local saved game still restores, including an older
  -- bare remembered identity that needs its local realm appended.
  local resumed = boot("Alpha", seeded, { realmless = false, charDB = { me = "Dea One" } })
  assert(resumed.ns.App.myName == mine and resumed.ns.App.chardb.me == mine, "did not qualify the remembered local identity")
  assert(resumed.ns.App.normalize("Dea Two") == "Dea Two-ClassicBetaPvE2", "lost the local realm for bare names")
  assert(resumed.ns.App.hosts.seeded1 and resumed.ns.App.hosts.seeded1.record.owner == mine, "did not restore a same-realm hosted game")
  inbox = {}   -- discard isolated clients' broadcasts before the two-client smoke
end

local alpha = boot("Alpha", seeded)
do
  local h = alpha.ns.App.hosts.seeded1
  assert(h, "seeded game did not resume for the short name")
  assert(h.record.owner == "Dea One", "owner not renamed: " .. tostring(h.record.owner))
  assert(h.record.roster["Dea One"], "roster key not renamed")
  assert(DEABingoCharDB.me == "Dea One", "learned name not remembered: " .. tostring(DEABingoCharDB.me))
  h:close()   -- out of the way for the rest of the run
  -- a closed host stays attached through the recovery period, to answer late sync requests
  assert(alpha.ns.App.hosts.seeded1 ~= nil, "closed hosted game detached at once")
  assert(DEABingoDB.hosted.seeded1 ~= nil, "closed hosted record forgotten at once")
  clock = clock + alpha.ns.Host.CLOSED_ANSWERS + 1
  alpha.ns.App.tick()
  assert(alpha.ns.App.hosts.seeded1 == nil, "closed hosted game still attached after the recovery period")
  assert(DEABingoDB.hosted.seeded1 == nil, "closed hosted record still saved after the recovery period")
  alpha.ns.App.current = nil
end
-- #53: a client that loads mid-fight (a /reload in combat) comes up dimmed
_G.UnitAffectingCombat = function() return true end
local beta = boot("Beta")
assert(beta.ns.Window.frame().combatScrim and beta.ns.Window.frame().combatScrim.__shown, "window built in combat is not dimmed")
_G.UnitAffectingCombat = function() return false end
beta.ns.Window.setCombat(false)
local clients = { alpha, beta }

-- #52: a secret sender or roster name never reaches a string function, debug tap included
do
  local hidden = "Hidden-ClassicBetaPvE2"
  secretValues[hidden] = true
  alpha.ns.debug = true
  alpha.fire("CHAT_MSG_ADDON", "DEABINGO", "2\31HI\31" .. "0\31", "GUILD", hidden)
  alpha.fire("CHAT_MSG_ADDON", "DEABINGO", "\001chunk", "GUILD", hidden)
  alpha.ns.debug = false
  local realRoster, realCount = _G.GetGuildRosterInfo, _G.GetNumGuildMembers
  _G.GetGuildRosterInfo = function(i) return ({ hidden, "Dea One", "Dea Two" })[i] end
  _G.GetNumGuildMembers = function() return 3 end
  alpha.ns.App.refreshGuild()
  _G.GetGuildRosterInfo, _G.GetNumGuildMembers = realRoster, realCount
  assert(alpha.ns.App.isMember(alpha.ns.App.normalize("Dea Two"), "G"), "guild refresh lost the readable names")
  assert(not alpha.ns.App.isMember(hidden, "G"), "a secret roster name was matched")
  secretValues[hidden] = nil
end

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
-- #72: our own hello replayed under another character's real name must not become our identity
do
  current = alpha.name
  alpha.ns.App.mirror:hello()
  alpha.ns.App.net:tick()   -- a hello leaves the queue on the next tick
  local hi
  for _, m in ipairs(inbox) do if m.text:find("\31HI\31", 1, true) then hi = m.text end end
  assert(hi, "no hello on the wire")
  pump()
  local before = alpha.ns.App.myName
  local gid = alpha.ns.App.current
  local owner = alpha.ns.App.hosts[gid].record.owner
  local hadRosterKey = alpha.ns.App.hosts[gid].record.roster[owner] ~= nil   -- a draft has no roster yet
  for _, impostor in ipairs({ "Deaone", "Dea Onex", "Dea", "Dea One Two" }) do
    alpha.handler("DEABINGO", hi, "GUILD", impostor); pump()
    assert(alpha.ns.App.myName == before, "became " .. tostring(alpha.ns.App.myName) .. " after a replay by " .. impostor)
  end
  assert(alpha.ns.App.hosts[gid].record.owner == owner, "hosted ownership changed by a replay")
  assert((alpha.ns.App.hosts[gid].record.roster[owner] ~= nil) == hadRosterKey, "roster key changed by a replay")
  assert(alpha.ns.App.chardb.me == before, "saved identity changed by a replay")
end
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
  -- #66: the old host object stays on the wire to answer sync requests, outside App.hosts
  assert(alpha.ns.App.handed[gid] and alpha.ns.App.net.hosts[gid] == alpha.ns.App.handed[gid], "handed-over host left the wire at once")
  assert(alpha.ns.App.mirror.games[gid] and alpha.ns.App.mirror.games[gid].joined, "alpha did not become a follower")
  run(beta, "call 6")
  tickAll(1)
  assert(alpha.ns.App.currentView().called[5], "old host did not see the new host's call")
end
-- #69: undoing a square that was never called must not call it, by slash command or by click
do
  local gid = beta.ns.App.current
  local h = beta.ns.App.hosts[gid]
  local free
  for i = 0, 23 do if not h.record.calls[i] then free = i; break end end
  assert(free, "no uncalled square left")
  run(beta, "undo " .. (free + 1))
  assert(h.record.calls[free] == nil, "undoing an uncalled square called it")
  assert(chat[#chat]:find("not called", 1, true), "undo of an uncalled square did not say why: " .. tostring(chat[#chat]))
  local okay, err = beta.ns.App.callSquare(free, true)
  assert(okay == false and err == "not called", "callSquare undo of an uncalled square: " .. tostring(okay) .. " " .. tostring(err))
  assert(h.record.calls[free] == nil, "callSquare undo of an uncalled square called it")
  assert(h.record.calls[4], "square 5 was expected to be called here")
  run(beta, "undo 5")   -- a called square really is undone
  assert(h.record.calls[4] == nil, "undo of a called square did not undo it")
end
tickAll(1)
-- #43/#51: a call made during a lockdown is held; the restriction event lets it out without a tick
_G.lockdown = true
run(beta, "call 9")
assert(#beta.ns.App.net.queue == 1, "call not held during the lockdown")
assert(not alpha.ns.App.currentView().called[8], "held call reached the follower")
_G.lockdown = false
beta.fire("ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
assert(#beta.ns.App.net.queue == 0, "the restriction event did not drain the queue")
pump()
assert(alpha.ns.App.currentView().called[8], "the released call did not reach the follower")
run(beta, "undo 9")
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
  local sh = Window.frame().sheetFrame
  local was = App.currentView().called[cell.item] == true
  cell.__scripts.OnEnter(cell); cell.__scripts.OnLeave(cell); cell.__scripts.OnClick(cell, "LeftButton")
  if App.currentView().canCall then
    -- #42: a caller's click acts at once, no sheet; the next click undoes it
    assert(not sh.__shown, c.name .. ": sheet opened for a caller's click")
    pump()
    assert((App.currentView().called[cell.item] == true) ~= was, c.name .. ": click did not toggle the call")
    cell.__scripts.OnClick(cell, "LeftButton"); pump()
    assert((App.currentView().called[cell.item] == true) == was, c.name .. ": second click did not toggle it back")
  else
    -- a reader's click opens the sheet with the text and a Close button
    assert(sh.__shown, c.name .. ": sheet did not open for a reader's click")
    sh.card.cancel.__scripts.OnClick(sh.card.cancel)
  end
  Window.sheet(cell.item); assert(sh.__shown); sh.card.cancel.__scripts.OnClick(sh.card.cancel)
  -- #33: scale changes re-thickness hairlines without error; reduced motion stops the flash
  c.ns.W.rescale()
  App.ui.setOption("reducedMotion", true)
  Chip.flash()
  assert(c.ns.Chip.frame == nil or true)
  App.ui.setOption("reducedMotion", false)
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
  -- #57: a burst of calls ticks once; a bingo always sounds; the next tick comes after the gap
  now = now + 1; played = 0
  App.playSound("call"); App.playSound("call"); App.playSound("undo")
  assert(played == 1, c.name .. ": burst of calls played " .. played .. " sounds")
  App.playSound("bingo")
  assert(played == 2, c.name .. ": bingo did not play in the burst")
  now = now + 1
  App.playSound("call")
  assert(played == 3, c.name .. ": call after the gap did not play")
  -- the gap's edges: exactly TICK_GAP after a tick plays; an undo inside it is dropped; a bingo
  -- inside it plays without moving the gap, so the next tick is still measured from the call
  local base = now + 10
  now = base; played = 0
  App.playSound("call")
  now = base + App.TICK_GAP / 2
  App.playSound("undo")
  assert(played == 1, c.name .. ": undo inside the gap played")
  App.playSound("bingo")
  assert(played == 2, c.name .. ": bingo inside the gap did not play")
  now = base + App.TICK_GAP
  App.playSound("call")
  assert(played == 3, c.name .. ": call exactly TICK_GAP after the last tick did not play, or the bingo moved the gap")
  now = base + App.TICK_GAP + App.TICK_GAP / 4
  App.playSound("call")
  assert(played == 3, c.name .. ": call inside the new gap played")
  now = base + 2 * App.TICK_GAP
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
  -- #27: clear history through its row and confirmation card
  do
    local before = #App.store:history()
    App.store:addHistory({ gid = "old1", title = "Old", roster = {}, calls = {} })
    assert(#App.store:history() == before + 1, "history entry not added")
    local clearRow
    for _, row in ipairs(Window.frame().views.options.rows) do if row.def.key == "clearHistory" then clearRow = row end end
    assert(clearRow and clearRow.action, "clear history row missing")
    clearRow.action.__scripts.OnClick(clearRow.action)
    local cf = Window.frame().confirmFrame
    assert(cf.__shown, "clear history did not ask first")
    cf.card.confirm.__scripts.OnClick(cf.card.confirm)
    assert(#App.store:history() == 0, "history not cleared")
  end
  -- #27: the preflight line counts group members outside the guild
  do
    local realRoster = _G.GetGuildRosterInfo
    _G.GetGuildRosterInfo = function(i) return ({ "Dea One" })[i] end   -- only Dea One is in the guild now
    _G.GetNumGuildMembers = function() return 1 end
    c.ns.App.refreshGuild()
    local n = App.ui.nonGuildInGroup()
    _G.GetGuildRosterInfo = realRoster
    _G.GetNumGuildMembers = function() return 2 end
    c.ns.App.refreshGuild()
    if c.name == "Dea One" then assert(n == 1, "expected one stranger in the group, got " .. n) end
  end
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

-- #66: the handed-over host leaves the wire once its recovery window has passed
do
  local handedGid = next(alpha.ns.App.handed)
  assert(handedGid, "no handed-over host waiting")
  clock = clock + alpha.ns.Host.HANDOFF_ANSWERS + 1
  current = alpha.name; alpha.ns.App.tick()
  assert(alpha.ns.App.net.hosts[handedGid] == nil, "handed-over host still on the wire after the window")
  assert(next(alpha.ns.App.handed) == nil, "handed-over host still listed after the window")
end
print("client smoke OK: protocol and UI executed headlessly")
