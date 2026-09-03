"""Generate OrderedLootList's greyscale UI textures as uncompressed 32-bit TGA.

Run from the repo root:  python Textures/make_textures.py

All assets are white-on-transparent so the addon can tint them at runtime
with SetVertexColor / SetBackdropBorderColor.  Dimensions are powers of two
(WoW requirement).  No image library needed: TGA is a small header plus raw
BGRA pixels, bottom-up.
"""
import math
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))


def write_tga(path, w, h, pixels):
    """pixels: list of rows (top row first), each a list of (r, g, b, a)."""
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,        # id length
        0,        # no colour map
        2,        # uncompressed true-colour
        0, 0, 0,  # colour map spec
        0, 0,     # x/y origin
        w, h,
        32,       # bits per pixel
        8,        # 8 alpha bits, bottom-left origin
    )
    body = bytearray()
    for row in reversed(pixels):          # TGA stores bottom row first
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    with open(path, "wb") as f:
        f.write(header + body)
    print(f"wrote {os.path.relpath(path, HERE)} ({w}x{h})")


def rounded_rect_coverage(w, h, radius, stroke, supersample=4):
    """Anti-aliased coverage of a 1px (stroke) rounded-rect outline that hugs
    the texture edge.  Returns a w*h grid of alpha 0..255.
    """
    grid = []
    ss = supersample
    inv = 1.0 / (ss * ss)
    for py in range(h):
        row = []
        for px in range(w):
            hits = 0
            for sy in range(ss):
                for sx in range(ss):
                    x = px + (sx + 0.5) / ss
                    y = py + (sy + 0.5) / ss
                    d_out = _rounded_rect_sdf(x, y, w, h, radius)
                    # outline band: between the outer edge and `stroke` px inside it
                    if -stroke <= d_out <= 0:
                        hits += 1
            row.append(int(round(255 * hits * inv)))
        grid.append(row)
    return grid


def _rounded_rect_sdf(x, y, w, h, r):
    """Signed distance to a rounded rect filling [0,w]x[0,h]; negative inside."""
    cx, cy = w / 2.0, h / 2.0
    hx, hy = w / 2.0 - r, h / 2.0 - r
    qx = abs(x - cx) - hx
    qy = abs(y - cy) - hy
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def edge_texture(name, size_w, size_h, radius, stroke=1.0):
    cov = rounded_rect_coverage(size_w, size_h, radius, stroke)
    pixels = [[(255, 255, 255, a) for a in row] for row in cov]
    write_tga(os.path.join(HERE, name), size_w, size_h, pixels)


def fill_texture(name, size_w, size_h, radius, supersample=4):
    """Solid anti-aliased rounded rect (the body under an edge_texture)."""
    ss = supersample
    inv = 1.0 / (ss * ss)
    pixels = []
    for py in range(size_h):
        row = []
        for px in range(size_w):
            hits = 0
            for sy in range(ss):
                for sx in range(ss):
                    x = px + (sx + 0.5) / ss
                    y = py + (sy + 0.5) / ss
                    if _rounded_rect_sdf(x, y, size_w, size_h, radius) <= 0:
                        hits += 1
            row.append((255, 255, 255, int(round(255 * hits * inv))))
        pixels.append(row)
    write_tga(os.path.join(HERE, name), size_w, size_h, pixels)


def chevron_texture(name, size=16, lines=3, gap=3, thickness=1.2):
    """Bottom-right resize grip: diagonal hairlines from lower-left to upper-right."""
    pixels = []
    for py in range(size):
        row = []
        for px in range(size):
            x, y = px + 0.5, py + 0.5
            a = 0.0
            for i in range(lines):
                # line: x + y = size + offset ; offsets step inward
                c = (size - 1) - i * gap
                d = abs((x + y) - c) / math.sqrt(2)
                # only the lower-right triangle
                if x + y >= c - 1.0:
                    a = max(a, max(0.0, 1.0 - (d - thickness / 2) / 0.8))
            row.append((255, 255, 255, int(round(255 * min(1.0, a)))))
        pixels.append(row)
    write_tga(os.path.join(HERE, name), size, size, pixels)


def dot_texture(name, size=16):
    """Anti-aliased filled disc (choice dots, status pills, avatar discs)."""
    pixels = []
    c = size / 2.0
    r = c - 1.0
    for py in range(size):
        row = []
        for px in range(size):
            d = math.hypot(px + 0.5 - c, py + 0.5 - c)
            a = max(0.0, min(1.0, r - d + 0.5))
            row.append((255, 255, 255, int(round(255 * a))))
        pixels.append(row)
    write_tga(os.path.join(HERE, name), size, size, pixels)


if __name__ == "__main__":
    # 9-slice edges: used as `edgeFile` with edgeSize = corner*? see Core.lua
    # Rounded outlines + matching solid bodies.  Both are sliced at runtime by
    # ns.SkinNineSlice (UI/Widgets.lua) into 9 textures with explicit
    # texcoords; they are NOT in Blizzard's 8-segment edgeFile layout.
    edge_texture("frame-edge.tga", 64, 64, radius=6)   # frames  (corner slice 8)
    fill_texture("frame-fill.tga", 64, 64, radius=6)
    edge_texture("btn-edge.tga",   32, 32, radius=4)   # buttons, segmented (corner slice 6)
    fill_texture("btn-fill.tga",   32, 32, radius=4)
    edge_texture("pill-edge.tga",  32, 16, radius=2)   # pills, badges, icon edges (corner slice 4)
    fill_texture("pill-fill.tga",  32, 16, radius=2)
    chevron_texture("resize-chevron.tga")
    dot_texture("dot.tga")
