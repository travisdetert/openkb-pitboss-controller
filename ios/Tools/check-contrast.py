#!/usr/bin/env python3
"""Verify both themes meet WCAG AA (4.5:1) for text on their own surfaces.

The theme comment in App/PitBoss/Theme.swift claims AA; this is what makes that
claim checkable rather than aspirational. Values are parsed straight out of
Theme.swift so the two cannot drift.

    python3 ios/Tools/check-contrast.py
"""
import re
import sys
from pathlib import Path

THEME = Path(__file__).resolve().parents[1] / "App/PitBoss/Theme.swift"
AA = 4.5


def luminance(hexv):
    def channel(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (hexv >> 16) & 255, (hexv >> 8) & 255, hexv & 255
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def parse_themes(text):
    """Pull `static let <name> = Theme(...)` blocks and their hex tokens."""
    themes = {}
    for name, body in re.findall(r"static let (\w+) = Theme\((.*?)\n    \)", text, re.S):
        tokens = dict(
            (k, int(v, 16))
            for k, v in re.findall(r"(\w+):\s*Color\(hex:\s*0x([0-9A-Fa-f]{6})\)", body)
        )
        themes[name] = tokens
    return themes


def main():
    themes = parse_themes(THEME.read_text(encoding="utf-8"))
    if not themes:
        sys.exit(f"no themes parsed from {THEME}")

    # Foregrounds that carry meaning, against every ground they sit on.
    foregrounds = ["text", "textMuted", "accent", "flame", "green", "amber", "red"]
    grounds = ["background", "surface", "surfaceRaised"]

    failures = []
    for theme_name, tokens in sorted(themes.items()):
        print(f"--- {theme_name} ---")
        for fg in foregrounds:
            for bg in grounds:
                if fg not in tokens or bg not in tokens:
                    continue
                r = ratio(tokens[fg], tokens[bg])
                ok = r >= AA
                print(f"  {fg:10} on {bg:14} {r:5.2f}  {'OK' if ok else 'FAIL'}")
                if not ok:
                    failures.append(f"{theme_name}: {fg} on {bg} is {r:.2f}, needs {AA}")

    print()
    if failures:
        print(f"✗ {len(failures)} contrast failure(s)")
        for f in failures:
            print(f"    {f}")
        sys.exit(1)
    print(f"✓ every token meets WCAG AA ({AA}:1) in {len(themes)} themes")


if __name__ == "__main__":
    main()
