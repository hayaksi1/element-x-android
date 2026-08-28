#!/usr/bin/env python3
"""Semantic checks for a rerere cache entry, and the Kotlin primitives they use.

The cache audit in .fork/lib/audit.sh asks three syntactic questions -- are the
conflict markers gone, is the postimage non-empty, is it an LFS pointer -- and
NONE of them can see a resolution that is merely wrong.  Entry f8cb8ae9ac was
replaying a resolution that lost a fast-path guard and glued the function's
closing brace onto its `return`; braces still balanced, no marker survived, so
every existing rule passed it.  A wrong entry is not a one-time mistake: rerere
replays it on every rebuild, for ever, and reports the merge clean.

Two kinds of rule live here.

  * Whole-file structural rules, which need only the postimage: delimiter
    balance, unreachable code, redeclaration, duplicate named arguments, an
    orphaned KDoc block, an empty `when`.
  * Preimage-relative rules, which compare the resolution against the two sides
    of the conflict it resolves: a line glued together out of two conflict
    lines, an annotation the resolution dropped, both spellings of a renamed
    type kept side by side.

Every rule here was validated to fire ZERO times across all 4240 committed .kt
files in this repository before being switched on, and each has a negative
control in .fork/tests/test-audit.sh.  Precision is the whole point: this runs
unattended, and a rule that cries wolf gets switched off by the next operator,
which is strictly worse than not having written it.

Usage:
    rr_semantic.py <entry-dir>       # audit one rr-cache entry, TSV to stdout
Exit 1 when the entry has problems, 0 when it is clean.
Each output row is:  <variant>\t<rule>\t<detail>
"""
import collections
import os
import re
import sys
import xml.etree.ElementTree as ET


# --- lexing -----------------------------------------------------------------

def code_only(text, keep_ticks=False):
    """Blank out comments and literals, one output line per input line.

    A single character scan, NOT sequential regex passes.  Stripping comments
    before strings makes `"text/*"` open a block comment that swallows the rest
    of the file -- which is how a balanced test class came back as 4 open braces
    and 2 close, and why 23 untouched files in this repository look damaged to a
    naive scanner.

    Kotlin backtick identifiers are blanked by default, so a brace inside a test
    name cannot unbalance the file.  Callers that COMPARE signatures must pass
    keep_ticks=True: with the names blanked, every `fun \\`a test name\\`()` in a
    file collapses to one key and the comparison becomes vacuous.
    """
    out, line = [], []
    i, n = 0, len(text)
    state = None      # None | line | block | str | raw | char | tick
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "\n":
            out.append("".join(line)); line = []
            if state == "line":
                state = None
            i += 1; continue
        if state is None:
            if c == "/" and nxt == "/": state = "line"; i += 2; continue
            if c == "/" and nxt == "*": state = "block"; i += 2; continue
            if text.startswith('"""', i): state = "raw"; i += 3; continue
            if c == '"': state = "str"; i += 1; continue
            if c == "'": state = "char"; i += 1; continue
            if c == "`":
                state = "tick"
                if keep_ticks: line.append(c)
                i += 1; continue
            line.append(c); i += 1; continue
        if state == "line":
            i += 1; continue
        if state == "block":
            if c == "*" and nxt == "/": state = None; i += 2
            else: i += 1
            continue
        if state == "raw":
            if text.startswith('"""', i): state = None; i += 3
            else: i += 1
            continue
        if state == "tick":
            if keep_ticks: line.append(c)
            if c == "`": state = None
            i += 1; continue
        if state in ("str", "char"):
            q = '"' if state == "str" else "'"
            if c == "\\": i += 2
            elif c == q: state = None; i += 1
            else: i += 1
            continue
    out.append("".join(line))
    return out


MODS = (r"(?:public |internal |private |protected |open |final |abstract |sealed |data |inline "
        r"|value |override |lateinit |const |suspend |external |actual |expect |companion "
        r"|annotation |enum |tailrec |operator |infix |inner |vararg |crossinline |noinline "
        r"|reified )*")
_ANN = r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s*)*"

DECL_LINE = re.compile(_ANN + MODS + r"(fun|val|var|class|object|interface|typealias)\s")
# The lookahead forbids `.` and `<` immediately after the NAME so an extension
# property (`val Number.kb`) is not read as a plain `val`.  It must be anchored
# to the name itself: with `\s*` in between the regex simply backtracks to a
# shorter name and matches anyway, which is how `val SemanticColors.foo` was
# read as a redeclaration of something called `SemanticColor`.
VALVAR = re.compile(_ANN + MODS + r"(val|var)\s+([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_.<])")
TYPEDECL = re.compile(_ANN + MODS + r"(class|interface|object)\s+([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])")
FUNSIG = re.compile(_ANN + MODS + r"fun\s+.*")
FUNNAME = re.compile(_ANN + MODS + r"fun\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
NAMED_ARG = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\S")
ANNOT = re.compile(r"^\s*@([\w.]+)")
ORPHAN_STAR = re.compile(r"^\s*\*(\s|$|/)")
EMPTY_WHEN = re.compile(r"\bwhen\s*(\([^()]*\))?\s*\{\s*\}")
TERMINAL = re.compile(r"^\s*(?:return(?:@\w+)?|throw)\b")
CONT = re.compile(r"^\s*(\}|\)|\]|,|\.|\?\.|::|else\b|catch\b|finally\b|while\b|->|\{"
                  r"|\+|\-|\*|/|\||&|=|\?|:)")
# A terminal line ending in one of these is an unfinished expression, so the
# line below it continues the statement and is reachable.
OPEN_END = re.compile(r"(&&|\|\||\+|\-|\*|/|%|=|==|!=|<|>|<=|>=|\?|:|,|\.|->|\(|\[|\{"
                      r"|\bin\b|\bis\b|\bas\b)\s*$")


def _scopes(lines):
    """Yield (scope_id, line) pairs.  Both braces AND parens open a scope:
    `data class A(val x)` puts constructor properties in the parameter list, not
    the class body, so two sibling data classes each declaring `val x` are not a
    redeclaration."""
    stack = [0]; nxt = 1
    for line in lines:
        yield stack[-1], line
        for ch in line:
            if ch in "{(":
                stack.append(nxt); nxt += 1
            elif ch in "})":
                if len(stack) > 1:
                    stack.pop()


# --- whole-file structural rules --------------------------------------------

def delimiter_balance(code_lines):
    s = "\n".join(code_lines)
    out = []
    for name, o, c in (("brace", "{", "}"), ("paren", "(", ")"), ("bracket", "[", "]")):
        if s.count(o) != s.count(c):
            out.append("%s balance %d open %d close" % (name, s.count(o), s.count(c)))
    return out


def unreachable(code_lines):
    """A statement after an unconditional return/throw at the same brace depth.

    Only a SELF-CONTAINED terminal line counts -- balanced braces, parens and
    brackets, and not ending mid-expression -- so `return Foo(\\n a = 1,\\n)` and
    `return a &&\\n b` are not mistaken for a return followed by statements.
    """
    bd = pd = 0; depth = []
    for s in code_lines:
        depth.append((bd, pd))
        bd += s.count("{") - s.count("}")
        pd += s.count("(") + s.count("[") - s.count(")") - s.count("]")
    hits = []
    for i, s in enumerate(code_lines):
        if not TERMINAL.match(s): continue
        if s.count("{") != s.count("}"): continue
        if s.count("(") + s.count("[") != s.count(")") + s.count("]"): continue
        if OPEN_END.search(s): continue
        b, p = depth[i]
        if p != 0: continue
        for j in range(i + 1, len(code_lines)):
            t = code_lines[j]
            if not t.strip(): continue
            tb, tp = depth[j]
            if tb != b or tp != 0: break
            if CONT.match(t) or DECL_LINE.match(t): break
            hits.append("line %d unreachable after the return above: %s" % (j + 1, t.strip()))
            break
    return hits


def redeclared_valvar(code_lines):
    """The same val/var name declared twice in ONE scope -- a hard Kotlin
    redeclaration error, so any hit is a defect rather than a style opinion."""
    seen = collections.defaultdict(list)
    for i, (scope, line) in enumerate(_scopes(code_lines)):
        m = VALVAR.match(line)
        if m: seen[(scope, m.group(2))].append(i + 1)
    return ["'%s' declared %d times in one scope, at lines %s" % (n, len(v), v[:6])
            for (_, n), v in sorted(seen.items(), key=lambda kv: kv[0][1]) if len(v) > 1]


def redeclared_types(tick_lines):
    """A class/interface/object name declared twice in one scope, or a `fun`
    whose entire signature line repeats in one scope.

    Types cannot be overloaded, so a repeated name is always a redeclaration.
    Functions can be, so only a byte-identical signature counts, and only when
    it is COMPLETE on one line: `fun Foo(` with its parameters below is
    identical between two genuine overloads.
    """
    types = collections.defaultdict(list)
    funs = collections.defaultdict(list)
    for i, (scope, line) in enumerate(_scopes(tick_lines)):
        m = TYPEDECL.match(line)
        if m:
            types[(scope, m.group(2))].append(i + 1)
        elif FUNSIG.match(line) and line.strip() and line.count("(") == line.count(")"):
            funs[(scope, line.strip())].append(i + 1)
    out = ["type '%s' declared %d times in one scope, at lines %s" % (n, len(v), v[:6])
           for (_, n), v in types.items() if len(v) > 1]
    out += ["identical signature '%s' declared %d times in one scope, at lines %s"
            % (n[:70], len(v), v[:6]) for (_, n), v in funs.items() if len(v) > 1]
    return sorted(out)


def duplicate_named_arg(code_lines):
    """The same named argument passed twice in ONE argument list.

    Keeping both sides of a renamed call leaves `mimeType = a.old()` next to
    `mimeType = a.new()` inside the same parentheses.  Scoped per paren, so the
    same argument name in two different calls is not a hit.
    """
    stack = [(0, "{")]; nxt = 1
    seen = collections.defaultdict(list)
    for i, line in enumerate(code_lines):
        m = NAMED_ARG.match(line)
        if m and stack[-1][1] == "(":
            seen[(stack[-1][0], m.group(1))].append(i + 1)
        for ch in line:
            if ch in "{(":
                stack.append((nxt, ch)); nxt += 1
            elif ch in "})":
                if len(stack) > 1: stack.pop()
    return ["named argument '%s' passed %d times in one call, at lines %s" % (n, len(v), v[:4])
            for (_, n), v in sorted(seen.items(), key=lambda kv: kv[0][1]) if len(v) > 1]


def orphan_kdoc(code_lines):
    """A KDoc continuation line left outside any comment.  code_only blanks
    everything inside a comment, so a surviving `* @param ...` means the block's
    `/**` opener was consumed by a splice and the text now parses as code."""
    return ["line %d is a KDoc continuation with no /** opener: %s" % (i + 1, l.strip())
            for i, l in enumerate(code_lines) if ORPHAN_STAR.match(l)]


def empty_when(code_lines):
    """`when { }` with no branches: always a compile error, and the residue of a
    rename splice that moved every branch into the sibling copy."""
    return ["empty `when` with no branches: %s" % m.group(0).replace("\n", " ")
            for m in EMPTY_WHEN.finditer("\n".join(code_lines))]


def empty_body_sibling(tick_lines):
    """A function with an empty body beside a same-named sibling that has one.

    A rename splice keeps the old signature but moves every statement into the
    new one.  Both are legal overloads, so only the empty/populated PAIR is
    reported, and only within one scope -- a no-op `override fun x() {}` in one
    anonymous object is not a sibling of a populated `x()` in another.
    """
    bodies = collections.defaultdict(list)
    scoped = list(_scopes(tick_lines))
    for i, (scope, line) in enumerate(scoped):
        m = FUNNAME.match(line)
        if not m or not line.rstrip().endswith("{"): continue
        j = i + 1
        while j < len(tick_lines) and not tick_lines[j].strip(): j += 1
        empty = j < len(tick_lines) and tick_lines[j].strip() in ("}", "})")
        bodies[(scope, m.group(1))].append((i + 1, empty))
    out = []
    for (_, name), v in sorted(bodies.items(), key=lambda kv: kv[0][1]):
        if len(v) > 1 and any(e for _, e in v) and any(not e for _, e in v):
            out.append("'%s' has an empty-bodied copy beside a populated one, at lines %s"
                       % (name, [i for i, _ in v]))
    return out


# --- preimage-relative rules ------------------------------------------------

MARK = re.compile(r"^(<<<<<<<|\|\|\|\|\|\|\||=======|>>>>>>>)")


def split_sides(preimage):
    """Reconstruct the whole file as each side of the conflict would leave it."""
    ours, theirs = [], []
    state = "ctx"
    for line in preimage.split("\n"):
        m = MARK.match(line)
        if m:
            t = m.group(1)
            state = {"<<<<<<<": "ours", "|||||||": "base",
                     "=======": "theirs", ">>>>>>>": "ctx"}[t]
            continue
        if state == "ctx":
            ours.append(line); theirs.append(line)
        elif state == "ours":
            ours.append(line)
        elif state == "theirs":
            theirs.append(line)
    return "\n".join(ours), "\n".join(theirs)


CLOSERS_ONLY = re.compile(r"^[\s})\]]+$")


def glued_lines(preimage, postimage):
    """A resolution line, absent from the recorded conflict, that is exactly a
    conflict line with a closing-delimiter line glued onto its end.

    This is entry f8cb8ae9ac's shape: `return document.body().html()    }`.  The
    brace has moved, not vanished, so the counts still balance and every
    delimiter rule passes it.
    """
    known = {l.strip() for l in preimage.split("\n") if l.strip()}
    hits = []
    for l in postimage.split("\n"):
        s = l.rstrip()
        if not s.strip() or s.strip() in known: continue
        m = re.match(r"^(.*?\S)(\s+)([})\]][\s})\]]*)$", s)
        if not m or not CLOSERS_ONLY.match(m.group(3)): continue
        head, tail = m.group(1).strip(), m.group(3).strip()
        if head in known and tail in known:
            hits.append("'%s' is '%s' with '%s' glued onto it" % (s.strip(), head, tail))
    return hits


def _annotated(lines):
    """Map each `fun` line to the annotations sitting immediately above it."""
    out = collections.defaultdict(set)
    for i, l in enumerate(lines):
        if not FUNSIG.match(l): continue
        anns, j = set(), i - 1
        while j >= 0:
            t = lines[j]
            if not t.strip(): j -= 1; continue
            m = ANNOT.match(t)
            if not m: break
            anns.add(m.group(1)); j -= 1
        out[l.strip()] |= anns
    return out


def dropped_annotation(ours, theirs, postimage):
    """A function that carried an annotation in every side that declares it, and
    carries it in the resolution no longer.

    A shared `@Test` sitting just above a conflict hunk belongs to whichever
    side's first function is kept.  Concatenating both sides leaves the second
    group's first function unannotated: the test still compiles, still looks
    right, and silently never runs again.

    Runs on RAW lines.  code_only blanks Kotlin backtick identifiers, which
    collapses every `fun \\`a test name\\`()` in a file to the same key.
    """
    post = _annotated(postimage.split("\n"))
    sides = [_annotated(ours.split("\n")), _annotated(theirs.split("\n"))]
    hits = []
    for fn, have in post.items():
        declaring = [s[fn] for s in sides if fn in s]
        if not declaring: continue
        lost = set.intersection(*declaring) - have
        if lost:
            hits.append("%s lost the annotation(s) %s it carries in the conflict"
                        % (fn[:80], sorted("@" + a for a in lost)))
    return hits


def _declared_types(tick_lines):
    out = {}
    for line in tick_lines:
        m = TYPEDECL.match(line)
        if m: out.setdefault(m.group(2), True)
    return set(out)


def _near(a, b):
    """Names differing only by a short suffix -- the rename shape."""
    if a == b: return False
    lo, hi = (a, b) if len(a) < len(b) else (b, a)
    return hi.startswith(lo) and len(hi) - len(lo) <= 2


def rename_splice(ours_tick, theirs_tick, post_tick):
    """The resolution declares BOTH spellings of a renamed type.

    A rename conflict (`ForwardMessagesEvent` -> `ForwardMessagesEvents`)
    resolved keep-both-sides leaves two near-identical sibling declarations,
    each valid on its own side and neither correct together.  Only fires when
    each name is unique to one side, so a file that genuinely declares both is
    untouched.
    """
    post = _declared_types(post_tick)
    a, b = _declared_types(ours_tick), _declared_types(theirs_tick)
    hits = []
    for x in sorted(a - b):
        for y in sorted(b - a):
            if x in post and y in post and _near(x, y):
                hits.append("both spellings of a renamed type kept: '%s' and '%s'" % (x, y))
    return hits


# --- driver -----------------------------------------------------------------

def looks_kotlin(text):
    return bool(re.search(r"^\s*(package|import)\s+\S", text, re.M)) or "fun " in text


def looks_xml(text):
    s = text.lstrip()
    return s.startswith("<?xml") or s.startswith("<resources")


def check_pair(preimage, postimage):
    """Every problem with one preimage/postimage pair, as a list of strings."""
    probs = []
    probs += [("glued-line", d) for d in glued_lines(preimage, postimage)]

    if looks_xml(postimage):
        try:
            ET.fromstring(postimage)
        except ET.ParseError as e:
            probs.append(("invalid-xml", "the resolution is not well-formed XML: %s" % e))

    if not looks_kotlin(postimage):
        return probs

    ours, theirs = split_sides(preimage)
    code = code_only(postimage)
    tick = code_only(postimage, keep_ticks=True)

    for rule, found in (
        ("delimiter-imbalance", delimiter_balance(code)),
        ("unreachable-code", unreachable(code)),
        ("redeclared", redeclared_valvar(code)),
        ("redeclared", redeclared_types(tick)),
        ("duplicate-named-arg", duplicate_named_arg(code)),
        ("orphan-kdoc", orphan_kdoc(code)),
        ("empty-when", empty_when(code)),
        ("empty-body-sibling", empty_body_sibling(tick)),
        ("dropped-annotation", dropped_annotation(ours, theirs, postimage)),
        ("rename-splice", rename_splice(code_only(ours, keep_ticks=True),
                                        code_only(theirs, keep_ticks=True), tick)),
    ):
        probs += [(rule, d) for d in found]
    return probs


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError, OSError):
        return None


def check_entry(directory):
    """TSV rows for one rr-cache entry: <variant>\\t<rule>\\t<detail>."""
    rows = []
    try:
        names = os.listdir(directory)
    except OSError:
        return rows
    variants = sorted({n[len("preimage"):] for n in names if n.startswith("preimage")})
    for v in variants:
        pre = read(os.path.join(directory, "preimage" + v))
        post = read(os.path.join(directory, "postimage" + v))
        # A preimage-only entry resolves nothing, so it replays nothing.  A
        # binary or undecodable image is not ours to judge.
        if pre is None or post is None:
            continue
        for rule, detail in check_pair(pre, post):
            rows.append((v or "0", rule, detail))
    return rows


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: rr_semantic.py <rr-cache-entry-dir>\n")
        return 2
    rows = check_entry(argv[1])
    for variant, rule, detail in rows:
        sys.stdout.write("%s\t%s\t%s\n" % (variant, rule, detail))
    return 1 if rows else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
