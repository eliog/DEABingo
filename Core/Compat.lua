--[[
  What this client can do. Probed once at load and stored, so the rest of the
  addon branches on capabilities rather than on version numbers.

  WoW: Forever reports Interface 16001 and is built on the retail codebase.
  Never test `>= 100000` for "modern client", never trust WOW_PROJECT_ID alone
  (it returned 1 on some beta builds), and never register an event the client
  does not know: on Forever that throws and aborts the whole file.
]]

local _, ns = ...

local Compat = {}
ns.Compat = Compat

local function probe()
  local version, build, date, interface = GetBuildInfo()
  Compat.version = version
  Compat.build = build
  Compat.date = date
  Compat.interface = tonumber(interface) or 0
  Compat.isForever = Compat.interface >= 16000 and Compat.interface < 20000
  Compat.isRetail = Compat.interface >= 100000
  Compat.project = rawget(_G, "WOW_PROJECT_ID")

  Compat.hasChatLockdown = C_ChatInfo ~= nil and type(C_ChatInfo.InChatMessagingLockdown) == "function"
  Compat.hasSecrets = type(rawget(_G, "issecretvalue")) == "function"
  Compat.hasEncodingUtil = rawget(_G, "C_EncodingUtil") ~= nil
  Compat.hasAddOns = rawget(_G, "C_AddOns") ~= nil
  Compat.hasStrlenUtf8 = type(rawget(_G, "strlenutf8")) == "function"
  Compat.hasCompartment = rawget(_G, "AddonCompartmentFrame") ~= nil
end

-- Registering an unknown event throws on Forever. Returns true when registered.
function Compat.RegisterEvent(frame, event)
  local okay = pcall(frame.RegisterEvent, frame, event)
  return okay
end

function Compat.InChatLockdown()
  if Compat.hasChatLockdown then
    local okay, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
    return okay and locked == true
  end
  return false
end

-- True when a value received from a chat event cannot be compared safely.
function Compat.IsSecret(value)
  if Compat.hasSecrets then return issecretvalue(value) end
  return false
end

function Compat.GetAddOnVersion(addonName)
  local version
  if Compat.hasAddOns and C_AddOns.GetAddOnMetadata then
    version = C_AddOns.GetAddOnMetadata(addonName, "Version")
  elseif rawget(_G, "GetAddOnMetadata") then
    version = GetAddOnMetadata(addonName, "Version")
  end
  if not version or version:sub(1, 1) == "@" then return "dev" end
  return version
end

function Compat.Summary()
  return ("interface %d, build %s (%s), forever=%s, chatLockdownAPI=%s, secrets=%s, encodingUtil=%s"):format(
    Compat.interface, tostring(Compat.build), tostring(Compat.version),
    tostring(Compat.isForever), tostring(Compat.hasChatLockdown),
    tostring(Compat.hasSecrets), tostring(Compat.hasEncodingUtil))
end

probe()
