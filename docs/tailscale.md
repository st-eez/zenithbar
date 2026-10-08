# Tailscale

The Tailscale item and panel, after Omarchy 4's Tailscale panel
(`shell/plugins/panels/tailscale/Panel.qml`, `Service.qml`, `Model.js`,
`TailscaleIcon.qml`) and the mockup Steve approved on 2026-10-08, its option B: offline
machines stay listed, dim, under the online ones. The item shows whether Tailscale's tunnel is
up; a left click opens the panel and a right click turns Tailscale on or off. The panel lists
the tailnet's machines, sends one files with Taildrop and copies its address. This doc records
what macOS and Tailscale give ZenithBar, what it costs, and what stays untested. Measured on
Steve's M3 Pro, macOS 27.0.1, 2026-10-08, with Tailscale 1.102.4 up on utun6 and no exit node.

## 1. What macOS and Tailscale give

- **The app:** Steve runs Tailscale's standalone app (`/Applications/Tailscale.app`), whose
  VPN runs as a system extension. `/usr/local/bin/tailscale` is a shell script that runs the
  app's binary with its arguments. That binary acts as the CLI only while `TERM` is set:
  with `env -i HOME=$HOME` and no `TERM` it answered "The Tailscale GUI failed to start" for
  `status --json`, and with `TERM=dumb` alone it answered. launchd starts ZenithBar without
  `TERM`, so ZenithBar runs the app's binary itself with `TERM=dumb` added.
- **The store:** the app's VPN service, `3F2A1C9E-…` on Steve's Mac, has
  `Setup:/Network/Service/<id>/Interface` `Type` VPN, `SubType` `io.tailscale.ipn.macsys`
  (the App Store app's should be `io.tailscale.ipn.macos`, unconfirmed), and `UserDefinedName` "Tailscale".
  While the tunnel is up, `State:/Network/Service/<id>/IPv4` holds utun6, 100.64.0.1 with
  itself as router, and routes to 100.64.0.0/10 and 100.100.100.100. `scutil --nc list`
  showed Steve's three other VPN services, ProtonVPN and two WireGuard, disconnected, and none
  of them had a `State:` IPv4 key, so ZenithBar takes that key as the tunnel being up. That
  Tailscale's key goes when its tunnel stops is untested, as Steve's SSH sessions run over it.
- **Reading the store:** the Interface values by pattern and the one IPv4 key took 0.29 ms,
  median of 200, 0.50 ms at the 90th percentile, in a release build. ZenithBar opens a second
  store session, `zenithbar.tailscale`, notified on `Setup:/Network/Service/.*/Interface` and
  `State:/Network/Service/.*/IPv4`, the second the network item's own key
  ([network.md](network.md), section 1). Its own session keeps the module apart from the
  network item, whose read lists every interface's kind, 2.1 ms that Tailscale's needs none
  of; the store sent the network item nothing in 180 s of steady Wi-Fi.
- **`tailscale status --json`:** 82 ms, 60 ms of CPU. ZenithBar reads `BackendState`;
  `Self`'s `HostName` ("Steve’s MacBook Pro"), `UserID` and `Capabilities`, which list
  `https://tailscale.com/cap/file-sharing` when the tailnet allows Taildrop; and each peer's
  `HostName`, `DNSName`, `OS`, `TailscaleIPs`, `Online`, `TaildropTarget` and `UserID`. The
  iPhone's `HostName` reads "localhost", as iOS hides it; its `DNSName` starts iphone.
  `TaildropTarget` read 1, available, for the six machines online, and 5, offline, for the
  Windows PC.
- **On and off:** `tailscale up` and `tailscale down`, as Omarchy runs them. Strings in the
  app's binary tie Tailscale's `WantRunning` to the VPN's state ("Failed to set wantRunning
  on vpnstate->connected", "wantrunning-false", "Termination deferred. Waiting for VPN Stop"),
  so `down` should stop the tunnel and take utun6's address with it, and `up` start it again.
  Neither was run, as `down` drops Steve's SSH sessions. `down` asks to confirm only from a
  shell inside an SSH session over Tailscale (its `--accept-risk lose-ssh`), and ZenithBar's
  environment has none.

## 2. The item

- **Mark** (`tailscaleMark`, `Sources/zenithbar/TailscaleModule.swift`): Tailscale's 3 by 3
  grid of dots, drawn as Omarchy's `TailscaleIcon.qml`: the middle row and the bottom's
  middle dot full, the rest at 24%, 12 pt square with dots 27% of it, cropped to its ink.
  It shows in the foreground while the tunnel has its address and in the theme's dim color
  while it does not; a Mac without Tailscale's VPN service shows none.
- **Place:** between the network and Bluetooth: the microphone, the speaker, Bluetooth,
  Tailscale, the network, the battery and the clock.
- **Clicks:** a left click opens or closes the panel; a right click runs `tailscale up` or
  `down`, as Omarchy's, and the store's notification then moves the mark. Nothing polls:
  the mark follows the store alone.

## 3. The panel

- **Header:** the mark at 26 pt, dim while off; this Mac's name from the last status read,
  "Tailscale" before one; under it, in capitals spaced 1.2 pt, Omarchy's phrases, one every
  2.8 s while on (`tailscalePhrases`): Encrypting connections, Sending secrets, Guarding
  wires, Braiding packets, Polishing tunnels, Hiding routes, Sealing ports, Sorting tailnets,
  Shuffling keys, Watching machines; "Disconnected" while off. At the right, the switch,
  which moves at the click and goes back after 10 s if the store never changes, and at once
  if the CLI fails.
- **Caption news:** what a click did shows in the accent color in place of the phrase for
  3 s while the panel is open: "Copied 100.64.0.5", "Refreshed", "Sent to devbox",
  "Could not send to devbox: …", or the CLI's error for the switch. A send that ends after
  the panel closed shows at the next open. "Sending to devbox…" shows while a send runs.
- **MACHINES,** while on: the machines online, by name, each with its OS's logo (Omarchy's
  `osIcon`, Material's glyphs in the bar's font: Linux U+F033D, Apple U+F0035 for macOS and
  iOS, Windows U+F0372, Android U+F0032, else U+F07C0), its name, and under it its IPv4
  address and DNS name. A machine whose `HostName` is "localhost" shows its DNS name's first
  label, as iphone. At the right of MACHINES, a refresh button reads the machines again.
- **Send:** the paper plane, shown for a machine Taildrop can reach: this Mac has the
  file-sharing capability, the machine is online, and its `TaildropTarget` is 1, or 0 with the
  same owner, as Omarchy's `isTaildropTarget`. A click closes the panel, which would cover
  the picker, makes ZenithBar the front app so the macOS file picker takes the keyboard, and
  gives the front back to the app that had it when the
  picker closes. The files picked go by `tailscale file cp --update-interval=0 -- <files>
  <ip>:`, Omarchy's `omarchy-tailscale-send` with the machine's address as the target, for as
  long as they take.
- **Copy:** copies the machine's IPv4 address and shows a check for 1 s. Omarchy's copy
  menu, which also offers the name and the DNS name, is left out.
- **OFFLINE:** the machines offline, below, dim, each with its OS's name and address under
  its name, without buttons or a hover.
- **Notes:** "Turn Tailscale on to see its machines" while off; "Reading the machines…"
  before the first read; "Could not read Tailscale" when it failed; "No machines online".
- **Reads:** `tailscale status --json` runs as the panel opens, on the refresh button, and
  after the switch turns Tailscale on, once at a time, off the main thread, and stops after
  15 s, as Omarchy's watchdog found the CLI can hang on a network coming and going. The
  rows are made again only when what they show changes.
- **Look:** 380 pt wide, built from PanelKit's labels, buttons, switch, rows, lists and
  divider, as the Bluetooth panel ([network.md](network.md), the pieces).
- **Module** (`TailscaleModule`, `Sources/zenithbar/TailscaleModule.swift`): the item and its
  panel (`TailscalePanel`), from `Tailscale` (`Sources/zenithbar/Tailscale.swift`), which
  holds the store's answer and the last status read, and runs the CLI
  ([overview.md](overview.md), modules). The status's parsing is
  `Sources/ZenithBarCore/Tailscale.swift`.
- **Left out,** from Omarchy's panel: exit nodes and Mullvad, switching accounts, logging in
  when Tailscale needs it, the operator setup, and keyboard navigation.

## 4. Receiving files

The Linux machines do not collect Taildrop files on their own: a file sent to one waits in
its tailscaled's inbox until `sudo tailscale file get ~/Downloads` runs there. Omarchy's
`omarchy-tailscale-receive` service runs that loop where its Tailscale install enabled it;
whether Steve's omarchy box has it is unchecked. Steve deferred setting up receivers on
2026-10-08 ([backlog.md](backlog.md)).

## 5. Cost

Between changes ZenithBar runs nothing for Tailscale: the mark waits for the store's
notifications, each a 0.29 ms read. An open panel adds one status read as it opens, about
82 ms and 60 ms of the child's CPU off the main thread, and the caption's phrase every
2.8 s, stopped when it closes. The open panel was rendered offscreen from a debug build
against the live tailnet: six machines online, the Windows PC offline.

## 6. Untested

Steve's SSH sessions run over Tailscale, so nothing turned it off on 2026-10-08. Untested:
the right click and the switch turning Tailscale off and on; the mark going dim as the
tunnel's IPv4 key goes, and back; `tailscale up` starting a stopped tunnel; the file picker
under Kosmos and the front app coming back after it; a send, and its error; the installed
panel on screen; the App Store app's subtype.
