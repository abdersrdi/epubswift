# Usage: python frame_screenshots.py <folder containing screenshots/iphone and screenshots/ipad> <output folder>
import os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

RAW = sys.argv[1]            # folder containing iphone/ and ipad/
OUT = sys.argv[2]            # output folder
FONT = r"C:\Windows\Fonts\segoeuib.ttf"
TOP, BOTTOM = (79, 70, 229), (139, 63, 234)
ORDER = [("library", "Your books, always free"),
         ("reader", "A clean, comfortable reader"),
         ("readerNight", "Night mode for late reading"),
         ("tools", "10 powerful EPUB tools"),
         ("pdf", "EPUB to PDF in one tap"),
         ("meta", "Edit title, author and cover"),
         ("validate", "Check and repair your books"),
         ("paywall", "Unlock the tools, remove ads")]

def banner_score(path):
    """Mean brightness of the band where the system notification banner appears (high = banner present)."""
    im = Image.open(path).convert("L")
    w, h = im.size
    band = im.crop((int(w * 0.2), int(h * 0.02), int(w * 0.8), int(h * 0.065)))
    px = list(band.getdata())
    return sum(px) / len(px)

def pick(folder, name):
    a = os.path.join(folder, name + ".png")
    b = os.path.join(folder, name + "-b.png")
    if not os.path.exists(b): return a
    sa, sb = banner_score(a), banner_score(b)
    chosen = a if sa <= sb else b
    print(f"{folder.split('/')[-1]:7} {name:9} first={sa:5.1f} second={sb:5.1f} -> {os.path.basename(chosen)}")
    return chosen

def gradient(w, h):
    base = Image.new("RGB", (w, h), TOP); px = base.load()
    for y in range(h):
        t = y / (h - 1); c = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        for x in range(w): px[x, y] = c
    return base

def wrap(d, text, font, maxw):
    lines, cur = [], ""
    for w in text.split():
        t = (cur + " " + w).strip()
        if d.textlength(t, font=font) <= maxw: cur = t
        else: lines.append(cur); cur = w
    lines.append(cur); return lines

def make(src, out, W, H, sw, sy, fs, caption):
    bg = gradient(W, H).convert("RGBA")
    shot = Image.open(src).convert("RGBA"); sh = int(shot.height * sw / shot.width)
    shot = shot.resize((sw, sh), Image.LANCZOS); r = int(sw * 0.07)
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.size[0] - 1, shot.size[1] - 1), r, fill=255)
    x = (W - sw) // 2
    sm = Image.new("L", (W, H), 0)
    ImageDraw.Draw(sm).rounded_rectangle((x, sy + 25, x + sw, sy + sh + 25), r, fill=110)
    sm = sm.filter(ImageFilter.GaussianBlur(35))
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0)); shadow.putalpha(sm); bg.alpha_composite(shadow)
    bg.paste(shot, (x, sy), mask)
    d = ImageDraw.Draw(bg); font = ImageFont.truetype(FONT, fs)
    lines = wrap(d, caption, font, int(W * 0.86)); lh = int(fs * 1.18); ty = (sy - lh * len(lines)) // 2
    for i, l in enumerate(lines):
        d.text(((W - d.textlength(l, font=font)) / 2, ty + i * lh), l, font=font, fill=(255, 255, 255, 255))
    bg.convert("RGB").save(out, "PNG", optimize=True)

for d in ("iphone", "ipad", "foldable-2007x2853", "foldable-1398x2034"):
    os.makedirs(f"{OUT}/{d}", exist_ok=True)
for i, (name, cap) in enumerate(ORDER, 1):
    make(pick(RAW + "/screenshots/iphone", name), f"{OUT}/iphone/{i:02d}-{name}.png", 1320, 2868, 1100, 500, 112, cap)
    ipad = pick(RAW + "/screenshots/ipad", name)
    make(ipad, f"{OUT}/ipad/{i:02d}-{name}.png", 2064, 2752, 1650, 430, 128, cap)
    # Foldable iPhone (unfolded, tablet-like): built from the iPad captures.
    make(ipad, f"{OUT}/foldable-2007x2853/{i:02d}-{name}.png", 2007, 2853, 1560, 470, 124, cap)
    make(ipad, f"{OUT}/foldable-1398x2034/{i:02d}-{name}.png", 1398, 2034, 1090, 340, 90, cap)

# extra phone sizes: the same screenshots at 1206x2622 and 1179x2556
for folder, (w, h) in {"iphone-1206x2622": (1206, 2622), "iphone-1179x2556": (1179, 2556)}.items():
    os.makedirs(f"{OUT}/{folder}", exist_ok=True)
    for f in sorted(os.listdir(OUT + "/iphone")):
        Image.open(f"{OUT}/iphone/{f}").convert("RGB").resize((w, h), Image.LANCZOS).save(f"{OUT}/{folder}/{f}", "PNG", optimize=True)
print("done", OUT)
