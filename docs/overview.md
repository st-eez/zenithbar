# ZenithBar design overview

ZenithBar is a macOS status bar to replace SketchyBar on Steve's Macs, drawn along the top
of each display, fed by Kosmos's state and by macOS's own events. It takes from SketchyBar
what works, from Noctalia its bar shapes, and from Omarchy's shell its behaviour, and where
SketchyBar's way costs more it does what costs less. SketchyBar configs are not translated:
ZenithBar keeps SketchyBar's names for things where they fit, and nothing of its script
protocol. It was named Zenith until 2026-10-07, when Steve renamed it after SketchyBar.

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

On Steve's M3 Pro, macOS 27.0, 2026-10-06, with SketchyBar stopped for ZenithBar's runs.

- **An update's cost** (`zenithbar-probe cost`): one item's text changing width and the 12
  items after it moving, 300 updates at 20 a second, in seconds alternating with idle ones,
  since WindowServer's own load drifted by a third between 15 s stretches. Ranges span the
  runs.
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
- **Blur inside a bar's outline** (`zenithbar-probe shape`): a tab with 32 pt flares and 20
  pt bottom corners over stripes. NSVisualEffectView with the outline as its `maskImage`,
  the same view with the outline as its layer's mask, and a translucent fill with
  `SLSSetWindowBackgroundBlurRadius` each blurred the stripes fully inside the outline,
  flares included, and left them sharp in the carved flares and corners. Noctalia's shapes
  need nothing private.
- **Clicks** (`zenithbar-probe clicks`): on a nonactivating panel at the status level,
  clicks on an item and on the fill reached the bar, and clicks in the carved flare and
  corner, where the window is clear, reached the probe's window behind it. No click
  activated the probe or made its panel key. A click on the window behind raised it over the
  bar, both at one level in one app, the reordering behind SketchyBar's blank bar (#850), so
  a bar keeps one window per display and gives its popups a level of their own.
- **Spaces** (`zenithbar-probe watch`, Steve driving, three displays): a panel at
  kCGBackstopMenuLevel, -20, with `.canJoinAllSpaces` and `.stationary`, stayed on screen
  through Kosmos workspace switches on two displays, Mission Control, the lock screen and
  back, and native fullscreen. In fullscreen it joined the fullscreen Space without
  `.fullScreenAuxiliary`, and the app covered it, as SketchyBar's bar hides there by
  default. The revealed menu bar slid over it. The window list showed MenuBarAgent's windows
  off screen even while the menu bar showed, so a bar learns of the reveal some other way,
  if it needs to; WindowServer's own `Menubar` window came on screen as the menu bar slid in
  for a status item's menu ([tray.md](tray.md)). AppKit's Space behaviours do what
  SketchyBar's private Space does.

## 3. The bar

- **One process, `zenithbar`,** an agent app with no Dock icon. It draws Steve's SketchyBar
  items natively and starts no process to update them; SketchyBar's script protocol is not
  carried over. Plugins for custom items, as long running processes that push to ZenithBar,
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
  the Mach port ZenithBar registers as `io.github.st-eez.zenithbar`, and ZenithBar reads
  only the newest of those waiting. At launch and after a wake ZenithBar asks for `state`,
  and a click on a workspace sends `workspace <name>`, each as one request on Kosmos's
  socket. Kosmos's snapshot names each display's CoreGraphics UUID, since Kosmos 638151c,
  and ZenithBar matches its screens by it; before, ZenithBar copied Kosmos's SketchyBar
  numbering, and the two counted active displays differently. Each workspace joins its
  display by its own `displayUUID`, as Kosmos's display numbers are no key: it gives 0 both
  when it manages no display and to a workspace on no listed display, and every display 1
  when one is active. From a Kosmos without the field, ZenithBar joins by number.
- **Icons:** solid, Steve's choice on 2026-10-07 after a line style, a thin speaker beside
  solid glyphs, read as clashing: SF Symbols at 14 pt (the filled speaker or AirPods, the
  microphone, Wi-Fi, a plugin's `symbol`, as the agents' sparkles), Material's solid Ethernet port and
  Bluetooth glyphs at 16 pt ([network.md](network.md), [bluetooth.md](bluetooth.md)), and the battery, a solid body filled to the charge over a
  fainter trough with the percent and the bolt cut out of it, 25 by 14 pt, its digits 8.5 to
  10 pt and a 8.5 pt bolt centered together, with room around them, as larger crowded the
  body. An outline holding only the number was too faint, and an outline around the fill
  unwanted. An SF Symbol drawn into a rect of its size stretches, as it draws past its size,
  so each icon is drawn at its own size and cropped to its ink
  (`Sources/zenithbar/Symbols.swift`).
- **The other items:** the clock redraws at each minute's start on a timer set for it,
  the battery on IOKit's power source notifications, the network on SystemConfiguration's
  and CoreWLAN's notifications ([network.md](network.md)), the speaker and the microphone
  on CoreAudio's listeners ([sound.md](sound.md)), and Bluetooth on CoreBluetooth's state and
  IOBluetooth's connections once Bluetooth is allowed ([bluetooth.md](bluetooth.md)). From the
  right end the order is the calendar, the battery, the network, Bluetooth, the speaker and the
  microphone, the native menu bar's order with the network in Wi-Fi's place and Bluetooth where
  Omarchy puts it, then the plugins' items. A click on the network opens its panel, on
  Bluetooth opens the Bluetooth panel, on the speaker opens the sound panel, and on the front
  app opens Mission Control; a right click on the speaker mutes it, and a click on the microphone mutes it. The
  microphone shows only while an app uses an input device or a mute is on. An output without
  a volume or a mute property, as Steve's monitors, whose level is set on the monitor, shows
  the full speaker.
- **Modules** (`BarModule`, `Sources/zenithbar/Module.swift`): each built-in item of the right
  run comes from a module in a file of its own: `CalendarModule`, `BatteryModule`,
  `NetworkModule`, `BluetoothModule` and `SoundModule`, which shows the speaker and the
  microphone. A module gives the keys of its items; its items for a display's scale and the
  theme, leaving out one it hides; its clicks and scrolls; its panel's view, with what runs
  while the panel opens, closes and refreshes; what it reads again after a wake; what it takes
  from config.json; and in debug builds its test hooks. `Controller` keeps the modules in one
  list in bar order and hands each what its keys receive, and names no item outside that
  list, so a new built-in item is a module file and an entry in the list. A module asks for a
  redraw through its `ModuleHost`, saying whether its icon changed, and the controller then
  refreshes the module's panel while it shows. The modules read services that know nothing of
  the bar: `Sound`, `Network`, `Bluetooth` and `Battery` hold the system's state and call back
  on each change, and the panels read the same services. The workspaces, the front app and the
  plugins' items stay in `Controller`. Each module keeps its images in a `DrawingCache`, which
  draws an image again only when what it shows changes; keyed by `AnyHashable` values built at
  each lookup, a render with nothing changed took about 0.03 ms more, 4%, so its keys are
  typed. A render, release builds, all three displays, the main thread's CPU over 3000 renders
  with nothing changed and 300 with every item changed, five runs each, taking turns, on
  2026-10-07: before the modules 0.697 to 0.721 ms and 4.06 to 4.31 ms, with them 0.715 to
  0.717 ms and 4.09 to 4.18 ms. Left out: a module's stop, as each runs until ZenithBar exits;
  a config that turns built-in items off ([backlog.md](backlog.md)) would need it.
- **Panels** (`Popup`): one nonactivating panel at the pop up menu level, over apps'
  windows and the bar, right aligned under its item, with a solid fill and a 2 pt accent
  border. It shows a plugin's page, drawn as rows ([plugins.md](plugins.md)), or the network
  panel, built from views of `Sources/zenithbar/PanelKit.swift`: labels, icon buttons, a
  switch, rows, a scrolling list and a password field, in the theme's colors and the bar's
  font, each taking the first click, as the panel is never active. It takes the keyboard
  only while a password field is open, without making ZenithBar the front app, and gives it
  back by ordering out and in ([network.md](network.md), the panel's focus). The sound panel
  is built from the same views and the slider it adds ([sound.md](sound.md)), and the Bluetooth
  panel from the same views ([bluetooth.md](bluetooth.md)). NSPopover and NSMenu were left out, as the theme cannot color
  their material.
- **The left run:** Apple's logo (U+F8FF in the system font, which only Apple's fonts draw;
  a click does nothing yet), then the workspaces, then the front app. A named workspace after
  numbered ones, as Steve's `agent`, sits past a thin dim line (U+2502), so it does not read as
  one of them, and config.json's `workspaceIcons` can give it a glyph in place of its name, as
  `{"agent": "\U000F06A9"}`, Material's robot, a number's width (Steve, 2026-10-08). Focus
  still shows by color alone, which a color or background on the agent workspace would have
  hidden. A glyph past U+FFFF is a surrogate pair in a string, so `joined` kerns its whole
  last character: on its second half the pair split and drew as two boxes.
- **Look:** the fonts, sizes, paddings and colors of Steve's SketchyBar config of
  2026-10-06, and its app glyph map, copied into `AppIcons.swift`. Colors come from
  `~/.config/zenithbar/theme.json` (`Theme`), Tokyo Night without it. Steve's dotfiles theme
  build renders it for each theme from `themes/templates/zenithbar-theme.json.tpl`, and
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
- **Styles** (`BarStyle`), chosen by `style` in `~/.config/zenithbar/config.json`:
  `standard` edge to edge; `floating` inset 240 pt from each side with its bottom corners
  rounded by 9 pt, Steve's SketchyBar floating style; and `tab`, inset the same with 12 pt
  bottom corners and its top corners flaring out 12 pt into the screen's edge, Noctalia's
  `concave_edge_corners`. The panel stays the display's width and the fill is one shape
  layer with the style's outline, solid, without blur, which shows only on a translucent
  fill. Mockups of these and of `hug`, `framed` and a panel attached to the bar were made
  for Steve on 2026-10-06; he chose these three first.
- **Install:** `script/install.sh` builds ZenithBar into `/Applications/ZenithBar.app`, an
  agent bundle (`LSUIElement`) with `Resources/Info.plist`, signed with the first Apple
  Development certificate as Kosmos's bundle is, and runs its binary from the LaunchAgent
  `io.github.st-eez.zenithbar`, which starts it at login and again when it crashes or exits
  with an error (`KeepAlive`'s `SuccessfulExit` false), at most every 10 s, launchd's default;
  errors go to `~/Library/Logs/zenithbar.log`. A bundle, as
  Location Services asked nothing of the bare `~/.local/bin/zenithbar` earlier installs ran,
  which the install removes ([network.md](network.md), section 3). Location Services' grant
  survived two reinstalls on 2026-10-07: ZenithBar logs its answer at launch. The build is signed in
  `.build/dist`, copied beside the installed app without the `.app` extension and renamed
  over it once ZenithBar stops. `--replace-sketchybar` also stops SketchyBar's Homebrew
  service, and `--uninstall` removes ZenithBar. Kosmos looks ZenithBar's port up again after
  a restart, so the bar's state comes back without a restart of Kosmos.
- **Crash loops** (`LaunchGuard`, `Sources/ZenithBarKit/LaunchGuard.swift`): launchd has no
  limit on restarts, so a crash at launch, as Bluetooth's on 2026-10-07, left no bar and a
  crash report every 10 s. Started by launchd, ZenithBar counts its launches in
  `~/Library/Application Support/ZenithBar/quick-launches`, and a run that lasts 30 s clears
  the count. The launch after three that each ended within 30 s logs why, to the unified log
  and `zenithbar.log`, clears the count and exits 0, which launchd does not restart.
  `launchctl kickstart gui/$(id -u)/io.github.st-eez.zenithbar`, the next login or
  `script/install.sh`, which clears the count too, starts it again. A run by hand counts
  nothing. A ZenithBar that cannot get its Mach name, as while a debug copy holds it, so stops
  after three tries where it retried every 10 s before. Tested on 2026-10-07 under a separate
  label with a copy of a debug build: launchd restarted it after a SIGSEGV and after two exits
  with an error, and the fourth launch logged, exited 0 and stayed stopped.
- **Settings reload** when `~/.config/zenithbar` or a file in it changes: an editor
  replacing a file or `theme-set` relinking one changes the folder, and a write in place
  changes only the file, so ZenithBar watches both.

## 4. Threads

Every callback macOS makes enters the main actor through `onMain`
(`Sources/ZenithBarKit/OnMain.swift`): its entry is nonisolated, a `@Sendable` closure or a
`nonisolated` method, and `onMain` runs its body at once on the main thread and on the main
queue's next turn from any other. A callback that arrives off the main thread is then one turn
late where a main-actor method would trap: IOBluetooth called `Bluetooth.connected` on
CoreBluetooth's queue, and the method's isolation check crashed every launch with AirPods
connected (2026-10-07, fixed in 75a191e). `onMain` holds the code's one
`MainActor.assumeIsolated`, after it checks the thread. Code that waits a turn on purpose, as
`Sound` does to read once for a burst of listener calls, dispatches to the main queue and
enters through `onMain` there.

Seen: logged by a debug copy that wrote each `onMain` caller's thread and queue, 2026-10-07;
the rest follow from where they are registered.

| Callback | Registered by | Arrives on | |
|---|---|---|---|
| Kosmos's snapshots on the Mach port, and its socket's replies | `KosmosLink` | ZenithBar's `zenithbar.kosmos` queue | seen |
| A plugin's output | `Plugins`, a pipe's `readabilityHandler` | Foundation's `com.apple.NSFileHandle.fd_monitoring` queue | seen |
| A plugin exiting | `Plugins`, `Process.terminationHandler` | a global queue | seen |
| The clock, the plugins' intervals, the panels' phrases, the network panel's samples | `Timer` on the main run loop | main | seen |
| `config.json`, `theme.json` and their folder changing | `DispatchSource` on the main queue | main | |
| Screens changing, wake, the popup losing key | `NotificationCenter`, queue `.main` | main | |
| Test hooks, debug builds only | `DistributedNotificationCenter`, queue `.main` | main | seen |
| Power sources | `IOPSNotificationCreateRunLoopSource` on the main run loop | main | |
| The primary interface and services | `SCDynamicStore` run loop source on the main run loop | main | |
| Wi-Fi power, link and link quality | `CWEventDelegate` | CoreWLAN's `com.apple.wifi.xpcclient.event.<UUID>` queue | seen |
| Audio devices, defaults, volumes, mutes, running | `AudioObjectAddPropertyListenerBlock` on the main queue | main | |
| coreaudiod restarting, `kAudioHardwarePropertyServiceRestarted` ([sound.md](sound.md), section 11) | `AudioObjectAddPropertyListenerBlock` on the main queue | main | untested live |
| Bluetooth's state | `CBCentralManager`, queue `.main` | main | seen |
| A Bluetooth device connecting | IOBluetooth's connect notification | `com.apple.bluetooth.iobluetooth.coordinatorQueue` | seen, and in the crash report |
| A Bluetooth device disconnecting, a connection the panel opened completing | IOBluetooth | unknown, taken as any | |
| Location Services' answer | `CLLocationManagerDelegate`, the manager made on the main thread | main | seen |
| system_profiler, Wi-Fi scans and actions, samples, the speed test | ZenithBar's own queues | those queues | seen |

## 5. Open questions

- What WindowServer spends on an update of one panel, and whether keeping items from moving
  cuts it, which needs a quieter WindowServer than Steve's three displays in use give, or a
  reading finer than `ps`.
