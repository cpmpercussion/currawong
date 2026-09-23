#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# Fails if a change touches anything in a Swift file other than comments and
# blank lines.
#
#   scripts/comment-only-diff.py              # working tree against HEAD
#   scripts/comment-only-diff.py origin/main  # working tree against a base
#
# A comment-only pass has no test coverage, so this is what makes a large one
# safe to review: strip `//` and `/* */` comments and blank lines from both
# sides, and the code that is left must be identical. Leading and trailing
# whitespace is ignored, so re-indenting a comment is not a code change.
#
# Exits 0 and prints nothing when the change is comment-only; otherwise prints
# a diff of the code that changed and exits 1.

import difflib
import subprocess
import sys


def strip_comments(source):
    """Swift source with comments and blank lines removed, one stripped line
    per remaining line. Knows enough about string literals (including
    multi-line `\"\"\"` ones) not to mistake `"https://"` for a comment."""
    out, line = [], []
    i, n = 0, len(source)
    in_block = 0       # nesting depth of /* */, which Swift allows
    in_string = None   # None, '"' or '"""'
    while i < n:
        c = source[i]
        if in_block:
            if source.startswith("/*", i):
                in_block += 1
                i += 2
            elif source.startswith("*/", i):
                in_block -= 1
                i += 2
            else:
                if c == "\n":
                    out.append("".join(line))
                    line = []
                i += 1
            continue
        if in_string:
            if c == "\\":
                line.append(source[i:i + 2])
                i += 2
                continue
            if source.startswith(in_string, i):
                line.append(in_string)
                i += len(in_string)
                in_string = None
                continue
            if c == "\n":
                out.append("".join(line))
                line = []
            else:
                line.append(c)
            i += 1
            continue
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
            continue
        if source.startswith("/*", i):
            in_block = 1
            i += 2
            continue
        if source.startswith('"""', i):
            in_string = '"""'
            line.append('"""')
            i += 3
            continue
        if c == '"':
            in_string = '"'
        if c == "\n":
            out.append("".join(line))
            line = []
        else:
            line.append(c)
        i += 1
    out.append("".join(line))
    return [l.strip() for l in out if l.strip()]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    changed = git("diff", "--name-only", "--diff-filter=AMD", base, "--", "*.swift").split()
    failed = False
    for path in changed:
        try:
            before = git("show", f"{base}:{path}")
        except subprocess.CalledProcessError:
            before = ""
        try:
            with open(path) as f:
                after = f.read()
        except FileNotFoundError:
            after = ""
        a, b = strip_comments(before), strip_comments(after)
        if a != b:
            failed = True
            sys.stdout.writelines(
                l + "\n" for l in difflib.unified_diff(a, b, f"{base}:{path}", path, lineterm="")
            )
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
