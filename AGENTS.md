Build with `swift build` and test with `swift test`; measure with `swift build -c release`, as a debug build overstates the bar's own time.
Before changing a component, read its doc, listed in `docs/README.md`.
Comments keep only what the code can't show: macOS behavior found by probes, ordering constraints, measured costs, and a ceiling with its upgrade path, each in a line or two that points to the component doc.
Open work lives in `docs/backlog.md`: take an item out when it lands, and add new work there.
Stop SketchyBar while a probe measures ZenithBar: `launchctl bootout gui/$(id -u)/sh.brew.sketchybar`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/sh.brew.sketchybar.plist` after.
Before building a visual change, show Steve mockups of the options and build exactly the one he picks.
This repo is public, so code, docs and tests use placeholders such as `tail1a2b3c`, `100.64.0.x` and `devbox` in place of real tailnet names, IPs, Bluetooth MACs, machine names or service UUIDs.
