"""Draws the Launch Timer app icon (1024×1024, no alpha). Run: python3 design/make_icon.py"""
from PIL import Image, ImageDraw, ImageFilter
import math, os

S = 3072                                   # draw at 3× and downsample for smooth edges
top, bottom = (34, 36, 44), (8, 9, 12)
grad = Image.linear_gradient("L").resize((S, S))
img = Image.composite(Image.new("RGB", (S, S), bottom), Image.new("RGB", (S, S), top), grad)
d = ImageDraw.Draw(img)

cx, cy, r = S * 0.5, S * 0.56, S * 0.34
start, end = 150, 390                      # gauge sweep, degrees (PIL: 0 = east, clockwise)
w = int(S * 0.075)
box = [cx - r, cy - r, cx + r, cy + r]
d.arc(box, start, end, fill=(58, 62, 74), width=w)

# The lit part of the gauge, with a soft glow.
lit = Image.new("L", (S, S), 0)
ImageDraw.Draw(lit).arc(box, start, 330, fill=255, width=w)
img.paste((255, 138, 31), mask=lit.filter(ImageFilter.GaussianBlur(S * 0.025)).point(lambda v: int(v * 0.6)))
img.paste((255, 138, 31), mask=lit)

# Tick marks.
for i in range(9):
    a = math.radians(start + (end - start) * i / 8)
    r1, r2 = r - w * 1.1, r - w * 1.9
    d.line([(cx + r1 * math.cos(a), cy + r1 * math.sin(a)), (cx + r2 * math.cos(a), cy + r2 * math.sin(a))],
           fill=(200, 204, 214), width=int(S * 0.014))

# Needle pointing at the end of the lit arc.
a = math.radians(330)
tip = (cx + (r - w * 1.2) * math.cos(a), cy + (r - w * 1.2) * math.sin(a))
n = (math.cos(a + math.pi / 2), math.sin(a + math.pi / 2))
base = S * 0.035
d.polygon([tip, (cx + n[0] * base, cy + n[1] * base), (cx - n[0] * base, cy - n[1] * base)], fill=(255, 255, 255))
d.ellipse([cx - S * 0.06, cy - S * 0.06, cx + S * 0.06, cy + S * 0.06], fill=(255, 255, 255))
d.ellipse([cx - S * 0.028, cy - S * 0.028, cx + S * 0.028, cy + S * 0.028], fill=(255, 138, 31))

out = img.resize((1024, 1024), Image.LANCZOS)
dest = os.path.join(os.path.dirname(__file__), "..", "Sources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(dest, exist_ok=True)
out.save(os.path.join(dest, "icon-1024.png"))
out.resize((256, 256), Image.LANCZOS).save(os.path.join(os.path.dirname(__file__), "..", "docs", "icon.png"))
print("saved")
