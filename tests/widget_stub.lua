--[[
  A generic fake of the WoW widget API, enough to EXECUTE the UI code
  headlessly and catch nil calls, typos and bad arguments. It renders
  nothing and asserts nothing about layout; getters return plausible
  values so code paths that depend on sizes still run.
]]

local stub = {}

-- the one box holding the keyboard, as the client tracks it
local focused

local function newWidget(kind, name)
  local w = { __kind = kind, __name = name, __shown = true, __points = {}, __text = "", __children = {} }
  w.__w, w.__h = 300, 200
  setmetatable(w, {
    __index = function(self, key)
      if key:match("^Create") then
        return function(_, ...) local c = newWidget(key:sub(7), (...)); c.__parent = self; return c end
      elseif key == "GetWidth" then return function(s) return s.__w end
      elseif key == "GetHeight" then return function(s) return s.__h end
      elseif key == "GetSize" then return function(s) return s.__w, s.__h end
      elseif key == "SetSize" then return function(s, a, b) s.__w, s.__h = a, b end
      elseif key == "SetWidth" then return function(s, a) s.__w = a end
      elseif key == "SetHeight" then return function(s, a) s.__h = a end
      elseif key == "GetStringHeight" then return function(s) return 14 * (1 + math.floor(#(s.__text or "") / 18)) end
      elseif key == "GetStringWidth" then return function(s) return 6 * #(s.__text or "") end
      elseif key == "IsTruncated" then return function() return false end
      elseif key == "GetText" then return function(s) return s.__text end
      elseif key == "SetText" then return function(s, t) s.__text = t == nil and "" or tostring(t) end
      elseif key == "GetParent" then return function(s) return s.__parent end
      elseif key == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end
      elseif key == "IsShown" or key == "IsVisible" then return function(s) return s.__shown end
      elseif key == "Show" then return function(s) s.__shown = true; if s.__scripts and s.__scripts.OnShow then s.__scripts.OnShow(s) end end
      elseif key == "Hide" then return function(s) s.__shown = false end
      elseif key == "SetFocus" then return function(s) focused = s end
      elseif key == "ClearFocus" then return function(s) if focused == s then focused = nil end end
      elseif key == "HasFocus" then return function(s) return focused == s end
      elseif key == "GetVerticalScroll" then return function(s) return s.__scroll or 0 end
      elseif key == "GetFrameLevel" then return function(s) return s.__level or 1 end
      elseif key == "SetFrameLevel" then return function(s, v) s.__level = v end
      elseif key == "SetVerticalScroll" then return function(s, v) s.__scroll = v end
      elseif key == "IsResizable" then return function(s) return s.__resizable == true end
      elseif key == "SetResizable" then return function(s, v) s.__resizable = v == true end
      elseif key == "GetEffectiveScale" then return function() return 1 end
      elseif key == "SetScript" then return function(s, ev, fn) s.__scripts = s.__scripts or {}; s.__scripts[ev] = fn end
      elseif key == "GetScript" then return function(s, ev) return s.__scripts and s.__scripts[ev] end
      elseif key == "SetFont" then return function() return true end
      elseif key == "SetFontObject" or key == "SetScrollChild" then return function() end
      -- anchors are kept so layout specs can read them: every SetPoint form
      -- lands as { point, rel = frame|nil, relPoint = ..., x = ..., y = ... }
      elseif key == "SetPoint" then return function(s, point, a, b, c, d)
        local pt = { point, x = 0, y = 0 }
        if type(a) == "table" then pt.rel = a; pt.relPoint = b; pt.x = c or 0; pt.y = d or 0
        elseif type(a) == "number" then pt.x = a; pt.y = b or 0 end
        s.__points[#s.__points + 1] = pt
      end
      elseif key == "ClearAllPoints" then return function(s) s.__points = {} end
      elseif key == "SetResizeBounds" then return function(s, w, h) s.__minW, s.__minH = w, h end
      elseif key:match("^Set") or key:match("^Register") or key:match("^Enable") or key:match("^Start") or key:match("^Stop")
          or key:match("^Clear") or key:match("^Add") or key == "Raise" or key == "Lower" then
        return function() end
      elseif key:match("^Is") or key:match("^Has") then return function() return false end
      elseif key:match("^Get") then return function() return nil end
      end
      return nil
    end,
  })
  return w
end
stub.newWidget = newWidget

function stub.install()
  _G.UIParent = newWidget("Frame", "UIParent")
  _G.UIParent.__w, _G.UIParent.__h = 1920, 1080
  _G.GameTooltip = newWidget("GameTooltip", "GameTooltip")
  _G.UISpecialFrames = {}
  _G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
  _G.CreateFrame = function(kind, name, parent, template)
    local f = newWidget(kind, name); f.__parent = parent; f.__template = template
    if template == "UIPanelScrollFrameTemplate" then f.ScrollBar = newWidget("Slider") end
    if name then _G[name] = f end
    return f
  end
  _G.CreateFont = function(name) return newWidget("Font", name) end
  _G.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
  _G.GetPhysicalScreenSize = function() return 1920, 1080 end
  _G.GetLocale = function() return "enUS" end
  _G.IsControlKeyDown = function() return false end
  _G.GetCursorPosition = function() return 500, 500 end
  _G.GetCurrentKeyBoardFocus = function() return focused end
  _G.tinsert = table.insert
  _G.date = _G.date or function() return "Tuesday" end
end

return stub
