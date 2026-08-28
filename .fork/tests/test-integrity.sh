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

# --- result -----------------------------------------------------------------
printf '\n=====================================\n'
printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
REACHED_END=1
[[ $FAILED -eq 0 ]] || exit 1
echo "ALL GREEN"
