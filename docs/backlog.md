# Backlog

- An expired limit keeps its alert for up to 15 minutes: the panel works out its times when
  it opens, but the agents plugin runs every 900 s. Run a plugin again at the earliest
  `until` it printed.
- Find what WindowServer spends on an update of one panel, and whether keeping items from
  moving cuts it: `zenithbar-probe cost text still` with the Mac otherwise idle.
- The calendar's double click between a filled and a transparent bar, with text colored
  from the wallpaper under it.
- A config file for which built in items show, their order and their look.
- Plugins kept running, to print as things change, as a media item would, restarted when
  they exit.
- More styles from the mockups: `hug`, full width with its bottom corners flaring down into
  the screen's sides, and `framed`, a border round the other three edges; and panels that
  drop out of the bar as one shape, with the agents popup.
- The Wi-Fi network's name and the scan's names ([network.md](network.md), section 3):
  Steve clicks Allow in the panel of the signed ZenithBar.app and allows it at Location
  Services' prompt, then confirm the name and the list show, and whether the grant survives
  `script/install.sh` replacing the app.
- Try the network panel's untested paths with Steve at the Mac ([network.md](network.md),
  untested): join a known network and a new one with its password, a wrong password, leave,
  forget, the Wi-Fi switch off and on, and the password field taking and giving back the
  keyboard. Record whether forgetting prompts for an admin password, and the speed test
  summary's keys from the log.
- The sound panel, with sliders and device lists, from the views in
  `Sources/zenithbar/PanelKit.swift`; a slider is the one piece it adds.
- Joining a hidden network by name, and an enterprise network with a user name, from the
  network panel; today a hidden network's row does nothing, and an enterprise network's says
  to join it in System Settings once.
- Run `zenithbar-probe network watch` while Steve plugs and unplugs Ethernet, turns Wi-Fi
  off and on, changes networks, sleeps and wakes, and turns on a Tailscale exit node, and
  record what the store and CoreWLAN sent and what the item showed
  ([network.md](network.md), untested).
- Native tray items ([tray.md](tray.md)): Tailscale from `tailscale status --json`, with a
  panel to connect, disconnect and pick an exit node; a keep awake item, KeepingYouAwake's
  state from its `caffeinate` assertion and `keepingyouawake:///toggle`, or ZenithBar's own
  `IOPMAssertion`.
- If Steve wants the other apps' glyphs in ZenithBar, a tray mirror ([tray.md](tray.md)):
  capture the active display's MenuBarAgent window once a second, read its slots when the
  capture changes, tint the glyphs and forward clicks with `AXPress`. Needs Screen Recording
  and Accessibility for ZenithBar. First probe how items folded behind the overflow button
  and items the system does not draw (RustDesk, G Hub, Google Drive) read and press.
- Read the tray with the menu bar shown, and confirm that WindowServer's `Menubar` window
  coming on screen marks every reveal of the hidden menu bar, if ZenithBar needs to know.
