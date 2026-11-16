#!/bin/bash
# Launches build/Marko.app in smoke mode on a .md and a .markdown file (in safe mode, as any file
# on its own), on a folder (which a smoke run is not asked about), with the sidebar
# toggled, and through the system's open-document event; then installs the command-line tool into a
# temporary folder and runs scripts/smoke-cli.sh. The app quits by itself every time.
# Nothing is built here: run scripts/build-app.sh first (scripts/build-app.sh && scripts/smoke.sh),
# and do not build while this runs. The windows open on the built-in display: not with the lid closed.
# Ends with "smoke: OK"; about a minute.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/build/Marko.app/Contents/MacOS/Marko"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$root/Tests/Fixtures/crlf.md" "$work/a.md"
cp "$root/Tests/Fixtures/bom.md" "$work/b.markdown"
for file in "$work/a.md" "$work/b.markdown"; do
    output="$(MARKO_SMOKE=1 MARKO_LINK=b.markdown "$bin" "$file")"
    echo "$output"
    for expected in "textLayoutManager=true" "savesByteIdentical=true" "windowVisible=true" "tableCommands=10" "formatCommands=22" \
        "icon=true" "startedInDock=false" "active=false background=true" "documentURL=true" "restorable=true" "recent=true" "openRecentItems=1" "windowMenu=true" "documents=.*b.markdown" \
        "safeMode=true loadsRemoteImages=false question=false"; do
        grep -q "smoke: $expected" <<<"$output" || { echo "smoke: FAIL missing $expected for $file"; exit 1; }
    done
done
output="$(MARKO_SMOKE=1 MARKO_LINK=b.markdown "$bin" "$work/a.md")"
grep -q "smoke: documents=a.md,b.markdown" <<<"$output" || { echo "smoke: FAIL a link to a Markdown file did not open it"; exit 1; }
# Its window and the first one merge into one window with two tabs.
grep -q "smoke: tabs=2 tabBar=true" <<<"$output" || { echo "smoke: FAIL two windows did not merge into tabs"; exit 1; }

# A folder: a window with the file tree and no file, named after the folder, the keyboard in the
# tree; hidden files and junk are not listed. A file chosen in the tree is shown in that window.
mkdir -p "$work/proj/docs" "$work/proj/.git" "$work/proj/node_modules"
ln -s proj "$work/linkproj"
cp "$root/Tests/Fixtures/lf.md" "$work/proj/README.md"
cp "$root/Tests/Fixtures/tables.md" "$work/proj/docs/tables.md"
touch "$work/proj/notes.txt" "$work/proj/.hidden.md"
output="$(MARKO_SMOKE=1 MARKO_SWITCH="$work/proj/docs/tables.md" "$bin" "$work/proj")"
echo "$output"
for expected in "file=none" "title=proj\$" "windows=1 documents=0" "keyboard=tree" "sidebar=true" "root=$work/proj" "tree=docs,notes.txt,README.md" "selected=none" \
    "restorable=true" "recent=true" "startedInDock=false" "active=false background=true" "switched=tables.md" "sameWindow=true documentWindows=1" "safeMode=none loadsRemoteImages=false question=false" \
    "pane=880 columnLeft=50 columnRight=50 columnCentred=true" "tree=docs,tables.md,notes.txt,README.md" "selected=tables.md"; do
    grep -q "smoke: $expected" <<<"$output" || { echo "smoke: FAIL missing $expected for the folder"; exit 1; }
done
cmp -s "$root/Tests/Fixtures/lf.md" "$work/proj/README.md" || { echo "smoke: FAIL a file of the folder was changed by opening the folder"; exit 1; }

# A file with the tree beside it: an edit is saved when another file is chosen in the tree.
output="$(MARKO_SMOKE=1 MARKO_SIDEBAR=1 MARKO_SWITCH="$work/proj/docs/tables.md" "$bin" "$work/proj/README.md")"
grep -E "smoke: (file|switched|sameWindow|editKept|scrolledBy)" <<<"$output"
for expected in "file=$work/proj/README.md" "selected=README.md" "scrolledBy=0" "switched=tables.md" "sameWindow=true documentWindows=1" "editKept=true"; do
    grep -q "smoke: $expected" <<<"$output" || { echo "smoke: FAIL missing $expected for the file switched in the tree"; exit 1; }
done
cmp -s <(printf 'smoke ' | cat - "$root/Tests/Fixtures/lf.md") "$work/proj/README.md" \
    || { echo "smoke: FAIL the file left behind is not the original plus the edit"; exit 1; }

# A link to a folder opens the folder; a document without a file has no folder to show.
output="$(MARKO_SMOKE=1 "$bin" "$work/linkproj")"
grep -q "smoke: root=$work/proj\$" <<<"$output" && grep -q "smoke: tree=docs,notes.txt,README.md" <<<"$output" \
    || { echo "smoke: FAIL a link to a folder did not open it: $output"; exit 1; }
# So does a folder the system itself reaches through a link ("/etc" is "/private/etc").
output="$(MARKO_SMOKE=1 "$bin" /etc)"
for expected in "file=none" "title=etc\$" "windows=1 documents=0" "root=/etc\$" "sidebar=true"; do
    grep -q "smoke: $expected" <<<"$output" || { echo "smoke: FAIL /etc did not open as a folder: $output"; exit 1; }
done
output="$(MARKO_SMOKE=1 MARKO_UNTITLED=1 MARKO_SIDEBAR=1 "$bin")"
grep -E "smoke: (file|sidebar|root|tree)" <<<"$output"
for expected in "file=untitled" "sidebar=true" "root=none" "tree=\$"; do
    grep -q "smoke: $expected" <<<"$output" || { echo "smoke: FAIL missing $expected for an untitled document"; exit 1; }
done

# A link to a Markdown file is the file it leads to: the edit is written there and the window moves on.
mkdir -p "$work/links/docs"
printf 'real text\n' > "$work/links/docs/real.md"
printf 'other\n' > "$work/links/other.md"
ln -s docs/real.md "$work/links/README.md"
output="$(MARKO_SMOKE=1 MARKO_SIDEBAR=1 MARKO_SWITCH="$work/links/other.md" "$bin" "$work/links/README.md")"
grep -E "smoke: (file|switched|editKept)" <<<"$output"
for expected in "file=$work/links/docs/real.md" "switched=other.md" "editKept=true"; do
    grep -q "smoke: $expected" <<<"$output" || { echo "smoke: FAIL missing $expected for the link"; exit 1; }
done
[ -L "$work/links/README.md" ] && [ "$(cat "$work/links/docs/real.md")" = "smoke real text" ] \
    || { echo "smoke: FAIL the edit did not reach the file behind the link"; exit 1; }

# Named as the app's argument, a file or a folder is also the only window.
for item in "$work/a.md" "$work/proj"; do
    grep -q "smoke: windows=1 documents=$([ -d "$item" ] && echo 0 || echo 1)" <<<"$(MARKO_SMOKE=1 MARKO_UNTITLED=1 "$bin" "$item")" \
        || { echo "smoke: FAIL an empty window beside $item at launch"; exit 1; }
done

# A file alone has no sidebar; Command-B shows its folder beside it without moving the text.
grep -q "smoke: sidebar=false" <<<"$(MARKO_SMOKE=1 "$bin" "$work/a.md")" || { echo "smoke: FAIL a file opened with the sidebar"; exit 1; }
output="$(MARKO_SMOKE=1 MARKO_SIDEBAR=1 "$bin" "$work/a.md")"
grep -E "smoke: (sidebar|root|tree|selected|scrolledBy|pane)" <<<"$output"
for expected in "sidebar=true" "root=$work\$" "tree=linkproj,links,proj,a.md,b.markdown" "selected=a.md" "scrolledBy=0" "pane=.* columnCentred=true"; do
    grep -q "smoke: $expected" <<<"$output" || { echo "smoke: FAIL missing $expected after toggling the sidebar"; exit 1; }
done

# A file handed over by the system, as when it is dropped on the app's icon: no argument, an open-document event.
log="$work/opened.log"
open -n -g -W -a "$root/build/Marko.app" --env MARKO_SMOKE=1 --env MARKO_UNTITLED=1 --stdout "$log" "$work/a.md"
cat "$log"
grep -q "smoke: openedBy=event" "$log" && grep -q "smoke: windows=1 documents=1" "$log" \
    || { echo "smoke: FAIL the app did not open the file it was handed, in its only window"; exit 1; }
# Started by the system as an app with a Dock icon, it is still one that cannot take the front.
grep -q "smoke: active=false background=true" "$log" || { echo "smoke: FAIL the app the system started can take the front"; exit 1; }
# And a folder handed over the same way, as when it is dropped on the icon or named on the command line.
# Allowed its empty window as outside a smoke run, the app still starts with the folder's alone.
log="$work/opened-folder.log"
open -n -g -W -a "$root/build/Marko.app" --env MARKO_SMOKE=1 --env MARKO_UNTITLED=1 --stdout "$log" "$work/proj"
grep -E "smoke: (file|openedBy|sidebar|root)" "$log"
grep -q "smoke: openedBy=event" "$log" && grep -q "smoke: root=.*/proj\$" "$log" && grep -q "smoke: sidebar=true" "$log" \
    && grep -q "smoke: file=none" "$log" && grep -q "smoke: windows=1 documents=0" "$log" \
    || { echo "smoke: FAIL the app did not open the folder it was handed, alone and without a file"; exit 1; }

# The command-line tool is put on the PATH as a link, by the script and by the app's menu item, which
# runs the copy of the script inside the app. Only ever into a folder made here.
tool="$(cd "$root/build/Marko.app/Contents/Helpers" && pwd -P)/marko"
mkdir "$work/bin" "$work/bin2"
"$root/scripts/install-cli.sh" "$work/bin"
[ "$(readlink "$work/bin/marko")" = "$tool" ] && [ "$("$work/bin/marko" --version)" = "$("$tool" --version)" ] \
    || { echo "smoke: FAIL the installed link does not start the tool"; exit 1; }
grep -q "already points to" <<<"$("$root/scripts/install-cli.sh" "$work/bin")" || { echo "smoke: FAIL installing twice"; exit 1; }
# Run without a terminal, as by the app's menu item, it still says when the shell will not find the link.
grep -q "$work/bin is not on your PATH" <<<"$("$root/scripts/install-cli.sh" "$work/bin" </dev/null)" || { echo "smoke: FAIL no hint about the PATH"; exit 1; }
grep -q "is not on your PATH" <<<"$(PATH="$work/bin:$PATH" "$root/scripts/install-cli.sh" "$work/bin" </dev/null)" && { echo "smoke: FAIL a hint about a folder that is on the PATH"; exit 1; }
"$root/scripts/install-cli.sh" --uninstall "$work/bin"
[ ! -e "$work/bin/marko" ] && "$root/scripts/install-cli.sh" --uninstall "$work/bin" | grep -q "no marko link" \
    || { echo "smoke: FAIL uninstalling"; exit 1; }
touch "$work/bin/marko"
if "$root/scripts/install-cli.sh" "$work/bin" 2>/dev/null || [ -L "$work/bin/marko" ]; then echo "smoke: FAIL a file named marko was replaced"; exit 1; fi
ln -sf /usr/bin/true "$work/bin/marko"
if "$root/scripts/install-cli.sh" "$work/bin" 2>/dev/null || [ "$(readlink "$work/bin/marko")" != /usr/bin/true ]; then echo "smoke: FAIL another tool's marko link was replaced"; exit 1; fi
output="$(MARKO_SMOKE=1 MARKO_INSTALL="$work/bin2" "$bin" "$work/a.md")"
grep -E "smoke: install" <<<"$output"
grep -q "smoke: installItem=true" <<<"$output" && grep -q "smoke: installed=true $work/bin2/marko now points to $tool" <<<"$output" \
    && [ "$(readlink "$work/bin2/marko")" = "$tool" ] || { echo "smoke: FAIL the app did not install the tool"; exit 1; }

"$root/scripts/smoke-cli.sh"
echo "smoke: OK"
