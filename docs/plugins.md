# Plugins

A plugin is a command that shows an item on the bar and, on a click, a panel under it. Zenith
runs it and reads what it prints; it needs no library and no socket. The agents item in
Steve's dotfiles, `zenith/.config/zenith/plugins/agents`, is the first.

- **Config:** `plugins` in `~/.config/zenith/config.json` lists each as `command`, the
  program then its arguments with `~` for the home folder, and `interval` in seconds.
- **Runs:** Zenith runs each plugin at launch, every `interval` seconds, after a wake and on a
  right click on its item, setting `ZENITH_EVENT` to `launch`, `interval`, `wake` or
  `refresh`. A run asked for while one goes is dropped, since that run reports, and a run
  past 2 minutes is stopped. A run ends when the plugin exits: a child it leaves holding
  standard output, as `cmd &` or ssh does, holds back no later run, and what the child prints
  still reaches the bar until it closes the pipe. A run that exits with an error is logged.
  Plugins inherit Zenith's environment, whose `PATH` the LaunchAgent sets to include Homebrew.
- **Ceiling:** the 2 minute stop reaches only the plugin, not its children, since Foundation's
  `Process` cannot start it in a process group of its own. Starting it with `posix_spawn` and
  `POSIX_SPAWN_SETPGROUP`, then signalling the group, would stop them too.
- **Output:** each line a plugin prints on standard output is one JSON object, an item:
  - `item`, its name, and `icon`, the glyph the bar shows, in JetBrains Mono Nerd Font.
  - `alert`, drawn in the theme's alert color, and `hidden`, off the bar.
  - `pages`, the panel's pages, each with a `tab` naming it among the others, a `title`,
    and `rows`, each one of:
    - `{"caption": "LIMITS"}`, a small heading;
    - `{"meter": "Session", "value": 0.62, "detail": "62%", "tone": "alert", "bold": true}`,
      a label, a bar filled from 0 to 1 and a value at the right;
    - `{"note": "Resets in", "until": 1791338399, "detail": "…", "tone": "dim"}`, small
      text, with the time to `until` or since `since`, Unix seconds, written when the panel
      opens.
  - A tone is `normal`, `dim`, `warning` or `alert`. A later line with the same `item`
    replaces it, so a plugin may print its last result at once and a fresh one later.
- **Clicks:** a left click opens or closes the panel, a middle click or a click on a tab
  shows another page, and a right click runs the plugin with `ZENITH_EVENT=refresh`. The
  panel closes 50 ms after the pointer leaves both it and its item.
- **Panel:** a nonactivating panel at the pop up menu level, over apps' windows and the bar,
  right aligned under its item, in the geometry and fonts of Steve's SketchyBar agents panel.
  It draws when it opens and when its item or page changes while it shows; closed, it draws
  nothing.
- **Why lines of JSON on a pipe:** every language prints JSON, it nests the panel, it can be
  read in a terminal, and new fields leave old plugins working. Decoding a line costs tens of
  microseconds. Waybar's custom modules start a shell per update; a Zenith plugin starts
  once per run. A plugin kept running to print as things change, for a media item, would
  need Zenith to restart it when it exits, which interval plugins do not.
- **Why the agents item runs on an interval:** a run costs about 50 ms of Python's CPU and
  about 5 s of waiting on ssh, four times an hour, where a resident Python would hold about
  15 MB. Steve chose the interval on 2026-10-06.
- **Native popups** (`zenith-probe popups`, 2026-10-06): an `NSPopover` and an `NSMenu`
  opened from a nonactivating bar panel without making Zenith the front app. Both draw in
  the system's material and take only a light or dark appearance: neither has a public
  background color or opacity, and a full width colored view inside a popover leaves its
  arrow and edge in the material. Steve found the popover's look loose beside the panel's;
  the panel stays custom, where the theme sets every color.
