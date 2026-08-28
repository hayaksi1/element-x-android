#!/usr/bin/env python3
"""Structural checks after any automatic conflict resolution.

Three independent classes of damage were observed on the first rebuild, and
NO single check catches all three:

  1. leftover conflict markers            -> marker scan
  2. spliced function bodies              -> brace balance
  3. a function emitted twice with        -> duplicate declarations, scoped
     identical bodies and balanced braces    (brace balance passes this)
  4. several <resources> roots merged     -> XML parse
     into one file

The rules themselves are in .fork/lib/rr_semantic.py, shared with the rerere
cache audit, which needs the same questions asked of a recorded resolution.

Run over the files an integration touched. Exit 1 if anything is damaged.
"""
import os, re, subprocess, sys, xml.etree.ElementTree as ET

# The lexer and the structural rules live in .fork/lib/rr_semantic.py, which the
# rerere cache audit shares. There used to be a second copy here that stripped
# comments BEFORE strings, so `"text/*"` opened a block comment that swallowed
# the rest of the file -- 23 untouched files in this repository looked damaged
# to it. One implementation, one place to fix it.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from rr_semantic import (                              # noqa: E402
    code_only, delimiter_balance, duplicate_named_arg, empty_when,
    orphan_kdoc, redeclared_types, redeclared_valvar, unreachable,
)

def check(path):
    problems = []
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, FileNotFoundError):
        return problems                      # binary or deleted: not ours to judge

    if "<<<<<<< " in text or ">>>>>>> " in text:
        problems.append("conflict markers")

    if path.endswith((".kt", ".kts")):
        code = code_only(text)
        tick = code_only(text, keep_ticks=True)
        problems += delimiter_balance(code)
        problems += redeclared_valvar(code)
        problems += redeclared_types(tick)
        problems += duplicate_named_arg(code)
        problems += orphan_kdoc(code)
        problems += empty_when(code)
        problems += unreachable(code)

    if path.endswith(".xml"):
        try:
            ET.fromstring(text)
        except ET.ParseError as e:
            problems.append(f"invalid XML: {e}")

    return problems


def main(argv):
    if len(argv) > 1:
        files = argv[1:]
    else:
        files = subprocess.check_output(
            ["git", "diff", "--name-only", "develop...HEAD"], text=True).split()
    bad = 0
    for f in files:
        for p in check(f):
            print(f"  {f}: {p}")
            bad += 1
    print(f"structural check: {len(files)} file(s), {bad} problem(s)")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
