--[[
  The seam between the game and the chat system. Owns the one prefix, routes
  incoming messages to the host that owns the game or to the mirror, and
  enforces the rules every untrusted sender is held to:

    - the sender is the server-stamped name, never a payload field
    - a per-sender token bucket, silent drops
    - whispers only from group or guild members
    - our own echoes are ignored
    - nothing from a message handler ever reaches a protected function

    deps.transport.send(payload, channel, target, prio)   the real or loopback wire
    deps.now()
    deps.me
    deps.groupChannel()      "INSTANCE_CHAT" | "RAID" | "PARTY" | nil
    deps.inGuild()           bool
    deps.isMember(name)      bool: in my group or my guild
    deps.learnMe(name)       optional: called when the server echoes our own HI under a different name
    deps.log(text)           optional
]]

local _, ns = ...
if type(ns) ~= "table" then ns = {} end
local Codec = ns.Codec or require("Core.Codec")

local Net = {}
Net.__index = Net
ns.Net = Net

Net.PREFIX = "DEABINGO"

local PRIORITY = { CL = "ALERT", UN = "ALERT", CQ = "ALERT", IT = "BULK", SN = "BULK" }
local HOST_BOUND = { JN = true, CQ = true, IQ = true, SQ = true, NV = true }

-- Token buckets: players may send 5 per 10 s, hosts 40 per 10 s (a join
-- wave is one JD per joiner, and the host's own throttle paces it anyway).
local PLAYER_BUCKET = { capacity = 5, refill = 0.5 }
local HOST_BUCKET = { capacity = 40, refill = 4 }

function Net.new(deps)
  local self = setmetatable({}, Net)
  self.deps = deps
  self.hosts = {}          -- gid -> Host
  self.mirror = nil
  self.buckets = {}        -- sender -> { tokens, at }
  self.stats = { sent = 0, received = 0, dropped = 0 }
  return self
end

function Net:log(text)
  if self.deps.log then self.deps.log(text) end
end

function Net:attachHost(host)
  self.hosts[host.record.gid] = host
end

function Net:detachHost(gid)
  self.hosts[gid] = nil
end

-- The send function handed to hosts and the mirror. Resolves "GROUP" to the
-- right channel at send time and drops quietly when no channel exists.
function Net:send(payload, channel, target)
  local dist = channel
  if channel == "GROUP" then
    dist = self.deps.groupChannel()
    if not dist then self:log("no group channel, dropped " .. payload:sub(1, 12)); return false end
  elseif channel == "GUILD" then
    if not self.deps.inGuild() then self:log("not in a guild, dropped " .. payload:sub(1, 12)); return false end
  elseif channel == "WHISPER" then
    if not Codec.isName(target) then return false end
  else
    return false
  end
  local msgType = payload:match("^%d+\31(%u%u)\31")
  self.stats.sent = self.stats.sent + 1
  self.deps.transport.send(payload, dist, target, PRIORITY[msgType] or "NORMAL")
  return true
end

-- Which broadcast channels this client can reach right now.
function Net:channels()
  local out = {}
  if self.deps.inGuild() then out[#out + 1] = "GUILD" end
  if self.deps.groupChannel() then out[#out + 1] = "GROUP" end
  return out
end

local function isKnownHost(self, sender)
  if self.mirror then
    for _, card in pairs(self.mirror.cards) do if card.host == sender then return true end end
    for _, g in pairs(self.mirror.games) do if g.owner == sender then return true end end
  end
  return false
end

function Net:allow(sender)
  local rule = isKnownHost(self, sender) and HOST_BUCKET or PLAYER_BUCKET
  local now = self.deps.now()
  local b = self.buckets[sender]
  if not b then
    b = { tokens = rule.capacity, at = now, capacity = rule.capacity }
    self.buckets[sender] = b
  end
  -- A sender we have since learned is a host gets the host allowance at once.
  if rule.capacity > b.capacity then
    b.tokens = b.tokens + (rule.capacity - b.capacity)
    b.capacity = rule.capacity
  end
  b.tokens = math.min(rule.capacity, b.tokens + (now - b.at) * rule.refill)
  b.at = now
  if b.tokens < 1 then return false end
  b.tokens = b.tokens - 1
  return true
end

-- Entry point from the transport. Never throws: a bad message is dropped.
function Net:onMessage(payload, channel, sender)
  local okay, err = pcall(self.dispatch, self, payload, channel, sender)
  if not okay then
    self.stats.dropped = self.stats.dropped + 1
    self:log("handler error: " .. tostring(err))
  end
end

function Net:dispatch(payload, channel, sender)
  self.stats.received = self.stats.received + 1
  if type(sender) ~= "string" or sender == self.deps.me then return end
  if not Codec.isName(sender) then self.stats.dropped = self.stats.dropped + 1; return end
  -- Our own HI coming back with our nonce: that sender string is what the
  -- server calls us, whatever the client's name functions say.
  if self.mirror and payload:find("\31HI\31", 1, true) then
    local echo = Codec.decode(payload)
    if echo and echo.type == "HI" and echo.f.nonce == self.mirror.nonce then
      if self.deps.learnMe then self.deps.learnMe(sender) end
      return
    end
  end
  if not self:allow(sender) then self.stats.dropped = self.stats.dropped + 1; return end
  if channel == "WHISPER" and not self.deps.isMember(sender) then self.stats.dropped = self.stats.dropped + 1; return end

  local msg, reason, info = Codec.decode(payload)
  if not msg then
    if reason == "newer" and self.mirror then self.mirror:noteNewer(info.v) end
    self.stats.dropped = self.stats.dropped + 1
    self:log(("dropped %dB from %s: %s"):format(#payload, sender, tostring(reason)))
    return
  end

  if msg.type == "HI" then
    for _, host in pairs(self.hosts) do host:handle(msg, sender) end
    return
  end
  if HOST_BOUND[msg.type] then
    local host = self.hosts[msg.gid]
    if host then host:handle(msg, sender) end
    return
  end
  if self.mirror then self.mirror:handle(msg, sender) end
end

function Net:tick()
  for _, host in pairs(self.hosts) do host:tick() end
  if self.mirror then self.mirror:tick() end
end

return Net
