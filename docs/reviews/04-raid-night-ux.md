# Raid Bingo addon: player experience recommendation

Written from the chair of someone who has run 40-man nights and uninstalled a lot of addons. The rule that governs everything below: a bingo addon is a between-pulls toy. If it ever competes with DBM for attention during a pull, it is gone by week two.

## 1. Raid-night reality and the attention model

When people look at a board: during trash clears (the long walk in MC), after wipes while running back, during loot and DKP arguments, buff-up and ready checks, and declared AFK breaks. That is easily 60% of a vanilla raid night. When they must not: from the pull until the boss dies or the raid wipes.

Three states, driven by `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED`:

- **Mini chip** (default state while in a game). A one-line movable frame: game title truncated, "12/24 called", "1 away" with a tiny 5x5 dot grid. Click opens the full window. Lockable, Edit Mode registered if feasible, remembers position.
- **Full window** (opened on demand). Board, standings, call log. Closes with Escape via `UISpecialFrames`. If combat starts while it is open, it fades to 40% alpha and ignores mouse (`EnableMouse(false)`) so it never eats a click meant for the world. It does not auto-hide; people hate losing a window they placed.
- **Notifications**. Toasts stack in a small area near the chip, not centre screen.

Combat rules, hard-coded unless the player opts out:

- **Nothing steals focus mid-pull.** No centre-screen banner, no sound, no window opening. The chip may flash its border once when a call lands and update its count. That is it.
- **Queue, do not drop.** A bingo earned during a pull is announced the moment combat ends, with its real timestamp. Players still get their moment.
- **"Quiet in combat" is per player, default on.** The owner cannot force sound onto a raider's client. The owner has a separate "quiet mode" toggle for their own announcements.

What deserves what:

| Event | Chip | Toast | Banner (centre) | Sound |
|---|---|---|---|---|
| Any call | count updates, border flash | no | no | no |
| Call that marks my square to 4-in-line | flash, "1 away" | small toast | no | soft tick (opt-in) |
| Someone else's bingo | updates standings | toast "Dorn: BINGO #1" | no | no |
| My bingo | – | – | yes, 4s, out of combat | yes, default on |
| Game started / invite | – | toast with Join button | no | no |

Every call already marks everyone's board, so a "your square got called" toast on every call is just a toast per call. Only the near-bingo threshold earns one.

## 2. The caller's experience

The raid leader is reading Discord, watching threat, and typing in raid chat. Calling has to be one click and findable in two seconds.

- **Caller panel**: a 24-row list, alphabetical, with a filter box at the top. Alphabetical beats "as on my board" because the caller is looking for a phrase they just heard, not a grid position. Called rows light fel-green with a strike and show the call time. Rows are tall enough to click at 1440p with a mouse that is also steering a character.
- **Click calls immediately.** Desktop, not phone. A modal twenty times a night is worse than an occasional mis-call. The web design already made this call and it holds in-game.
- **Undo** is a click on the lit row, plus an "Undo last" button at the bottom that names the item. A called row shows a 1.5s inert window after calling so a double-click does not call-then-undo.
- **Calling from the board**: Ctrl-click on a square in the full window (plain click shows the full phrase, same as web). Ctrl is the discriminator so a casual tap never broadcasts to 40 people. No calling from the chip; it is too small to trust.
- **`/rb call <text>`** with fuzzy prefix match, confirming in the chat frame ("Called: Someone pulls before the count"). Cheap to build and lets a caller fire without opening anything. Keybinds only for "toggle window" and "toggle chip". Twenty-four call keybinds would be clutter nobody sets.
- **Raid-chat text per call**: opt-in, default off. Addon players already see it on their board, and non-addon players cannot play, so per-call text only adds noise. When on, throttle to one line per call, min 8s apart, batched if calls come faster: `[Raid Bingo] Called: "Warrior charges in early" (14/24)`. Banter wording belongs in the item text, not the announcement.
- **Grant caller** is a right-click on a roster name. Owner only, mirroring the web rule.

## 3. Lobby and game picking

Discovery runs on an addon-message heartbeat: the owner's client broadcasts the game header (id, title, owner, player count, calls, protocol version) on `RAID` every 30s and on request. Anyone with the addon learns about games without anyone typing.

- **One open game**: opening the addon shows the board with a "Join Tuesday MC" button pre-focused. One click. Owner option "auto-join on invite": default **off** for players, because a game is a social opt-in, but the toast carries a Join button.
- **Several games**: a list with title, owner, players, calls, and whether you are already in it. Already-joined games sort first.
- **None**: a single "Start a game" button and a "Browse history" link.
- **Invite line in raid chat**: when a game starts, the owner's client posts one line with a clickable link. Custom `|Haddon:RaidBingo:join:<id>|h[Join Tuesday MC]|h` links are supported natively in the retail engine and fire through the ItemRef hook, so a player with the addon clicks and joins. Players without the addon see plain text plus the install line (section 7). Re-post is a button, never automatic.
- **Rejoin after /reload**: the client stores current game id and board in SavedVariables. On `PLAYER_ENTERING_WORLD` it sends a sync request to the owner and restores silently. No toast, no "welcome back". If the owner is offline, the board renders from the last known state with an "owner away" marker.
- **Owner disconnects** are the vanilla reality. The second-longest-present caller becomes acting sync source for calls already made; the owner reclaims on return. The architect should own the exact protocol.

## 4. Game setup for the owner

Nobody types 24 phrases on a Tuesday at 19:55. Rank the paths by how little typing they need:

1. **Copy items from last game.** The default when the owner has any history. Title and items prefilled, one click to create.
2. **Saved sets** in SavedVariables (named, with date and item count). "Save this set" after creating.
3. **Shipped presets**: three generic sets (Generic Raid Night, Pug Night, Classic Classics), no guild names, editable before use.
4. **Paste a list**: a multi-line edit box that splits on newlines, trims, dedupes. Pasting 24 lines from Discord or a Google Doc is the realistic path for a new set.
5. **Share string**: a compact import/export string (`!RB1:...`) so a guild can pass a set through Discord or the website. Importing the website's presets.json falls out of this if the web exports the same string.

Validation mirrors the web: 60 char hard cap, soft warning at 48, duplicates flagged against the slot they clash with. **Skip "randomise order"**: every player's board is shuffled anyway, and the setup should say so in one line. Title defaults to `<Weekday> <instance name>` from `GetInstanceInfo`, falling back to `<Weekday> raid`.

## 5. Board readability

- **Window size**: 520px square default at 1080p, scalable 420 to 700. Cells land around 90 to 115px. One fitted font size across the whole grid (the web rule), computed from the longest phrase; rows grow before text clips. Hover tooltip shows the full phrase and, if called, who called it and when.
- **Called state carries three signals**: fel-green fill, strikethrough, and a check glyph in the corner. Winning line adds inverted contrast. The Hearthstone centre uses a dotted top bar so it never reads as called. Colour-blind safe without a mode switch.
- **Near-bingo**: any line at 4/5 gets a gold edge glow on its five cells. The header says "1 away" in Cinzel. Two lines at 4/5 both glow; it is a good feeling.
- **Standings**: compact rows, name, bestLine as a five-dot meter, bingo time if any. Winners pinned top with rank. Mark counts are never shown; they are identical for everyone.
- **Call log**: newest first, time and phrase, undone calls simply vanish.
- **Fonts**: ship Cinzel and Alegreya Sans with the OFL licence. Full window sits on a solid stone backdrop so legibility over the world is not an issue. The chip uses `OUTLINE` on its text and a 70% backdrop because it does float over the world.

## 6. Social layer

- **No in-addon chat in v0.1, and probably never.** Raid chat is already open, already has everyone's attention, and reaches non-addon players. An addon chat box splits the conversation and becomes one more thing to miss. The call log is the timeline. If anything, add one-click reactions later.
- **Roster**: who is in the game, with caller badges, in the standings panel. Not a separate screen.
- **Bingo celebration**: the winner gets the centre banner and sound. Everyone else gets a toast and a standings update. Exactly one client posts the raid-chat line: the winner's, worded from the game ("Felwarden: BINGO! #2, 21:47"). Never 40 clients announcing the same thing.
- **End of night**: the owner's "Post results" button writes three lines to raid or guild chat: title, calls made, winners in order with times. Manual, once.
- **History**: a per-character list in SavedVariables, each game readable with board, calls, winners. Keep it; people like reopening the night that Thalgrim got a bingo on "Warlock forgets the soulwell".

## 7. Onboarding and adoption

- **Entry points**: addon compartment entry always, `/rb` always, minimap button on by default (this crowd runs Titan and minimap buttons, and the compartment is new to them). One toggle turns the minimap button off.
- **First run**: nothing on login. The first time a game invite arrives, the toast includes a one-line "Click to join, drag the chip wherever you like". That is the whole tutorial.
- **Players without the addon**: the invite line carries the install URL once. A manual "Nudge" button lets the owner repost it. Never automatic, never per call.
- **Version mismatch**: protocol version in every header. A client that sees a newer protocol shows "Update Raid Bingo to play in this game" in its lobby and says it once per session. Older clients are never kicked from reading.
- **Spam defence**: the addon's total raid-chat output per night, with all defaults, is one invite line, one line per bingo, and one results post. Anything else is opt-in.

## 8. MVP, decisions, risks

**v0.1 (first guild night)**: create game with paste-a-list and copy-last, join via list or link, dealt unique boards, call and undo from the alphabetical panel, chip plus full window, combat quiet rules, my-bingo banner and toast for others, standings by bestLine, call log, silent rejoin after reload, raid-chat invite line and bingo line, SavedVariables history.

**v0.2**: saved sets and shipped presets, share string import/export, grant caller, `/rb call`, near-bingo glow and toast, post-results button, minimap button toggle, Edit Mode registration, owner-away handover.

**Later**: animations in the Peggle spirit (bingo burst, called-square flip), reactions, light theme, cross-game lobby filters, website import.

**Top five UX decisions**

1. Chip by default, full window on demand. The addon should disappear during pulls without being closed.
2. No pop or sound in combat, ever, and bingos queue to end of combat. Protects the one thing a raid cannot afford.
3. Caller panel is alphabetical with immediate click-to-call and one-click undo. Finding beats layout fidelity when the leader is busy.
4. Raid chat is the social layer; the addon posts three kinds of lines and all else is opt-in. Adoption dies on spam.
5. Copy-last and paste-a-list before any typing path. Setup friction decides whether week two happens.

**Risks**

- **Adoption**: half the raid must install it before it is fun. Mitigation: the invite link plus visible bingo lines make non-players curious without nagging.
- **Annoyance**: one raider with sound on during a pull poisons the whole raid against it. Mitigation: combat quiet is default and not owner-overridable.
- **Clutter**: vanilla-style UIs are already busy. Mitigation: the chip is one line, movable, lockable, and hides in Edit Mode like a Blizzard frame.
- **Owner disconnects**: common in Classic-style raids. Mitigation: acting sync source and state cached on every client.

## Wireframes

Full window (about 520px wide):

```
+------------------------------------------------------------------+
| RAID BINGO   Tuesday MC            Live  14/24 called   1 away  X |
+------------------------------------------+-----------------------+
| [Someone pulls ] [Healer blames] [Wipe   ] [Tank dies  ] [DC mid ]|  STANDINGS (14)      |
| [ before count ] [ the tank  v ] [under 5%] [first 30s  ] [fight  ]|  1 Dorn    BINGO 21:41|
| [Loot for class] [Stands in   ] [Soulwell] [Same roll  ] [Rogue  ]|  2 Jaina   BINGO 21:47|
| [ not here   v ] [ fire     v ] [forgot  ] [twice   v  ] [trash  ]|    Felwarden ●●●●○ 1 away
| [AFK at pull   ] [Wrong totem ] [  ◇HS◇  ] [Who pulled?] [Repair ]|    Bonkgrog  ●●●●○ 1 away
| [     v        ] [     v      ] [ free   ] [    v      ] [bill v ]|    Thalgrim  ●●●○○     |
| [Take five?    ] [Mage table  ] [Recount ] [DKP fight  ] [B-rez  ]|  ...                  |
| [              ] [mid-fight v ] [link  v ] [           ] [wrong  ]+-----------------------+
| [Healer OOM    ] [Wrong flask ] [Charges ] [Wait 10 min] [Thought]|  CALL LOG             |
| [  <50%  v     ] [     v      ] [early   ] [one person ] [interr ]|  21:52 Wrong flask    |
+------------------------------------------+   21:47 "I thought..."|
| Kaelthas is calling      [Caller panel]  |  21:41 Recount link   |
+------------------------------------------+-----------------------+
   v = called (green fill + strike + glyph)   gold edge = 4/5 line
```

Mini chip (default state, movable, about 200x28px):

```
+----------------------------------------------+
| ■ Tuesday MC    14/24    1 away   ·····      |
|                                  ·■■■·  (5x5 dots: filled = called)
+----------------------------------------------+
   click: open window   border flashes on call   dims in combat
```

Lobby (several games open):

```
+------------------------------------------------------+
| RAID BINGO                                      X    |
+------------------------------------------------------+
|  GAMES IN THIS RAID                                  |
|  Tuesday MC          Kaelthas   14 players  12 calls |
|  you're in this one                        [Open]    |
|  Sunday Hyjal pugs   Bonkgrog    3 players   0 calls |
|                                            [Join]    |
+------------------------------------------------------+
|  [ + Start a game ]        [ History ]   [ Options ] |
+------------------------------------------------------+
|  Raid Bingo 0.1 · /rb                                |
+------------------------------------------------------+
```

Files consulted: the shared brief (`scratchpad/brief.md`), `/Users/elio/Library/CloudStorage/Dropbox-Personal/Projects/WoW/RaidBingo/CLAUDE.md`, and the artboards `BoardPlayer.dc.html`, `Lobby.dc.html`, `CreateGame.dc.html`, `States.dc.html` in `/Users/elio/Library/CloudStorage/Dropbox-Personal/Projects/WoW/RaidBingo/design/`.
