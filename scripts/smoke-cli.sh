#!/bin/bash
# Runs the marko command-line tool of build/Marko.app against the app in its serving smoke mode: an
# instance of its own on a socket of its own, which writes to a log what every request left open.
# Covers: starting the app, reusing the running one, files, line numbers, a relative path, several
# paths, a file that does not exist yet, a folder (which shows no file), a link, piped text, --wait,
# git's editor, an empty window taken over by what is opened next, safe mode and --trust/--safe
# (against a listener on this Mac that counts what connects to it), what the tool refuses, five tools
# starting the app at once (ten rounds), the app going away under --wait, and the app started for a file.
# Also fails when `marko file.md` with the app running takes more than 40 ms in the median of 20
# runs, and when any instance was ever the frontmost app ("active=false background=true").
# Needs build/Marko.app as it is now (nothing is built here), the built-in display, perl and git.
# Run by scripts/smoke.sh, and can be run by itself.
# The instances are ended here; left alone they end themselves after a minute.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cli="$root/build/Marko.app/Contents/Helpers/marko"
work="$(cd "$(mktemp -d)" && pwd -P)"
log="$work/serve.log"
# Every instance that was started, by the lines of the logs.
started() { sed -n 's/^serve: started pid=//p' "$work"/*.log 2>/dev/null; }
listener=""
# The piped text of step 5 is a document without a file, unsaved when its instance is ended here:
# AppKit keeps such text for the next launch, for a smoke run in the temporary folder. MEASURED:
# one "Unsaved Marko Document <n>.md" was left there by every run.
kept="$(getconf DARWIN_USER_TEMP_DIR)Autosave Information"
stop() {
    kill $(started) $listener 2>/dev/null || true
    find "$kept" -name 'Unsaved Marko Document*.md' -newer "$work/a.md" \
        -exec sh -c 'printf "# piped\n" | cmp -s - "$1" && rm -f "$1"' _ {} \; 2>/dev/null || true
    chmod -R u+rwx "$work" 2>/dev/null || true
    rm -rf "$work"
}
trap stop EXIT
fail() { echo "smoke-cli: FAIL $*"; [ -f "$log" ] && cat "$log"; exit 1; }

# The log line of request number $1, which is written a second after the request.
served() {
    for _ in $(seq 100); do
        grep "^serve: request=$1 " "$log" 2>/dev/null && return
        sleep 0.1
    done
    fail "request $1 never showed up"
}
# expect <line> <pattern>...: every pattern is in the line.
expect() {
    local line="$1" pattern
    shift
    for pattern in "$@"; do grep -Eq -- "$pattern" <<<"$line" || fail "expected $pattern in: $line"; done
}

cp "$root/Tests/Fixtures/lf.md" "$work/a.md"
cp "$root/Tests/Fixtures/bom.md" "$work/b.markdown"
mkdir -p "$work/proj/docs"
cp "$root/Tests/Fixtures/lf.md" "$work/proj/README.md"
cp "$root/Tests/Fixtures/tables.md" "$work/proj/docs/tables.md"
ln -s a.md "$work/link.md"

# What needs no app: help, the version, a wrong option, a file in a folder that is not there.
"$cli" --help | grep -q "^usage: marko" || fail "--help"
[ "$("$cli" --version)" = "marko $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Support/Info.plist")" ] || fail "--version"
status=0; "$cli" --bogus 2>"$work/err" || status=$?
[ "$status" = 2 ] && grep -q "marko: unknown option --bogus" "$work/err" || fail "a wrong option: status $status"
export MARKO_SMOKE=1 MARKO_SERVE="$log" MARKO_SOCKET="$work/socket"
# refused <what it is> <message> <arguments>...: the tool says why, fails, and starts no app.
refused() {
    local what="$1" message="$2" status=0
    shift 2
    "$cli" "$@" 2>"$work/err" </dev/null || status=$?
    [ "$status" = 1 ] && grep -q "marko: .*$message" "$work/err" || fail "$what: status $status, $(cat "$work/err")"
    [ ! -e "$log" ] || fail "$what: the app was started for what cannot be opened"
}
mkdir "$work/locked" "$work/gone"
echo x > "$work/locked/x.md"
chmod 000 "$work/locked"
refused "a file in a missing folder" "missing/x.md: there is no folder" "$work/missing/x.md"
refused "an empty path" "an empty path" ""
refused "a file in a folder that may not be read" "locked/x.md: the folder .* may not be read" "$work/a.md" "$work/locked/x.md"
refused "a folder that may not be read" "locked: the folder may not be read" "$work/locked"
refused "a pipe of the shell" "neither a file nor a folder" <(echo hi)
(cd "$work/gone" && rmdir "$work/gone" && refused "a relative path in a folder that is gone" "x.md: the current folder no longer exists" x.md)
status=0; printf 'ok\xff\xfe' | "$cli" - 2>"$work/err" || status=$?
[ "$status" = 1 ] && grep -q "marko: the piped text is not UTF-8" "$work/err" && [ ! -e "$log" ] || fail "piped text that is not UTF-8: status $status"
chmod 755 "$work/locked"

# 1. Not running: the tool starts the app, through a link to itself, and the file opens at the line.
ln -s "$cli" "$work/marko"
# With a column after the line, as compilers and grep print it.
"$work/marko" "$work/a.md:3:7"
expect "$(served 1)" "documents=a.md@3\+[0-9]+ folders= windows=1$"

# 2. Running: the same instance takes a path relative to another folder; the open file stays.
(cd "$work/proj" && "$cli" docs/tables.md)
expect "$(served 2)" "documents=a.md@3\+[0-9]+,tables.md@1\+"

# 3. Several paths: a file that is open (through a link, at another line), a .markdown file, and one
# that does not exist yet, which is a document but no file.
"$cli" +5 "$work/link.md" "$work/b.markdown" "$work/new.md"
expect "$(served 3)" "documents=a.md@5\+[0-9]+,b.markdown@1\+[0-9]+,new.md@1\+0,tables.md@1\+"
[ ! -e "$work/new.md" ] || fail "a file that was only opened exists"

# 4. A folder gets a window with the tree and none of its files: the four documents are the ones
# that were open, and the fifth window is the folder's.
"$cli" "$work/proj"
line="$(served 4)"
expect "$line" "documents=a.md@5\+[0-9]+,b.markdown@1\+[0-9]+,new.md@1\+0,tables.md@1\+[0-9]+ folders=proj windows=5$"
grep -q "README" <<<"$line" && fail "a folder was opened on a file of it: $line"

# 5. Piped text is a new document.
printf '# piped\n' | "$cli" -
expect "$(served 5)" "[=,]Untitled[^,]*@1\+8[, ]"

# 6. --wait returns when the window has been closed, not before; the app has typed into the document
# by then, which made the file.
"$cli" --wait "$work/fresh.md"
grep -q "^serve: closing=6" "$log" || fail "--wait returned before the window was closed"
[ "$(cat "$work/fresh.md")" = "smoke edit" ] || fail "the new file was not written: $(cat "$work/fresh.md" 2>&1)"
# An existing file, eight at once: when the tool returns the edit is in the file and no backup is beside it.
mkdir "$work/wait"
for n in 1 2 3 4 5 6 7 8; do echo x > "$work/wait/p$n.md"; done
for n in 1 2 3 4 5 6 7 8; do
    ( "$cli" --wait "$work/wait/p$n.md" && [ ! -e "$work/wait/p$n~.md" ] && [ "$(head -1 "$work/wait/p$n.md")" = "smoke edit" ] || touch "$work/wait/failed$n" ) &
done
wait
[ -z "$(ls "$work/wait" | grep -v '^p[1-8]\.md$')" ] || fail "--wait on existing files left: $(ls "$work/wait" | tr '\n' ' ')"

# 7. As git's editor: the commit message is what was typed, in a file without an extension.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q "$work/repo"
GIT_EDITOR="'$cli' --wait" git -C "$work/repo" -c user.name=smoke -c user.email=smoke@example.invalid commit -q --allow-empty \
    || fail "git commit with marko --wait as the editor"
[ "$(git -C "$work/repo" log -1 --format=%s)" = "smoke edit" ] || fail "the commit message is $(git -C "$work/repo" log -1 --format=%s)"
[ -z "$(find "$work/repo/.git" -name 'COMMIT_EDITMSG.*')" ] || fail "the commit message file was renamed"
echo x > "$work/repo/n.md"
"$cli" --wait "$work/repo/n.md"
git -C "$work/repo" add -A
[ "$(git -C "$work/repo" status --short)" = "A  n.md" ] || fail "git sees more than the file after --wait: $(git -C "$work/repo" status --short)"

# 8. An empty untitled window is taken over by the file or folder opened next, not added to;
# --new-window leaves it alone. The line of the request just made is the next one of the log.
latest() { served $(( $(grep -c "^serve: request=" "$log") + 1 )); }
windows() { sed -n 's/.* windows=\([0-9]*\)$/\1/p' <<<"$1"; }
empty="[=,]Untitled[^,@]*@1\+0[, ]"
echo reuse > "$work/reuse.md"
mkdir "$work/proj2"
"$cli" --new-window
line="$(latest)"; before="$(windows "$line")"
expect "$line" "$empty"
"$cli" "$work/reuse.md"
line="$(latest)"
expect "$line" "[=,]reuse.md@1\+6[, ]" "windows=$before$"
grep -Eq -- "$empty" <<<"$line" && fail "the empty window is still there beside the file: $line"
"$cli" --new-window
expect "$(latest)" "$empty" "windows=$((before + 1))$"
"$cli" "$work/proj2"
line="$(latest)"
expect "$line" "folders=proj,proj2 windows=$((before + 1))$"
grep -Eq -- "$empty" <<<"$line" && fail "the empty window is still there beside the folder: $line"
# A file of a folder whose window shows no file yet is shown there.
echo in > "$work/proj2/in.md"
"$cli" "$work/proj2/in.md"
expect "$(latest)" "[=,]in.md@1\+3[, ]" "folders=proj,proj2 windows=$((before + 1))$"
# The empty window in front is also taken when a file that is open is named first and comes forward.
echo order > "$work/order.md"
"$cli" --new-window
"$cli" "$work/a.md" "$work/order.md"
line="$(latest)"
expect "$line" "[=,]order.md@1\+6[, ]" "windows=$((before + 2))$"
grep -Eq -- "$empty" <<<"$line" && fail "the empty window is still there beside the two files: $line"
"$cli" --new-window
"$cli" --new-window "$work/cold.md"
expect "$(latest)" "$empty" "[=,]cold.md@1\+0[, ]" "windows=$((before + 4))$"

# 9. Safe mode. A document names an image at a port of this Mac where a listener counts what
# connects: nothing does until the document or its folder is trusted. No folder is asked about
# in a smoke run, and --trust and --safe answer for the folder they name.
perl -MIO::Socket::INET -e '
    my $server = IO::Socket::INET->new(Listen => 16, LocalAddr => "127.0.0.1", LocalPort => 0) or die "no listener";
    open(my $port, ">", $ARGV[0]); print $port $server->sockport, "\n"; close $port;
    while (my $client = $server->accept) { open(my $log, ">>", $ARGV[1]); print $log "connection\n"; close $log; close $client }
' "$work/port" "$work/connections" &
listener=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
port="$(cat "$work/port")"
connections() { if [ -f "$work/connections" ]; then wc -l < "$work/connections" | tr -d ' '; else echo 0; fi; }
# The line about trust that goes with the request just made.
trust() { latest >/dev/null; grep "^serve: trust=$(grep -c "^serve: request=" "$log") " "$log"; }
mkdir -p "$work/remote/sub"
for name in single in sub/deep; do printf '![x](http://127.0.0.1:%s/%s.png)\n' "$port" "$name" > "$work/remote/$name.md"; done
status=0; "$cli" --trust --safe "$work/remote" 2>"$work/err" || status=$?
[ "$status" = 2 ] && grep -q "marko: --trust and --safe exclude each other" "$work/err" || fail "--trust with --safe: status $status"
# A file named like the option, which is what "marko *" passes where there is one, trusts nothing.
mkdir -p "$work/glob/docs" && : > "$work/glob/--trust"
status=0; (cd "$work/glob" && "$cli" *) 2>"$work/err" || status=$?
[ "$status" = 2 ] && grep -q "marko: --trust is also the name of a file here" "$work/err" || fail "marko * beside a file named --trust: status $status"
"$cli" "$work/remote/single.md"
expect "$(trust)" " trusted= loading= questions=0$"
# The temporary folder, where downloads and attachments pass through, is too much to trust.
status=0; "$cli" --trust "$(dirname "$work")" 2>"$work/err" || status=$?
[ "$status" = 1 ] && grep -q "marko: .*: too much to trust, opened in safe mode" "$work/err" || fail "--trust on the folder above: status $status, $(cat "$work/err")"
expect "$(trust)" " trusted= loading= questions=0$"
[ "$(connections)" = 0 ] || fail "a file opened on its own connected to the address of its image"
"$cli" "$work/remote"
expect "$(trust)" " trusted= loading= questions=0$"
"$cli" "$work/remote/in.md"
expect "$(trust)" " trusted= loading= questions=0$"
[ "$(connections)" = 0 ] || fail "a file of a folder that is not trusted connected to the address of its image"
# --trust on a file: that document loads its images, and nothing is trusted.
"$cli" --trust "$work/remote/single.md"
expect "$(trust)" " trusted= loading=single.md questions=0$"
for _ in $(seq 50); do [ "$(connections)" != 0 ] && break; sleep 0.1; done
[ "$(connections)" != 0 ] || fail "--trust on a file did not fetch its image"
# --trust on a folder: the documents of it that are open load theirs at once, also below it.
before="$(connections)"
"$cli" --trust "$work/remote" "$work/remote/sub/deep.md"
expect "$(trust)" " trusted=remote loading=deep.md,in.md,single.md questions=0$"
for _ in $(seq 50); do [ "$(connections)" -gt "$before" ] && break; sleep 0.1; done
[ "$(connections)" -gt "$before" ] || fail "--trust on a folder did not fetch the images of its open documents"
# --safe on the folder takes it back; --safe on a file keeps one document from loading.
"$cli" --safe "$work/remote"
expect "$(trust)" " trusted= loading= questions=0$"
"$cli" --trust "$work/remote"
"$cli" --safe "$work/remote/in.md"
expect "$(trust)" " trusted=remote loading=deep.md,single.md questions=0$"
# --safe on a folder inside the trusted one is for that folder: the one above stays trusted.
"$cli" --safe "$work/remote/sub"
expect "$(trust)" " trusted=remote loading=single.md questions=0$"
kill "$listener" && wait "$listener" 2>/dev/null || true
listener=""

# One instance served all of it, and an unreadable file is an error of the tool.
[ "$(grep -c "^serve: started" "$log")" = 1 ] || fail "more than one instance was started"
printf '\xff\xfe\x00' > "$work/binary.md"
status=0; "$cli" "$work/binary.md" 2>"$work/err" || status=$?
[ "$status" = 1 ] && grep -q "marko: .*binary.md: " "$work/err" || fail "a file that is not text: status $status, $(cat "$work/err")"

# How long the tool takes when the app is running: twenty runs, the median. MEASURED: 8 to 10 ms;
# over 40 ms on a machine that is not overloaded means the tool waits for something again.
perl -MTime::HiRes=time -e '
    my @ms = sort { $a <=> $b } map { my $start = time; system(@ARGV) == 0 or die "marko failed"; (time - $start) * 1000 } 1..20;
    printf "smoke-cli: marko file.md with the app running, 20 runs: median %.1f ms, slowest %.1f ms\n", $ms[10], $ms[-1];
    exit($ms[10] > 40 ? 1 : 0);
' "$cli" "$work/a.md" || fail "the tool is slow or failed with the app running (budget: median 40 ms)"

# Five tools at once with no app running, ten times over: every tool is answered, and by one
# instance, which serves them all and is the only one that stays. (Hundreds of rounds of this, on
# a loaded machine, are what found requests that were dropped.)
kill $(started)
for n in 1 2 3 4 5; do echo x > "$work/cold$n.md"; done
# The log is not there until the instance has started.
alive() { for pid in $(sed -n 's/^serve: started pid=//p' "$MARKO_SERVE" 2>/dev/null); do kill -0 "$pid" 2>/dev/null && echo "$pid"; done; }
for round in $(seq 10); do
    [ "$round" = 1 ] || kill $(alive)
    export MARKO_SERVE="$work/serve2-$round.log" MARKO_SOCKET="$work/socket2-$round"
    for n in 1 2 3 4 5; do ( "$cli" "$work/cold$n.md" || touch "$work/cold-failed" ) & done
    wait
    [ ! -e "$work/cold-failed" ] || fail "a tool failed when five started the app at once (round $round)"
    for _ in $(seq 50); do [ -n "$(alive)" ] && break; sleep 0.1; done
    [ "$(grep -c '^serve: started' "$MARKO_SERVE")" = 1 ] || fail "five tools at once started $(grep -c '^serve: started' "$MARKO_SERVE") instances that stayed (round $round)"
done
for _ in $(seq 50); do [ "$(alive | wc -l | tr -d ' ')" = 1 ] && break; sleep 0.1; done
[ "$(alive | wc -l | tr -d ' ')" = 1 ] || fail "five tools at once left $(alive | wc -l | tr -d ' ') instances"
for _ in $(seq 50); do [ "$(grep -c '^serve: request=' "$MARKO_SERVE" 2>/dev/null)" = 5 ] && break; sleep 0.1; done
tail -1 "$MARKO_SERVE" | grep -q "documents=cold1.md@1+2,cold2.md@1+2,cold3.md@1+2,cold4.md@1+2,cold5.md@1+2 " \
    || fail "the one instance does not show all five files: $(cat "$MARKO_SERVE")"

# The app goes away while a tool waits: the tool fails, so that git does not take a half-written message.
status=0
( sleep 0.4; kill $(alive) ) &
"$cli" --wait "$work/cold1.md" 2>"$work/err" || status=$?
wait
[ "$status" = 1 ] && grep -q "marko: Marko went away while waiting" "$work/err" || fail "the app was killed under --wait: status $status, $(cat "$work/err")"

# Started for a file, the app shows it before it has finished launching, as Markdown whatever its
# name, and the request that follows finds it open: one document in one window, and it outlives the tool.
export MARKO_SERVE="$work/serve3.log" MARKO_SOCKET="$work/socket3"
printf 'message\n' > "$work/COMMIT_EDITMSG"
"$cli" "$work/COMMIT_EDITMSG"
for _ in $(seq 100); do grep -q "^serve: request=1 " "$MARKO_SERVE" 2>/dev/null && break; sleep 0.1; done
grep -q "^serve: request=1 documents=COMMIT_EDITMSG@1+8 folders= windows=1$" "$MARKO_SERVE" || fail "started for a file: $(cat "$MARKO_SERVE")"
[ "$(alive | wc -l | tr -d ' ')" = 1 ] || fail "the app the tool started did not outlive it"
# None of the instances was the frontmost app when it answered, and none is of a kind that can be:
# the user's keys go to the app the user is in.
[ -n "$(cat "$work"/*.log | grep "^serve: front=")" ] || fail "no instance said whether it was in front"
cat "$work"/*.log | grep "^serve: front=" | grep -v " active=false background=true$" && fail "an instance was in front or could be"
echo "smoke-cli: OK"
