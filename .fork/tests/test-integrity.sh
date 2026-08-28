#!/usr/bin/env bash
# Harness for .fork/lib/integrity.sh.
#
# Every guard is exercised twice: once on a healthy fixture (it must stay
# silent) and once on a deliberately broken one (it must fire). A guard that
# has not been SEEN to fire is not a guard.
#
# Builds its own throwaway repo under ./t. Touches nothing else.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/t"
rm -rf "$T"
mkdir -p "$T"

PASSED=0
FAILED=0
ok()  { printf 'PASS  %s\n' "$*"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
# eq <desc> <expected> <actual>
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
have(){ if grep -q -- "$2" "$3"; then ok "$1"; else bad "$1 (no match for [$2] in $3)"; fi; }
hasnt(){ if grep -q -- "$2" "$3"; then bad "$1 (unexpected match for [$2] in $3)"; else ok "$1"; fi; }

# The harness runs under `set -e`. A module bug can therefore kill the harness
# outright, mid-case -- and a run with no FAIL lines then LOOKS green to anyone
# grepping for FAIL. This trap makes an abort louder than a failure.
REACHED_END=0
on_abort() {
  local rc=$?
  [[ $REACHED_END -eq 1 ]] && return 0
  printf '\n\033[1;31mABORT\033[0m  the harness died before the summary (exit %s).\n' "$rc"
  printf '        The last PASS above is the last case that COMPLETED, not the\n'
  printf '        last case that passed. A sourced function exited non-zero under\n'
  printf '        set -e -- that is a module bug, not a test bug.\n'
  exit 1
}
trap on_abort EXIT

section() { printf '\n--- %s\n' "$*"; }

# --- the globals and helpers the contract says are already defined ----------
REPO_ROOT="$T/repo"
FORK_DIR="$REPO_ROOT/.fork"
UPSTREAM_REF="upstream/develop"
MIRROR="develop"
INTEGRATION="master"
TOOLING="feat/fork-tooling"
STATE="$FORK_DIR/.state"
REPORT="$FORK_DIR/.report"
DRY_RUN=0; NO_PUSH=0; CONTINUE=0; SKIP_VERIFY=0; ONLY_FEATURES=""

log()  { printf '      log  %s\n' "$*"; }
warn() { printf '      warn %s\n' "$*" >&2; }
die()  { printf '      die  %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '      [dry-run] %s\n' "$*"; else "$@"; fi; }

read_manifest() {
  local file base raw
  file="$1"; base="$(basename "$file")"
  [[ -f "$file" ]] || die "test stub: missing manifest $base"
  raw="$(cat "$file")"
  printf '%s\n' "$raw" | sed -e 's/#.*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

kind_rows() { # <kind> -> row count of that kind
  [[ -f "$REPORT.incomplete" ]] || { echo 0; return 0; }
  cut -f2 -- "$REPORT.incomplete" | grep -cx -- "$1" || true
}

# --- fixture repo -----------------------------------------------------------
mkdir -p "$FORK_DIR"
git init -q "$REPO_ROOT"
cd "$REPO_ROOT"
git config user.email t@example.invalid
git config user.name  "integrity test"
git checkout -q -b work
for i in 1 2 3 4; do git commit -q --allow-empty -m "c$i"; done
C1="$(git rev-parse HEAD~3)"; C2="$(git rev-parse HEAD~2)"
C3="$(git rev-parse HEAD~1)"; C4="$(git rev-parse HEAD)"
git checkout -q "$C3"
git commit -q --allow-empty -m "x1"
X1="$(git rev-parse HEAD)"
git checkout -q work

mk() { git update-ref "$1" "$2"; }

# PR-drift fixtures: identical / behind / ahead / diverged / no-remote
mk refs/heads/fix/1-identical "$C3";  mk refs/remotes/origin/fix/1-identical "$C3"
mk refs/heads/fix/2-behind    "$C2";  mk refs/remotes/origin/fix/2-behind    "$C4"
mk refs/heads/fix/3-ahead     "$C4";  mk refs/remotes/origin/fix/3-ahead     "$C3"
mk refs/heads/fix/4-diverged  "$X1";  mk refs/remotes/origin/fix/4-diverged  "$C4"
mk refs/heads/fix/5-no-remote "$C3"

# Branches the unmanaged check must never flag, plus one it must.
mk refs/remotes/origin/develop         "$C4"
mk refs/remotes/origin/master          "$C4"
mk refs/remotes/origin/feat/fork-tooling "$C4"
mk refs/remotes/origin/HEAD            "$C4"
mk refs/remotes/origin/feat/managed    "$C4"
mk refs/remotes/origin/chore/stray     "$C4"

cat > "$FORK_DIR/features.txt" <<'EOF'
# fork-only branches, rebased
feat/managed
EOF
cat > "$FORK_DIR/pr-branches.txt" <<'EOF'
# heads of open upstream PRs, merged as-is
fix/1-identical
fix/2-behind
fix/3-ahead
fix/4-diverged
fix/5-no-remote
EOF

# shellcheck source=/dev/null
# The module lives in .fork/lib/; the harness in .fork/tests/.
. "${FORK_LIB:-$HERE/../lib}/integrity.sh"

# --- 1: incomplete_reset truncates ------------------------------------------
section "1  incomplete_reset truncates the accumulate-forever files"
printf 'stale\tmissing-branch\tfrom a previous run\n' >> "$REPORT.incomplete"
printf 'stale\tmissing-branch\tfrom a previous run\n' >> "$REPORT.incomplete"
printf 'old-branch\n' >> "$REPORT.rebase-failed"
eq "list is pre-populated"            2 "$(incomplete_count)"
eq "rebase-failed is pre-populated"   1 "$(grep -c '' "$REPORT.rebase-failed")"
incomplete_reset
eq "incomplete_reset empties the list"          0 "$(incomplete_count)"
eq "incomplete_reset empties .rebase-failed"    0 "$(grep -c '' "$REPORT.rebase-failed" || true)"
rm -f "$REPORT.incomplete"
eq "incomplete_count is 0 with no file at all"  0 "$(incomplete_count)"

# --- 2: fail_add round-trip, one row per call -------------------------------
section "2  fail_add / incomplete_count round-trip"
incomplete_reset
fail_add "feat/one" rebase-failed "plain detail" 2>/dev/null
eq "one row after one fail_add" 1 "$(incomplete_count)"
fail_add "feat/two" merge-conflict "$(printf 'tab\there\nand a newline')" 2>/dev/null
eq "two rows after two fail_adds" 2 "$(incomplete_count)"
IFS=$'\t' read -r _b _k _d < <(tail -n1 "$REPORT.incomplete")
eq "branch survives"  "feat/two"       "$_b"
eq "kind survives"    "merge-conflict" "$_k"
eq "tab+newline collapsed into one line" "tab here and a newline" "$_d"
eq "file really has 2 physical lines" 2 "$(wc -l < "$REPORT.incomplete")"
if ( fail_add "feat/x" not-a-real-kind "d" ) >/dev/null 2>&1; then
  bad "fail_add rejects an unknown kind"
else
  ok "fail_add rejects an unknown kind"
fi

# --- 3: check_pr_drift ------------------------------------------------------
section "3  check_pr_drift over identical / behind / ahead / diverged / no-remote"
incomplete_reset
check_pr_drift 2>/dev/null
eq "exactly 4 rows (identical adds nothing)" 4 "$(incomplete_count)"
eq "pr-drift-behind   x1" 1 "$(kind_rows pr-drift-behind)"
eq "pr-drift-ahead    x1" 1 "$(kind_rows pr-drift-ahead)"
eq "pr-drift-diverged x1" 1 "$(kind_rows pr-drift-diverged)"
eq "pr-no-remote      x1" 1 "$(kind_rows pr-no-remote)"
hasnt "identical branch is silent" "fix/1-identical" "$REPORT.incomplete"
have  "behind row names the right branch"   "^fix/2-behind	pr-drift-behind"   "$REPORT.incomplete"
have  "ahead row names the right branch"    "^fix/3-ahead	pr-drift-ahead"    "$REPORT.incomplete"
have  "diverged row names the right branch" "^fix/4-diverged	pr-drift-diverged" "$REPORT.incomplete"
have  "no-remote row names the right branch" "^fix/5-no-remote	pr-no-remote"     "$REPORT.incomplete"
have  "behind detail carries the real count and plain English" "behind origin/fix/2-behind by 2 commit(s)" "$REPORT.incomplete"
have  "ahead detail carries the real count"  "ahead of origin/fix/3-ahead by 1 commit(s)" "$REPORT.incomplete"
have  "diverged detail carries both counts"  "ahead by 1 commit(s) and behind by 1 commit(s)" "$REPORT.incomplete"

# --- 4: check_unmanaged_branches --------------------------------------------
section "4  check_unmanaged_branches"
rm -f "$FORK_DIR/unmanaged-branches.txt"
incomplete_reset
check_unmanaged_branches 2>/dev/null
eq "exactly one unmanaged branch fires" 1 "$(incomplete_count)"
have  "the stray branch fires" "^chore/stray	unmanaged-branch" "$REPORT.incomplete"
hasnt "develop never fires"           "^develop	"           "$REPORT.incomplete"
hasnt "master never fires"            "^master	"            "$REPORT.incomplete"
hasnt "feat/fork-tooling never fires" "^feat/fork-tooling	" "$REPORT.incomplete"
hasnt "origin/HEAD never fires"       "^HEAD	"              "$REPORT.incomplete"
hasnt "a manifest branch never fires" "^feat/managed	"      "$REPORT.incomplete"
ok "missing allowlist file did not die (we got here)"

# An allowlist that is nothing but comments: `grep -v '^$'` finds no lines and
# exits 1, which under `set -euo pipefail` killed the whole run at the
# assignment. Only reproducible with a comments-only file, which is exactly
# what a fresh fork has.
printf '# nothing deliberate yet\n\n' > "$FORK_DIR/unmanaged-branches.txt"
# Called DIRECTLY, not in a subshell: `if ( ... )` suppresses errexit inside the
# subshell as well, so a probe would report a pass for the very bug it is meant
# to catch. Under the bug this line kills the harness and the trap says ABORT.
incomplete_reset
check_unmanaged_branches 2>/dev/null
ok "a comments-only allowlist did not kill the run"
eq "and the stray still fires through a comments-only allowlist" 1 "$(incomplete_count)"

printf '# deliberate\nchore/stray\n' > "$FORK_DIR/unmanaged-branches.txt"
incomplete_reset
check_unmanaged_branches 2>/dev/null
eq "allowlisted branch is silent" 0 "$(incomplete_count)"
rm -f "$FORK_DIR/unmanaged-branches.txt"

# --- 5: assert_push_list ----------------------------------------------------
section "5  assert_push_list"
if ( assert_push_list develop master ) >/dev/null 2>&1; then
  ok "assert_push_list develop master succeeds"
else
  bad "assert_push_list develop master succeeds"
fi
if ( assert_push_list "develop:develop" "master:master" ) >/dev/null 2>&1; then
  ok "assert_push_list accepts src:dst refspecs"
else
  bad "assert_push_list accepts src:dst refspecs"
fi
# Each rule must be pinned independently: assert WHICH rule refused, so a
# redundant catch-all cannot hide the loss of the fix/*/feature/*/search/* glob.
# dies <desc> <expected substring of the die message> <ref>...
dies() {
  local desc="$1" want="$2"; shift 2
  local out rc=0
  out="$( ( assert_push_list "$@" ) 2>&1 )" || rc=$?
  if [[ $rc -eq 0 ]]; then
    bad "$desc (it did NOT die)"
  elif [[ "$out" != *"$want"* ]]; then
    bad "$desc (died for the wrong reason: $out)"
  else
    ok "$desc"
  fi
}
GLOB="fix/*, feature/* and search/* are never pushed"
dies "dies on fix/7471-conversation-notifications, by the glob rule" \
     "$GLOB" develop master fix/7471-conversation-notifications
dies "dies on feature/code-block-copy-button, by the glob rule" \
     "$GLOB" develop master feature/code-block-copy-button
dies "dies on search/message-search-index, by the glob rule" \
     "$GLOB" develop master search/message-search-index
dies "dies on fix/2-behind, by the glob rule" \
     "$GLOB" develop master fix/2-behind
dies "dies on a features.txt branch, naming the manifest" \
     "it is listed in features.txt" develop master feat/managed
dies "dies on an unlisted stray, by the develop/master-only rule" \
     "only develop, master and a sync/<ts> tag may be pushed" develop master chore/stray
dies "the refspec destination is checked too" \
     "$GLOB" "develop:fix/7471-conversation-notifications"

# --- 6: write_last_run on a clean run ---------------------------------------
section "6  write_last_run 0 on an empty list"
incomplete_reset
rm -f "$FORK_DIR/LAST_RUN.md"
write_last_run 0 "$C4" "$C4" "$X1"
[[ -f "$FORK_DIR/LAST_RUN.md" ]] && ok "LAST_RUN.md written on the clean path" \
                                 || bad "LAST_RUN.md written on the clean path"
have  "says the run was complete" "^\*\*Result:\*\* complete" "$FORK_DIR/LAST_RUN.md"
hasnt "does not say INCOMPLETE"   "INCOMPLETE"                "$FORK_DIR/LAST_RUN.md"
have  "carries the exit code"     "| exit code | 0 |"         "$FORK_DIR/LAST_RUN.md"
have  "carries the upstream sha"  "$C4"                       "$FORK_DIR/LAST_RUN.md"
have  "carries the master sha"    "$X1"                       "$FORK_DIR/LAST_RUN.md"
eq    "issue body says there is nothing outstanding" \
      "No integration failures: every managed branch reached \`master\`." "$(last_run_issue_body)"

# --- 7: write_last_run on a failed run --------------------------------------
section "7  write_last_run 3 with rows"
incomplete_reset
check_pr_drift 2>/dev/null
fail_add "feat/gone"     missing-branch   "listed in features.txt but no local ref" 2>/dev/null
fail_add "feat/stubborn" rebase-failed    "3 files conflicted during rebase"        2>/dev/null
fail_add "chore/stray"   unmanaged-branch "in neither manifest"                     2>/dev/null
fail_add "fix/1-gamma"   merge-conflict   "cherry-pick conflicted in: app/src/Alpha.kt" 2>/dev/null
rm -f "$FORK_DIR/LAST_RUN.md"
write_last_run 3 "$C4" "$C4" "$X1"
have "says INCOMPLETE"        "^\*\*Result:\*\* INCOMPLETE" "$FORK_DIR/LAST_RUN.md"
# The merge-conflict advice must not tell an operator to merge a branch the run
# integrates by cherry-pick: emit_report was corrected for this and LAST_RUN.md
# is the artifact the nightly job actually surfaces.
have "merge-conflict advice names cherry-pick for a stale base" \
     "git cherry-pick" "$FORK_DIR/LAST_RUN.md"
have "merge-conflict advice says --continue rebuilds the branch" \
     "REBUILDS master" "$FORK_DIR/LAST_RUN.md"
have "carries exit code 3"    "| exit code | 3 |"           "$FORK_DIR/LAST_RUN.md"
for b in fix/2-behind fix/3-ahead fix/4-diverged fix/5-no-remote feat/gone feat/stubborn chore/stray fix/1-gamma; do
  have "names branch $b" "\`$b\`" "$FORK_DIR/LAST_RUN.md"
done
for k in pr-drift-behind pr-drift-ahead pr-drift-diverged pr-no-remote \
         missing-branch rebase-failed unmanaged-branch merge-conflict; do
  have "groups under kind $k" "^## $k$" "$FORK_DIR/LAST_RUN.md"
done
eq "one 'What to do' line per kind present" 8 \
   "$(grep -c '^\*\*What to do:\*\*' "$FORK_DIR/LAST_RUN.md")"
hasnt "no kind heading for a kind with no rows" "^## stale-base$" "$FORK_DIR/LAST_RUN.md"
last_run_issue_body > "$T/issue.md"
have "issue body counts the failures" "^8 outstanding integration failure(s):" "$T/issue.md"
have "issue body names a branch"      "\`fix/2-behind\`"                       "$T/issue.md"

section "9  every kind sync-upstream.sh passes to fail_add is registered"
# This is the guard for a real failure: two call sites used kinds that were never
# in _fork_kinds(), so the FIRST branch to hit one killed a 76-branch run 23
# branches in, with "ERR fail_add: unknown kind". It was invisible until then --
# no harness exercised the caller. Registration is checked against the script
# itself, so a new fail_add with an unregistered kind fails here, not in production.
SYNC="${FORK_SYNC:-$HERE/../sync-upstream.sh}"
if [[ -r "$SYNC" ]]; then
  registered=" $(_fork_kinds | tr '\n' ' ') "
  used="$(grep -oE 'fail_add "\$b" [a-z-]+' "$SYNC" | awk '{print $3}' | sort -u)"
  [[ -n "$used" ]] && ok "found fail_add call sites in sync-upstream.sh" \
                   || bad "found NO fail_add call sites -- the grep is wrong, not the script"
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    if [[ "$registered" == *" $k "* ]]; then ok "kind '$k' is registered"
    else bad "kind '$k' is used by sync-upstream.sh but NOT in _fork_kinds()"; fi
  done <<< "$used"
else
  bad "cannot read $SYNC to check kind registration"
fi

section "10  LAST_RUN.md keys 'truncated' off the loop, not off the exit code"
# A real run finished the loop over both manifests, recorded 42 rows, and then
# died in a later stage with exit 1. LAST_RUN.md told the operator the rows were
# truncated. They were the complete picture.
incomplete_reset
fail_add "feat/one" rebase-failed  "conflicted"  2>/dev/null
fail_add "feat/two" merge-conflict "conflicted"  2>/dev/null
rm -f "$FORK_DIR/LAST_RUN.md"
INTEGRATION_LOOP_DONE=1 write_last_run 1 "$C4" "$C4" "$X1"
have  "loop finished: says the rows are the complete picture" \
      "reached the end of both manifests" "$FORK_DIR/LAST_RUN.md"
hasnt "loop finished: does NOT claim the rows are truncated" \
      "truncated"                         "$FORK_DIR/LAST_RUN.md"
have  "loop finished: still reports the failure" \
      "^\*\*Result:\*\* FAILED"           "$FORK_DIR/LAST_RUN.md"
have  "loop finished: still lists the rows" "\`feat/one\`" "$FORK_DIR/LAST_RUN.md"
rm -f "$FORK_DIR/LAST_RUN.md"
INTEGRATION_LOOP_DONE=0 write_last_run 1 "$C4" "$C4" "$X1"
have  "loop cut short: says the rows are truncated" \
      "truncated"                         "$FORK_DIR/LAST_RUN.md"
hasnt "loop cut short: does not claim completeness" \
      "reached the end of both manifests" "$FORK_DIR/LAST_RUN.md"
# The signal is only consulted on the died-in-a-later-stage path. A clean
# refusal already knows the loop ran.
rm -f "$FORK_DIR/LAST_RUN.md"
INTEGRATION_LOOP_DONE=0 write_last_run 3 "$C4" "$C4" "$X1"
hasnt "exit 3 is a clean refusal, never 'truncated'" "truncated" "$FORK_DIR/LAST_RUN.md"

section "11  a signalled run records the signal, not the last command's status"
# bash runs the EXIT trap on SIGTERM, but `on_exit $?` there reads the status of
# the last command that COMPLETED -- so a killed run wrote 'exit code 0 /
# complete'. The trap wiring is lifted out of sync-upstream.sh verbatim so this
# tests the real statements, not a copy of them.
SIGD="$T/signal"
mkdir -p "$SIGD/.fork"
if [[ -r "$SYNC" ]]; then
  {
    echo 'set -euo pipefail'
    printf 'FORK_DIR=%q\n'      "$SIGD/.fork"
    printf 'REPORT=%q\n'        "$SIGD/.fork/.report"
    printf 'UPSTREAM_REF=%q\n'  "$UPSTREAM_REF"
    printf 'MIRROR=%q\n'        "$MIRROR"
    printf 'INTEGRATION=%q\n'   "$INTEGRATION"
    echo 'DRY_RUN=0'
    echo 'INTEGRATION_LOOP_DONE=1'
    printf '. %q\n' "${FORK_LIB:-$HERE/../lib}/integrity.sh"
    sed -n '/^LAST_RUN_WRITTEN=0$/,/^finish()/p' "$SYNC"
    grep -E "^ *trap '" "$SYNC"
    echo 'true'
    echo 'kill -TERM $$'
    echo 'sleep 5'
  } > "$SIGD/run.sh"
  eq "the trap wiring lifted from sync-upstream.sh has an INT and a TERM trap" 2 \
     "$(grep -cE "^ *trap '(finish 130' INT|finish 143' TERM)" "$SIGD/run.sh")"
  sigrc=0
  bash "$SIGD/run.sh" >/dev/null 2>&1 || sigrc=$?
  eq "a TERM'd run exits 143" 143 "$sigrc"
  if [[ -f "$SIGD/.fork/LAST_RUN.md" ]]; then
    ok "a TERM'd run still writes LAST_RUN.md"
    have  "...recording the signal's code, not 0" "| exit code | 143 |" "$SIGD/.fork/LAST_RUN.md"
    hasnt "...and never claiming the run completed" "^\*\*Result:\*\* complete" "$SIGD/.fork/LAST_RUN.md"
    eq "write_last_run_once is idempotent: the EXIT trap did not rewrite it" 1 \
       "$(grep -c '^# Fork sync' "$SIGD/.fork/LAST_RUN.md")"
  else
    bad "a TERM'd run still writes LAST_RUN.md"
  fi
else
  bad "cannot read $SYNC to lift the trap wiring"
fi

section "12  assert_patch_landed refuses a patch that applied nothing"
# `git format-patch -1` on a MERGE commit emits an empty patch, and
# `git am --3way` on an empty patch exits 0 having done nothing. Every rebuild
# then drops the fix that patch was supposed to carry, silently.
(
  cd "$REPO_ROOT"
  h="$(git rev-parse HEAD)"
  if ( assert_patch_landed "0001-empty.patch" "$h" ) >/dev/null 2>&1; then
    exit 3
  fi
  git commit -q --allow-empty -m "a patch that did land"
  assert_patch_landed "0002-real.patch" "$h" || exit 4
) 2>/dev/null && landrc=0 || landrc=$?
case "$landrc" in
  0) ok "assert_patch_landed dies on an unmoved HEAD and stays silent on a moved one" ;;
  3) bad "assert_patch_landed did NOT fire when HEAD had not moved" ;;
  4) bad "assert_patch_landed fired on a patch that DID create a commit" ;;
  *) bad "assert_patch_landed case aborted (rc=$landrc)" ;;
esac
if err="$( ( cd "$REPO_ROOT"; assert_patch_landed "0001-empty.patch" "$(git rev-parse HEAD)" ) 2>&1 )"; then :; fi
case "$err" in
  *"applied nothing"*) ok "...and says the patch applied nothing" ;;
  *) bad "...error text does not say the patch applied nothing: $err" ;;
esac
case "$err" in
  *merge*) ok "...and names the merge-commit export as the cause" ;;
  *) bad "...error text does not name the cause" ;;
esac

# --- 13: check_merge_only_content -------------------------------------------
section "13  check_merge_only_content: content a merge carries in no parent"
# A branch whose base predates the mirror is integrated by cherry-pick, whose
# pick list is --no-merges. A merge carrying content of its OWN -- lines in no
# parent -- is therefore dropped: it is in no non-merge commit, nothing replays
# it, nothing is recorded, every gate passes and master publishes without it.
# feature/search-index-button @ 3e79bd6a61 is the live instance: 38 such lines.
#
# The fixture carries all three shapes the guard has to tell apart:
#   feat/evil        a hand-made resolution      -> MUST fire
#   feat/interleave  both parents' one-sided changes combined, so the combined
#                    diff is NON-EMPTY but every line is in a parent -> must NOT
#                    fire. This is fix/2914-phone-word-boundary's shape, and it
#                    is in pr-branches.txt, whose base is permanently stale by
#                    fork rule: firing on it would fail every future run with no
#                    legal remedy.
#   feat/linear      no merge at all             -> must NOT fire
MR="$T/mergeonly"
git init -q "$MR"
(
  cd "$MR"
  git config user.email t@example.invalid
  git config user.name  "merge-only test"
  git config commit.gpgsign false

  printf 'L1\nL2\nL3\n' > f.txt
  git add f.txt; git commit -qm base
  BASE="$(git rev-parse HEAD)"
  printf 'TOP\nL1\nL2\nDEV-A\nDEV-B\nL3\n' > f.txt
  git add f.txt; git commit -qm u1
  git branch develop

  # A merge that edits a file itself, so the result is in NEITHER parent. Its own
  # non-merge commit touches a DIFFERENT file, so the pick list replays cleanly
  # and the loss is silent rather than a conflict.
  git checkout -q -b feat/evil "$BASE"
  printf 'A\n' > a.txt
  git add a.txt; git commit -qm e1
  git merge --no-commit --no-ff develop >/dev/null 2>&1 || true
  printf 'TOP\nL1\nL2\nDEV-A\nDEV-B\nL3\nRESOLVED-IN-THE-MERGE-ONLY\n' > f.txt
  git add f.txt; git commit -qm "Merge develop into feat/evil" >/dev/null

  # fix/2914-phone-word-boundary's exact shape: both sides add different code in
  # the SAME region, git raises a conflict, and the human resolves it by keeping
  # both blocks verbatim. The result is in neither parent, so --cc prints real
  # hunks -- but every line came from one parent, so the pick list reproduces it.
  git checkout -q -b feat/interleave "$BASE"
  printf 'L1\nL2\nFEAT-A\nFEAT-B\nL3\n' > f.txt
  git add f.txt; git commit -qm i1
  git merge --no-commit --no-ff develop >/dev/null 2>&1 || true
  printf 'TOP\nL1\nL2\nDEV-A\nDEV-B\nFEAT-A\nFEAT-B\nL3\n' > f.txt
  git add f.txt; git commit -qm "Merge develop into feat/interleave" >/dev/null

  git checkout -q -b feat/linear "$BASE"
  printf 'linear\n' > h.txt
  git add h.txt; git commit -qm h1

  # The mirror moves on, so all three have a base predating it and would be
  # integrated by cherry-pick rather than merged.
  git checkout -q develop
  printf 'TOP\nL1\nL2\nDEV-A\nDEV-B\nL3\nlater\n' > f.txt
  git add f.txt; git commit -qm u2
  git checkout -q feat/linear
)
cd "$MR"
EVIL="$(git rev-list --merges develop..feat/evil)"
ILV="$(git rev-list --merges develop..feat/interleave)"

# The harm, in git terms, independent of any module version.
seen=0
for c in $(git rev-list --no-merges develop..feat/evil); do
  if git show "$c:f.txt" 2>/dev/null | grep -q RESOLVED-IN-THE-MERGE-ONLY; then seen=1; fi
done
eq "the resolution is in NO non-merge commit, so --no-merges cannot replay it" 0 "$seen"
eq "...yet it IS in the branch tip" 1 "$(git show feat/evil:f.txt | grep -c RESOLVED-IN-THE-MERGE-ONLY)"

# Why the loose test is not usable: BOTH merges have a non-empty combined diff.
eq "the evil merge's combined diff names f.txt"       "f.txt" \
   "$(git diff-tree --cc --no-commit-id --name-only -r "$EVIL")"
eq "the INTERLEAVED merge's combined diff names it too -- the loose test cannot tell them apart" "f.txt" \
   "$(git diff-tree --cc --no-commit-id --name-only -r "$ILV")"
# Without this the interleave fixture can degenerate into a clean auto-merge,
# whose --cc TEXT is empty -- and then the false-positive control below passes
# against a loose byte-count predicate too, proving nothing. fix/2914 has 6272
# such bytes and zero all-parent lines; the fixture must have the same shape.
eq "the interleave really does emit combined-diff TEXT (as fix/2914 does)" 1 \
   "$( [ "$(git show --cc --format="" "$ILV" | wc -c)" -gt 0 ] && echo 1 || echo 0 )"

# A plain rebase is NOT a safe remedy: it replays --no-merges as well, so it
# drops the resolution, exits 0, and leaves the branch on the merge path where
# the cherry-pick guard can no longer see it. This is why the advice must not
# say "rebase it" and why rebase_features skips such a branch.
# Run it on a COPY: a rebase that goes wrong would otherwise leave a conflicted
# index behind and take the rest of the harness with it.
RB="$T/rebasedrop"
rm -rf "$RB"; cp -r "$MR" "$RB"
REB_RC=0
(
  cd "$RB"
  git checkout -q -B rebasetest feat/evil
  git rebase --onto develop "$(git merge-base rebasetest develop)" rebasetest >/dev/null 2>&1
) || REB_RC=$?
eq "the rebase SUCCEEDS (exit 0), so nothing marks it as a problem" 0 "$REB_RC"
eq "...and the resolution is GONE from the rebased branch" 0 \
   "$(git -C "$RB" show rebasetest:f.txt | grep -c RESOLVED-IN-THE-MERGE-ONLY)"
git -C "$RB" merge-base --is-ancestor develop rebasetest && ANC=yes || ANC=no
eq "...and the branch is now on the MERGE path, where no guard looks" "yes" "$ANC"

if ! declare -F check_merge_only_content >/dev/null 2>&1; then
  bad "check_merge_only_content is not defined -- the cherry-pick loss site is unguarded, a branch whose only unique content is in a merge integrates silently and master publishes without it"
else
  eq "the strict count is non-zero for the hand-made resolution" 1 \
     "$( [ "$(_fork_merge_only_lines "$EVIL")" -gt 0 ] && echo 1 || echo 0 )"
  eq "the strict count is ZERO for the interleave"               0 "$(_fork_merge_only_lines "$ILV")"

  incomplete_reset
  rc=0; check_merge_only_content develop feat/evil 2>/dev/null || rc=$?
  eq "fires on a merge carrying content in no parent (returns 1)" 1 "$rc"
  eq "records exactly one row"                                    1 "$(incomplete_count)"
  eq "the row's kind is merge-only-content"                       1 "$(kind_rows merge-only-content)"
  have "the row names the branch"        "^feat/evil	merge-only-content" "$REPORT.incomplete"
  have "the detail names the merge sha"  "$(git rev-parse --short "$EVIL")"       "$REPORT.incomplete"
  have "the detail says it cannot be replayed" "cannot be replayed"               "$REPORT.incomplete"

  # The load-bearing negative control. Firing here would fail every future run
  # on a branch the fork rules forbid rebasing, renaming or amending.
  incomplete_reset
  rc=0; check_merge_only_content develop feat/interleave 2>/dev/null || rc=$?
  eq "an interleaved merge is NOT flagged (returns 0)" 0 "$rc"
  eq "...and records nothing"                          0 "$(incomplete_count)"

  incomplete_reset
  rc=0; check_merge_only_content develop feat/linear 2>/dev/null || rc=$?
  eq "a branch with no merges is NOT flagged (returns 0)" 0 "$rc"
  eq "...and records nothing"                             0 "$(incomplete_count)"

  eq "merge_only_carriers is silent on the interleave" "" "$(merge_only_carriers develop feat/interleave)"
  eq "merge_only_carriers names the evil merge"        1  \
     "$(merge_only_carriers develop feat/evil | grep -c "$(git rev-parse --short "$EVIL")")"

  if _fork_kinds | grep -qx merge-only-content; then
    ok "merge-only-content is registered in _fork_kinds"
  else
    bad "merge-only-content is NOT registered in _fork_kinds"
  fi
  ADV="$(_fork_kind_advice merge-only-content)"
  case "$ADV" in
    *"Unknown kind"*) bad "no advice registered for merge-only-content" ;;
    *)                ok  "advice is registered for merge-only-content" ;;
  esac
  # The remedy must not be "rebase it": that is the one action proven above to
  # destroy the content.
  case "$ADV" in
    *"Do NOT rebase"*) ok  "advice warns that a rebase drops the content" ;;
    *)                 bad "advice does not warn against rebasing -- the one action that destroys it" ;;
  esac
  case "$ADV" in
    *pr-branches.txt*) ok  "advice covers the branch class that may never be rebased" ;;
    *)                 bad "advice does not say what to do for a pr-branches.txt branch" ;;
  esac
fi

# Every registered kind must have real advice. Nothing else checks this, and a
# kind whose arm is missing silently falls through to "Unknown kind."
missing_adv=0
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  [[ "$(_fork_kind_advice "$k")" == "Unknown kind." ]] && missing_adv=$((missing_adv + 1))
done < <(_fork_kinds)
eq "every kind in _fork_kinds has advice that is not the fallback" 0 "$missing_adv"

# Wiring: the guard must be CALLED at BOTH loss sites -- before the pick list is
# built, and before the rebase that would drop the same content.
cd "$REPO_ROOT"
if [[ -r "$SYNC" ]]; then
  CALL_LN="$(grep -nF 'check_merge_only_content "$MIRROR" "$b"' "$SYNC" | head -n1 | cut -d: -f1)"
  PICK_LN="$(grep -nF 'picks="$(git rev-list --reverse --no-merges' "$SYNC" | head -n1 | cut -d: -f1)"
  REB_CALL="$(grep -nF 'merge_only_carriers "$MIRROR" "$b"' "$SYNC" | head -n1 | cut -d: -f1)"
  REB_LN="$(grep -nF 'git rebase --onto "$MIRROR"' "$SYNC" | head -n1 | cut -d: -f1)"
  if [[ -n "$CALL_LN" ]]; then ok "sync-upstream.sh calls the guard at the cherry-pick site"
  else bad "sync-upstream.sh never calls check_merge_only_content -- the guard is dead code"; fi
  if [[ -n "$CALL_LN" && -n "$PICK_LN" && "$CALL_LN" -lt "$PICK_LN" ]]; then
    ok "the guard runs BEFORE the --no-merges pick list is built"
  else
    bad "guard call (line ${CALL_LN:-none}) does not precede the pick list (line ${PICK_LN:-none})"
  fi
  if [[ -n "$REB_CALL" && -n "$REB_LN" && "$REB_CALL" -lt "$REB_LN" ]]; then
    ok "rebase_features checks for merge-only content BEFORE rebasing"
  else
    bad "rebase_features rebases (line ${REB_LN:-none}) without checking first (check at ${REB_CALL:-none}) -- the rebase drops the content"
  fi
else
  bad "cannot read $SYNC to check the guard is wired in"
fi

# --- result -----------------------------------------------------------------
printf '\n=====================================\n'
printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
REACHED_END=1
[[ $FAILED -eq 0 ]] || exit 1
echo "ALL GREEN"
