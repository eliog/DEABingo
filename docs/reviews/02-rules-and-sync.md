# Raid Bingo addon: rules and state-sync recommendation

## 1. Rules fidelity: web rule to addon

| Web rule | Addon adaptation |
|---|---|
| Identity = Discord pid, typed char name, unique per game | Identity = normalized `Name-Realm` (always append `GetNormalizedRealmName()` when the sender arrives bare). Store GUID beside it for display and tie-breaks, but key on name-realm because WHISPER needs it. Uniqueness is free. No name gate, no suggestions, no mixed-script checks. |
| Anyone creates; creator owns | Same. Owner's client is the **host**. No creation rate limit (no server to protect); soft cap of one open game per owner, UI asks to close the previous one. |
| Items freeze on first non-owner join | Same, enforced by host. Host deals itself a board when it opens the game (the web owner "takes a board through the same gate"). Items carry a 6-char hash so clients detect a changed draft. |
| Title 40 chars, owner edits | Same, via a TITLE delta. |
| Owner is caller, grants/revokes | Same. Granted callers do not call directly: they send a request to the host, who validates and broadcasts. One serialization point. |
| Undo leaves no trace; bingo kept with original time if another line stands | Not derivable from the call set. If line A completes at t1, line B at t2, then A is undone, the web keeps t1; `min over lines of max(calledAt)` gives t2, and a re-call gives a third answer. So **bingoAt is host state**, carried in CALL and UNDO deltas and in the roster, exactly as `reconcileBingos` returns `winners`. Clients compute `hasBingo` locally for instant feedback but display the host's time. |
| Standings by bingoAt asc, then bestLine desc | Same comparator, computed locally from calls plus roster boards. Never show a marks column. |
| Late joiner inherits calls, instant bingo possible | Host reconciles on join; the JOINED delta includes bingoAt when it is instant. |
| Bingo time = time of completing call | Host's `GetServerTime()` when it processes the call. Epoch seconds, synchronized across clients. `GetTime()` is local uptime and never leaves a client. Wire format: seconds since `createdAt`, base36, 4 chars. |
| Auto-close after 8h idle; close never deletes | Host enforces from `lastActivity`; on reload, if idle exceeded it closes at `lastActivity + 8h`, as the web does. Heartbeat carries `lastActivity` so non-hosts render it closed too. Nothing deletes; history is SavedVariables. |
| Three-word IDs, blocklist, oracle rate limits | Dropped. Games are discoverable in the raid by design, so there is no keyspace to protect. gid = `createdAt` base36 + 2 random chars, with owner name as a tiebreaker. |
| Lobby lists only games you are in | Inverted: open games in your group are the lobby. History stays "games you were in". |
| Per-game chat, 300 chars | **Drop in v1.** The raid has voice and `/raid`. Keep the timeline (joins, calls, bingos) as a local event log so undo still erases its event. Optional: host posts bingos to raid chat as plain text, opt-in. |
| Presets, previous item sets | Owner's SavedVariables hold every item set they hosted or received (keyed by hash), which doubles as the "previous sets" library. |

## 2. Multiple games in one raid

Recommend **(b) many games, player picks from a list**, keyed by gid with the owner shown on the card. One game per raid cannot be enforced without a server and (c) owner-keyed is (b) with a worse card.

Discovery is announce plus query, no polling by joiners.

1. On login, `/reload`, and debounced `GROUP_ROSTER_UPDATE`, every client broadcasts HELLO.
2. Every host with an open game replies with a GAME card by WHISPER to the HELLO sender.
3. Hosts also broadcast the GAME card every 30s as a heartbeat. The card is the heartbeat.
4. The lobby shows one card per gid: title, owner, players, calls so far, open or closed, "you are in this game" badge. Cards expire 90s after the last heartbeat and show "host away".
5. Join = JOIN whisper to host. Host replies WELCOME (your board) and broadcasts JOINED to the raid. Items arrive from the broadcast cache or by request.
6. Leave does not exist, as on the web. The player hides the game; the roster keeps them.

Players may be in several games; the state is per gid and independent. The UI focuses one board with a switcher. Visibility is the whole group over RAID, PARTY or INSTANCE_CHAT, chosen by a helper at send time. Invite-only is out of scope; squares name guild members and the raid is the intended audience. A game started before someone joins the raid is covered by step 1: the HELLO on roster change pulls the cards.

## 3. Authority and consistency

Host-authoritative. The host is the owner's client. Everyone else is a replica that applies deltas and may ask for a snapshot.

**States:** `drafting` (owner edits items locally, nothing broadcast) to `open` (card announced, joins allowed, items freeze on first non-owner join) to `closed` (explicit or 8h idle, read-only forever).

**Canonical record, held by host and persisted on every mutation:** gid, gen, seq, title, owner, createdAt, lastActivity, closedAt, itemsHash, items[24], roster map of name to {board[24], canCall, bingoAt, joinedAt}, calls map of idx to calledAt.

- **Boards** are dealt by the host with `dealUniqueBoard` against the roster, so no collision. A board is 24 letters A–X, FREE implicit at cell 12.
- **Sequence numbers:** every mutation bumps `seq` and every delta carries it. A replica applies `seq == last + 1`, buffers out-of-order for 2s, then sends SYNC_REQ. No-op calls (already called) do not bump seq and are not broadcast.
- **Calls are a set.** CALL adds, UNDO removes, re-call adds with a new time. Marks and bestLine derive from the set; bingoAt does not, see section 1.
- **Snapshot vs delta:** deltas on the group channel for every change. Full SYNC by whisper on request only, rate-limited to one per player per 10s. The 30s heartbeat carries seq, a 24-bit call mask and lastActivity, so most drift self-heals without a SYNC: if the mask differs but seq matches, the replica is corrupt and requests SYNC.
- **Staleness detection:** seq gap, mask mismatch, no heartbeat for 90s, or a WELCOME whose seq is ahead of the replica.
- **Concurrent callers:** two requests within a second reach the host and are applied in arrival order. Call and undo on the same square in the same second resolves to the last arrival. The requester shows a ghost mark for 2s until the echo lands, then clears it with a "host away" notice.
- **Transport:** AceComm-3.0 over ChatThrottleLib for chunking and throttling. Fields tab-separated; `cleanText` already strips controls so tabs cannot appear in items.

**Budget check:** 25 players joining in 2 minutes cost the host about 3 messages per join (JOIN in, WELCOME, JOINED) plus one ITEMS broadcast of 6 chunks. Unicasting items per player would be 35KB and 45s of throttle; broadcasting once and caching by hash is 1.4KB.

## 4. Failure cases

- **Host /reloads:** SavedVariables restore the record. The host re-broadcasts the card; replicas compare seq and need nothing.
- **Host disconnects 10 min:** heartbeat stops, cards show "host away" after 90s, callers get "host away" and no ghost mark. Boards stay viewable. Host return resumes silently.
- **Host leaves raid or logs off for the night:** game freezes. v1 offers explicit TRANSFER by the owner only, which bumps `gen`. Replicas already hold roster, boards and calls, so the new host needs only bingoAt, which the roster carries. Takeover by a granted caller after a 5-minute silence is v2, resolved by `gen`: a returning host that hears a higher gen demotes itself.
- **Player reloads:** JOIN is idempotent. Host finds the name in the roster and returns the same board.
- **Player leaves raid:** stays in roster, shown greyed via `UnitInRaid`. Rejoining the group restores them with the same board.
- **Party to raid conversion:** channel helper re-evaluates per send. The card is re-sent on roster change. Nothing in the state references the group.
- **Cross-realm names:** normalize every sender to `Name-Realm` before any comparison. Never `Ambiguate` stored keys.
- **No addon:** they see nothing. The host may post one plain raid-chat line, never repeated.
- **Two hosts, same title:** distinct gids. The card shows the owner, and the lobby appends the owner name when titles collide.
- **Out-of-order or lost messages:** addon messages ride the game's TCP connection, so loss means a disconnect or throttle drop. The seq gap plus heartbeat mask catches both.
- **Clock skew:** only host timestamps exist, and `GetServerTime` is server-synced. Relative times use the viewer's `GetServerTime`.

## 5. Anti-cheat and trust

The game server stamps the sender on every addon message, so spoofing the host requires the host's exact name-realm. Normalization closes the bare-name gap. Beyond that, this is a friendly guild game.

Checks that matter, on every incoming message:

- Prefix, version, known gid, schema shape and field lengths (title 40, item 60, name 24).
- Sender equals host for every state message. Host checks JOIN comes from a group member and CALL_REQ from a `canCall` roster entry.
- `idx` in 0..23, board passes `isValidBoard`, seq monotonic, times non-negative.
- Per-sender rate limit, roughly 5 messages per 10s per gid, drop silently. Cap displayed cards per owner at 2.

A client cannot claim a bingo: every replica derives it from calls and boards. A bogus board is ignored because only host roster entries count. Overkill: HMAC, encryption, shared secrets, hiding other players' boards (the web shows them).

## 6. Game-night flow and friction

Owner picks "New game", chooses a previous set, an imported string, or types 24 items with the soft warning at 48 chars. Opens the game; the card appears in every lobby. Players click Join and see their board. Pull timer starts. Caller taps a square in combat; the host echoes within a second and every board ticks. Bingo plays a celebration on the winner's screen and a quieter toast on everyone else's. Standings tab ranks by time then bestLine. Owner closes at the end; the game moves to history on every client.

Friction and fixes:

- Items typed in-game are painful. Fix: paste an export string from the website, see section 7.
- Calling in combat needs a tiny always-on-top caller strip, not the full board.
- Late joiners during a boss cannot find the lobby. Fix: a minimap or chat-link button that opens the card list, and a one-time whisper from the host client "Raid Bingo is open" to known addon users.
- Host tabbed out means no calls. Fix: grant a second caller early, and the "host away" badge so people know why.

## 7. Nice-to-haves, ranked

1. **Item-set export and import string**, a compact base64 of title plus 24 items, byte-compatible with a `presets.json` entry. Also the vector for sharing between guildies by chat link.
2. **Results to chat**: one `/raid` summary at close, winners and times.
3. **Prize roll**: owner button that runs `/roll` among bingo holders or picks by time. Keep it a button, not a rule.
4. **Guild-wide persistent stats**: aggregate from local history; cross-player merge needs an export string, since no server exists.
5. **Website bridge**: not possible from the client. Addons have no network access and chat transports are banned (`!ChatTransmit` is in `bannedaddons.db2`). Manual alternative: copy the results string out of a text box and paste it into the website.

## 8. Message table

Prefix `RBINGO`. Payload sizes approximate, before AceComm chunking.

| Message | Direction | Channel | Fields | Bytes |
|---|---|---|---|---|
| HELLO | any to all | group | ver | 10 |
| GAME (card and heartbeat) | host to all, or to HELLO sender | group or WHISPER | gid, gen, seq, state, title, owner, players, callMask, lastActivity, itemsHash, createdAt | 110 |
| JOIN | player to host | WHISPER | gid, ver | 20 |
| WELCOME | host to player | WHISPER | gid, seq, board24, canCall, createdAt, bingoAt | 55 |
| JOINED | host to all | group | gid, seq, name, board24, canCall, bingoAt | 75 |
| ITEMS | host to all on open, or to requester | group or WHISPER | gid, itemsHash, 24 items | up to 1500 |
| ITEMS_REQ | player to host | WHISPER | gid, itemsHash | 20 |
| CALL_REQ / UNDO_REQ | caller to host | WHISPER | gid, idx, nonce | 20 |
| CALL | host to all | group | gid, seq, idx, t, winners | 30 to 120 |
| UNDO | host to all | group | gid, seq, idx, revoked | 30 to 120 |
| GRANT | host to all | group | gid, seq, name, canCall | 45 |
| TITLE | host to all | group | gid, seq, title | 55 |
| CLOSE | host to all | group | gid, seq, closedAt | 25 |
| TRANSFER | host to all | group | gid, seq, gen, newHost | 50 |
| SYNC_REQ | player to host | WHISPER | gid, haveSeq | 20 |
| SYNC | host to player | WHISPER | full record minus items | 1600 |

## 9. Top 5 decisions and risks

1. **Host-authoritative with seq per game**: one writer removes every ordering and conflict problem for the cost of host availability.
2. **Call set as the mark truth, bingoAt as host state**: matches the web's undo semantics exactly, which a pure derivation cannot.
3. **Many games, lobby from heartbeat cards**: no coordination needed, and the owner's open question about picking a game is answered by a list.
4. **Broadcast items once, cache by hash**: turns the one throttle hotspot into a non-issue and gives the item library for free.
5. **Drop chat, keep the timeline**: the raid has voice; the timeline preserves "undo erases the event" with no protocol.

Risks: host disconnect freezes calls until TRANSFER exists in practice, so grant a backup caller early and ship TRANSFER in v1. ChatThrottleLib shares budget with BigWigs and Plater, so joins during a pull may lag by seconds. Beta SavedVariables had a load bug fixed in build 70009; the host's persistence depends on it, so retest on launch build. Name normalization is the single anti-spoof check, so test the same-realm bare-name path on a connected realm.
