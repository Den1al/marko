#!/bin/bash
# Renders the window showing a file to a PNG, to look at it. Needs build/Marko.app (scripts/build-app.sh).
# With the Screen Recording permission for the terminal the PNG is the whole window, otherwise the page only.
# The app comes to the front for a moment, so that the caret and the selection are drawn, and quits by itself.
# Keys and clicks do not reach its window meanwhile, so the file is not changed by being photographed
# (MARKO_SWITCH, which types into the first file on purpose, excepted).
# A folder instead of a file gives the window with the file tree; MARKO_SIDEBAR=1 in the environment
# toggles the sidebar first, MARKO_SWITCH=<path> chooses that file in the tree, and MARKO_RENAME=<path>
# starts editing that item's name there. Also taken from the environment: MARKO_LINK=<destination>
# (follow that link; two tabs), MARKO_ZOOM=<factor>, MARKO_FULLWIDTH=1, MARKO_TRUST=ask (the trust
# question on the window) and MARKO_UNTITLED=1; Sources/MarkoApp/Smoke.swift has the whole list.
# The window is on the built-in display, which limits its height (900x1000 is cut to what fits).
# Fails when a key reached the document meanwhile, when no image was written, when the front did
# not go back to the app that had it, or when the window is not as wide as asked for.
# It takes the keyboard for under a second: not to be run unasked while someone is typing.
# usage: snapshot.sh <file.md|folder> <out.png> [light|dark] [<width>x<height>] [<caret offset>[,<selection length>]]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
file="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

size="${4:-900x1000}"
output="$(MARKO_SMOKE=1 MARKO_SNAPSHOT="$out" MARKO_APPEARANCE="${3:-light}" MARKO_SIZE="$size" \
    MARKO_CARET="${5:-0}" "$root/build/Marko.app/Contents/MacOS/Marko" "$file")"
grep "smoke: snapshot=" <<<"$output" || true
# The window is key while it is photographed; what is typed on the machine meanwhile must not get into the file.
grep -q "smoke: keysIgnored=true" <<<"$output" || { echo "snapshot: FAIL a key pressed meanwhile reached the document"; exit 1; }
[ -s "$out" ] || { echo "snapshot: FAIL no image written"; exit 1; }
# The app that was in front has the front again before this one ends; no line when this one never got it.
if grep -q "smoke: frontReturned=false" <<<"$output"; then echo "snapshot: FAIL the front did not go back to the app that had it"; exit 1; fi
# Seen: a window 756 points wide where another width was asked for. Its height is the display's to limit.
grep -q "smoke: shown=${size%x*}x" <<<"$output" || { echo "snapshot: FAIL the window is not ${size%x*} points wide: $(grep "smoke: shown=" <<<"$output")"; exit 1; }
# Another app took the keyboard meanwhile: the picture has no caret and a grey selection.
grep -q "smoke: shown=.* key=true" <<<"$output" || echo "snapshot: the window was not key"
