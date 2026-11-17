#!/bin/sh
set -eu
cd "$(dirname "$0")"
cargo build --release "$@"
app="dist/BreakCue.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp target/release/breakcue "$app/Contents/MacOS/breakcue"
cp macos/Info.plist "$app/Contents/Info.plist"
cp settings.toml "$app/Contents/Resources/settings.toml"
cp assets/BreakCue.icns "$app/Contents/Resources/BreakCue.icns"
codesign --force --sign - "$app"
staging=$(mktemp -d)
mountpoint=$(mktemp -d)
rw_image="$staging.rw.dmg"
trap 'hdiutil detach "$mountpoint" >/dev/null 2>&1 || true; rm -rf "$staging" "$mountpoint" "$rw_image"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
cp assets/BreakCue.icns "$staging/.VolumeIcon.icns"
hdiutil create -volname "BreakCue" -srcfolder "$staging" -format UDRW -ov "$rw_image"
hdiutil attach -nobrowse -mountpoint "$mountpoint" "$rw_image"
SetFile -a C "$mountpoint"
hdiutil detach "$mountpoint"
hdiutil convert "$rw_image" -format UDZO -ov -o "dist/BreakCue.dmg"
echo "Built $PWD/$app and $PWD/dist/BreakCue.dmg"
