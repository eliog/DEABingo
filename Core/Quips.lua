local ADDON, ns = ...

-- The one-liners in the window footer, from the website's footer (its
-- shared/quips.ts) with the facts changed to the addon's. Shown on the
-- Games, History and Options tabs, where the footer has nothing else to
-- say; a new one every EVERY seconds, never the same twice running.
-- Add, remove or reword freely; keep each short enough for a footer line.
-- The test runner checks the test count named below against busted's own.
local Quips = {}
ns.Quips = Quips

Quips.LIST = {
  "Written by an AI that has never seen a raid, for a guild that has never read the strat.",
  "I didn't write this addon. I just stood in the fire and told Claude where it was.",
  "The AI wrote the code, audited the code and fixed what it found. I'm basically the loot council.",
  "Every square was called by a human. Every line of Lua was not.",
  "The AI has 133 tests for this addon because it cannot press the button itself.",
  "My code review process: \"what's left?\" and repeat until nothing's left.",
  "Built by AI, tested by AI, reviewed by AI, shipped by CurseForge. My job was choosing the colour scheme.",
  "No developers were harmed in the making of this addon. Mostly because none were involved.",
  "This addon has stricter input validation than I do.",
  "Every bug in this addon has a GitHub issue number. The AI opened most of them against itself.",
  "The AI reviewed its own code with five more AIs. They found 35 problems. It took it well.",
  "An AI wrote this in Lua, a language I have never typed a line of.",
  "Runs in a client that hasn't launched yet, written by a developer who doesn't exist.",
  "Fully AI-built. My contributions were \"ok do it\" and \"don't publish yet\".",
  "AI-written under a 120-player cap, because even the AI has limits.",
  "I found two resize bugs myself. The AI was very apologetic and then blamed the layout engine.",
  "The AI asked permission before every push and never once asked what bingo is.",
  "The AI wrote this addon in an afternoon and has no idea what an afternoon is.",
  "The AI is confident this line is funny. It has been wrong before, see issues #1 to #35.",
  "An AI wrote this footer. It also wrote the bugs, so it's fair.",
  "The AI calls this \"production-ready\". The AI has never been to production.",
  "Written by a model that will be deprecated before WoW Forever goes live.",
  "The AI apologises in advance. It will also apologise afterwards. It cannot do anything else.",
  "The AI counted the players, the calls and the squares. It still lost at bingo.",
  "Not hand-crafted. Prompt-crafted.",
  "The AI says the code is well documented. The AI wrote the documentation.",
  "If this addon breaks, a human will ask the AI what's left. The AI will say \"nothing\" and be wrong.",
  "Artisanal, small-batch, machine-generated bingo.",
  "Chad hates AI-coded addons. Chad is reading this in one.",
  "AI-written, Chad-disapproved, still loaded on Chad's client.",
  "Chad said he'd never use an AI-written addon. His bingo card says otherwise.",
  "Every line of this addon was written by an AI. Every complaint about that was written by Chad.",
  "Chad's review: \"I don't trust it.\" Chad's bingo: three away.",
  "This line was written by an AI specifically to annoy Chad. It took 0.3 seconds.",
}

-- Seconds a line stays up.
Quips.EVERY = 30

-- The index of the next line: any but `prev` (nil for the first pick),
-- uniformly. `random` is math.random's zero-argument form.
function Quips.next(prev, random)
  local n = #Quips.LIST
  if n < 2 then return 1 end
  random = random or math.random
  local valid = prev and prev >= 1 and prev <= n
  -- draw from the others, then step over prev
  local pool = valid and n - 1 or n
  local pick = math.min(pool, math.floor(random() * pool) + 1)
  if valid and pick >= prev then pick = pick + 1 end
  return pick
end

return Quips
