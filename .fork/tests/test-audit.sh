#!/usr/bin/env bash
# audit.sh is SOURCED, so shellcheck cannot see it calling log/warn/die/run or
# reading the globals this harness sets on its behalf.
# shellcheck disable=SC2034,SC2329
#
# Harness for .fork/lib/audit.sh (WP-C: defects 3 and 4).
#
# Every case shows BOTH halves: the guard silent on a good fixture, and the
# guard firing on a deliberately broken one. Case 5 reproduces the actual LFS
# pointer corruption end to end.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/t"
FAILED=0

# --- helpers the module expects the caller to have defined -------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ ${DRY_RUN:-0} -eq 1 ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

DRY_RUN=0; NO_PUSH=0; CONTINUE=0; SKIP_VERIFY=0; ONLY_FEATURES=""
MIRROR=develop; INTEGRATION=master; TOOLING=feat/fork-tooling
REPO_ROOT=""; FORK_DIR=""

# Module lives in .fork/lib/, this harness in .fork/tests/. Falls back to $HERE
# so it also runs from a flat scratch directory.
FORK_LIB="${FORK_LIB:-$HERE/../lib}"
[[ -f "$FORK_LIB/audit.sh" ]] || FORK_LIB="$HERE"
# shellcheck source=/dev/null
. "$FORK_LIB/audit.sh"

# --- test scaffolding -------------------------------------------------------
banner() { printf '\n\033[1m=== CASE %s ===\033[0m\n' "$1"; }
pass()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail()   { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }

expect_eq() { # got want desc
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 -- got [$1], want [$2]"; fi
}
expect_true() { # cond-rc desc
  if [[ "$1" -eq 0 ]]; then pass "$2"; else fail "$2"; fi
}

in_repo() { local d="$1"; shift; cd "$d" || return 9; "$@"; }

# Runs a command in a subshell; requires it to exit non-zero and prints what it said.
expect_die() { # desc cmd...
  local desc="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "$desc (exit $rc)"
    printf '%s\n' "$out" | sed -e 's/^/       | /'
  else
    fail "$desc -- returned 0, the guard did not fire"
    printf '%s\n' "$out" | sed -e 's/^/       | /'
  fi
}
expect_live() { # desc cmd...
  local desc="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "$desc"
    printf '%s\n' "$out" | sed -e 's/^/       | /'
  else
    fail "$desc -- exited $rc, the guard fired on a good fixture"
    printf '%s\n' "$out" | sed -e 's/^/       | /'
  fi
}

mkrepo() { # dir
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q -b base
  git -C "$d" config user.email 'wpc@test.invalid'
  git -C "$d" config user.name  'wpc'
  git -C "$d" config commit.gpgsign false
  git -C "$d" commit -q --allow-empty -m 'base'
}

attrfile() { printf '%s\n' "$1/.git/info/attributes"; }
nrules()   { grep -c 'merge=binary' "$1" 2>/dev/null || true; }

rm -rf "$T"; mkdir -p "$T"
printf '\033[1mWP-C audit.sh harness -- workspace %s\033[0m\n' "$T"

###############################################################################
banner "1 -- ensure_snapshot_attrs writes all three rules, idempotently"
###############################################################################
R="$T/attrs"; mkrepo "$R"; REPO_ROOT="$R"; FORK_DIR="$R/.fork"
A="$(attrfile "$R")"
mkdir -p "$(dirname "$A")"; : > "$A"

in_repo "$R" ensure_snapshot_attrs >/dev/null
expect_eq "$(nrules "$A")" "3" "empty file gains all three rules"
printf '     %s\n' "--- $A ---"; sed -e 's/^/       | /' "$A"

in_repo "$R" ensure_snapshot_attrs >/dev/null
expect_eq "$(nrules "$A")" "3" "second run adds no duplicates"

# The old bug: grep for pattern 1 only, and skip the rest when it matches.
printf '%s\n' '**/snapshots/**/*.png merge=binary' > "$A"
in_repo "$R" ensure_snapshot_attrs >/dev/null
expect_eq "$(nrules "$A")" "3" "a file holding ONLY rule 1 gains rules 2 and 3 (the old skip bug)"
expect_eq "$(grep -cxF '**/snapshots/**/*.png merge=binary' "$A")" "1" "rule 1 not duplicated while doing so"
printf '     %s\n' "--- $A ---"; sed -e 's/^/       | /' "$A"

# A file with no trailing newline must not have rule 1 glued onto its last line.
printf 'x\n*.md text' > "$A"
in_repo "$R" ensure_snapshot_attrs >/dev/null
expect_eq "$(grep -cxF '*.md text' "$A")" "1" "a file with no trailing newline is not corrupted by the append"
expect_eq "$(nrules "$A")" "3" "...and still gains all three rules"

###############################################################################
banner "2 -- ensure_snapshot_attrs writes FOR REAL under DRY_RUN=1"
###############################################################################
R="$T/attrs-dry"; mkrepo "$R"; REPO_ROOT="$R"; FORK_DIR="$R/.fork"
A="$(attrfile "$R")"
rm -f "$A"
DRY_RUN=1
in_repo "$R" ensure_snapshot_attrs >/dev/null
DRY_RUN=0
expect_eq "$(nrules "$A")" "3" "DRY_RUN=1 still writes the local, uncommitted policy"
expect_true "$([[ -f "$A" ]] && echo 0 || echo 1)" "the attributes file exists after a dry run"

###############################################################################
banner "3 -- assert_snapshot_attrs: silent when correct, dies when a rule is gone"
###############################################################################
R="$T/assert"; mkrepo "$R"; REPO_ROOT="$R"; FORK_DIR="$R/.fork"
A="$(attrfile "$R")"
# The upstream .gitattributes, verbatim, declaring a driver that does not exist.
cat > "$R/.gitattributes" <<'GA'
screenshots/**/*.png filter=lfs diff=lfs merge=lfs -text
libraries/compound/screenshots/** filter=lfs diff=lfs merge=lfs -text
**/snapshots/**/*.png filter=lfs diff=lfs merge=lfs -text
GA
git -C "$R" add -A && git -C "$R" commit -q -m 'upstream .gitattributes'
rm -f "$A"
in_repo "$R" ensure_snapshot_attrs >/dev/null
expect_live "assert passes once the three rules are installed" in_repo "$R" assert_snapshot_attrs

# Delete rule 3 -- the rule the REAL repo is missing today.
grep -vxF 'libraries/compound/screenshots/** merge=binary' "$A" > "$A.tmp" && mv "$A.tmp" "$A"
expect_die "assert dies when a rule is deleted" in_repo "$R" assert_snapshot_attrs

###############################################################################
banner "4 -- assert_snapshot_attrs dies when the line names a bogus driver"
###############################################################################
cat > "$A" <<'ATTRS'
**/snapshots/**/*.png merge=binary
screenshots/**/*.png merge=binary
libraries/compound/screenshots/** merge=lfs
ATTRS
expect_die "assert dies on merge=lfs (a driver that exists at no scope)" \
  in_repo "$R" assert_snapshot_attrs

###############################################################################
banner "5 -- THE CORRUPTION: merge=lfs text-merges an LFS pointer"
###############################################################################
# Two branches, each holding a different LFS-pointer-shaped file at a snapshot
# path whose .gitattributes says merge=lfs. No driver of that name exists, so
# git falls back to its internal TEXT merge. The pointer is plain ASCII, so
# buffer_is_binary() says text, and the merge writes conflict markers INTO a
# file whose first line still reads like a valid LFS pointer.
C5="$T/lfs-corruption"
ptr() { printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n' "$1" "$2"; }
P="tests/uitests/src/test/snapshots/images/probe.png"

build_c5() { # dir
  local d="$1"
  mkrepo "$d"
  mkdir -p "$d/$(dirname "$P")"
  # merge=lfs verbatim from upstream, including -text. filter=/diff= are left
  # out only so this throwaway repo does not need git-lfs configured; neither
  # attribute takes part in choosing a merge driver.
  printf '%s\n' '**/snapshots/**/*.png merge=lfs -text' > "$d/.gitattributes"
  ptr aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1000 > "$d/$P"
  git -C "$d" add -A; git -C "$d" commit -q -m 'base snapshot'
  git -C "$d" checkout -q -b theirs
  ptr cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 3000 > "$d/$P"
  git -C "$d" commit -q -am 'their snapshot'
  git -C "$d" checkout -q base
  git -C "$d" checkout -q -b ours
  ptr bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2000 > "$d/$P"
  git -C "$d" commit -q -am 'our snapshot'
}

printf '     %s\n' "--- 5a: WITHOUT the local merge=binary policy ---"
build_c5 "$C5/before"
if git -C "$C5/before" config --get-regexp '^merge\.' >/dev/null 2>&1; then
  fail "fixture has a merge driver configured"
else
  pass "no merge driver named 'lfs' exists at any scope (as in the real repo)"
fi
git -C "$C5/before" merge --no-edit theirs >/dev/null 2>&1 || true
printf '     %s\n' "--- git check-attr merge -- $P ---"
(cd "$C5/before" && git check-attr merge -- "$P") | sed -e 's/^/       | /'
printf '     %s\n' "--- worktree content after the merge ---"
sed -e 's/^/       | /' "$C5/before/$P"
BEFORE_MARKERS="$(grep -cE '^(<<<<<<<|=======|>>>>>>>)' "$C5/before/$P" || true)"
BEFORE_HEADER="$(head -1 "$C5/before/$P")"
expect_true "$([[ "$BEFORE_MARKERS" -gt 0 ]] && echo 0 || echo 1)" \
  "the merged file contains conflict markers ($BEFORE_MARKERS of them)"
expect_eq "$BEFORE_HEADER" "version https://git-lfs.github.com/spec/v1" \
  "...while its first line still reads as a valid LFS pointer header"
# `git add` then stores that marker text as the file's content. With the lfs
# clean filter installed it becomes a structurally valid pointer TO the marker
# text, which is why `git lfs fsck` passes and nothing notices.
(cd "$C5/before" && git add -- "$P")
printf '     %s\n' "--- the blob git add staged (git show :$P) ---"
(cd "$C5/before" && git show ":$P") | sed -e 's/^/       | /'
STAGED_MARKERS="$(cd "$C5/before" && git show ":$P" | grep -cE '^(<<<<<<<|=======|>>>>>>>)' || true)"
expect_true "$([[ "$STAGED_MARKERS" -gt 0 ]] && echo 0 || echo 1)" \
  "git add committed the marker text into the object database ($STAGED_MARKERS markers)"

printf '\n     %s\n' "--- 5b: WITH the local merge=binary policy ---"
build_c5 "$C5/after"
REPO_ROOT="$C5/after"; FORK_DIR="$C5/after/.fork"
in_repo "$C5/after" ensure_snapshot_attrs >/dev/null
expect_live "assert_snapshot_attrs confirms the policy is live" in_repo "$C5/after" assert_snapshot_attrs
printf '     %s\n' "--- git check-attr merge -- $P ---"
(cd "$C5/after" && git check-attr merge -- "$P") | sed -e 's/^/       | /'
printf '     %s\n' "--- git merge output ---"
(cd "$C5/after" && git merge --no-edit theirs 2>&1 || true) | sed -e 's/^/       | /'
printf '     %s\n' "--- worktree content after the merge ---"
sed -e 's/^/       | /' "$C5/after/$P"
AFTER_MARKERS="$(grep -cE '^(<<<<<<<|=======|>>>>>>>)' "$C5/after/$P" || true)"
expect_eq "$AFTER_MARKERS" "0" "no conflict markers anywhere in the file"
expect_eq "$(cat "$C5/after/$P")" "$(ptr bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2000)" \
  "the worktree still holds our real pointer, byte for byte"
CONFLICTED="$(cd "$C5/after" && git status --porcelain | grep -c '^UU ' || true)"
expect_eq "$CONFLICTED" "1" "the path is still reported as conflicted -- a human must pick a side"

###############################################################################
banner "6 -- audit_rerere_cache: clean cache passes, each broken entry dies"
###############################################################################
R="$T/rr"; mkrepo "$R"; REPO_ROOT="$R"; FORK_DIR="$R/.fork"; mkdir -p "$FORK_DIR"
RR="$R/.git/rr-cache"; mkdir -p "$RR"

conflict_text() { printf 'a\n<<<<<<<\nours\n=======\ntheirs\n>>>>>>>\nz\n'; }
resolved_text() { printf 'a\nours\nz\n'; }
lfs_conflict()  { printf 'version https://git-lfs.github.com/spec/v1\n<<<<<<<\noid sha256:bbbb\nsize 2000\n=======\noid sha256:cccc\nsize 3000\n>>>>>>>\n'; }

mk_good()  { mkdir -p "$RR/$1"; conflict_text > "$RR/$1/preimage"; resolved_text > "$RR/$1/postimage"; }
mk_preonly() { mkdir -p "$RR/$1"; conflict_text > "$RR/$1/preimage"; }
mk_variant() { mkdir -p "$RR/$1"; conflict_text > "$RR/$1/preimage"; conflict_text > "$RR/$1/preimage.1"; resolved_text > "$RR/$1/postimage.1"; }

mk_good    aaa0000000000000000000000000000000000001
mk_preonly aaa0000000000000000000000000000000000002
mk_variant aaa0000000000000000000000000000000000003
expect_live "clean cache (1 plain + 1 preimage-only + 1 variant-only) passes" \
  in_repo "$R" audit_rerere_cache

drop() { rm -rf "${RR:?}/$1"; }

mkdir -p "$RR/bad1"; resolved_text > "$RR/bad1/postimage"
expect_die "dies on an entry with no preimage" in_repo "$R" audit_rerere_cache
drop bad1

mkdir -p "$RR/bad2"; resolved_text > "$RR/bad2/preimage"; resolved_text > "$RR/bad2/postimage"
expect_die "dies on a preimage with no conflict markers" in_repo "$R" audit_rerere_cache
drop bad2

mkdir -p "$RR/bad3"; conflict_text > "$RR/bad3/preimage"; conflict_text > "$RR/bad3/postimage"
expect_die "dies on a postimage that still contains conflict markers" in_repo "$R" audit_rerere_cache
drop bad3

mkdir -p "$RR/bad4"; conflict_text > "$RR/bad4/preimage"; : > "$RR/bad4/postimage"
expect_die "dies on a zero-byte postimage with a non-empty preimage" in_repo "$R" audit_rerere_cache
drop bad4

LFSID=bad5000000000000000000000000000000000005
mkdir -p "$RR/$LFSID"; lfs_conflict > "$RR/$LFSID/preimage"; resolved_text > "$RR/$LFSID/postimage"
expect_die "dies on an entry recorded from an LFS pointer" in_repo "$R" audit_rerere_cache

###############################################################################
banner "7 -- the LFS entry is accepted once its id is listed as verified"
###############################################################################
printf '# hand-verified ids\n%s\n' "$LFSID" > "$FORK_DIR/rr-cache-verified.txt"
expect_live "the same cache passes with the id in rr-cache-verified.txt" \
  in_repo "$R" audit_rerere_cache
# ...but the exemption is for the LFS rule ONLY.
conflict_text > "$RR/$LFSID/postimage"
expect_die "a verified id is still NOT exempt from the marker rules" \
  in_repo "$R" audit_rerere_cache
drop "$LFSID"
rm -f "$FORK_DIR/rr-cache-verified.txt"
expect_live "cache clean again after removing the bad entry" in_repo "$R" audit_rerere_cache

# empty and absent cache directories must be safe
rm -rf "${RR:?}"
expect_live "an absent rr-cache is not an error" in_repo "$R" audit_rerere_cache
mkdir -p "$RR"
expect_live "an empty rr-cache is not an error" in_repo "$R" audit_rerere_cache

###############################################################################
banner "8 -- rr_cache_stage survives the checkout that empties the worktree"
###############################################################################
build_stage_repo() { # dir
  local d="$1"
  mkrepo "$d"
  git -C "$d" checkout -q -b feat/fork-tooling
  mkdir -p "$d/.fork/rr-cache/e1"
  printf 'a\n<<<<<<<\nours\n=======\ntheirs\n>>>>>>>\nz\n' > "$d/.fork/rr-cache/e1/preimage"
  printf 'a\nours\nz\n' > "$d/.fork/rr-cache/e1/postimage"
  git -C "$d" add -A; git -C "$d" commit -q -m 'tooling with a committed rr-cache'
  # exactly what setup-local-git.sh does
  rm -rf "$d/.git/rr-cache"
  ln -sfn "$d/.fork/rr-cache" "$d/.git/rr-cache"
}

printf '     %s\n' "--- 8a: WITHOUT staging, the checkout evaporates the cache ---"
S="$T/stage-before"; build_stage_repo "$S"
# `ls` on a dangling symlink prints the link's own name, so count what is
# actually REACHABLE through it instead.
entries() { find -L "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
expect_eq "$(entries "$S/.git/rr-cache")" "1" "cache visible through the symlink before the checkout"
git -C "$S" checkout -q -B master base
expect_eq "$(entries "$S/.git/rr-cache")" "0" "after 'git checkout -B master base' the cache is GONE (rerere silently stops replaying)"
expect_true "$([[ ! -f "$S/.git/rr-cache/e1/preimage" ]] && echo 0 || echo 1)" "...the recorded resolution is unreachable"
printf '     %s\n' "--- the symlink dangles now ---"
printf '       | %s -> %s\n' "$S/.git/rr-cache" "$(readlink "$S/.git/rr-cache")"

printf '     %s\n' "--- 8b: WITH rr_cache_stage ---"
S="$T/stage-after"; build_stage_repo "$S"; REPO_ROOT="$S"; FORK_DIR="$S/.fork"
expect_true "$([[ -L "$S/.git/rr-cache" ]] && echo 0 || echo 1)" ".git/rr-cache starts as a worktree symlink"
in_repo "$S" rr_cache_stage | sed -e 's/^/       | /'
expect_true "$([[ -d "$S/.git/rr-cache" && ! -L "$S/.git/rr-cache" ]] && echo 0 || echo 1)" \
  "it is now a real directory"
expect_true "$([[ -f "$S/.fork/rr-cache/e1/preimage" ]] && echo 0 || echo 1)" \
  "the symlink target was NOT deleted"
in_repo "$S" rr_cache_stage | sed -e 's/^/       | /'
expect_eq "$(entries "$S/.git/rr-cache")" "1" "a second call is a no-op (idempotent)"
git -C "$S" checkout -q -B master base
expect_eq "$(entries "$S/.git/rr-cache")" "1" \
  "the entry SURVIVES the same checkout that destroyed it in 8a"
expect_true "$([[ -s "$S/.git/rr-cache/e1/postimage" ]] && echo 0 || echo 1)" \
  "...with its postimage intact"
expect_true "$([[ ! -d "$S/.fork" ]] && echo 0 || echo 1)" \
  "...even though the worktree .fork/ directory is gone"

###############################################################################
banner "9 -- rr_cache_export copies good entries and refuses bad ones"
###############################################################################
E="$T/export"; mkrepo "$E"; REPO_ROOT="$E"; FORK_DIR="$E/.fork"
RR="$E/.git/rr-cache"; mkdir -p "$RR" "$FORK_DIR"
mk_good    ccc0000000000000000000000000000000000001
mk_preonly ccc0000000000000000000000000000000000002
mkdir -p "$RR/ccc0000000000000000000000000000000000003"
conflict_text > "$RR/ccc0000000000000000000000000000000000003/preimage"
conflict_text > "$RR/ccc0000000000000000000000000000000000003/postimage"   # marker-bearing: unsafe

# It refuses, but only AFTER copying the entries that pass: the good work is
# saved, and the run stops rather than continuing past a line nobody reads.
expect_die "export REFUSES while one entry fails the audit" in_repo "$E" rr_cache_export
expect_true "$([[ -f "$FORK_DIR/rr-cache/ccc0000000000000000000000000000000000001/postimage" ]] && echo 0 || echo 1)" \
  "the good entry was exported"
expect_true "$([[ -f "$FORK_DIR/rr-cache/ccc0000000000000000000000000000000000002/preimage" ]] && echo 0 || echo 1)" \
  "the preimage-only entry was exported (harmless, replays nothing)"
expect_true "$([[ ! -e "$FORK_DIR/rr-cache/ccc0000000000000000000000000000000000003" ]] && echo 0 || echo 1)" \
  "the marker-bearing entry was NOT exported"
expect_eq "$(find "$RR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "3" "nothing was deleted from the source cache"

# .fork/.gitignore really does carry `rr-cache/*`, so an export that says
# nothing would leave the operator staging an empty set. The unsafe entry goes
# first: the export refuses while it is present, and would never reach the
# ignore probe.
drop ccc0000000000000000000000000000000000003
printf '%s\n' 'rr-cache/*' '!rr-cache/.gitkeep' > "$FORK_DIR/.gitignore"
git -C "$E" add -f -- .fork/.gitignore >/dev/null 2>&1
rm -rf "${FORK_DIR:?}/rr-cache"
IGN="$(in_repo "$E" rr_cache_export 2>&1 || true)"
printf '%s\n' "$IGN" | sed -e 's/^/       | /'
if printf '%s' "$IGN" | grep -q 'git add -f'; then
  pass "export warns that the exported entries are git-ignored, and gives the working command"
else
  fail "export did NOT warn about .fork/.gitignore hiding what it just wrote"
fi

###############################################################################
banner "10 -- the semantic rules: each one silent on sound code, firing on broken"
###############################################################################
# Every rule below was validated to fire ZERO times across all 4240 committed
# .kt files in this repository. A rule that only ever fires is not a check, so
# each case ships BOTH halves: a sound fixture that must pass and a broken one
# that must not.
S="$T/sem"; mkdir -p "$S"
SEM="$FORK_LIB/rr_semantic.py"

# kt <dir> <preimage-body> <postimage-body>
mk_sem() {
  local d="$S/$1"; shift
  rm -rf "$d"; mkdir -p "$d"
  printf '%s' "$1" > "$d/preimage"
  printf '%s' "$2" > "$d/postimage"
  printf '%s\n' "$d"
}

sem_clean() { # desc dir
  if python3 "$SEM" "$2" >/dev/null 2>&1; then pass "$1"; else
    fail "$1 -- rule fired on sound input: $(python3 "$SEM" "$2" 2>&1 | head -2 | tr '\n' ' ')"; fi
}
sem_fires() { # desc dir wanted-rule
  local out rc=0
  # `out=$(cmd)` on its own would trip `set -e` the moment the rule fires, which
  # is the case this helper exists to assert.
  out="$(python3 "$SEM" "$2" 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q "$3"; then pass "$1"
  else fail "$1 -- wanted rule '$3', got rc=$rc: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
}

PRE_MIN=$'package p\n<<<<<<<\nval a = 1\n=======\nval b = 2\n>>>>>>>\nfun z() {}\n'

sem_clean "unreachable-code: silent on a multi-line return" \
  "$(mk_sem un_ok "$PRE_MIN" $'package p\nfun f(): Int {\n    return g(\n        a = 1,\n    )\n}\n')"
sem_fires "unreachable-code: fires on a statement after a return" \
  "$(mk_sem un_bad "$PRE_MIN" $'package p\nfun f(): Int {\n    return g(a)\n    log(a)\n}\n')" unreachable-code

sem_clean "redeclared: silent on the same name in two sibling scopes" \
  "$(mk_sem rd_ok "$PRE_MIN" $'package p\nclass C {\n    fun f() { val x = 1 }\n    fun g() { val x = 2 }\n}\n')"
sem_fires "redeclared: fires on two vals of one name in one scope" \
  "$(mk_sem rd_bad "$PRE_MIN" $'package p\nclass C {\n    fun f() {\n        val x = 1\n        val x = 2\n    }\n}\n')" redeclared

sem_clean "redeclared: silent on two genuine overloads" \
  "$(mk_sem ov_ok "$PRE_MIN" $'package p\nclass C {\n    fun g(x: Int) {}\n    fun g(x: String) {}\n}\n')"
sem_fires "redeclared: fires on a repeated type name" \
  "$(mk_sem ov_bad "$PRE_MIN" $'package p\nclass C {\n}\nclass C {\n}\nfun z() {}\n')" redeclared

sem_clean "duplicate-named-arg: silent on the same label in two different calls" \
  "$(mk_sem na_ok "$PRE_MIN" $'package p\nfun f() {\n    g(\n        mimeType = a,\n    )\n    h(\n        mimeType = b,\n    )\n}\n')"
sem_fires "duplicate-named-arg: fires on one label twice in one call" \
  "$(mk_sem na_bad "$PRE_MIN" $'package p\nfun f() {\n    g(\n        mimeType = a.old(),\n        mimeType = a.new(),\n    )\n}\n')" duplicate-named-arg

sem_clean "orphan-kdoc: silent on a well-formed KDoc block" \
  "$(mk_sem kd_ok "$PRE_MIN" $'package p\n/**\n * @param a x\n */\nfun f(a: Int) {}\n')"
sem_fires "orphan-kdoc: fires on a KDoc body whose /** opener was spliced away" \
  "$(mk_sem kd_bad "$PRE_MIN" $'package p\nfun f(a: Int) {}\n * @param b y\n */\nfun g(b: Int) {}\n')" orphan-kdoc

sem_clean "empty-when: silent on a populated when" \
  "$(mk_sem ew_ok "$PRE_MIN" $'package p\nfun f(x: Int): String = when {\n    x > 0 -> "a"\n    else -> "b"\n}\n')"
sem_fires "empty-when: fires on a when a rename splice emptied" \
  "$(mk_sem ew_bad "$PRE_MIN" $'package p\nfun f(x: Int): String = when {\n}\n')" empty-when

sem_clean "empty-body-sibling: silent on two populated overloads" \
  "$(mk_sem eb_ok "$PRE_MIN" $'package p\nclass C {\n    fun handle(e: A) {\n        go()\n    }\n    fun handle(e: B) {\n        go()\n    }\n}\n')"
sem_fires "empty-body-sibling: fires on an empty copy beside a populated one" \
  "$(mk_sem eb_bad "$PRE_MIN" $'package p\nclass C {\n    fun handle(e: A) {\n    }\n    fun handle(e: B) {\n        go()\n    }\n}\n')" empty-body-sibling

sem_clean "delimiter-imbalance: silent on a balanced file" \
  "$(mk_sem db_ok "$PRE_MIN" $'package p\nfun f() {\n    g(a)\n}\n')"
sem_fires "delimiter-imbalance: fires on a call a splice never closed" \
  "$(mk_sem db_bad "$PRE_MIN" $'package p\nfun f() {\n    g(\n        a = 1,\n}\n')" delimiter-imbalance

# A string holding `/*` used to open a block comment that swallowed the rest of
# the file, so a balanced test class came back as 4 open braces and 2 close.
sem_clean "the lexer does not read \"text/*\" as a block comment" \
  "$(mk_sem lx_ok "$PRE_MIN" $'package p\nfun f() {\n    assertThat("text/*".x()).isEqualTo(y)\n}\n')"
# ...and a brace inside a backticked test name must not unbalance it either.
sem_clean "the lexer does not count braces inside a backticked name" \
  "$(mk_sem lx_tick "$PRE_MIN" $'package p\nclass C {\n    fun `a name with { a brace }`() {\n        go()\n    }\n}\n')"

PRE_ANN=$'package p\nclass C {\n    @Test\n<<<<<<<\n    fun `one`() {\n        a()\n    }\n=======\n    fun `two`() {\n        b()\n    }\n>>>>>>>\n}\n'
sem_clean "dropped-annotation: silent when the kept test keeps its @Test" \
  "$(mk_sem an_ok "$PRE_ANN" $'package p\nclass C {\n    @Test\n    fun `one`() {\n        a()\n    }\n}\n')"
# The single @Test above the hunk belongs to whichever side comes first, so
# concatenating both sides silently disables the second group's first test.
sem_fires "dropped-annotation: fires when a concatenation eats the shared @Test" \
  "$(mk_sem an_bad "$PRE_ANN" $'package p\nclass C {\n    @Test\n    fun `one`() {\n        a()\n    }\n    fun `two`() {\n        b()\n    }\n}\n')" dropped-annotation

PRE_REN=$'package p\n<<<<<<<\nsealed interface XEvent {\n}\n=======\nsealed interface XEvents {\n}\n>>>>>>>\nfun z() {}\n'
sem_clean "rename-splice: silent when the resolution picks one spelling" \
  "$(mk_sem rn_ok "$PRE_REN" $'package p\nsealed interface XEvents {\n}\nfun z() {}\n')"
sem_fires "rename-splice: fires when both spellings of a renamed type are kept" \
  "$(mk_sem rn_bad "$PRE_REN" $'package p\nsealed interface XEvent {\n}\nsealed interface XEvents {\n}\nfun z() {}\n')" rename-splice

###############################################################################
banner "11 -- the entry that motivated all of this, and its sound sibling"
###############################################################################
# Both are the REAL recorded images, not hand-written approximations:
# .fork/tests/fixtures/rr-glued-brace is f8cb8ae9ac, recovered from the
# pre-purge backup, and rr-sound-sibling is ff722e81, the correct resolution of
# the same conflict in the same file. See fixtures/README.md.
FIX="$HERE/fixtures"
sem_fires "the purged entry f8cb8ae9ac is caught" "$FIX/rr-glued-brace" glued-line
sem_clean "the sound resolution of the SAME conflict still passes" "$FIX/rr-sound-sibling"

# ...and through the audit that actually runs, not just the module.
RRF="$T/fixrepo"; mkrepo "$RRF"; REPO_ROOT="$RRF"; FORK_DIR="$RRF/.fork"; mkdir -p "$FORK_DIR"
mkdir -p "$RRF/.git/rr-cache/f8cb8ae9ac82a7eae4becc1b969f835425763750"
cp "$FIX/rr-glued-brace/preimage" "$FIX/rr-glued-brace/postimage" \
   "$RRF/.git/rr-cache/f8cb8ae9ac82a7eae4becc1b969f835425763750/"
expect_die "audit_rerere_cache dies on the f8cb8ae9ac fixture" in_repo "$RRF" audit_rerere_cache
rm -rf "$RRF/.git/rr-cache/f8cb8ae9ac82a7eae4becc1b969f835425763750"
mkdir -p "$RRF/.git/rr-cache/ff722e81b25db186e7cde861d6becd22b958ab11"
cp "$FIX/rr-sound-sibling/preimage" "$FIX/rr-sound-sibling/postimage" \
   "$RRF/.git/rr-cache/ff722e81b25db186e7cde861d6becd22b958ab11/"
expect_live "audit_rerere_cache passes the sound sibling" in_repo "$RRF" audit_rerere_cache

###############################################################################
banner "12 -- rr_reaudit_recorded audits ONLY what the run recorded"
###############################################################################
# audit_rerere_cache runs over the cache as imported, before the first merge, so
# a resolution recorded DURING the run was never audited by anything. That is
# the hole; this closes it without re-auditing 200 entries that have not moved.
A="$T/reaudit"; mkrepo "$A"; REPO_ROOT="$A"; FORK_DIR="$A/.fork"; mkdir -p "$FORK_DIR"
RR="$A/.git/rr-cache"; mkdir -p "$RR"
STATE="$A/.git/fork-sync"

# A bad entry that was ALREADY there is not this function's business: it is
# audit_rerere_cache's, and re-reporting it would make every run look dirty.
mkdir -p "$RR/old0000000000000000000000000000000000001"
cp "$FIX/rr-glued-brace/preimage" "$FIX/rr-glued-brace/postimage" \
   "$RR/old0000000000000000000000000000000000001/"
in_repo "$A" rr_reaudit_begin >/dev/null 2>&1
in_repo "$A" rr_reaudit_recorded >/dev/null 2>&1
expect_true "$([[ -d "$RR/old0000000000000000000000000000000000001" ]] && echo 0 || echo 1)" \
  "a pre-existing bad entry is left alone -- it is not what this run recorded"

# Now record one good and one bad entry, as rerere would mid-run.
mk_good new0000000000000000000000000000000000001
mkdir -p "$RR/new0000000000000000000000000000000000002"
cp "$FIX/rr-glued-brace/preimage" "$FIX/rr-glued-brace/postimage" \
   "$RR/new0000000000000000000000000000000000002/"
OUT="$(in_repo "$A" rr_reaudit_recorded 2>&1 || true)"
printf '%s\n' "$OUT" | sed -e 's/^/       | /'
expect_true "$([[ -d "$RR/new0000000000000000000000000000000000001" ]] && echo 0 || echo 1)" \
  "the good entry recorded this run is kept"
expect_true "$([[ ! -e "$RR/new0000000000000000000000000000000000002" ]] && echo 0 || echo 1)" \
  "the bad entry recorded this run is quarantined"
expect_true "$([[ -f "$A/.git/rr-cache-quarantine/new0000000000000000000000000000000000002/QUARANTINE_REASON.txt" ]] && echo 0 || echo 1)" \
  "quarantine is a move with its reason beside it, never a delete"
expect_eq "$(find "$RR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "2" \
  "the rest of the cache is untouched -- one entry moved aside, not a clear"

###############################################################################
banner "13 -- rr_cache_export REFUSES a bad entry instead of warning past it"
###############################################################################
# A warning is a line the run continues past: the export looked like it worked,
# the operator committed what landed, and the entry that failed stayed live and
# kept replaying.
X="$T/refuse"; mkrepo "$X"; REPO_ROOT="$X"; FORK_DIR="$X/.fork"; mkdir -p "$FORK_DIR"
RR="$X/.git/rr-cache"; mkdir -p "$RR"
mk_good ddd0000000000000000000000000000000000001
expect_live "export succeeds when every entry passes" in_repo "$X" rr_cache_export
mkdir -p "$RR/ddd0000000000000000000000000000000000002"
cp "$FIX/rr-glued-brace/preimage" "$FIX/rr-glued-brace/postimage" \
   "$RR/ddd0000000000000000000000000000000000002/"
expect_die "export REFUSES once one entry fails the audit" in_repo "$X" rr_cache_export
expect_true "$([[ ! -e "$FORK_DIR/rr-cache/ddd0000000000000000000000000000000000002" ]] && echo 0 || echo 1)" \
  "the failing entry was not exported"
expect_true "$([[ -d "$RR/ddd0000000000000000000000000000000000002" ]] && echo 0 || echo 1)" \
  "and it was not deleted either -- the operator decides"

###############################################################################
printf '\n'
if [[ $FAILED -eq 0 ]]; then
  printf '\033[1;32mALL CASES PASSED\033[0m\n'
  exit 0
fi
printf '\033[1;31m%d CHECK(S) FAILED\033[0m\n' "$FAILED"
exit 1
