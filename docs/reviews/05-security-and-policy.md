# Security, policy and compliance review: RaidBingo addon

## 0. Two findings that change the plan

- **The name "Raid Bingo" is already taken on CurseForge.** https://www.curseforge.com/wow/addons/raid-bingo by gavinlandon, active (v2.0.13 uploaded 1 Oct 2026, ~4.5k downloads, MoP Classic / TBC Anniversary), zips named `RaidBingo_vX.zip`, so its folder is almost certainly `RaidBingo`. Two addons with the same folder name overwrite each other on install, and CurseForge will not accept a duplicate project name. Pick a distinct folder, project name, addon-message prefix and SavedVariables global now. A second competitor, Guild Bingo (https://www.curseforge.com/wow/addons/guild-bingo), is CDDL-licensed. Do not copy code from it into an MIT project.
- **Do not port the web app's banter chat over addon messages.** Carrying human chat inside addon messages is the exact pattern Blizzard has acted against: `!ChatTransmit` (in Forever's `bannedaddons.db2`) re-displayed server-filtered chat via addon comms and was removed "due to the policy of Blizzard/163" (https://www.curseforge.com/wow/addons/chattransmit); Classic 1.13.3 banned `SendAddonMessage` over CHANNEL to stop invisible broadcast (https://us.forums.blizzard.com/en/wow/t/classic-patch-1-13-3-lua-api-change/384543). Players already have /raid. Keep addon messages for game state only.

## 1. Blizzard policy

A raid minigame synced over RAID addon messages is squarely allowed; the Peggle addon, Guild Bingo and the existing Raid Bingo all do this. The governing text is the UI Add-On Development Policy (https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534, 2009, still the reference):

- Free of charge, no premium tiers, no in-game donation requests, no in-game ads.
- Code "must in no way be hidden or obfuscated". No minified Lua, no `loadstring` of encoded blobs (a DataStore fork was pulled for exactly this).
- No function that negatively impacts realms or other players: Blizzard explicitly lists "excessive use of the chat system".
- T-rated content, ToU/EULA compliance, Blizzard may disable any addon at its discretion (the `bannedaddons` mechanism).

What the Forever ban list tells us: Auctionator old versions (throughput abuse), GearScore (toxicity), RotationBuilder/VenturePlan (automation), ChatTransmit (chat as transport). None are "minigame" shaped. Our exposure is only chat volume and chat-as-transport.

Forever/Midnight "addon disarmament" that touches us (https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes, https://warcraft.wiki.gg/wiki/Secret_Values):

- `C_ChatInfo.InChatMessagingLockdown()` is true during encounters, M+, PvP matches and restricted maps. Tainted `SendChatMessage` to SAY/YELL/EMOTE/public channels is blocked then; PARTY/RAID/GUILD/INSTANCE are reported unrestricted. `Enum.SendAddonMessageResult` has `AddOnMessageLockdown` (11), so treat addon sends as possibly refused and queue for retry when the lockdown ends.
- Incoming whisper text and sender names can be secret values during lockdown. Comparing or boolean-testing a secret throws immediately; concatenation is allowed. Guard every value from `CHAT_MSG_ADDON` with `issecretvalue()` before comparing it, and wrap the handler in `pcall`.
- `UnitName` is secret only for non-player units in combat, so roster lookups on player units are safe. Never read health, auras or combat log.
- `COMBAT_LOG_EVENT*` registration errors; registering any unknown event aborts the file. Register events in `pcall` on Forever.

Throttle facts (https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage): prefix <=16 chars, payload <=255 bytes, 10-message burst per prefix recovering at 1/s, server-reconfigurable, and "the client may be disconnected" if too much goes out on separate prefixes. Use AceComm-3.0 + ChatThrottleLib, one prefix, and never a second prefix to dodge the bucket.

## 2. Threat model for the protocol

Anyone in the raid can send any payload with our prefix. Severity is rated for a friendly guild game with occasional pugs.

| Attack | Severity | Mitigation |
|---|---|---|
| Forged host messages (CALL, UNDO, CLOSE, GRANT, ITEMS) | High: ruins the game | Authority is the **server-provided sender** (arg 5 of `CHAT_MSG_ADDON`, always `Name-Realm`), never a name inside the payload. Accept state-changing messages only if sender == recorded host. Game id = host name-realm + nonce; a second ANNOUNCE for an existing id from a different sender is dropped. |
| Fake game announcements (lobby flooding) | Medium | Cap discovered games (e.g. 8) and per-sender games (1 hosted). Only list games whose host is in the group. |
| Oversized / malformed payloads | Medium: Lua error storms | Cap reassembled multipart length (4 KB) **before** deserializing. `pcall` AceSerializer. Skip LibDeflate entirely: payloads are tiny and decompression bombs have no built-in output cap. Hard-reject unknown message types and versions. |
| Numbers from the wire | Medium | Every number may be nan, inf, negative, float or huge. Check `type=="number"`, `n==n`, `n==floor(n)`, range (index 0..23, bestLine 0..5, timestamps within +-1 day of `GetServerTime()`). |
| Lua pattern DoS | Low | Lua patterns have no alternation, so catastrophic backtracking is limited, but `.-` chains on 4 KB inputs still cost. Run patterns only on length-capped strings and anchor them. |
| Escape-sequence injection (`|c`, `|H...|h`, `|T`, `|A`, `|K`, `|n`) | High: fake item links, 512 px textures, fake system text rendered on every player's screen | The server validates hyperlinks in real chat but **not addon payloads**, and `FontString:SetText` renders them. Escape `|` as `||` in all displayed untrusted text (item text, titles, names), or strip `|` entirely. (https://warcraft.wiki.gg/wiki/UI_escape_sequences, https://warcraft.wiki.gg/wiki/Hyperlinks) |
| Name spoofing (cross-realm ambiguity, lookalike letters) | Low: display only | Identity uses the full sender string; use `Ambiguate(name, "none")` for display only. Blizzard's name rules reject most lookalikes. |
| cleanText reimplementation (Lua 5.1, no utf8 lib, byte strings) | Medium | Strip `%c` bytes, strip zero-width/bidi/variation-selector UTF-8 byte sequences explicitly (`\226\128\139`, `\226\128\142`-`\226\128\174`, `\239\184\128`-`\239\184\143`, `\226\129\160`-`\226\129\175`), collapse whitespace, cap by bytes (240 for a 60-char item), validate UTF-8 well-formedness, and use `strlenutf8` for the user-facing length check. |
| SavedVariables tampering | Low locally, Medium when a host's file feeds a broadcast | Treat the file as untrusted input: schema-validate on `ADDON_LOADED`, cap sizes, migrate by version, never `loadstring`. Validate items from saved presets before broadcasting them. |
| Spam / churn (announce flood, join/leave, re-sync requests) | Medium: throttle starvation, UI thrash | Per-sender token bucket (5 messages / 10 s for non-host, 20 / 10 s for host), silent drop. Host coalesces roster broadcasts to <=1/s. Full-state replies via WHISPER to the requester only, at most one per requester per 10 s. |
| Non-members | Low | RAID distribution already limits receipt. For WHISPER, accept only from `UnitInRaid`/`UnitInParty` members. Drop everything when not grouped. |
| Replay / reorder | Low | Host stamps a monotonic sequence number per game; clients ignore stale seq, request a full sync on a gap. |

## 3. Privacy

- **Stored**: item sets and presets that name real guildmates, game histories with character names and times, the player's own character list. All in `WTF/Account/.../SavedVariables`, plaintext, readable by anyone with disk access, and synced by WTF-backup tools. Keep history small (e.g. last 20 games), offer "clear history".
- **Broadcast**: title, 24 items and the roster go to every raid member including pugs, invisibly. Recommendation: host sees a preflight line "N players in this raid are not in your guild and will see the item text" with a **Guild-only** toggle that sends and accepts only from `UnitIsInMyGuild` members. Default the toggle off but show the warning.
- **Chat output**: nothing is posted to real chat by default. Optional host-only "announce bingos to /raid" setting, one line per bingo, never on join/call. No SAY/YELL (blocked in lockdown anyway).
- The web app already accepts that presets name real people; carry the same stance into the README, and keep every real-name preset out of the repo.

## 4. Licensing and trademarks

- **Addon**: MIT, same as the web app. Libraries carry their own permissive licenses (Ace3 BSD-style, LibStub/ChatThrottleLib public domain) and the packager keeps each library's LICENSE in its folder.
- **Fonts**: Cinzel and Alegreya Sans are OFL 1.1. Verified from Google's font repo: neither declares a Reserved Font Name (https://raw.githubusercontent.com/google/fonts/main/ofl/cinzel/OFL.txt, https://raw.githubusercontent.com/google/fonts/main/ofl/alegreyasans/OFL.txt). Ship the unmodified `.ttf` files with their `OFL.txt` beside them in `Fonts/`, do not rename the files, do not subset. Bundling in software is explicitly permitted (OFL FAQ: https://ctan.math.washington.edu/tex-archive/fonts/cm-unicode/doc/OFL-FAQ.txt). Note the client loads font files at startup; adding one needs a restart.
- **Trademarks**: "Hearthstone", "Warcraft" and "World of Warcraft" are Blizzard marks. Using "Hearthstone" as the name of the free square in-game is fine as vocabulary; keep it out of the addon name, slug, icon and marketing. "for World of Warcraft" in the description is nominative use.
- **Art**: never copy BLPs/PNGs from the DataMining CDN dumps into the addon. Referencing in-client atlases by name through `SetAtlas` at runtime is standard and fine. Own glyphs only, as the web CLAUDE.md already requires.
- **Repo must not contain**: guild presets or any real character names, SavedVariables dumps, datamined art, API keys. `.gitignore`: `.release/`, `*.bak`, `WTF/`, `.env*`.

## 5. Publishing and supply chain

- BigWigs packager via GitHub Actions (https://warcraft.wiki.gg/wiki/Using_the_BigWigs_Packager_with_GitHub_Actions) releasing to CurseForge, Wago and GitHub Releases. Secrets `CF_API_KEY`, `WAGO_API_KEY` live only in GitHub Actions secrets; `GITHUB_TOKEN` is automatic.
- `.pkgmeta` `externals` for Ace3, LibStub, CallbackHandler, ChatThrottleLib, AceComm/AceSerializer, each pinned to a `tag:` or `commit:`. Never vendor hand-edited library copies; if you must patch, fork and pin the fork.
- `ignore:` the tests, docs and tooling. Ship `LICENSE`, `CHANGELOG.md` (the packager uses it; otherwise it generates from git), and the OFL files.
- TOC metadata: `## Interface: 16001`, `## Title`, `## Notes`, `## Author`, `## Version: @project-version@`, `## SavedVariables`, `## IconTexture`, `## X-License: MIT`, `## X-Website`, `## X-Curse-Project-ID`, `## X-Wago-ID`, `## X-Category: Miscellaneous`. CurseForge requires a license selection on the project; pick MIT there too. Wago wants the project ID in the TOC (https://docs.wago.io/).
- The interface number will likely bump at the 4 Nov launch. Keep it only in the TOC and never branch on it in Lua; the packager's auto-version flag may not know Forever yet, so update by hand.

## 6. Code-safety checklist

1. Authority comes from the `CHAT_MSG_ADDON` sender argument, never from payload fields.
2. Escape `|` as `||` (or strip it) in every untrusted string before it reaches a FontString or chat.
3. `pcall` every deserialization and every message handler; log and drop on failure.
4. Cap reassembled payload size before parsing; cap every string field by bytes and every array by count.
5. Treat every wire number as possibly nan, inf, float, negative or huge; validate type, integrality and range.
6. Check `issecretvalue()` before comparing anything received from a chat event.
7. One addon prefix, one AceComm instance, ChatThrottleLib priorities; never a second prefix to bypass throttling.
8. Per-sender token bucket; silent drops, never error popups triggered by remote input.
9. Only RAID/PARTY/INSTANCE_CHAT/WHISPER; never CHANNEL, SAY, YELL for addon messages.
10. No `loadstring`, no `RunScript`, no code in SavedVariables, no obfuscation or minification.
11. Never call protected functions (`ReloadUI`, unit targeting, secure frames) from a message handler.
12. Register events in `pcall`; initialise in `ADDON_LOADED`, not at file scope.
13. Validate SavedVariables on load with the same validators used for wire data.
14. Handle `AddOnMessageLockdown` and throttle results by queuing, never by spinning.
15. Run the message validators as pure Lua unit tests outside the client, ported 1:1 from `shared/validate.ts`.

## 7. Top decisions and risk register

**Decisions**

1. **Rename the addon** (folder, prefix, SavedVariables): "Raid Bingo" is taken and actively maintained.
2. **No in-addon chat**: real /raid exists, and chat-over-addon-messages is the banned pattern.
3. **Host-authoritative protocol keyed on server sender**: the only spoof-proof identity available.
4. **Plain AceSerializer, no compression**: payloads are small, bombs are not worth the risk.
5. **Escape-not-trust rendering**: every untrusted string passes one `escape()` before display.

**Risk register**

| Risk | Likelihood | Impact | Owner action |
|---|---|---|---|
| Name/folder collision with existing Raid Bingo | High | Medium (rejected upload, overwritten installs) | Rename before first release |
| Escape-sequence injection by a pug | Medium | High (fake loot links, textures) | Escape at render boundary |
| Forged host CALL/UNDO | Medium | High | Sender == host check |
| Secret-value comparison error in handler | Medium | Medium (handler dies mid-raid) | `issecretvalue` guards, `pcall` |
| Throttle disconnect from re-sync storm | Low | High | Per-requester sync cooldown, ChatThrottleLib |
| Interface bump at launch breaks loading | High | Low | TOC-only, "Load out of date" fallback |
| Real names leak via repo or presets | Low | Medium | No presets in repo, gitleaks |
| Blizzard policy action | Very low | High | No chat transport, no spam, visible MIT code |

## Sources

- UI Add-On Development Policy: https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534
- Classic 1.13.3 CHANNEL ban: https://us.forums.blizzard.com/en/wow/t/classic-patch-1-13-3-lua-api-change/384543
- ChatTransmit archival: https://www.curseforge.com/wow/addons/chattransmit
- Patch 12.0.0 API changes: https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes
- Secret Values: https://warcraft.wiki.gg/wiki/Secret_Values
- SendAddonMessage: https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage
- UI escape sequences: https://warcraft.wiki.gg/wiki/UI_escape_sequences
- Hyperlinks: https://warcraft.wiki.gg/wiki/Hyperlinks
- Icy Veins on eased combat restrictions: https://www.icy-veins.com/wow/news/combat-addon-restrictions-eased-in-midnight/
- BigWigs packager guide: https://warcraft.wiki.gg/wiki/Using_the_BigWigs_Packager_with_GitHub_Actions
- Wago docs: https://docs.wago.io/
- Existing Raid Bingo: https://www.curseforge.com/wow/addons/raid-bingo
- Guild Bingo: https://www.curseforge.com/wow/addons/guild-bingo
- Cinzel OFL: https://raw.githubusercontent.com/google/fonts/main/ofl/cinzel/OFL.txt
- Alegreya Sans OFL: https://raw.githubusercontent.com/google/fonts/main/ofl/alegreyasans/OFL.txt
- OFL FAQ: https://ctan.math.washington.edu/tex-archive/fonts/cm-unicode/doc/OFL-FAQ.txt
