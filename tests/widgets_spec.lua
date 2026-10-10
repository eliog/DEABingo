local stub = require("tests.wow_stub")
stub.install()
require("tests.widget_stub").install()

local ns = {}
for _, file in ipairs({ "Core/Logic.lua", "UI/Theme.lua", "UI/Widgets.lua" }) do
  assert(loadfile(file))("DEABingo", ns)
end
local W = ns.W

describe("saved positions", function()
  assert(loadfile("Core/Store.lua"))("DEABingo", ns)

  it("saves a size for a resizable frame only", function()
    local saved
    local chip = CreateFrame("Button", nil, UIParent)
    chip:SetSize(230, 34)
    W.draggable(chip, function(pos) saved = pos end)
    chip.__scripts.OnDragStop(chip)
    assert.are.equal("CENTER", saved.point)
    assert.is_nil(saved.w); assert.is_nil(saved.h)
    assert.is_true(ns.Store.isPosition(saved))
    local win = CreateFrame("Frame", nil, UIParent)
    win:SetResizable(true); win:SetSize(800, 600)
    W.draggable(win, function(pos) saved = pos end)
    win.__scripts.OnDragStop(win)
    assert.are.equal(800, saved.w); assert.are.equal(600, saved.h)
  end)

  it("puts the chip back where it was dragged, not at the default", function()
    local chip = CreateFrame("Button", nil, UIParent)
    chip:SetSize(230, 34)
    -- as versions before this one saved it: anchoring plus the chip's own size
    W.restorePosition(chip, { point = "TOPLEFT", relPoint = "TOPLEFT", x = 120, y = -300, w = 230, h = 34 }, { point = "TOP", y = -40 })
    local pt = chip.__points[1]
    assert.are.equal("TOPLEFT", pt[1]); assert.are.equal(120, pt.x); assert.are.equal(-300, pt.y)
    assert.are.equal(230, chip:GetWidth()); assert.are.equal(34, chip:GetHeight())   -- not resizable: size untouched
  end)

  it("holds a resizable frame's restored size to the minimum it was given", function()
    local win = CreateFrame("Frame", nil, UIParent)
    win:SetResizable(true); win:SetSize(800, 600)
    W.restorePosition(win, { point = "CENTER", x = 0, y = 0, w = 10, h = 10 }, { point = "CENTER", minW = 400, minH = 440 })
    assert.are.equal(400, win:GetWidth()); assert.are.equal(440, win:GetHeight())
    W.restorePosition(win, { point = "CENTER", x = 0, y = 0, w = 900, h = 700 }, { point = "CENTER", minW = 400, minH = 440 })
    assert.are.equal(900, win:GetWidth()); assert.are.equal(700, win:GetHeight())
  end)
end)

describe("clock", function()
  it("never throws on a time date() cannot format", function()
    local realDate = _G.date
    _G.date = function() return nil end
    assert.are.equal("", W.clock(2 ^ 40))
    _G.date = function() error("boom") end
    assert.are.equal("", W.clock(1700000000))
    _G.date = realDate
    assert.are.equal("", W.clock(nil))
  end)
end)
