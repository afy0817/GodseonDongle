#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
"""Checks app/Resources/en.lproj/GodseonDongle.strings against the t("...") calls in the app.

The app's strings are written in Korean inside t(...); the lookup key is the literal with each
interpolation replaced by %@. Prints keys without an English translation, translations no
longer used, and Korean literals that are not wrapped in t(...). Exits 1 if any are missing.
    python3 app/tools/check_strings.py
"""
import pathlib
import plistlib
import re
import subprocess
import sys

APP = pathlib.Path(__file__).resolve().parent.parent
HANGUL = re.compile(r"[\uac00-\ud7a3\u3131-\u318e]")
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0", "r": "\r"}


def literals(src):
    """(start, segments) for every single-line string literal, nested ones included."""
    found, n = [], len(src)

    def code(i, until_paren):
        depth = 0
        while i < n:
            if src.startswith("//", i):
                i = src.find("\n", i) if "\n" in src[i:] else n
            elif src.startswith("/*", i):
                i = src.index("*/", i + 2) + 2
            elif src[i] == '"':
                i = string(i)
            else:
                if src[i] == "(":
                    depth += 1
                elif src[i] == ")":
                    if depth == 0 and until_paren:
                        return i
                    depth -= 1
                i += 1
        return i

    def string(start):
        segments, i = [""], start + 1
        while src[i] != '"':
            if src[i] == "\\" and src[i + 1] == "(":
                i = code(i + 2, True) + 1
                segments.append("")
            elif src[i] == "\\" and src[i + 1] == "u":
                m = re.match(r"\\u\{([0-9a-fA-F]+)\}", src[i:])
                segments[-1] += chr(int(m.group(1), 16))
                i += len(m.group(0))
            elif src[i] == "\\":
                segments[-1] += ESCAPES[src[i + 1]]
                i += 2
            else:
                segments[-1] += src[i]
                i += 1
        found.append((start, segments))
        return i + 1

    code(0, False)
    return found


def main():
    used, unwrapped = {}, []
    for path in sorted((APP / "Sources").rglob("*.swift")):
        src = path.read_text(encoding="utf-8")
        for start, segments in literals(src):
            if not any(HANGUL.search(s) for s in segments):
                continue
            where = "%s:%d" % (path.relative_to(APP), src.count("\n", 0, start) + 1)
            wrapped = src[max(0, start - 2):start] == "t(" and not re.match(r"[\w]", src[start - 3:start - 2])
            verbatim = re.search(r"verbatim:\s*$", src[max(0, start - 12):start]) is not None
            if wrapped:
                used.setdefault("%@".join(segments), where)
            elif not verbatim:
                unwrapped.append(where)
    table_path = APP / "Resources/en.lproj/GodseonDongle.strings"
    plist = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", str(table_path)],
                           check=True, capture_output=True).stdout
    table = plistlib.loads(plist)
    missing = sorted(k for k in used if k not in table)
    unused = sorted(k for k in table if k not in used)
    for key in missing:
        print("missing  %s  %r" % (used[key], key))
    for key in unused:
        print("unused   %r" % key)
    for where in unwrapped:
        print("not in t(...)  %s" % where)
    print("%d keys, %d translated" % (len(used), len(used) - len(missing)))
    sys.exit(1 if missing else 0)


main()
