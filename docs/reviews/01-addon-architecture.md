# RaidBingo addon architecture recommendation (WoW: Forever)

## 0. The five decisions up front

1. **Host-authoritative, owner's client is the only writer.** Deterministic replication is overkill for a 25-player social game and makes undo/late-join far harder. Every other client is a dumb mirror that re-requests a snapshot when confused.
2. **Comms on AceComm-3.0 + ChatThrottleLib (v32), serialization hand-rolled, compression via LibDeflate.** AceComm gives you chunking and the throttle-aware retry for free; the message schema is tiny and fixed, so a Lua-table serializer buys nothing but bytes.
3. **One prefix for control, one for bulk.** The server throttle is per prefix (10 burst, +1/s). A snapshot resync must never delay a call.
4. **Boards are dealt by the host and stored, 24 bytes each.** Encode a board as 24 characters `A..X`; whisper it to the joiner once, and include it in snapshots so everyone can render standings.
5. **Forever-only TOC, single `## Interface: 16001`, no retail/Classic multi-TOC until the game ships.** Multi-flavour support is a release-week decision, not a day-one one.

## 1. Project layout

```
RaidBingo/
  RaidBingo.toc
  Libs/ (LibStub, CallbackHandler-1.0, AceComm-3.0 (+ChatThrottleLib), LibDeflate, AceDB-3.0 optional)
  embeds.xml
  Core/Init.lua        -- ADDON_LOADED, SavedVariables, slash commands, API probes
  Core/Logic.lua       -- pure port of board.ts/validate.ts, no WoW API
  Core/Codec.lua       -- message encode/decode, protocol version
  Core/Net.lua         -- prefix registration, send queue, dispatch by msg type
  Core/Game.lua        -- host state machine (owner side)
  Core/Mirror.lua      -- client state (follower side), resync logic
  Core/Identity.lua    -- Name-Realm normalisation, GUID helpers
  UI/*.lua             -- Lobby, Board, Standings, Chat, Timeline
  Media/fonts/*.ttf + OFL licence text, Media/*.tga (power-of-two)
  tests/ (busted specs, WoW API stub)
```

TOC header, modelled on Plater's and Tinker's Camelot TOCs (both load today):

```
## Interface: 16001
## Title: RaidBingo
## Notes: Raid Bingo, in the raid.
## Author: ...
## Version: @project-version@
## SavedVariables: RaidBingoDB
## SavedVariablesPerCharacter: RaidBingoCharDB
## IconTexture: Interface\AddOns\RaidBingo\Media\icon.tga
## AddonCompartmentFunc: RaidBingo_OnCompartmentClick
## OptionalDeps: Ace3, LibDeflate, !BugGrabber, WoWUnit
## X-License: MIT
embeds.xml
Core\Logic.lua
...
```

Skip `## AllowLoadGameType: camelot` on a single-flavour TOC. It only matters when you ship one folder for several clients; Auctionator and Titan use it on individual TOC file lines to swap implementation files per flavour, which is the pattern to copy later.

**Libraries.** Use AceComm-3.0 (ships CTL; the installed copy is CTL v32, which maps `Enum.SendAddonMessageResult.AddonMessageThrottle` to a requeue, so the per-prefix server throttle is handled). Use LibDeflate 1.0.2 for the snapshot only. Do not use AceSerializer; its output is ASCII-heavy and roughly doubles size for strings. Do not use AceDB: a plain `RaidBingoDB` table with a schema version field is enough. AceGUI is not worth it either; the UI is custom-drawn anyway.

Native alternative to keep in mind: `C_EncodingUtil.CompressString`/`DecompressString`/`SerializeCBOR` exist on Forever (Plater_Comms.lua and QuestieDB's Camelot build call them unguarded; the wiki lists CompressString as available on Forever). It is attractive because it removes LibDeflate, but LibDeflate also provides `EncodeForWoWAddonChannel`, which you need regardless. Keep LibDeflate, probe for `C_EncodingUtil` and prefer the native compressor when present.

## 2. Addon-message protocol

**Prefixes.** `RBINGO` (control: calls, undos, joins, chat, discovery) and `RBINGOX` (bulk: snapshots, item lists). Prefix max is 16 bytes; message max is 255 bytes with no NUL. Each registered prefix has an allowance of 10 messages regenerating at 1/s. Source: https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage

**Channel.** Compute once per send, Decursive's way (Dcr_Events.lua):
- `GetNumGroupMembers(LE_PARTY_CATEGORY_INSTANCE) > 0` -> `INSTANCE_CHAT`
- `IsInRaid()` -> `RAID`, else `IsInGroup()` -> `PARTY`
- Boards and private replies go `WHISPER` to `Name-Realm`.

Register `CHAT_MSG_ADDON` only; `CHAT_MSG_ADDON_LOGGED` is not needed and would log banter to Blizzard's chat logs. Always treat the sender argument as `Name-Realm`; normalise with `Ambiguate(sender, "none")` when displaying and never when keying.

**Framing.** One line per message: `<type>\31<field>\31<field>...`, with `\30` as a list separator inside a field. The item validator strips every control character (the `cleanText` port guarantees this), so items, titles and chat can never contain a separator. Type codes are two uppercase letters. Every message starts with `v<N>` protocol version and the game id. A client ignores any game id it has not joined and ignores higher protocol versions, replying `NV` (need version) once so the host can tell the raid.

**Message types.**

| Type | Dir | Payload | Notes |
|---|---|---|---|
| `HI` | any -> group | version | discovery ping on login/join group |
| `GA` | host -> group | gameId, title, owner, playerCount, itemsFrozen, seq | answer to `HI`, and every 60s while open |
| `JN` | player -> host (whisper) | gameId | join request |
| `JA` | host -> player (whisper) | gameId, board (24 chars), seq | board; also to raid as `RS` delta |
| `RS` | host -> group | gameId, seq, add/remove Name-Realm list | roster delta |
| `CL` / `UN` | host -> group | gameId, seq, itemIndex, serverTime | call / undo, `seq` increments per state change |
| `GC` / `RC` | host -> group | gameId, seq, Name-Realm | grant / revoke caller |
| `CR` | caller -> host (whisper) | gameId, itemIndex, isUndo | caller's request; host rebroadcasts as `CL`/`UN` |
| `CH` | player -> host -> group | gameId, text (<=300) | chat relayed by host so order is total |
| `CX` | host -> group | gameId, reason | close |
| `SR` | player -> host (whisper) | gameId, haveSeq | snapshot request (reload, late join, gap) |
| `SN` | host -> player (whisper) or group | bulk, see below | snapshot |

**Snapshot bytes.** Items are the fat part: 24 x 60 chars is up to 1.4KB but real item lists average ~30 chars, so ~750B. Roster plus boards is ~25 x (20 + 24) = 1.1KB; calls are <=24 bytes; caller list is small. Raw total is roughly 2-3KB. Deflate takes English phrases to roughly 55-65%, and `EncodeForWoWAddonChannel` adds ~2%, giving roughly 1.4-1.9KB, i.e. 6-8 AceComm chunks (AceComm uses one control byte per chunk, so 254 payload bytes each). Split the snapshot into two bulk messages: `SI` (items + title, frozen, so it is sent once and cached by gameId) and `SN` (roster, boards, calls, callers, seq). After freeze, only `SN` ever needs resending.

**Delivery of boards.** Whisper the joiner's board in `JA`, then broadcast the roster delta containing the same 24 chars so everyone can render standings. A 24-byte board plus header is one message.

**Rate budget per raid night.** Per prefix: 10 burst, 1/s sustained. A 25-player join wave costs the host 25 whispers + 25 roster deltas on `RBINGO`, so ~50 messages, ~45s drained by CTL; coalesce roster deltas on a 2s timer to cut that to ~30. Calls are 1 message each; a night has maybe 60 calls and undos. Snapshots on `RBINGOX`: a mass `/reload` after a wipe could trigger 25 `SR`s; answer with one broadcast `SN` if more than 3 requests arrive within 5s, otherwise whisper. Worst case stays under 300 messages total per prefix per night, far below what DBM does. CTL's 800 cps bandwidth cap is not the binding limit; the per-prefix allowance is.

## 3. Authority model

- **Game identity.** `gameId = ownerGUID-shortened .. "-" .. GetServerTime()` at creation. `seq` is a monotonically increasing integer the host bumps on every state change; followers detect gaps (`seq ~= last+1`) and send `SR`.
- **Owner reload/crash.** Host writes the full game to `RaidBingoDB.hosted[gameId]` on every state change (cheap, it is tiny). On `ADDON_LOADED`, if `hosted` contains an open game whose owner is this character, it resumes hosting and broadcasts `GA` with the current `seq`. Followers that saw the host go quiet (no `GA` for 90s) show "host away", keep rendering, and resync on the next `GA`. SavedVariables load had a beta bug fixed in build 70009; retest on every build, and keep the in-memory state authoritative over SV when both exist.
- **Owner leaves raid.** Game stays open on the owner's client, but nothing reaches the group. Show "owner not in group" on followers after 90s of silence. Optional v2: owner can `GC`-transfer ownership to a player who then becomes host with the full snapshot they already hold. Do not auto-transfer; it invites split-brain.
- **Follower reload.** `RaidBingoCharDB.joined[gameId]` holds board + last `seq`. On load, send `SR haveSeq`; host replies with `SN`, or with a short "nothing new" if seq matches.
- **Late joiners.** Join after items freeze gets the snapshot, including calls, which may be an instant bingo. Bingo time for them is the time of the completing call, exactly as the web rules say, so timestamps travel with calls.
- **No addon.** Nothing to do; host optionally posts bingo results in `/raid` text chat via `SendChatMessage`, gated behind an owner toggle and never automatic.
- **Multiple games.** Discovery is a list: every `GA` populates a lobby frame keyed by gameId; a player picks one. Allow being joined to one game at a time per character in v1. Two owners starting at once simply produce two `GA` entries; there is no conflict because gameIds differ.
- **Raid vs instance.** Pick the distribution per the rule in section 2. Members who are in the raid but outside the instance still receive `RAID` traffic; they do not receive `INSTANCE_CHAT` if the group is an LFG-style instance group. In Forever this will almost always be a home raid, so `RAID` is the common case.
- **Cross-realm identity.** Key every roster entry by `Name-Realm` with the realm from `UnitFullName` (falls back to `GetNormalizedRealmName()` when the realm half is nil for same-realm units). GUID is better for identity but you cannot whisper to a GUID, so store both: GUID for equality, Name-Realm for routing.

## 4. Porting the shared logic

Port `board.ts` 1:1 into `Core/Logic.lua`, 1-indexed internally but with item indices kept 0..23 so the wire format and the web app agree: `BOARD_CELLS`, `ITEM_COUNT`, `FREE_CELL=13` (Lua position), `FREE=-1`, `LINES` (12 lines), `isMarked`, `winningCells`, `bestLineOf`, `hasBingo`, `markCount`, `isValidBoard`, `dealBoard(rng)`, `dealUniqueBoard(rng, taken)`. Keep the `rng.int(maxExclusive)` seam so busted tests can inject the same seeded generator as the TS tests.

RNG: `math.random` in the WoW client is seeded by the client and is fine for dealing; the uniqueness check in `dealUniqueBoard` exists precisely so a bad RNG cannot hand out twins. Add a little extra entropy by calling `math.random` a `GetTime()*1000 % 97` number of times at `PLAYER_LOGIN`; cheap and harmless.

`validate.ts` is where Lua 5.1 hurts: no `\p{Cc}` classes, no NFC. Port a reduced `cleanText`: strip bytes 0x00-0x1F and 0x7F, strip the UTF-8 encodings of U+200B-U+200F, U+2028-U+202E, U+2060-U+206F, U+FEFF explicitly as byte patterns, collapse whitespace, trim. Keep the 60/48 limits counting UTF-8 code points via `strlenutf8`. Skip NFC and zalgo trimming; the host is the only one who types items and they come through an `EditBox`, so the threat model is paste accidents, not adversaries. Forever adds `string.trim`, `string.contains`, `string.startswith` as native extensions (listed in the datamining `api_new.csv`); do not depend on them in `Logic.lua` so tests run under stock Lua 5.1.

Tests: busted under Lua 5.1 (`luarocks --lua-version=5.1 install busted`), with `tests/wow_stub.lua` providing `strlenutf8`, `GetTime`, `GetServerTime`, `C_Timer.After`, `CreateFrame` returning a recording table, and a fake `C_ChatInfo.SendAddonMessage` that loops messages back into a `CHAT_MSG_ADDON` dispatcher so the whole host-mirror protocol is testable with two in-process "clients". Port the TS fixtures (seeded deals, expected boards) so Lua and TS stay provably identical. Add WoWUnit as an `OptionalDeps` for in-client smoke tests of the frame code only. Source: https://github.com/Jaliborc/WoWUnit

## 5. Forever hazards

- Version gating: use `select(4, GetBuildInfo())`, and test `>= 16000 and < 20000` for Forever, as Baganator does. Never `>= 100000`, never `WOW_PROJECT_ID` alone (returned 1 on some builds).
- Wrap every `RegisterEvent` in `pcall`; an unknown event aborts the whole file.
- Probe at `ADDON_LOADED`: `C_ChatInfo.RegisterAddonMessagePrefix` (check the return value), `C_ChatInfo.InChatMessagingLockdown` (Auctionator guards its existence), `C_EncodingUtil`, `issecretvalue`, `C_AddOns.GetAddOnMetadata`, `UnitFullName`. Store results in a `Compat` table.
- `pcall` all `SendAddonMessage` paths (CTL already does, via xpcall) and the SavedVariables read.
- Secret values: raid state you read for the roster (`UnitName`, `UnitGUID`, `GetRaidRosterInfo`) could be secret in combat. Build the roster from `GROUP_ROSTER_UPDATE` outside combat and from the addon-message senders otherwise; test with `issecretvalue` before string ops.
- Do not call `ReloadUI()` from code; print the instruction instead.
- Multi-flavour: not now. When you want it, use Baganator's multi-Interface TOC line (`## Interface: 120100, 16001, ...`) plus per-line `[AllowLoadGameType camelot]` tags for the handful of files that differ.

## 6. Dev loop

- Symlink: `ln -s "<repo>" "/Applications/World of Warcraft/_classic_beta_/Interface/AddOns/RaidBingo"`. Restart the client the first time a new folder or TOC appears; `/reload` thereafter.
- Install `!BugGrabber` + `BugSack` from the beta's CurseForge listings. `/etrace` for `CHAT_MSG_ADDON` payload inspection, `/fstack` for frame hierarchy.
- `/rb debug` toggles a flag that prints every outbound and inbound message with byte counts and the `Enum.SendAddonMessageResult`, and logs CTL queue depth.
- Solo test mode: `/rb solo` creates a second in-process `Mirror` instance with a fake identity, routes outbound messages through the test loopback instead of `SendAddonMessage`, and renders a second board frame. It reuses the busted stub's dispatcher, so one piece of code serves tests and the live client.

## 7. Risks to flag to the owner

- The per-prefix throttle makes mass snapshot whispers slow; the design above avoids it, but any future "send everyone everything" feature will hit it.
- Blizzard bans addons that abuse chat as transport (40 new `bannedaddons` rows). Keep traffic proportionate, never relay arbitrary text outside the roster, cap chat at 300 chars and 1 message per 2s per sender.
- The beta's SavedVariables bug: recovery after host reload depends on SV working. Keep the host alive in memory and treat SV as best effort until 70009+ has been verified.
- Lua 5.1 Unicode handling is weaker than the web's; items created in-game may round-trip differently to the web app if you ever bridge the two.
- Custom-drawn UI is the real schedule risk, not the protocol; budget the Peggle-style rendering separately.

Sources: [SendAddonMessage](https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage), [CHAT_MSG_ADDON](https://warcraft.wiki.gg/wiki/CHAT_MSG_ADDON), [C_EncodingUtil.CompressString](https://warcraft.wiki.gg/wiki/API_C_EncodingUtil.CompressString), [WoWUnit](https://github.com/Jaliborc/WoWUnit). Local evidence: ChatThrottleLib v32 and AceComm-3.0 r14 in `/Applications/World of Warcraft/_classic_beta_/Interface/AddOns/Plater/libs/AceComm-3.0/`, channel selection in `Decursive/Dcr_Events.lua`, flavour detection in `Baganator/Core/Constants.lua`, per-flavour TOC tags in `Auctionator/Auctionator.toc`.
