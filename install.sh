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
# kv is the short name; a kv that is not ours stays.
if [[ ! -e $BIN_DIR/kv && ! -L $BIN_DIR/kv || $(readlink "$BIN_DIR/kv") == "$APP/Contents/Resources/kyvia" ]]; then
    ln -sf "$APP/Contents/Resources/kyvia" "$BIN_DIR/kv"
else
    echo "kyvia: $BIN_DIR/kv is something else, kept it; use the kyvia command" >&2
fi
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
# The first launch of a downloaded build takes a few seconds; wait so "try it" below works at once.
for _ in {1..100}; do curl -s -o /dev/null http://127.0.0.1:47321/ && break; sleep 0.1; done

echo "kyvia installed: $APP, starts at login"
try="kyvia -t success 'Hello' 'kyvia is running'"
case ":$PATH:" in *":$BIN_DIR:"*) echo "try it: $try"; exit 0 ;; esac

# A stock macOS PATH lacks ~/.local/bin. uninstall.sh removes the lines marked "added by kyvia".
# shellcheck disable=SC2016 # $HOME and $PATH expand when the shell reads the line
line='export PATH="$HOME/.local/bin:$PATH" # added by kyvia'
case ${SHELL##*/} in
    zsh) rc=${ZDOTDIR:-$HOME}/.zshrc ;;
    bash)
        # bash reads only the first of these, so a new .bash_profile would hide an existing .profile.
        rc=$HOME/.bash_profile
        for f in .bash_profile .bash_login .profile; do [[ -e $HOME/$f ]] && { rc=$HOME/$f; break; }; done ;;
    fish)
        rc=$HOME/.config/fish/conf.d/kyvia.fish
        # shellcheck disable=SC2016
        line='fish_add_path $HOME/.local/bin # added by kyvia' ;;
    *) echo "add $BIN_DIR to your PATH to use the kyvia command"; exit 0 ;;
esac
if ! grep -qs '# added by kyvia$' "$rc"; then
    mkdir -p "$(dirname "$rc")"
    # shortcut: an rc without a final newline gets one, which uninstall leaves behind
    if [[ -s $rc && -n $(tail -c1 "$rc") ]]; then echo >> "$rc"; fi
    echo "$line" >> "$rc"
fi
echo "added $BIN_DIR to PATH in $rc; open a new terminal and try it: $try"
