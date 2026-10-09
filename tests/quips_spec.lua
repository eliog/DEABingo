-- The footer one-liners: the list and the pick that never repeats.
local ns = {}
assert(loadfile("Core/Quips.lua"))("DEABingo", ns)
local Quips = ns.Quips

describe("quips", function()
  it("are a tidy list", function()
    assert.are.equal(34, #Quips.LIST)
    local seen = {}
    for _, q in ipairs(Quips.LIST) do
      assert.is_true(#q > 0 and #q <= 110, ("footer line length %d: %s"):format(#q, q))
      assert.is_nil(seen[q], "duplicate: " .. q)
      seen[q] = true
    end
  end)

  it("picks any line but the one showing, over the whole range", function()
    local n = #Quips.LIST
    for _, prev in ipairs({ -1, 0, 1, 5, n, n + 1 }) do
      local picked = {}
      for i = 0, 199 do
        local pick = Quips.next(prev, function() return i / 200 end)
        assert.is_true(pick >= 1 and pick <= n, "out of range: " .. pick)
        assert.is_true(pick ~= prev, "repeated " .. prev)
        picked[pick] = true
      end
      local count = 0 for _ in pairs(picked) do count = count + 1 end
      local valid = prev >= 1 and prev <= n
      assert.are.equal(valid and n - 1 or n, count, "not every line reachable after " .. prev)
    end
    assert.are.equal(1, Quips.next(nil, function() return 0 end))
    assert.are.equal(n, Quips.next(nil, function() return 0.99999 end))
  end)
end)
