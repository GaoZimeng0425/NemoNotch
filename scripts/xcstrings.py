#!/usr/bin/env python3
"""Canonical (de)serializer for the `*.xcstrings` String Catalog.

WHY THIS EXISTS
---------------
`*.xcstrings` is JSON, but Xcode's String Catalog editor writes it in a specific
non-standard style that a naive `json.dump(indent=2)` does NOT match — and
mismatching it reformats *every line* (thousands of bogus diff lines for a
one-key change). We keep the file in **Xcode's own format** so that editing in
the Xcode GUI produces zero churn; `dump_canonical()` reproduces that format
BYTE-FOR-BYTE (verified against a committed catalog). A `pre-commit` hook runs
`format` on any staged `*.xcstrings`, so hand-edits / script edits are pulled
back to the exact same bytes Xcode would write — edit however you like (GUI or
this script), the committed file is always canonical.

Xcode's format rules, all reproduced below:
  - 2-space indent, `" : "` key separator (a space on BOTH sides of the colon)
  - no ASCII escaping (CJK stays literal)
  - insertion order preserved — keys are NEVER sorted
  - empty objects expanded to the multi-line form `{\n\n<indent>}`
  - NO trailing newline

THIS IS THE ONE SERIALIZATION CONTRACT — never hand-edit with an ad-hoc
serializer that sorts keys or changes the separator; go through this module or
the Xcode GUI (the pre-commit hook reconciles either).

USAGE
-----
  scripts/xcstrings.py check  [file]                 # exit 1 if not canonical
  scripts/xcstrings.py format [file]                 # rewrite canonically in place
  scripts/xcstrings.py set    [file] KEY --en E --zh Z   # add/update a key, then format

`file` defaults to NemoNotch/Resources/Localizable.xcstrings.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_FILE = "NemoNotch/Resources/Localizable.xcstrings"

# Expands a single-line empty object `<body> : {}` to Xcode's multi-line form,
# with the closing brace re-indented to the line's own indent.
_EMPTY_OBJ = re.compile(r"(?m)^(?P<indent> *)(?P<body>.*?) : \{\}(?P<comma>,?)$")


def dump_canonical(obj) -> str:
    """Serialize `obj` exactly as Xcode's String Catalog editor would: 2-space
    indent, ' : ' key separator, no ASCII escaping (CJK stays literal), insertion
    order preserved (never sorted), empty objects expanded, and NO trailing
    newline."""
    s = json.dumps(obj, indent=2, ensure_ascii=False, separators=(",", " : "))
    return _EMPTY_OBJ.sub(
        lambda m: f"{m['indent']}{m['body']} : {{\n\n{m['indent']}}}{m['comma']}",
        s,
    )


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def translated_unit(en: str, zh: str) -> dict:
    """A fully-translated (en + zh-Hans) string entry. `state: "translated"`
    keeps Xcode's build-time extraction from re-touching the entry."""
    return {
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": en}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
        }
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Canonical Xcode .xcstrings tool")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check", help="exit 1 if file is not canonical")
    p_check.add_argument("file", nargs="?", default=DEFAULT_FILE)

    p_fmt = sub.add_parser("format", help="rewrite file canonically in place")
    p_fmt.add_argument("file", nargs="?", default=DEFAULT_FILE)

    p_set = sub.add_parser("set", help="add/update a translated key, then format")
    p_set.add_argument("file", nargs="?", default=DEFAULT_FILE)
    p_set.add_argument("key")
    p_set.add_argument("--en", required=True)
    p_set.add_argument("--zh", required=True)

    args = ap.parse_args()
    path = Path(args.file)
    original = path.read_text(encoding="utf-8")
    data = json.loads(original)

    if args.cmd == "check":
        if dump_canonical(data) != original:
            print(f"{path}: NOT canonical — run `scripts/xcstrings.py format`", file=sys.stderr)
            return 1
        print(f"{path}: canonical")
        return 0

    if args.cmd == "set":
        data["strings"][args.key] = translated_unit(args.en, args.zh)

    path.write_text(dump_canonical(data), encoding="utf-8")
    print(f"{path}: written canonically ({len(data['strings'])} keys)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
