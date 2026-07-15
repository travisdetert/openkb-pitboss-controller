"""Generate the app icon: a flame on a dark-ember rounded square, matching the
controller UI palette (flame #ff6b1a on #16110d). Pure Pillow — no external art.

Outputs (under build/):
  icon.png            1024x1024 master
  icon.iconset/*.png  the sizes macOS wants
The caller turns the iconset into icon.icns via `iconutil`.

Run:  . .venv/bin/activate && python scripts/make_icon.py
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
SS = 4                      # supersample factor for crisp anti-aliasing
W = 1024 * SS              # working resolution


# ---- helpers ---------------------------------------------------------------

def lerp(a, b, t):
    return a + (b - a) * t


def lerp_color(c1, c2, t):
    return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(3))


def cubic(p0, p1, p2, p3, n):
    """Sample a cubic bezier into n points."""
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = (mt**3 * p0[0] + 3 * mt**2 * t * p1[0]
             + 3 * mt * t**2 * p2[0] + t**3 * p3[0])
        y = (mt**3 * p0[1] + 3 * mt**2 * t * p1[1]
             + 3 * mt * t**2 * p2[1] + t**3 * p3[1])
        pts.append((x, y))
    return pts


def flame_outline():
    """Normalized (0..1) flame silhouette: sharp tip, widest in the lower
    third, rounded base (so it reads as fire, not a leaf)."""
    # Right contour, tip -> base, as three cubic segments.
    right = []
    # narrow, sharp taper from the tip
    right += cubic((0.50, 0.03), (0.53, 0.15), (0.66, 0.26), (0.71, 0.42), 40)
    # bulge out to the widest point low down
    right += cubic((0.71, 0.42), (0.78, 0.55), (0.82, 0.66), (0.74, 0.76), 40)
    # curve into the bottom with a horizontal tangent -> rounded base
    right += cubic((0.74, 0.76), (0.70, 0.84), (0.62, 0.93), (0.50, 0.93), 40)
    # Mirror to the left and walk back up to close the path.
    left = [(1.0 - x, y) for (x, y) in reversed(right)]
    return right + left


def map_pts(pts, x0, y0, w, h):
    return [(x0 + nx * w, y0 + ny * h) for (nx, ny) in pts]


def scale_about(pts, cx, cy, s):
    return [(cx + (x - cx) * s, cy + (y - cy) * s) for (x, y) in pts]


def vertical_gradient(size, stops):
    """RGB gradient image; stops = [(pos0..1, (r,g,b)), ...] top->bottom."""
    w, h = size
    grad = Image.new("RGB", (1, h))
    px = grad.load()
    for y in range(h):
        t = y / (h - 1)
        # find bracketing stops
        for i in range(len(stops) - 1):
            p0, c0 = stops[i]
            p1, c1 = stops[i + 1]
            if p0 <= t <= p1:
                lt = (t - p0) / (p1 - p0) if p1 > p0 else 0
                px[0, y] = lerp_color(c0, c1, lt)
                break
        else:
            px[0, y] = stops[-1][1]
    return grad.resize((w, h))


# ---- compose ---------------------------------------------------------------

def render():
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # Rounded-square background with a warm vertical gradient.
    radius = int(W * 0.225)
    bg_grad = vertical_gradient((W, W), [
        (0.0, (58, 38, 24)),    # warm top
        (0.55, (33, 26, 19)),
        (1.0, (18, 13, 9)),     # near-black base
    ]).convert("RGBA")
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, W - 1], radius, fill=255)
    img.paste(bg_grad, (0, 0), mask)

    # Soft warm glow behind the flame.
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * 0.28, W * 0.34, W * 0.72, W * 0.86], fill=(255, 110, 26, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.06))
    img = Image.alpha_composite(img, glow)

    # Flame geometry.
    bw, bh = W * 0.52, W * 0.66
    bx0, by0 = (W - bw) / 2, W * 0.16
    outline = flame_outline()
    outer = map_pts(outline, bx0, by0, bw, bh)

    # Outer flame (masked vertical gradient).
    fminy = min(p[1] for p in outer)
    fmaxy = max(p[1] for p in outer)
    fh = int(fmaxy - fminy)
    outer_grad = vertical_gradient((W, fh), [
        (0.0, (255, 214, 90)),
        (0.45, (255, 130, 30)),
        (1.0, (198, 60, 16)),
    ])
    fmask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(fmask).polygon(outer, fill=255)
    flame_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    flame_layer.paste(outer_grad.convert("RGBA"), (0, int(fminy)),
                      fmask.crop((0, int(fminy), W, int(fminy) + fh)))
    img = Image.alpha_composite(img, flame_layer)

    # Inner core flame: smaller, brighter, sitting lower.
    cx = W / 2
    cy = by0 + bh * 0.62
    inner = scale_about(outer, cx, cy, 0.52)
    iminy = min(p[1] for p in inner)
    imaxy = max(p[1] for p in inner)
    ih = int(imaxy - iminy)
    inner_grad = vertical_gradient((W, ih), [
        (0.0, (255, 245, 200)),
        (0.6, (255, 205, 70)),
        (1.0, (255, 150, 40)),
    ])
    imask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(imask).polygon(inner, fill=255)
    core_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    core_layer.paste(inner_grad.convert("RGBA"), (0, int(iminy)),
                     imask.crop((0, int(iminy), W, int(iminy) + ih)))
    img = Image.alpha_composite(img, core_layer)

    # Subtle top sheen on the background for a little depth.
    sheen = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).rounded_rectangle(
        [0, 0, W - 1, int(W * 0.5)], radius, fill=(255, 255, 255, 12))
    sheen.putalpha(sheen.split()[3].filter(ImageFilter.GaussianBlur(W * 0.02)))
    img = Image.alpha_composite(img, Image.composite(
        sheen, Image.new("RGBA", (W, W), (0, 0, 0, 0)), mask))

    return img.resize((1024, 1024), Image.LANCZOS)


def render_tray():
    """Monochrome flame silhouette for the macOS menu bar. Template images are
    pure black + alpha; macOS recolors them for light/dark themes."""
    S = 256
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bw, bh = S * 0.60, S * 0.84
    bx0, by0 = (S - bw) / 2, S * 0.08
    pts = map_pts(flame_outline(), bx0, by0, bw, bh)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    black = Image.new("RGBA", (S, S), (0, 0, 0, 255))
    return Image.composite(black, img, mask)


def main():
    os.makedirs(BUILD, exist_ok=True)
    icon = render()
    master = os.path.join(BUILD, "icon.png")
    icon.save(master)
    print("wrote", master)

    iconset = os.path.join(BUILD, "icon.iconset")
    os.makedirs(iconset, exist_ok=True)
    # macOS iconset: each size at 1x and 2x.
    for base in (16, 32, 64, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    # 1024 is the 512@2x slot.
    icon.save(os.path.join(iconset, "icon_512x512@2x.png"))
    print("wrote", iconset)

    # Menu-bar template icons (16pt @1x and @2x).
    tray = render_tray()
    tray.resize((16, 16), Image.LANCZOS).save(os.path.join(BUILD, "trayTemplate.png"))
    tray.resize((32, 32), Image.LANCZOS).save(os.path.join(BUILD, "trayTemplate@2x.png"))
    print("wrote tray template icons")


if __name__ == "__main__":
    main()
