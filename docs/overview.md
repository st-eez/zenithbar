# Zenith design overview

Zenith is a macOS status bar to replace SketchyBar on Steve's Macs, drawn along the top of
each display, fed by Kosmos's state and by macOS's own events. It takes from SketchyBar what
works, from Noctalia its bar shapes, and from Omarchy's shell its behaviour, and where
SketchyBar's way costs more it does what costs less. SketchyBar configs are not translated:
Zenith keeps SketchyBar's names for things where they fit, and nothing of its script protocol.

## 1. What the others do

- **SketchyBar 2.24** (C, source read at 5f358ec): one SkyLight window per bar per display and
  one per item per display, each drawn with CoreGraphics into a bitmap that becomes a layer's
  contents. A change lays out every item and redraws each changed item whole; an animation
  frame redraws the animated items. Scripts run as `env`, `sh`, then the script, on each
  update, and `update_freq` counts ticks of a 1 Hz timer that never stops. Its bar joins every
  Space through a private Space of its own at absolute level 0, which costs nothing per Space
  change. On macOS 27 two of its window choices fail: a click on an empty part of the bar
  raises the bar's window over its items' windows at the same level, blanking the bar
  (FelixKratz/SketchyBar#850), and alias items find nothing, since MenuBarAgent hosts every
  app's status item in one window at layer 24 (#849).
- **Noctalia 5.2** (native C++, EGL): one surface per bar, its outline drawn by a rounded
  rectangle shader whose corners are each convex or concave with their own radius. Concave
  corners where the bar meets the screen edge, with `margin_ends`, make a tab hanging from
  the edge; panels open out of the bar with concave corners where they meet it, overlapping
  it by `panel_overlap` so no seam shows. Capsules style widgets alone or in groups, a group
  can fold to its first widget until hovered, and the bar can hide until the pointer reaches
  its edge or show only on an empty workspace. Docs: https://docs.noctalia.dev/noctalia/bar/.
- **Omarchy 4** (its own Quickshell shell, from 2026-08-14, after Waybar): one process holds
  the bar and its panels, which take their data from native bindings and IPC pushes, apply a
  theme over IPC without a restart, and hide the bar by moving it off screen, about 20 ms
  against about 150 ms to rebuild it. The clock is pinned to the center while the widgets
  around it come and go, and indicators show only while their mode is on.

## 2. What the probes measured

On Steve's M3 Pro, macOS 27.0, 2026-10-06, with SketchyBar stopped for Zenith's runs.

- **An update's cost** (`zenith-probe cost`): one item's text changing width and the 12 items
  after it moving, in one AppKit panel with a layer per item, 300 updates at 20 a second.
  | | Bar process per update | WindowServer per update | Footprint |
  |---|---|---|---|
  | CATextLayer items | 0.80 ms | 1.5 to 2.3 ms | 10.6 MB |
  | CoreText drawn into each item's contents | 0.78 to 0.89 ms | 2.8 ms | 12.1 MB |
  | SketchyBar, the same updates to an item through its CLI | 3.55 ms | 18.4 ms | 43.7 MB |

  Of the panel's main thread time, about 0.69 ms an update, the Core Animation commit took
  0.43 to 0.47 ms, setting the text 0.18 ms (CATextLayer) or 0.32 ms (CoreText), and the
  layout code 0.02 to 0.03 ms. The Swift of the bar's own code is about 4% of its time, so a
  bar in C or Rust would make the same framework calls at the same cost. WindowServer idled
  at about 200 ms a second during the runs, so its figures carry that noise. SketchyBar's
  figures include parsing each CLI message, and its CLI held the rate to 10 a second.
- **Blur inside a bar's outline** (`zenith-probe shape`): a tab with 32 pt flares and 20 pt
  bottom corners over stripes. NSVisualEffectView with the outline as its `maskImage`, the
  same view with the outline as its layer's mask, and a translucent fill with
  `SLSSetWindowBackgroundBlurRadius` each blurred the stripes fully inside the outline,
  flares included, and left them sharp in the carved flares and corners. Noctalia's shapes
  need nothing private.

## 3. Open questions

Each names the probe that settles it.

- Whether a panel joined to every Space stays on screen through Kosmos's workspace switches
  and slides, Mission Control, a native fullscreen Space and the menu bar's reveal, and where
  MenuBarAgent's window sits then (`zenith-probe watch`, which Steve drives).
- Whether clicks on a bar's clear areas reach the window behind it, and whether a click
  activates Zenith or reorders its windows (`zenith-probe clicks`, which moves the pointer).
- Why WindowServer spends two to four times the bar's own time on an update, and whether
  updating only the changed item, as right-aligned items that do not move, cuts it.
