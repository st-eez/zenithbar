# The tray

Whether ZenithBar can show the native menu bar's status items, the tray, in its own bar on
macOS 27, and which of Steve's tray apps ZenithBar could show natively instead. Probe:
`zenithbar-probe tray` (`Sources/zenithbar-probe/Tray.swift`). Measured on Steve's M3 Pro,
macOS 27.0 (26A428), 2026-10-07, with the menu bar auto-hidden (`_HIHideMenuBar = 1`) for
every run, three displays, and a release build.

## 1. How macOS 27 holds the items

- `MenuBarAgent` draws the menu bar of each display in a window of its own at layer 24, three
  windows here. Through Accessibility each window lists every drawn item as a slot whose frame
  is the item's frame on that display, 14 slots each: 6 system items and 8 apps' items.
- A system item's slot holds an `AXMenuBarItem` with an identifier
  (`com.apple.menuextra.clock`, `.battery`, `.sound`, `.wifi`, `.now-playing`,
  `.controlcenter`), a description and a value that carries its state: "Wed Oct 7 9:35 AM",
  "100%, charging", "31%", and the Wi-Fi's description "Wi‑Fi, connected, 3 bars".
- An app's slot holds, on the display whose menu bar is active, the app's own `AXButton`, a
  remote element whose `AXUIElementGetPid` is the app's. On the other displays it holds an
  `AXApplication` carrying the app's name. The active menu bar moved between displays with
  Steve's focus several times during the runs, and the window holding the `AXButton`s moved
  with it.
- Each app also lists its items under its own `AXExtrasMenuBar`, as Ice PR #995 reads them:
  an `AXMenuBarItem` with subrole `AXMenuExtra`, framed on the active display only, whose one
  action is `AXPress`. `MenuBarAgent`'s own `AXExtrasMenuBar` lists the 6 system items.
- RustDesk, Logitech G Hub and Google Drive each list an item at (-1, 1068), and no
  `MenuBarAgent` window has a slot for them, so the system draws them nowhere. Why is
  unconfirmed; System Settings' "Allow in the Menu Bar" switch is the likely cause, as the
  1920 pt displays had room to spare.
- BetterTouchTool, Raycast, Karabiner and CuaDriver have no status item at all
  (`kAXErrorNoValue` for `AXExtrasMenuBar`). Karabiner's menu bar app is not running.
- Text is thin: Teams, Bitwarden and Tailscale give their items no description, title or
  help. OneDrive's title carries its state ("Backed up and synced"), and KeepingYouAwake's help
  says "Click to allow sleep / Right click to show menu".

## 2. Listing the items

`zenithbar-probe tray list 10`, all with the menu bar hidden:

| Read | Time | `MenuBarAgent` CPU a read |
|---|---|---|
| Every running app's `AXExtrasMenuBar`, 129 apps, 0.25 s timeout each | 29 to 51 ms | 0.5 ms |
| The same for the 12 apps with items | 18 to 27 ms | 0.4 ms |
| `MenuBarAgent`'s windows, slot frames and owners | 5 to 37 ms | 4 to 12 ms |
| The same with each item's text | 34 to 154 ms | 9 to 12 ms |

The first read of every app after the process starts took 2.9 s, with a 0.5 s timeout, while
Accessibility connected to each app; Ice measured 12.7 s right after login. Reads with the menu
bar shown were not made: the probe moves no pointer, so nothing revealed it. The frames read
while hidden are where the items show, y 3 to 4 on a 30 pt bar.

## 3. Images

ScreenCaptureKit captures a `MenuBarAgent` window alone with
`SCContentFilter(desktopIndependentWindow:)` while the menu bar is hidden and the window
reads off screen (`zenithbar-probe tray capture`):

- The active display's window holds every item drawn as it shows, the clock to the minute.
  Captures at 09:42:55 and 09:43:06 read "9:42" and "9:43".
- The other displays' windows hold the system items, dimmer, and the apps' items whose images
  are not templates (Teams, OneDrive). Template items, Kosmos, ChatGPT, KeepingYouAwake,
  Bitwarden, Tailscale and BetterDisplay, are clear there. The probe's own item confirmed it:
  a template circle showed only in the active display's window, and a red image that is no
  template showed in all three.
- Captures stay current. In `zenithbar-probe tray watch 45 own` the probe's item swapped its
  template image at 8.0 s and the next capture, at 9.3 s, drew it; it widened at 13.0 s and
  the capture at 14.2 s drew the wide one.
- Cost: listing the shareable content took 45 to 57 ms, and capturing one window 24 to 34 ms,
  over 100 ms in about one capture of five. `MenuBarAgent` spent 0.1 ms a second on a
  capture a second; WindowServer's share is inside its ±50 ms a second of noise.
- Glyphs come white on clear, for the dark menu bar here; ZenithBar would tint them to its
  theme, as Ice cuts the bar away and tints them.

Ice PR #995 captures the display's strip of the menu bar instead, which needs the menu bar
shown, and says a capture of `MenuBarAgent`'s window "holds just the application menu"; it
does not say which display's window it captured.

## 4. Change notifications

`zenithbar-probe tray watch` registered every Accessibility notification it tried on
`MenuBarAgent`, its windows, slots and items (all accepted), and on each item app's
application element, `AXExtrasMenuBar` and item (11 of 33 refused with
`kAXErrorNotificationUnsupported`), while reading and capturing once a second. What arrived:

- At the minute, `AXTitleChanged` and `AXValueChanged`, twice each, from the clock on every
  display, within 20 ms.
- An item added: `AXLayoutChanged` from `MenuBarAgent` for its new slot on each display, 260 to
  300 ms after the app created it.
- An item removed: `AXUIElementDestroyed` from the app after 0.2 s and from `MenuBarAgent` after
  0.9 s.
- `AXMoved` from the clock's slot every few seconds, as it shifted 2 to 3 pt and back. Clock
  seconds and flashing separators are off, and the cause is unknown.

Nothing arrived when an app's item changed its image, changed its width or moved, or when
the active menu bar moved to another display. ZenithBar would take the clock and the add and
remove notifications, and poll for the rest. `zenithbar-probe tray cost`, polling once a
second, in a quiet stretch with each poll run for 20 s:

| Poll | `MenuBarAgent` CPU a second | Probe CPU a second |
|---|---|---|
| Nothing | 0.0 ms | 1.0 ms |
| Slot frames and owners | 11.7 ms | 4.9 ms |
| Frames, owners and text | 14.2 ms | 13.7 ms |
| A capture of one window | 0.1 ms | 4.6 ms |

In two later runs, the second taking turns in 5 s stretches, `MenuBarAgent` spent 30 to 53 ms a
second with nothing polled, while Moonlight streamed and mediaanalysisd ran at 170%, and that load buried the polls' share; the
tight loop in section 2 gives the same 4 to 12 ms a read of its slots. WindowServer's share
stays inside its own noise of ±50 ms a second or more. A capture a second costs
`MenuBarAgent` nothing, and a changed capture says when to read the slots again, so a mirror
would poll the capture and read the slots only when it changes.

## 5. Clicks

`zenithbar-probe tray press io.github.st-eez.kosmos` pressed Kosmos's item once through its
`AXExtrasMenuBar` element, with Chrome in front and the menu bar hidden. KeepingYouAwake was
passed over, as its help text says a click allows sleep.

- At 107 ms WindowServer's `Menubar` window, layer 24, came on screen at y -22, sliding in,
  and the top 40 pt of the display had changed by 11% at 585 ms: the hidden menu bar shows.
- At 164 ms Kosmos's menu opened at layer 101, (1282, 34 234x116), under the item's own place
  on the active display.
- `AXCancel` on the item's `AXMenu` child closed it, and `AXPress`, which blocks while the menu
  is open, returned 597 ms after the press.

A forwarded click therefore opens the app's own menu where the native item is, with the menu
bar shown, whatever display ZenithBar's copy sits on. Apps' items offer `AXPress` alone: an
app whose menu needs a right click, as KeepingYouAwake's does, cannot be opened by
Accessibility. KeepingYouAwake, Bitwarden, BetterDisplay and OneDrive attach no `AXMenu` to
their items and handle the press themselves. WindowServer's `Menubar` window coming on
screen is a signal for the reveal, which [overview.md](overview.md) found missing from
`MenuBarAgent`'s windows; it was seen once here.

## 6. What breaks a mirror

- Template items draw only in the active display's window, so a mirror has to find that
  window, the one whose slots hold `AXButton`s, after each focus change, which no notification
  marks.
- Items the system does not draw (RustDesk, G Hub, Google Drive here) have no image to
  capture. Whether `AXPress` reaches them is untested.
- The notch: the built-in display drew all 14 items right of it, x 1095 to 1707, with the notch
  from 771.5 to 956.5. With more items `MenuBarAgent` folds them behind its overflow button, an
  `AXButton` in its `AXExtrasMenuBar` (Ice PR #995); none was present, and how folded items
  read and capture is untested.
- Permissions: Accessibility for the reads and the press, which ZenithBar has for nothing
  today, and Screen Recording for the captures.
- None of this is documented. The window per display, the slots and the remote `AXButton`s
  are `MenuBarAgent`'s current layout and can change in any update.
- Apps' Accessibility can stall: every read needs a timeout, and the first after launch is
  slow.

**Verdict: feasible with caveats.** Listing, images and clicks all work with the menu bar
hidden. The caveats: only the active display's window holds every image, changes to apps'
items need polling, a click opens the native menu at the native place with the menu bar shown,
right click menus are out of reach, and it all rests on undocumented structure plus Screen
Recording.

## 7. Rebuilding items natively

Read only: `tailscale status --json` (BackendState "Running", 7 peers, no exit node),
`pmset -g assertions`, `karabiner_cli --help`, `cua-driver --help`, the apps' `Info.plist` URL
schemes and BetterDisplay's integration help in its binary. Nothing that changes state was run.

| App | Drawn now | State ZenithBar can read | A click | Verdict |
|---|---|---|---|---|
| Battery, Clock, Sound (Control Center) | yes | IOKit power sources, the clock, CoreAudio, as ZenithBar does today | ZenithBar's own actions, as today | Native, done |
| Wi-Fi | yes | CoreWLAN's interface: power, RSSI, noise, rate and channel; the network name only with Location Services, which ZenithBar lacks ([network.md](network.md)) | A ZenithBar panel | Native, done, as a network item that shows Ethernet too |
| Now Playing | yes | MediaRemote is private, and answers only Apple's own processes since macOS 15.4 (reported, unconfirmed here); Spotify and Music answer AppleScript | Play or pause through the player's AppleScript | Native for Spotify and Music; the system item otherwise |
| Kosmos | yes | Kosmos already pushes its snapshot to ZenithBar | Kosmos's commands over its socket | Native |
| Tailscale | yes | `tailscale status --json`: backend state, this Mac's IPs, peers, exit node, health | `tailscale up`, `down`, `set --exit-node` from a ZenithBar panel | Native |
| KeepingYouAwake | yes | its `caffeinate` child in `pmset -g assertions` ("asserting on behalf of Process ID 1649") | `keepingyouawake:///toggle` or `activate?minutes=`; or ZenithBar takes its own `IOPMAssertion` and the app goes | Native |
| BetterDisplay | yes | its integration: the app binary as a CLI, `BetterDisplay://` with x-callback-url, HTTP and distributed notifications, if enabled in its settings (unconfirmed) | the same calls set brightness, resolution and the like | Native for chosen controls |
| Karabiner | no item | `karabiner_cli --show-current-profile-name`, `--list-profile-names` | `--select-profile` | Native, optional |
| Bitwarden | yes | nothing: no CLI for the desktop app, and `bw` is not installed | open the app | Mirror, or leave in the menu bar |
| OneDrive | yes | its item's Accessibility title ("Backed up and synced") | `AXPress` | Mirror its text |
| Google Drive | not drawn | no interface; sync state is internal to DriveFS | open the app | Leave |
| RustDesk | not drawn | its app binary takes CLI flags such as `--get-id` (not run); `rustdesk://` | open the app | Leave |
| Logitech G Hub | not drawn | none | none | Leave |
| BetterTouchTool | no item | AppleScript (`BTTScripting.sdef`), `btt://` | `trigger_named` | Native only if Steve wants a BTT item |
| Raycast | no item | `raycast://` runs commands | a deep link | Nothing to show |
| CuaDriver | no item | `cua-driver status`, `permissions status` | none needed | Nothing to show |
| Teams, ChatGPT (also present) | yes | nothing public on the Mac | `AXPress` | Mirror, or leave |

## 8. Recommendation

Build the items Steve wants at a glance natively, and leave the rest in the hidden native
menu bar: Tailscale, KeepingYouAwake (or ZenithBar's own assertion) and Kosmos, beside the
clock, battery, volume and network ZenithBar has. They need no Screen Recording, cost
nothing between changes, and a click does what ZenithBar chooses on the display it was made
on. Of the other drawn items only Bitwarden, Teams, ChatGPT and OneDrive have nothing to
read, and a mirrored click would still open their menus at the native place with the native
menu bar shown, so a mirror buys their glyphs alone. Build the mirror later only if Steve
wants those glyphs in ZenithBar: capture the active display's `MenuBarAgent` window once a
second, read the slots when the capture changes, tint the glyphs, and forward clicks with
`AXPress` ([backlog.md](backlog.md)).

Steve chose native items over the mirror on 2026-10-07. Wi-Fi came first, built as a network
item that shows Ethernet too ([network.md](network.md)), then Tailscale on 2026-10-08, its mark
following its tunnel in SystemConfiguration's store ([tailscale.md](tailscale.md)).
