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
  after it moving, 300 updates at 20 a second, in seconds alternating with idle ones, since
  WindowServer's own load drifted by a third between 15 s stretches. Ranges span the runs.
  | | Bar process per update | WindowServer per update | Footprint |
  |---|---|---|---|
  | One panel, a CATextLayer per item | 0.69 to 0.80 ms | 1.0 to 2.8 ms | 10.6 to 10.9 MB |
  | One panel, CoreText drawn into each item's contents | 0.78 to 0.89 ms | 2.8 ms | 12.1 MB |
  | A panel per item, as SketchyBar draws them | 5.5 to 7.1 ms | 7.0 to 8.2 ms | |
  | SketchyBar, the same updates to an item through its CLI | 3.4 to 3.6 ms | 11.3 to 18.4 ms | 43.5 to 43.7 MB |

  Of the one panel's main thread time, about 0.6 to 0.7 ms an update, the Core Animation
  commit took 0.4 to 0.47 ms, setting the text 0.15 to 0.18 ms (CATextLayer) or 0.32 ms
  (CoreText), and the layout code 0.02 to 0.03 ms. The Swift of the bar's own code is about
  4% of its time, so a bar in C or Rust would make the same framework calls at the same cost.
  A panel per item spent 1.1 ms setting the panels' frames and twice as long committing.
  SketchyBar's figures include parsing each CLI message, and its CLI held the rate to 10 a
  second. Changing the last item, so no other moves, did not read lower than changing the
  second: WindowServer's noise, about ±1 ms an update read through `ps`, hides the
  difference.
- **Blur inside a bar's outline** (`zenith-probe shape`): a tab with 32 pt flares and 20 pt
  bottom corners over stripes. NSVisualEffectView with the outline as its `maskImage`, the
  same view with the outline as its layer's mask, and a translucent fill with
  `SLSSetWindowBackgroundBlurRadius` each blurred the stripes fully inside the outline,
  flares included, and left them sharp in the carved flares and corners. Noctalia's shapes
  need nothing private.
- **Clicks** (`zenith-probe clicks`): on a nonactivating panel at the status level, clicks on
  an item and on the fill reached the bar, and clicks in the carved flare and corner, where
  the window is clear, reached the probe's window behind it. No click activated the probe or
  made its panel key. A click on the window behind raised it over the bar, both at one level
  in one app, the reordering behind SketchyBar's blank bar (#850), so a bar keeps one window
  per display and gives its popups a level of their own.
- **Spaces** (`zenith-probe watch`, Steve driving, three displays): a panel at
  kCGBackstopMenuLevel, -20, with `.canJoinAllSpaces` and `.stationary`, stayed on screen
  through Kosmos workspace switches on two displays, Mission Control, the lock screen and back,
  and native fullscreen. In fullscreen it joined the fullscreen Space without
  `.fullScreenAuxiliary`, and the app covered it, as SketchyBar's bar hides there by default.
  The revealed menu bar slid over it. The window list showed MenuBarAgent's windows off screen
  even while the menu bar showed, so a bar learns of the reveal some other way, if it needs
  to. AppKit's Space behaviours do what SketchyBar's private Space does.

## 3. Open questions

- What WindowServer spends on an update of one panel, and whether keeping items from moving
  cuts it, which needs a quieter WindowServer than Steve's three displays in use give, or a
  reading finer than `ps`.
