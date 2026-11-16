#!/bin/sh
set -eu
cd "$(dirname "$0")"
cargo build --release "$@"
app="dist/BreakCue.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp target/release/breakcue "$app/Contents/MacOS/breakcue"
cp macos/Info.plist "$app/Contents/Info.plist"
cp settings.toml "$app/Contents/Resources/settings.toml"
codesign --force --sign - "$app"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "BreakCue" -srcfolder "$staging" -format UDZO -ov "dist/BreakCue.dmg"
echo "Built $PWD/$app and $PWD/dist/BreakCue.dmg"
