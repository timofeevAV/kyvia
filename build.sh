#!/bin/bash
# Build Kyvia.app and install it with install.sh (--no-install: build only). Run after any change.
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/Kyvia.app"
LABEL=io.github.timofeevav.kyvia

(cd web && npm install --silent && npx esbuild main.jsx --bundle --minify --jsx=automatic \
    --define:process.env.NODE_ENV='"production"' --outfile=dist/app.js)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp web/index.html web/dist/app.js bin/kyvia LICENSE THIRD_PARTY_NOTICES "$APP/Contents/Resources/"
# Universal binary; macOS 11 is the oldest release with every API the app calls.
BIN=$(mktemp -d)
for arch in arm64 x86_64; do swiftc -O -target $arch-apple-macos11 Notifier.swift -o "$BIN/$arch"; done
lipo -create "$BIN/arm64" "$BIN/x86_64" -output "$APP/Contents/MacOS/Kyvia"
rm -rf "$BIN"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Kyvia</string>
  <key>CFBundleExecutable</key><string>Kyvia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"

[[ ${1:-} == --no-install ]] || ./install.sh "$APP"
