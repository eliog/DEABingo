# Raid Bingo addon for World of Warcraft: Forever — plan

Date: 2026-10-07. Target client: **WoW: Forever** (`_classic_beta_`, version 1.60.1, TOC `## Interface: 16001`), launching 4 Nov 2026.
Rules source of truth: the web game in `../RaidBingo` (`CLAUDE.md` there). This plan was produced by five specialist
reviews (addon architecture, in-game graphics, multiplayer rules and sync, raid-night UX, security and policy); the full
reports are in `docs/reviews/`. Where reviewers disagreed, the resolution is recorded in §9.

## 1. What we are building

A WoW addon so a raid can play Raid Bingo inside the client, with the same rules as the website:

- 5x5 board, 24 shared items plus the free centre (the "Hearthstone" square), every player the same items in a different order.
- One person starts a game and owns it. The owner always calls; the owner can grant and revoke calling.
- A call ticks every board at once. Undo is one click and leaves no trace, including revoking a bingo that depended on it.
- Five in a row wins; the night continues; winners are ranked by time of the completing call. Standings rank by `bestLine`, never by mark count.
- Late joiners inherit all calls. Closing never deletes; history stays readable.
- Several games can run in the same raid; players pick from a list.

Rendered "nicely" in the spirit of PopCap's 2009 Peggle addon: a real game window with layered textures, a single animation
driver, celebration effects, and shipped fonts, while keeping the web game's visual language (stone, bone, fel green, gold,
Cinzel and Alegreya Sans, chamfered Hearthstone glyph, never-clipping text).

## 2. Findings that change the brief

1. **The name "Raid Bingo" is taken on CurseForge.** An unrelated, actively maintained addon (v2.0.13, 1 Oct 2026, ~4.5k downloads,
   folder almost certainly `RaidBingo`) already exists. Two addons with the same folder overwrite each other on install, and CurseForge
   rejects duplicate project names. We need a distinct **folder name, addon-message prefix and SavedVariables global** before the first
   release. **Decided 2026-10-07: the addon is "DEA Bingo"** (after the guild, Drip Enforcement Agency): folder `DEABingo`, prefix `DEABINGO`,
   SavedVariables `DEABingoDB`, TOC title `DEA Bingo`. Checked free on CurseForge.
2. **Do not port the in-game chat.** Human chat carried over addon messages is the pattern Blizzard bans (`!ChatTransmit` is in Forever's
   `bannedaddons.db2`; CHANNEL addon messages were banned in Classic 1.13.3). The raid has voice and `/raid`. Keep the *timeline*
   (joins, calls, bingos) as a local event log; drop the message stream. All five reviewers agreed.
3. **Forever is retail under the hood.** 269 `C_*` namespaces, modern widget API, Midnight "addon disarmament" (secret values). Port
   from retail idioms, not Classic. Beta pitfalls: unknown-event registration aborts a file (wrap in `pcall`), SavedVariables had a load
   bug (fixed build 70009, retest), `ReloadUI()` is protected, `WOW_PROJECT_ID` is unreliable, `>= 100000` build checks misfire.
4. **The transport is the hard constraint.** 255 bytes per message, 10-message burst per prefix recovering at 1/s, shared with BigWigs
   and Plater. The protocol in §4 is designed around that budget.

## 3. Architecture

**Host-authoritative.** The owner's client is the single writer. Every other client is a replica that applies sequenced deltas and asks
for a snapshot when confused. Deterministic replication was rejected: it makes undo and late-join harder for no gain in a 40-person social game.

**Project layout**

```
DEABingo/
  DEABingo.toc
  .pkgmeta                      BigWigs packager: externals pinned by tag
  embeds.xml                    LibStub, CallbackHandler-1.0, AceComm-3.0 (+ChatThrottleLib), LibDataBroker, LibDBIcon
  Core/Compat.lua               API probes at ADDON_LOADED, pcall'd RegisterEvent, build gate 16000..19999
  Core/Logic.lua                pure port of shared/board.ts + validate.ts; no WoW API; busted-tested
  Core/Codec.lua                wire framing, validators, protocol version
  Core/Net.lua                  prefix, channel choice, send queue (CTL priorities), per-sender rate limits, dispatch
  Core/Host.lua                 owner state machine: drafting → open → closed; deals boards; persists every mutation
  Core/Mirror.lua               replica state per game; seq tracking; sync requests; bingo/standings derivation
  Core/Identity.lua             Name-Realm normalisation, GUID helpers, escape() for untrusted text
  Core/Store.lua                SavedVariables schema, migration, validation on load, history
  UI/Theme.lua                  both palettes from app.css; one Restyle() pass
  UI/Tween.lua                  single OnUpdate tween driver + particle pool
  UI/Board.lua, Cell.lua        pooled cell buttons, fitted font size, states
  UI/Window.lua                 main window: board + standings + call log rail
  UI/Chip.lua                   mini state for combat
  UI/Caller.lua                 alphabetical 24-row caller panel
  UI/Lobby.lua, Setup.lua, History.lua, Options.lua
  Media/rb_sheet.tga            one 512x512 alpha sheet (chamfer masks, Hearthstone glyph, logo, glow, particle, check)
  Media/Fonts/*.ttf + OFL.txt   Cinzel Bold, Alegreya Sans Regular/Bold
  Media/bingo.ogg               celebration sound (original or CC0; licence text beside it)
tests/                          busted (Lua 5.1), wow_stub.lua, loopback dispatcher, fixtures ported from the TS tests
docs/reviews/                   the five expert reports
```

**TOC**

```
## Interface: 16001
## Title: DEA Bingo
## Notes: Raid Bingo for the Drip Enforcement Agency, played in the raid. Fonts Cinzel and Alegreya Sans under the SIL OFL.
## Author: ...
## Version: @project-version@
## SavedVariables: DEABingoDB
## SavedVariablesPerCharacter: DEABingoCharDB
## IconTexture: Interface\AddOns\DEABingo\Media\icon.tga
## AddonCompartmentFunc: DEABingo_OnCompartmentClick
## OptionalDeps: Ace3, !BugGrabber
## X-License: MIT
## X-Category: Miscellaneous
```

Forever-only for now (single Interface line). Multi-flavour TOCs are a post-launch decision; Baganator's multi-Interface line
plus per-file `[AllowLoadGameType camelot]` tags is the pattern to copy when wanted. The interface number lives only in the TOC and is
never branched on in Lua, because it will likely bump at launch.

**Libraries.** AceComm-3.0 with ChatThrottleLib (chunking, throttle-aware retry, priority queues), LibDataBroker + LibDBIcon (minimap
button), LibStub, CallbackHandler. No AceDB (a plain table with a schema version suffices), no AceGUI (UI is custom-drawn), no
AceSerializer and **no LibDeflate** in v1 (see §9). Probe `C_EncodingUtil` at load for a possible later native compressor.

**Identity.** Key every roster entry by normalised `Name-Realm` (append `GetNormalizedRealmName()` when the realm half is missing);
store GUID beside it for equality checks. Authority is the **server-stamped sender argument** of `CHAT_MSG_ADDON`, never a name inside the
payload. `Ambiguate(name, "none")` for display only, never for keys.

## 4. Protocol and state sync

One prefix. Every game has an **audience**, chosen by the owner at creation:

- **Guild** (default, decided 2026-10-07): all game traffic goes on the `GUILD` channel. Anyone online in the guild can see the card and join,
  whether or not they are in the raid. Pugs are excluded by construction; no filtering code. The host accepts JOIN only from `IsGuildMember`-verified
  senders (`C_GuildInfo`/roster lookup) as a belt-and-braces check.
- **Raid**: traffic goes on the group channel, chosen per send: `INSTANCE_CHAT` if in an instance group, else `RAID`, else `PARTY`. Anyone in the
  group can join, pugs and cross-guild friends included. For nights with guests.

Boards and private replies always go by `WHISPER`. Never CHANNEL, SAY or YELL. The invite line (§6) and bingo lines post to the chat that
matches the audience (`/guild` or `/raid`). Guild mode means a join wave scales with guild members online, not raid size, so roster deltas are
coalesced and the join budget below is sized for a 100-person guild. ChatThrottleLib priorities: `ALERT` for calls and undos, `NORMAL` for roster and cards, `BULK` for
items and snapshots, so a resync never delays a call. Framing: `v<ver>\31<gid>\31<type>\31<field>...` with `\30` as the in-field list
separator (the item validator strips all control bytes, so separators cannot appear in text). Unknown types, versions and game ids are
dropped; a newer protocol version is reported once in the lobby ("Update to play in this game").

**State per game (host holds, persists on every mutation):** gid, gen, seq, title, owner, createdAt, lastActivity, closedAt,
itemsHash, items[24], roster {Name-Realm → board[24], canCall, bingoAt, joinedAt}, calls {idx → calledAt}.

- **Boards** dealt by the host with `dealUniqueBoard`, encoded as 24 letters `A..X`, FREE implicit at cell 12. Stored, never derived.
- **Calls are a set.** CALL adds, UNDO removes, re-call adds with a new time. Marks and `bestLine` derive from the set on every client.
- **`bingoAt` is host state**, carried in CALL and UNDO deltas and in the roster. It cannot be derived from the call set (line A at t1,
  line B at t2, undo A: the web keeps t1), so the host runs the web's `reconcileBingos` and ships the result.
- **Timestamps** are the host's `GetServerTime()` (epoch seconds, server-synced). `GetTime()` never leaves a client.
- **Sequence numbers.** Every mutation bumps `seq`; replicas apply `seq == last+1`, buffer out-of-order for 2 s, then request a sync. The
  30 s heartbeat card carries `seq`, a 24-bit call mask and `lastActivity`, so most drift self-heals without a snapshot.
- **Granted callers do not broadcast.** They whisper a CALL_REQ to the host, which validates `canCall` and rebroadcasts. One serialisation point.
- **Items broadcast once** on open (about 6 chunks) and cached by hash on every client; a client missing them asks by whisper. Never
  unicast items per player (35 KB and 45 s of throttle for 25 players).

**Message table** (approximate bytes before chunking)

| Message | Direction | Channel | Fields | Bytes |
|---|---|---|---|---|
| HELLO | any → all | group | ver | 10 |
| GAME (card + heartbeat) | host → all, or → HELLO sender | group / WHISPER | gid, gen, seq, state, title, owner, players, callMask, lastActivity, itemsHash, createdAt | 110 |
| JOIN | player → host | WHISPER | gid, ver | 20 |
| WELCOME | host → player | WHISPER | gid, seq, board24, canCall, createdAt, bingoAt | 55 |
| JOINED | host → all | group | gid, seq, name, board24, canCall, bingoAt | 75 |
| ITEMS / ITEMS_REQ | host → all or requester / player → host | group or WHISPER | gid, itemsHash, 24 items / gid, itemsHash | ≤1500 / 20 |
| CALL_REQ / UNDO_REQ | caller → host | WHISPER | gid, idx, nonce | 20 |
| CALL / UNDO | host → all | group | gid, seq, idx, t, winners or revoked | 30–120 |
| GRANT | host → all | group | gid, seq, name, canCall | 45 |
| TITLE / CLOSE | host → all | group | gid, seq, title / closedAt | 55 / 25 |
| TRANSFER | host → all | group | gid, seq, gen, newHost | 50 |
| SYNC_REQ / SYNC | player → host / host → player | WHISPER | gid, haveSeq / full record minus items | 20 / ≤1600 |

**Budget.** A 25-player join wave (or a larger one in Guild mode, where everyone online may join) costs the host about 3 messages per join plus one 6-chunk ITEMS broadcast, coalescing roster deltas on a
2 s timer. A night has perhaps 60 calls and undos at one message each. If more than 3 SYNC_REQs arrive within 5 s (mass `/reload` after
a wipe) the host answers once by broadcast. Worst case stays under 300 messages per night, far below what boss mods send.

**Failure behaviour**

| Case | Behaviour |
|---|---|
| Host `/reload` or crash | SavedVariables restore the record; host re-announces the card; replicas compare `seq`. In-memory state wins over SV when both exist (beta SV bug). |
| Host silent 90 s | Cards and chip show "host away"; boards stay viewable; callers see no ghost mark; silent resume on return. |
| Host leaves for the night | Game freezes. **TRANSFER** by the owner (bumps `gen`) is in v1; replicas already hold everything but need nothing new. Automatic takeover by a granted caller is v2, resolved by `gen` (a returning host that hears a higher gen demotes itself). |
| Player `/reload` | JOIN is idempotent: the host returns the same board. Restore is silent, no toast. |
| Player leaves the raid | Stays on the roster, greyed via `UnitInRaid`; same board on return. |
| Party ↔ raid conversion | Channel re-evaluated per send; card re-sent on roster change. |
| Two owners, same title | Distinct gids; lobby appends the owner name. |
| No addon | Sees nothing except the optional raid-chat lines (§6). |
| Lost or reordered message | Seq gap or heartbeat mask mismatch triggers a sync. |

**Trust.** Accept state-changing messages only when sender == recorded host. Host accepts JOIN only from group members and CALL_REQ only
from `canCall` roster entries. Validate every field (idx 0..23, `isValidBoard`, title 40, item 60 chars, names 24, times within ±1 day,
numbers finite and integral). Per-sender token bucket (5 per 10 s for players, 20 per 10 s for the host), silent drops. Cap displayed games
at 8 and hosted games per sender at 1. HMAC, encryption and board hiding are overkill for a guild game.

## 5. Rendering

Three-layer hybrid, in the Peggle spirit but without Peggle's 8 MB of bitmaps:

- **Layer A, colour textures (most of the UI).** `SetColorTexture` for faces, panels, rules, bars; `SetGradient` with two `CreateColor`
  values for the stone sheen and fel wash. Resolution-independent, theme-swappable at runtime, free.
- **Layer B, one shipped 512x512 TGA alpha sheet**, white-on-transparent, tinted via `SetVertexColor`: chamfer corner masks
  (`CreateMaskTexture` + `AddMaskTexture`), the Hearthstone glyph at 64 and 128 px rasterised from the web app's exact SVG path, the six-stone
  logo, a radial glow, strike end caps, caller flag, check mark, dashed-rule tile, soft particle, ignite ring. A generated `Media/Sheet.lua`
  holds the UV table.
- **Layer C, Blizzard atlases for chrome only**: `_Common-Opacity-Frame-NineSlice-*` for the window via `NineSliceUtil.ApplyLayout`,
  `!ButtonGreenGlow-NineSlice-*` for button hover. Never for the mark, glyph or logo (trademark rule). Never ship extracted BLPs.

**Cell anatomy** (one pooled `Button` per cell, `CellMixin`): face, sheen, four 1 px border textures, 2 px top bar, ADD-blend glow, wrapped
centred FontString, strike line, chamfer mask. States mirror `app.css`: idle, hover, pressed, called (fel wash face, fel border, top bar,
strike, bold — three signals so colour-blind players still read it), winning line (fel face, inverted text). Free centre: sunk face,
Hearthstone glyph at 42% of cell width, dashed top bar so it never reads as called.

**One fitted font size.** Port the web `fit()` loop: a hidden ruler FontString binary-searches a size in 0.5 steps across all 24 items
using `GetStringHeight` and `IsTruncated`, then grows row height (max 4 steps) before anything clips. Run on `OnSizeChanged`, debounced one
frame. Hover shows the full phrase in a tooltip. Minimum board width 560 px in the main window.

**Pixel snapping.** `PX = 768 / physicalHeight / UIParent:GetEffectiveScale()`, applied to every hairline; recompute on `UI_SCALE_CHANGED`
and `DISPLAY_SIZE_CHANGED`; `SetSnapToPixelGrid(true)` on borders and strikes only.

**Fonts.** Ship Cinzel Bold and Alegreya Sans Regular and Bold with `OFL.txt` beside them, unmodified and unrenamed (neither declares a
Reserved Font Name). Four font objects: heading, eyebrow, cell, body. The client has no glyph-level fallback, so switch to Blizzard locale
fonts on ruRU/koKR/zhCN/zhTW clients and, per game, when any item contains characters above U+024F. Shadow on body text; `OUTLINE` only on
the chip, which floats over the world.

**Animation.** One OnUpdate tween driver on the root frame that sleeps when idle; AnimationGroups avoided for anything that also sets alpha
in code (documented quirks). Call: 420 ms ignite (scale 0.94→1, glow fade, six particles). Undo: 200 ms reverse, no particles ("leaves no
trace"). Winning line: 2 px fel bar growing from the completing cell. Bingo: Cinzel banner, 24-sprite burst, and a shipped celebration sound
(`Media/bingo.ogg`, original or CC0 audio, played with `PlaySoundFile` on the Master channel; a settings toggle mutes it). Standings rows tween to their new order. Budget under 0.3 ms per frame, 32 live particles max, a
"reduced motion" option, and nothing beyond alpha during combat.

**Asset pipeline.** `design/addon-sheet.svg` → `rsvg-convert` → `magick ... -type TrueColorAlpha -compress none rb_sheet.tga` (power-of-two,
32-bit). 2 px gutters between sprites. Test at UI scale 0.64 and 1.0 and at 4K.

## 6. Player experience

The governing rule from the raid-leader review: **a bingo addon is a between-pulls toy. If it competes with DBM during a pull it is gone by week two.**

**Three states**, driven by `PLAYER_REGEN_DISABLED/ENABLED`:

- **Chip** (default while in a game): one movable line, title, "14/24 called", "1 away", a tiny 5x5 dot grid. Click opens the window.
- **Full window** (on demand): board left, 320 px rail right with standings and call log; Escape closes via `UISpecialFrames`. In combat it
  fades to 40% alpha and stops taking mouse input; it never auto-hides.
- **Toasts** stack near the chip, never centre screen.

**Combat rules, default on and not owner-overridable:** no banner, no sound, no window opening mid-pull. The chip may flash once per call.
A bingo earned in combat is celebrated the moment combat ends, with its real timestamp.

| Event | Chip | Toast | Centre banner | Sound |
|---|---|---|---|---|
| Any call | count + flash | no | no | no |
| My line reaches 4/5 | "1 away" | small | no | soft tick, opt-in |
| Someone else's bingo | standings | "Dorn: BINGO #1" | no | no |
| My bingo | – | – | 4 s, out of combat | default on |
| Game started | – | with Join button | no | no |

**Caller panel:** 24 rows, alphabetical with a filter box (the caller is hunting a phrase they just heard, not a grid position). Click calls
immediately, no modal; a called row goes inert for 1.5 s so a double-click cannot call-then-undo. Click a lit row to undo, plus an "Undo
last" button naming the item. Ctrl-click a square on the board also calls (plain click shows the phrase). `/dea call <text>` with prefix
match. Keybinds only for toggle window and toggle chip. Grant caller = right-click a roster name, owner only.

**Lobby.** The 30 s heartbeat card populates the list. One open game: the board with a pre-focused "Join Tuesday MC" button. Several: a list
with title, owner, players, calls, already-joined first. None: "Start a game". When a game opens, the owner's client posts **one** raid-chat line
with a native custom hyperlink (`|Haddon:...:join:<gid>|h[Join Tuesday MC]|h`, handled through the ItemRef hook) plus the install URL for
players without the addon. Re-post is a button, never automatic. Rejoin after `/reload` is silent.

**Setup paths, ranked by typing required:** copy items from last game (default when history exists) → saved named sets → three shipped
generic presets (no guild names) → paste a list into a multi-line box (split on newlines, trim, dedupe) → share string (`!RB1:...`,
byte-compatible with a `presets.json` entry so sets can travel through Discord and the website). Validation mirrors the web: 60 hard, 48 soft,
duplicates flagged against the slot they clash with. No "randomise" button; every board is shuffled anyway. Title defaults to `<Weekday>
<instance>` from `GetInstanceInfo`.

**Board readability:** 520 px default at 1080p, scalable 420 to 700. Near-bingo lines get a gold edge glow. Standings: name, five-dot
`bestLine` meter, bingo time; winners pinned top. Call log newest first; undone calls simply vanish.

**Social layer:** raid chat is the social layer. The addon's total chat output per night, with defaults, is one invite line, one line per
bingo (posted by the winner's client only), and one manual "Post results" summary. Everything else is opt-in. History is per character in
SavedVariables, each game reopenable.

**Adoption:** addon compartment entry, `/dea` (alias `/deabingo`), minimap button on by default (this crowd runs Titan). First-run tutorial is one line on the
first invite toast. Version mismatch is said once per session; old clients are never kicked from reading.

## 7. Security, policy and compliance

Allowed: a raid minigame over RAID addon messages is squarely within Blizzard's UI Add-On Development Policy (free, unobfuscated, no
excessive chat use). Our only exposure is chat volume and chat-as-transport, both designed out above.

Forever specifics that touch us: `C_ChatInfo.InChatMessagingLockdown()` and `Enum.SendAddonMessageResult.AddOnMessageLockdown` mean an
addon send can be refused during encounters, so queue and retry when lockdown ends. Incoming sender names and text can be **secret values**
during lockdown: comparing one throws, so guard with `issecretvalue()` and `pcall` the handler. This is exactly where PeggleClassic broke.

**Code-safety rules for the implementer**

1. Authority comes from the `CHAT_MSG_ADDON` sender argument, never from payload fields.
2. Escape `|` as `||` in every untrusted string before it reaches a FontString or chat (`|H`, `|T`, `|c` injection renders fake links and textures on every screen).
3. `pcall` every deserialisation and handler; log and drop on failure. Cap reassembled payload size (4 KB) before parsing.
4. Every wire number may be nan, inf, float, negative or huge: check type, integrality and range.
5. `issecretvalue()` before comparing anything from a chat event.
6. One prefix, one AceComm instance, CTL priorities; never a second prefix to dodge the bucket.
7. Per-sender token bucket; silent drops; never an error popup triggered by remote input.
8. Only RAID/PARTY/INSTANCE_CHAT/WHISPER for addon messages.
9. No `loadstring`, no `RunScript`, no code in SavedVariables, no minification.
10. Never call protected functions (`ReloadUI`, targeting, secure frames) from a message handler.
11. Register events in `pcall`; initialise in `ADDON_LOADED`, never at file scope.
12. Validate SavedVariables on load with the same validators used for wire data.
13. The `cleanText` port strips control bytes and the UTF-8 byte sequences of zero-width, bidi and variation-selector characters, collapses
    whitespace, caps by bytes (240) and counts length with `strlenutf8`. NFC and zalgo trimming are skipped (items come from the owner's EditBox).
14. The validators run as pure Lua unit tests outside the client, ported from `shared/validate.ts`.

**Privacy.** The audience setting (§4) decides who sees items and roster. In Guild mode, every guild member online sees them, in or out of the
raid; in Raid mode, everyone in the group, pugs included. When the owner picks Raid mode with non-guild members present, show a preflight line
("N players in this raid are not in your guild and will see the item text"). Keep history to the last 20 games with a "clear history" button. Nothing posts to real chat by default except the three lines in §6.

**Licensing.** MIT like the web app. Fonts under OFL 1.1 with licence files shipped, unmodified. "Hearthstone" stays in-game vocabulary only,
never in the addon name, slug, icon or marketing. Never ship datamined art; runtime `SetAtlas` by name is fine. The repo never contains guild
presets, real names, SavedVariables dumps or API keys; gitleaks pre-commit as in the web repo.

**Publishing.** BigWigs packager via GitHub Actions to CurseForge, Wago and GitHub Releases; `.pkgmeta` externals pinned by tag or commit (done 2026-10-07, issue #25); API keys only
in Actions secrets; `## X-Curse-Project-ID` and `## X-Wago-ID` in the TOC.

## 8. Testing and dev loop

- **Pure logic under busted on Lua 5.1** (`luarocks --lua-version=5.1 install busted`). `tests/wow_stub.lua` provides `strlenutf8`,
  `GetTime`, `GetServerTime`, `C_Timer.After`, a recording `CreateFrame`, and a fake `C_ChatInfo.SendAddonMessage` that loops messages into
  a `CHAT_MSG_ADDON` dispatcher, so a host and several mirrors run in one process and the whole protocol is testable: join wave, call, undo
  with bingo revocation, late-join instant bingo, host reload, seq gap and resync, malformed and forged messages.
- **Fixtures ported from the TypeScript tests** (seeded deals, expected boards, line detection) so Lua and TS stay provably identical.
  Keep the `rng.int(maxExclusive)` seam.
- **In-client:** symlink the addon folder into `/Applications/World of Warcraft/_classic_beta_/Interface/AddOns/`; restart the client the
  first time a folder or TOC appears, `/reload` after. Install `!BugGrabber` and `BugSack`. `/etrace` for payloads, `/fstack` for frames.
  `/dea debug` prints every message with byte counts and the send result. `/dea solo` spins up a second in-process mirror with a fake identity
  through the same loopback used by the tests, rendering a second board, so one person can exercise the whole flow.
- **Retest on every beta build**: SavedVariables load, event registration, secure snippets, and the Interface number at launch.

## 9. Decisions and how disagreements were resolved

| Decision | Resolution | Why |
|---|---|---|
| Authority | Host-authoritative, seq per game | One writer removes every ordering and conflict problem; all reviewers agreed. |
| Compression | **None in v1** (architect proposed LibDeflate for snapshots; security objected) | Payloads are ≤1.6 KB, 6–7 chunks; decompression bombs have no output cap. Revisit with native `C_EncodingUtil` if ever needed. |
| Prefixes | **One prefix** with CTL priorities (architect proposed two) | Priorities already keep calls ahead of snapshots; multiple prefixes are the pattern Blizzard warns can disconnect a client. |
| Serialisation | Hand-rolled delimited framing with strict validators (not AceSerializer) | Smaller, no table-shape surprises, every field validated anyway. |
| Host hand-off | Explicit owner TRANSFER in v1; automatic takeover in v2 via `gen` | UX wants continuity, architecture fears split-brain; `gen` reconciles both. |
| In-addon chat | Dropped; timeline kept | Chat-over-addon-messages is the banned pattern; raid chat already exists. |
| Multiple games | Many games, lobby from heartbeat cards | Cannot enforce one per raid without a server; a list answers the owner's open question. |
| Boards | Dealt and stored by the host, 24 letters, whispered once and included in roster deltas | Matches the web's "stored, not derived" rule; standings need every board. |
| `bingoAt` | Host state, shipped in deltas | The web's undo semantics cannot be derived from the call set. |
| Rendering | Colour textures + one alpha sheet + atlases for chrome; single OnUpdate driver | Tiny download, theme-swappable, trademark-safe; sidesteps AnimationGroup quirks. |
| Combat | Quiet by default, not owner-overridable; bingos queue to end of combat | One raider's sound mid-pull poisons adoption. |
| Audience | Per-game setting, default Guild (GUILD channel), Raid as the alternative | Excludes pugs by construction and lets guildies outside the raid play; Raid mode covers cross-guild guests. |
| Name | **DEA Bingo**: folder `DEABingo`, prefix `DEABINGO`, SV `DEABingoDB` | "Raid Bingo" collides with an existing CurseForge project; the guild name is free. |

## 10. Open decisions for the owner

1. ~~Folder and project name~~ **Decided 2026-10-07: "DEA Bingo"**, folder `DEABingo`, prefix `DEABINGO`, SV `DEABingoDB`.
2. ~~Guild-only default~~ **Decided 2026-10-07: audience defaults to Guild** (GUILD channel; guild members outside the raid can join; pugs excluded).
   Raid mode remains available for nights with cross-guild guests.
3. ~~Celebration sound~~ **Decided 2026-10-07: ship a celebration OGG.** Needs an original or CC0 clip; its licence ships beside it.

## 11. Milestones

Launch is 4 Nov 2026; the beta client is the test bed until then.

| Milestone | Scope | Done when |
|---|---|---|
| **M0 Foundations** (week 1) — *done 2026-10-07: 22 tests green, loads on beta build 70245, `C_EncodingUtil` present* | Repo, TOC, `.pkgmeta`, symlink, `Core/Logic.lua` port, busted harness, TS fixtures ported, `cleanText` port, `escape()` | `busted` green; addon loads on the beta client with `/dea` printing its version |
| **M1 Protocol** (weeks 1–2) — *done 2026-10-07: 50 tests green; verified between two beta clients (join, items, call, grant, caller request) on realmless two-word names* | Codec, Net, Host, Mirror, Store; HELLO/GAME/JOIN/WELCOME/JOINED/ITEMS/CALL/UNDO/GRANT/CLOSE/SYNC/TRANSFER; rate limits; `/dea debug`, `/dea solo` | Loopback tests cover join wave, undo-revokes-bingo, late-join bingo, host reload, seq gap, forged and malformed input; two real clients sync on the beta |
| **M2 Board and windows** (weeks 2–3) — *done 2026-10-07: verified in the beta (board, bingo, resize, Escape, combat dim); caller panel, confirmation sheet, sounds, paste-a-list, history and options added* | Theme, Cell, Board with fitted font, Window with standings and call log, Chip with combat rules, Caller panel, Lobby, Setup (copy-last, paste-a-list), History | A full game can be played by a 5-person group in the beta with no slash commands |
| **M3 Juice and polish** (week 3–4) | Alpha sheet, fonts with locale fallback, tween driver, call/undo/bingo animations, celebration OGG, toasts, minimap button, chat invite link, bingo and results lines, options | Visual review against `design/BoardPlayer.dc.html`; frame-time budget met in a 40-person raid |
| **M4 Release** (launch week) — *v0.1.0 shipped 2026-10-07: GitHub release + CurseForge project 1732315 via the packager; README, CI, changelog in place; first guild night pending* | README, LICENSE, OFL files, CHANGELOG, GitHub Actions packager, CurseForge and Wago projects, first guild night | v0.1 installable from CurseForge; one full guild raid played |
| **v0.2** | Saved sets, shipped presets, share string import/export (website-compatible), `/dea call`, near-bingo glow, automatic host takeover, Edit Mode registration, light theme | |
| **Later** | Reactions, prize `/roll` button, guild-wide stats via export string, multi-flavour TOC | |

## 12. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Name collision with existing CurseForge addon | Resolved | – | Named DEA Bingo (§2) |
| Custom-drawn UI is the schedule risk, not the protocol | High | Medium | M1 ships with a plain debug UI; M2/M3 budgeted separately |
| Beta SavedVariables bug breaks host recovery | Medium | Medium | In-memory state authoritative; retest each build |
| Secret-value comparison kills a handler mid-raid | Medium | Medium | `issecretvalue` guards, `pcall`, handler-level isolation |
| Escape-sequence injection by a pug | Medium | High | `escape()` at the render boundary, tested |
| Throttle starvation during a join wave or mass reload | Medium | Medium | Items broadcast once; coalesced roster deltas; broadcast SYNC when >3 requests in 5 s |
| Host disconnects freeze calls | Medium | Medium | Grant a backup caller early; TRANSFER in v1 |
| Text clipping with 60-char items | Medium | Low | Fitted size, growing rows, 560 px minimum, tooltip |
| Interface bump at launch | High | Low | TOC-only, never branched on |
| Adoption and annoyance | Medium | High | Combat quiet by default; three chat lines per night max; copy-last setup |
| Blizzard policy action | Very low | High | No chat transport, no spam, visible MIT code |

## Sources consulted by the reviewers

Blizzard UI Add-On Development Policy (us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534); Patch 1.60.1 and 12.0.0 API changes
and Secret Values (warcraft.wiki.gg); `C_ChatInfo.SendAddonMessage`, UI escape sequences, Hyperlinks, `TextureBase_SetGradient`, `UIOBJECT_MaskTexture`,
`UIOBJECT_FontString`, UI Scale, TGA files (warcraft.wiki.gg); forever-addon-kit (github.com/Thunderz96/forever-addon-kit); wowforeverguides.com/addons/developers;
PeggleClassic (wowinterface.com/downloads/info24964-PeggleClassic.html); existing Raid Bingo and Guild Bingo on CurseForge; Cinzel and Alegreya Sans OFL
texts (github.com/google/fonts); BigWigs packager guide; local evidence from Plater, Decursive, Baganator, Auctionator and Tinker in the beta AddOns folder
and the `../DataMining` notes (`API.md`, `GRAPHICS.md`, `WHATS-NEW.md`).
