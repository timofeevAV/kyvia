# kyvia

kyvia watches your agents work, so you don't have to.

A small macOS menu-bar app that shows toasts in the top-right corner of the screen when a
script, a build or a coding agent wants your attention. Toasts are drawn with
[sileo](https://github.com/hiaaryan/sileo) and float above every window without taking focus.
Click a toast to get back to where it came from: the app that sent it and, in VS Code, the
window with that folder. Clicks next to a toast pass through. The bell in the menu bar keeps the
last 20; click one to go back there too.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/timofeevAV/kyvia/main/install.sh | bash
```

This puts `Kyvia.app` in `~/Applications`, the `kyvia` command in `~/.local/bin`, and a
LaunchAgent that starts kyvia at login and restarts it if it quits. If `~/.local/bin` is not
on your PATH, it adds one line marked `# added by kyvia` to `~/.zshrc` or your bash profile
(fish: `~/.config/fish/conf.d/kyvia.fish`); open a new terminal afterwards. The uninstaller
removes that line.

Or with Homebrew (use one of the two: both run kyvia on port 47321, and a second copy
quits at start):

```sh
brew install timofeevAV/tap/kyvia
brew services start kyvia
```

Requires macOS 11 or later, Apple Silicon or Intel.

## Use

```sh
kyvia "Build finished"
kyvia -t success "Deploy" "api is live on staging"
kyvia -t error -d 15000 "Tests failed" "3 of 120 failed"
```

`-t` is one of `success`, `error`, `warning`, `info` (default) and `action`; `-d` is how long
the toast stays, in milliseconds (default 6000). A description may span several lines. `kyvia`
exits with 1 when the app is not running and 2 on wrong arguments. `kv` is the same command,
shorter: `kv "Build finished"`.

The menu-bar bell also has **Sound** (a chime on each new toast) and **Clear**.

### Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "kyvia -t success \"${CLAUDE_PROJECT_DIR##*/}\" 'Done'" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "kyvia -t action \"${CLAUDE_PROJECT_DIR##*/}\" 'Waiting for you'" }] }
    ]
  }
}
```

### HTTP

kyvia listens on `127.0.0.1:47321`, so anything that can make an HTTP request can raise a toast:

```sh
curl -H 'X-Kyvia: 1' -d '{"type":"success","title":"Done","description":"all good","duration":8000}' \
  http://127.0.0.1:47321/notify
```

Every field is optional; strings are cut at 500 characters. `app` is the bundle id of the app a
click on the toast brings forward if it is running (`kyvia` sends `$__CFBundleIdentifier`, the app
it runs in), and `path` is the directory the toast is about (`kyvia` sends `$PWD`): VS Code then
focuses the window whose folder holds it. The answer is `204` on success,
`400` for a malformed body and `403` without the `X-Kyvia: 1` header. The header keeps web
pages out: a browser cannot send a custom header cross-origin without a CORS preflight, and
kyvia never answers one.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/timofeevAV/kyvia/main/uninstall.sh | bash
```

With Homebrew: `brew services stop kyvia && brew uninstall kyvia`.

## Build from source

Needs the Xcode command line tools and Node.js.

```sh
./build.sh               # build Kyvia.app and install it like install.sh does
./build.sh --no-install  # build only
test/smoke.sh            # start the built app and check the HTTP API and the CLI (port 47321 must be free)
```

The app is ad-hoc signed, not notarized. `curl` does not mark downloads as quarantined, so
Gatekeeper lets it run.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party code is listed in
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
