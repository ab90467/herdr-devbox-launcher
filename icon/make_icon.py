import math
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# Vibrant diagonal 3-stop gradient: violet -> sky blue -> emerald.
stops = [
    (0.00, (124, 58, 237)),   # violet
    (0.55, (14, 165, 233)),   # sky blue
    (1.00, (16, 185, 129)),   # emerald
]

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def color_at(t):
    t = min(max(t, 0.0), 1.0)
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]
        t1, c1 = stops[i + 1]
        if t0 <= t <= t1:
            local = (t - t0) / (t1 - t0)
            return lerp(c0, c1, local)
    return stops[-1][1]

grad = Image.new("RGB", (SIZE, SIZE))
px = grad.load()
# Diagonal gradient along the (1,1) direction.
diag = SIZE * 2
for y in range(SIZE):
    for x in range(0, SIZE, 1):
        pass

# Faster: build gradient with numpy-free vectorized rows using per-pixel loop
# is slow at 1024x1024 (1M px) in pure python; use PIL's point-based approach
# instead with a precomputed 1D gradient projected along the diagonal.
import array
grad_len = SIZE * 2
lut = [color_at(i / (grad_len - 1)) for i in range(grad_len)]

pixels = bytearray(SIZE * SIZE * 3)
for y in range(SIZE):
    base = y
    row_off = y * SIZE * 3
    for x in range(SIZE):
        t = (x + y) / (2 * (SIZE - 1))
        idx = int(t * (grad_len - 1))
        r, g, b = lut[idx]
        o = row_off + x * 3
        pixels[o] = r
        pixels[o + 1] = g
        pixels[o + 2] = b

grad = Image.frombytes("RGB", (SIZE, SIZE), bytes(pixels))
img.paste(grad, (0, 0))

# Rounded-square (squircle-ish) mask, Big Sur proportions.
radius = int(SIZE * 0.1763)
mask = Image.new("L", (SIZE, SIZE), 0)
mdraw = ImageDraw.Draw(mask)
mdraw.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=radius, fill=255)
img.putalpha(mask)

draw = ImageDraw.Draw(img)

# Subtle depth: soft dark glow in bottom-right corner, soft light glow top-left,
# kept low-opacity and inside the shape only (no edge frame).
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gdraw = ImageDraw.Draw(glow)
gdraw.ellipse([SIZE * 0.55, SIZE * 0.55, SIZE * 1.3, SIZE * 1.3], fill=(0, 0, 0, 60))
gdraw.ellipse([-SIZE * 0.3, -SIZE * 0.3, SIZE * 0.45, SIZE * 0.45], fill=(255, 255, 255, 35))
glow = glow.filter(ImageFilter.GaussianBlur(SIZE * 0.08))
glow.putalpha(Image.composite(glow.split()[3], Image.new("L", (SIZE, SIZE), 0), mask))
img = Image.alpha_composite(img, glow)
draw = ImageDraw.Draw(img)

# Bold terminal chevron ">" with soft shadow for depth (no bright outline).
shadow_offset = 10
chevron_pts = [
    (360, 340),
    (590, 512),
    (360, 684),
]
line_width = 54

def draw_chevron(points, fill, width):
    draw.line([points[0], points[1]], fill=fill, width=width, joint="curve")
    draw.line([points[1], points[2]], fill=fill, width=width, joint="curve")
    r = width // 2
    for p in points:
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=fill)

shadow_pts = [(x + shadow_offset, y + shadow_offset) for x, y in chevron_pts]
draw_chevron(shadow_pts, (0, 0, 0, 70), line_width)
draw_chevron(chevron_pts, (255, 255, 255, 255), line_width)

# Cursor underscore.
cursor = [660, 648, 860, 648]
sr = line_width // 2
draw.rounded_rectangle(
    [cursor[0] + shadow_offset, cursor[1] + shadow_offset - sr,
     cursor[2] + shadow_offset, cursor[3] + shadow_offset + sr],
    radius=sr, fill=(0, 0, 0, 70),
)
draw.rounded_rectangle(
    [cursor[0], cursor[1] - sr, cursor[2], cursor[3] + sr],
    radius=sr, fill=(255, 255, 255, 255),
)

# Remote-signal glyph, top right, warm accent color for an extra pop of color.
cx, cy = 820, 230
amber = (251, 191, 36, 255)
amber_shadow = (0, 0, 0, 70)

def arc_ring(cx, cy, radius, width, color):
    bbox = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(bbox, start=215, end=325, fill=color, width=width)

for off, col in [(shadow_offset, amber_shadow), (0, amber)]:
    arc_ring(cx + off, cy + off, 150, 26, col)
    arc_ring(cx + off, cy + off, 100, 26, col)
    arc_ring(cx + off, cy + off, 50, 26, col)
    r = 20
    draw.ellipse(
        [cx + off - r, cy + off + 95 - r, cx + off + r, cy + off + 95 + r],
        fill=col,
    )

img.save("/tmp/icon-preview/new_icon.png")
print("done")
