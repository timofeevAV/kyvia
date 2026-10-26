#!/bin/bash
# Remove kyvia: curl -fsSL https://raw.githubusercontent.com/timofeevAV/kyvia/main/uninstall.sh | bash
set -euo pipefail
# local.sileo-notifier is the pre-release build.
for label in io.github.timofeevav.kyvia local.sileo-notifier; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "$HOME/Applications/Kyvia.app"
rm -f "$HOME/.local/bin/kyvia"
defaults delete io.github.timofeevav.kyvia 2>/dev/null || true
echo "kyvia removed"
