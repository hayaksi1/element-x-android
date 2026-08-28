#!/usr/bin/env bash
# Harness for .fork/regen-manifests.sh.
#
# The guard under test is the drop refusal. Every case that asserts it also
# asserts the file was not touched, because "exited non-zero" and "changed
# nothing" are different promises and only the second one saves the manifest.
set -uo pipefail

REACHED_END=0
on_abort() {
  local rc=$?
  [[ $REACHED_END -eq 1 ]] && return 0
  printf '\n\033[1;31mABORT\033[0m  the harness died before the summary (exit %s).\n' "$rc"
  printf '        The last PASS above is the last case that COMPLETED.\n'
  exit 1
}
trap on_abort EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${FORK_SUT:-$HERE/../regen-manifests.sh}"
T="$HERE/t-regen"; rm -rf "$T"; mkdir -p "$T"

PASSES=0; FAILS=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASSES=$((PASSES+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
is()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 -- expected [$3], got [$2]"; fi; }

# --- a throwaway fork: work repo + bare origin + bare upstream ---------------
build_repo() {
  rm -rf "$T/up" "$T/orig" "$T/work"
  git init -q --bare "$T/up"; git init -q --bare "$T/orig"
  git init -q "$T/work"; cd "$T/work"
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$T/orig"; git remote add upstream "$T/up"

  echo base > f; git add f; git commit -qm base
  git branch -M develop
  git push -q upstream develop; git push -q origin develop

  mkdir -p .fork
  # three manifest branches: one open, one closed-unmerged, one that will be merged
  for b in fix/1-open fix/2-closed fix/3-merged; do
    git checkout -q -b "$b" develop
    # NOT "$b.txt": a branch name contains a slash, so that redirect fails and
    # the branch ends up identical to develop -- which makes every proof-based
    # case below pass against nothing.
    echo "$b" > "${b//\//-}.txt"; git add .; git commit -qm "$b"
    git push -q origin "$b"
    git checkout -q develop
  done

  # Fixture guard. A silently-degenerate fixture is how a suite goes green while
  # asserting nothing, so prove the branches really diverge before testing.
  local n
  for b in fix/1-open fix/2-closed fix/3-merged; do
    n="$(git rev-list --count "develop..$b")"
    [[ "$n" -ge 1 ]] || { printf '\033[1;31mABORT\033[0m fixture broken: %s has %s commits over develop\n' "$b" "$n"; exit 1; }
  done
  # fix/3-merged really is absorbed upstream: fast-forward develop onto it
  git merge -q --ff-only fix/3-merged 2>/dev/null || git merge -q --no-ff --no-edit fix/3-merged
  git push -q upstream develop:develop
  git push -q origin develop:develop
  git fetch -q origin; git fetch -q upstream

  cat > .fork/pr-branches.txt <<'EOF'
# Heads of upstream PRs. MERGED AS-IS.
fix/1-open
fix/2-closed
fix/3-merged
EOF
  printf '# fork-only\nfeat/mine\n'          > .fork/features.txt
  printf '# acknowledged\nfix/9-unmanaged\n' > .fork/unmanaged-branches.txt
  git add .fork; git commit -qm manifests
}

prjson() { printf '%s\n' "$1" > "$T/prs.json"; }
run()    { FORK_PR_JSON="$T/prs.json" FORK_UPSTREAM=upstream/develop FORK_REMOTE=origin bash "$SUT" "$@" 2>"$T/err" >"$T/out"; }
sum()    { md5sum < "$T/work/.fork/pr-branches.txt" | cut -d' ' -f1; }

FULL='[{"number":1,"headRefName":"fix/1-open","state":"OPEN","mergedAt":null},
       {"number":2,"headRefName":"fix/2-closed","state":"CLOSED","mergedAt":null},
       {"number":3,"headRefName":"fix/3-merged","state":"MERGED","mergedAt":"2026-01-01T00:00:00Z"}]'

echo "== 1. baseline: full PR data, nothing to add, nothing lost"
build_repo; prjson "$FULL"; before=$(sum)
run; rc=$?
is "1a. exits 0 on a current manifest" "$rc" "0"
is "1b. file untouched" "$(sum)" "$before"
grep -q 'fix/3-merged' "$T/out" && ok "1c. reports fix/3-merged as retirable" || bad "1c. did not report the provably-merged branch as retirable"

echo
echo "== 2. NEGATIVE CONTROL: truncated PR data must refuse, not shrink the file"
# fix/2-closed vanishes from the answer -- exactly what --state open would do.
prjson '[{"number":1,"headRefName":"fix/1-open","state":"OPEN","mergedAt":null},
         {"number":3,"headRefName":"fix/3-merged","state":"MERGED","mergedAt":"2026-01-01T00:00:00Z"}]'
before=$(sum)
run --apply; rc=$?
is "2a. exits NON-ZERO rather than writing a shorter manifest" "$rc" "1"
is "2b. manifest byte-identical after the refusal" "$(sum)" "$before"
grep -q 'fix/2-closed' "$T/err" && ok "2c. names the branch it would have lost" || bad "2c. refusal does not name the branch"
grep -qi 'would be lost' "$T/err" && ok "2d. says work would be lost" || bad "2d. refusal text does not say work would be lost"

echo
echo "== 3. the same shape a --state open recipe produces"
prjson '[{"number":1,"headRefName":"fix/1-open","state":"OPEN","mergedAt":null}]'
before=$(sum); run --apply; rc=$?
is "3a. refuses" "$rc" "1"
is "3b. file untouched" "$(sum)" "$before"

echo
echo "== 4. empty and malformed answers refuse too"
prjson '[]';        before=$(sum); run --apply; is "4a. empty array refuses"     "$?" "1"; is "4b. untouched" "$(sum)" "$before"
prjson 'not json';  before=$(sum); run --apply; is "4c. malformed refuses"       "$?" "1"; is "4d. untouched" "$(sum)" "$before"
: > "$T/prs.json";  before=$(sum); run --apply; is "4e. empty file refuses"      "$?" "1"; is "4f. untouched" "$(sum)" "$before"

echo
echo "== 5. a genuinely new closed-unmerged branch IS added, and only appended"
build_repo
git -C "$T/work" checkout -q -b fix/4-new develop
echo new > "$T/work/n.txt"; git -C "$T/work" add .; git -C "$T/work" commit -qm new
git -C "$T/work" push -q origin fix/4-new; git -C "$T/work" fetch -q origin
git -C "$T/work" checkout -q develop
prjson "$(printf '%s' "$FULL" | sed 's/\]$/,{"number":4,"headRefName":"fix\/4-new","state":"CLOSED","mergedAt":null}]/')"
head_before="$(head -4 "$T/work/.fork/pr-branches.txt")"
run --apply; rc=$?
is "5a. exits 0" "$rc" "0"
grep -qx 'fix/4-new' "$T/work/.fork/pr-branches.txt" && ok "5b. the new branch is in the manifest" || bad "5b. new branch not added"
is "5c. existing bytes untouched (append-only)" "$(head -4 "$T/work/.fork/pr-branches.txt")" "$head_before"
is "5d. no line was removed" "$(grep -cx 'fix/1-open\|fix/2-closed\|fix/3-merged' "$T/work/.fork/pr-branches.txt")" "3"

echo
echo "== 6. an acknowledged unmanaged branch is reported, never silently adopted"
build_repo
git -C "$T/work" checkout -q -b fix/9-unmanaged develop
echo u > "$T/work/u.txt"; git -C "$T/work" add .; git -C "$T/work" commit -qm u
git -C "$T/work" push -q origin fix/9-unmanaged; git -C "$T/work" fetch -q origin
git -C "$T/work" checkout -q develop
prjson "$(printf '%s' "$FULL" | sed 's/\]$/,{"number":9,"headRefName":"fix\/9-unmanaged","state":"CLOSED","mergedAt":null}]/')"
run --apply; rc=$?
is "6a. exits 0" "$rc" "0"
grep -qx 'fix/9-unmanaged' "$T/work/.fork/pr-branches.txt" && bad "6b. adopted an acknowledged branch" || ok "6b. did not adopt it"
grep -q 'fix/9-unmanaged' "$T/err" && ok "6c. reported it for a human decision" || bad "6c. did not report it"

echo
echo "== 7. a MERGED branch upstream later REVERTED is NOT retirable"
build_repo
# fix/3-merged is an ancestor of upstream/develop, so both proofs pass...
git -C "$T/work" checkout -q develop
echo revert > "$T/work/r.txt"; git -C "$T/work" add .
git -C "$T/work" commit -qm "Merge pull request #99 from element-hq/revert-3-fix/3-merged"
git -C "$T/work" push -q upstream develop:develop; git -C "$T/work" fetch -q upstream
# ...but the revert makes it un-prunable, so dropping its line must be refused.
prjson '[{"number":1,"headRefName":"fix/1-open","state":"OPEN","mergedAt":null},
         {"number":2,"headRefName":"fix/2-closed","state":"CLOSED","mergedAt":null},
         {"number":3,"headRefName":"fix/3-merged","state":"MERGED","mergedAt":"2026-01-01T00:00:00Z"}]'
before=$(sum); run --apply; rc=$?
is "7a. reverted-but-merged branch is not treated as retirable" "$rc" "1"
is "7b. file untouched" "$(sum)" "$before"
grep -q 'fix/3-merged' "$T/err" && ok "7c. names the reverted branch" || bad "7c. does not name it"

echo
echo "========================================"
printf 'passed: %s   failed: %s\n' "$PASSES" "$FAILS"
REACHED_END=1
trap - EXIT
[[ $FAILS -eq 0 ]] && { printf '\033[1;32mHARNESS OK\033[0m\n'; exit 0; }
printf '\033[1;31mHARNESS FAILED\033[0m\n'; exit 1
