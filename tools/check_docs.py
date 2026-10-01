#!/usr/bin/env python3
"""Checks the Markdown documentation, offline:

- every relative link and image names a file or directory that exists,
  with the case GitHub will see, which a case-insensitive file system
  would not catch;
- every #anchor names a heading, or an <a id> or <a name>, in its file,
  as GitHub makes them;
- every code block that follows `<!-- snippet: PATH -->` equals that file
  without its leading `//!` comment, and every one that follows
  `<!-- snippet: PATH#NAME -->` equals the lines between `// snippet: NAME`
  and `// end snippet` there, so the code the docs show is code that
  compiles and runs;
- every page under docs/ is linked from another page.

What code blocks, inline code and HTML comments hold is not checked, as
GitHub renders none of it as a link.

    python3 tools/check_docs.py

Covers every Markdown file git tracks or would track. External links are
not fetched. Prints each problem as `file:line: message` and exits 1 if
there are any."""

import difflib
import os
import re
import subprocess
import sys
import textwrap
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
HTML_ANCHOR = re.compile(r"""<a\s+(?:[^>]*\s)?(?:id|name)=["']([^"']+)["']""", re.IGNORECASE)
INLINE_CODE = re.compile(r"(`+)(?:(?!\1).)+?\1")
INLINE_LINK = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFERENCE_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
HTML_LINK = re.compile(r"""\b(?:href|src)=["']([^"']+)["']""", re.IGNORECASE)
# An HTML comment, which may span lines, and which HTML also ends at "--!>".
COMMENT = re.compile(r"<!--.*?--!?>", re.DOTALL)
COMMENT_END = re.compile(r"--!?>")
SNIPPET = re.compile(r"^\s*<!--\s*snippet:\s*([^\s#]+)(?:#(\S+))?\s*-->\s*$")
EXTERNAL = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)


def markdown_files():
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "*.md"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout
    return sorted(set(line for line in out.splitlines() if line))


def slug(text):
    """The id GitHub gives a heading: its text without markup, lowercased,
    every character but letters, digits, marks, '-', '_' and spaces
    dropped, and spaces made hyphens."""
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    kept = []
    for ch in text.lower():
        if ch in "-_ " or unicodedata.category(ch)[0] in "LNM":
            kept.append(ch)
    return "".join(kept).replace(" ", "-")


class Page:
    def __init__(self, path):
        self.path = path
        with open(os.path.join(ROOT, path), encoding="utf-8") as f:
            self.lines = f.read().split("\n")
        self.anchors = set()
        self.links = []  # (line number, target)
        self.snippets = []  # (line number, path, name, block lines)
        self.problems = []  # (line number, message)
        self.parse()

    def parse(self):
        seen = {}
        in_fence = None
        in_comment = False
        pending_snippet = None
        block = None
        for number, line in enumerate(self.lines, 1):
            if in_comment:
                end = COMMENT_END.search(line)
                if end is None:
                    continue
                line = line[end.end():]
                in_comment = False
            fence = FENCE.match(line)
            if in_fence:
                if fence and fence.group(1) == in_fence and line.strip() == in_fence:
                    in_fence = None
                    if block is not None:
                        self.snippets.append(block)
                        block = None
                elif block is not None:
                    block[3].append(line)
                continue
            if fence:
                in_fence = fence.group(1)
                if pending_snippet:
                    block = (*pending_snippet, [])
                    pending_snippet = None
                continue
            marker = SNIPPET.match(line)
            if marker:
                pending_snippet = (number, marker.group(1), marker.group(2))
                continue
            if pending_snippet and line.strip():
                self.problems.append((pending_snippet[0], "a snippet marker must be followed by a code block"))
                pending_snippet = None
            # What a comment holds is not rendered: no heading, no link.
            line = COMMENT.sub("", line)
            if "<!--" in line:
                line, in_comment = line[: line.index("<!--")], True
            heading = HEADING.match(line)
            if heading:
                base = slug(heading.group(2))
                count = seen.get(base, 0)
                seen[base] = count + 1
                self.anchors.add(base if count == 0 else f"{base}-{count}")
            for anchor in HTML_ANCHOR.findall(line):
                self.anchors.add(anchor)
            text = INLINE_CODE.sub("", line)
            for target in INLINE_LINK.findall(text) + HTML_LINK.findall(text):
                self.links.append((number, target))
            definition = REFERENCE_DEF.match(text)
            if definition:
                self.links.append((number, definition.group(1)))
        if pending_snippet:
            self.problems.append((pending_snippet[0], "a snippet marker must be followed by a code block"))


def exists_exactly(path):
    """Whether `path`, relative to the repository, exists with exactly this
    case in every component."""
    current = ROOT
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            current = os.path.dirname(current)
            continue
        try:
            names = os.listdir(current)
        except (NotADirectoryError, FileNotFoundError):
            return False
        if part not in names:
            return False
        current = os.path.join(current, part)
    return True


def snippet_source(path, name):
    """The text a snippet marker names, or an error message."""
    full = os.path.join(ROOT, path)
    if not exists_exactly(path):
        return None, f"snippet source {path} does not exist"
    with open(full, encoding="utf-8") as f:
        lines = f.read().split("\n")
    if name is None:
        start = 0
        while start < len(lines) and lines[start].startswith("//!"):
            start += 1
        while start < len(lines) and not lines[start].strip():
            start += 1
        return "\n".join(lines[start:]).rstrip("\n"), None
    begin = f"// snippet: {name}"
    try:
        first = next(i for i, l in enumerate(lines) if l.strip() == begin)
    except StopIteration:
        return None, f"{path} has no `{begin}`"
    try:
        last = next(i for i in range(first + 1, len(lines)) if lines[i].strip() == "// end snippet")
    except StopIteration:
        return None, f"{path}: `{begin}` has no `// end snippet`"
    return textwrap.dedent("\n".join(lines[first + 1:last])).rstrip("\n"), None


def main():
    os.chdir(ROOT)
    pages = {path: Page(path) for path in markdown_files()}
    problems = [(page.path, number, message) for page in pages.values() for number, message in page.problems]

    linked = set()
    for path, page in pages.items():
        here = os.path.dirname(path)
        for number, target in page.links:
            if EXTERNAL.match(target) or target.startswith("//"):
                continue
            file_part, _, anchor = target.partition("#")
            if file_part:
                resolved = os.path.normpath(os.path.join(here, file_part)).replace(os.sep, "/")
                if resolved.startswith(".."):
                    problems.append((path, number, f"{target} leaves the repository"))
                    continue
                if not exists_exactly(resolved):
                    problems.append((path, number, f"{target}: no such file or directory"))
                    continue
                linked.add(resolved)
            else:
                resolved = path
            if anchor and resolved.endswith(".md"):
                target_page = pages.get(resolved)
                if target_page is None:
                    problems.append((path, number, f"{target}: {resolved} is not a checked page"))
                elif anchor not in target_page.anchors:
                    near = difflib.get_close_matches(anchor, sorted(target_page.anchors), n=1)
                    hint = f"; did you mean #{near[0]}?" if near else ""
                    problems.append((path, number, f"{target}: no heading makes #{anchor}{hint}"))

        for number, source, name, block in page.snippets:
            want, error = snippet_source(source, name)
            if error:
                problems.append((path, number, error))
                continue
            got = "\n".join(block).rstrip("\n")
            if got != want:
                label = source + (f"#{name}" if name else "")
                diff = "\n".join(difflib.unified_diff(
                    want.split("\n"), got.split("\n"), label, path, lineterm="", n=1))
                problems.append((path, number, f"the block differs from {label}:\n{diff}"))

    for path in pages:
        if path.startswith("docs/") and path not in linked:
            problems.append((path, 1, "no other page links here"))

    for path, number, message in sorted(problems):
        print(f"{path}:{number}: {message}")
    if problems:
        print(f"{len(problems)} problem(s) in {len(pages)} pages")
        return 1
    print(f"{len(pages)} pages checked: links, anchors and snippets agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
