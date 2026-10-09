# Changelog

## Unreleased

- Version shown on the Options tab and in the minimap tooltip, with a note on the Options tab when a newer release is around.
- Resizing the window: the History and Games lists now widen with it, and the Options rows no longer lose their hints and buttons.

## v0.1.1 (2026-10-09)

- Update notice: players hear once per session when a newer release is around, and a release can set a minimum version to join.
- Crest textures re-keyed from the source: the shield interior stays filled, so the D and A no longer show black counters and the speckle between the letters is gone. `design/crest-key.py` regenerates them.
- Options tab scrolls: at the minimum window height the rows ran past the panel.

Includes everything from v0.1.1-beta1 below.

## v0.1.1-beta1 (2026-10-07)

Prerelease for guild testers: every fix from the 2026-10-07 review (GitHub issues #1 to #35).

- Ownership and identity: no takeover by a higher generation, no identity replay, welcomes only after a join request.
- Capacity: paged snapshots, a 120-player cap, items cached from the broadcast, retitle keeps items, rate buckets per role.
- UI: real diagonals and diamond marks, board rows that grow instead of clipping, tabs that always leave history, a larger minimum size, toasts and chip clear of raid warnings, combat scrim, paste card fixes, reduce-motion option, clear history.
- Protocol: transfer wired with a confirmation, sync back-off, closed games reach lobbies, audience checks, sanitised wire times, website rules on closed games.
- Release: single release path with top-section notes, pinned libraries and actions, licence texts shipped.

## v0.1.0 (2026-10-07)

First playable build for the World of Warcraft: Forever beta.

- Host-authoritative game sync over addon messages, guild or group audience.
- Board, standings and call log in one window with tabs: Game, Games, History, Options.
- Click a square to call it after a confirmation; an alphabetical caller list with a filter.
- Toast with a Join button when a game opens; chip with a dot grid while the window is closed.
- Minimap button with an attention badge; sounds on call, undo and bingo, silent in combat.
- Setup with paste-a-list and a picker of previous games; finished games kept under History.
- The DEA crest in the header and as the free centre square.
