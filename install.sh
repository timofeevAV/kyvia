#!/bin/bash
# Install kyvia: curl -fsSL https://raw.githubusercontent.com/timofeevAV/kyvia/main/install.sh | bash
# Given the path of a built Kyvia.app (build.sh passes one), installs it instead of the latest release.
set -euo pipefail
LABEL=io.github.timofeevav.kyvia
APP="$HOME/Applications/Kyvia.app"
BIN_DIR="$HOME/.local/bin"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

[[ $(uname) == Darwin ]] || { echo "kyvia: macOS only" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ $# -ge 1 ]]; then
    src=$1
else
    curl -fsSL https://github.com/timofeevAV/kyvia/releases/latest/download/Kyvia.zip -o "$tmp/Kyvia.zip"
    ditto -x -k "$tmp/Kyvia.zip" "$tmp"
    src="$tmp/Kyvia.app"
fi
[[ -x $src/Contents/MacOS/Kyvia ]] || { echo "kyvia: no app at $src" >&2; exit 1; }

# bootout returns before the job is gone, and a bootstrap meanwhile fails with error 5.
unload() {
    launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
    while launchctl print "$DOMAIN/$1" >/dev/null 2>&1; do sleep 0.1; done
}
# local.sileo-notifier is the pre-release build; it holds the same port.
unload local.sileo-notifier
rm -f "$HOME/Library/LaunchAgents/local.sileo-notifier.plist"
unload $LABEL

mkdir -p "$HOME/Applications" "$BIN_DIR" "$(dirname "$AGENT")"
rm -rf "$APP"
ditto "$src" "$APP"
ln -sf "$APP/Contents/Resources/kyvia" "$BIN_DIR/kyvia"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Kyvia</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "$DOMAIN" "$AGENT"

echo "kyvia installed: $APP, starts at login"
case ":$PATH:" in
    *":$BIN_DIR:"*) echo "try it: kyvia -t success 'Hello' 'kyvia is running'" ;;
    *) echo "add $BIN_DIR to your PATH to use the kyvia command" ;;
esac
