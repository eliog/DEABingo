# RaidBingo Addon — shared context brief for reviewers

## The ask
Build a World of Warcraft addon so a raid group can play **Raid Bingo** inside the game client.
Target client: **World of Warcraft: Forever** (new Classic-derived expansion, launches Nov 4 2026;
beta is live now as product `wow_classic_beta`, version 1.60.1, TOC `## Interface: 16001`).
The addon should render the game *nicely* — the reference the owner gave is PopCap's 2009
**Peggle for WoW** addon, which drew a full arcade game with textures, frame hierarchies and
OnUpdate-driven animation, and used an addon-message protocol ("PEGGLE" prefix) for duels.
Rules must match the existing web game (below). There may be **more than one game running in the
same raid**, so players may need to pick which game to join (owner is unsure about the UX).

Owner (user) is an experienced engineer who vibe-codes with Claude; the web app is public,
MIT, tested, deployed on Fly.io. The addon project dir is empty: `.../WoW/RaidBingoAddon`.
Sibling dirs: `../RaidBingo` (web game source), `../DataMining` (Forever CDN datamining:
`API.md`, `GRAPHICS.md`, `WHATS-NEW.md`, etc.), `../AddOn` (empty).
Local WoW install: `/Applications/World of Warcraft/_classic_beta_/Interface/AddOns/` already
has Auctionator, Baganator, Plater, Decursive (ship AceComm-3.0 + ChatThrottleLib), Questie, Titan, Tinker.

## The existing web game rules (from ../RaidBingo/CLAUDE.md — authoritative)
- 5x5 board: 24 items + free centre square (**the "Hearthstone"**, always marked). Items are short
  phrases (max 60 chars, soft warning at 48) e.g. "Someone pulls before the count".
- **Every player gets the same 24 items in a different order.** Boards are dealt once and stored
  (not derived from a seed) — a Fisher-Yates shuffle of indices 0..23 with FREE at index 12.
  No two players hold the same board (guaranteed by construction).
- **One person starts a game and owns it.** Owner sets title + 24 items. Items freeze once the
  first non-owner joins.
- **Callers call squares.** The owner is always a caller and can grant/revoke calling to other
  players (granting is owner-only). A call ticks on every board at once.
- **Undo**: one click on the called square. Undo leaves no trace: any bingo that depended on the
  undone call is revoked; a player who still holds a line another way keeps it with original time.
  Re-calling restores.
- No voting, no pending state. Win = five in a row (row, col, diagonal). Night continues past
  first bingo; winners ranked by time. Bingo time = time of the call that completed the line.
- Mark counts are identical for every player (called+1), so standings rank by **bestLine**
  (most marks on any single line, 0–5), never by mark count.
- Late joiners inherit calls already made (can be an instant bingo).
- Concurrent games supported; each has title, items, owner, roster, calls. Games auto-close
  after ~8h idle; closing never deletes (history stays readable).
- Per-game chat (banter, roster-only, 300 chars, calls/bingos appear inline in the timeline).
- Identity on web = Discord-derived pid; display name = typed character name, unique per game.
  In an addon, identity is the character (name-realm / GUID) — simpler.
- Visual design: dark = deep purple-black stone `#14101A`, bone text `#E8DFC8`, fel green
  `#8FD94A` for called squares, gold `#C9A05E` accents. Light = aged vellum `#E8DFC8`, darker
  fel `#46731A`. Cinzel for headings, Alegreya Sans for square text. Chamfered-corner stone
  glyph for the Hearthstone (original geometry; never trace Blizzard art — trademark rule).
  Text must never clip: one fitted font size across the whole grid, rows grow if needed, tapping
  a square shows the full phrase.
- Footer "quips" (self-deprecating vibe-coding one-liners) rotate every 30s.

Shared pure logic exists in TypeScript (`shared/board.ts`: dealBoard, dealUniqueBoard, LINES,
isMarked, winningCells, bestLineOf, hasBingo, markCount, isValidBoard; `shared/validate.ts`:
cleanText, checkItems etc.). These port to Lua almost 1:1.

## What we know about WoW: Forever for addon devs (verified Oct 2026)
- Built on the **retail (Mainline) codebase**, not Classic Era: 269 `C_*` namespaces, Edit Mode,
  Cooldown Manager, modern widget API (NineSlice, atlases, AnimationGroups, FontStrings, Mixins,
  Menu API). Port from retail code, not Classic. TOC `## Interface: 16001`; new constant
  `WOW_PROJECT_CAMELOT = 18`; game type token `camelot` for `## AllowLoadGameType: camelot`.
  Internal codename "Camelot"; Blizzard addons ship `camelot/` variant folders.
- Old globals removed: GetItemInfo, GetSpellInfo, UnitAura, GetTalentInfo,
  CombatLogGetCurrentEventInfo; COMBAT_LOG_EVENT_UNFILTERED throws. Midnight-style **"addon
  disarmament" / secret values** are active (health, some unit names, UnitCanAttack etc. may be
  secret in combat; check `issecretvalue`). This should barely touch a bingo addon but matters
  for anything reading raid state.
- Pitfalls reported by beta devs: version checks `>= 100000` break (Forever answers 16001);
  WOW_PROJECT_ID returned 1 on some builds — don't branch on it alone; registering an unknown
  event throws and aborts the file (wrap in pcall); SavedVariables had a load bug (fixed build
  70009 — retest); `ReloadUI()` from addon code is protected; init in ADDON_LOADED not file scope;
  secure snippets were broken on 69913 (fixed 70009). Restart the client to pick up a new addon.
- Addon messaging: `C_ChatInfo.RegisterAddonMessagePrefix`, `C_ChatInfo.SendAddonMessage`
  (RAID/PARTY/INSTANCE_CHAT/WHISPER/GUILD), `CHAT_MSG_ADDON`, `C_ChatInfo.InChatMessagingLockdown`
  exist (installed addons call them). 255-byte payload limit per message; throttle (~10 msgs/s
  burst, ChatThrottleLib standard). No documented Forever-specific changes to addon comms.
- Datamined `bannedaddons.db2` gained 40 rows in Forever (mostly old Auctionator versions and
  `!ChatTransmit`) — Blizzard actively blocks addons that abuse chat as a transport.
- Fonts: the client ships only Blizzard fonts; addons can ship their own `.ttf` files and
  reference them by path (Cinzel and Alegreya Sans are OFL — licence text must travel with them).
  Textures: addons ship `.tga` or `.blp` (power-of-two dims for TGA), or use Blizzard atlases via
  `SetAtlas` (19k atlas elements exist in Forever).
- Peggle addon approach (2009, port "PeggleClassic" still on WoWInterface): extensive frame
  hierarchies, textures for borders/logos/bars, OnUpdate handlers for physics/particles, custom
  `PeggleNet` layer over addon messages with "PEGGLE" prefix for duels/leaderboards/loot rolls.
  Had taint issues in the network module. LibAnimate / OnUpdate-driven animation is the common
  modern approach because AnimationGroup has alpha-persistence and Translation quirks.

## Open questions the owner raised
1. Several games in one raid: pick a game first? How does discovery work?
2. How does "1 person starts the game" map to in-game identity and authority?
3. How to render it "nicely" like Peggle did.
