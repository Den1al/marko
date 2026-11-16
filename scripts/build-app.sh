#!/bin/bash
# Assembles build/Marko.app from the SwiftPM executable targets: the app and its command-line tool.
# usage: build-app.sh [release|debug]     (release when nothing is given)
# The bundle is removed and made again every time, and signed ad hoc. A `marko` link installed from
# the repository (scripts/install-cli.sh) points into it: it is missing while the bundle is put
# together and stays missing when that fails (a compile error leaves the old bundle in place).
# scripts/smoke.sh runs this bundle too, so not during a smoke run.
# The icon is only drawn again when scripts/make-icon.swift is newer than build/icon/Marko.icns.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-release}"
app="$root/build/Marko.app"

swift build --package-path "$root" -c "$config" --product MarkoApp
swift build --package-path "$root" -c "$config" --product MarkoCLI
bin="$(swift build --package-path "$root" -c "$config" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
# The icon is drawn by a script; it is made again when the script changes.
icon="$root/build/icon/Marko.icns"
if [ ! -f "$icon" ] || [ "$root/scripts/make-icon.swift" -nt "$icon" ]; then
    mkdir -p "$(dirname "$icon")"
    swift "$root/scripts/make-icon.swift" "$icon"
fi
cp "$icon" "$app/Contents/Resources/Marko.icns"
cp "$bin/MarkoApp" "$app/Contents/MacOS/Marko"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
# The command-line tool, and the script that links it into the PATH ("Install Command Line Tool…").
cp "$bin/MarkoCLI" "$app/Contents/Helpers/marko"
cp "$root/scripts/install-cli.sh" "$app/Contents/Resources/install-cli.sh"
# The licences of what is linked into the executable go wherever the app goes.
cp "$root/THIRD-PARTY-NOTICES.txt" "$app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
codesign --force --sign - --identifier local.marko.cli "$app/Contents/Helpers/marko"
codesign --force --sign - "$app"

echo "$app"
