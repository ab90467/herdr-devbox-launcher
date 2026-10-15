from PIL import Image, ImageDraw

SIZE = 1024
SS = 4  # supersample factor for a clean anti-aliased rounded-rect edge
BIG = SIZE * SS

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
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
img.paste(grad, (0, 0))

# Supersampled mask: draw the rounded-rect large, then downsize with LANCZOS
# so the edge is properly anti-aliased — no halo/ring from a hard-edged mask
# getting resampled later by sips for smaller icon sizes.
radius_big = int(BIG * 0.1763)
mask_big = Image.new("L", (BIG, BIG), 0)
ImageDraw.Draw(mask_big).rounded_rectangle([0, 0, BIG - 1, BIG - 1], radius=radius_big, fill=255)
mask = mask_big.resize((SIZE, SIZE), Image.LANCZOS)
img.putalpha(mask)

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
