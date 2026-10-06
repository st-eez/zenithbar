Build with `swift build` and test with `swift test`; measure with `swift build -c release`, as a debug build overstates the bar's own time.
Before changing a component, read its doc, listed in `docs/README.md`.
Comments keep only what the code can't show: macOS behavior found by probes, ordering constraints, measured costs, and a ceiling with its upgrade path, each in a line or two that points to the component doc.
Open work lives in `docs/backlog.md`: take an item out when it lands, and add new work there.
Stop SketchyBar while a probe measures Zenith: `launchctl bootout gui/$(id -u)/sh.brew.sketchybar`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/sh.brew.sketchybar.plist` after.
