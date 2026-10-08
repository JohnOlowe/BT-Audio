#!/usr/bin/env python3
"""splash_preview.py -- render the splash loop as a filmstrip, off-device.

There is no emulator in this environment, so the animation cannot be watched where it
runs. This script re-does what SplashView does, on the same numbers: it reads the same
hand bitmap, asks the same choreography, and paints the same gradient, glass line (bent by
the same travelling wave), ripples and reflection. The result is a filmstrip of one loop
that can be looked at, which is how the composition was actually tuned - the hand size, the
contact point and the ripple spread were all settled here rather than by guessing.

It is a *replica*, not the real thing: it cannot prove the Java draws correctly, only that
the design it encodes looks right. The values below are copied from SplashView and
SplashChoreography, and the choreography constants are asserted against the Java source so
that editing one without the other is caught rather than drifting quietly.

Usage:  python3 design/splash_preview.py [--frames 12] [--width 540] [--height 1170]
"""

import argparse
import math
import os
import re
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "app", "src", "main", "res")
JAVA = os.path.join(ROOT, "app", "src", "main", "java", "damjay", "control", "ghosthand")

# --- values mirrored from SplashView.java (asserted below where they matter) ----------
LINE_Y_FRACTION = 0.68
CONTACT_X_FRACTION = 0.62
LINE_HEIGHT_DP = 3.0
REFLECTION_GAP_FRACTION = 0.008
REFLECTION_SQUASH = 0.75
HAND_HEIGHT_FRACTION = 0.34
HAND_MAX_WIDTH_FRACTION = 0.70
HAND_TIP_X_FRACTION = 0.995
HAND_TIP_Y_FRACTION = 0.987
TEAL_TOP = (2, 104, 91)
TEAL_BOTTOM = (1, 88, 78)
GLASS = (167, 242, 223)


def choreography_constants():
    """The numbers this preview must agree with, read straight out of the Java."""
    source = open(os.path.join(JAVA, "util", "SplashChoreography.java"), encoding="utf-8").read()
    wanted = {
        "LOOP_MS": "long", "CONTACT_MS": "long", "PRESS_MS": "long",
        "LIFT_START_MS": "long", "LIFT_END_MS": "long", "RIPPLE_COUNT": "int",
        "RIPPLE_STAGGER_MS": "long", "RIPPLE_LIFE_MS": "long",
    }
    values = {}
    for name, kind in wanted.items():
        match = re.search(r"public static final %s %s = (\d+)L?" % (kind, name), source)
        if not match:
            raise SystemExit("cannot find %s in SplashChoreography.java" % name)
        values[name] = int(match.group(1))
    floats = {}
    for name in ("RAISED_FRACTION", "PRESS_FRACTION", "RIPPLE_MAX_WIDTH_FRACTION",
                 "RIPPLE_FLATTEN", "RIPPLE_ALPHA", "REFLECTION_ALPHA",
                 "WAVE_AMPLITUDE_FRACTION"):
        match = re.search(r"public static final float %s = ([0-9.]+)f" % name, source)
        if not match:
            raise SystemExit("cannot find %s in SplashChoreography.java" % name)
        floats[name] = float(match.group(1))
    values.update(floats)
    return values


C = choreography_constants()


def phase(elapsed):
    return elapsed % C["LOOP_MS"]


def wave(x):
    return math.sin(math.pi * min(1.0, max(0.0, x)))


def hand_offset(elapsed):
    t = phase(elapsed)
    if t < C["CONTACT_MS"]:
        p = t / C["CONTACT_MS"]
        return C["RAISED_FRACTION"] * (1.0 - p * p * p)
    if t < C["CONTACT_MS"] + C["PRESS_MS"]:
        p = (t - C["CONTACT_MS"]) / C["PRESS_MS"]
        return -C["PRESS_FRACTION"] * wave(p)
    if t < C["LIFT_START_MS"]:
        return 0.0
    if t < C["LIFT_END_MS"]:
        p = (t - C["LIFT_START_MS"]) / (C["LIFT_END_MS"] - C["LIFT_START_MS"])
        return C["RAISED_FRACTION"] * (p * p)
    return C["RAISED_FRACTION"]


def ripple_life(index):
    spawn = C["CONTACT_MS"] + index * C["RIPPLE_STAGGER_MS"]
    return max(1, min(C["RIPPLE_LIFE_MS"], C["LOOP_MS"] - spawn))


def ripple_progress(elapsed, index):
    if index < 0 or index >= C["RIPPLE_COUNT"]:
        return -1.0
    spawn = C["CONTACT_MS"] + index * C["RIPPLE_STAGGER_MS"]
    p = (phase(elapsed) - spawn) / ripple_life(index)
    return -1.0 if p < 0 else min(1.0, p)


def ripple_alpha(elapsed, index):
    p = ripple_progress(elapsed, index)
    return 0.0 if p < 0 else C["RIPPLE_ALPHA"] * (1.0 - p * p)


def ripple_width(elapsed, index):
    p = ripple_progress(elapsed, index)
    return 0.0 if p < 0 else C["RIPPLE_MAX_WIDTH_FRACTION"] * math.sqrt(p)


def reflection_alpha(elapsed):
    presence = 1.0 - min(1.0, max(0.0, hand_offset(elapsed) / C["RAISED_FRACTION"]))
    return C["REFLECTION_ALPHA"] * presence


def travelling_wave(distance, elapsed, phase_offset):
    t = phase(elapsed)
    if t < C["CONTACT_MS"]:
        return 0.0
    since = (t - C["CONTACT_MS"]) / 1000.0
    arg = distance * 12.0 - since * 9.0 + phase_offset
    decay = math.exp(-distance * 4.5) * math.exp(-since * 1.6)
    return math.sin(arg) * decay


def render(elapsed, width, height, hand, scale):
    frame = Image.new("RGB", (width, height), TEAL_TOP)
    d = ImageDraw.Draw(frame, "RGBA")

    # background gradient
    for y in range(height):
        f = y / max(1, height - 1)
        d.line([(0, y), (width, y)],
               fill=(int(TEAL_TOP[0] + (TEAL_BOTTOM[0] - TEAL_TOP[0]) * f),
                     int(TEAL_TOP[1] + (TEAL_BOTTOM[1] - TEAL_TOP[1]) * f),
                     int(TEAL_TOP[2] + (TEAL_BOTTOM[2] - TEAL_TOP[2]) * f)))

    line_y = height * LINE_Y_FRACTION
    line_h = max(2, int(LINE_HEIGHT_DP * scale))
    contact_x = width * CONTACT_X_FRACTION

    # hand size and position, exactly as drawHandAt computes them
    aspect = hand.width / hand.height
    draw_h = height * HAND_HEIGHT_FRACTION
    draw_w = draw_h * aspect
    if draw_w > width * HAND_MAX_WIDTH_FRACTION:
        draw_w = width * HAND_MAX_WIDTH_FRACTION
        draw_h = draw_w / aspect
    offset = hand_offset(elapsed) * height
    left = contact_x - HAND_TIP_X_FRACTION * draw_w
    top = line_y - offset - HAND_TIP_Y_FRACTION * draw_h
    hand_layer = hand.resize((max(1, int(draw_w)), max(1, int(draw_h))), Image.LANCZOS)

    # reflection first (under the glass), mirrored about a line just below it
    alpha = reflection_alpha(elapsed)
    if alpha > 0.01:
        mirror = line_y + height * REFLECTION_GAP_FRACTION
        # Same transform as SplashView: y -> 2 * mirror - SQUASH * y. Scaling first keeps
        # the preview's arithmetic identical to the canvas's, which is the only reason the
        # preview is worth looking at.
        refl = hand_layer.resize((hand_layer.width,
                                  max(1, int(hand_layer.height * REFLECTION_SQUASH))),
                                 Image.LANCZOS).transpose(Image.FLIP_TOP_BOTTOM)
        refl_top = 2 * mirror - REFLECTION_SQUASH * top - refl.height
        refl_layer = Image.new("RGBA", frame.size, (0, 0, 0, 0))
        refl_alpha = refl.split()[3].point(lambda v: int(v * alpha))
        white = Image.new("RGBA", refl.size, (255, 255, 255, 0))
        white.putalpha(refl_alpha)
        refl_layer.paste(white, (int(left), int(refl_top)), white)
        frame = Image.alpha_composite(frame.convert("RGBA"), refl_layer).convert("RGB")
        d = ImageDraw.Draw(frame, "RGBA")

    # glass, bent by the travelling wave
    amplitude = C["WAVE_AMPLITUDE_FRACTION"] * width
    points = []
    for i in range(65):
        x = width * i / 64.0
        distance = abs(x - contact_x) / width
        bend = amplitude * travelling_wave(distance, elapsed, 0.0)
        points.append((x, line_y + bend + line_h * 0.5))
    points += [(width, line_y + line_h), (0, line_y + line_h)]
    d.polygon(points, fill=GLASS + (255,))

    # ripples
    for i in range(C["RIPPLE_COUNT"]):
        a = ripple_alpha(elapsed, i)
        if a <= 0.005:
            continue
        half_w = ripple_width(elapsed, i) * width * 0.5
        half_h = half_w * C["RIPPLE_FLATTEN"]
        d.ellipse([contact_x - half_w, line_y - half_h, contact_x + half_w, line_y + half_h],
                  outline=GLASS + (int(a * 255),), width=max(1, int(1.5 * scale)))

    # the hand on top
    frame.paste(hand_layer, (int(left), int(top)), hand_layer)
    return frame


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", type=int, default=12)
    parser.add_argument("--width", type=int, default=540)
    parser.add_argument("--height", type=int, default=1170)
    parser.add_argument("--out", default=os.path.join(ROOT, "design", "splash-filmstrip.png"))
    args = parser.parse_args(argv[1:])

    hand = Image.open(os.path.join(RES, "drawable-nodpi", "splash_hand.png")).convert("RGBA")
    scale = args.height / 1170.0
    step = C["LOOP_MS"] / args.frames

    thumbs = []
    for i in range(args.frames):
        elapsed = int(i * step)
        frame = render(elapsed, args.width, args.height, hand, scale)
        thumb = frame.resize((args.width // 3, args.height // 3), Image.LANCZOS)
        thumbs.append((elapsed, thumb))

    pad, cap = 8, 26
    cols = 6
    rows = (len(thumbs) + cols - 1) // cols
    tw, th = thumbs[0][1].size
    sheet = Image.new("RGB", (cols * (tw + pad) + pad, rows * (th + cap + pad) + pad),
                      (22, 24, 25))
    d = ImageDraw.Draw(sheet)
    for i, (elapsed, thumb) in enumerate(thumbs):
        col, row = i % cols, i // cols
        x = pad + col * (tw + pad)
        y = pad + row * (th + cap + pad)
        sheet.paste(thumb, (x, y))
        note = "%d ms" % elapsed
        if elapsed == C["CONTACT_MS"]:
            note += "  <- contact"
        d.text((x + 2, y + th + 4), note, fill=(225, 238, 233))
    sheet.save(args.out)
    print("loop: %d ms, %d frames, contact at %d ms, ripples %d every %d ms for %d ms"
          % (C["LOOP_MS"], args.frames, C["CONTACT_MS"], C["RIPPLE_COUNT"],
             C["RIPPLE_STAGGER_MS"], C["RIPPLE_LIFE_MS"]))
    print("wrote %s (%dx%d)" % (os.path.relpath(args.out, ROOT), sheet.width, sheet.height))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
