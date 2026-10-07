# Key the guild crest out of its black source image and write the addon textures.
#
#   python3 design/crest-key.py            (needs Pillow: pip install pillow)
#
# The shield's fabric is black in places, so a colour key cannot tell it from the
# background. Instead the emblem's silhouette is found geometrically: every pixel
# that is not black, closed morphologically so thin black channels between the
# fabric and the outside are plugged, then the background is flooded from the
# corners and whatever it cannot reach is the emblem. The interior stays filled,
# so the counters of the D and the A match the rest of the shield.
import sys
from collections import deque
from PIL import Image, ImageFilter

ROOT = __file__.rsplit("/design/", 1)[0] if "/design/" in __file__ else "."
SRC = f"{ROOT}/design/dea-logo-source.png"
OUT = f"{ROOT}/Media"
NONBLACK = 14      # channel sum above which a pixel counts as part of the emblem
CLOSE = 8          # radius of the morphological close, in source pixels
MIN_ISLAND = 400   # stray components smaller than this are dropped
EDGE_REF = 60      # brightness treated as fully opaque on the anti-aliased rim

src = Image.open(SRC).convert("RGB"); W, H = src.size; p = src.load()

mask = Image.new("L", (W, H), 0); mp = mask.load()
for y in range(H):
    for x in range(W):
        if sum(p[x, y]) > NONBLACK: mp[x, y] = 255
closed = mask.filter(ImageFilter.MaxFilter(CLOSE * 2 + 1)).filter(ImageFilter.MinFilter(CLOSE * 2 + 1)).load()

bg = bytearray(W * H); q = deque()
for sx, sy in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1)]:
    bg[sy * W + sx] = 1; q.append((sx, sy))
while q:
    x, y = q.popleft()
    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
        if 0 <= nx < W and 0 <= ny < H:
            i = ny * W + nx
            if not bg[i] and closed[nx, ny] == 0: bg[i] = 1; q.append((nx, ny))
sil = Image.frombytes("L", (W, H), bytes(0 if v else 255 for v in bg))

def despeckle(m, minpx):
    mp = m.load(); seen = bytearray(W * H); out = m.copy(); op = out.load()
    for y in range(H):
        for x in range(W):
            i = y * W + x
            if seen[i] or mp[x, y] == 0: continue
            comp = [(x, y)]; seen[i] = 1; qq = deque(comp)
            while qq:
                cx, cy = qq.popleft()
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if 0 <= nx < W and 0 <= ny < H:
                        j = ny * W + nx
                        if not seen[j] and mp[nx, ny]: seen[j] = 1; qq.append((nx, ny)); comp.append((nx, ny))
            if len(comp) < minpx:
                for cx, cy in comp: op[cx, cy] = 0
    return out

sil = despeckle(sil, MIN_ISLAND)
alpha = sil.filter(ImageFilter.GaussianBlur(0.8)); ap = alpha.load(); sp = sil.load()
for y in range(1, H - 1):
    for x in range(1, W - 1):
        if sp[x, y] and (not sp[x + 1, y] or not sp[x - 1, y] or not sp[x, y + 1] or not sp[x, y - 1]):
            ap[x, y] = min(ap[x, y], min(255, max(p[x, y]) * 255 // EDGE_REF))
crest = src.convert("RGBA"); crest.putalpha(alpha)

# Crop to content, pad to a square with a small margin, write power-of-two textures.
crest = crest.crop(crest.getbbox()); cw, ch = crest.size
side = int(max(cw, ch) * 1.04)
canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
canvas.paste(crest, ((side - cw) // 2, (side - ch) // 2))
for size, name in ((512, "logo"), (128, "logo128"), (64, "icon")):
    canvas.resize((size, size), Image.LANCZOS).save(f"{OUT}/{name}.tga")
canvas.resize((512, 512), Image.LANCZOS).save(f"{ROOT}/design/crest.png")
print("wrote Media/logo.tga logo128.tga icon.tga and design/crest.png from", cw, "x", ch)
