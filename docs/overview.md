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
  app's status item in one window per display at layer 24 (#849); [tray.md](tray.md) covers
  what can replace them.
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
  to; WindowServer's own `Menubar` window came on screen as the menu bar slid in for a status
  item's menu ([tray.md](tray.md)). AppKit's Space behaviours do what SketchyBar's private Space does.

## 3. The bar

- **One process, `zenith`,** an agent app with no Dock icon. It draws Steve's SketchyBar
  items natively and starts no process to update them; SketchyBar's script protocol is not
  carried over. Plugins for custom items, as long running processes that push to Zenith,
  come later ([backlog.md](backlog.md)).
- **One panel per display, a layer per item** (`Bar`), from the measurements above: a
  nonactivating `NSPanel` at kCGBackstopMenuLevel, -20, joined to every Space, 25 pt tall
  along the display's top. Each item's text or image is drawn once into its layer's
  contents; a change redraws only the items that changed, in one Core Animation
  transaction, and moves the others only when a width changed. The view finds the item
  under a click or the pointer from the frames the last layout gave. A hovered item is held
  with its display and forgotten once that bar stops showing it, as when its display goes,
  since no exit event comes then; a panel on a display that goes closes.
- **Kosmos** (`KosmosLink`): Kosmos pushes its snapshot (Kosmos's docs/ipc.md) as JSON to
  the Mach port Zenith registers as `io.github.st-eez.zenith`, and Zenith reads only the
  newest of those waiting. At launch and after a wake Zenith asks for `state`, and a click
  on a workspace sends `workspace <name>`, each as one request on Kosmos's socket. Kosmos's
  snapshot names each display's CoreGraphics UUID, since Kosmos 638151c, and Zenith matches
  its screens by it; before, Zenith copied Kosmos's SketchyBar numbering, and the two
  counted active displays differently. Each workspace joins its display by its own
  `displayUUID`, as Kosmos's display numbers are no key: it gives 0 both when it manages no
  display and to a workspace on no listed display, and every display 1 when one is active.
  From a Kosmos without the field, Zenith joins by number.
- **Icons:** SF Symbols at 14 to 16 pt (the speaker, Wi-Fi, a plugin's `symbol`, as the
  agents' sparkles), an Ethernet port drawn in SF's 1.3 pt strokes ([network.md](network.md)),
  and the filled battery with its percent inside. Steve tried an outlined battery on
  2026-10-07 and rejected it as too faint. An SF Symbol drawn into a rect of its size
  stretches, as it draws past its size, so each is drawn at its own size and cropped to its
  ink (`Sources/zenith/Symbols.swift`).
- **The other items:** the clock redraws at each minute's start on a timer set for it,
  the battery on IOKit's power source notifications, the network on SystemConfiguration's
  and CoreWLAN's notifications ([network.md](network.md)), and the volume on CoreAudio's
  listeners for the default output device's volume and mute, following a new default device.
  From the right end the order is the calendar, the battery, the network and the volume, the
  native menu bar's order with the network in Wi-Fi's place. A click on the network opens
  its panel, on the volume toggles mute through CoreAudio, and on the front app opens Mission
  Control. An output without a volume or a mute property, as Steve's VG279QE5A
  monitors, whose level is set on the monitor, shows the full speaker, and a click does
  nothing there without mute.
- **Look:** the fonts, sizes, paddings and colors of Steve's SketchyBar config of
  2026-10-06, and its app glyph map, copied into `AppIcons.swift`. Colors come from
  `~/.config/zenith/theme.json` (`Theme`), Tokyo Night without it. Steve's dotfiles theme
  build renders it for each theme from `themes/templates/zenith-theme.json.tpl`, and
  `theme-set` links the current one there.
- **Spacing:** items are laid out by their ink, the part of each drawing that shows, with
  16 pt between neighbours, and a pill's number and glyphs, and the calendar's date and
  time, are kerned to 8 pt of ink apart. Laid out by advance widths, as first built, the
  gap after a pill ending in an app glyph read 21.5 to 24 pt against 16.5 pt after a bare
  number, as sketchybar-app-font's glyphs carry several points of blank on their right;
  SketchyBar's own gaps read 14.5 to 16 pt with Steve's paddings. Measured from screen
  captures, 2026-10-06; the gaps now read 15.5 to 16 pt, and 7 to 8.5 pt inside pills.
- **Room on the left:** the left run ends 16 pt before the right run and, on a display with
  a notch, 16 pt before the notch's left edge, x 771.5 on the 1728 pt built-in display, as
  the 32 pt notch hides the 25 pt bar's ink. Items that would pass that are left out from
  the end, the front app's name first, which is cut to 24 characters with "…" so that
  rarely happens. The runs then never overlap, so a click finds one item.
- **Vertical centering:** text centers the height of its first font's capitals and figures
  on the bar's middle line, so baselines agree and descenders move nothing, as Omarchy's
  shell centers its labels (`WidgetButton.qml`); icons center their ink, and a pill's app
  glyphs are raised or lowered to center on its number. Every item's ink then read within
  0.5 pt of the middle, a pixel's rounding, in captures on 2026-10-06.
- **Styles** (`BarStyle`), chosen by `style` in `~/.config/zenith/config.json`: `standard`
  edge to edge; `floating` inset 240 pt from each side with its bottom corners rounded by
  9 pt, Steve's SketchyBar floating style; and `tab`, inset the same with 12 pt bottom
  corners and its top corners flaring out 12 pt into the screen's edge, Noctalia's
  `concave_edge_corners`. The panel stays the display's width and the fill is one shape
  layer with the style's outline, solid, without blur, which shows only on a translucent
  fill. Mockups of these and of `hug`, `framed` and a panel attached to the bar were made
  for Steve on 2026-10-06; he chose these three first.
- **Install:** `script/install.sh` builds Zenith, copies it to `~/.local/bin/zenith` and
  runs it from the LaunchAgent `io.github.st-eez.zenith`, which starts it at login and again
  when it exits, at most every 10 s, launchd's default; errors go to
  `~/Library/Logs/zenith.log`. `--replace-sketchybar` also stops SketchyBar's Homebrew
  service, and `--uninstall` removes Zenith. Kosmos looks Zenith's port up again after a
  restart, so the bar's state comes back without a restart of Kosmos.
- **Settings reload** when `~/.config/zenith` or a file in it changes: an editor replacing
  a file or `theme-set` relinking one changes the folder, and a write in place changes only
  the file, so Zenith watches both.

## 4. Open questions

- What WindowServer spends on an update of one panel, and whether keeping items from moving
  cuts it, which needs a quieter WindowServer than Steve's three displays in use give, or a
  reading finer than `ps`.
