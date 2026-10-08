#!/usr/bin/env python3
"""make_assets.py -- turn the two chosen designs into everything the app ships.

Inputs (committed in design/, produced by the design pass):

    variant-b1-half-hand-mirror.png   the launcher icon: solid half hand + its
                                      mirrored translucent half, split by a line
    variant-d1-finger-press.png       the splash mark: a hand whose fingertip
                                      presses a glass line

Outputs, all written into app/src/main/res/:

    mipmap-*/ic_launcher.webp               legacy square icon (API < 26), 48..192 px
    mipmap-*/ic_launcher_round.webp         legacy round icon, circle-masked
    mipmap-*/ic_launcher_foreground.png     adaptive foreground, 108 dp canvas with the
                                            art inside the inner 72 dp safe zone
    mipmap-anydpi-v26/ic_launcher(_round).xml  adaptive icon XML (generated, see below)
    drawable-nodpi/splash_hand.png          the splash hand, cropped and alpha-only
    drawable/ic_stat_mirror.xml             notification silhouette, traced from B1

Everything is generated from the PNGs, so the mark can change by replacing one file
and re-running this script. The one thing it does not do is invent art.

Usage:  python3 design/make_assets.py [--check]

--check re-generates into temporary files and reports whether the committed
resources are up to date, without writing anything.
"""

import argparse
import os
import shutil
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DESIGN = os.path.join(ROOT, "design")
RES = os.path.join(ROOT, "app", "src", "main", "res")

ICON_SRC = os.path.join(DESIGN, "launcher.png")
# The splash hand is its own drawing, not a crop of the D1 design: in D1 the hand runs
# off the edge of the image and overlaps the ripples and the reflection, so there is no
# alpha mask that separates it. This one is a flat black silhouette on white, which keys
# out perfectly (alpha = 255 - luminance) and leaves the hand, the glass line, the ripples
# and the reflection to be drawn independently - which is the whole point of animating it.
SPLASH_SRC = os.path.join(DESIGN, "splash-hand.png")

# Adaptive icons: 108 dp canvas, 72 dp "safe zone" the launcher will show at most.
ADAPTIVE_DP = 108
SAFE_ZONE_DP = 72
# Legacy launcher icons are 48 dp.
LEGACY_DP = 48
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

BG = (0, 105, 92)          # #00695C, the app's brand teal (values/colors.xml accent)
SPLASH_TEAL_TOP = (2, 104, 91)
SPLASH_TEAL_BOTTOM = (1, 88, 78)


def load_rgb(path):
    return Image.open(path).convert("RGB")


def flatten_tile(im, band=6):
    """Turn a rounded-square icon tile on a white field into a full-bleed square.

    Two problems to solve at once, both of them consequences of the tile being drawn on a
    white field:

    * A naive "bounding box of everything that is not the background" finds the four white
      corner wedges and calls *those* the art. (That is exactly what the first version of
      this script did; the legacy icons came out with white triangles in the corners.)
    * The tile's own edge is antialiased against that white field, so there is a thin
      lighter-teal ring just inside the tile boundary. Invisible on a teal icon - the ring
      is teal-ish - but it becomes a visible outline the moment the alpha channel is used
      as a shape, which is exactly what the notification silhouette does.

    So: flood-fill the outside from the four corners with a sentinel, dilate that region by
    `band` pixels to swallow the antialiased ring, and paint the result in the tile's own
    colour. The mark loses `band` pixels where it meets the tile edge (the glass line and
    the wrists run off the edge anyway) and everything downstream - keying, silhouettes,
    adaptive foreground - gets a clean edge to work from.
    """
    out = im.copy().convert("RGB")
    w, h = out.size
    px = out.load()
    # Sample just inside the tile rather than assuming a palette: the icon is generated,
    # and its teal drifts by a unit or two between renders.
    tile = px[min(60, w - 1), min(60, h - 1)]
    if sum(tile) > 600:          # sampled the white field: fall back to the brand colour
        tile = BG

    sentinel = (255, 0, 255)
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        ImageDraw.floodfill(out, seed, sentinel, thresh=30)

    exterior = Image.new("L", (w, h), 0)
    epx = exterior.load()
    opx = out.load()
    for y in range(h):
        for x in range(w):
            if opx[x, y] == sentinel:
                epx[x, y] = 255
    if band:
        exterior = exterior.filter(ImageFilter.MaxFilter(band * 2 + 1))

    epx = exterior.load()
    for y in range(h):
        for x in range(w):
            if epx[x, y]:
                opx[x, y] = tile
    return out


def keyed_out_mark(im, tolerance=110):
    """The mark alone, with the tile colour turned into transparency.

    A chroma key rather than a crop: cropping a rectangular piece out of a teal tile and
    pasting it onto a differently-tuned teal leaves a faint seam around the mark, and on a
    launcher that seam is exactly where a shadow or a highlight lands. Here every pixel's
    alpha is its distance from the background colour, ramped over `tolerance`, so the
    antialiased edge of the mark keeps a proper soft edge instead of a hard cut.
    """
    rgb = im.convert("RGB")
    px = rgb.load()
    w, h = rgb.size
    key = px[2, 2]
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    opx = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            distance = abs(r - key[0]) + abs(g - key[1]) + abs(b - key[2])
            if distance <= 8:
                continue
            alpha = 255 if distance >= tolerance else int(255 * (distance - 8) / (tolerance - 8))
            opx[x, y] = (r, g, b, alpha)
    return out


def art_bounds(im, bg_tolerance=40):
    """Bounding box of everything that is not the background colour.

    The generated designs are a flat teal background with the mark on top, so a
    per-pixel distance from the corner colour finds the art without any guessing
    about colours or shapes.
    """
    bg = im.getpixel((2, 2))
    px = im.load()
    w, h = im.size
    left, top, right, bottom = w, h, 0, 0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            if (abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2])) > bg_tolerance:
                left, right = min(left, x), max(right, x)
                top, bottom = min(top, y), max(bottom, y)
    return left, top, right + 1, bottom + 1


def square_icon(im, size):
    """The full-bleed tile at `size` x `size`.

    Because `flatten_tile` has already made the source square edge to edge, this is a
    straight resize: the mark keeps the exact composition and the exact margin the design
    pass settled on, instead of the generator re-centring it and quietly changing the
    proportions.
    """
    return im.resize((size, size), Image.LANCZOS)


def round_icon(im, size):
    """Same, masked to a circle - what a pre-26 launcher shows for round icons."""
    square = square_icon(im, size)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(square, (0, 0), mask)
    return out


def adaptive_foreground(im, size):
    """The mark alone, transparent, sized for the 72 dp safe zone of a 108 dp canvas.

    The launcher crops an adaptive icon to whatever shape the device uses and may scale the
    foreground layer up by 1.5x, so only the middle 72 dp is guaranteed to survive. The mark
    is cut out of the tile by chroma key, cropped to its own bounds and scaled to sit
    comfortably inside that safe circle.
    """
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    art = keyed_out_mark(im)
    box = art.getbbox()
    art = art.crop(box)
    # 0.8 of the safe zone: enough that the mark is bold, with room for the launcher's own
    # scaling and mask. The glass line is the tallest part of the mark, so height decides.
    inner = int(size * SAFE_ZONE_DP / ADAPTIVE_DP * 0.80)
    scale = min(inner / art.width, inner / art.height)
    art = art.resize((max(1, int(art.width * scale)), max(1, int(art.height * scale))),
                     Image.LANCZOS)
    canvas.paste(art, ((size - art.width) // 2, (size - art.height) // 2), art)
    return canvas


def notification_icon(im, size):
    """The mark as a white silhouette on transparency, for the status bar.

    Android tints a notification icon and discards its colours, so what survives is the
    alpha channel. That is exactly why this is derived from the mark rather than drawn by
    hand: the alpha of the launcher art *is* the design, and the translucent reflection
    half comes through as a lighter grey, which is the mark's whole idea. Alpha is pushed
    up because at 24 dp anything under about 60% disappears into the status bar.
    """
    art = keyed_out_mark(im)
    art = art.crop(art.getbbox())
    art = art.resize((size, size), Image.LANCZOS)
    px = art.load()
    out = Image.new("RGBA", art.size, (255, 255, 255, 0))
    opx = out.load()
    for y in range(art.size[1]):
        for x in range(art.size[0]):
            alpha = px[x, y][3]
            opx[x, y] = (255, 255, 255, min(255, int(alpha * 1.6)))
    return out


def splash_hand(im):
    """The hand as white-on-transparent, cropped to its own bounds.

    The source is a black silhouette on white, so alpha is simply 255 minus luminance and
    no colour keying is involved: black becomes fully opaque, white fully transparent, and
    the antialiased edge in between keeps its softness. A low threshold removes the faint
    off-white the image generator leaves in the background, which would otherwise survive
    as a rectangular haze.

    Returns the hand and the position of its fingertip inside the crop, as fractions of
    the crop's width and height. The fingertip is the extremal opaque pixel along the
    down-right diagonal - the drawing has the finger reaching down and to the right - and
    SplashView anchors the hand by exactly that point so it meets the glass line.
    """
    grey = im.convert("L")
    alpha = grey.point(lambda value: 255 - value)
    strong = alpha.point(lambda value: 255 if value > 40 else 0)
    box = strong.getbbox()
    if box is None:
        raise SystemExit("splash hand source has no dark pixels: %s" % SPLASH_SRC)
    alpha = alpha.crop(box)

    hand = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
    hand.putalpha(alpha)

    # Where the fingertip is, in the units SplashView works in.
    mask = alpha.load()
    best, best_value = (0, 0), -1
    for y in range(alpha.size[1]):
        for x in range(alpha.size[0]):
            if mask[x, y] > 128 and (x + y) > best_value:
                best_value, best = x + y, (x, y)
    tip_x = best[0] / float(alpha.size[0] - 1)
    tip_y = best[1] / float(alpha.size[1] - 1)
    if not (tip_x > 0.8 and tip_y > 0.8):
        raise SystemExit("the splash hand's fingertip should be at the bottom right of the "
                         "crop (it is at %.3f, %.3f) - the drawing changed, so the anchor "
                         "in SplashView needs revisiting" % (tip_x, tip_y))
    return hand, box, tip_x, tip_y


ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<!--
  Adaptive icon (API 26+). Generated by design/make_assets.py.

  The background is a flat colour and the foreground is the launcher mark on a
  transparent 108 dp canvas. The launcher applies its own mask - circle, squircle,
  rounded square - and may scale the foreground up by 1.5x, which is why the art sits
  inside the central 72 dp and nothing important is near the edge.
-->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""


def write(path, data, check, drift):
    """Write data to path, or compare when --check is on. Tracks drift in `drift`."""
    if check:
        if not os.path.exists(path) or open(path, "rb").read() != data:
            drift.append(os.path.relpath(path, ROOT))
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)


def save_image(image, path, check, drift, **kwargs):
    """Render an image into bytes, then hand it to write() so --check works the same."""
    buffer = tempfile.SpooledTemporaryFile()
    image.save(buffer, **kwargs)
    buffer.seek(0)
    write(path, buffer.read(), check, drift)
    buffer.close()


def say(message):
    print("    %s" % message)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the committed resources match the designs")
    args = parser.parse_args(argv[1:])

    for src in (ICON_SRC, SPLASH_SRC):
        if not os.path.exists(src):
            print("missing design source: %s" % src, file=sys.stderr)
            return 2

    icon = flatten_tile(load_rgb(ICON_SRC))
    splash = load_rgb(SPLASH_SRC)
    drift = []

    say("launcher icon from %s" % os.path.basename(ICON_SRC))
    for name, scale in DENSITIES.items():
        legacy = int(LEGACY_DP * scale)
        adaptive = int(ADAPTIVE_DP * scale)
        save_image(square_icon(icon, legacy),
                   os.path.join(RES, "mipmap-%s" % name, "ic_launcher.webp"),
                   args.check, drift, format="WEBP", quality=92, method=6)
        save_image(round_icon(icon, legacy),
                   os.path.join(RES, "mipmap-%s" % name, "ic_launcher_round.webp"),
                   args.check, drift, format="WEBP", quality=92, method=6)
        save_image(adaptive_foreground(icon, adaptive),
                   os.path.join(RES, "mipmap-%s" % name, "ic_launcher_foreground.webp"),
                   args.check, drift, format="WEBP", quality=92, method=6)
        save_image(notification_icon(icon, max(24, int(24 * scale))),
                   os.path.join(RES, "drawable-%s" % name, "ic_stat_mirror.png"),
                   args.check, drift, format="PNG", optimize=True)
        say("%-8s legacy %3d px, adaptive foreground %3d px" % (name, legacy, adaptive))

    for xml in ("ic_launcher", "ic_launcher_round"):
        write(os.path.join(RES, "mipmap-anydpi-v26", "%s.xml" % xml),
              ADAPTIVE_XML.encode(), args.check, drift)

    colour = ('<?xml version="1.0" encoding="utf-8"?>\n'
              '<!-- Generated by design/make_assets.py - the adaptive icon background. -->\n'
              '<resources>\n'
              '    <color name="ic_launcher_background">#%02X%02X%02X</color>\n'
              '</resources>\n' % BG)
    write(os.path.join(RES, "values", "ic_launcher_background.xml"),
          colour.encode(), args.check, drift)
    say("adaptive icon background #%02X%02X%02X" % BG)

    say("splash hand from %s" % os.path.basename(SPLASH_SRC))
    hand, box, tip_x, tip_y = splash_hand(splash)
    # The hand is drawn at up to ~40% of a tall screen's height; 512 px covers the
    # largest phone here with room for the press squish. PNG because it is a soft-edged
    # alpha mask, where WebP's quantisation shows banding along the glow.
    hand = hand.resize((int(hand.width * 512 / hand.height), 512), Image.LANCZOS)
    save_image(hand, os.path.join(RES, "drawable-nodpi", "splash_hand.png"),
               args.check, drift, format="PNG", optimize=True)
    say("splash_hand.png %dx%d (cropped from %s), fingertip at (%.3f, %.3f) of the image"
        % (hand.width, hand.height, box, tip_x, tip_y))

    stale_vector = os.path.join(RES, "drawable", "ic_stat_mirror.xml")
    if os.path.exists(stale_vector):
        if args.check:
            drift.append(os.path.relpath(stale_vector, ROOT))
        else:
            os.remove(stale_vector)
    say("notification silhouettes ic_stat_mirror.png (mdpi..xxxhdpi)")

    # The Android Studio template shipped a vector foreground and a vector background;
    # the adaptive icon now points at the generated raster foreground and a colour, so
    # those two files are dead. Leaving dead resources in a resource table is how you end
    # up with two launcher icons and no idea which one is showing.
    for stale in (os.path.join(RES, "drawable", "ic_launcher_background.xml"),
                  os.path.join(RES, "drawable-v24", "ic_launcher_foreground.xml"),
                  os.path.join(RES, "drawable", "ic_stat_mirror.xml")):
        if os.path.exists(stale):
            if args.check:
                drift.append(os.path.relpath(stale, ROOT))
            else:
                os.remove(stale)
                say("removed the template vector %s" % os.path.relpath(stale, RES))

    if args.check:
        if drift:
            print("\nthese resources are out of date (run design/make_assets.py):")
            for path in drift:
                print("    %s" % path)
            return 1
        print("\neverything is up to date")
        return 0
    print("\ndone - rebuild to pick the new resources up")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
