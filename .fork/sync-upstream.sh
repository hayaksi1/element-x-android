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

DRY_RUN=0; NO_PUSH=0; CONTINUE=0; SKIP_VERIFY=0; ONLY_FEATURES=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)      DRY_RUN=1 ;;
    --no-push)      NO_PUSH=1 ;;
    --continue)     CONTINUE=1 ;;
    --skip-verify)  SKIP_VERIFY=1 ;;
    --features=*)   ONLY_FEATURES="${arg#--features=}" ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
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

# --- snapshot merge policy --------------------------------------------------
# .gitattributes declares merge=lfs, but no such driver exists at any scope, so
# git falls back to a TEXT merge of the LFS pointer. `git add` then re-encodes
# the conflict markers into a structurally valid pointer whose payload is text.
# git lfs fsck passes; nothing notices until a PNG fails to decode.
# One line in .git/info/attributes (never the committed .gitattributes) makes
# these conflict as binary instead: no markers, no corruptible object, and
# rerere skips them automatically.
ensure_snapshot_attrs() {
  local f
  f="$(git rev-parse --git-common-dir)/info/attributes"
  mkdir -p "$(dirname "$f")"
  if ! grep -qs 'snapshots/\*\*/\*\.png' "$f" 2>/dev/null; then
    log "installing snapshot merge policy into .git/info/attributes"
    run bash -c "printf '%s\n' '**/snapshots/**/*.png merge=binary' 'screenshots/**/*.png merge=binary' >> '$f'"
  fi
}

# Resolve snapshot conflicts deterministically. Branches on the status code:
# DU (deleted on our side) needs `git rm`; checkout --ours errors there.
resolve_snapshot_conflicts() {
  local resolved=0 line code path
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    code="${line:0:2}"; path="${line:3}"
    case "$path" in
      *snapshots/*.png|screenshots/*.png) ;;
      *) continue ;;
    esac
    case "$code" in
      DU) run git rm -q --  "$path" ;;
      *)  run git checkout --ours -- "$path"; run git add -- "$path" ;;
    esac
    resolved=$((resolved + 1))
  done < <(git status --porcelain | grep -E '^(UU|AA|UD|DU|DD) ' || true)
  [[ $resolved -gt 0 ]] && log "auto-resolved $resolved snapshot path(s); these need re-recording"
  echo "$resolved"
}

# --- step 1: fast-forward the mirror ---------------------------------------
sync_mirror() {
  log "fetching upstream"
  run git fetch upstream --prune --tags
  run git fetch origin --prune

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
      warn "rebase conflict on $b -- left unrebased, will merge as-is"
      echo "$b" >> "$REPORT.rebase-failed"
    fi
  done
  git checkout --quiet - 2>/dev/null || true
}

# --- step 3: rebuild the integration branch --------------------------------
rebuild_integration() {
  log "rebuilding $INTEGRATION from $MIRROR"
  run git checkout -B "$INTEGRATION" "$MIRROR"

  : > "$REPORT.conflicts"
  : > "$REPORT.retire"

  local ordered=() b before after rc n mode
  ordered+=("$TOOLING")
  mapfile -t -O "${#ordered[@]}" ordered < <(read_manifest "$FORK_DIR/features.txt")
  mapfile -t -O "${#ordered[@]}" ordered < <(read_manifest "$FORK_DIR/pr-branches.txt")

  local prset
  prset=" $(read_manifest "$FORK_DIR/pr-branches.txt" | tr '\n' ' ') "

  for b in "${ordered[@]}"; do
    git show-ref --verify --quiet "refs/heads/$b" || { warn "missing branch, skipping: $b"; continue; }
    if [[ $DRY_RUN -eq 1 ]]; then printf '    [dry-run] integrate %s\n' "$b"; continue; fi

    before="$(git rev-parse HEAD)"
    rc=0

    # A branch whose base predates the mirror cannot be MERGED: the merge would
    # drag its stale base across everything already integrated and conflict in
    # files the branch never touched. PR branches must not be rebased (upstream
    # maintainers push onto them), so integrate their unique commits by
    # cherry-pick instead -- that touches only the integration branch.
    if [[ "$prset" == *" $b "* ]] && ! git merge-base --is-ancestor "$MIRROR" "$b"; then
      mode="cherry-pick"
      local picks
      picks="$(git rev-list --reverse --no-merges "$MIRROR..$b")"
      if [[ -z "$picks" ]]; then
        log "nothing unique to pick: $b"
        continue
      fi
      # shellcheck disable=SC2086
      git cherry-pick --keep-redundant-commits $picks >/dev/null 2>&1 || rc=$?
    else
      mode="merge"
      git merge --no-ff --no-edit "$b" >/dev/null 2>&1 || rc=$?
    fi

    if [[ $rc -ne 0 ]]; then
      n="$(resolve_snapshot_conflicts)"
      # Anything still conflicted is real code. Never auto-resolve it.
      if git status --porcelain | grep -qE '^(UU|AA|UD|DU|DD) '; then
        {
          printf '%s\t%s\n' "$b" "$(git status --porcelain \
            | grep -E '^(UU|AA|UD|DU|DD) ' | awk '{print $2}' | paste -sd, -)"
        } >> "$REPORT.conflicts"
        warn "CONFLICT integrating $b ($mode)"
        if [[ "$mode" == "cherry-pick" ]]; then
          git cherry-pick --abort 2>/dev/null || true
        else
          git merge --abort 2>/dev/null || true
        fi
        continue
      fi
      if [[ "$mode" == "cherry-pick" ]]; then
        git -c core.editor=true cherry-pick --continue >/dev/null 2>&1 || true
      else
        git commit --no-edit >/dev/null 2>&1 || true
      fi
    fi

    after="$(git rev-parse HEAD)"
    # Retirement is ADVISORY ONLY and valid only when the merge was clean.
    # A conflicted-then-resolved merge proves nothing: the resolution policy
    # chose the outcome, not the content.
    if [[ $rc -eq 0 ]] && git diff --quiet "$before" "$after"; then
      echo "$b" >> "$REPORT.retire"
    fi
  done
}

# --- step 4: integration patches -------------------------------------------
apply_patches() {
  local p count=0
  shopt -s nullglob
  for p in "$FORK_DIR"/integration-patches/*.patch; do
    log "applying integration patch $(basename "$p")"
    if [[ $DRY_RUN -eq 0 ]]; then
      git am --3way < "$p" || die "integration patch failed: $p"
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
  local failed=0
  local -a gates=(
    ":app:assembleGplayDebug app:assembleFDroidDebug -PallWarningsAsErrors=true"
    ":app:testGplayDebugUnitTest testDebugUnitTest -x :tests:konsist:testDebugUnitTest"
    ":tests:konsist:testDebugUnitTest --rerun"
    ":tests:uitests:verifyPaparazziDebug"
    "detekt ktlintCheck :app:lintGplayDebug --continue"
  )
  local g
  for g in "${gates[@]}"; do
    log "gate: ./gradlew $g"
    if [[ $DRY_RUN -eq 1 ]]; then continue; fi
    # shellcheck disable=SC2086
    if ./gradlew $g --no-configuration-cache; then
      log "  PASS"
    else
      warn "  FAIL: $g"
      failed=$((failed + 1))
    fi
  done
  return "$failed"
}

# --- step 6: push -----------------------------------------------------------
publish() {
  if [[ $NO_PUSH -eq 1 || $DRY_RUN -eq 1 ]]; then log "push skipped"; return 0; fi
  if [[ $SKIP_VERIFY -eq 1 ]]; then die "refusing to push: verification was skipped"; fi
  log "pushing $MIRROR and $INTEGRATION"
  git push --force-with-lease origin "$MIRROR:$MIRROR"
  git push --force-with-lease origin "$INTEGRATION:$INTEGRATION"
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
    echo "    git merge --no-ff <branch>"
    echo "    # fix the files, then:"
    echo "    git add <files> && git commit"
    echo "    # then re-run: .fork/sync-upstream.sh --continue"
  else
    echo "  no conflicts"
  fi
  if [[ -s "$REPORT.retire" ]]; then
    echo
    printf '  ADVISORY -- these merged clean but changed nothing (likely absorbed upstream):\n'
    sed 's/^/    /' "$REPORT.retire"
    echo "    (nothing is deleted; review and remove from the manifest by hand if you agree)"
  fi
}

# --- main -------------------------------------------------------------------
main() {
  mkdir -p "$FORK_DIR"
  preflight
  ensure_snapshot_attrs
  git config rerere.enabled true
  git config rerere.autoUpdate true
  git config submodule.recurse false

  if [[ $CONTINUE -eq 0 ]]; then
    sync_mirror
    rebase_features
  else
    log "--continue: skipping mirror sync and rebases"
  fi

  rebuild_integration
  apply_patches

  local gate_rc=0
  verify || gate_rc=$?

  emit_report

  if [[ -s "$REPORT.conflicts" ]]; then
    warn "conflicts present -- not pushing"
    exit 0   # conflicts are the expected output, not a job failure
  fi
  if [[ $gate_rc -ne 0 ]]; then
    die "$gate_rc gate(s) failed -- not pushing"
  fi
  publish
  log "done"
}

main "$@"
