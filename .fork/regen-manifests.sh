#!/usr/bin/env bash
# Regenerate .fork/pr-branches.txt by ADDING what is new. It never overwrites the
# file and it refuses, loudly, to drop a line.
#
# The selector is "every PR of ours whose state is not MERGED, whose head still
# exists on the remote". The name of the file says OPEN; the meaning is
# "integrated as-is, never rewritten", which is why a closed-but-unmerged branch
# belongs here and cannot move to features.txt -- that would mean rebasing it.
#
# The whole point is the drop guard. `gh pr list --state open > pr-branches.txt`
# is the obvious recipe and it silently discards every closed-but-unmerged
# branch, handing back a shorter file that reads perfectly clean. So: any line
# already in the manifest that the selector does not re-derive must be PROVABLY
# MERGED, or this exits non-zero and writes nothing at all.
#
# Usage:
#   .fork/regen-manifests.sh              # report only; changes nothing
#   .fork/regen-manifests.sh --apply      # append the additions
#
# Env:
#   FORK_PR_JSON    read PR data from this file instead of calling gh. The
#                   harness uses it; so can you, to rehearse against a snapshot.
#   FORK_REMOTE     default origin
#   FORK_UPSTREAM   default upstream/develop
#   FORK_DIR        default <repo>/.fork
set -uo pipefail

REMOTE="${FORK_REMOTE:-origin}"
UPSTREAM="${FORK_UPSTREAM:-upstream/develop}"
APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1
[[ "${1:-}" =~ ^(-h|--help)$ ]] && { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT"
FORK_DIR="${FORK_DIR:-$ROOT/.fork}"
PRMAN="$FORK_DIR/pr-branches.txt"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

read_list() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$' || true; }

[[ -f "$PRMAN" ]] || die "no $PRMAN"
for f in features.txt unmanaged-branches.txt; do
  [[ -f "$FORK_DIR/$f" ]] || die "no $FORK_DIR/$f -- run this from a checkout of feat/fork-tooling, not from master, whose .fork/ is a stale rebuild artefact"
done

# --- PR data ----------------------------------------------------------------
PRJSON="${FORK_PR_JSON:-}"
if [[ -z "$PRJSON" ]]; then
  command -v gh >/dev/null || die "gh not found and FORK_PR_JSON not set"
  PRJSON="$(mktemp)"; trap 'rm -f "$PRJSON"' EXIT
  log "querying PRs (--state all; --state open is the recipe that loses work)"
  gh pr list --repo element-hq/element-x-android --author hayaksi1 \
     --state all --limit 500 --json number,headRefName,state,mergedAt > "$PRJSON" \
     || die "gh pr list failed -- refusing to regenerate from a partial answer"
fi
[[ -s "$PRJSON" ]] || die "PR data is empty -- refusing to regenerate from it"

# A truncated or malformed answer must stop the run, not shrink the manifest.
jq -e 'type == "array" and length > 0' "$PRJSON" >/dev/null 2>&1 \
  || die "PR data is not a non-empty JSON array -- refusing to regenerate from it"

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
jq -r '.[] | select(.state != "MERGED") | .headRefName' "$PRJSON" | sort -u > "$TD/notmerged"
jq -r '.[] | select(.state == "MERGED") | .headRefName' "$PRJSON" | sort -u > "$TD/merged"
jq -r '.[] | [.headRefName, (.number|tostring), .state] | @tsv' "$PRJSON" > "$TD/prmap"

read_list "$PRMAN"                        | sort -u > "$TD/manifest"
read_list "$FORK_DIR/features.txt"        | sort -u > "$TD/features"
read_list "$FORK_DIR/unmanaged-branches.txt" | sort -u > "$TD/unmanaged"
git ls-remote --heads "$REMOTE" 2>/dev/null | sed 's|.*refs/heads/||' | sort -u > "$TD/onremote"
[[ -s "$TD/onremote" ]] || die "could not list $REMOTE heads -- refusing to regenerate blind"

# --- the selector -----------------------------------------------------------
# not-MERGED, still on the remote, not already fork-owned in features.txt, not a
# core branch. Anything acknowledged in unmanaged-branches.txt is reported, never
# silently adopted: that file records a deliberate decision.
comm -12 "$TD/notmerged" "$TD/onremote" > "$TD/sel.0"
comm -23 "$TD/sel.0" "$TD/features"     > "$TD/sel.1"
grep -vxE 'develop|master|feat/fork-tooling' "$TD/sel.1" | sort -u > "$TD/sel.2"
comm -23 "$TD/sel.2" "$TD/unmanaged"    > "$TD/selected"
comm -12 "$TD/sel.2" "$TD/unmanaged"    > "$TD/acknowledged"

pr_of()  { awk -F'\t' -v b="$1" '$1==b {print $2; exit}' "$TD/prmap"; }

# --- the drop guard ---------------------------------------------------------
# A line the selector did not re-derive may leave ONLY if the branch is provably
# merged. Proof A is literal ancestry; proof B is git cherry with no unabsorbed
# patch, which is what catches a squash-merge. A branch upstream later REVERTED
# passes both and is not prunable -- see "Branch retention" in FORK_RULES.md.
provably_merged() {
  local b="$1" ref="$REMOTE/$b" pr
  grep -qxF "$b" "$TD/merged" || return 1
  git rev-parse --verify --quiet "refs/remotes/$ref" >/dev/null || return 1
  pr="$(pr_of "$b")"
  if [[ -n "$pr" ]] && git log "$UPSTREAM" --oneline -i --grep="revert-$pr-" | grep -q .; then
    return 1
  fi
  git merge-base --is-ancestor "refs/remotes/$ref" "$UPSTREAM" 2>/dev/null && return 0
  git cherry "$UPSTREAM" "refs/remotes/$ref" > "$TD/.cherry" 2>/dev/null || return 1
  [[ "$(grep -c '^+' "$TD/.cherry")" -eq 0 ]]
}

comm -23 "$TD/manifest" "$TD/selected" > "$TD/notrederived"
: > "$TD/wouldlose"; : > "$TD/retirable"
while IFS= read -r b; do
  [[ -n "$b" ]] || continue
  if provably_merged "$b"; then printf '%s\n' "$b" >> "$TD/retirable"
  else printf '%s\n' "$b" >> "$TD/wouldlose"; fi
done < "$TD/notrederived"

if [[ -s "$TD/wouldlose" ]]; then
  warn "these lines are in $PRMAN but the selector did not re-derive them,"
  warn "and none is provably merged. Regenerating would DROP them:"
  while IFS= read -r b; do
    printf '      %-52s pr=%s\n' "$b" "$(pr_of "$b" || echo NONE)" >&2
  done < "$TD/wouldlose"
  die "refusing to write. $(grep -c . "$TD/wouldlose") branch(es) would be lost. Nothing changed. A truncated gh answer, a renamed head or a deleted remote branch all land here -- find out which before touching the manifest."
fi

# --- report -----------------------------------------------------------------
comm -13 "$TD/manifest" "$TD/selected" > "$TD/additions"
log "manifest $(grep -c . "$TD/manifest") · selector $(grep -c . "$TD/selected") · additions $(grep -c . "$TD/additions") · retirable $(grep -c . "$TD/retirable")"

if [[ -s "$TD/acknowledged" ]]; then
  warn "selected but acknowledged in unmanaged-branches.txt -- NOT adopted, decide by hand:"
  sed 's/^/      /' "$TD/acknowledged" >&2
fi
if [[ -s "$TD/retirable" ]]; then
  log "provably merged, so removable under Branch retention (archive + record + ask FIRST):"
  sed 's/^/      /' "$TD/retirable"
fi
if [[ ! -s "$TD/additions" ]]; then
  log "no additions; $PRMAN is current"
  exit 0
fi
log "additions:"; sed 's/^/      /' "$TD/additions"

if [[ $APPLY -eq 0 ]]; then
  log "report only -- re-run with --apply to append them"
  exit 0
fi

# Append. Never rewrite: the existing bytes are left exactly as they are, so a
# hand-written comment or a deliberate ordering cannot be lost by this script.
printf '%s\n' "" >> "$PRMAN"
printf '# added by regen-manifests.sh\n' >> "$PRMAN"
cat "$TD/additions" >> "$PRMAN"
log "appended $(grep -c . "$TD/additions") line(s) to $PRMAN"
