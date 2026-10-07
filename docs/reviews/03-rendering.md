# RaidBingo addon: visual and rendering recommendation

## 1. Rendering strategy: a three-layer hybrid

**What Peggle did and what to copy.** The PopCap addon drew everything with Texture regions on a deep frame hierarchy and ran a per-frame OnUpdate for ball physics and particles. The still-maintained PeggleClassic port is 8 MB on disk, nearly all art, and its one open bug is a taint error from comparing a secret string in its network parser (https://wowinterface.com/downloads/info24964-PeggleClassic.html , https://www.engadget.com/2009-04-23-wow-insider-exclusive-popcap-releases-peggle-for-wow.html). Copy the frame hierarchy and the single OnUpdate driver. Do not copy the 8 MB of baked bitmaps or the per-cell texture swapping. Bingo is a flat, geometric UI, so most of it can be drawn with colour fills.

**Layer A, pure colour (most of the UI).** `Texture:SetColorTexture(r,g,b,a)` for every cell face, panel, rule line and bar. `TextureBase:SetGradient("VERTICAL", CreateColor(...), CreateColor(...))` for the stone sheen on cells and the fel wash on called cells. The 10.0 signature takes two ColorMixin objects and merged the old SetGradientAlpha (https://warcraft.wiki.gg/wiki/API:TextureBase_SetGradient). Colour textures are resolution independent, theme-swappable at runtime, and free to download.

**Layer B, one shipped alpha sheet (shapes the engine cannot draw).** A single 512x512 32-bit TGA, `Media/rb_sheet.tga`, holding white-on-transparent shapes tinted at runtime with `SetVertexColor`:
- chamfer corner cutters for the cell (four 16 px triangles) used as MaskTexture via `Frame:CreateMaskTexture` plus `Texture:AddMaskTexture` (https://warcraft.wiki.gg/wiki/UIOBJECT_MaskTexture)
- the Hearthstone glyph at 64 and 128 px, rasterised from the exact path in `client/app.js` lines 448-450
- the six-stone logo mark from `app.js` lines 120-122
- a soft radial glow, a 1 px strike-through end cap, a flag icon for callers, a check mark, a dashed-rule tile
- 8 x 8 soft particle, a thin ring for the ignite flash

**Layer C, Blizzard atlases (chrome only).** Use atlases for things players already read as "WoW UI": the `_Common-Opacity-Frame-NineSlice-*` and `_Common-Opacity-Background-NineSlice-*` set for the window frame via `NineSliceUtil.ApplyLayout`, `!ButtonGreenGlow-NineSlice-*` for the primary button hover, and `UI-HUD-ActionBar-IconFrame-Mouseover`-style highlights. All of these are in the Forever `uitextureatlaselement` dump at `DataMining/WHATS-NEW.md` lines 86-108. Never use atlases for the mark, the glyph or the logo. That is where the trademark rule bites.

## 2. The board

**Cell anatomy.** One `Button` per cell from a pool, built by a `RaidBingoCellMixin`:
1. `face` colour texture, surface colour
2. `sheen` gradient at 8 percent alpha
3. `border` four 1 px colour textures, not a NineSlice, so colours swap per state
4. `topbar` 2 px colour texture, the called signal from `.cell.on::after`
5. `glow` sheet glyph in ADD blend mode, hidden until called
6. `text` FontString, `SetWordWrap(true)`, `SetNonSpaceWrap(true)`, `SetJustifyH("CENTER")`, insets 6 px
7. `strike` 1 px colour texture over the text, shown when called
8. mask: the chamfer cutter masks face, sheen and glow together

States map directly from `app.css`: idle, hover raises border to `line-strong`, pressed darkens the face 8 percent, called uses `fel-wash` face plus fel border, topbar and strike plus bold font, winning line uses fel face with `fel-ink` text and the strike in ink colour. Called keeps three signals, exactly as the CSS comment says, so colour-blind raiders still read it.

**Free centre.** Face uses the `sunk` colour, the Hearthstone glyph tinted fel at 42 percent of the cell width, a Cinzel label "HEARTHSTONE" that hides under 70 px cells, and the dashed topbar tile with `SetHorizTile(true)`.

**One fitted size.** Port the `fit()` loop in `app.js` lines 405-433 to Lua with a hidden ruler FontString:

```lua
local ruler = UIParent:CreateFontString(nil, "ARTWORK", "RaidBingoCellFont")
ruler:Hide(); ruler:SetWordWrap(true); ruler:SetNonSpaceWrap(true)
local function Fits(size, width, maxH)
  ruler:SetWidth(width - 12)
  ruler:SetFont(ALEGREYA, size, "")
  for _, item in ipairs(items) do
    ruler:SetText(item)
    if ruler:GetStringHeight() > maxH or ruler:IsTruncated() then return false end
  end
  return true
end
-- binary search lo..hi in 0.5 steps, then grow row height by 6 and retry, max 4 grows
```

`GetStringHeight`, `GetNumLines` and `IsTruncated` are all in the SimpleFontString API (https://warcraft.wiki.gg/wiki/UIOBJECT_FontString). `GetUnboundedStringWidth` catches a single unbreakable 60-character token. Run the fit on `OnSizeChanged` of the board frame, debounced one frame, never per OnUpdate. For long phrases, hovering shows a `GameTooltip` with the full item, and clicking opens a sheet frame mirroring `.sheet` with the phrase and its call time.

**Pixel snapping.** Store the pixel multiplier once: `local _, h = GetPhysicalScreenSize(); PX = 768 / h / UIParent:GetEffectiveScale()`. The 768-based formula is the standard UI scale rule (https://warcraft.wiki.gg/wiki/UI_Scale). Multiply all 1 px and 2 px thicknesses by PX, recompute on `UI_SCALE_CHANGED` and `DISPLAY_SIZE_CHANGED`, and call `SetSnapToPixelGrid(true)` with `SetTexelSnappingBias(1)` on the border and strike textures only (https://warcraft.wiki.gg/wiki/API_TextureBase_SetSnapToPixelGrid). Leave snapping off on the glow and glyph so they stay smooth.

## 3. Fonts

Ship `Media/Fonts/Cinzel-Bold.ttf`, `AlegreyaSans-Regular.ttf`, `AlegreyaSans-Bold.ttf`, with `OFL.txt` beside them and the licence named in the TOC notes. Define four font objects in `Fonts.xml`: `RaidBingoHeading` (Cinzel 19, letter-spacing is not available, so fake it with uppercase and a wider FontString), `RaidBingoEyebrow` (Cinzel 11), `RaidBingoCell` (Alegreya 12, resized by the fit), `RaidBingoBody` (Alegreya 13). Since 10.0 the flags argument of `SetFont` is mandatory, pass `""` (https://warcraft.wiki.gg/wiki/API_FontInstance_SetFont).

**Non-Latin caveat.** The client does not fall back glyph by glyph. A Cyrillic or CJK item typed into a Cinzel FontString renders as empty boxes, which is why LibSharedMedia marks fonts as Latin-only unless told otherwise and skips them on ruRU, koKR, zhCN and zhTW clients (https://wowinterface.com/forums/showthread.php?p=319503). Follow the same convention: branch on `GetLocale()` at load and substitute Blizzard's locale font paths, `Fonts\FRIZQT___CYR.TTF`, `Fonts\2002.TTF`, `Fonts\ARKai_T.ttf` (https://wowinterface.com/forums/showthread.php?p=265651). Item text is player-typed, so also scan each item for bytes above U+024F and switch the cell font object to the Blizzard fallback for that game only. Headings can stay Cinzel because they are addon strings.

**Readability over the world.** Use `SetShadowOffset(1,-1)` with a 65 percent black shadow on body text, matching the `--engrave` CSS. Reserve `OUTLINE` for the mini board, which floats over combat.

## 4. Animation and juice

**Driver.** One OnUpdate on the root frame that steps a tween list, LibAnimate style, and goes dormant when the list is empty. Use AnimationGroups only for self-contained loops that never touch alpha the code also sets. Known quirks are real: an AnimationGroup alpha overwrites child alpha set by code, and Translation offsets are not scaled so a tween lands off-target under pixel-perfect scale (https://www.wowinterface.com/forums/showthread.php?p=315356). `SetToFinalAlpha(true)` exists to keep final alpha (https://warcraft.wiki.gg/wiki/UIOBJECT_AnimationGroup), but it is still simpler to own alpha in one place.

**Call.** 420 ms ignite from `.cell[data-just-called]`: scale 0.94 to 1 via `Frame:SetScale`, glow alpha 1 to 0 in ADD blend, face brightened via `SetVertexColor` 1.6 to 1. Six particles from the sheet's soft dot, pooled, fel tinted, fading over 500 ms. **Undo** is the reverse at 200 ms with no particles, since undo "leaves no trace". **Winning line** draws a 2 px fel bar through the five cells, growing from the completing cell over 350 ms. **Bingo** shows a banner frame mirroring `.banner` in Cinzel, with a 1.2 s particle burst of 24 sprites and `PlaySound(SOUNDKIT.READY_CHECK)` for a lightweight default (https://warcraft.wiki.gg/wiki/API_PlaySound), with an option for a shipped `Media/bingo.ogg` via `PlaySoundFile`, which accepts addon paths and OGG (https://warcraft.wiki.gg/wiki/API_PlaySoundFile). **Standings** reorder by tweening row Y via `SetPoint` offsets over 250 ms, with the mover's name flashing fel. **Toasts** slide up from the bottom centre over 180 ms, mirroring `.toast`, max three stacked.

**Budget.** Target under 0.3 ms per frame during a call animation in a 40-man raid. Cap particles at 32 live sprites, reuse them, step the tween list with `elapsed`, and honour a "reduced motion" checkbox that disables scale and particles entirely. Never animate during `InCombatLockdown()` beyond alpha on the mini board.

## 5. Layout and windows

- **Main window**, 960 x 640 default: board left at a flexible width, 320 px rail right with Standings, Call log and Chat panels, matching `design/BoardPlayer.dc.html`. Resizable via a corner grip with `SetResizeBounds(640, 480)`, saved to SavedVariables. Window chrome is the Common-Opacity NineSlice tinted to the `surface` colour.
- **Caller panel** for owners and granted callers: the same board with a "CALLER" bar styled like `.callbar.owner` and tap-to-call, tap-again-to-undo semantics.
- **Lobby and game picker**: a scrolling list of gamecards with the 24-segment call bar from `.bar`, join button, owner name and raider count.
- **Item editor**: two columns of 12 numbered EditBoxes with Cinzel slot numbers, counters that turn gold past 48 characters and block past 60.
- **Mini board** for combat: a 5 x 5 grid of 14 px colour squares like `.mini`, no text, pinned near the minimap, toggled automatically on `PLAYER_REGEN_DISABLED`.
- **Minimap button** via LibDBIcon and an LDB data object showing "15/24 · 1 away".
- **Edit Mode**: not in v1. LibEditMode exists and limits Blizzard method reuse to avoid taint (https://www.wowinterface.com/downloads/info26456-LibEditMode.html), but a movable frame with saved position covers the need.
- **ESC to close**: give the window a global name and `tinsert(UISpecialFrames, "RaidBingoFrame")`.
- **Theme**: a `Theme` table holding both palettes from `app.css`, applied through one `Restyle()` pass that re-colours every registered texture. Default dark, with light as an option.
- **Colour blindness**: keep the three-signal called state and offer an alternate mark colour, gold, in settings.

## 6. Asset pipeline

1. Author shapes as SVG in `design/addon-sheet.svg` on a 512 grid, white fills on transparent.
2. Rasterise with `rsvg-convert -w 512 -h 512 sheet.svg -o sheet.png`.
3. Convert with `magick sheet.png -depth 8 -type TrueColorAlpha -compress none RaidBingo/Media/rb_sheet.tga`. WoW requires power-of-two edges and 32-bit depth for alpha (https://warcraft.wiki.gg/wiki/TGA_files).
4. Optional BLP for size: Kanma's BLPConverter handles BLP2 DXT5 with 8-bit alpha (https://github.com/suuphoenix/BLPConverter). Keep TGA for v1, the sheet is under 1 MB.
5. Generate `Media/Sheet.lua` from the SVG ids with left, right, top, bottom UV values, so Lua calls `tex:SetTexCoord(unpack(SHEET.hearth64))`.
6. Crispness checklist: 2 px transparent gutter between sprites, no mip-mapping artefacts by keeping glyph edges off the gutter, premultiplied-looking fringes removed with `-channel A -threshold 0` checks, test at UI scale 0.64 and 1.0 and at 4K.

## 7. Top five decisions and risks

1. **Colour textures first, one alpha sheet second, atlases only for chrome.** Keeps the download tiny, theme-swappable and trademark-safe.
2. **One OnUpdate tween driver, AnimationGroups avoided for alpha.** Sidesteps the documented alpha and translation quirks.
3. **One fitted font size via a hidden ruler FontString with grow-rows fallback.** Honours "text never clips" and matches the web algorithm.
4. **Shipped OFL fonts with locale and per-item fallback to Blizzard fonts.** Keeps the design on Latin clients without breaking Russian or CJK raids.
5. **Pixel-multiplier from GetPhysicalScreenSize applied to all hairlines.** Stone chamfers and 1 px borders stay crisp at every scale.

Risks: a 60-character item at a 400 px wide board gives 74 px cells, where the fit bottoms out at 9.5 px and rows must grow, so enforce a 560 px minimum board width in the main window and lean on the tooltip. Particle bursts during a raid pull can spike frame time, hence the hard sprite cap and the combat gate. Cinzel and Alegreya Sans are OFL, but the licence files must ship and the TOC must not rename the fonts. Forever's secret-value rules can taint string comparisons in message parsing, which is exactly where PeggleClassic broke, so wrap parsed names in `issecretvalue` checks before they reach any FontString.
