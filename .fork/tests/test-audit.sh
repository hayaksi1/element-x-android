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

in_repo "$E" rr_cache_export 2>&1 | sed -e 's/^/       | /'
expect_true "$([[ -f "$FORK_DIR/rr-cache/ccc0000000000000000000000000000000000001/postimage" ]] && echo 0 || echo 1)" \
  "the good entry was exported"
expect_true "$([[ -f "$FORK_DIR/rr-cache/ccc0000000000000000000000000000000000002/preimage" ]] && echo 0 || echo 1)" \
  "the preimage-only entry was exported (harmless, replays nothing)"
expect_true "$([[ ! -e "$FORK_DIR/rr-cache/ccc0000000000000000000000000000000000003" ]] && echo 0 || echo 1)" \
  "the marker-bearing entry was NOT exported"
expect_eq "$(find "$RR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "3" "nothing was deleted from the source cache"

# .fork/.gitignore really does carry `rr-cache/*`, so an export that says
# nothing would leave the operator staging an empty set.
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
printf '\n'
if [[ $FAILED -eq 0 ]]; then
  printf '\033[1;32mALL CASES PASSED\033[0m\n'
  exit 0
fi
printf '\033[1;31m%d CHECK(S) FAILED\033[0m\n' "$FAILED"
exit 1
