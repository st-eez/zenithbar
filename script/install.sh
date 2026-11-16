#!/usr/bin/env bash
# Builds ZenithBar from this checkout into a signed ZenithBar.app, installs it to /Applications
# and runs it from a LaunchAgent that starts it at login and again whenever it exits
# unsuccessfully; after three quick exits in a row ZenithBar exits successfully, which ends a
# crash loop (docs/overview.md, install). Location Services prompts for and remembers a signed
# bundle, and asked nothing of the bare executable this installed before (docs/network.md).
#
# Signing uses ZENITHBAR_SIGN_IDENTITY, or the first Apple Development certificate in the
# keychain, as Kosmos's script/bundle.sh does. Keep using the same certificate: the Location
# Services grant is tied to it.
#
#   script/install.sh [--replace-sketchybar | --uninstall]
#
# --replace-sketchybar also stops SketchyBar's Homebrew service, so it no longer starts at
# login; `brew services start sketchybar` brings it back. --uninstall stops ZenithBar and removes
# its LaunchAgent and app, leaving ~/.config/zenithbar.
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
app=/Applications/ZenithBar.app
binary=$app/Contents/MacOS/zenithbar
# Where earlier installs put the bare executable.
old_binary=$HOME/.local/bin/zenithbar
# ZenithBar's count of quick launches in a row (LaunchGuard), cleared so a new install starts.
quick_launches="$HOME/Library/Application Support/ZenithBar/quick-launches"
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
    rm -rf "$plist" "$app" "$old_binary" "$(dirname "$quick_launches")"
    echo "ZenithBar is stopped and removed; ~/.config/zenithbar stays."
    exit 0
fi

cd "$(dirname "$0")/.."
identity=${ZENITHBAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')}
if [[ -z $identity ]]; then
    echo "No signing certificate found. Set ZENITHBAR_SIGN_IDENTITY." >&2
    exit 1
fi
swift build -c release
built=.build/dist/ZenithBar.app
rm -rf "$built"
mkdir -p "$built/Contents/MacOS" "$(dirname "$plist")"
cp Resources/Info.plist "$built/Contents/Info.plist"
cp "$(swift build -c release --show-bin-path)/zenithbar" "$built/Contents/MacOS/zenithbar"
codesign --force --options runtime --timestamp=none --entitlements Resources/ZenithBar.entitlements \
    --sign "$identity" "$built"
codesign --verify --strict "$built"
# Copied beside the installed app without the .app extension, so LaunchServices never
# registers the copy, then renamed over it once ZenithBar stops, as Kosmos's install does.
stage=/Applications/.ZenithBar-install
rm -rf "$stage"
ditto "$built" "$stage"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <!-- Login Items names the job ZenithBar by this, not the certificate's developer name. -->
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$label</string>
    </array>
    <key>ProgramArguments</key>
    <array>
        <string>$binary</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restarted after a crash or an exit with an error, not after ZenithBar ends a crash loop. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
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
rm -rf "$app" "$old_binary" "$quick_launches"
mv "$stage" "$app"
launchctl bootstrap "$domain" "$plist"
echo "ZenithBar runs from $app, signed by $identity, under the LaunchAgent $label; errors go to $log."
if pgrep -x sketchybar >/dev/null; then
    echo "SketchyBar is running too; script/install.sh --replace-sketchybar stops it for good."
elif [[ -f $HOME/Library/LaunchAgents/sh.brew.sketchybar.plist ]]; then
    echo "SketchyBar's LaunchAgent will start it at login; script/install.sh --replace-sketchybar stops that."
fi
