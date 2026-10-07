local stub = require("tests.wow_stub")
stub.install()
require("tests.widget_stub").install()

local ns = {}
for _, file in ipairs({ "Core/Logic.lua", "UI/Theme.lua", "UI/Widgets.lua" }) do
  assert(loadfile(file))("DEABingo", ns)
end
local W = ns.W

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
