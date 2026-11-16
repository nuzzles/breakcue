#!/bin/sh
set -eu
cd "$(dirname "$0")"
cargo build --release "$@"
app="dist/screen_doctor.app"
mkdir -p "$app/Contents/MacOS"
cp target/release/screen_doctor "$app/Contents/MacOS/screen_doctor"
cp macos/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built $PWD/$app"
