#!/usr/bin/env bash
# Builds ZenithBar from this checkout, installs it to ~/.local/bin/zenithbar and runs it from a
# LaunchAgent that starts it at login and again whenever it exits (docs/overview.md).
#
#   script/install.sh [--replace-sketchybar | --uninstall]
#
# --replace-sketchybar also stops SketchyBar's Homebrew service, so it no longer starts at
# login; `brew services start sketchybar` brings it back. --uninstall stops ZenithBar and removes
# its LaunchAgent and binary, leaving ~/.config/zenithbar.
set -euo pipefail
usage="usage: script/install.sh [--replace-sketchybar | --uninstall]"
mode=install
case ${1:-} in
    "") ;;
    --replace-sketchybar) mode=replace ;;
    --uninstall) mode=uninstall ;;
    *) echo "$usage" >&2; exit 2 ;;
esac

label=io.github.st-eez.zenithbar
domain=gui/$(id -u)
plist=$HOME/Library/LaunchAgents/$label.plist
binary=$HOME/.local/bin/zenithbar
log=$HOME/Library/Logs/zenithbar.log

stop() {
    launchctl bootout "$domain/$label" 2>/dev/null || true
    # A ZenithBar started by hand holds the Mach name the new one registers.
    pkill -x zenithbar 2>/dev/null || true
    # bootout can return before launchd lets the label go, and a bootstrap then fails with
    # "Input/output error", leaving no bar.
    for _ in {1..50}; do
        launchctl print "$domain/$label" >/dev/null 2>&1 || break
        sleep 0.1
    done
}

if [[ $mode == uninstall ]]; then
    stop
    rm -f "$plist" "$binary"
    echo "ZenithBar is stopped and removed; ~/.config/zenithbar stays."
    exit 0
fi

cd "$(dirname "$0")/.."
swift build -c release
mkdir -p "$(dirname "$binary")" "$(dirname "$plist")"
# Copied beside the old binary and renamed over it, so a running ZenithBar keeps its file.
cp "$(swift build -c release --show-bin-path)/zenithbar" "$binary.new"
mv -f "$binary.new" "$binary"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$binary</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- Plugins run under ZenithBar's environment, and launchd's PATH leaves out Homebrew. -->
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardErrorPath</key>
    <string>$log</string>
</dict>
</plist>
EOF

if [[ $mode == replace ]]; then
    brew services stop sketchybar >/dev/null 2>&1 || launchctl bootout "$domain/sh.brew.sketchybar" 2>/dev/null || true
fi
stop
launchctl bootstrap "$domain" "$plist"
echo "ZenithBar runs from $binary under the LaunchAgent $label; errors go to $log."
if pgrep -x sketchybar >/dev/null; then
    echo "SketchyBar is running too; script/install.sh --replace-sketchybar stops it for good."
elif [[ -f $HOME/Library/LaunchAgents/sh.brew.sketchybar.plist ]]; then
    echo "SketchyBar's LaunchAgent will start it at login; script/install.sh --replace-sketchybar stops that."
fi
