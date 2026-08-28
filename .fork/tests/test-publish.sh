#!/usr/bin/env bash
# Test harness for .fork/lib/publish.sh.
#
# Builds throwaway repos under ./t/ -- a work repo and a SECOND REAL LOCAL REPO
# acting as `origin` -- and exercises every function, including the failure
# paths. A guard that has not been seen to fire is not a guard, so each case
# proves both halves where one exists.
# SC2034: the globals below exist because sync-upstream.sh defines them; the
# module under test reads some and the rest document the contract.
# shellcheck disable=SC2034
set -euo pipefail

# The harness runs under `set -e`, so a module bug can kill it outright, mid-case
# -- and a transcript with no FAIL lines then LOOKS green to anything grepping
# for FAIL. This makes an abort louder than a failure.
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/t"
rm -rf "$T"; mkdir -p "$T"

# --- globals the module reads, as defined by sync-upstream.sh ---------------
MIRROR=develop
INTEGRATION=master
TOOLING=feat/fork-tooling
# The fixture's stand-in for upstream/develop. publish_ff reads this: the mirror
# push is gated on the mirror still being an ancestor of upstream.
UPSTREAM_REF=up
DRY_RUN=0; NO_PUSH=0; CONTINUE=0; SKIP_VERIFY=0; ONLY_FEATURES=""

# --- helpers the module calls, copied verbatim from sync-upstream.sh --------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

# --- stub for integrity.sh's assert_push_list (owned by another session) ----
APL_LOG="$T/assert_push_list.calls"
assert_push_list() { printf '%s\n' "$*" >> "$APL_LOG"; }

# shellcheck source=/dev/null
# The module lives in .fork/lib/; the harness in .fork/tests/.
. "${FORK_LIB:-$HERE/../lib}/publish.sh"

# --- scoring ----------------------------------------------------------------
PASSES=0; FAILURES=0
ok()  { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASSES=$((PASSES+1)); }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 -- expected [$3], got [$2]"; fi; }
hdr() { printf '\n\033[1m--- %s\033[0m\n' "$*"; }

git_q() { git "$@" >/dev/null 2>&1; }

# --- fixture ----------------------------------------------------------------
# Builds:
#   origin.git   bare, a real second repo
#   work         `up` (stands in for upstream/develop), `develop` (moved only by
#                update-ref, never checked out), `feat/x`, and an OLD `master`
#                already published to origin.
# Then advances `up`/`develop` by one commit, so a from-scratch rebuild produces
# a master with a DIFFERENT TREE and a history the old master is not part of.
fixture() {
  local name="$1" o w
  o="$T/$name/origin.git"; w="$T/$name/work"
  mkdir -p "$T/$name"
  git init -q --bare -b master "$o"

  git init -q -b up "$w"
  (
    cd "$w"
    git config user.email fork@example.invalid
    git config user.name  "Fork Sync"
    git config commit.gpgsign false
    echo a > a.txt; git add a.txt; git commit -qm c0
    echo b > b.txt; git add b.txt; git commit -qm c1
    git update-ref refs/heads/develop "$(git rev-parse up)"
    git branch feat/x "$(git rev-parse up~1)"
    git checkout -q feat/x
    echo f > f.txt; git add f.txt; git commit -qm f1
    git checkout -q -B master develop
    git merge -q --no-ff --no-edit -m "integrate feat/x" feat/x
    git remote add origin "$o"
    git push -q origin develop master
    # upstream moves on, so the next rebuild differs from the published master
    git checkout -q up
    echo c > c.txt; git add c.txt; git commit -qm c2
    git update-ref refs/heads/develop "$(git rev-parse up)"
    git checkout -q master
  )
  echo "$w"
}

# Replays what rebuild_integration does: master from scratch off the mirror.
rebuild() {
  git checkout -q -B "$INTEGRATION" "$MIRROR"
  git merge -q --no-ff --no-edit -m "integrate feat/x" feat/x
}

###############################################################################
hdr "case 1+2: graft makes a from-scratch rebuild a fast-forward"
###############################################################################
W="$(fixture core)"
cd "$W"
TS=$(sync_timestamp)
PREV="$(capture_prev_integration)"                 # old master, before it is destroyed
echo "  prev master (captured)   : $PREV"
rebuild
REBUILD="$(git rev-parse HEAD)"
echo "  rebuilt master (from scratch): $REBUILD"
if [[ "$PREV" != "$REBUILD" ]]; then
  ok "rebuild is a different commit from the old master"
else
  bad "fixture is degenerate: rebuild == old master"
fi
if git diff --quiet "$PREV" "$REBUILD"; then
  bad "fixture is degenerate: rebuild tree == old master tree"
else
  ok "rebuild TREE differs from the old master tree (as in a real sync)"
fi

echo
echo "  # BEFORE the graft -- a plain push must be REJECTED:"
rc=0; out="$(git push origin master:master 2>&1)" || rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
eq "plain push of an un-grafted rebuild is rejected (rc!=0)" "$([[ $rc -ne 0 ]] && echo rejected || echo accepted)" "rejected"
if printf '%s' "$out" | grep -qiE 'non-fast-forward|fetch first|rejected'; then
  ok "rejection reason is non-fast-forward"
else
  bad "rejection did not mention non-fast-forward"
fi

echo
graft_integration "$PREV" "$TS"

echo
echo "  # THE CORE CLAIM"
echo "  \$ git diff $REBUILD master"
rc=0; git --no-pager diff "$REBUILD" refs/heads/master || rc=$?
echo "      (no output above)  exit=$rc"
eq "git diff <rebuild> master is EMPTY" "$rc" "0"
echo "  \$ git merge-base --is-ancestor $PREV master"
rc=0; git merge-base --is-ancestor "$PREV" refs/heads/master || rc=$?
echo "      exit=$rc"
eq "old master IS an ancestor of the new master" "$rc" "0"
echo "  master is now $(git rev-parse --short master), parents: $(git log -1 --format='%p' master)"

echo
echo "  # AFTER the graft -- the same plain push must SUCCEED:"
rc=0; out="$(git push origin master:master 2>&1)" || rc=$?
printf '%s\n' "$out" | sed 's/^/      /'
eq "plain (non-force) push of the grafted master succeeds" "$rc" "0"
eq "origin/master now equals the local tip" \
   "$(git --git-dir="$T/core/origin.git" rev-parse master)" "$(git rev-parse master)"
eq "origin/master content equals the rebuild content" \
   "$(git --git-dir="$T/core/origin.git" rev-parse 'master^{tree}')" "$(git rev-parse "$REBUILD^{tree}")"

###############################################################################
hdr "case 3: graft_integration \"\" (first-ever run) is a clean no-op"
###############################################################################
W="$(fixture firstrun)"; cd "$W"
rebuild
BEFORE="$(git rev-parse master)"
rc=0; graft_integration "" "$(sync_timestamp)" || rc=$?
eq "returns 0" "$rc" "0"
eq "master unmoved" "$(git rev-parse master)" "$BEFORE"

###############################################################################
hdr "case 4: graft onto a sha that is already an ancestor is a clean no-op"
###############################################################################
W="$(fixture ancestor)"; cd "$W"
rebuild
BEFORE="$(git rev-parse master)"
ANC="$(git rev-parse develop)"     # the mirror is by construction an ancestor
rc=0; graft_integration "$ANC" "$(sync_timestamp)" || rc=$?
eq "returns 0" "$rc" "0"
eq "master unmoved" "$(git rev-parse master)" "$BEFORE"

###############################################################################
hdr "case 5: tag_sync creates the tag once and refuses to overwrite it"
###############################################################################
W="$(fixture tagging)"; cd "$W"
rebuild
TS2=$(sync_timestamp)
rc=0; tag_sync "$TS2" || rc=$?
eq "first tag_sync returns 0" "$rc" "0"
eq "sync/$TS2 points at master" "$(git rev-parse "sync/$TS2^{commit}")" "$(git rev-parse master)"
eq "tag is annotated" "$(git cat-file -t "refs/tags/sync/$TS2")" "tag"
# Re-running after a push failed partway must not be blocked: same ts, same
# commit is the ordinary recovery path.
rc=0; ( tag_sync "$TS2" ) 2>"$T/tag_err.txt" || rc=$?
sed 's/^/      /' "$T/tag_err.txt"
eq "second tag_sync, same ts SAME commit, is a no-op (rc=0)" "$rc" "0"
eq "sync/$TS2 still points where it did" "$(git rev-parse "sync/$TS2^{commit}")" "$(git rev-parse master)"
# ... but the same ts pointing somewhere ELSE is overwriting a rollback point.
git commit -q --allow-empty -m "moves master on"
rc=0; ( tag_sync "$TS2" ) 2>"$T/tag_err2.txt" || rc=$?
sed 's/^/      /' "$T/tag_err2.txt"
eq "same ts at a DIFFERENT commit still dies (rc=1)" "$rc" "1"
eq "the rollback point was not moved" "$(git rev-parse "sync/$TS2^{commit}")" "$(git rev-parse master~1)"

###############################################################################
hdr "case 6: publish_ff dies when origin/master is not an ancestor"
###############################################################################
W="$(fixture divergent)"; cd "$W"
TS3=$(sync_timestamp)
PREV="$(capture_prev_integration)"
rebuild
graft_integration "$PREV" "$TS3" >/dev/null
tag_sync "$TS3" >/dev/null
GOOD="$(git rev-parse master)"
# A third party pushes something else onto origin/master. Force is used HERE by
# the harness to simulate a hostile remote -- publish.sh never forces anything.
git checkout -q -b rogue "$PREV"
echo rogue > rogue.txt; git add rogue.txt; git commit -qm "someone else's commit"
git push -q --force origin rogue:master
git checkout -q master
git fetch -q origin
echo "  origin/master = $(git rev-parse --short origin/master), local master = $(git rev-parse --short master)"
: > "$APL_LOG"
rc=0; ( publish_ff "$TS3" ) 2>"$T/pub_err.txt" || rc=$?
sed 's/^/      /' "$T/pub_err.txt"
eq "publish_ff dies (rc=1)" "$rc" "1"
eq "nothing was pushed: origin/master still the rogue commit" \
   "$(git --git-dir="$T/divergent/origin.git" rev-parse master)" "$(git rev-parse rogue)"
eq "assert_push_list was NOT reached" "$(wc -l < "$APL_LOG" | tr -d ' ')" "0"

###############################################################################
hdr "case 7: publish_ff honours NO_PUSH=1 and DRY_RUN=1"
###############################################################################
# restore a sane origin so the ancestor check passes and only the flag matters
git --git-dir="$T/divergent/origin.git" update-ref refs/heads/master "$PREV"
git fetch -q origin
O_BEFORE="$(git --git-dir="$T/divergent/origin.git" for-each-ref --format='%(refname) %(objectname)' | sort)"

: > "$APL_LOG"
NO_PUSH=1; rc=0; publish_ff "$TS3" || rc=$?; NO_PUSH=0
eq "NO_PUSH=1 returns 0" "$rc" "0"
eq "NO_PUSH=1 still ran assert_push_list (verification is not skipped)" \
   "$(cat "$APL_LOG")" "develop master sync/$TS3"
eq "NO_PUSH=1 pushed nothing" \
   "$(git --git-dir="$T/divergent/origin.git" for-each-ref --format='%(refname) %(objectname)' | sort)" "$O_BEFORE"

: > "$APL_LOG"
DRY_RUN=1; rc=0; publish_ff "$TS3" || rc=$?; DRY_RUN=0
eq "DRY_RUN=1 returns 0" "$rc" "0"
eq "DRY_RUN=1 pushed nothing" \
   "$(git --git-dir="$T/divergent/origin.git" for-each-ref --format='%(refname) %(objectname)' | sort)" "$O_BEFORE"

# ...and with both flags off it really does push, so the two cases above are
# proving the flags and not a broken function.
: > "$APL_LOG"
rc=0; publish_ff "$TS3" >/dev/null 2>&1 || rc=$?
eq "with no flags publish_ff returns 0" "$rc" "0"
eq "with no flags origin/master advanced to the grafted tip" \
   "$(git --git-dir="$T/divergent/origin.git" rev-parse master)" "$GOOD"
eq "with no flags the sync tag was pushed" \
   "$(git --git-dir="$T/divergent/origin.git" rev-parse "sync/$TS3^{commit}")" "$GOOD"

###############################################################################
hdr "case 8: graft refuses when master is not at HEAD (precondition guard)"
###############################################################################
W="$(fixture precond)"; cd "$W"
PREV="$(capture_prev_integration)"
rebuild
git checkout -q --detach HEAD~1                              # HEAD is no longer the rebuild
rc=0; ( graft_integration "$PREV" "$(sync_timestamp)" ) 2>"$T/pre_err.txt" || rc=$?
sed 's/^/      /' "$T/pre_err.txt"
eq "dies when refs/heads/master != HEAD" "$rc" "1"

###############################################################################
hdr "case 9: publish_ff pushes the mirror only while the mirror is pristine"
###############################################################################
# develop is a byte-exact copy of upstream. sync_mirror is the only thing that
# ever checked that -- and it is called only when CONTINUE is 0, while publish_ff
# pushes refs/heads/develop on every path. A --continue run published whatever
# was on local develop, unchecked, exit 0. Both halves are proven here: the
# healthy mirror must still be pushed, the poisoned one must stop the run dead.

# --- healthy: develop == up, so the push happens exactly as before ------------
W="$(fixture mirrorok)"; cd "$W"
O="$T/mirrorok/origin.git"
TS9=$(sync_timestamp)
PREV="$(capture_prev_integration)"
rebuild
graft_integration "$PREV" "$TS9" >/dev/null
tag_sync "$TS9" >/dev/null
git fetch -q origin
rc=0; git merge-base --is-ancestor refs/heads/develop up || rc=$?
eq "fixture precondition: develop IS an ancestor of up" "$rc" "0"
: > "$APL_LOG"
rc=0; publish_ff "$TS9" >/dev/null 2>&1 || rc=$?
eq "pristine mirror: publish_ff returns 0" "$rc" "0"
eq "pristine mirror: origin/develop advanced to the local mirror" \
   "$(git --git-dir="$O" rev-parse develop)" "$(git rev-parse develop)"
eq "pristine mirror: origin/master advanced too" \
   "$(git --git-dir="$O" rev-parse master)" "$(git rev-parse master)"

# --- poisoned: a fork commit on develop, as a --continue run would find it ----
W="$(fixture mirrorbad)"; cd "$W"
O="$T/mirrorbad/origin.git"
TS10=$(sync_timestamp)
PREV="$(capture_prev_integration)"
rebuild
graft_integration "$PREV" "$TS10" >/dev/null
tag_sync "$TS10" >/dev/null
git fetch -q origin
# Never checked out, exactly as the real script moves it: update-ref only.
git checkout -q -b poison develop
echo poison > poison.txt; git add poison.txt
git commit -qm "a fork commit that must never reach the mirror"
git update-ref refs/heads/develop "$(git rev-parse poison)"
git checkout -q master
rc=0; git merge-base --is-ancestor refs/heads/develop up || rc=$?
eq "fixture precondition: develop is NO LONGER an ancestor of up" "$rc" "1"

DEV_BEFORE="$(git --git-dir="$O" rev-parse develop)"
MAS_BEFORE="$(git --git-dir="$O" rev-parse master)"
TAG_BEFORE="$(git --git-dir="$O" for-each-ref --format='%(refname)' refs/tags | sort)"
rc=0; ( publish_ff "$TS10" ) >/dev/null 2>"$T/mirror_err.txt" || rc=$?
sed 's/^/      /' "$T/mirror_err.txt"
eq "poisoned mirror: publish_ff dies (rc=1)" "$rc" "1"
eq "poisoned mirror: origin/develop was NOT moved" \
   "$(git --git-dir="$O" rev-parse develop)" "$DEV_BEFORE"
eq "poisoned mirror: origin/master was NOT moved either" \
   "$(git --git-dir="$O" rev-parse master)" "$MAS_BEFORE"
eq "poisoned mirror: no tag was pushed" \
   "$(git --git-dir="$O" for-each-ref --format='%(refname)' refs/tags | sort)" "$TAG_BEFORE"
# Both halves, deliberately. The short sha ALONE is tautological: on the unfixed
# module publish_ff succeeds and `git push` prints "d893513..14bebe1 develop"
# to stderr, which contains that very sha -- the assertion passed against the
# defect it exists to catch. The refusal's own wording is what distinguishes a
# refusal from a successful push.
if grep -q 'carries fork commit' "$T/mirror_err.txt" &&
   grep -q "$(git rev-parse --short poison)" "$T/mirror_err.txt"; then
  ok "poisoned mirror: the refusal says why AND names the offending commit"
else
  bad "poisoned mirror: refusal text does not both explain and name the commit"
fi

# A --no-push rehearsal prints "refs verified". It must not print that over a
# poisoned mirror, so the guard runs before that early return -- as
# assert_push_list already does.
NO_PUSH=1; rc=0; ( publish_ff "$TS10" ) >/dev/null 2>&1 || rc=$?; NO_PUSH=0
eq "poisoned mirror: --no-push does not report 'refs verified' either (rc=1)" "$rc" "1"

# The mirror check cannot be satisfied by an unprovable upstream: "cannot tell"
# must refuse, not push.
git update-ref refs/heads/develop "$(git rev-parse up)"      # heal the mirror
rc=0; ( UPSTREAM_REF=""            ; publish_ff "$TS10" ) >/dev/null 2>&1 || rc=$?
eq "unset UPSTREAM_REF refuses rather than pushing unproven" "$rc" "1"
rc=0; ( UPSTREAM_REF="no/such/ref" ; publish_ff "$TS10" ) >/dev/null 2>&1 || rc=$?
eq "unresolvable UPSTREAM_REF refuses rather than pushing unproven" "$rc" "1"
# ...and with the mirror healed and UPSTREAM_REF sane it really does push again,
# so the four refusals above are proving the guard and not a broken function.
rc=0; publish_ff "$TS10" >/dev/null 2>&1 || rc=$?
eq "healed mirror: publish_ff returns 0 again" "$rc" "0"
eq "healed mirror: origin/develop finally advanced" \
   "$(git --git-dir="$O" rev-parse develop)" "$(git rev-parse develop)"

###############################################################################
printf '\n\033[1m======== %s passed, %s failed ========\033[0m\n' "$PASSES" "$FAILURES"
REACHED_END=1
[[ $FAILURES -eq 0 ]]
