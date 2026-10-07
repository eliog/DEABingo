# DEA Bingo

Raid Bingo, played inside World of Warcraft: Forever. One person starts a game and calls the
squares, everyone in the guild gets the same 24 squares in a different order, and every board
ticks over live. Same rules as the website at raidbingo.com.

**Status:** M1, protocol. Game logic and the host/mirror sync protocol are built and tested
under a loopback chat system; `/dea` drives a whole game from the chat box. No graphical UI yet.
`PLAN.md` holds the design and milestones, `docs/reviews/` the expert reviews it came from.

## Layout

    DEABingo.toc      the addon; the repo root IS the addon folder
    Core/             Logic, Codec, Host, Mirror, Net, Store (pure, tested); Presets; Compat; Init (/dea)
    Libs/             embedded libraries, fetched, not committed
    tests/            busted specs and fixtures generated from the web game
    scripts/          test.sh, fetch-libs.sh, link-beta.sh

## Developing

    brew install luajit luarocks
    luarocks --lua-version=5.1 --lua-dir=/opt/homebrew/opt/luajit install busted
    scripts/fetch-libs.sh        # pulls LibStub, CallbackHandler, AceComm into Libs/
    scripts/test.sh              # runs the suite under LuaJIT (Lua 5.1 semantics)
    scripts/link-beta.sh         # symlinks the repo into the beta client's AddOns

Restart the client the first time the addon appears; `/reload` is enough afterwards.
In game, `/dea` prints status, `/dea help` lists the commands, `/dea test` runs a self-check.
A whole game runs from the chat box until the UI lands: `/dea new <title>`, `/dea open`,
then on another client `/dea list`, `/dea join 1`, `/dea board`; the host calls with
`/dea call <n>` and undoes with `/dea undo <n>`.

`tests/fixtures/web_fixtures.lua` is generated from `../RaidBingo/shared` and pins the Lua
port to the TypeScript draw for draw. Regenerate it when the web logic changes.

## Licence

MIT. Ace3 libraries are BSD-licensed; fonts are under the SIL Open Font License, with the
licence text beside them.
