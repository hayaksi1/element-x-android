#!/usr/bin/env bash
# Rebuild the fork's integration branch from a pristine upstream mirror.
#
#   develop  ff-only mirror of upstream/develop. Never carries a fork commit.
#   feat/*   fork-only work, rebased onto develop  (.fork/features.txt)
#   <pr>     heads of open upstream PRs, merged as-is, NEVER rebased
#            (.fork/pr-branches.txt)
#   master   develop + every branch, rebuilt from scratch. Disposable.
#
# This script never deletes or renames a branch.
#
# Exit codes:
#   0  pushed
#   1  hard error
#   2  bad flag
#   3  integration incomplete -- a branch did not make it in. NOT pushed.
#   4  a gate failed. NOT pushed.

# Re-exec from a temp copy: we switch branches while running and bash reads
# scripts incrementally, so editing the tree under ourselves would corrupt it.
if [[ "${FORK_SYNC_SELF_COPY:-}" != "1" ]]; then
  # Resolve the repo from the CWD, not from $0: the temp copy lives outside it.
  __root="$(git rev-parse --show-toplevel)" || {
    echo "not inside a git repository" >&2; exit 1; }
  __tmp="$(mktemp)"; cp "$0" "$__tmp"; chmod +x "$__tmp"
  FORK_SYNC_SELF_COPY=1 FORK_SYNC_ORIG="$__root" exec "$__tmp" "$@"
fi

set -euo pipefail

REPO_ROOT="${FORK_SYNC_ORIG:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"

FORK_DIR="$REPO_ROOT/.fork"
UPSTREAM_REF="upstream/develop"
MIRROR="develop"
INTEGRATION="master"
TOOLING="feat/fork-tooling"
STATE="$FORK_DIR/.state"
REPORT="$FORK_DIR/.report"

EXIT_INCOMPLETE=3
EXIT_GATE=4
SYNC_TS=""

DRY_RUN=0; NO_PUSH=0; CONTINUE=0; SKIP_VERIFY=0; ONLY_FEATURES=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --no-push)      NO_PUSH=1 ;;
    --continue)     CONTINUE=1 ;;
    --skip-verify)  SKIP_VERIFY=1 ;;
    --features=*)   ONLY_FEATURES="${arg#--features=}" ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

# --- manifest reading -------------------------------------------------------
# Manifests live on the tooling branch. On a fresh integration branch they are
# not in the worktree yet (tooling is merged first, but preflight runs before
# that), so fall back to reading them straight out of the tooling branch.
read_manifest() {
  local file base raw
  file="$1"
  base="$(basename "$file")"
  if [[ -f "$file" ]]; then
    raw="$(cat "$file")"
  elif raw="$(git show "$TOOLING:.fork/$base" 2>/dev/null)"; then
    :
  elif raw="$(git show "origin/$TOOLING:.fork/$base" 2>/dev/null)"; then
    :
  else
    die "missing manifest: $file (and not found on $TOOLING)"
  fi
  printf '%s\n' "$raw" | sed -e 's/#.*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
}

# --- modules ----------------------------------------------------------------
# The guards live in sourced modules so each one has its own test harness. They
# are read into memory HERE, before any checkout: rebuild_integration resets the
# worktree to develop, which has no .fork/ directory at all, so a module read
# later would not be on disk.
for __lib in integrity publish audit envcheck; do
  __f="$FORK_DIR/lib/$__lib.sh"
  if [[ ! -f "$__f" ]]; then
    __f="$(mktemp)"
    git show "$TOOLING:.fork/lib/$__lib.sh" > "$__f" 2>/dev/null \
      || die "missing module: .fork/lib/$__lib.sh (not in the worktree, not on $TOOLING)"
  fi
  # shellcheck source=/dev/null
  . "$__f"
  [[ "$__f" == "$FORK_DIR/lib/$__lib.sh" ]] || rm -f "$__f"
done
unset __lib __f

# --- LAST_RUN.md is written on every path, including the clean one ----------
LAST_RUN_WRITTEN=0
write_last_run_once() {
  [[ $LAST_RUN_WRITTEN -eq 1 ]] && return 0
  LAST_RUN_WRITTEN=1
  write_last_run "$1" \
    "$(git rev-parse --short "$UPSTREAM_REF" 2>/dev/null || echo '?')" \
    "$(git rev-parse --short "$MIRROR"       2>/dev/null || echo '?')" \
    "$(git rev-parse --short "$INTEGRATION"  2>/dev/null || echo '?')"
}
on_exit() { write_last_run_once "${1:-1}"; }
finish()  { write_last_run_once "$1"; exit "$1"; }

# --- preflight --------------------------------------------------------------
preflight() {
  log "preflight"

  local dirty
  dirty="$(git status --porcelain --untracked-files=no)"
  if [[ -n "$dirty" ]]; then
    echo "$dirty" >&2
    die "working tree has uncommitted tracked changes. Commit or stash first."
  fi

  # A dirty submodule is reported, never wiped.
  local sub
  sub="$(git submodule status --recursive 2>/dev/null | grep -E '^\+|^U' || true)"
  if [[ -n "$sub" ]]; then
    warn "submodule not at the recorded gitlink:"; echo "$sub" >&2
    die "refusing to run with a modified submodule; resolve it by hand."
  fi

  git remote get-url upstream >/dev/null 2>&1 || die "no 'upstream' remote configured."

  local feats prs both
  feats="$(read_manifest "$FORK_DIR/features.txt")"
  prs="$(read_manifest "$FORK_DIR/pr-branches.txt")"
  both="$(comm -12 <(echo "$feats" | sort -u) <(echo "$prs" | sort -u))"
  if [[ -n "$both" ]]; then
    echo "$both" >&2
    die "branch(es) listed in BOTH manifests. They get opposite treatment; fix the manifests."
  fi
  log "manifests ok: $(echo "$feats" | grep -c . ) fork-only, $(echo "$prs" | grep -c . ) pr-backed"
}

# Resolve snapshot conflicts deterministically. Branches on the status code:
# DU (deleted on our side) needs `git rm`; checkout --ours errors there.
resolve_snapshot_conflicts() {
  local resolved=0 line code path
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    code="${line:0:2}"; path="${line:3}"
    # Key off the merge ATTRIBUTE, not the path shape. The policy installed by
    # ensure_snapshot_attrs is what this resolver actually means, and the three
    # rules share no spellable prefix: `libraries/compound/screenshots/**`
    # neither begins with `screenshots/` nor contains the substring
    # "snapshots", so both of the old globs missed it -- and it covers assets
    # that are not .png, so a *.png filter would have missed it too. Those
    # paths would have fallen through to "anything still conflicted is real
    # code" and aborted the branch.
    [[ "$(git check-attr merge -- "$path" | sed 's/.*: //')" == "binary" ]] || continue
    case "$code" in
      DU) run git rm -q --  "$path" ;;
      *)  run git checkout --ours -- "$path"; run git add -- "$path" ;;
    esac
    resolved=$((resolved + 1))
  done < <(git status --porcelain | grep -E '^(UU|AA|UD|DU|DD) ' || true)
  if [[ $resolved -gt 0 ]]; then
    log "auto-resolved $resolved binary/snapshot path(s); these need re-recording"
  fi
}

# --- step 0: fetch ----------------------------------------------------------
fetch_remotes() {
  log "fetching upstream and origin"
  run git fetch upstream --prune --tags
  run git fetch origin --prune
}

# --- step 1: fast-forward the mirror ---------------------------------------
sync_mirror() {
  log "fast-forwarding $MIRROR to $UPSTREAM_REF"
  if [[ $DRY_RUN -eq 0 ]]; then
    # Never check the mirror out: a branch nobody has checked out cannot be
    # committed to by accident.
    if ! git merge-base --is-ancestor "$MIRROR" "$UPSTREAM_REF" 2>/dev/null; then
      warn "$MIRROR is NOT an ancestor of $UPSTREAM_REF."
      warn "Something committed to the mirror. It must stay pristine."
      warn "Offending commits:"
      git log --oneline "$UPSTREAM_REF..$MIRROR" >&2 || true
      die "refusing to continue. Move that work to a feat/* branch, then reset $MIRROR."
    fi
    git update-ref "refs/heads/$MIRROR" "$(git rev-parse "$UPSTREAM_REF")"
  fi
  log "$MIRROR is at $(git rev-parse --short "$MIRROR" 2>/dev/null || echo '?')"
}

# --- step 2: rebase fork-only branches -------------------------------------
rebase_features() {
  local branches=() b
  mapfile -t branches < <(read_manifest "$FORK_DIR/features.txt")
  if [[ -n "$ONLY_FEATURES" ]]; then
    local filtered=()
    for b in "${branches[@]}"; do
      case ",$ONLY_FEATURES," in *",$b,"*) filtered+=("$b") ;; esac
    done
    branches=("${filtered[@]}")
  fi

  for b in "${branches[@]}"; do
    git show-ref --verify --quiet "refs/heads/$b" || { warn "missing branch, skipping: $b"; continue; }
    if git merge-base --is-ancestor "$b" "$UPSTREAM_REF"; then
      log "absorbed upstream, nothing to rebase: $b"
      continue
    fi
    log "rebasing $b onto $MIRROR"
    if [[ $DRY_RUN -eq 1 ]]; then continue; fi
    if ! git rebase --onto "$MIRROR" "$(git merge-base "$b" "$MIRROR")" "$b" >/dev/null 2>&1; then
      git rebase --abort 2>/dev/null || true
      # The branch stays on its old base. It is integrated by cherry-pick below
      # rather than merged, but a human still has to rebase it, so the run is
      # incomplete and must not push.
      fail_add "$b" rebase-failed "rebase onto $MIRROR conflicted; branch left on its old base"
    fi
  done
  # Never leave the mirror checked out: a branch nobody has checked out cannot
  # be committed to by accident, and that is the invariant protecting develop.
  if [[ "$(git symbolic-ref -q --short HEAD || true)" == "$MIRROR" ]]; then
    git checkout --quiet "$INTEGRATION" 2>/dev/null ||
      git checkout --quiet "$TOOLING" 2>/dev/null || true
  fi
}

# --- step 3: rebuild the integration branch --------------------------------
integrate_branch() {
  local b="$1"
  local mode rc=0 picks before after gitdir

  # A previous branch can leave an operation in progress: a `cherry-pick
  # --continue` that refuses leaves CHERRY_PICK_HEAD behind, and git then
  # refuses to merge over it -- which took out the NEXT branch too. preflight
  # cannot see this, because the index still matches HEAD.
  gitdir="$(git rev-parse --git-dir)"
  if [[ -e "$gitdir/CHERRY_PICK_HEAD" || -e "$gitdir/MERGE_HEAD" ]]; then
    warn "clearing a leftover in-progress operation before integrating $b"
    git cherry-pick --quit >/dev/null 2>&1 || true
    git merge --abort      >/dev/null 2>&1 || true
    git reset -q --hard HEAD >/dev/null 2>&1 || true
  fi

  before="$(git rev-parse HEAD)"

  # A branch whose base predates the mirror cannot be MERGED: the merge drags
  # its stale base across everything already integrated and conflicts in files
  # the branch never touched. Integrate its unique commits by cherry-pick, which
  # touches only the integration branch.
  #
  # This applies to BOTH branch classes. A PR branch must never be rebased
  # (maintainers push onto it). A feat/* branch whose rebase failed above is in
  # exactly the same position -- and this test was previously gated on PR
  # membership, so the feat/* case fell through to the very merge the guard
  # exists to prevent.
  if ! git merge-base --is-ancestor "$MIRROR" "$b"; then
    mode="cherry-pick"
    picks="$(git rev-list --reverse --no-merges "$MIRROR..$b")"
    if [[ -z "$picks" ]]; then
      log "nothing unique to pick: $b"
      return 0
    fi
    # shellcheck disable=SC2086
    git cherry-pick --keep-redundant-commits $picks >/dev/null 2>&1 || rc=$?
  else
    mode="merge"
    git merge --no-ff --no-edit "$b" >/dev/null 2>&1 || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    # What was conflicted before anything touched it. rerere.autoUpdate has
    # already replayed whatever it recognised by this point, so a path that was
    # conflicted and is now staged was resolved without a human this run.
    local was_conflicted
    was_conflicted="$(git status --porcelain | grep -E '^(UU|AA|UD|DU|DD) ' \
                      | cut -c4- | paste -sd, - || true)"
    resolve_snapshot_conflicts
    # Anything still conflicted is real code. Never auto-resolve it.
    if git status --porcelain | grep -qE '^(UU|AA|UD|DU|DD) '; then
      local paths
      # cut, not awk: a path containing a space is truncated by $2.
      paths="$(git status --porcelain | grep -E '^(UU|AA|UD|DU|DD) ' \
               | cut -c4- | paste -sd, -)"
      printf '%s\t%s\n' "$b" "$paths" >> "$REPORT.conflicts"
      if [[ "$mode" == "cherry-pick" ]]; then
        git cherry-pick --abort 2>/dev/null || true
      else
        git merge --abort 2>/dev/null || true
      fi
      fail_add "$b" merge-conflict "$mode conflicted in: $paths"
      return 0
    fi
    # Concluding the operation MUST NOT be swallowed. `|| true` here was the
    # single worst bug in this script: when a branch conflicted only in binary
    # snapshot paths, resolve_snapshot_conflicts restored HEAD's copy of every
    # one of them, the pick became empty, `--continue` refused, and the error
    # was eaten. The branch contributed nothing, no row was recorded, and the
    # run pushed a green master with that branch's work missing -- reached by
    # the fork's own snapshot policy, on the most common branch shape here.
    local concluded=0
    if [[ "$mode" == "cherry-pick" ]]; then
      git -c core.editor=true cherry-pick --continue >/dev/null 2>&1 && concluded=1
    else
      git commit --no-edit >/dev/null 2>&1 && concluded=1
    fi
    if [[ $concluded -eq 0 ]]; then
      if git diff --cached --quiet HEAD 2>/dev/null; then
        git cherry-pick --skip >/dev/null 2>&1 || git cherry-pick --quit >/dev/null 2>&1 || true
        git merge --abort >/dev/null 2>&1 || true
        fail_add "$b" empty-after-resolve \
          "every conflicted path was binary, resolution kept ours, so the branch added nothing to $INTEGRATION"
      else
        git cherry-pick --abort >/dev/null 2>&1 || git cherry-pick --quit >/dev/null 2>&1 || true
        git merge --abort >/dev/null 2>&1 || true
        fail_add "$b" integrate-failed "$mode could not be concluded"
      fi
      return 0
    fi

    # This branch conflicted and was resolved with nobody watching -- by rerere
    # replaying a recorded answer, or by the snapshot resolver keeping ours.
    # Both are reported to git exactly like a clean merge, and rerere matches on
    # the SHAPE of a conflict hunk, not its meaning: when upstream moves so that
    # a hunk still hashes the same but now means something else, the stale
    # answer is reapplied silently. This does not block a sync -- it is how the
    # cache is supposed to work -- but a replay has to be distinguishable from a
    # clean merge, or nobody can ever notice a stale one.
    printf '%s\t%s\n' "$b" "${was_conflicted:-?}" >> "$REPORT.autoresolved"
  fi

  after="$(git rev-parse HEAD)"
  # Retirement is ADVISORY ONLY and valid only when the merge was clean.
  # A conflicted-then-resolved merge proves nothing: the resolution policy
  # chose the outcome, not the content.
  if [[ $rc -eq 0 ]] && git diff --quiet "$before" "$after"; then
    echo "$b" >> "$REPORT.retire"
  fi
  return 0
}

rebuild_integration() {
  # `git checkout -B` below destroys whatever $INTEGRATION currently points at.
  # On --continue that is the operator's hand-resolved merge, which they were
  # told to make and which they have every reason to think is being kept. It is
  # not: --continue skips the mirror sync and the rebases, but still rebuilds
  # from scratch. Their content usually survives because rerere replays the
  # resolution they just recorded -- and when rerere cannot replay it (a rename,
  # a delete/modify, a whole-file ours/theirs) it is simply gone.
  #
  # The rebuild-from-scratch model is not up for negotiation, so instead nothing
  # is destroyed unrecoverably: the old tip is kept under refs/fork/pre-rebuild/
  # before the reset. One ref per run, never deleted, and `git log` finds it.
  if git show-ref --verify --quiet "refs/heads/$INTEGRATION"; then
    local rescue="refs/fork/pre-rebuild/${SYNC_TS:-unknown}"
    if [[ $DRY_RUN -eq 0 ]]; then
      git update-ref "$rescue" "$(git rev-parse "refs/heads/$INTEGRATION")"
      log "previous $INTEGRATION tip saved at $rescue ($(git rev-parse --short "$rescue"))"
    fi
  fi

  log "rebuilding $INTEGRATION from $MIRROR"
  run git checkout -B "$INTEGRATION" "$MIRROR"

  : > "$REPORT.conflicts"
  : > "$REPORT.retire"
  : > "$REPORT.autoresolved"

  local ordered=() b
  ordered+=("$TOOLING")
  mapfile -t -O "${#ordered[@]}" ordered < <(read_manifest "$FORK_DIR/features.txt")
  mapfile -t -O "${#ordered[@]}" ordered < <(read_manifest "$FORK_DIR/pr-branches.txt")

  for b in "${ordered[@]}"; do
    if ! git show-ref --verify --quiet "refs/heads/$b"; then
      fail_add "$b" missing-branch "listed in a manifest but there is no local ref"
      continue
    fi
    if [[ $DRY_RUN -eq 1 ]]; then printf '    [dry-run] integrate %s\n' "$b"; continue; fi
    integrate_branch "$b"
  done
}

# --- step 4: integration patches -------------------------------------------
apply_patches() {
  local p count=0
  shopt -s nullglob
  for p in "$FORK_DIR"/integration-patches/*.patch; do
    log "applying integration patch $(basename "$p")"
    if [[ $DRY_RUN -eq 0 ]]; then
      if ! git am --3way < "$p"; then
        # Leaving .git/rebase-apply behind makes the NEXT run's preflight say
        # "commit or stash first", which is the wrong remedy entirely.
        git am --abort >/dev/null 2>&1 || true
        die "integration patch failed: $p (the am was aborted; the tree is clean)"
      fi
    fi
    count=$((count + 1))
  done
  shopt -u nullglob
  [[ $count -eq 0 ]] && log "no integration patches"
  return 0
}

# --- step 5: gates ----------------------------------------------------------
# `./gradlew test` alone SKIPS konsist (excluded in CI) and Paparazzi
# (a separate task). Running only that would be theatre.
verify() {
  if [[ $SKIP_VERIFY -eq 1 ]]; then
    warn "verification SKIPPED -- push is disabled for this run"
    return 0
  fi

  # Subshells for the same reason as assert_artifacts_fresh below: die is
  # exit 1, which would unwind past rr_cache_export and emit_report and report
  # 1 where the exit-code contract says 4.
  local failed=0 g started assemble_ok=0 first=1
  ( assert_jdk21_with_compiler )      || { warn "JDK 21 check failed";  failed=$((failed + 1)); }
  ( assert_enterprise_uninitialised ) || { warn "enterprise check failed"; failed=$((failed + 1)); }
  [[ $failed -gt 0 ]] && return "$failed"
  # Re-run for effect (the JAVA_HOME export and submodule.recurse) now both pass.
  assert_jdk21_with_compiler
  assert_enterprise_uninitialised

  # A previous release build that was OOM-killed leaves stale APKs behind with
  # no BUILD FAILED line. Clearing the directory first is what makes the mtime
  # assertion below meaningful.
  clean_build_outputs
  started="$(build_start_stamp)"

  local -a gates=(
    ":app:assembleGplayDebug app:assembleFDroidDebug -PallWarningsAsErrors=true"
    ":app:testGplayDebugUnitTest testDebugUnitTest -x :tests:konsist:testDebugUnitTest"
    ":tests:konsist:testDebugUnitTest --rerun"
    ":tests:uitests:verifyPaparazziDebug"
    "detekt ktlintCheck :app:lintGplayDebug --continue"
  )
  for g in "${gates[@]}"; do
    log "gate: ./gradlew $g"
    if [[ $DRY_RUN -eq 1 ]]; then first=0; continue; fi
    # shellcheck disable=SC2086
    if ./gradlew $g --no-configuration-cache; then
      log "  PASS"
      [[ $first -eq 1 ]] && assemble_ok=1
    else
      warn "  FAIL: $g"
      failed=$((failed + 1))
    fi
    first=0
  done

  # Only meaningful if the assemble actually claimed success. A pass with no new
  # APK, or with one older than the build, is the OOM signature.
  # Subshell: assert_artifacts_fresh dies, and die is exit 1, which would unwind
  # the whole script past rr_cache_export and emit_report. A stale artifact is a
  # failed gate, so it must be counted like one and exit 4.
  if [[ $DRY_RUN -eq 0 && $assemble_ok -eq 1 ]]; then
    ( assert_artifacts_fresh "$started" ) || failed=$((failed + 1))
  fi

  return "$failed"
}

# --- report -----------------------------------------------------------------
emit_report() {
  echo
  log "SUMMARY"
  if [[ -s "$REPORT.conflicts" ]]; then
    printf '  CONFLICTS (%s branch(es)):\n' "$(wc -l < "$REPORT.conflicts")"
    while IFS=$'\t' read -r b paths; do
      printf '    %s\n      %s\n' "$b" "${paths//,/$'\n      '}"
    done < "$REPORT.conflicts"
    echo
    echo "  To resolve one by hand:"
    echo "    git checkout $INTEGRATION"
    echo "    git merge --no-ff <branch>        # but see below for fix/* branches"
    echo "    # fix the files, then:"
    echo "    git add <files> && git commit     # this is what records the"
    echo "                                      # resolution into rerere"
    echo "    .fork/sync-upstream.sh --continue"
    echo
    echo "  --continue REBUILDS $INTEGRATION from scratch. It does not keep the"
    echo "  commit you just made; what carries your work across is rerere"
    echo "  replaying the resolution that commit recorded. If rerere cannot"
    echo "  replay it -- a rename, a delete/modify, a whole-file ours/theirs --"
    echo "  the branch simply conflicts again and the run exits 3 without"
    echo "  pushing. Your commit is kept at refs/fork/pre-rebuild/<timestamp>"
    echo "  either way; nothing is thrown away unrecoverably."
    echo
    echo "  For a branch whose base predates $MIRROR -- most fix/* branches --"
    echo "  the run integrates it by CHERRY-PICK, not by merge. Resolving with"
    echo "  'git merge --no-ff' there drags its stale base across everything"
    echo "  already integrated, which is what the cherry-pick path exists to"
    echo "  prevent. Use instead:"
    echo "    git cherry-pick \$(git rev-list --reverse --no-merges $MIRROR..<branch>)"
  else
    echo "  no conflicts"
  fi
  if [[ -s "$REPORT.retire" ]]; then
    echo
    printf '  ADVISORY -- these merged clean but changed nothing (likely absorbed upstream):\n'
    sed 's/^/    /' "$REPORT.retire"
    echo "    (nothing is deleted; review and remove from the manifest by hand if you agree)"
  fi
  if [[ -s "$REPORT.autoresolved" ]]; then
    echo
    printf '  AUTO-RESOLVED -- %s branch(es) conflicted and were resolved with no\n' \
      "$(wc -l < "$REPORT.autoresolved")"
    printf '  human in the loop, by a replayed rerere resolution or by the snapshot\n'
    printf '  policy. git reports these exactly like a clean merge:\n'
    while IFS=$'\t' read -r b paths; do
      printf '    %-46s %s\n' "$b" "$paths"
    done < "$REPORT.autoresolved"
    printf '  Check these first if %s builds but behaves oddly.\n' "$INTEGRATION"
  fi
  if [[ -s "$REPORT.incomplete" ]]; then
    echo
    printf '  INCOMPLETE -- %s branch(es) are not fully represented in %s:\n' \
      "$(incomplete_count)" "$INTEGRATION"
    while IFS=$'\t' read -r b kind detail; do
      printf '    %-46s %-20s %s\n' "$b" "$kind" "$detail"
    done < "$REPORT.incomplete"
    echo
    echo "  The run will NOT push. See .fork/LAST_RUN.md."
  fi
}

# --- main -------------------------------------------------------------------
main() {
  mkdir -p "$FORK_DIR"
  incomplete_reset
  trap 'on_exit $?' EXIT

  preflight

  # Local git policy. All of this must be in place BEFORE the first merge.
  ensure_snapshot_attrs
  assert_snapshot_attrs
  git config rerere.enabled true
  git config rerere.autoUpdate true
  # submodule.recurse is NOT set here. assert_enterprise_uninitialised sets it
  # when unset and refuses when an operator set it to true; setting it first
  # would overwrite the very value the assert exists to catch.
  rr_cache_stage
  rr_cache_import
  audit_rerere_cache
  assert_enterprise_uninitialised

  fetch_remotes

  # Drift and manifest coverage need the fetch to have happened.
  check_pr_drift
  check_unmanaged_branches

  local prev_tip rebuild_sha gate_rc n
  SYNC_TS="$(sync_timestamp)"

  if [[ $CONTINUE -eq 0 ]]; then
    sync_mirror
    rebase_features
    # Captured BEFORE rebuild_integration: `git checkout -B master develop`
    # destroys the old tip, and that tip is what master has to fast-forward from.
    prev_tip="$(capture_prev_integration)"
    printf '%s\n' "$prev_tip" > "$STATE.prev-integration"
  else
    log "--continue: skipping mirror sync and rebases"
    prev_tip="$(cat "$STATE.prev-integration" 2>/dev/null || true)"
  fi
  # The graft exists so the REMOTE fast-forwards, so the remote's tip is the
  # authoritative parent. On a fresh run the locally captured value is the same
  # thing, but on --continue it is the tip from before the PREVIOUS run's
  # rebuild: if master was published in between, the graft would parent a stale
  # commit. publish_ff catches that and dies -- but only after
  # graft_integration has already rewritten refs/heads/master.
  if git show-ref --verify --quiet "refs/remotes/origin/$INTEGRATION"; then
    prev_tip="$(git rev-parse "refs/remotes/origin/$INTEGRATION")"
  fi

  rebuild_integration
  apply_patches
  # The pre-graft tip. Captured here rather than after verify(): nothing in the
  # gates moves HEAD today, but this value's whole job is to be the tree the
  # graft publishes, and here it provably is.
  rebuild_sha="$(git rev-parse HEAD)"

  gate_rc=0
  verify || gate_rc=$?

  rr_cache_export
  emit_report

  n="$(incomplete_count)"
  if [[ "$n" -gt 0 ]]; then
    warn "$n branch(es) did not make it into $INTEGRATION."
    warn "Refusing to publish a $INTEGRATION that is missing a branch's work."
    finish "$EXIT_INCOMPLETE"
  fi
  if [[ $gate_rc -ne 0 ]]; then
    warn "$gate_rc gate(s) failed -- not pushing"
    finish "$EXIT_GATE"
  fi

  # Everything that would refuse the push has to refuse BEFORE
  # graft_integration rewrites refs/heads/master and tag_sync mints a rollback
  # point. A --skip-verify run used to graft and tag an unverified build and
  # only then say "refusing to push", leaving sync/<ts> -- the documented
  # rollback target -- owned by a build no gate ever saw.
  # Precedence matches the publish() this replaced: --no-push/--dry-run is a
  # deliberate rehearsal and succeeds, --skip-verify is a refusal. What changed
  # is only that BOTH now decide before graft_integration rewrites
  # refs/heads/master. Exit 0 still means "pushed", so neither path can claim it
  # while grafting or tagging: a rehearsal that mutated master would not be one.
  if [[ $NO_PUSH -eq 1 || $DRY_RUN -eq 1 ]]; then
    log "publish skipped (--no-push/--dry-run); nothing grafted, nothing tagged"
    finish 0
  fi
  if [[ $SKIP_VERIFY -eq 1 ]]; then
    die "refusing to publish: verification was skipped"
  fi
  if git rev-parse --verify --quiet "refs/tags/sync/$SYNC_TS" >/dev/null 2>&1; then
    die "tag sync/$SYNC_TS already exists. Nothing has been grafted or pushed; wait a minute and re-run rather than overwrite a rollback point."
  fi

  graft_integration "$prev_tip" "$SYNC_TS"
  tag_sync "$SYNC_TS"
  publish_ff "$SYNC_TS"

  if [[ "$(git symbolic-ref -q --short HEAD || true)" == "$MIRROR" ]]; then
    warn "HEAD ended on $MIRROR; moving off so nothing can commit to the mirror"
    git checkout --quiet "$INTEGRATION" 2>/dev/null || true
  fi
  log "done (rebuild $(git rev-parse --short "$rebuild_sha"), published as $(git rev-parse --short "$INTEGRATION"))"
  finish 0
}

main "$@"
