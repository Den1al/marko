#!/usr/bin/env python3
"""Measures build/Marko.app (release, scripts/build-app.sh) and prints one JSON line per metric.

    perf.py <command>... [--corpus <folder>] [--runs <n>] [--out <file.jsonl>] [--quick] [--only <documents>] [--check]

Commands: size launch turns cli open typing scroll resize floor switch folder idle compare profile report.
The corpus is what scripts/perf/gen.py wrote. Every app that is started ends by itself (MARKO_PERF,
see Sources/MarkoApp/Perf.swift) or is ended here by its pid.
"""
import argparse
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# MARKO_PERF_APP names another build of the app, to measure a change against what was there before.
APP = os.environ.get("MARKO_PERF_APP") or os.path.join(ROOT, "build", "Marko.app")
BIN = os.path.join(APP, "Contents", "MacOS", "Marko")
CLI = os.path.join(APP, "Contents", "Helpers", "marko")
HELPER = os.path.join(ROOT, "build", "perf", "helper")
CONTROL = os.path.join(ROOT, "build", "perf", "control")
DOCS = ["note-5k.md", "doc-100k.md", "doc-600k.md", "doc-5m.md", "table-2000.md", "images-200.md"]
# Typed in besides: the largest document that is still parsed whole on a key that needs it, one
# block as long as its text, a table whose columns stay where they are, and one that shows as source.
TYPED = DOCS[:1] + ["doc-90k.md"] + DOCS[1:] + ["list-500k.md", "list-74k.md", "table-wide.md", "table-source.md"]
# With --check: medians that must stay under these, as (metric, document, limit in its unit).
# Wide enough for a machine that is doing other things (two to four times what was measured on
# an M3 Max); they catch a path that became slow, not a few percent.
BUDGETS = [
    ("launch.spawnToFirstFrame", "note-5k.md", 320), ("launch.spawnToFirstFrame", "doc-600k.md", 400),
    # The tool waiting for the window again shows at 600 KB (190 ms then); 5 KB was 33 ms at a load of 6.
    ("cli.warm.wall", "note-5k.md", 60), ("cli.warm.wall", "doc-600k.md", 60), ("cli.warm.again.wall", "note-5k.md", 30),
    ("cli.cold.wall", "note-5k.md", 400),
    ("open.total", "note-5k.md", 90), ("open.total", "doc-600k.md", 300), ("open.pictures", "images-200.md", 250),
    ("type.middle.key", "note-5k.md", 12), ("type.middle.key", "doc-90k.md", 14), ("type.middle.key", "doc-600k.md", 16),
    ("type.middle.key", "list-500k.md", 16), ("type.middle.key", "list-74k.md", 14), ("type.middle.key", "images-200.md", 14),
    ("type.above.key", "table-2000.md", 12), ("type.tableMiddle.key", "table-2000.md", 35),
    ("type.tableMiddle.key", "table-wide.md", 14), ("type.tableMiddle.key", "table-source.md", 16),
    ("type.middle.pause", "doc-600k.md", 30), ("afterTyping.middle.return", "doc-600k.md", 30),
    ("scroll.wheel.frame.over8ms", "doc-600k.md", 3), ("scroll.wheel.frame.over8ms", "images-200.md", 5),
    ("resize.step", "note-5k.md", 20), ("resize.step", "doc-600k.md", 24),
    ("switch.5k", "notes/a.md, b.md", 80), ("folder.expand.flat.wall", "tree-20k", 200),
    ("idle.cpuPercent", "note-5k.md", 1),
]
# No state is restored or kept between runs.
ARGS = ["-ApplePersistenceIgnoreState", "YES"]

options = None
results = []


def record(metric, values, doc="", unit="ms", note=""):
    """One metric: the median and the spread of its values."""
    values = sorted(values)
    if not values:
        return
    entry = {"metric": metric, "doc": doc, "unit": unit, "n": len(values), "median": round(statistics.median(values), 3),
             "min": round(values[0], 3), "p95": round(values[min(len(values) - 1, int(len(values) * 0.95))], 3),
             "max": round(values[-1], 3)}
    if note:
        entry["note"] = note
    results.append(entry)
    print(json.dumps(entry), flush=True)


def load():
    one, five, fifteen = os.getloadavg()
    return round(one, 2)


def environment(extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith("MARKO_")}
    env.update({k: str(v) for k, v in extra.items()})
    return env


def parse(text):
    """`perf: <metric> <value>...` lines as {metric: [values]}; a failure in the app ends the run."""
    metrics = {}
    for line in text.splitlines():
        if not line.startswith("perf: "):
            continue
        parts = line.split()
        if parts[1] in ("FAIL", "HARD"):
            raise SystemExit(f"the app reported: {line}")
        metrics.setdefault(parts[1], []).extend(float(v) for v in parts[2:])
    return metrics


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def end(pid, wait=5.0):
    """Waits for a process this script started to go, and kills it by pid if it does not."""
    deadline = time.time() + wait
    while alive(pid) and time.time() < deadline:
        time.sleep(0.02)
    if alive(pid):
        os.kill(pid, signal.SIGKILL)


def run(scenario, target, env=None, timeout=120, binary=None):
    """Starts the app (or `binary`) on `target` for one scenario and returns its metrics, with the
    time from just before the process was made to its first frame as `spawnToFirstFrame`."""
    env = environment({"MARKO_PERF": scenario, "MARKO_PERF_TIMEOUT": timeout, **(env or {})})
    # MEASURED: an app in the background is scheduled less steadily (a key in a 5 KB note took 6 to
    # 17 ms instead of 6 to 7), so what a person does in the frontmost app is measured in one.
    if scenario not in ("launch", "idle") and not options.background:
        env["MARKO_PERF_ACTIVATE"] = "1"
    started = time.time() * 1000
    process = subprocess.Popen([binary or BIN] + ARGS + ([target] if target else []), env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True)
    try:
        output, _ = process.communicate(timeout=timeout + 10)
    except subprocess.TimeoutExpired:
        process.kill()
        raise SystemExit(f"{scenario} on {target} did not end")
    if process.returncode != 0:
        raise SystemExit(f"{scenario} on {target} ended with status {process.returncode}: {output[-400:]}")
    metrics = parse(output)
    if "launch.firstFrameEpoch" in metrics:
        metrics["spawnToFirstFrame"] = [metrics.pop("launch.firstFrameEpoch")[0] - started]
    metrics.pop("pid", None)
    return metrics


def merged(runs):
    total = {}
    for metrics in runs:
        for name, values in metrics.items():
            total.setdefault(name, []).extend(values)
    return total


def corpus():
    with open(os.path.join(options.corpus, "corpus.json")) as file:
        return json.load(file)


def doc(name):
    return os.path.join(options.corpus, name)


def scratch_copy(name):
    """A copy to edit: typing changes the file, and a document saves itself."""
    folder = tempfile.mkdtemp(prefix="marko-perf-run.")
    shutil.copy(doc(name), folder)
    if name == "images-200.md":
        os.symlink(doc("img"), os.path.join(folder, "img"))
    return folder, os.path.join(folder, name)


def chosen(names):
    """The documents of a command that --only leaves."""
    return [name for name in names if not options.only or name in options.only.split(",")]


def runs(standard, name=""):
    n = options.runs or standard
    if options.quick:
        n = min(n, 2)
    return max(1, n // 3) if name == "doc-5m.md" else n


# ---- commands


def size():
    def folder_size(path):
        return sum(os.path.getsize(os.path.join(d, f)) for d, _, files in os.walk(path) for f in files)

    record("size.app", [os.path.getsize(BIN) / 1e6], unit="MB")
    record("size.cli", [os.path.getsize(CLI) / 1e6], unit="MB")
    record("size.bundle", [folder_size(APP) / 1e6], unit="MB")


def launch():
    """A new process for every run, the file as its argument. The disk cache is warm."""
    for name in chosen(DOCS):
        total = merged(run("launch", doc(name)) for _ in range(runs(10, name)))
        for metric, values in total.items():
            record(metric if metric.startswith("launch.") else f"launch.{metric}", values, name, "MB" if "MB" in metric else "ms")
        record("launch.openToFirstFrame", [f - o for f, o in zip(total["launch.firstFrame"], total["launch.openRequest"])], name)
    if not options.only:
        total = merged(run("launch", doc("note-5k.md"), {"MARKO_PERF_POLICY": "regular"}) for _ in range(runs(5)))
        record("launch.firstFrame.regularApp", total["launch.firstFrame"], "note-5k.md")


def build_control():
    """The least an AppKit app can do to show a text (scripts/perf/control), which puts its window
    where the app's measuring runs put theirs."""
    sources = [os.path.join(ROOT, "scripts", "perf", "control", "main.swift"), os.path.join(ROOT, "Sources", "MarkoEditor", "BuiltInDisplay.swift")]
    if not os.path.exists(CONTROL) or os.path.getmtime(CONTROL) < max(os.path.getmtime(source) for source in sources):
        os.makedirs(os.path.dirname(CONTROL), exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", CONTROL] + sources, check=True)


def turns():
    """Launches in turn: the control, the app, and every other build named with --against, one
    after the other, round after round, so that all of them see the same machine. The control
    is the floor: what an AppKit app with one window of text takes here."""
    build_control()
    # The control twice: sending its frame when AppKit does, and at once, as the app does at launch.
    builds = [("control", CONTROL, {}), ("controlFlushed", CONTROL, {"MARKO_CONTROL_FLUSH": 1}), ("app", BIN, {})]
    builds += [(os.path.basename(os.path.dirname(app)) or app, os.path.join(app, "Contents", "MacOS", "Marko"), {}) for app in options.against]
    for name in chosen(DOCS if options.only else ["note-5k.md"]):
        for _, binary, env in builds:
            run("launch", doc(name), env, binary=binary)
        total = {label: [] for label, _, _ in builds}
        for round in range(runs(15, name)):
            for label, binary, env in builds[round % len(builds):] + builds[:round % len(builds)]:
                # MEASURED: what is started straight after a Marko has ended reaches
                # willFinishLaunching 10 to 20 ms later than after the control; half a second evens that out.
                time.sleep(0.5)
                total[label].append(run("launch", doc(name), env, binary=binary))
        for label, _, _ in builds:
            for metric, values in merged(total[label]).items():
                if metric.startswith(("launch.", "spawn")):
                    record(f"turns.{label}.{metric.removeprefix('launch.')}", values, name)


def spawn(arguments, env):
    """Wall time of a process from just before it is made until it has ended, in milliseconds."""
    started = time.perf_counter()
    pid = os.posix_spawn(arguments[0], arguments, env, file_actions=[(os.POSIX_SPAWN_OPEN, 1, "/dev/null", os.O_WRONLY, 0)])
    _, status = os.waitpid(pid, 0)
    elapsed = (time.perf_counter() - started) * 1000
    if status != 0:
        raise SystemExit(f"{arguments} ended with status {status}")
    return elapsed


def read_metrics(path):
    try:
        with open(path) as file:
            return parse(file.read())
    except FileNotFoundError:
        return {}


def cli():
    """The `marko` tool: by itself, starting the app, and handing over to an app that runs."""
    env = environment({})
    record("cli.version", [spawn([CLI, "--version"], env) for _ in range(runs(20))])
    work = tempfile.mkdtemp(prefix="marko-perf-cli.")
    try:
        # Cold: nothing runs; the tool starts the app, waits for its socket and hands over.
        for name in ["note-5k.md", "doc-600k.md"]:
            walls, frames, starts, marks = [], [], [], {}
            # MEASURED: the first start of a new build is the system checking the binary (495 ms
            # before `main` through LaunchServices against 61). As in `run`, one start is not counted.
            for index in range(-1 if name == "note-5k.md" else 0, runs(10)):
                out, socket = os.path.join(work, f"cold-{index}-{name}.out"), os.path.join(work, f"s{index}{name[:1]}")
                env = environment({"MARKO_SOCKET": socket, "MARKO_PERF": "launch", "MARKO_PERF_OUT": out, "MARKO_PERF_TIMEOUT": 30})
                started = time.time() * 1000
                wall = spawn([CLI, doc(name)], env)
                deadline = time.time() + 20
                while "footprintMB" not in read_metrics(out) and time.time() < deadline:
                    time.sleep(0.05)
                metrics = read_metrics(out)
                if "pid" in metrics:
                    end(int(metrics["pid"][0]))
                if "launch.firstFrameEpoch" not in metrics:
                    raise SystemExit("the app started by the tool drew nothing")
                if index < 0:
                    continue
                walls.append(wall)
                frames.append(metrics["launch.firstFrameEpoch"][0] - started)
                starts.append(metrics["launch.firstFrame"][0])
                for mark in ["main", "willFinishLaunching", "didFinishLaunching", "openRequest"]:
                    marks.setdefault(mark, []).extend(metrics.get(f"launch.{mark}", []))
            record("cli.cold.wall", walls, name, note="tool returns; the app was not running")
            record("cli.cold.toFirstFrame", frames, name, note="tool started to first frame of the app it started")
            record("cli.cold.appStartToFirstFrame", starts, name, note="the app's own part of that")
            for mark, values in marks.items():
                record(f"cli.cold.app.{mark}", values, name, note="from the start of the app's process")

        # Warm: an app is running and has shown a window before.
        out, socket = os.path.join(work, "serve.out"), os.path.join(work, "serve")
        env = environment({"MARKO_SOCKET": socket, "MARKO_PERF": "serve", "MARKO_PERF_OUT": out, "MARKO_PERF_TIMEOUT": 120})
        server = subprocess.Popen([BIN] + ARGS, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.time() + 20
            while not os.path.exists(socket) and time.time() < deadline:
                time.sleep(0.02)
            env = environment({"MARKO_SOCKET": socket})
            shutil.copy(doc("note-5k.md"), os.path.join(work, "warm.md"))
            spawn([CLI, os.path.join(work, "warm.md")], env)
            time.sleep(1)
            for name in ["note-5k.md", "doc-600k.md"]:
                walls, frames = [], []
                for index in range(runs(12, name)):
                    path = os.path.join(work, f"{index}-{name}")
                    shutil.copy(doc(name), path)
                    before = len(read_metrics(out).get("handoff.frameEpoch", []))
                    started = time.time() * 1000
                    walls.append(spawn([CLI, path], env))
                    deadline = time.time() + 20
                    while len(read_metrics(out).get("handoff.frameEpoch", [])) == before and time.time() < deadline:
                        time.sleep(0.01)
                    frames.append(read_metrics(out)["handoff.frameEpoch"][-1] - started)
                    time.sleep(0.3)
                record("cli.warm.wall", walls, name, note="tool returns; a new file handed to a running app")
                record("cli.warm.toFrame", frames, name, note="tool started to the file on screen")
            record("cli.warm.again.wall", [spawn([CLI, os.path.join(work, "warm.md")], env) for _ in range(runs(20))], "note-5k.md",
                   note="a file that is open already comes forward")
            record("cli.warm.appOpen", read_metrics(out).get("handoff.open", [])[1:], "mixed", note="request received to frame, inside the app")
        finally:
            server.terminate()
            end(server.pid)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def open_():
    """The same file opened ten times in one running app: no process start, no first-window cost."""
    for name in chosen(DOCS):
        total = run("open", doc(name), {"MARKO_PERF_COUNT": runs(10, name)}, timeout=300)
        for metric, values in total.items():
            if metric.startswith("open."):
                record(metric, values, name, "MB" if "MB" in metric else "ms")


def offsets(name, keys=None):
    places = corpus()[name]["offsets"]
    return ",".join(f"{key}:{value}" for key, value in places.items() if keys is None or key in keys)


def typing():
    """Every place in a process of its own: the command keys at one place change the text (a
    Return in a table row), and the next place would be typed into what they left."""
    for name in chosen(TYPED):
        places = corpus()[name]["offsets"]
        if options.check:
            # Only the places a budget speaks of.
            places = [place for place in places if any(f".{place}." in metric and name == document for metric, document, _ in BUDGETS)]
        total = []
        for index, place in enumerate(places):
            env = {"MARKO_PERF_OFFSETS": offsets(name, [place]), "MARKO_PERF_COUNT": 1 if name == "doc-5m.md" else 3}
            # Pasting, selecting and deleting everything: once per document.
            if index == 0 and name in DOCS + ["doc-90k.md"]:
                env["MARKO_PERF_PASTE"] = doc("paste-50k.md")
            for _ in range(runs(3, name)):
                folder, path = scratch_copy(name)
                try:
                    total.append(run("typing", path, env, timeout=900))
                finally:
                    shutil.rmtree(folder, ignore_errors=True)
        total = merged(total)
        for metric, values in total.items():
            if metric.startswith(("launch.", "spawn")):
                continue
            record(metric, values, name)
            if metric.startswith("type.") and metric.endswith(".key"):
                # MEASURED: a few keys per process take 100 ms and more (NSTextView hiding the pointer,
                # a call to the window server), in a burst. They are counted, not averaged in.
                slow = [index for index, value in enumerate(values) if value > 16.67]
                parts = [statistics.median(total[f"{metric}.{part}"][index] for index in slow) if slow else 0
                         for part in ["work", "layout", "draw", "commit"]]
                record(metric + ".over16ms", [len(slow)], name, "keys",
                       note=f"of {len(values)}; their work / layout / draw / commit medians: " + " / ".join(f"{part:.1f}" for part in parts))


def frames(metric, values, name):
    """Frame times, and how many of them miss a 120 Hz and a 60 Hz frame."""
    record(metric, values, name)
    record(metric + ".over8ms", [100 * sum(v > 8.33 for v in values) / len(values)], name, "%")
    record(metric + ".over16ms", [100 * sum(v > 16.67 for v in values) / len(values)], name, "%")


def scroll():
    """Frames `--frame-gap` ms apart: 8 is what a 120 Hz display leaves between two, and says
    whether frames would be dropped; 1 leaves no time between frames, and
    mostly measures the wait for the window server."""
    for name in chosen(DOCS):
        total = merged(run("scroll", doc(name), {"MARKO_PERF_FRAME_GAP": options.frame_gap}, timeout=600) for _ in range(runs(3, name)))
        for metric, values in total.items():
            if metric.endswith(".frame"):
                frames(metric, values, name)
            elif metric.startswith("scroll."):
                # How many frames were made while the app was not in front, per run, and how many of those were slow.
                record(metric, values, name, "pt" if metric == "scroll.height" else "frames" if "Frames" in metric else "ms")


def resize():
    """From 880 points down to 480 and back, where the text column changes with the window; with
    `--width 1500` from there down to 1,100 and back, where only the margins beside it do."""
    env = {"MARKO_PERF_WIDTH": options.width} if options.width else {}
    for name in chosen(DOCS):
        total = merged(run("resize", doc(name), {"MARKO_PERF_OFFSETS": offsets(name, ["middle", "tableMiddle"]), **env}, timeout=600)
                       for _ in range(runs(3, name)))
        frames("resize.wide.step" if options.width else "resize.step", total["resize.step"], name)


def floor():
    """What a stock TextKit 2 text view takes for the same steps, on the same text as plain text
    (scripts/perf/control): the floor under a frame of scrolling, a step of a resize, a key and
    Return, and a key that gives every row in the window other tab stops (`restyle`: what a key
    that widens a table's column asks of TextKit)."""
    build_control()
    for name in chosen(["note-5k.md", "doc-600k.md", "table-2000.md"]):
        place = "tableMiddle" if name.startswith("table") else "middle"
        for scenario in ["scroll", "resize", "typing"] + (["restyle"] if name.startswith("table") else []):
            env = {"MARKO_PERF_OFFSETS": offsets(name, [place]), "MARKO_PERF_FRAME_GAP": options.frame_gap}
            total = merged(run(scenario, doc(name), env, binary=CONTROL) for _ in range(runs(3, name)))
            for metric, values in total.items():
                if metric.endswith(".frame") or metric == "resize.step":
                    frames(f"floor.{metric}", values, name)
                elif metric.startswith(("type.", "afterTyping.")):
                    record(f"floor.{scenario}.{metric}", values, name)


def switch():
    notes = doc("notes")
    files = ":".join(os.path.join(notes, f) for f in ["a.md", "b.md", "c.md"])
    total = merged(run("switch", notes, {"MARKO_PERF_FILES": files, "MARKO_PERF_COUNT": 30}) for _ in range(runs(3)))
    record("switch.5k", total["switch.a"] + total["switch.b"], "notes/a.md, b.md")
    record("switch.100k", total["switch.c"], "notes/c.md")
    record("switch.after", total["switch.after"], "notes")


def folder():
    total = merged(run("folder", doc("tree-20k"), {"MARKO_PERF_EXPAND": "dir-000,flat,*"}, timeout=300) for _ in range(runs(5)))
    for metric, values in total.items():
        if metric == "folder.scroll.frame":
            frames(metric, values, "tree-20k")
        elif metric.startswith(("folder.", "launch.", "spawn")):
            unit = "rows" if metric.endswith("rows") else "MB" if "MB" in metric else "ms"
            record(metric if metric.startswith("folder.") else f"folder.{metric}", values, "tree-20k", unit)
    # The same folder with the first listing not yet in the system's cache cannot be had without purging it.


def idle():
    for name in ["note-5k.md", "doc-600k.md"]:
        total = merged(run("idle", doc(name)) for _ in range(runs(3)))
        record("idle.cpuPercent", total["idle.cpuPercent"], name, "%")
        record("idle.footprintMB", total["idle.footprintMB"], name, "MB")


# ---- other editors


def build_helper():
    source = os.path.join(ROOT, "scripts", "perf", "helper.swift")
    if not os.path.exists(HELPER) or os.path.getmtime(HELPER) < os.path.getmtime(source):
        os.makedirs(os.path.dirname(HELPER), exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", HELPER, source], check=True)


EDITORS = [
    # name, app, what goes before the file on its command line; {data} is a folder of its own for the
    # runs, "env:" a variable for the instance. None: the file is handed over as a document to open.
    ("Marko", APP, None),
    ("TextEdit", "/System/Applications/TextEdit.app", None),
    # MEASURED: beside a Zed that is running, a second one ends at once ("zed is already running"),
    # also with a data folder of its own; with ZED_STATELESS it runs, and keeps nothing.
    ("Zed", "/Applications/Zed.app", ["env:ZED_STATELESS=1", "--user-data-dir", "{data}"]),
    ("Visual Studio Code", "/Applications/Visual Studio Code.app",
     ["--user-data-dir", "{data}/user", "--extensions-dir", "{data}/extensions", "--disable-workspace-trust", "--skip-welcome",
      "--skip-release-notes", "--disable-updates", "--new-window"]),
    # Obsidian opens vaults, not files: with a data folder of its own it shows its vault chooser.
    ("Obsidian", "/Applications/Obsidian.app", ["--user-data-dir={data}", "{nofile}"]),
]


def compare():
    """Time until another editor has a window on screen and until it has gone quiet, by asking the
    system from outside; see helper.swift. Each editor gets one data folder for its runs and a
    first run that is not counted, so none is measured setting itself up for the first time."""
    build_helper()
    for editor, app, arguments in EDITORS:
        if options.only and editor not in options.only.split(","):
            continue
        if not os.path.exists(app):
            print(json.dumps({"editor": editor, "skipped": "not installed"}), flush=True)
            continue
        data = tempfile.mkdtemp(prefix="marko-perf-editor.")
        try:
            for name in ["note-5k.md", "doc-600k.md"]:
                visible, quiet, memory, inside, skipped = [], [], [], [], None
                for index in range(runs(5) + 1):
                    folder, path = scratch_copy(name)
                    try:
                        command = [HELPER, "window", app]
                        if arguments is None:
                            command += ["--file", path, "--document"]
                            if editor == "Marko":
                                # Its own account of the same launch goes to a file, to compare the two methods.
                                own = os.path.join(data, f"marko-{name}-{index}.out")
                                command += ["--isolated", "--env", "MARKO_PERF=idle", "--env", "MARKO_PERF_TIMEOUT=40",
                                            "--env", f"MARKO_PERF_OUT={own}"]
                        else:
                            command += ["--isolated"] + ([] if "{nofile}" in arguments else ["--file", path])
                            for argument in arguments:
                                if argument.startswith("env:"):
                                    command += ["--env", argument[4:]]
                                elif argument != "{nofile}":
                                    command += ["--arg", argument.replace("{data}", data)]
                        output = subprocess.run(command, capture_output=True, text=True, timeout=180).stdout
                    finally:
                        shutil.rmtree(folder, ignore_errors=True)
                    found = dict(re.findall(r"(\w+)=(\S+)", output))
                    if "visible" not in found:
                        skipped = output.strip()[-200:] or "no answer"
                        break
                    if index > 0:
                        if editor == "Marko":
                            inside.extend(read_metrics(own).get("launch.firstFrame", []))
                        visible.append(float(found["visible"]))
                        quiet.append(float(found["quiet"]))
                        memory.append(float(found["memoryMB"]))
                    time.sleep(1)
                if skipped:
                    print(json.dumps({"editor": editor, "doc": name, "skipped": skipped}), flush=True)
                record(f"compare.windowVisible.{editor}", visible, name)
                record("compare.ownFirstFrame.Marko", inside, name, note="process start to first frame, as the app itself saw it in these runs")
                record(f"compare.quiet.{editor}", [q for q in quiet if q >= 0], name)
                record(f"compare.memory.{editor}", memory, name, "MB")
        finally:
            shutil.rmtree(data, ignore_errors=True)


# ---- profiles


PROFILES = [
    # name, scenario, target, environment, seconds to sample
    ("launch", "launch", "note-5k.md", {}, 3),
    ("open-5k", "open", "note-5k.md", {"MARKO_PERF_COUNT": 20}, 12),
    ("open-600k", "open", "doc-600k.md", {"MARKO_PERF_COUNT": 12}, 12),
    ("typing-600k", "typing", "doc-600k.md", {"MARKO_PERF_PROFILE": 1, "MARKO_PERF_COUNT": 12, "MARKO_PERF_OFFSETS": "middle"}, 14),
    ("typing-5k", "typing", "note-5k.md", {"MARKO_PERF_PROFILE": 1, "MARKO_PERF_COUNT": 12, "MARKO_PERF_OFFSETS": "middle"}, 14),
    ("typing-images", "typing", "images-200.md", {"MARKO_PERF_PROFILE": 1, "MARKO_PERF_COUNT": 8, "MARKO_PERF_OFFSETS": "middle"}, 14),
    ("resize-5k", "resize", "note-5k.md", {"MARKO_PERF_COUNT": 800}, 12),
    ("typing-table", "typing", "table-2000.md", {"MARKO_PERF_PROFILE": 1, "MARKO_PERF_COUNT": 3, "MARKO_PERF_OFFSETS": "tableMiddle"}, 20),
    ("scroll-600k", "scroll", "doc-600k.md", {"MARKO_PERF_PROFILE": 1, "MARKO_PERF_COUNT": 600}, 12),
    ("open-images", "open", "images-200.md", {"MARKO_PERF_COUNT": 6}, 12),
    ("scroll-images", "scroll", "images-200.md", {"MARKO_PERF_PROFILE": 1, "MARKO_PERF_COUNT": 300}, 12),
    ("folder", "folder", "tree-20k", {"MARKO_PERF_EXPAND": "flat,*"}, 12),
]


def profile():
    """Samples the main thread about once a millisecond while a scenario runs and prints where its
    time goes; see `hot`. The reports stay in build/perf/profiles; --again reads them again."""
    build_helper()
    out = os.path.join(ROOT, "build", "perf", "profiles")
    os.makedirs(out, exist_ok=True)
    for name, scenario, target, env, seconds in PROFILES:
        if options.only and name not in options.only.split(","):
            continue
        report = os.path.join(out, f"{name}.sample.txt")
        if not options.again:
            folder, path = scratch_copy(target) if scenario == "typing" else (None, doc(target))
            if "MARKO_PERF_OFFSETS" in env:
                env = {**env, "MARKO_PERF_OFFSETS": offsets(target, [env["MARKO_PERF_OFFSETS"]])}
            env = environment({"MARKO_PERF": scenario, "MARKO_PERF_TIMEOUT": 120, "MARKO_PERF_ACTIVATE": 1, **env})
            # The app is made stopped, so that the sampler is watching when its first instruction runs.
            subprocess.run([HELPER, "sample", report, str(seconds), "--", BIN] + ARGS + [path], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=200)
            if folder:
                shutil.rmtree(folder, ignore_errors=True)
        print(f"== {name}: {report}")
        if options.tree:
            tree(report, options.tree)
            continue
        shown = [entry for entry in hot(report) if not options.match or re.search(options.match, entry[2])]
        for count, share, symbol in shown[: options.top]:
            print(f"{count:6d} {share:5.1f}%  {symbol[:150]}")


IDLE = ("__CFRunLoopServiceMachPort", "dyld4::RemoteNotificationResponder", "_dyld_start", "__semwait_signal", "__ulock_wait")


def graph(report):
    """The main thread's call graph from a `sample` report as [symbol, samples, parent, depth], and
    the number of samples in which the thread was doing something. Only those are counted. Left
    out: waiting for events, the stopped process before the sampler let it go, and dyld telling
    the sampler of each library it loads, which only happens because the sampler is there."""
    with open(report, errors="replace") as file:
        lines = file.read().splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("Call graph:")) + 1
    except StopIteration:
        return [], 0
    nodes, stack, threads = [], [], 0  # [symbol, samples, parent, depth, samples of its callees as reported]
    for line in lines[start:]:
        match = re.match(r"^([ +!:|]*)(\d+) (.*)$", line)
        if not match:
            break
        depth, count, rest = len(match.group(1)), int(match.group(2)), match.group(3)
        if rest.startswith("Thread_"):
            threads += 1
            if threads > 1:
                break
            continue
        symbol = re.sub(r"\s+\(in [^)]*\).*$", "", rest)
        symbol = re.sub(r"\s+\+ \d+.*$", "", symbol)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        parent = stack[-1][1] if stack else None
        if parent is not None:
            nodes[parent][4] += count
        nodes.append([symbol, count, parent, len(stack), 0])
        stack.append((depth, len(nodes) - 1))
    # From the leaves up: a function's samples are its own and those of its callees that count.
    for node in nodes:
        node[1] = 0 if node[0].startswith(IDLE) else node[1] - node[4]
    for index in range(len(nodes) - 1, -1, -1):
        symbol, count, parent = nodes[index][:3]
        if parent is not None and not nodes[parent][0].startswith(IDLE) and not symbol.startswith(IDLE):
            nodes[parent][1] += count
    for index, node in enumerate(nodes):
        # Under something that waits, nothing counts.
        if node[2] is not None and (nodes[node[2]][1] == 0 or nodes[node[2]][0].startswith(IDLE)):
            node[1] = 0
    return [node[:4] for node in nodes], sum(node[1] for node in nodes if node[2] is None)


def hot(report):
    """For each function, the samples in which it or anything it calls was running, and their
    share of the samples in which the main thread was doing something."""
    nodes, total = graph(report)
    below = [0] * len(nodes)
    for symbol, count, parent, _ in nodes:
        if parent is not None:
            below[parent] += count
    counts = {}
    for index, (symbol, count, parent, _) in enumerate(nodes):
        own = count - below[index]
        names = {symbol}
        while parent is not None:
            names.add(nodes[parent][0])
            parent = nodes[parent][2]
        for name in names:
            counts[name] = counts.get(name, 0) + own
    return sorted(((count, 100 * count / total, symbol) for symbol, count in counts.items() if count > 0), reverse=True) if total else []


def tree(report, share):
    """The call graph itself, down to the calls that have at least `share` percent of the samples."""
    nodes, total = graph(report)
    for symbol, count, parent, depth in nodes:
        if total and 100 * count / total >= share:
            print(f"{count:6d} {100 * count / total:5.1f}%  {'  ' * min(depth, 40)}{symbol[:110]}")


def report():
    """The results file as a Markdown table."""
    with open(options.out) as file:
        entries = [json.loads(line) for line in file if line.startswith("{")]
    print("| Metric | Document | Median | Min | p95 | Max | n |")
    print("| :--- | :--- | ---: | ---: | ---: | ---: | ---: |")
    for e in entries:
        if "metric" in e:
            print(f"| {e['metric']} | {e['doc']} | {e['median']:g} {e['unit']} | {e['min']:g} | {e['p95']:g} | {e['max']:g} | {e['n']} |")


COMMANDS = {"size": size, "launch": launch, "turns": turns, "cli": cli, "open": open_, "typing": typing, "scroll": scroll, "resize": resize,
            "floor": floor, "switch": switch, "folder": folder, "idle": idle, "compare": compare, "profile": profile, "report": report}


def main():
    global options
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("commands", nargs="+", choices=list(COMMANDS))
    parser.add_argument("--corpus", default=os.environ.get("MARKO_PERF_CORPUS", ""))
    parser.add_argument("--runs", type=int, default=0, help="processes per measurement instead of each command's own number")
    parser.add_argument("--quick", action="store_true", help="at most two runs of everything")
    parser.add_argument("--out", default="", help="append the JSON lines to this file")
    parser.add_argument("--background", action="store_true", help="never bring the app to the front (noisier numbers)")
    parser.add_argument("--only", default="", help="profile: only these, comma-separated; launch, open, typing, scroll, resize: only these documents; compare: only these editors")
    parser.add_argument("--frame-gap", type=float, default=8, help="scroll: milliseconds between frames (8)")
    parser.add_argument("--width", type=float, default=0, help="resize: the width to start from instead of the window's own (1500: only the margins change)")
    parser.add_argument("--against", action="append", default=[], help="turns: another Marko.app to launch in turn with this one; may be given more than once")
    parser.add_argument("--check", action="store_true", help="fail when a median that was measured is over its budget (BUDGETS)")
    parser.add_argument("--top", type=int, default=45, help="profile: how many functions to print")
    parser.add_argument("--tree", type=float, default=0, help="profile: print the call graph down to this share in percent")
    parser.add_argument("--match", default="", help="profile: only functions matching this expression")
    parser.add_argument("--again", action="store_true", help="profile: read the reports of the last run instead of sampling")
    options = parser.parse_args()
    if options.commands != ["report"]:
        if not os.path.exists(BIN):
            raise SystemExit("build/Marko.app is missing: run scripts/build-app.sh")
        if not os.path.exists(os.path.join(options.corpus, "corpus.json")) and options.commands != ["size"]:
            raise SystemExit("no corpus: run scripts/perf/gen.py <folder> and pass --corpus <folder>")
    if set(options.commands) - {"report", "size"}:
        # The first start after a build pays for the system's check of the new binary (0.5 s was seen).
        run("launch", doc("note-5k.md"))
    for command in options.commands:
        before = load()
        started = len(results)
        if command not in ("report", "profile", "size"):
            # The same every time: says how this run's numbers compare with another run's.
            record("control.true", [spawn(["/usr/bin/true"], environment({})) for _ in range(20)], command,
                   note="/usr/bin/true, the cost of making any process, just before this part")
        COMMANDS[command]()
        if command not in ("report", "profile"):
            line = {"command": command, "load1": [before, load()], "app": APP}
            if command == "scroll":
                line["frameGap"] = options.frame_gap
            print(json.dumps(line), flush=True)
            if options.out:
                with open(options.out, "a") as file:
                    for entry in results[started:] + [line]:
                        file.write(json.dumps(entry) + "\n")
    if options.check:
        failed = 0
        for metric, name, limit in BUDGETS:
            found = [entry for entry in results if entry["metric"] == metric and entry["doc"] == name]
            if found:
                over = found[-1]["median"] > limit
                failed += over
                print(f"check: {'FAIL' if over else 'ok  '} {metric} {name}: {found[-1]['median']:g} {found[-1]['unit']} (budget {limit:g})", flush=True)
        if failed:
            raise SystemExit(f"check: {failed} over budget")


if __name__ == "__main__":
    main()
