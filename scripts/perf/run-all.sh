#!/bin/bash
# Builds the release app, makes the test documents in a temporary folder and runs every measurement
# of scripts/perf/perf.py on them. The results are JSON lines on standard output and, with the
# machine's load before and after each part, in build/perf/results.jsonl. A full run
# takes about 45 minutes on an M3 Max; `--quick` makes two runs of everything.
#
#   scripts/perf/run-all.sh [--quick] [command...]     commands as in perf.py; all but `profile` by default
#   scripts/perf/run-all.sh --check                    a short run that fails when a median is over its
#                                                      budget (BUDGETS in perf.py); about 7 minutes
#   scripts/perf/run-all.sh --fuzz                     the long random test of the partial parse against
#                                                      the whole one (release, about 8 minutes); run it
#                                                      after any change to Restyle.swift, MarkdownStyler
#                                                      or the version of swift-markdown, and before a release
#
# Other editors are only started as new background instances with data folders of their own, and
# one that is already running without that is skipped. Every app started here ends by itself or is
# ended by its pid.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "${1:-}" = "--fuzz" ]; then
    # A scratch folder of its own: a release build with testing enabled would otherwise replace what build-app.sh built.
    MARKO_FUZZ=1500 exec swift test --package-path "$root" -c release -Xswiftc -enable-testing --scratch-path "$root/.build/fuzz" --filter RestyleTests
fi
quick=()
if [ "${1:-}" = "--quick" ]; then quick=(--quick); shift; fi
if [ "${1:-}" = "--check" ]; then
    shift
    quick=(--check --runs 1 --only note-5k.md,doc-90k.md,doc-600k.md,list-500k.md,list-74k.md,table-2000.md,table-wide.md,table-source.md,images-200.md)
    set -- launch cli open typing scroll resize switch folder idle
fi
commands=("$@")
if [ ${#commands[@]} -eq 0 ]; then commands=(size launch cli open typing scroll resize switch folder idle compare); fi

"$root/scripts/build-app.sh" > /dev/null
corpus="$(mktemp -d /tmp/marko-perf-corpus.XXXXXX)"
trap 'rm -rf "$corpus"' EXIT
python3 "$root/scripts/perf/gen.py" "$corpus" > /dev/null

mkdir -p "$root/build/perf"
# A check leaves the results of the last whole run alone.
out="$root/build/perf/results.jsonl"
case " ${quick[*]-} " in *" --check "*) out="$root/build/perf/check.jsonl" ;; esac
rm -f "$out"
echo "{\"machine\": \"$(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)\", \"date\": \"$(date -u +%Y-%m-%dT%H:%MZ)\"}" | tee "$out"
python3 "$root/scripts/perf/perf.py" "${commands[@]}" --corpus "$corpus" --out "$out" ${quick[@]+"${quick[@]}"}
