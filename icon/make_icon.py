from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# Hot, high-energy diagonal gradient: magenta -> orange -> yellow.
# Far more eye-catching in a Dock full of cool-toned/muted icons.
stops = [
    (0.00, (236, 18, 139)),   # magenta
    (0.55, (255, 94, 0)),     # orange
    (1.00, (255, 206, 0)),    # yellow
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

grad_len = SIZE * 2
lut = [color_at(i / (grad_len - 1)) for i in range(grad_len)]

pixels = bytearray(SIZE * SIZE * 3)
for y in range(SIZE):
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

radius = int(SIZE * 0.1763)
mask = Image.new("L", (SIZE, SIZE), 0)
mdraw = ImageDraw.Draw(mask)
mdraw.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=radius, fill=255)
img.putalpha(mask)

draw = ImageDraw.Draw(img)

# Depth: dark corner glow + a brighter top-left highlight than before, for more punch.
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gdraw = ImageDraw.Draw(glow)
gdraw.ellipse([SIZE * 0.55, SIZE * 0.55, SIZE * 1.3, SIZE * 1.3], fill=(0, 0, 0, 70))
gdraw.ellipse([-SIZE * 0.3, -SIZE * 0.3, SIZE * 0.5, SIZE * 0.5], fill=(255, 255, 255, 55))
glow = glow.filter(ImageFilter.GaussianBlur(SIZE * 0.08))
glow.putalpha(Image.composite(glow.split()[3], Image.new("L", (SIZE, SIZE), 0), mask))
img = Image.alpha_composite(img, glow)
draw = ImageDraw.Draw(img)

shadow_offset = 10
chevron_pts = [
    (355, 330),
    (600, 512),
    (355, 694),
]
line_width = 58

def draw_chevron(points, fill, width):
    draw.line([points[0], points[1]], fill=fill, width=width, joint="curve")
    draw.line([points[1], points[2]], fill=fill, width=width, joint="curve")
    r = width // 2
    for p in points:
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=fill)

shadow_pts = [(x + shadow_offset, y + shadow_offset) for x, y in chevron_pts]
draw_chevron(shadow_pts, (0, 0, 0, 80), line_width)
draw_chevron(chevron_pts, (255, 255, 255, 255), line_width)

cursor = [670, 648, 880, 648]
sr = line_width // 2
draw.rounded_rectangle(
    [cursor[0] + shadow_offset, cursor[1] + shadow_offset - sr,
     cursor[2] + shadow_offset, cursor[3] + shadow_offset + sr],
    radius=sr, fill=(0, 0, 0, 80),
)
draw.rounded_rectangle(
    [cursor[0], cursor[1] - sr, cursor[2], cursor[3] + sr],
    radius=sr, fill=(255, 255, 255, 255),
)

# Remote-signal glyph: bright cyan reads as a cool, high-contrast pop against
# the hot magenta/orange/yellow background (amber would have blended in).
cx, cy = 820, 225
cyan = (0, 229, 255, 255)
cyan_shadow = (0, 0, 0, 80)

def arc_ring(cx, cy, radius, width, color):
    bbox = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(bbox, start=215, end=325, fill=color, width=width)

for off, col in [(shadow_offset, cyan_shadow), (0, cyan)]:
    arc_ring(cx + off, cy + off, 150, 28, col)
    arc_ring(cx + off, cy + off, 100, 28, col)
    arc_ring(cx + off, cy + off, 50, 28, col)
    r = 22
    draw.ellipse(
        [cx + off - r, cy + off + 95 - r, cx + off + r, cy + off + 95 + r],
        fill=col,
    )

img.save("new_icon.png")
print("done")
