# DEA Bingo

Raid Bingo, played inside World of Warcraft: Forever. One person starts a game and calls the
squares, everyone gets the same 24 squares in a different order, and every board ticks over
live. The same rules as [raidbingo.com](https://raidbingo.com), without leaving the game.

Made for the Drip Enforcement Agency, and it works for any guild or group.

## Playing

- **Open the window** with the minimap button, `/dea`, or the addon compartment.
- **Start a game** from the Games tab: give it a title, pick who can join (your guild
  anywhere, or whoever is grouped with you), fill the 24 squares by pasting a list or
  starting from a previous game, and open it.
- **Join a game** from the toast that appears when someone opens one, or from the Games tab.
- **Calling**: the host, and anyone the host lets call, clicks a square and confirms. Clicking
  a called square undoes it, and an undo leaves no trace. There is also an alphabetical
  caller list with a filter under the calls panel.
- **Five in a row wins.** The night continues past the first bingo; winners are ranked by time.
- **The chip** at the top of the screen keeps the score while the window is closed. Nothing
  pops or makes a sound during combat.
- **History** keeps the last 20 finished games readable. **Options** has the theme, sounds,
  the chip and the minimap button.

## What it shares and keeps

Squares usually name real guildmates, so it is worth knowing where they go.

- **Opening a game broadcasts it.** The title, all 24 squares and the list of players go to
  everyone who can hear the game. In Guild mode, the default, that is every guild member
  online, in the raid or not. In Raid mode it is everyone grouped with you, pugs included.
  Pick Raid mode only when the squares are fit for strangers.
- **Nothing is ever posted to chat.** Everything travels on the addon channel, which only
  other copies of the addon read. Players without the addon see nothing.
- **Kept on this computer**, in the game's SavedVariables files in plain text: every set of
  squares you have hosted or played, the last 20 finished games with each player's character
  name and bingo time, and the games you have been offered. Tools that back up or sync your
  WTF folder carry these along. Deleting the addon's SavedVariables file clears them.

## Installing

Through the CurseForge or Wago app once it is listed, or by dropping the `DEABingo` folder
from a [release](../../releases) into `World of Warcraft/_classic_beta_/Interface/AddOns/`
(`_retail_`-style folder names will change at launch). The first install needs a client
restart; updates only need `/reload`.

## Developing

The repo root is the addon folder; `DEABingo.toc` lives here.

    DEABingo.toc      the addon
    Core/             Logic, Codec, Host, Mirror, Net, Store, View (pure, tested); Presets; Compat; Init
    UI/               Theme, Widgets, Board, Window, Chip, Toast
    Media/            crest textures, fonts (OFL)
    Libs/             embedded libraries, fetched, not committed
    tests/            busted specs, fixtures from the web game, a headless client smoke
    scripts/          test.sh, fetch-libs.sh, link-beta.sh
    docs/reviews/     the expert reviews the design came from; PLAN.md is the plan

    brew install luajit luarocks
    luarocks --lua-version=5.1 --lua-dir=/opt/homebrew/opt/luajit install busted
    scripts/fetch-libs.sh        # LibStub, CallbackHandler, AceComm, LibDataBroker, LibDBIcon
    scripts/test.sh              # busted under LuaJIT, then the headless client smoke
    scripts/link-beta.sh         # symlinks the repo into the beta client's AddOns

In game, `/dea help` lists the chat-box commands; `/dea debug` prints every message sent
and received; `/dea probe` prints what the client says about names.

`tests/fixtures/web_fixtures.lua` is generated from the website's `shared/` code and pins
the Lua port to the TypeScript draw for draw. Regenerate it when the web logic changes.

### How it works

The owner's client is the host and the only writer. State travels as sequenced addon
messages on the guild or group channel, one prefix, with every field validated and
authority taken from the server-stamped sender. Followers mirror the deltas and ask for a
snapshot when they fall behind. Boards are dealt by the host and stored, never derived.
Details are in `PLAN.md`.

### Releasing

Add a section to the top of `CHANGELOG.md`, then push a tag like `v0.1.1`. The release
workflow runs the BigWigs packager, which pulls the libraries from `.pkgmeta`, builds the zip
and uploads it to CurseForge (the project id is in the TOC; `CF_API_KEY` is a repository
secret; `WAGO_API_TOKEN` does the same for Wago). A separate step then creates the GitHub
release with the zip, using the top changelog section as the notes.

## Licence

MIT, for the addon's own code. The embedded libraries, the fonts and the crest each have their
own terms, collected in `Licenses/README.md` and shipped with every release: Ace3's
LibStub, CallbackHandler and AceComm under Ace3's BSD-style licence, LibDBIcon under the same
style, LibDataBroker as its author distributes it, Cinzel and Alegreya Sans under the SIL Open
Font License. The DEA crest is the guild's mark and is not under the MIT grant.
