#!/usr/bin/env python3
"""Generates the Control's battery symbols.

Apple's battery, reproduced as SF Symbol templates: the small menu-bar body (19x10) and its
cap, from the exact control points `Sources/QotaFolioKit/StatusItem/AppleBattery.swift` lifted
out of ControlCenter's own assets — so the symbol in a Control slot is the same battery the
strip draws on the bar. One symbol per five points of the week still held (`qf.battery.0` …
`qf.battery.100`), plus `qf.battery.spent` (Apple's red hairline, here as ink) and
`qf.battery.empty` (the outline alone).

Each template carries the three interpolation sources (Ultralight-S, Regular-S, Black-S) with
identical path counts, so the system generates every other weight and scale. Run it after
changing anything here:

    python3 Tools/make-battery-symbols.py
"""

import json
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Sources", "QotaFolioWidgets", "Assets.xcassets")

# ── The geometry, in the battery's own 19x10 space (origin bottom-left, y up) ──────────────

W, H = 19.0, 10.0
CORNER = 3.589439          # the outline's corner radius, from the control points
CAP_W, CAP_H = 1.25, 3.75  # the small cap
FILL_INSET = 2.0           # wall (1) + gap (1): the fill box the strip uses
KAPPA = 0.5522847498

# Apple's small outline, verbatim (M/L/C commands over (x, y) tuples).
OUTLINE = [
    ("M", (3.589439, 10)),
    ("L", (15.41056, 10)),
    ("C", (16.65869, 10), (17.11129, 9.870044), (17.56758, 9.626014)),
    ("C", (18.02388, 9.381984), (18.38198, 9.02388), (18.62601, 8.567584)),
    ("C", (18.87004, 8.111288), (19, 7.658687), (19, 6.410561)),
    ("L", (19, 3.589439)),
    ("C", (19, 2.341313), (18.87004, 1.888712), (18.62601, 1.432416)),
    ("C", (18.38198, 0.9761197), (18.02388, 0.6180157), (17.56758, 0.3739858)),
    ("C", (17.11129, 0.1299559), (16.65869, 0), (15.41056, 0)),
    ("L", (3.589439, 0)),
    ("C", (2.341313, 0), (1.888712, 0.1299559), (1.432416, 0.3739858)),
    ("C", (0.9761197, 0.6180157), (0.6180157, 0.9761197), (0.3739858, 1.432416)),
    ("C", (0.1299559, 1.888712), (0, 2.341313), (0, 3.589439)),
    ("L", (0, 6.410561)),
    ("C", (0, 7.658687), (0.1299559, 8.111288), (0.3739858, 8.567584)),
    ("C", (0.6180157, 9.02388), (0.9761197, 9.381984), (1.432416, 9.626014)),
    ("C", (1.888712, 9.870044), (2.341313, 10), (3.589439, 10)),
    ("Z",),
]

# Apple's cap ("battery-cap"): flat left edge, superelliptic bulge right, scaled to the small
# body and anchored at x = W, centred on midY.
def cap_commands():
    sx = CAP_W / 1.5
    sy = CAP_H / 4.235294
    def p(px, py):
        return (W + px * sx, H / 2 + (py - 6) * sy)
    return [
        ("M", p(0, 8.117647)),
        ("L", p(0, 3.882353)),
        ("C", p(0.9089323, 4.241057), p(1.5, 5.075506), p(1.5, 6)),
        ("C", p(1.5, 6.924494), p(0.9089323, 7.758943), p(0, 8.117647)),
        ("Z",),
    ]

def rounded_rect(x, y, w, h, r, reversed_winding=False):
    """A rounded rectangle as bezier commands, y up. `reversed_winding` runs it the other way
    round, which is what cuts it OUT of an enclosing path under the nonzero fill rule — the
    rule the symbol pipeline actually applies, whatever the SVG's fill-rule attribute says."""
    r = max(0.0, min(r, w / 2, h / 2))
    k = KAPPA * r
    commands = [
        ("M", (x + r, y + h)),
        ("L", (x + w - r, y + h)),
        ("C", (x + w - r + k, y + h), (x + w, y + h - r + k), (x + w, y + h - r)),
        ("L", (x + w, y + r)),
        ("C", (x + w, y + r - k), (x + w - r + k, y), (x + w - r, y)),
        ("L", (x + r, y)),
        ("C", (x + r - k, y), (x, y + r - k), (x, y + r)),
        ("L", (x, y + h - r)),
        ("C", (x, y + h - r + k), (x + r - k, y + h), (x + r, y + h)),
        ("Z",),
    ]
    if not reversed_winding:
        return commands
    # Walk the same geometry backwards: last point becomes first, each curve's control points
    # swap. The rendered shape is identical; only the winding number flips.
    points = []
    for command in commands[:-1]:
        points.append(command[1:])
    reversed_commands = [("M", points[-1][-1])]
    previous_end = points[-1][-1]
    for segment in reversed(points):
        if len(segment) == 1:
            if segment[0] == previous_end:
                continue
            reversed_commands.append(("L", segment[0]))
            previous_end = segment[0]
        else:
            control1, control2, _ = segment
            # The segment started where the previous one ended; that start is the new end.
            start = points[points.index(segment) - 1][-1]
            reversed_commands.append(("C", control2, control1, start))
            previous_end = start
    reversed_commands.append(("Z",))
    return reversed_commands

def to_svg_path(command_lists, scale, ox, oy):
    """Joins command lists into one SVG path, flipping y (SVG y points down)."""
    def sx(x):
        return round(ox + x * scale, 3)
    def sy(y):
        return round(oy + (H - y) * scale, 3)
    parts = []
    for commands in command_lists:
        for command in commands:
            kind = command[0]
            points = command[1:]
            flat = " ".join(f"{sx(x)} {sy(y)}" for (x, y) in points)
            parts.append(kind if kind == "Z" else f"{kind} {flat}")
    return " ".join(parts)

def wall_ring(wall):
    """The body's wall as one region: the outline, with the inside cut out by winding."""
    inner = rounded_rect(wall, wall, W - 2 * wall, H - 2 * wall, CORNER - wall, reversed_winding=True)
    return [OUTLINE, inner]

def variant_paths(kind, level, wall):
    """The paths of one weight variant: the wall ring, the cap, and (per kind) the fill."""
    paths = []
    paths.append(("evenodd", wall_ring(wall)))
    paths.append(("nonzero", [cap_commands()]))
    if kind == "level":
        width = max(0.75, (W - 2 * FILL_INSET) * level / 100.0)
        box_h = H - 2 * FILL_INSET
        paths.append(("nonzero", [rounded_rect(FILL_INSET, FILL_INSET, width, box_h, min(1.0, width / 2))]))
    elif kind == "spent":
        box_h = H - 2 * FILL_INSET
        paths.append(("nonzero", [rounded_rect(FILL_INSET, FILL_INSET, 1.0, box_h, 0.5)]))
    return paths

# ── The template canvas: the standard export geometry, S row only ──────────────────────────

CANVAS_W, CANVAS_H = 3300, 2200
CAPLINE_S, BASELINE_S = 600.784, 720.121
# The validator requires the M and L rows' guides even when no variant sits on them. The cap
# heights follow the scale factors (S 0.783, M 1.0, L 1.29) from the S row's measured pair.
CAP_HEIGHT_M = (BASELINE_S - CAPLINE_S) / 0.783
BASELINE_M = 1556.0
CAPLINE_M = BASELINE_M - CAP_HEIGHT_M
BASELINE_L = 2000.0
CAPLINE_L = BASELINE_L - CAP_HEIGHT_M * 1.29
SCALE = 8.0                                # 19x10 -> 152x80 ink, ~2/3 of the S cap height
GLYPH_W = (W + CAP_W) * SCALE
TOP_Y = (CAPLINE_S + BASELINE_S) / 2 - (H * SCALE) / 2
VARIANTS = [("Ultralight-S", 0.55, 500), ("Regular-S", 1.0, 1500), ("Black-S", 1.75, 2500)]

def symbol_svg(kind, level):
    groups = []
    for name, wall, x in VARIANTS:
        pieces = []
        for rule, commands in variant_paths(kind, level, wall):
            d = to_svg_path(commands, SCALE, x, TOP_Y)
            pieces.append(f'   <path fill-rule="{rule}" clip-rule="{rule}" d="{d}"/>')
        groups.append(f'  <g id="{name}">\n' + "\n".join(pieces) + "\n  </g>")
    guide_lines = [
        f'  <line id="{name}" x1="0" y1="{round(y, 3)}" x2="{CANVAS_W}" y2="{round(y, 3)}" '
        'style="fill:none;stroke:#27AAE1;stroke-width:0.5"/>'
        for name, y in (
            ("Capline-S", CAPLINE_S), ("Baseline-S", BASELINE_S),
            ("Capline-M", CAPLINE_M), ("Baseline-M", BASELINE_M),
            ("Capline-L", CAPLINE_L), ("Baseline-L", BASELINE_L),
        )
    ]
    # The margins actool requires: one vertical pair per interpolation source, at the ink's
    # own left and right edges, spanning capline to baseline.
    for name, _, x in VARIANTS:
        for side, edge in (("left", x), ("right", x + GLYPH_W)):
            guide_lines.append(
                f'  <line id="{side}-margin-{name}" x1="{round(edge, 3)}" y1="{CAPLINE_S}" '
                f'x2="{round(edge, 3)}" y2="{BASELINE_S}" '
                'style="fill:none;stroke:#00AEEF;stroke-width:0.5"/>'
            )
    guides = "\n".join(guide_lines)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg width="{CANVAS_W}" height="{CANVAS_H}" viewBox="0 0 {CANVAS_W} {CANVAS_H}" xmlns="http://www.w3.org/2000/svg" version="1.1">
 <g id="Notes">
  <text id="template-version" x="20" y="40" font-family="sans-serif" font-size="13">Template v.4.0</text>
  <text x="20" y="60" font-family="sans-serif" font-size="13">Generated by Tools/make-battery-symbols.py — do not edit by hand.</text>
 </g>
 <g id="Guides">
{guides}
 </g>
 <g id="Symbols">
{chr(10).join(groups)}
 </g>
</svg>
"""

def write_symbolset(name, kind, level=0):
    directory = os.path.join(CATALOG, f"{name}.symbolset")
    shutil.rmtree(directory, ignore_errors=True)
    os.makedirs(directory)
    with open(os.path.join(directory, f"{name}.svg"), "w") as handle:
        handle.write(symbol_svg(kind, level))
    with open(os.path.join(directory, "Contents.json"), "w") as handle:
        json.dump(
            {
                "info": {"author": "xcode", "version": 1},
                "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}],
            },
            handle,
            indent=2,
            sort_keys=True,
        )

def main():
    names = []
    for level in range(0, 101, 5):
        write_symbolset(f"qf.battery.{level}", "level", level)
        names.append(f"qf.battery.{level}")
    write_symbolset("qf.battery.spent", "spent")
    write_symbolset("qf.battery.empty", "empty")
    names += ["qf.battery.spent", "qf.battery.empty"]
    print(f"wrote {len(names)} symbol sets into {CATALOG}")

if __name__ == "__main__":
    main()
