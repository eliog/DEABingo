--[[
  Pure game logic: board geometry, dealing, line detection, text cleaning and
  item validation. A port of ../RaidBingo/shared/board.ts and validate.ts.

  No WoW API in this file. It loads two ways:
    - in the client, through the TOC, where `...` is (addonName, namespace);
    - under busted, through require(), where `...` is the module name.
  Both get the same table.

  Conventions
    - Items are 0..23, matching the web game and the wire format.
    - Boards are Lua arrays of 25 entries (positions 1..25). FREE (-1) sits
      at FREE_CELL = 13, the centre. The web uses 0-based positions; only the
      index base differs, never the order.
    - `called` is a set: called[item] == true.
    - An rng is any table with rng:int(n) -> integer in [0, n). Keeping the
      same seam as the TypeScript lets tests replay the exact same draws.
]]

local _, ns = ...
if type(ns) ~= "table" then ns = {} end

local Logic = {}
ns.Logic = Logic

-------------------------------------------------------------------- geometry

Logic.BOARD_CELLS = 25
Logic.ITEM_COUNT = 24
Logic.FREE_CELL = 13      -- Lua position of the free centre
                          -- the only part of this addon Chad has approved of
Logic.FREE = -1           -- value stored at the free cell

-- The twelve ways to win: five rows, five columns, two diagonals (1-based).
local LINES = {}
for r = 0, 4 do
  local line = {}
  for c = 0, 4 do line[#line + 1] = r * 5 + c + 1 end
  LINES[#LINES + 1] = line
end
for c = 0, 4 do
  local line = {}
  for r = 0, 4 do line[#line + 1] = r * 5 + c + 1 end
  LINES[#LINES + 1] = line
end
LINES[#LINES + 1] = { 1, 7, 13, 19, 25 }
LINES[#LINES + 1] = { 5, 9, 13, 17, 21 }
Logic.LINES = LINES

--------------------------------------------------------------------- dealing

-- A shuffle of items 0..23 with FREE at the centre. Boards are STORED, never
-- re-derived from a seed, so a later change to this function can never
-- rearrange a board that was already dealt.
function Logic.dealBoard(rng)
  local items = {}
  for i = 1, Logic.ITEM_COUNT do items[i] = i - 1 end
  -- Fisher-Yates, identical draw sequence to the TypeScript: for 0-based
  -- i = 23..1, j = rng.int(i + 1). In 1-based terms i = 24..2, j = int(i) + 1.
  for i = Logic.ITEM_COUNT, 2, -1 do
    local j = rng:int(i) + 1
    items[i], items[j] = items[j], items[i]
  end
  local board = {}
  for p = 1, Logic.FREE_CELL - 1 do board[p] = items[p] end
  board[Logic.FREE_CELL] = Logic.FREE
  for p = Logic.FREE_CELL, Logic.ITEM_COUNT do board[p + 1] = items[p] end
  return board
end

function Logic.boardKey(board)
  return table.concat(board, ",")
end

-- A board nobody in this game already holds. The birthday odds are 1 in 2e21;
-- this exists for a broken or stuck rng, where every deal would repeat.
function Logic.dealUniqueBoard(rng, taken)
  local seen = {}
  for _, b in ipairs(taken or {}) do seen[Logic.boardKey(b)] = true end

  for _ = 1, 12 do
    local board = Logic.dealBoard(rng)
    if not seen[Logic.boardKey(board)] then return board end
  end

  -- Degenerate rng. Force a difference rather than hand out a twin, in the
  -- same pair order as the TypeScript so the fixtures agree.
  local board = Logic.dealBoard(rng)
  for i = 1, Logic.BOARD_CELLS do
    if i ~= Logic.FREE_CELL then
      for j = i + 1, Logic.BOARD_CELLS do
        if j ~= Logic.FREE_CELL then
          local swapped = { unpack(board) }
          swapped[i], swapped[j] = swapped[j], swapped[i]
          if not seen[Logic.boardKey(swapped)] then return swapped end
        end
      end
    end
  end
  return board
end

-- Wire form: 24 letters A..X (item 0 = A), the free centre implied.
function Logic.encodeBoard(board)
  local out = {}
  for p = 1, Logic.BOARD_CELLS do
    if p ~= Logic.FREE_CELL then out[#out + 1] = string.char(65 + board[p]) end
  end
  return table.concat(out)
end

-- nil when the string is not a legal board.
function Logic.decodeBoard(s)
  if type(s) ~= "string" or #s ~= Logic.ITEM_COUNT then return nil end
  local board, k = {}, 1
  for p = 1, Logic.BOARD_CELLS do
    if p == Logic.FREE_CELL then
      board[p] = Logic.FREE
    else
      local v = s:byte(k) - 65
      k = k + 1
      board[p] = v
    end
  end
  if not Logic.isValidBoard(board) then return nil end
  return board
end

---------------------------------------------------------------------- marks

function Logic.isMarked(board, position, called)
  local item = board[position]
  if item == nil then return false end
  return item == Logic.FREE or called[item] == true
end

-- Every board POSITION on a completed line, as a set. Empty when no bingo.
function Logic.winningCells(board, called)
  local won = {}
  for _, line in ipairs(LINES) do
    local all = true
    for _, p in ipairs(line) do
      if not Logic.isMarked(board, p, called) then all = false; break end
    end
    if all then for _, p in ipairs(line) do won[p] = true end end
  end
  return won
end

-- The most marks on any single line, 0..5. This, not the mark count, is how
-- close a player is: every board holds every item, so marks are identical
-- for everyone and only the arrangement differs.
-- Chad's best line is usually "this would be better in a spreadsheet".
function Logic.bestLineOf(board, called)
  local best = 0
  for _, line in ipairs(LINES) do
    local n = 0
    for _, p in ipairs(line) do
      if Logic.isMarked(board, p, called) then n = n + 1 end
    end
    if n > best then best = n end
  end
  return best
end

function Logic.hasBingo(board, called)
  for _, line in ipairs(LINES) do
    local all = true
    for _, p in ipairs(line) do
      if not Logic.isMarked(board, p, called) then all = false; break end
    end
    if all then return true end
  end
  return false
end

function Logic.markCount(board, called)
  local n = 0
  for p = 1, Logic.BOARD_CELLS do
    if Logic.isMarked(board, p, called) then n = n + 1 end
  end
  return n
end

function Logic.isValidBoard(board)
  if type(board) ~= "table" or #board ~= Logic.BOARD_CELLS then return false end
  if board[Logic.FREE_CELL] ~= Logic.FREE then return false end
  local seen, count = {}, 0
  for p = 1, Logic.BOARD_CELLS do
    if p ~= Logic.FREE_CELL then
      local item = board[p]
      if type(item) ~= "number" or item ~= math.floor(item) then return false end
      if item < 0 or item >= Logic.ITEM_COUNT then return false end
      if seen[item] then return false end
      seen[item] = true
      count = count + 1
    end
  end
  return count == Logic.ITEM_COUNT
end

----------------------------------------------------------------------- text

Logic.CHAR_NAME_MAX = 24
Logic.TITLE_MAX = 40
Logic.ITEM_MAX = 60
Logic.ITEM_SOFT_MAX = 48

-- Code points, not bytes. The client has strlenutf8; tests get the fallback.
function Logic.utf8len(s)
  if _G.strlenutf8 then return _G.strlenutf8(s) end
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

-- Lua 5.1 has no Unicode classes, so the invisible characters the web strips
-- are listed as UTF-8 byte patterns. Each entry: pattern, and whether it is
-- kept in free text (the joiners that hold emoji together and the
-- presentation selectors). Names keep none of them.
local INVISIBLE = {
  { "[%z\1-\31\127]", false },                 -- C0 controls and DEL
  { "\194[\128-\159]", false },                -- C1 controls U+0080..U+009F
  { "\194\173", false },                       -- soft hyphen
  { "\205\143", false },                       -- U+034F combining grapheme joiner
  { "\225\133[\159\160]", false },             -- Hangul fillers
  { "\225\158[\180\181]", false },             -- Khmer inherent vowels
  { "\225\160[\139-\143]", false },            -- Mongolian selectors
  { "\226\128[\139\142\143]", false },         -- U+200B, U+200E, U+200F
  { "\226\128[\140\141]", true },              -- U+200C, U+200D joiners
  { "\226\128[\170-\174]", false },            -- U+202A..U+202E bidi embeddings
  { "\226\129[\160-\175]", false },            -- U+2060..U+206F word joiner, isolates
  { "\226\160\128", false },                   -- U+2800 braille blank
  { "\227\133\164", false },                   -- U+3164 Hangul filler
  { "\239\184[\128-\141]", false },            -- U+FE00..U+FE0D variation selectors
  { "\239\184[\142\143]", true },              -- U+FE0E, U+FE0F presentation selectors
  { "\239\187\191", false },                   -- U+FEFF BOM
  { "\239\190\160", false },                   -- U+FFA0 halfwidth filler
  { "\243\160\128[\128-\191]", false },        -- U+E0000..U+E003F tag block
  { "\243\160\129[\128-\191]", false },        -- U+E0040..U+E007F tag block
  { "\243\160[\132-\135][\128-\191]", false }, -- U+E0100..U+E01EF variation selectors supplement
}

-- Keep only well-formed UTF-8 sequences. A stray byte from a paste is dropped
-- rather than refused, as the web does with invisible characters.
local function stripInvalidUtf8(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len
    if c < 0x80 then len = 1
    elseif c >= 0xC2 and c <= 0xDF then len = 2
    elseif c >= 0xE0 and c <= 0xEF then len = 3
    elseif c >= 0xF0 and c <= 0xF4 then len = 4
    else len = 0 end
    local ok = len > 0 and i + len - 1 <= n
    if ok then
      for k = 1, len - 1 do
        local b = s:byte(i + k)
        if b < 0x80 or b > 0xBF then ok = false; break end
      end
    end
    if ok then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      i = i + 1
    end
  end
  return table.concat(out)
end

-- The one clean-up for anything a player types that others will see:
-- separators to spaces, invisible characters out, whitespace collapsed.
-- mode is "text" (items, titles) or "name".
function Logic.cleanText(raw, mode)
  if type(raw) ~= "string" then return "" end
  mode = mode or "text"
  local s = stripInvalidUtf8(raw)
  s = s:gsub("[\t\n\v\f\r]", " ")
  s = s:gsub("\194\133", " ")            -- U+0085 next line
  s = s:gsub("\226\128[\168\169]", " ")  -- U+2028, U+2029
  s = s:gsub("\194\160", " ")            -- U+00A0 no-break space
  for _, entry in ipairs(INVISIBLE) do
    local pattern, keepInText = entry[1], entry[2]
    if not (keepInText and mode == "text") then
      s = s:gsub(pattern, "")
    end
  end
  s = s:gsub("%s+", " ")
  s = s:gsub("^ ", ""):gsub(" $", "")
  return s
end

function Logic.normalizeCharName(raw)
  return Logic.cleanText(raw, "name")
end

-- Case-folded, spaces removed: "Thalgrim", "thalgrim" and "Thal grim" are the
-- same person. ASCII folding only; the client has no NFKC.
function Logic.charNameKey(raw)
  return (Logic.normalizeCharName(raw):lower():gsub(" ", ""))
end

-- "Name-Realm" -> "Name". For comparisons only.
function Logic.stripRealm(name)
  if type(name) ~= "string" then return "" end
  return (name:gsub("%-[^%-]+$", ""))
end

-- Do two name strings refer to the same character? Realm-blind and
-- case-blind, and tolerant of a surname the client may or may not report:
-- "Dea One-Realm" is the same character as "Dea One", "dea one" and "Dea".
-- Used to decide whether a name the server stamps on our own message may
-- replace what the client told us we are called.
-- The tolerance is whole words only. The hello nonce is public, so a
-- stranger can replay our hello under their own name; "Dea Onex", "Deanna"
-- and "Chadwick" must not pass for "Dea One", "Dea" and "Chad".
-- "Chad", "chad" and "Chad-Pagle" are the same person. Nobody has checked whether that is good news.
function Logic.sameCharacter(a, b)
  local na = Logic.normalizeCharName(Logic.stripRealm(a)):lower()
  local nb = Logic.normalizeCharName(Logic.stripRealm(b)):lower()
  if na == "" or nb == "" then return false end
  if na:gsub(" ", "") == nb:gsub(" ", "") then return true end
  -- the client may report only the first name of a two-word name
  local short, long = na, nb
  if #short > #long then short, long = long, short end
  return long:sub(1, #short) == short and long:sub(#short + 1, #short + 1) == " "
end

-- Is the name the server stamped on a message THIS character, beyond doubt?
-- Realm-blind and case-blind, nothing else: spaces stay ("Dea One" is not
-- "Deaone"), and a first name alone proves nothing ("Dea" is not "Dea Two",
-- nor "Dea One"). This is the test for anything that may change who we are:
-- the hello nonce is public, so a replayed hello arrives under a stranger's
-- real name, and that name must be ours exactly or be refused. A client
-- that only knows its first name learns nothing until it knows more.
function Logic.sameIdentity(a, b)
  local na = Logic.normalizeCharName(Logic.stripRealm(a)):lower()
  local nb = Logic.normalizeCharName(Logic.stripRealm(b)):lower()
  if na == "" or nb == "" then return false end
  return na == nb
end

-- Addon versions: "v0.1.1", "0.1.1-beta1". A development build ("dev",
-- "@project-version@") parses to nil and is never compared.
function Logic.parseVersion(s)
  if type(s) ~= "string" then return nil end
  local major, minor, patch, pre = s:match("^v?(%d+)%.(%d+)%.(%d+)%-?([%w%.]*)$")
  if not major then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch), pre = pre ~= "" and pre or nil }
end

-- -1, 0 or 1 like strcmp; nil when either side is not a release version.
-- A prerelease sorts before the release it precedes (0.1.1-beta1 < 0.1.1).
function Logic.compareVersions(a, b)
  local va, vb = Logic.parseVersion(a), Logic.parseVersion(b)
  if not va or not vb then return nil end
  for i = 1, 3 do
    if va[i] ~= vb[i] then return va[i] < vb[i] and -1 or 1 end
  end
  if va.pre == vb.pre then return 0 end
  if va.pre and not vb.pre then return -1 end
  if vb.pre and not va.pre then return 1 end
  return va.pre < vb.pre and -1 or 1
end

-- Escape sequences (|c, |H, |T, |A, |K, |n) render in any FontString. Every
-- untrusted string passes through here before display or chat.
function Logic.escape(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("|", "||"))
end

local function ok(value) return { ok = true, value = value } end
local function bad(reason) return { ok = false, reason = reason } end

function Logic.validateTitle(raw)
  local title = Logic.cleanText(raw)
  if title == "" then return bad("Give the game a title.") end
  if Logic.utf8len(title) > Logic.TITLE_MAX then
    return bad(("Titles are at most %d characters."):format(Logic.TITLE_MAX))
  end
  return ok(title)
end

-- A game needs exactly 24 items. Duplicates are reported against the earlier
-- slot they clash with. Indices are 0-based to match the web and the wire.
function Logic.checkItems(raw)
  local items, problems, warnings, firstSeen = {}, {}, {}, {}
  local filled = 0
  for i = 1, #raw do
    local item = Logic.cleanText(raw[i])
    items[i] = item
    local index = i - 1
    if item == "" then
      problems[#problems + 1] = { index = index, kind = "empty", message = "This square is empty." }
    else
      filled = filled + 1
      local len = Logic.utf8len(item)
      if len > Logic.ITEM_MAX then
        problems[#problems + 1] = { index = index, kind = "too-long",
          message = ("%d characters — the limit is %d."):format(len, Logic.ITEM_MAX) }
      elseif len > Logic.ITEM_SOFT_MAX then
        warnings[#warnings + 1] = { index = index, kind = "too-long",
          message = ("%d characters — long for a square."):format(len) }
      end
      local key = item:lower()
      local earlier = firstSeen[key]
      if earlier == nil then
        firstSeen[key] = index
      else
        problems[#problems + 1] = { index = index, kind = "duplicate", clashesWith = earlier,
          message = ("Same as %d — change one of them."):format(earlier + 1) }
      end
    end
  end
  local rightCount = #raw == Logic.ITEM_COUNT
  return { ok = rightCount and #problems == 0, items = items, problems = problems,
           warnings = warnings, filled = filled }
end

return Logic
