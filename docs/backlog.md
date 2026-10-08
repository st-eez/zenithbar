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
- The Wi-Fi network's name and the scan's names ([network.md](network.md), section 3): with
  Location Services allowed, and the grant surviving reinstalls, confirm the name and the
  list show in the panel.
- Try the network panel's untested paths with Steve at the Mac ([network.md](network.md),
  untested): join a known network and a new one with its password, a wrong password, leave,
  forget, the Wi-Fi switch off and on, and the password field taking and giving back the
  keyboard. Record whether forgetting prompts for an admin password, and the speed test
  summary's keys from the log.
- Try the sound panel and the microphone with Steve at the Mac ([sound.md](sound.md),
  untested): mute the MacBook Pro Microphone from the item while Discord listens, and confirm
  Discord hears silence; whether the alert sound device follows the default output; scroll on
  the speaker and the microphone with a mouse and a trackpad, and drop scrolling if it
  misbehaves. Steve's clicks on 2026-10-07 already set defaults and dragged both sliders.
- With AirPods ([sound.md](sound.md), AirPods): connect and disconnect them with the panel open
  and closed, let them switch to the iPhone, and take a call, and check the speaker's
  `airpods.gen4`, the rows, the microphone item and that no row or icon is left behind. Check
  whether the AirPods' output device lists under INPUT during a call, and whether it keeps
  counting as a microphone in use after the call, which `IsRunningSomewhere` would show as live
  while only music plays (sound.md, section 2's ceiling).
  Check `preferBuiltInMic` ([sound.md](sound.md), section 10): on connecting, the default input
  goes back to the MacBook Pro Microphone with the output left on the AirPods, the log names
  the switch, and the AirPods' microphone picked in the panel stays.
- Try the Bluetooth panel with Steve at the Mac ([bluetooth.md](bluetooth.md), untested): allow
  ZenithBar's Bluetooth prompt on the panel's first open and check the log for the events
  starting; connect and disconnect the AirPods and the Beats from the panel, and the MX Master or
  AULA keyboard, which are Bluetooth LE and may refuse IOBluetooth's connection; check the item's
  connected glyph follows, the rows' batteries, and how far system_profiler lags the
  notifications; turn Bluetooth off and on from the switch when no keyboard or mouse needs it.
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
