# shellcheck shell=bash
# .fork/lib/publish.sh -- make a bad sync rollback-able.
#
# Sourced by .fork/sync-upstream.sh. Functions only: no top-level side effects,
# no `exit`, no `set` changes. Runs under `set -euo pipefail`.
#
# The defect this closes: `master` was force-pushed on every run, so the only
# recorded fallback was `backup/develop-*` -- a PRE-CUTOVER snapshot of the old
# `develop` that contains none of the integrated branches. Restoring it would
# destroy the app.
#
# The fix has two halves:
#   1. the from-scratch rebuild is GRAFTED onto the previous `master` tip, so
#      `master` only ever fast-forwards and a plain `git push` (no --force,
#      no lease) is enough. Nothing on the remote is ever overwritten.
#   2. every successful publish is tagged `sync/<YYYYMMDD-HHMM>`, so the
#      previous known-good build is a named, immutable ref. THAT is the
#      rollback point.
#
# Reads: MIRROR INTEGRATION UPSTREAM_REF DRY_RUN NO_PUSH SKIP_VERIFY
# Calls: log warn die run  (sync-upstream.sh) / assert_push_list (integrity.sh)

# echo YYYYMMDD-HHMM in UTC. Call ONCE per run and pass the value around, so the
# tag name and the graft commit message cannot disagree across a midnight tick.
sync_timestamp() {
  date -u +%Y%m%d-%H%M
}

# echo the current refs/heads/$INTEGRATION sha, or nothing if it does not exist.
# MUST run before rebuild_integration's `git checkout -B "$INTEGRATION" "$MIRROR"`
# destroys the old tip.
capture_prev_integration() {
  git rev-parse --verify --quiet "refs/heads/$INTEGRATION^{commit}" 2>/dev/null || true
}

# graft_integration <prev_sha> <sync_ts>
#
# Precondition: HEAD is the finished from-scratch rebuild and
# refs/heads/$INTEGRATION already points at it.
#
# Produces a commit whose TREE is byte-identical to the rebuild and whose FIRST
# parent is <prev_sha>, so the remote branch fast-forwards. Second parent is the
# rebuild itself, so the rebuilt history stays reachable and `git log master`
# still shows it.
graft_integration() {
  local prev="${1:-}" ts="${2:-}"
  local rebuild tree new mirror_short head_ref

  [[ -n "$ts" ]] || die "graft_integration: missing sync timestamp"

  if [[ -z "$prev" ]]; then
    log "no previous $INTEGRATION tip (first-ever run) -- nothing to graft"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    [dry-run] graft %s onto previous tip %s\n' "$INTEGRATION" "$prev"
    return 0
  fi

  git rev-parse --verify --quiet "$prev^{commit}" >/dev/null 2>&1 ||
    die "graft_integration: not a commit: $prev"

  head_ref="$(git rev-parse --verify --quiet "refs/heads/$INTEGRATION" 2>/dev/null || true)"
  [[ -n "$head_ref" ]] ||
    die "graft_integration: refs/heads/$INTEGRATION does not exist"

  rebuild="$(git rev-parse HEAD)"
  [[ "$head_ref" == "$rebuild" ]] ||
    die "graft_integration: refs/heads/$INTEGRATION ($head_ref) is not at HEAD ($rebuild); graft must run immediately after the rebuild"

  if git merge-base --is-ancestor "$prev" "$rebuild"; then
    log "previous $INTEGRATION tip $(git rev-parse --short "$prev") is already an ancestor -- no graft needed"
    return 0
  fi

  tree="$(git rev-parse "HEAD^{tree}")"
  mirror_short="$(git rev-parse --short "$MIRROR" 2>/dev/null || echo unknown)"
  new="$(git commit-tree "$tree" -p "$prev" -p "$rebuild" \
           -m "sync: rebuild $ts (develop $mirror_short)")"

  # Compare-and-swap: refuse if anything moved the branch since we read it.
  git update-ref "refs/heads/$INTEGRATION" "$new" "$rebuild" ||
    die "graft_integration: $INTEGRATION moved under us; refusing to graft"

  # The whole point of the graft is that it changes NOTHING about the content.
  # If that is not true the commit-tree call was wrong and the run must stop.
  if ! git diff --quiet "$rebuild" "refs/heads/$INTEGRATION"; then
    git update-ref "refs/heads/$INTEGRATION" "$rebuild" "$new" || true
    die "graft changed the tree ($rebuild vs $new) -- reverted, refusing to continue"
  fi

  log "grafted $INTEGRATION -> $(git rev-parse --short "$new"): tree of $(git rev-parse --short "$rebuild"), first parent $(git rev-parse --short "$prev")"
}

# tag_sync <sync_ts>
# Annotated tag sync/<ts> on refs/heads/$INTEGRATION. This is the rollback point.
# Never overwrites an existing tag: overwriting one would delete the very thing
# it exists to preserve.
tag_sync() {
  local ts="${1:-}" tag
  [[ -n "$ts" ]] || die "tag_sync: missing sync timestamp"
  tag="sync/$ts"

  if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null 2>&1; then
    # Identical target: this is a re-run after a push failed partway, which is
    # the ordinary recovery path. Anything else would be overwriting a rollback
    # point, which is never allowed.
    if [[ "$(git rev-parse "refs/tags/$tag^{commit}")" == "$(git rev-parse "refs/heads/$INTEGRATION")" ]]; then
      log "tag $tag already present at the same commit -- leaving it alone"
      return 0
    fi
    die "tag $tag already exists at $(git rev-parse --short "refs/tags/$tag") -- refusing to overwrite a rollback point"
  fi

  log "tagging $tag at $INTEGRATION"
  run git tag -a "$tag" -m "fork sync $ts: $INTEGRATION rebuilt from $MIRROR" "refs/heads/$INTEGRATION"
}

# assert_mirror_pristine
# The mirror is a byte-exact copy of upstream. Nothing of the fork's may ever
# land on it, because a single fork commit breaks every future fast-forward.
#
# sync_mirror enforces that -- but sync_mirror is CALLED only when CONTINUE is 0,
# and publish_ff below pushes refs/heads/$MIRROR on every path into it. A
# --continue run therefore published the mirror having checked nothing at all:
# whatever was on local develop went straight to origin, silently, exit 0.
#
# So the check lives HERE, as a precondition of the push, rather than as a step
# that happens to run first on one of two paths. A guard that protects a push has
# to be reachable from the push, not from one of its callers.
#
# It DIES rather than skipping just the mirror push: $INTEGRATION was rebuilt
# from this mirror, so a poisoned mirror means the whole run is built on fork
# commits that upstream has never seen. There is nothing here worth publishing.
assert_mirror_pristine() {
  local up="${UPSTREAM_REF:-}"

  # Unprovable is not the same as fine. Without a resolvable upstream ref there
  # is no way to show the mirror is clean, and "cannot tell" must not push.
  [[ -n "$up" ]] ||
    die "assert_mirror_pristine: UPSTREAM_REF is unset -- cannot prove $MIRROR is pristine, refusing to push it"
  git rev-parse --verify --quiet "$up^{commit}" >/dev/null 2>&1 ||
    die "assert_mirror_pristine: $up does not resolve -- cannot prove $MIRROR is pristine, refusing to push it"
  git rev-parse --verify --quiet "refs/heads/$MIRROR^{commit}" >/dev/null 2>&1 ||
    die "assert_mirror_pristine: refs/heads/$MIRROR does not exist"

  # Ancestor, not equality: --continue skips sync_mirror, so the mirror may
  # legitimately be BEHIND upstream. Behind is stale, which is harmless. AHEAD is
  # a fork commit on the mirror, which is the thing that must never be published.
  if git merge-base --is-ancestor "refs/heads/$MIRROR" "$up"; then return 0; fi

  warn "$MIRROR is NOT an ancestor of $up. Commits the mirror has and $up does not:"
  git log --oneline "$up..refs/heads/$MIRROR" >&2 || true
  die "refusing to push: $MIRROR carries fork commit(s). The mirror must stay a byte-exact copy of $up, and $INTEGRATION was rebuilt from it, so nothing in this run is publishable. Move that work to a feat/* branch and reset $MIRROR to $up."
}

# publish_ff <sync_ts>
# Replacement for publish(). Pushes develop, master and the sync tag with NO
# force of any kind: after graft_integration the master push is a genuine
# fast-forward, and a plain push fails loudly if that assumption ever breaks --
# which is exactly the signal --force-with-lease would have swallowed.
publish_ff() {
  local ts="${1:-}" tag tip origin_tip
  [[ -n "$ts" ]] || die "publish_ff: missing sync timestamp"
  tag="sync/$ts"

  if [[ $DRY_RUN -eq 1 ]]; then log "push skipped (--dry-run)"; return 0; fi

  tip="$(git rev-parse --verify "refs/heads/$INTEGRATION")"
  origin_tip="$(git rev-parse --verify --quiet "refs/remotes/origin/$INTEGRATION" 2>/dev/null || true)"

  if [[ -n "$origin_tip" ]]; then
    if ! git merge-base --is-ancestor "$origin_tip" "$tip"; then
      warn "origin/$INTEGRATION = $(git rev-parse --short "$origin_tip")"
      warn "local  $INTEGRATION = $(git rev-parse --short "$tip")"
      die "origin/$INTEGRATION is NOT an ancestor of the new tip -- the graft parented a stale tip, or someone pushed. Fetch and investigate; do NOT force."
    fi
  else
    warn "no refs/remotes/origin/$INTEGRATION -- cannot pre-verify the fast-forward; the push itself will"
  fi

  declare -F assert_push_list >/dev/null 2>&1 ||
    die "assert_push_list is not defined -- .fork/lib/integrity.sh was not sourced"
  assert_push_list "$MIRROR" "$INTEGRATION" "$tag"

  # Before the NO_PUSH return, exactly like assert_push_list above it, so
  # "refs verified" is never printed over a poisoned mirror. main() also asserts
  # this much earlier, before the rebuild and the graft; this call is the
  # tripwire that cannot be bypassed, since every path to the pushes below goes
  # through it.
  assert_mirror_pristine

  if [[ $NO_PUSH -eq 1 ]]; then log "push skipped (--no-push); refs verified"; return 0; fi
  if [[ $SKIP_VERIFY -eq 1 ]]; then die "refusing to push: verification was skipped"; fi

  log "pushing $MIRROR, $INTEGRATION (fast-forward) and $tag"
  run git push origin "refs/heads/$MIRROR:refs/heads/$MIRROR"
  run git push origin "refs/heads/$INTEGRATION:refs/heads/$INTEGRATION"
  run git push origin "refs/tags/$tag:refs/tags/$tag"
}
