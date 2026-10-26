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
if [[ $(readlink "$HOME/.local/bin/kv") == "$HOME/Applications/Kyvia.app/Contents/Resources/kyvia" ]]; then
    rm -f "$HOME/.local/bin/kv"
fi
defaults delete io.github.timofeevav.kyvia 2>/dev/null || true
# Drop only the PATH lines install.sh added; cat > keeps a symlinked rc a symlink, sed -i would not.
for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if grep -qs '# added by kyvia$' "$rc"; then
        kept=$(mktemp)
        grep -v '# added by kyvia$' "$rc" > "$kept" || true
        cat "$kept" > "$rc"
        rm -f "$kept"
    fi
done
rm -f "$HOME/.config/fish/conf.d/kyvia.fish"
echo "kyvia removed"
