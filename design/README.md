# design/ — the artwork, and the scripts that cut it up

Two files here are the app's visual source of truth. Everything else is either a script or
the design history.

| file | what it is |
|---|---|
| `launcher.png` | the launcher mark: a hand and its reflection either side of a thin glass line. 1024 px, rounded tile on white — `make_assets.py` flattens that field away. |
| `splash-hand.png` | the splash hand, a flat black silhouette on white. Chosen over cropping the hand out of a full scene because a silhouette keys to alpha perfectly — and the animation needs the hand, the glass line, the ripples and the reflection to move independently. |
| `make_assets.py` | generates every icon in `app/src/main/res/` from those two, plus the splash bitmap and the notification silhouette. `--check` reports stale resources without writing. |
| `splash_preview.py` | renders the splash loop as a filmstrip on the desktop, reading its constants out of `SplashChoreography.java` so it cannot drift from the app. |
| `options/` | the design history: three contact sheets of every option considered (each shown at full size and at a real 72 px and 48 px), plus the finalists and the review renders. |

## How the mark was chosen

The brief was an icon for "one phone becomes the screen, the other becomes the hands", in the
app's own palette (`#00695C` teal, `#A7F2DF` mint). Four directions were generated and put in
front of the user at real icon sizes rather than at 1024 px, because an icon is only ever seen
small: **ghost hand + tap ripple**, **hand + its mirror reflection**, **two phones + link**, and
**tap pointer**. The ghost-hand and mirror families went through three rounds each — including
one round that tried to improve the mirror mark and made it worse, which is recorded here
because the sheet is a record, not a highlight reel.

`launcher.png` is the mirror mark: the solid half is the phone in your hand, the translucent
half is the screen it appears on. `options/variant-d1-finger-press.png` is the splash's original
scene — a fingertip pressing the glass — and `splash-hand.png` is the hand from it, redrawn
alone so it can be animated.

## Regenerating

```bash
python3 design/make_assets.py          # rewrite every icon/splash resource
python3 design/make_assets.py --check  # fail if they are out of date
python3 design/splash_preview.py       # look at the splash loop without a device
```

`make_assets.py` needs Pillow (`python3 -m pip install --break-system-packages pillow`); the
build itself does not, so a checkout without it still builds — it just cannot regenerate icons.
