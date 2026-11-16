#!/usr/bin/env python3
"""Makes the documents and folders the measurements run on. The same seed gives the same files.

    gen.py <folder>

Writes note-5k.md, doc-90k.md, doc-100k.md, doc-600k.md, doc-5m.md (mixed Markdown), table-2000.md (one table of
2,000 rows), table-wide.md (the same with one wide row, so that typing in another moves no column),
table-source.md (the same with a row too wide for the window, so that it shows as source),
list-500k.md (one list of 16,000 items: a single block), list-74k.md (the same with 2,400 items), images-200.md with img/ (200 local
pictures), paste-50k.md, notes/ (a few files to switch between), tree-20k/ (20,000 files) and
corpus.json: sizes and the places to type at, as UTF-16 offsets.
"""
import json
import os
import random
import struct
import sys
import zlib

WORDS = """the of and to in is that for it as was with be by on not he this are or his from at which but have an
had they you were their one all we can her has there been if more when will would who so no out up into than them
only time some could these two may then do first any my now such like our over man me even most made after also
did many before must through years where much your way well down should because each just those people how too
little state good very make world still own see men work long get here between both life being under never day
same another know while last might us great old year off come since against go came right used take three note
draft table editor window folder launch render quickly simple""".split()
EXTRA = ["café", "naïve", "Zürich", "東京", "日本語", "🚀", "✅", "über", "señor", "— dash —"]
CODE = {
    "swift": ["import Foundation", "", "struct Point {", "    var x: Double", "    var y: Double // metres", "}", "",
              "func length(_ p: Point) -> Double {", "    return (p.x * p.x + p.y * p.y).squareRoot()", "}",
              'print("length: \\(length(Point(x: 3, y: 4)))")'],
    "python": ["import os", "", "def walk(root):", '    """Yield every file under root."""',
               "    for folder, _, files in os.walk(root):", "        for name in files:",
               "            yield os.path.join(folder, name)  # full path", "", "print(sum(1 for _ in walk('.')))"],
    "js": ["const fs = require('fs');", "", "function count(dir) {", "  // entries of one folder",
           "  return fs.readdirSync(dir).length;", "}", "console.log(`files: ${count('.')}`);"],
}


def utf16(text):
    return len(text.encode("utf-16-le")) // 2


class Mixed:
    """Markdown as people write it: headings, long paragraphs with inline markup, lists, quotes,
    code, small tables. Remembers where its plain paragraphs start."""

    def __init__(self, seed):
        self.random = random.Random(seed)
        self.parts = []
        self.length = 0  # UTF-16 units so far
        self.bytes = 0
        self.paragraphs = []  # offsets a few words into a paragraph

    def add(self, text):
        self.parts.append(text)
        self.length += utf16(text)
        self.bytes += len(text.encode())

    def words(self, low, high):
        r = self.random
        out = []
        for _ in range(r.randint(low, high)):
            word = r.choice(WORDS) if r.random() > 0.02 else r.choice(EXTRA)
            roll = r.random()
            if roll < 0.03:
                word = f"**{word} {r.choice(WORDS)}**"
            elif roll < 0.06:
                word = f"*{word}*"
            elif roll < 0.08:
                word = f"`{word}_{r.randint(1, 99)}`"
            elif roll < 0.095:
                word = f"[{word} {r.choice(WORDS)}](https://example.com/{word}/{r.randint(1, 999)})"
            elif roll < 0.1:
                word = f"~~{word}~~"
            out.append(word)
        return " ".join(out)

    def sentence_block(self, low, high):
        r = self.random
        sentences = []
        for _ in range(r.randint(low, high)):
            s = self.words(6, 18)
            sentences.append(s[0].upper() + s[1:] + r.choice([".", ".", ".", "?", "!"]))
        return " ".join(sentences)

    def paragraph(self):
        text = self.sentence_block(2, 7)
        # Past the first word, which may be markup.
        self.paragraphs.append(self.length + utf16(text[: text.index(" ", 12) + 1]))
        self.add(text + "\n\n")

    def section(self):
        r = self.random
        self.add(f"{'#' * r.choice([1, 2, 2, 2, 3, 3])} {self.words(2, 6).title()}\n\n")
        for _ in range(r.randint(2, 6)):
            kind = r.random()
            if kind < 0.5:
                self.paragraph()
            elif kind < 0.62:
                for _ in range(r.randint(3, 8)):
                    self.add(f"- {self.words(3, 14)}\n")
                    if r.random() < 0.3:
                        self.add(f"  - {self.words(3, 10)}\n")
                self.add("\n")
            elif kind < 0.7:
                for number in range(1, r.randint(3, 7)):
                    self.add(f"{number}. {self.words(3, 14)}\n")
                self.add("\n")
            elif kind < 0.76:
                for _ in range(r.randint(2, 6)):
                    self.add(f"- [{r.choice('x ')}] {self.words(3, 10)}\n")
                self.add("\n")
            elif kind < 0.84:
                for _ in range(r.randint(1, 3)):
                    self.add(f"> {self.sentence_block(1, 3)}\n")
                self.add("\n")
            elif kind < 0.93:
                language = r.choice(list(CODE))
                self.add(f"```{language}\n" + "\n".join(CODE[language]) + "\n```\n\n")
            elif kind < 0.98:
                self.add("| Name | Value | Note |\n| :--- | ---: | :---: |\n")
                for _ in range(r.randint(2, 6)):
                    self.add(f"| {self.words(1, 2)} | {r.randint(1, 9999)} | {self.words(1, 4)} |\n")
                self.add("\n")
            else:
                self.add("---\n\n")

    def build(self, size):
        self.add(f"# {self.words(2, 5).title()}\n\n")
        self.paragraph()
        while self.bytes < size:
            self.section()
        self.paragraph()
        return "".join(self.parts)

    def offsets(self):
        middle = min(self.paragraphs, key=lambda offset: abs(offset - self.length // 2))
        return {"top": self.paragraphs[0], "middle": middle, "end": self.paragraphs[-1]}


def table_document(rows, wide=0):
    """`wide`: the length of the item in row 5, which is then the widest of its column by far."""
    r = random.Random(7)
    head = "# Inventory\n\nEvery item in the store room, counted on the first of the month.\n\n"
    parts = [head, "| No | Item | Kind | Code | Price |\n", "| ---: | :--- | :--- | :---: | ---: |\n"]
    offsets = {"above": utf16(head) - 20}
    length = sum(utf16(p) for p in parts)
    for row in range(1, rows + 1):
        item = f"{r.choice(WORDS)} {r.choice(WORDS)}"
        if wide and row == 5:
            item = ("a long name that makes this column wide " * 4)[:wide].strip()
        kind = r.choice(["**new**", "*used*", "plain", "spare"])
        line = f"| {row} | {item} | {kind} | `c{r.randint(100, 999)}` | {r.randint(1, 999)}.{r.randint(10, 99)} |\n"
        if row in (2, rows // 2, rows - 1):
            # In the middle of the item's name.
            name = {2: "tableTop", rows // 2: "tableMiddle", rows - 1: "tableEnd"}[row]
            offsets[name] = length + utf16(line[: line.index(item) + 3])
        parts.append(line)
        length += utf16(line)
    tail = "\nThat is all of it.\n"
    offsets["below"] = length + 6
    parts.append(tail)
    return "".join(parts), offsets


def list_document(items):
    """One tight list and nothing else: a block as long as the text."""
    r = random.Random(9)
    head = "# List\n\n"
    lines = [f"- {' '.join(r.choice(WORDS) for _ in range(6))}\n" for _ in range(items)]
    middle = utf16(head) + sum(utf16(line) for line in lines[: items // 2]) + 6
    return head + "".join(lines), {"middle": middle}


def png(width, height, seed):
    """A picture that does not compress to nothing, as a photograph does not: a smooth row, shifted
    from row to row, with noise in the low bits."""
    r = random.Random(seed)
    value, base = [r.randint(0, 255) for _ in range(3)], bytearray()
    for _ in range(width):
        value = [min(255, max(0, v + r.randint(-6, 6))) for v in value]
        base += bytes(value)
    size = len(base)
    mask = int.from_bytes(b"\x07" * size, "big")
    rows = bytearray()
    for y in range(height):
        shift = (y * 3) % size
        row = int.from_bytes(base[shift:] + base[:shift], "big") ^ (int.from_bytes(r.randbytes(size), "big") & mask)
        rows += b"\x00" + row.to_bytes(size, "big")

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")


def images_document(folder, count):
    os.makedirs(os.path.join(folder, "img"), exist_ok=True)
    # Eight different pictures under 200 names; the names are links to save room on the disk.
    kinds = []
    for seed in range(8):
        kinds.append(os.path.join(folder, "img", f"kind-{seed}.png"))
        with open(kinds[-1], "wb") as file:
            file.write(png(1024, 768, seed))
    mixed = Mixed(11)
    mixed.add("# Pictures\n\n")
    for index in range(count):
        name = os.path.join(folder, "img", f"picture-{index:03}.png")
        if os.path.lexists(name):
            os.remove(name)
        os.link(kinds[index % len(kinds)], name)
        mixed.add(f"![Picture {index}](img/picture-{index:03}.png)\n\n")
        mixed.paragraph()
    return "".join(mixed.parts), mixed.offsets()


def tree(root, note):
    """20,000 files: one folder of 5,000 and 75 folders of 200, with a README to open on."""
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "README.md"), "w") as file:
        file.write(note)

    def fill(folder, count):
        os.makedirs(folder, exist_ok=True)
        for index in range(count):
            extension = "md" if index % 4 else "txt"
            with open(os.path.join(folder, f"file-{index:04}.{extension}"), "w") as file:
                file.write(f"# File {index}\n")

    fill(os.path.join(root, "flat"), 5000)
    for index in range(75):
        fill(os.path.join(root, f"dir-{index:03}"), 200)


def main(folder):
    os.makedirs(folder, exist_ok=True)
    corpus = {}

    def write(name, text, offsets):
        with open(os.path.join(folder, name), "w", encoding="utf-8", newline="") as file:
            file.write(text)
        corpus[name] = {"bytes": len(text.encode()), "lines": text.count("\n"), "units": utf16(text), "offsets": offsets}

    # doc-90k.md is just under the size up to which the editor parses on every key, doc-100k.md just over it.
    for name, size, seed in [("note-5k.md", 5_000, 1), ("doc-90k.md", 90_000, 6), ("doc-100k.md", 100_000, 2),
                             ("doc-600k.md", 600_000, 3), ("doc-5m.md", 5_000_000, 4)]:
        mixed = Mixed(seed)
        write(name, mixed.build(size), mixed.offsets())
    write("table-2000.md", *table_document(2000))
    # Typed in at one place, the middle row: what the other places cost is in table-2000.md.
    for name, wide in [("table-wide.md", 67), ("table-source.md", 110)]:
        text, offsets = table_document(2000, wide=wide)
        write(name, text, {"tableMiddle": offsets["tableMiddle"]})
    write("list-500k.md", *list_document(16000))
    # Under the size up to which every key is parsed at once: a key there pays for its block.
    write("list-74k.md", *list_document(2400))
    write("images-200.md", *images_document(folder, 200))
    write("paste-50k.md", Mixed(5).build(50_000), {})

    notes = os.path.join(folder, "notes")
    os.makedirs(notes, exist_ok=True)
    for name, size, seed in [("README.md", 2_000, 20), ("a.md", 5_000, 21), ("b.md", 5_000, 22), ("c.md", 100_000, 23)]:
        with open(os.path.join(notes, name), "w", encoding="utf-8") as file:
            file.write(Mixed(seed).build(size))
    tree(os.path.join(folder, "tree-20k"), Mixed(30).build(5_000))
    with open(os.path.join(folder, "corpus.json"), "w") as file:
        json.dump(corpus, file, indent=1)
    for name, entry in corpus.items():
        print(f"{name}: {entry['bytes']} bytes, {entry['lines']} lines")


if __name__ == "__main__":
    main(sys.argv[1])
