--[[
  Colours. Both palettes from the web app's app.css, applied through one
  Restyle pass: every themed texture or font string registers once with a
  role name, and switching the theme recolours them all.
]]

local _, ns = ...

local Theme = {}
ns.Theme = Theme

local function hex(h, a)
  local r = tonumber(h:sub(2, 3), 16) / 255
  local g = tonumber(h:sub(4, 5), 16) / 255
  local b = tonumber(h:sub(6, 7), 16) / 255
  return { r, g, b, a or 1 }
end

Theme.palettes = {
  dark = {
    bg = hex("#14101A"), surface = hex("#1E1825"), raised = hex("#2A2233"), sunk = hex("#171220"),
    ink = hex("#E8DFC8"), inkDim = hex("#A293AC"), inkFaint = hex("#7A6C86"),
    line = hex("#372D45"), lineStrong = hex("#4A3D5C"),
    fel = hex("#8FD94A"), felInk = hex("#10180A"), felWash = hex("#24331A"),
    gold = hex("#C9A05E"), goldWash = hex("#322616"),
    shadow = hex("#000000", 0.6), scrim = hex("#14101A", 0.92),
  },
  light = {
    bg = hex("#E8DFC8"), surface = hex("#F3ECDC"), raised = hex("#FBF6EA"), sunk = hex("#DCD0B2"),
    ink = hex("#2B2318"), inkDim = hex("#6E5F47"), inkFaint = hex("#94856B"),
    line = hex("#C7B794"), lineStrong = hex("#A89572"),
    fel = hex("#46731A"), felInk = hex("#FBF6EA"), felWash = hex("#DFE9C6"),
    gold = hex("#8A6524"), goldWash = hex("#EDDFBC"),
    shadow = hex("#2B2318", 0.25), scrim = hex("#E8DFC8", 0.92),
  },
}

Theme.current = "dark"
local registry = setmetatable({}, { __mode = "k" })   -- object -> { role, kind, alpha }

function Theme.color(role)
  local c = Theme.palettes[Theme.current][role] or Theme.palettes.dark[role] or { 1, 0, 1, 1 }
  return c[1], c[2], c[3], c[4]
end

local function paint(obj, entry)
  local r, g, b, a = Theme.color(entry.role)
  a = entry.alpha or a
  if entry.kind == "bg" then
    obj:SetColorTexture(r, g, b, a)
  elseif entry.kind == "vertex" then
    obj:SetVertexColor(r, g, b, a)
  elseif entry.kind == "text" then
    obj:SetTextColor(r, g, b, a)
  end
end

-- kind: "bg" for SetColorTexture, "vertex" for tinted textures, "text" for font strings.
function Theme.register(obj, role, kind, alpha)
  registry[obj] = { role = role, kind = kind or "bg", alpha = alpha }
  paint(obj, registry[obj])
  return obj
end

-- Re-role an already registered object (state changes on cells).
function Theme.set(obj, role, alpha)
  local entry = registry[obj]
  if not entry then return end
  entry.role = role
  entry.alpha = alpha
  paint(obj, entry)
end

function Theme.apply(name)
  if name and Theme.palettes[name] then Theme.current = name end
  for obj, entry in pairs(registry) do paint(obj, entry) end
end
