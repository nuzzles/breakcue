#!/bin/sh
set -eu
cd "$(dirname "$0")"
cargo build --release "$@"
app="dist/screen_doctor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp target/release/screen_doctor "$app/Contents/MacOS/screen_doctor"
cp macos/Info.plist "$app/Contents/Info.plist"
cp settings.toml "$app/Contents/Resources/settings.toml"
codesign --force --sign - "$app"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "screen_doctor" -srcfolder "$staging" -format UDZO -ov "dist/screen_doctor.dmg"
echo "Built $PWD/$app and $PWD/dist/screen_doctor.dmg"
