#!/usr/bin/env python3
"""Summarizes the kcov report from `zig build coverage` as Markdown: the
total, one row per file, and every line no test reached.

Usage: tools/coverage_summary.py [zig-out/coverage]
"""

import json
import os
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

report = os.path.join(sys.argv[1] if len(sys.argv) > 1 else "zig-out/coverage", "kcov-merged")
total = json.load(open(os.path.join(report, "coverage.json")))
cobertura = ET.parse(os.path.join(report, "cobertura.xml")).getroot()
sources = [s.text for s in cobertura.iter("source")]


def locate(name):
    """Cobertura names files relative to one of its source roots."""
    for root in sources:
        path = os.path.join(root, name)
        if os.path.exists(path):
            return path
    return name


def shown(path):
    """The path from src/ on, as the repository shows it."""
    return "src/" + path.split("/src/", 1)[1] if "/src/" in path else path


missed = defaultdict(list)
for cls in cobertura.iter("class"):
    for line in cls.iter("line"):
        if line.get("hits") == "0":
            missed[locate(cls.get("filename"))].append(int(line.get("number")))

print(f"## Line coverage: {total['percent_covered']}%\n")
print(
    f"{total['covered_lines']} of {total['total_lines']} lines ran. kcov counts "
    "lines, not branches, and sees only code the compiler kept.\n"
)
print("| File | Coverage | Lines |")
print("| --- | ---: | ---: |")
for f in sorted(total["files"], key=lambda f: (float(f["percent_covered"]), f["file"])):
    print(f"| `{shown(f['file'])}` | {f['percent_covered']}% | {f['covered_lines']} of {f['total_lines']} |")

count = sum(len(lines) for lines in missed.values())
print(f"\n<details><summary>{count} lines no test reached</summary>\n\n```")
for path in sorted(missed):
    text = open(path).read().split("\n") if os.path.exists(path) else []
    for n in sorted(missed[path]):
        print(f"{shown(path)}:{n}: {text[n - 1].strip() if n <= len(text) else ''}")
print("```\n\n</details>")
