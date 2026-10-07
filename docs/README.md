# Zenith docs

- [overview.md](overview.md): the goal, what SketchyBar, Noctalia and Omarchy do, what the
  probes measured, the bar's design, and the open questions.
  Code: `Sources/zenith/`, `Sources/ZenithCore/`, `Sources/ZenithKit/`, `Sources/CZenith/`,
  `Sources/zenith-probe/`, `script/install.sh`.
- [plugins.md](plugins.md): plugins, the commands that show items and panels, their output
  and clicks.
  Code: `Sources/ZenithKit/Plugins.swift`, `Sources/zenith/Panel.swift`, `Sources/ZenithCore/Plugin.swift`.
- [tray.md](tray.md): the native menu bar's status items on macOS 27, what a mirror of them
  in Zenith would read, capture and cost, and which tray apps Zenith could show natively.
  Code: `Sources/zenith-probe/Tray.swift`.
- [network.md](network.md): the network item, how Zenith finds the interface macOS routes
  through, what CoreWLAN gives it for Wi-Fi on macOS 27, the events and their cost, and the
  Wi-Fi network's name, which needs Location Services.
  Code: `Sources/zenith/Network.swift`, `Sources/ZenithCore/Network.swift`, `Sources/zenith-probe/Network.swift`.
- [backlog.md](backlog.md): open work, most urgent first.
