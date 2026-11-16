#!/bin/bash
# Starts a copy of build/Marko.app that can be driven with scripts/drive/drive.swift without
# touching the user's Marko, settings, display or keyboard (the copy does not come to the front by
# itself: `front` and `hide` of the driver do that), and prints its pid. A NORMAL launch (menus,
# restoration, recent documents, autosaved frames), not a smoke run. See docs/development.md,
# "A normal launch, driven", for what this does not keep away from the user.
#
# usage: launch.sh <work folder> <seconds to live> [app arguments...]
#   <work folder>: an empty folder of the caller's (mktemp -d), also used for the next launches of
#   the same run (quit and relaunch restores windows). End the last launch with Marko > Quit and
#   Close All Windows (the saved windows are not in the work folder), remove the folder
#   afterwards, and `defaults delete local.marko.drive`. Also left outside the work folder, to
#   remove: the copy's LaunchServices entry (`lsregister -u <work folder>/Marko.app`, before the
#   folder goes), ~/Library/Caches/local.marko.drive, ~/Library/HTTPStorages/local.marko.drive,
#   its recent-documents list (local.marko.drive.sfl4 under
#   ~/Library/Application Support/com.apple.sharedfilelist) and $TMPDIR/local.marko.drive.savedState.
#   The app is copied into the work folder ONCE: after a new build, remove <work folder>/Marko.app
#   or the old app is driven. The copy shows a Dock icon named Marko while it runs, and a file it
#   moves to the Trash goes to the user's Trash.
#   "-ApplePersistenceIgnoreState YES" as app arguments starts without the windows of the last run.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(cd "$1" && pwd -P)"
life="$2"
shift 2
out="$root/build/drive"
mkdir -p "$out"
[ "$out/drive" -nt "$root/scripts/drive/drive.swift" ] || swiftc -O -o "$out/drive" "$root/scripts/drive/drive.swift"
[ "$out/pin.dylib" -nt "$root/scripts/drive/pin.m" ] || clang -dynamiclib -fobjc-arc -framework AppKit -o "$out/pin.dylib" "$root/scripts/drive/pin.m"

if [ ! -d "$work/Marko.app" ]; then
    # A bundle identifier of its own: its own settings, recent documents and saved windows.
    cp -R "$root/build/Marko.app" "$work/Marko.app"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.marko.drive' "$work/Marko.app/Contents/Info.plist"
    codesign --force --sign - --identifier local.marko.cli "$work/Marko.app/Contents/Helpers/marko" 2>/dev/null
    codesign --force --sign - "$work/Marko.app" 2>/dev/null
    mkdir -p "$work/home/.local/bin"
fi
# A home of its own, first on the PATH: "Install Command Line Tool…" links into it, not into the user's.
export HOME="$work/home" CFFIXED_USER_HOME="$work/home" MARKO_SOCKET="$work/socket" PATH="$work/home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset MARKO_SMOKE MARKO_SERVE MARKO_CLI MARKO_FILE MARKO_PERF
# MEASURED: not through nohup or any other program of the system, which drops DYLD_INSERT_LIBRARIES.
DYLD_INSERT_LIBRARIES="$out/pin.dylib" "$work/Marko.app/Contents/MacOS/Marko" "$@" >"$work/app.out" 2>&1 &
pid=$!
# Ended after its time. The timer goes with the app: a blind `sleep` outlived an app that had
# quit and would then have signalled whatever process had its pid by then.
( for _ in $(seq "$life"); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 1; done; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
# Windows that were anywhere but on the built-in display are in this log when the app has ended.
"$out/drive" watch "$pid" "$work/watch.$pid.log" >/dev/null 2>&1 &
# The pin says so before the app's own code runs; an app without it is ended at once.
for _ in $(seq 50); do
    grep -q "pin: installed" "$work/app.out" 2>/dev/null && { echo "$pid"; exit 0; }
    sleep 0.02
done
kill "$pid" 2>/dev/null
echo "launch: the app started without the window pin and was ended" >&2
exit 1
