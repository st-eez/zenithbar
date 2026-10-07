# Backlog

- An expired limit keeps its alert for up to 15 minutes: the panel works out its times when
  it opens, but the agents plugin runs every 900 s. Run a plugin again at the earliest
  `until` it printed.
- Find what WindowServer spends on an update of one panel, and whether keeping items from
  moving cuts it: `zenith-probe cost text still` with the Mac otherwise idle.
- The calendar's double click between a filled and a transparent bar, with text colored
  from the wallpaper under it.
- A config file for which built in items show, their order and their look.
- Plugins kept running, to print as things change, as a media item would, restarted when
  they exit.
- SketchyBar was retired on 2026-10-06 (`script/install.sh --replace-sketchybar`). Move the
  agents collector out of the dotfiles sketchybar package into zenith's, where the agents
  plugin runs it from, and decide whether Kosmos still pushes to SketchyBar's port.
- More styles from the mockups: `hug`, full width with its bottom corners flaring down into
  the screen's sides, and `framed`, a border round the other three edges; and panels that
  drop out of the bar as one shape, with the agents popup.
- The tray: SketchyBar's alias items cannot work on macOS 27. Leave status items in the
  hidden native menu bar until reading MenuBarAgent's items through Accessibility and
  capturing its window is probed.
