#!/bin/bash
# Links the marko command-line tool of Marko.app into a folder on the PATH, or takes the link away.
# The app's "Install Command Line Tool…" runs the copy of this script inside the app.
# usage: install-cli.sh [--uninstall] [folder]
#   Without a folder: the first of ~/.local/bin and /usr/local/bin that exists, can be written and
#   is on the PATH; if neither is on it, the first that exists and can be written.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# Inside the app the tool is next door; in the repository it is in the app that was built.
tool="$here/../Helpers/marko"
[ -x "$tool" ] || tool="$here/../build/Marko.app/Contents/Helpers/marko"
[ -x "$tool" ] || { echo "install-cli: there is no marko tool yet; run scripts/build-app.sh" >&2; exit 1; }
tool="$(cd "$(dirname "$tool")" && pwd -P)/marko"

uninstall=false
folder=""
for argument in "$@"; do
    case "$argument" in
        --uninstall) uninstall=true ;;
        -*) echo "usage: install-cli.sh [--uninstall] [folder]" >&2; exit 2 ;;
        *) folder="${argument%/}" ;;
    esac
done

# The PATH that "marko" will be looked up in. Run by the app (no terminal), that is not this
# script's, which is the system's bare one: the login shell is asked for its own.
path="$PATH"
[ -t 1 ] || path="$path:$("${SHELL:-/bin/zsh}" -lc 'printf %s "$PATH"' 2>/dev/null </dev/null || true)"
on_path() { [[ ":$path:" == *":$1:"* ]]; }

if [ -z "$folder" ]; then
    for candidate in "$HOME/.local/bin" /usr/local/bin; do
        if $uninstall; then
            [ -L "$candidate/marko" ] && { folder="$candidate"; break; }
        elif [ -d "$candidate" ] && [ -w "$candidate" ]; then
            # A folder on the PATH is taken before one that is not.
            if on_path "$candidate"; then folder="$candidate"; break; fi
            [ -n "$folder" ] || folder="$candidate"
        fi
    done
    if [ -z "$folder" ]; then
        $uninstall && { echo "There is no marko link in ~/.local/bin or /usr/local/bin."; exit 0; }
        echo "install-cli: neither ~/.local/bin nor /usr/local/bin exists and can be written." >&2
        echo "Make one of them (mkdir -p ~/.local/bin) or name a folder that is on your PATH." >&2
        exit 1
    fi
fi
link="$folder/marko"

if $uninstall; then
    if [ ! -L "$link" ]; then
        [ -e "$link" ] && { echo "install-cli: $link is not a link; left alone." >&2; exit 1; }
        echo "There is no marko link in $folder."
    elif [[ "$(readlink "$link")" != */Contents/Helpers/marko ]]; then
        echo "install-cli: $link does not point into a Marko.app; left alone." >&2
        exit 1
    else
        rm "$link"
        echo "Removed $link."
    fi
    exit 0
fi

[ -d "$folder" ] && [ -w "$folder" ] || { echo "install-cli: $folder is not a folder that can be written." >&2; exit 1; }
if [ -L "$link" ] && [ "$(readlink "$link")" = "$tool" ]; then
    echo "$link already points to $tool."
elif [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "install-cli: $link exists and is not a link; left alone." >&2
    exit 1
elif [ -L "$link" ] && [[ "$(readlink "$link")" != */Contents/Helpers/marko ]]; then
    # Another tool's command of the same name, such as the Python package "marko" linked by pipx.
    echo "install-cli: $link points to $(readlink "$link"), which is not Marko's; left alone." >&2
    exit 1
else
    ln -sfn "$tool" "$link"
    echo "$link now points to $tool."
fi
# Also said through the app's menu item: a link the shell does not find is not an installed tool.
if ! on_path "$folder"; then
    echo "$folder is not on your PATH; add it to use \"marko\" by name."
fi
