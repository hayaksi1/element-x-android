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
    unmanaged-branch
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
    if [[ "$n" -eq 0 ]]; then
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
