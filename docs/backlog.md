# Backlog

- Find what WindowServer spends on an update of one panel, and whether keeping items from
  moving cuts it: `zenith-probe cost text still` with the Mac otherwise idle.
- Kosmos: put each display's UUID in the snapshot's `displays`, and key Zenith's bars by
  it, so Zenith drops its copy of SketchyBar's display numbering. The copies differ: Zenith
  counts `NSScreen.screens` and Kosmos `CGGetActiveDisplayList`, which may disagree around
  mirroring. In the same change, BarPush can keep each bar's port itself, in place of
  KosmosBar.c's table of names (review of 2026-10-06).
- Retire SketchyBar with `script/install.sh --replace-sketchybar` once the agents item lands.
- The agents item and popup, as Zenith's first plugin.
- The calendar's double click between a filled and a transparent bar, with text colored
  from the wallpaper under it.
- A config file for which items show, their order and their look, and the socket plugins
  push to.
- More styles from the mockups: `hug`, full width with its bottom corners flaring down into
  the screen's sides, and `framed`, a border round the other three edges; and panels that
  drop out of the bar as one shape, with the agents popup.
- The tray: SketchyBar's alias items cannot work on macOS 27. Leave status items in the
  hidden native menu bar until reading MenuBarAgent's items through Accessibility and
  capturing its window is probed.
