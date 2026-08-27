#!/usr/bin/env python3
"""Structural checks after any automatic conflict resolution.

Three independent classes of damage were observed on the first rebuild, and
NO single check catches all three:

  1. leftover conflict markers            -> marker scan
  2. spliced function bodies              -> brace balance
  3. a function emitted twice with        -> duplicate top-level declarations
     identical bodies and balanced braces    (brace balance passes this)
  4. several <resources> roots merged     -> XML parse
     into one file

Run over the files an integration touched. Exit 1 if anything is damaged.
"""
import re, subprocess, sys, xml.etree.ElementTree as ET

def code_only(text):
    out, incomment = [], False
    for line in text.split("\n"):
        s = line
        if incomment:
            if "*/" in s:
                s = s.split("*/", 1)[1]; incomment = False
            else:
                continue
        while "/*" in s:
            pre, rest = s.split("/*", 1)
            if "*/" in rest:
                s = pre + rest.split("*/", 1)[1]
            else:
                s = pre; incomment = True; break
        s = re.sub(r"//.*$", "", s)
        s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
        out.append(s)
    return "\n".join(out)

DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:internal |private |public |protected )?(?:suspend )?fun\s+[^\s(]+")

def check(path):
    problems = []
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, FileNotFoundError):
        return problems                      # binary or deleted: not ours to judge

    if "<<<<<<< " in text or ">>>>>>> " in text:
        problems.append("conflict markers")

    if path.endswith((".kt", ".kts")):
        c = code_only(text)
        if c.count("{") != c.count("}"):
            problems.append(f"unbalanced braces ({c.count('{')} open, {c.count('}')} close)")
        sigs = [m.group(0).strip() for m in (DECL.match(l) for l in text.split("\n")) if m]
        dupes = {s for s in sigs if sigs.count(s) > 1}
        if dupes:
            problems.append("duplicate declarations: " + ", ".join(sorted(dupes)[:3]))

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
