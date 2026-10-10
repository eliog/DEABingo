--[[
  A loopback chat system for tests: several in-process clients, each with
  its own Net, Mirror and optional Host, wired to one fake clock. Delivery
  mimics the game: GUILD reaches everyone in the sender's guild, RAID and
  PARTY everyone in the sender's group, WHISPER one target, and the sender
  hears its own broadcasts.

  Messages are queued and delivered on flush(), so a test can reorder or drop
  them to simulate a bad night.
]]

local Net = require("Core.Net")
local Host = require("Core.Host")
local Mirror = require("Core.Mirror")

local Hub = {}
Hub.__index = Hub

function Hub.new(opts)
  local self = setmetatable({}, Hub)
  self.time = (opts and opts.time) or 1700000000
  self.clients = {}
  self.queue = {}
  self.log = {}
  self.rng = { int = function(_, n) return math.random(0, n - 1) end }
  return self
end

function Hub:now() return self.time end

function Hub:addClient(name, opts)
  opts = opts or {}
  local hub = self
  local client = { name = name, guild = opts.guild, group = opts.group, sent = {}, received = {} }

  local transport = {
    send = function(payload, channel, target, prio, onResult)
      -- client.refuse(payload) -> true models the chat library refusing a send (lockdown result 11)
      if client.refuse and client.refuse(payload) then
        if onResult then onResult(false, 11) end
        return
      end
      client.sent[#client.sent + 1] = { payload = payload, channel = channel, target = target, prio = prio }
      hub.queue[#hub.queue + 1] = { from = name, payload = payload, channel = channel, target = target }
      if onResult then onResult(true, 0) end
    end,
  }
  local deps = {
    transport = transport,
    addonVersion = opts.version or "v0.1.1",
    now = function() return hub.time end,
    me = opts.thinksItIs or name,     -- what the client believes; the hub always stamps `name`
    learnMe = function(real)
      -- the same rule App.learnMe applies: only a name for this character
      if not require("Core.Logic").sameCharacter(real, opts.displayName or name) then client.refused = real; return end
      client.learned = real
      client.net.deps.me = real
      client.mirror.deps.me = real
      if client.hosted then client.hosted.deps.me = real end
    end,
    groupChannel = function() return client.group and "RAID" or nil end,
    inLockdown = function() return client.locked == true end,
    inGuild = function() return client.guild ~= nil end,
    isMember = function(other, audience)
      local o = hub.clients[other]
      if not o then return false end
      local inGuild = client.guild ~= nil and o.guild == client.guild
      local inGroup = client.group ~= nil and o.group == client.group
      if audience == "G" then return inGuild end
      if audience == "R" then return inGroup end
      return inGuild or inGroup
    end,
    log = function(text) hub.log[#hub.log + 1] = name .. ": " .. text end,
  }
  client.net = Net.new(deps)
  client.mirror = Mirror.new({
    now = deps.now, me = deps.me, log = deps.log, addonVersion = deps.addonVersion,
    inLockdown = deps.inLockdown,
    send = function(p, c, t) return client.net:send(p, c, t) end,
    channels = function() return client.net:channels() end,
    persist = function(gid, g) client.joined = client.joined or {}; client.joined[gid] = g end,
  })
  client.net.mirror = client.mirror
  client.hostDeps = {
    now = deps.now, rng = hub.rng, me = name, log = deps.log, addonVersion = deps.addonVersion,
    send = function(p, c, t) return client.net:send(p, c, t) end,
    persist = function(record) client.persisted = record end,
    isMember = deps.isMember,
  }
  function client:host(opts2)
    local h = Host.new(self.hostDeps)
    assert(h:create(opts2))
    self.net:attachHost(h)
    self.hosted = h
    return h
  end
  function client:restoreHost(record)
    local h = Host.restore(record, self.hostDeps)
    self.net:attachHost(h)
    self.hosted = h
    return h
  end
  self.clients[name] = client
  return client
end

function Hub:removeClient(name)
  self.clients[name] = nil
end

-- Deliver one queued message to everyone who would hear it.
function Hub:deliver(m)
  local from = self.clients[m.from]
  for name, c in pairs(self.clients) do
    local hears = false
    if m.channel == "WHISPER" then
      hears = (name == m.target)
    elseif m.channel == "GUILD" then
      hears = from and from.guild ~= nil and c.guild == from.guild
    elseif m.channel == "RAID" or m.channel == "PARTY" or m.channel == "INSTANCE_CHAT" then
      hears = from and from.group ~= nil and c.group == from.group
    end
    if hears then
      c.received[#c.received + 1] = m
      c.net:onMessage(m.payload, m.channel, m.from)
    end
  end
end

-- Deliver everything queued, including what delivery itself queues.
function Hub:flush(filter)
  local rounds = 0
  while #self.queue > 0 do
    rounds = rounds + 1
    assert(rounds < 1000, "message storm")
    local batch = self.queue
    self.queue = {}
    for _, m in ipairs(batch) do
      if not filter or filter(m) then self:deliver(m) end
    end
  end
end

-- Advance the clock, ticking everyone once per second, flushing as we go.
function Hub:advance(seconds)
  for _ = 1, seconds do
    self.time = self.time + 1
    for _, c in pairs(self.clients) do c.net:tick() end
    self:flush()
  end
end

function Hub:types(client)
  local out = {}
  for _, m in ipairs(client.sent) do out[#out + 1] = m.payload:match("^%d+\31(%u%u)") end
  return out
end

return Hub
