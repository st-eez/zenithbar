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
  the Wi-Fi network's name, which needs Location Services, and the network panel: its live
  figures, Wi-Fi list, speed test, keyboard focus, the views it is built from, and its cost.
  Code: `Sources/zenithbar/Network.swift`, `Sources/zenithbar/NetworkPanel.swift`,
  `Sources/zenithbar/NetworkStats.swift`, `Sources/zenithbar/Wifi.swift`,
  `Sources/zenithbar/PanelKit.swift`, `Sources/zenithbar/Panel.swift`,
  `Resources/Info.plist`, `script/install.sh`, `Sources/ZenithBarCore/Network.swift`,
  `Sources/ZenithBarCore/NetworkPanel.swift`, `Sources/CZenithBar/`,
  `Sources/zenithbar-probe/Network.swift`, `Sources/zenithbar-probe/NetworkPanel.swift`,
  `Sources/zenithbar-probe/Focus.swift`.
- [sound.md](sound.md): the speaker, the microphone item and the sound panel, what CoreAudio
  gives for each device, which app uses a microphone, AirPods' models, the listeners and their
  cost, and the panel's sliders and device lists.
  Code: `Sources/zenithbar/Sound.swift`, `Sources/zenithbar/SoundPanel.swift`,
  `Sources/zenithbar/PanelKit.swift`, `Sources/zenithbar/Controller.swift`,
  `Sources/ZenithBarCore/Sound.swift`, `Sources/zenithbar-probe/Sound.swift`.
- [backlog.md](backlog.md): open work, most urgent first.
