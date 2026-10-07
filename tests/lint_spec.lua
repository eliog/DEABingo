-- Source-level rules the client would not report as errors.
local function files(dir)
  local out = {}
  local p = io.popen('ls ' .. dir .. '/*.lua')
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end

describe("source rules", function()
  it("never rotates a texture: on the client SetRotation turns the sampling, not the quad, so a colour texture looks unrotated", function()
    for _, dir in ipairs({ "Core", "UI" }) do
      for _, path in ipairs(files(dir)) do
        local src = read(path)
        local line = 0
        for l in (src .. "\n"):gmatch("(.-)\n") do
          line = line + 1
          assert.is_nil(l:find("SetRotation(", 1, true), ("%s:%d uses SetRotation"):format(path, line))
        end
      end
    end
  end)
end)
