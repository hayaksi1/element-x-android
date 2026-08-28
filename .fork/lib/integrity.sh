#!/usr/bin/env bash
# .fork/lib/integrity.sh -- SOURCED by sync-upstream.sh. Functions only.
#
# Owns the shared failure list. A non-empty list means the run is INCOMPLETE:
# the build and the gates still run, but nothing is pushed and the script exits 3.
#
# The list lives at $REPORT.incomplete as TSV:  branch <TAB> kind <TAB> detail

# The kind vocabulary is fixed by the contract. Anything else is a wiring bug.
_fork_kinds() {
  printf '%s\n' \
    rebase-failed stale-base merge-conflict missing-branch \
    pr-drift-behind pr-drift-ahead pr-drift-diverged pr-no-remote \
    unmanaged-branch empty-after-resolve integrate-failed merge-only-content
}

_fork_kind_advice() {
  case "$1" in
    rebase-failed)
      echo "Rebase it onto $MIRROR by hand, resolve, then re-run with --continue." ;;
    stale-base)
      echo "Its base predates $MIRROR: rebase (feat/*) or cherry-pick (fix/*) onto the mirror, then re-run." ;;
    merge-conflict)
      echo "Resolve on $INTEGRATION by hand, commit, then re-run with --continue. Use git merge --no-ff <branch> ONLY if $MIRROR is already an ancestor of it; for a branch whose base predates the mirror -- most fix/* -- use git cherry-pick \$(git rev-list --reverse --no-merges $MIRROR..<branch>), because merging drags its stale base across everything already integrated. --continue REBUILDS $INTEGRATION: what carries your work across is rerere replaying the resolution your commit records, and the old tip is kept at refs/fork/pre-rebuild/<ts> either way." ;;
    missing-branch)
      echo "Fetch or recreate the branch, or remove it from the manifest." ;;
    empty-after-resolve)
      echo "Every conflicted path was binary, so resolution kept ours and the branch added nothing. Re-record the snapshots on that branch, then re-run." ;;
    integrate-failed)
      echo "The cherry-pick or merge could not be concluded. Reproduce it by hand on $INTEGRATION and see what git says." ;;
    merge-only-content)
      echo "A merge on that branch carries content that is in NEITHER of its parents -- a conflict resolution. Its base predates $MIRROR, so it is integrated by CHERRY-PICK, and the pick list is --no-merges: that content is in no non-merge commit and cannot be replayed, so it would be silently missing from $INTEGRATION. For a branch in features.txt, rebase it onto $MIRROR -- a plain rebase flattens the merge and replays its unique content -- then re-run. For a branch in pr-branches.txt, which may NEVER be rebased, export the merge's own content (git show --cc <sha> names the files) as an integration patch under .fork/integration-patches/ and commit it to $TOOLING." ;;
    pr-drift-behind)
      echo "A maintainer pushed to the PR: fast-forward the local ref from origin. Never rebase a fix/* branch." ;;
    pr-drift-ahead)
      echo "Local-only commits on a PR branch: push them to origin or drop them. Never force-push over a maintainer." ;;
    pr-drift-diverged)
      echo "Local and origin both moved: reconcile by hand. Never force-push a PR branch." ;;
    pr-no-remote)
      echo "Not on origin: push the branch, or remove it from pr-branches.txt." ;;
    unmanaged-branch)
      echo "Add it to a manifest to integrate it, or to .fork/unmanaged-branches.txt to acknowledge it is deliberate." ;;
    *)
      echo "Unknown kind." ;;
  esac
}

# --- the list ---------------------------------------------------------------

# Truncate the failure list. Also truncates the legacy rebase-failed file, which
# was written but never read and so accumulated across every run ever made.
incomplete_reset() {
  mkdir -p "$(dirname "$REPORT.incomplete")"
  : > "$REPORT.incomplete"
  : > "$REPORT.rebase-failed"
}

# fail_add <branch> <kind> <detail>
fail_add() {
  local branch="$1" kind="$2" detail="${3:-}"

  _fork_kinds | grep -qx -- "$kind" ||
    die "fail_add: unknown kind '$kind' for '$branch' (wiring bug)"

  # One row must stay one line: TSV is parsed with IFS=$'\t' read -r.
  detail="${detail//$'\t'/ }"
  detail="${detail//$'\r'/ }"
  detail="${detail//$'\n'/ }"

  mkdir -p "$(dirname "$REPORT.incomplete")"
  printf '%s\t%s\t%s\n' "$branch" "$kind" "$detail" >> "$REPORT.incomplete"
  warn "INCOMPLETE [$kind] $branch: $detail"
}

# assert_patch_landed <patch> <head_before_am>
# `git am` on a patch with no commit in it -- what `git format-patch -1` emits
# for a MERGE commit -- exits 0 having done nothing.
assert_patch_landed() {
  local p="$1" before="$2"
  if [[ "$(git rev-parse HEAD)" == "$before" ]]; then
    die "integration patch applied nothing: $p -- git am exited 0 without creating a commit, so the fix it carries is NOT in $INTEGRATION and every rebuild drops it silently. Re-export it from a normal commit; format-patch on a merge (a refs/fork/pre-rebuild/<ts> tip) produces an empty patch."
  fi
}

incomplete_count() {
  if [[ -f "$REPORT.incomplete" ]]; then
    grep -c '' -- "$REPORT.incomplete" || true
  else
    echo 0
  fi
}

# --- guards -----------------------------------------------------------------

# element-hq maintainers push straight onto the heads of open PRs. A local ref
# that has drifted from origin means the run would integrate the wrong code --
# and we may never rebase or force-push these, so this is always a report.
check_pr_drift() {
  local b counts left right
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    git show-ref --verify --quiet "refs/heads/$b" || continue

    if ! git show-ref --verify --quiet "refs/remotes/origin/$b"; then
      fail_add "$b" pr-no-remote "listed in pr-branches.txt but origin/$b does not exist"
      continue
    fi

    counts="$(git rev-list --left-right --count "refs/heads/$b...refs/remotes/origin/$b")"
    left="${counts%%[[:space:]]*}"
    right="${counts##*[[:space:]]}"
    [[ -z "$left" ]] && left=0
    [[ -z "$right" ]] && right=0

    if [[ "$left" -gt 0 && "$right" -gt 0 ]]; then
      fail_add "$b" pr-drift-diverged \
        "local and origin have both moved: local is ahead by $left commit(s) and behind by $right commit(s)"
    elif [[ "$right" -gt 0 ]]; then
      fail_add "$b" pr-drift-behind \
        "local is behind origin/$b by $right commit(s) -- a maintainer pushed to the PR"
    elif [[ "$left" -gt 0 ]]; then
      fail_add "$b" pr-drift-ahead \
        "local is ahead of origin/$b by $left commit(s) -- local cruft that origin has never seen"
    fi
  done < <(read_manifest "$FORK_DIR/pr-branches.txt")
}

# A branch on origin that is in neither manifest is silently never integrated.
# Most of them are deliberate, so this is an allowlist-driven report.
check_unmanaged_branches() {
  local managed allow b short
  managed=" $(read_manifest "$FORK_DIR/features.txt" | tr '\n' ' ') $(read_manifest "$FORK_DIR/pr-branches.txt" | tr '\n' ' ') "

  allow=" "
  if [[ -f "$FORK_DIR/unmanaged-branches.txt" ]]; then
    allow=" $(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$FORK_DIR/unmanaged-branches.txt" | grep -v '^$' | tr '\n' ' ' || true) "
  fi

  while IFS= read -r short; do
    b="${short#origin/}"
    [[ -z "$b" || "$b" == "HEAD" || "$b" == "$short" ]] && continue
    [[ "$b" == "$MIRROR" || "$b" == "$INTEGRATION" || "$b" == "$TOOLING" ]] && continue
    [[ "$managed" == *" $b "* ]] && continue
    [[ "$allow" == *" $b "* ]] && continue
    fail_add "$b" unmanaged-branch \
      "origin/$b is in neither manifest and not in .fork/unmanaged-branches.txt -- its work is not in $INTEGRATION"
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin)
}

# check_merge_only_content <base> <branch>
#
# The cherry-pick path in integrate_branch builds its pick list with
# `git rev-list --reverse --no-merges`, so no merge commit in the range is ever
# replayed. For an ordinary merge that is correct: its content lives in its
# parents, and the parents' own commits ARE in the pick list. It is wrong for a
# merge that carries content of its OWN. A conflict resolution exists in neither
# parent, so it appears in no non-merge commit, so that pick list provably cannot
# reproduce it. The branch was integrated, nothing was recorded, every gate
# passed, and $INTEGRATION was published with the resolution missing.
#
# `git diff-tree --cc` prints exactly that content and nothing else -- it drops
# any file whose result matches a parent -- so non-empty output IS the proof of
# loss. --name-only keeps it cheap: the whole 75-branch manifest sweeps in under
# half a second.
#
# Checked HERE, at the loss site, and not where the stale base comes from,
# because a branch reaches the cherry-pick path by more than one route: a rebase
# that failed on an earlier run (--continue truncates the ledger, so that row is
# gone and never regenerated), a branch that --features left unselected, and
# every pr-branches.txt branch, which rebase_features never touches at all. The
# loss site is the only thing all of them have in common.
#
# Returns 1 when it recorded a failure, so the caller can skip the branch. The
# run is then INCOMPLETE and will not push -- a warning it continued past would
# publish the same broken $INTEGRATION, just noisily.
check_merge_only_content() {
  local base="$1" b="$2" m names carriers=""

  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    names="$(git diff-tree --cc --no-commit-id --name-only -r "$m" 2>/dev/null || true)"
    [[ -n "$names" ]] || continue
    carriers+="${carriers:+; }$(git rev-parse --short "$m") ($(printf '%s' "$names" | paste -sd, -))"
  done < <(git rev-list --merges "$base..$b" 2>/dev/null || true)

  [[ -n "$carriers" ]] || return 0

  fail_add "$b" merge-only-content \
    "its base predates $base so it is integrated by cherry-pick, which is --no-merges, but these merge(s) carry content present in neither parent -- it is in no non-merge commit and cannot be replayed: $carriers"
  return 1
}

# Tripwire. Only develop and master may ever be pushed. A future edit that adds
# a branch to the push list -- above all a fix/* one -- dies here instead of
# force-pushing over an upstream maintainer's commits.
assert_push_list() {
  local spec ref part feats prs
  feats=" $(read_manifest "$FORK_DIR/features.txt" | tr '\n' ' ') "
  prs=" $(read_manifest "$FORK_DIR/pr-branches.txt" | tr '\n' ' ') "

  for spec in "$@"; do
    spec="${spec#+}"
    # Accept both "master" and a "src:dst" refspec; check every side.
    for part in ${spec//:/ }; do
      ref="${part#refs/heads/}"
      ref="${ref#refs/tags/}"
      [[ -z "$ref" ]] && continue
      # publish_ff pushes the rollback tag alongside the two branches. Only the
      # sync/<YYYYMMDD-HHMM> shape, so an arbitrary tag still cannot slip in.
      if [[ "$ref" =~ ^sync/[0-9]{8}-[0-9]{4}$ ]]; then continue; fi
      case "$ref" in
        fix/*|feature/*|search/*)
          die "assert_push_list: refusing to push '$ref' -- fix/*, feature/* and search/* are never pushed by this script" ;;
      esac
      if [[ "$feats" == *" $ref "* ]]; then
        die "assert_push_list: refusing to push '$ref' -- it is listed in features.txt"
      fi
      if [[ "$prs" == *" $ref "* ]]; then
        die "assert_push_list: refusing to push '$ref' -- it is the head of an open upstream PR"
      fi
      if [[ "$ref" != "$MIRROR" && "$ref" != "$INTEGRATION" ]]; then
        die "assert_push_list: refusing to push '$ref' -- only $MIRROR, $INTEGRATION and a sync/<ts> tag may be pushed"
      fi
    done
  done
}

# --- LAST_RUN.md ------------------------------------------------------------

# Rows of one kind, as markdown list items. Prints nothing when there are none.
_fork_rows_of_kind() {
  local want="$1"
  [[ -f "$REPORT.incomplete" ]] || return 0
  local b k d
  while IFS=$'\t' read -r b k d; do
    [[ "$k" == "$want" ]] || continue
    printf -- '- `%s` — %s\n' "$b" "$d"
  done < "$REPORT.incomplete"
}

_fork_kinds_present() {
  [[ -f "$REPORT.incomplete" ]] || return 0
  local kind
  while IFS= read -r kind; do
    if cut -f2 -- "$REPORT.incomplete" | grep -qx -- "$kind"; then
      printf '%s\n' "$kind"
    fi
  done < <(_fork_kinds)
}

# The failure table on its own, for a GitHub issue body.
last_run_issue_body() {
  local n kind
  n="$(incomplete_count)"
  if [[ "$n" -eq 0 ]]; then
    echo "No integration failures: every managed branch reached \`$INTEGRATION\`."
    return 0
  fi
  printf '%s outstanding integration failure(s):\n' "$n"
  while IFS= read -r kind; do
    printf '\n**%s** — %s\n\n' "$kind" "$(_fork_kind_advice "$kind")"
    _fork_rows_of_kind "$kind"
  done < <(_fork_kinds_present)
}

# write_last_run <exit_code> <upstream_sha> <mirror_sha> <integration_sha>
# Written on EVERY path, including the clean one: a complete run leaves a file
# that says so, so "no file" and "nothing went wrong" can never be confused.
write_last_run() {
  local rc="$1" up_sha="$2" mirror_sha="$3" integ_sha="$4"
  local n kind
  n="$(incomplete_count)"

  mkdir -p "$FORK_DIR"
  {
    echo "# Fork sync — last run"
    echo
    echo "| field | value |"
    echo "| :--- | :--- |"
    printf '| finished | %s |\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
    printf '| exit code | %s |\n' "$rc"
    printf '| %s | `%s` |\n' "$UPSTREAM_REF" "$up_sha"
    printf '| %s | `%s` |\n' "$MIRROR" "$mirror_sha"
    printf '| %s | `%s` |\n' "$INTEGRATION" "$integ_sha"
    echo
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      echo "**Result:** DRY RUN — nothing was integrated, nothing was pushed."
      echo
      echo "The branch loop only printed what it would do. This file describes a"
      echo "rehearsal, not a build."
    elif [[ "$rc" -ne 0 && "$rc" -ne 3 && "$rc" -ne 4 ]]; then
      printf '**Result:** FAILED — the run stopped with exit %s.\n' "$rc"
      echo
      if [[ "${INTEGRATION_LOOP_DONE:-0}" -eq 1 ]]; then
        printf 'The integration loop reached the end of both manifests, so the %s row(s)\n' "$n"
        echo "below are the complete picture; a later stage died. Read the run's own"
        echo "output for the error that stopped it."
      else
        printf 'It recorded %s failure row(s) before it died, so this is NOT a clean\n' "$n"
        echo "refusal: the integration loop did not finish and the rows below are"
        echo "truncated. Read the run's own output for the error that stopped it."
      fi
      echo
      while IFS= read -r kind; do
        printf '## %s\n\n' "$kind"
        _fork_rows_of_kind "$kind"
        printf '\n**What to do:** %s\n\n' "$(_fork_kind_advice "$kind")"
      done < <(_fork_kinds_present)
    elif [[ "$n" -eq 0 ]]; then
      echo "**Result:** complete — every managed branch was integrated into \`$INTEGRATION\`."
      echo
      echo "No branch was skipped, no failure was recorded."
    else
      printf '**Result:** INCOMPLETE — %s failure(s). `%s` does NOT contain every branch and was not pushed.\n' \
        "$n" "$INTEGRATION"
      echo
      while IFS= read -r kind; do
        printf '## %s\n\n' "$kind"
        _fork_rows_of_kind "$kind"
        printf '\n**What to do:** %s\n\n' "$(_fork_kind_advice "$kind")"
      done < <(_fork_kinds_present)
    fi
  } > "$FORK_DIR/LAST_RUN.md"
}
