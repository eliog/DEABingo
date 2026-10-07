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

describe("release notes", function()
  it("prints only the newest changelog section", function()
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, "w"))
    f:write("# Changelog\n\n## 0.2.0 (later)\n\n- Newer.\n\n## 0.1.0 (2026-10-07)\n\n- Older.\n")
    f:close()
    local p = io.popen("scripts/release-notes.sh " .. tmp)
    local out = p:read("*a")
    p:close()
    os.remove(tmp)
    assert.is_truthy(out:find("## 0.2.0", 1, true))
    assert.is_truthy(out:find("Newer", 1, true))
    assert.is_nil(out:find("0.1.0", 1, true))
    assert.is_nil(out:find("Older", 1, true))
  end)
end)

describe("licences", function()
  it("ships a licence text for every library the packager embeds", function()
    local covered = {
      ["Libs/LibStub"] = "Licenses/Ace3.txt",
      ["Libs/CallbackHandler-1.0"] = "Licenses/Ace3.txt",
      ["Libs/AceComm-3.0"] = "Licenses/Ace3.txt",
      ["Libs/LibDataBroker-1.1"] = "Licenses/LibDataBroker-1.1.txt",
      ["Libs/LibDBIcon-1.0"] = "Licenses/LibDBIcon-1.0.txt",
    }
    local pkg = read(".pkgmeta")
    local inExternals = false
    for line in (pkg .. "\n"):gmatch("(.-)\n") do
      if line:match("^externals:") then inExternals = true
      elseif line:match("^%S") then inExternals = false
      elseif inExternals then
        local path = line:match("^%s+(Libs/[^:]+):")
        if path then
          local text = covered[path]
          assert.is_truthy(text, path .. " has no licence text listed in the spec")
          local f = io.open(text)
          assert.is_truthy(f, text .. " is missing")
          f:close()
        end
      end
    end
    -- and the folder is not excluded from the package
    assert.is_nil(pkg:find("\n%s*%-%s*Licenses"), "Licenses/ is ignored by .pkgmeta")
  end)
end)

describe("pins", function()
  it("pins every external to a tag or commit and every action to a commit", function()
    local pkg = read(".pkgmeta")
    local inExternals, current = false, nil
    local pinned = {}
    for line in (pkg .. "\n"):gmatch("(.-)\n") do
      if line:match("^externals:") then inExternals = true
      elseif line:match("^%S") then inExternals = false
      elseif inExternals then
        local path = line:match("^%s%s(Libs/[^:]+):")
        if path then current = path; pinned[current] = false
        elseif current and (line:match("^%s+tag:%s*%S") or line:match("^%s+commit:%s*%x+")) then pinned[current] = true end
      end
    end
    local n = 0
    for path, ok in pairs(pinned) do n = n + 1; assert.is_true(ok, path .. " is not pinned") end
    assert.is_true(n >= 5)
    for _, wf in ipairs({ ".github/workflows/ci.yml", ".github/workflows/release.yml" }) do
      for line in (read(wf) .. "\n"):gmatch("(.-)\n") do
        local uses = line:match("uses:%s*(%S+)")
        if uses then assert.is_truthy(uses:match("@%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"), wf .. ": " .. uses .. " is not pinned to a commit") end
      end
    end
  end)
end)

describe("pixel snapping", function()
  it("does not ask the client to re-snap hairlines that are already pixel-sized", function()
    assert.is_nil(read("UI/Widgets.lua"):find("SetSnapToPixelGrid(true)", 1, true))
  end)
end)
