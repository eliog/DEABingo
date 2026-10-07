--[[
  Bootstrap and client glue: the WoW side of every dependency the pure
  modules take, SavedVariables, the slash command, and the one-second ticker.
  Everything initialises in ADDON_LOADED or PLAYER_LOGIN, never at file scope.

  Until the UI lands, /dea doubles as a plain debug interface: enough to run
  a whole game between two clients from the chat box.
]]

local ADDON, ns = ...
local Logic, Codec, Host, Mirror, Net, Store, Compat, View = ns.Logic, ns.Codec, ns.Host, ns.Mirror, ns.Net, ns.Store, ns.Compat, ns.View

ns.name = ADDON
local App = {}
ns.App = App

local PREFIX = "|cff8fd94aDEA Bingo|r "
local function print_(msg)
  (DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage(PREFIX .. tostring(msg))
end
ns.print = print_
local function debug_(msg)
  if ns.debug then print_("|cff7a6c86" .. tostring(msg) .. "|r") end
end

------------------------------------------------------------------ identity

-- First guess at our own name. On Forever, UnitName and UnitFullName return
-- first name and SURNAME, so only the display helper with the full-name flag
-- gives "Dea One". The realm suffix the server stamps on chat does not match
-- GetNormalizedRealmName either, so the guess is corrected by App.learnMe as
-- soon as our own hello echoes back.
local realm
local function displayName(unit)
  local name
  if GetUnitName then name = GetUnitName(unit, true) end
  if not name or name == "" or Compat.IsSecret(name) then name = UnitName(unit) end
  if not name or Compat.IsSecret(name) then return nil end
  return name
end

-- Forever's realmless rulesets make names unique region-wide: the server
-- stamps bare names and whispers route by name alone, so no realm is ever
-- attached. Classic realms keep the "Name-Realm" form.
function App.realmless()
  if App.isRealmless == nil then
    local okay, v = pcall(function() return RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() end)
    App.isRealmless = okay and v == true
  end
  return App.isRealmless
end

local function stripRealm(name)
  return (name:gsub("%-[^%-]+$", ""))
end

function App.me()
  if App.myName then return App.myName end
  local name = displayName("player")
  if not name then return nil end
  if App.realmless() then
    App.myName = stripRealm(name)
    return App.myName
  end
  realm = realm or GetNormalizedRealmName()
  if not realm then return nil end
  if name:find("-", 1, true) then App.myName = name else App.myName = name .. "-" .. realm end
  return App.myName
end

-- The server echoes our own HI with the name it uses for us. That beats any
-- guess from UnitFullName, which on Forever may split a surname off.
function App.learnMe(name)
  local old = App.myName
  if name == old then return end
  App.myName = name
  realm = name:match("%-([^%-]+)$") or realm
  debug_(("the server calls me %s (was %s)"):format(name, tostring(old)))
  if not App.net then return end
  App.net.deps.me = name
  App.mirror.deps.me = name
  for _, host in pairs(App.hosts or {}) do
    host.deps.me = name
    local r = host.record
    if r.owner == old then
      r.owner = name
      if r.roster[old] then r.roster[name] = r.roster[old]; r.roster[old] = nil end
      host:persist()
    end
  end
end

-- Same-realm senders may arrive bare; keys always carry the realm.
function App.normalize(name)
  if type(name) ~= "string" then return nil end
  if App.realmless() then return stripRealm(name) end
  if name:find("-", 1, true) then return name end
  if not realm then App.me() end
  return realm and (name .. "-" .. realm) or nil
end

------------------------------------------------------------------- roster

local guildSet, groupSet = {}, {}

function App.refreshGuild()
  guildSet = {}
  if not IsInGuild() then return end
  local n = GetNumGuildMembers() or 0
  for i = 1, n do
    local name = GetGuildRosterInfo(i)
    local full = App.normalize(name)
    if full then guildSet[full] = true end
  end
end

function App.refreshGroup()
  groupSet = {}
  local n = GetNumGroupMembers() or 0
  for i = 1, n do
    local unit = IsInRaid() and ("raid" .. i) or (i == n and "player" or ("party" .. i))
    local okay, name = pcall(displayName, unit)
    if okay and name then
      local full = App.normalize(name)
      if full then groupSet[full] = true end
    end
  end
end

function App.groupChannel()
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if IsInRaid() then return "RAID" end
  if IsInGroup() then return "PARTY" end
  return nil
end

function App.inGuild() return IsInGuild() == true end

-- Roster sets can lag the group (a party formed before login, a roster
-- event that fired before names were readable), so a miss re-reads them once
-- before saying no.
function App.isMember(name, audience)
  -- Let the client resolve "Name-Realm" itself: UnitInParty/UnitInRaid accept
  -- player names, which sidesteps every realm-format difference.
  local function unitInGroup()
    local okay, a = pcall(UnitInParty, name)
    if okay and a and not Compat.IsSecret(a) and a then return true end
    local okay2, b = pcall(UnitInRaid, name)
    return okay2 and b ~= nil and not Compat.IsSecret(b)
  end
  local function check()
    local inGuild = guildSet[name] == true
    local inGroup = groupSet[name] == true or unitInGroup()
    if audience == "G" then return inGuild end
    if audience == "R" then return inGroup end
    return inGuild or inGroup
  end
  if check() then return true end
  App.refreshGroup()
  if audience ~= "R" then App.refreshGuild() end
  local okay = check()
  if not okay then
    debug_(("membership miss for %s (%s); group: %s"):format(name, tostring(audience), (function()
      local t = {} for n in pairs(groupSet) do t[#t + 1] = n end return table.concat(t, ", ") end)()))
  end
  return okay
end

---------------------------------------------------------------- transport

local AceComm = LibStub and LibStub("AceComm-3.0", true)

local transport = {
  send = function(payload, channel, target, prio)
    if not AceComm then return end
    debug_(("-> %s %s %dB %s"):format(channel, target or "", #payload, payload:match("^%d+\31(%u%u)") or "?"))
    AceComm:SendCommMessage(Net.PREFIX, payload, channel, target, prio)
  end,
}

local function onComm(_, text, distribution, sender)
  if Compat.IsSecret(text) or Compat.IsSecret(sender) then return end
  local from = App.normalize(sender)
  if not from then return end
  debug_(("<- %s %s %dB %s"):format(distribution, from, #text, text:match("^%d+\31(%u%u)") or "?"))
  App.net:onMessage(text, distribution, from)
end

---------------------------------------------------------------------- wiring

function App.hostDeps()
  return {
    now = GetServerTime, me = App.me(), log = debug_,
    rng = { int = function(_, n) return math.random(0, n - 1) end },
    send = function(p, c, t) return App.net:send(p, c, t) end,
    persist = function(record) App.store:saveHosted(record); App.uiRefresh() end,
    isMember = App.isMember,
    onEvent = function(kind, info) App.onGameEvent(kind, info) end,
  }
end

-------------------------------------------------------------------- sounds

-- Blizzard sound kits by id, so this works without the SOUNDKIT table.
local SOUNDS = {
  call = 856,      -- IG_MAINMENU_OPTION_CHECKBOX_ON: a soft tick
  undo = 857,      -- IG_MAINMENU_OPTION_CHECKBOX_OFF
  bingo = 8960,    -- READY_CHECK
}

function App.inCombat()
  local okay, v = pcall(UnitAffectingCombat, "player")
  return okay and v == true
end

function App.playSound(kind)
  local o = App.store and App.store.db.options or {}
  if o.sounds == false then return end
  if o.quietInCombat ~= false and App.inCombat() then return end
  local id = SOUNDS[kind]
  if id then pcall(PlaySound, id, "Master") end
end

-------------------------------------------------------------------- toasts

-- Toasts never interrupt a pull: in combat they wait for PLAYER_REGEN_ENABLED.
App.pendingToasts = {}
function App.toast(opts)
  if not ns.Toast then return end
  if App.inCombat() then App.pendingToasts[#App.pendingToasts + 1] = opts; return end
  ns.Toast.show(opts)
end

function App.flushToasts()
  local queue = App.pendingToasts
  App.pendingToasts = {}
  for _, opts in ipairs(queue) do if ns.Toast then ns.Toast.show(opts) end end
end

-- A game has opened near us: say so once per game, with a Join button.
function App.announceGame(info)
  if info.state ~= "open" or info.owner == App.me() then return end
  local seen = App.store.db.seenGames
  if seen[info.gid] then return end
  seen[info.gid] = GetServerTime()
  -- keep the set small
  local n = 0 for _ in pairs(seen) do n = n + 1 end
  if n > 200 then
    local oldest, oldestAt
    for gid, at in pairs(seen) do if not oldestAt or at < oldestAt then oldest, oldestAt = gid, at end end
    seen[oldest] = nil
  end
  App.toast({
    text = Logic.escape(info.title or "Raid Bingo"),
    sub = View.shortName(info.owner) .. " opened a game",
    ttl = 60,
    action = { label = "Join", fn = function() App.ui.join(info.gid) end },
  })
end

-- Game events from the host or the mirror.
function App.onGameEvent(kind, info)
  if kind == "close" then App.archive(info.gid); App.uiRefresh(); return end
  if kind == "newGame" then App.announceGame(info); return end
  if info.gid ~= App.current then return end
  local me = App.me()
  if kind == "call" then
    if ns.Chip then ns.Chip.flash() end
    local mine, others = false, {}
    for _, name in ipairs(info.winners or {}) do
      if name == me then mine = true else others[#others + 1] = View.shortName(name) end
    end
    App.playSound(mine and "bingo" or "call")
    if #others > 0 then
      App.toast({ text = table.concat(others, ", ") .. (#others == 1 and " has BINGO" or " have BINGO"), sub = "Standings updated", accent = "gold", ttl = 10 })
    end
  elseif kind == "undo" then
    App.playSound("undo")
  elseif kind == "close" then
    App.archive(info.gid)
  end
end

-- Coalesce UI refreshes: a join wave persists dozens of times a second.
function App.uiRefresh()
  if not ns.Window or App.refreshScheduled then return end
  App.refreshScheduled = true
  C_Timer.After(0.05, function()
    App.refreshScheduled = false
    ns.Window.refresh()
    ns.Chip.update(App.currentView())
  end)
end

function App.setup()
  local me = App.me()
  if not me then return false end
  App.net = Net.new({
    transport = transport, now = GetServerTime, me = me, log = debug_,
    groupChannel = App.groupChannel, inGuild = App.inGuild, isMember = App.isMember,
    learnMe = App.learnMe,
  })
  App.mirror = Mirror.new({
    now = GetServerTime, me = me, log = debug_,
    send = function(p, c, t) return App.net:send(p, c, t) end,
    channels = function() return App.net:channels() end,
    persist = function(gid, g) App.store:saveJoined(gid, g); App.uiRefresh() end,
    onCards = function() App.uiRefresh() end,
    lookupItems = function(hash) local set = App.store.db.itemSets[hash]; if type(set) == "table" then return set end end,
    onEvent = function(kind, info) App.onGameEvent(kind, info) end,
  })
  App.net.mirror = App.mirror
  App.hosts = {}
  for _, record in ipairs(App.store:openHosted(me)) do
    local host = Host.restore(record, App.hostDeps())
    App.hosts[record.gid] = host
    App.net:attachHost(host)
    App.current = record.gid
    print_(("resumed hosting \"%s\""):format(Logic.escape(record.title)))
  end
  App.rejoin = {}
  for gid, j in pairs(App.store.db.joined) do
    if type(j) == "table" and j.state == "open" then App.rejoin[gid] = true end
  end
  if AceComm then AceComm:RegisterComm(Net.PREFIX, onComm) end
  App.ticker = C_Timer.NewTicker(1, App.tick)
  App.ready = true
  if ns.Window and rawget(_G, "UIParent") then
    ns.Theme.apply(App.store.db.options.theme or "dark")
    ns.Window.init(App.ui)
    ns.Chip.init(App.chipUi)
    ns.Chip.applyOptions(App.store.db.options)
    if ns.Toast then ns.Toast.init() end
    App.uiRefresh()
  end
  return true
end

function App.tick()
  if not App.ready then return end
  App.net:tick()
  -- Silent rejoin after a reload: as soon as the card is heard, ask for the same board back.
  for gid in pairs(App.rejoin) do
    if App.mirror.cards[gid] and not App.mirror.games[gid] then
      App.mirror:join(gid)
      App.rejoin[gid] = nil
      App.current = App.current or gid
      debug_("rejoining " .. gid)
    end
  end
end

-- Keep a finished game readable: boards, calls, winners. Host or follower.
function App.archive(gid)
  local src = App.hosts[gid] and App.hosts[gid].record or App.mirror.games[gid]
  if not src then return end
  local roster = {}
  for name, e in pairs(src.roster or {}) do
    roster[name] = { board = e.board, canCall = e.canCall, bingoAt = e.bingoAt }
  end
  local calls = {}
  for idx, t in pairs(src.calls or {}) do calls[idx] = t end
  App.store:addHistory({
    gid = gid, title = src.title, owner = src.owner, audience = src.audience,
    createdAt = src.createdAt, closedAt = src.closedAt or GetServerTime(),
    items = src.items, roster = roster, calls = calls,
  })
end

local helloPending = false
function App.helloSoon()
  if helloPending or not App.ready then return end
  helloPending = true
  C_Timer.After(2, function()
    helloPending = false
    App.refreshGroup()
    App.mirror:hello()
  end)
end

------------------------------------------------------------------ commands

-- The game commands act on: the current one, else the only open game this
-- client hosts or has joined.
local function currentGame()
  if App.current and App.hosts[App.current] then return App.hosts[App.current], nil end
  if App.current and App.mirror.games[App.current] then return nil, App.mirror.games[App.current] end
  local onlyHost, onlyGame, n = nil, nil, 0
  for _, host in pairs(App.hosts) do if host.record.state ~= "closed" then onlyHost = host; n = n + 1 end end
  for _, g in pairs(App.mirror.games) do if g.state ~= "closed" and g.joined then onlyGame = g; n = n + 1 end end
  if n == 1 then
    App.current = onlyHost and onlyHost.record.gid or onlyGame.gid
    return onlyHost, onlyGame
  end
  return nil, nil
end

-- The view model for the current game, or nil when not in one.
function App.currentView()
  local host, game = currentGame()
  if host then return View.fromHost(host.record, App.me()) end
  if game then return View.fromMirror(game, App.me(), App.mirror.cards[game.gid]) end
  return nil
end

function App.createGame(opts)
  local host = Host.new(App.hostDeps())
  local audience = opts.audience
  if audience == "G" and not App.inGuild() then audience = "R" end
  local record, err = host:create({ title = opts.title, items = opts.items, audience = audience })
  if not record then return nil, err end
  App.hosts[record.gid] = host
  App.net:attachHost(host)
  App.current = record.gid
  if opts.open ~= false then
    local okay, err2 = host:open()
    if not okay then return nil, err2 end
  end
  App.store:saveItemSet(record.itemsHash, record.title, record.items, GetServerTime())
  App.uiRefresh()
  return record
end

function App.callSquare(idx, undo)
  local host, game = currentGame()
  if host then
    local result, err = undo and host:undo(idx) or host:call(idx)
    return result ~= nil, err
  elseif game then
    return App.mirror:requestCall(game.gid, idx, undo)
  end
  return nil, "not in a game"
end

App.ui = {
  lobby = function()
    local rows = View.lobby(App.mirror.cards, (function() local t = {} for gid, h in pairs(App.hosts) do t[gid] = h.record end return t end)(), App.me())
    for _, r in ipairs(rows) do r.joined = App.mirror.games[r.gid] ~= nil and App.mirror.games[r.gid].joined end
    return rows
  end,
  view = App.currentView,
  join = function(gid)
    local okay, err = App.mirror:join(gid)
    if okay then App.current = gid; ns.Window.show("game") else print_(tostring(err)) end
  end,
  open = function(gid) App.current = gid; ns.Window.show("game") end,
  create = function(opts) return App.createGame(opts) end,
  call = function(idx, undo)
    local okay, err = App.callSquare(idx, undo)
    if not okay and err then print_(tostring(err)) end
  end,
  grant = function(name, on)
    local host = currentGame()
    if host then host:grant(name, on) end
  end,
  close = function()
    local host = currentGame()
    if host then host:close() end
  end,
  leaveToLobby = function() App.current = nil end,
  savePosition = function(pos) App.store.db.options.window = pos end,
  position = function() return App.store.db.options.window end,
  defaultAudience = function() return App.inGuild() and "G" or "R" end,
  inGuild = App.inGuild,
  history = function() return App.store:history() end,
  historyView = function(gid)
    for _, e in ipairs(App.store:history()) do
      if e.gid == gid then return View.fromHistory(e, App.me()) end
    end
    return nil
  end,
  option = function(key) return App.store.db.options[key] end,
  setOption = function(key, value)
    App.store.db.options[key] = value
    if key == "theme" then ns.Theme.apply(value) end
    if ns.Chip then ns.Chip.applyOptions(App.store.db.options) end
  end,
  itemSets = function()
    local out = {}
    for _, p in ipairs(ns.PRESETS) do out[#out + 1] = { name = p.name, items = p.items } end
    for _, s in ipairs(App.store:itemSets()) do out[#out + 1] = { name = s.title, items = s.items, titleHint = s.title, usedAt = s.usedAt, saved = true } end
    return out
  end,
}

App.chipUi = {
  savePosition = function(pos) App.store.db.options.chip = pos end,
  position = function() return App.store.db.options.chip end,
}

local function itemsOf(host, game)
  if host then return host.record.items end
  if game then return game.items end
end

local function printBoard(board, called, items)
  for r = 0, 4 do
    local cells = {}
    for c = 1, 5 do
      local p = r * 5 + c
      local item = board[p]
      if item == Logic.FREE then
        cells[c] = "|cffc9a05e[ HS ]|r"
      else
        local mark = called[item] and "|cff8fd94a" or "|cffa293ac"
        cells[c] = ("%s[%2d%s]|r"):format(mark, item + 1, called[item] and "*" or " ")
      end
    end
    print_(table.concat(cells, " "))
  end
  if items then print_("numbers are items from /dea items") end
end

local commands = {}

commands.show = function()
  if ns.Window then ns.Window.toggle() else commands.status() end
end
commands.hide = function() if ns.Window and ns.Window.isShown() then ns.Window.toggle() end end

commands.help = function()
  print_("/dea new <title> | new raid <title> | items | item <n> <text> | open | list | join <n>")
  print_("/dea board | call <n> | undo <n> | standings | grant <Name-Realm> | revoke <Name-Realm> | close")
  print_("/dea show | hide | sound | quiet | status | net | probe | reset | debug | test")
end

commands.status = function()
  print_(("version %s on %s"):format(Compat.GetAddOnVersion(ADDON), Compat.Summary()))
  print_(("you are %s; guild channel %s; group channel %s"):format(tostring(App.me()), App.inGuild() and "yes" or "no", tostring(App.groupChannel())))
  local host, game = currentGame()
  if host then
    local r = host.record
    local n = 0 for _ in pairs(r.roster) do n = n + 1 end
    print_(("hosting \"%s\" [%s] %s, %d players, seq %d"):format(Logic.escape(r.title), r.gid, r.state, n, r.seq))
  elseif game then
    print_(("in \"%s\" [%s] hosted by %s, seq %d%s"):format(Logic.escape(game.title), game.gid, game.owner, game.seq, game.items and "" or " (items not received yet)"))
  else
    print_("not in a game; /dea list")
  end
end

commands.new = function(rest)
  local audience = "G"
  local title = rest
  if rest:match("^raid%s+") then audience = "R"; title = rest:gsub("^raid%s+", "") end
  if title == "" then title = date("%A") .. " raid" end
  if audience == "G" and not App.inGuild() then
    print_("you are not in a guild, so this game is for your group instead (Raid mode)")
    audience = "R"
  end
  if audience == "R" and not App.groupChannel() then
    print_("note: you are not in a group yet; nobody will hear the game until you are")
  end
  local host = Host.new(App.hostDeps())
  local record, err = host:create({ title = title, items = ns.PRESETS[1].items, audience = audience })
  if not record then print_("could not create: " .. tostring(err)); return end
  App.hosts[record.gid] = host
  App.net:attachHost(host)
  App.current = record.gid
  print_(("drafted \"%s\" for %s; edit with /dea item <n> <text>, then /dea open"):format(Logic.escape(record.title), audience == "G" and "the guild" or "the raid"))
end

commands.items = function()
  local host, game = currentGame()
  local items = itemsOf(host, game)
  if not items then
    if game then App.mirror:requestItems(game.gid); print_("items not received yet; asked the host again") else print_("no items to show") end
    return
  end
  for i, item in ipairs(items) do print_(("%2d. %s"):format(i, Logic.escape(item))) end
end

commands.item = function(rest)
  local host = currentGame()
  if not host then print_("only the host edits items"); return end
  local n, text = rest:match("^(%d+)%s+(.+)$")
  n = tonumber(n)
  if not n or n < 1 or n > Logic.ITEM_COUNT then print_("usage: /dea item <1-24> <text>"); return end
  local items = { unpack(host.record.items) }
  items[n] = text
  local okay, err = host:setItems(items)
  print_(okay and ("item %d set"):format(n) or ("not set: " .. tostring(err)))
end

commands.open = function()
  local host = currentGame()
  if not host then print_("nothing drafted; /dea new <title>"); return end
  local okay, err = host:open()
  print_(okay and "game is open; the card is out" or tostring(err))
end

commands.list = function()
  local games = App.mirror:openGames()
  for gid, host in pairs(App.hosts) do
    if host.record.state == "open" then print_(("  (hosting) \"%s\" [%s]"):format(Logic.escape(host.record.title), gid)) end
  end
  if #games == 0 then print_("no open games heard; hosts answer within a few seconds of /dea list"); App.mirror:hello(); return end
  for i, g in ipairs(games) do
    print_(("%d. \"%s\" by %s, %d players, %d calls%s%s"):format(i, Logic.escape(g.title), g.owner, g.players, g.calls,
      g.joined and " (joined)" or "", g.hostAway and " (host away)" or ""))
  end
  App.listed = games
end

commands.join = function(rest)
  local n = tonumber(rest)
  local g = App.listed and App.listed[n]
  if not g then print_("usage: /dea list, then /dea join <n>"); return end
  local okay, err = App.mirror:join(g.gid)
  if okay then App.current = g.gid; print_("asked to join " .. Logic.escape(g.title)) else print_(tostring(err)) end
end

commands.board = function()
  local host, game = currentGame()
  if host then
    local e = host.record.roster[App.me()]
    if not e then print_("open the game first"); return end
    local called = {} for idx in pairs(host.record.calls) do called[idx] = true end
    printBoard(e.board, called, host.record.items)
  elseif game then
    local st = App.mirror:myState(game.gid)
    if not st then print_("no board yet"); return end
    printBoard(st.board, st.called, game.items)
    print_(("best line %d/5%s"):format(st.bestLine, st.hasBingo and " BINGO" or ""))
  else
    print_("not in a game")
  end
end

local function callOrUndo(rest, undo)
  local n = tonumber(rest)
  if not n or n < 1 or n > Logic.ITEM_COUNT then print_("usage: /dea " .. (undo and "undo" or "call") .. " <1-24>"); return end
  local host, game = currentGame()
  if host then
    local result, err = undo and host:undo(n - 1) or host:call(n - 1)
    if not result then print_(tostring(err)); return end
    print_(((undo and "undone: " or "called: ") .. Logic.escape(host.record.items[n])) .. (#result > 0 and (" | " .. (undo and "revoked " or "BINGO ") .. table.concat(result, ", ")) or ""))
  elseif game then
    local okay, err = App.mirror:requestCall(game.gid, n - 1, undo)
    print_(okay and "asked the host" or tostring(err))
  else
    print_("not in a game")
  end
end
commands.call = function(rest) callOrUndo(rest, false) end
commands.undo = function(rest) callOrUndo(rest, true) end

commands.standings = function()
  local host, game = currentGame()
  local gid = host and host.record.gid or (game and game.gid)
  if not gid then print_("not in a game"); return end
  local rows
  if host then
    local called = {} for idx in pairs(host.record.calls) do called[idx] = true end
    rows = {}
    for name, e in pairs(host.record.roster) do
      rows[#rows + 1] = { name = name, bestLine = Logic.bestLineOf(e.board, called), bingoAt = e.bingoAt, canCall = e.canCall or name == host.record.owner }
    end
    table.sort(rows, function(a, b)
      if (a.bingoAt == nil) ~= (b.bingoAt == nil) then return a.bingoAt ~= nil end
      if a.bingoAt and b.bingoAt and a.bingoAt ~= b.bingoAt then return a.bingoAt < b.bingoAt end
      if a.bestLine ~= b.bestLine then return a.bestLine > b.bestLine end
      return a.name < b.name
    end)
  else
    rows = App.mirror:standings(gid)
  end
  for i, r in ipairs(rows) do
    print_(("%d. %s %s %s%s"):format(i, r.name, ("*"):rep(r.bestLine) .. ("."):rep(5 - r.bestLine),
      r.bingoAt and ("BINGO " .. date("%H:%M", r.bingoAt)) or "", r.canCall and " (caller)" or ""))
  end
end

commands.grant = function(rest)
  local host = currentGame()
  if not host then print_("only the owner grants calling"); return end
  local okay, err = host:grant(App.normalize(rest), true)
  print_(okay and (rest .. " can call") or tostring(err))
end

commands.revoke = function(rest)
  local host = currentGame()
  if not host then print_("only the owner revokes calling"); return end
  local okay, err = host:grant(App.normalize(rest), false)
  print_(okay and (rest .. " can no longer call") or tostring(err))
end

commands.close = function()
  local host = currentGame()
  if not host then print_("only the owner closes a game"); return end
  local okay, err = host:close()
  print_(okay and "closed" or tostring(err))
end

-- What this client says about names, for the Forever surname question.
commands.probe = function()
  local function show(label, ...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    print_(("%s -> %s"):format(label, n == 0 and "(nothing)" or table.concat(parts, " | ")))
  end
  show("UnitName('player')", UnitName("player"))
  show("UnitFullName('player')", UnitFullName("player"))
  show("GetUnitName('player', true)", GetUnitName and GetUnitName("player", true))
  show("GetNormalizedRealmName()", GetNormalizedRealmName())
  show("GetRealmName()", GetRealmName())
  show("UnitGUID('player')", UnitGUID("player"))
  show("ShouldDisplaySurname()", C_PlayerInfo and C_PlayerInfo.ShouldDisplaySurname and C_PlayerInfo.ShouldDisplaySurname())
  show("RegionalUniqueNamesEnabled()", RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled())
  show("addon treats this ruleset as realmless", App.realmless())
  if IsInGuild() and GetNumGuildMembers and (GetNumGuildMembers() or 0) > 0 then
    show("GetGuildRosterInfo(1)", GetGuildRosterInfo(1))
  end
  if IsInGroup() then
    local unit = IsInRaid() and "raid1" or "party1"
    show("UnitName('" .. unit .. "')", UnitName(unit))
    show("GetUnitName('" .. unit .. "', true)", GetUnitName and GetUnitName(unit, true))
  end
  show("addon thinks I am", App.myName)
end

-- Development helper: forget every hosted and joined game on this character.
commands.reset = function()
  for gid in pairs(App.hosts or {}) do App.net:detachHost(gid) end
  App.hosts = {}
  App.current = nil
  App.rejoin = {}
  App.store.db.hosted = {}
  App.store.db.joined = {}
  App.mirror.games = {}
  App.mirror.cards = {}
  print_("forgot every hosted and joined game on this character")
end

commands.net = function()
  local s = App.net.stats
  print_(("sent %d, received %d, dropped %d"):format(s.sent, s.received, s.dropped))
end

commands.sound = function()
  local o = App.store.db.options
  o.sounds = not (o.sounds ~= false)
  print_("sounds " .. (o.sounds and "on" or "off"))
end

commands.quiet = function()
  local o = App.store.db.options
  o.quietInCombat = not (o.quietInCombat ~= false)
  print_("quiet in combat " .. (o.quietInCombat and "on" or "off"))
end

commands.debug = function()
  ns.debug = not ns.debug
  print_("debug " .. (ns.debug and "on" or "off"))
end

commands.test = function()
  local okay, err = pcall(function()
    local rng = { int = function(_, n) return math.random(0, n - 1) end }
    local board = Logic.dealBoard(rng)
    assert(Logic.isValidBoard(board), "dealt board is invalid")
    assert(Logic.decodeBoard(Logic.encodeBoard(board)) ~= nil, "board does not round-trip")
    local wire = assert(Codec.encode("CL", "selftest", { seq = 1, idx = 3, t = GetServerTime(), winners = {} }))
    local msg = assert(Codec.decode(wire))
    assert(msg.f.idx == 3, "codec")
    assert(Logic.escape("a|cff00ff00b") == "a||cff00ff00b", "escape")
  end)
  print_(okay and "self-test passed" or ("self-test FAILED: " .. tostring(err)))
end

local function onSlash(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = (cmd or (ns.Window and "show" or "status")):lower()
  if not App.ready and cmd ~= "test" and cmd ~= "debug" and cmd ~= "help" then print_("not ready yet"); return end
  local fn = commands[cmd]
  if not fn then commands.help(); return end
  fn(rest or "")
end

-------------------------------------------------------------------- events

local frame = CreateFrame("Frame")
for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "GUILD_ROSTER_UPDATE", "CHAT_MSG_ADDON", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
  Compat.RegisterEvent(frame, ev)
end
frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
  if event == "CHAT_MSG_ADDON" then
    -- Raw chunk tap, debug only: AceComm reassembles above this, so a lost
    -- or truncated chunk shows up here first.
    if ns.debug and arg1 == Net.PREFIX and type(arg2) == "string" and not Compat.IsSecret(arg2) then
      local control = arg2:byte(1)
      local kind = (control == 1 and "first") or (control == 2 and "next") or (control == 3 and "last") or "single"
      debug_(("  raw %s %s %dB %s from %s"):format(tostring(arg3), kind, #arg2, kind == "single" and (arg2:match("^%d+\31(%u%u)") or "?") or "", tostring(arg4)))
    end
    return
  end
  if event == "ADDON_LOADED" and arg1 == ADDON then
    if type(DEABingoDB) ~= "table" then DEABingoDB = {} end
    if type(DEABingoCharDB) ~= "table" then DEABingoCharDB = {} end
    App.store = Store.new(DEABingoDB)
    DEABingoDB = App.store.db
    ns.db = App.store.db
    SLASH_DEABINGO1 = "/dea"
    SLASH_DEABINGO2 = "/deabingo"
    SlashCmdList.DEABINGO = onSlash
    self:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_LOGIN" then
    for _ = 1, (math.floor(GetTime() * 1000) % 97) do math.random() end
    if not App.setup() then
      -- realm not known yet; try again when the world is up
      C_Timer.After(3, function() if not App.ready then App.setup() end end)
    end
    if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
    App.refreshGuild()
    App.refreshGroup()
  elseif event == "PLAYER_ENTERING_WORLD" then
    App.helloSoon()
  elseif event == "GROUP_ROSTER_UPDATE" then
    App.refreshGroup()
    App.helloSoon()
  elseif event == "GUILD_ROSTER_UPDATE" then
    App.refreshGuild()
  elseif event == "PLAYER_REGEN_DISABLED" then
    if ns.Window then ns.Window.setCombat(true) end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if ns.Window then ns.Window.setCombat(false) end
    App.flushToasts()
  end
end)

function DEABingo_OnCompartmentClick()
  onSlash("show")
end
