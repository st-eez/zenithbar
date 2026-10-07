# ZenithBar docs

- [overview.md](overview.md): the goal, what SketchyBar, Noctalia and Omarchy do, what the
  probes measured, the bar's design, and the open questions.
  Code: `Sources/zenithbar/`, `Sources/ZenithBarCore/`, `Sources/ZenithBarKit/`,
  `Sources/CZenithBar/`, `Sources/zenithbar-probe/`, `script/install.sh`.
- [plugins.md](plugins.md): plugins, the commands that show items and panels, their output
  and clicks.
  Code: `Sources/ZenithBarKit/Plugins.swift`, `Sources/zenithbar/Panel.swift`,
  `Sources/ZenithBarCore/Plugin.swift`.
- [tray.md](tray.md): the native menu bar's status items on macOS 27, what a mirror of them
  in ZenithBar would read, capture and cost, and which tray apps ZenithBar could show
  natively.
  Code: `Sources/zenithbar-probe/Tray.swift`.
- [network.md](network.md): the network item, how ZenithBar finds the interface macOS
  routes through, what CoreWLAN gives it for Wi-Fi on macOS 27, the events and their cost,
  and the Wi-Fi network's name, which needs Location Services.
  Code: `Sources/zenithbar/Network.swift`, `Sources/ZenithBarCore/Network.swift`,
  `Sources/zenithbar-probe/Network.swift`.
- [backlog.md](backlog.md): open work, most urgent first.
