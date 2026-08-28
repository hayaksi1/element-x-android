#!/usr/bin/env bash
# .fork/lib/audit.sh -- SOURCED by .fork/sync-upstream.sh. Functions only.
#
# Two jobs:
#
#   1. The snapshot merge policy.  The committed .gitattributes declares
#      `merge=lfs` on snapshot PNGs, but no merge driver of that name exists at
#      any scope.  Git therefore falls back to a TEXT merge of the LFS pointer,
#      and a later `git add` re-encodes the conflict markers into a
#      structurally valid pointer whose payload is marker text.  `git lfs fsck`
#      passes.  Nothing notices until a PNG fails to decode.  The countermeasure
#      is `merge=binary` in $(git rev-parse --git-common-dir)/info/attributes --
#      a LOCAL, UNCOMMITTED file, because .gitattributes is an upstream file and
#      editing it conflicts on every upstream change.  Local means a fresh clone
#      or a CI runner has none, so the rules are (re)written on every run and
#      then PROVEN with `git check-attr`.
#
#   2. The rerere cache audit.  rerere replays recorded resolutions unattended.
#      A resolution that is itself wrong replays a broken file forever while the
#      merge reports clean.  Every entry is validated before the first merge;
#      one bad entry stops the run instead of being replayed.
#
# Reads globals: REPO_ROOT FORK_DIR DRY_RUN MIRROR INTEGRATION
# Calls helpers:  log warn die run

# --- the three rules, and one probe path per rule ---------------------------
# Kept as functions, not arrays: this file is sourced, possibly more than once,
# and must have no top-level side effects.
_snapshot_attr_rules() {
  printf '%s\n' \
    '**/snapshots/**/*.png merge=binary' \
    'screenshots/**/*.png merge=binary' \
    'libraries/compound/screenshots/** merge=binary'
}

# Same order as _snapshot_attr_rules. Each probe is matched by exactly one rule,
# so a failing probe names the rule that is missing.
_snapshot_attr_probes() {
  printf '%s\n' \
    'tests/uitests/src/test/snapshots/images/probe.png' \
    'screenshots/probedir/probe.png' \
    'libraries/compound/screenshots/probedir/probe.png'
}

# Absolute path of the common git dir. `git rev-parse --git-common-dir` returns
# a path relative to the CWD ('.git') in the ordinary case, which is wrong the
# moment anything cds.
_audit_gitdir() {
  local d
  d="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$d" ]]; then
    d="$(git rev-parse --git-common-dir)"
    [[ "$d" == /* ]] || d="$PWD/$d"
  fi
  printf '%s\n' "$d"
}

# --- defect 3: the snapshot merge policy ------------------------------------

# Idempotently ensure ALL THREE rules are present. One `grep -qxF` per rule:
# the old code grepped for the first pattern only and skipped the rest when it
# matched, so a file holding just rule 1 never gained rules 2 and 3.
#
# Writes for real even under DRY_RUN=1. The file is local and uncommitted, it
# is not part of the change under review, and NOT writing it is the bug this
# function exists to fix -- a dry run that leaves the policy off would merge
# snapshots as text.
ensure_snapshot_attrs() {
  local f rule last added=0
  f="$(_audit_gitdir)/info/attributes"
  mkdir -p -- "${f%/*}"
  [[ -e "$f" ]] || : > "$f"

  # A file whose last byte is not a newline would glue rule 1 onto its last line.
  if [[ -s "$f" ]]; then
    last="$(tail -c 1 -- "$f")"
    [[ -n "$last" ]] && printf '\n' >> "$f"
  fi

  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    grep -qxF -- "$rule" "$f" && continue
    printf '%s\n' "$rule" >> "$f"
    log "snapshot merge policy: added '$rule' to $f"
    added=$((added + 1))
  done < <(_snapshot_attr_rules)

  if [[ $added -eq 0 ]]; then
    log "snapshot merge policy already complete in $f"
  fi
  return 0
}

# Prove the policy is actually in effect. Presence of a line is not proof:
# .gitattributes precedence, a typo, or a stale `merge=lfs` line in the same
# file would all leave a rule present and inert. Call before the first merge.
assert_snapshot_attrs() {
  local probe out value n=0
  while IFS= read -r probe; do
    [[ -z "$probe" ]] && continue
    out="$(git check-attr merge -- "$probe" 2>/dev/null || true)"
    value="${out##*: merge: }"
    if [[ "$value" != "binary" ]]; then
      die "snapshot merge policy NOT in effect: 'git check-attr merge -- $probe' reports '${value:-<no output>}', expected 'binary'. Snapshot PNGs would be TEXT-merged and silently corrupted. Fix $(_audit_gitdir)/info/attributes (or run .fork/setup-local-git.sh) and re-run."
    fi
    n=$((n + 1))
  done < <(_snapshot_attr_probes)
  log "snapshot merge policy verified: $n/$n probe path(s) report merge=binary"
  return 0
}

# --- defect 4: the rerere cache audit ---------------------------------------

# Resolved from THIS file's own location, not $FORK_DIR: the test harness sources
# the module from a scratch directory with FORK_DIR empty.
_rr_semantic_py() {
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rr_semantic.py"
}

rr_cache_dir() {
  printf '%s\n' "$(_audit_gitdir)/rr-cache"
}

# Ids exempt from the LFS-pointer rule ONLY -- never from the marker rules.
# Missing file = empty list.
_rr_verified_ids() {
  local f="${FORK_DIR:-}/rr-cache-verified.txt"
  [[ -n "${FORK_DIR:-}" && -f "$f" ]] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' -- "$f" | grep -v '^$' || true
}

# A rerere preimage is a recorded conflict: all three markers, at line start.
_rr_has_all_markers() {
  local f="$1"
  grep -qa '^<<<<<<<' -- "$f" &&
  grep -qa '^=======' -- "$f" &&
  grep -qa '^>>>>>>>' -- "$f"
}

_rr_has_any_marker() {
  grep -qaE '^(<<<<<<<|=======|>>>>>>>)' -- "$1"
}

_rr_is_lfs_pointer() {
  grep -qaF -- 'version https://git-lfs.github.com/spec/' "$1"
}

# Print one TSV row per problem: <variant>\t<rule>\t<detail>.
# Returns 0 when the entry is clean, 1 when it is not.
_rr_entry_problems() {
  local dir="${1%/}"
  local id="${dir##*/}"
  local exempt=0 bad=0
  local -a images=() variants=()
  local f v pre post

  if _rr_verified_ids | grep -qxF -- "$id"; then exempt=1; fi

  mapfile -t images < <(find "$dir" -maxdepth 1 -type f \
    \( -name 'preimage' -o -name 'preimage.*' \
    -o -name 'postimage' -o -name 'postimage.*' \) -printf '%f\n' 2>/dev/null | sort)

  if [[ ${#images[@]} -eq 0 ]]; then
    printf '%s\t%s\t%s\n' '-' 'malformed' "no preimage and no postimage in $dir"
    return 1
  fi

  for f in "${images[@]}"; do
    case "$f" in
      preimage)    variants+=('') ;;
      preimage.*)  variants+=("${f#preimage}") ;;
      postimage)   variants+=('') ;;
      postimage.*) variants+=("${f#postimage}") ;;
    esac
  done
  mapfile -t variants < <(printf '%s\n' "${variants[@]}" | sort -u)

  for v in "${variants[@]}"; do
    pre="$dir/preimage$v"
    post="$dir/postimage$v"

    if [[ ! -f "$pre" ]]; then
      printf '%s\t%s\t%s\n' "${v:-0}" 'missing-preimage' \
        "postimage$v exists with no matching preimage$v; rerere cannot match it to any conflict"
      bad=1
      continue
    fi

    if ! _rr_has_all_markers "$pre"; then
      printf '%s\t%s\t%s\n' "${v:-0}" 'preimage-no-marker' \
        "preimage$v carries no <<<<<<< / ======= / >>>>>>> conflict markers; a preimage is by definition a recorded conflict"
      bad=1
    fi

    if [[ $exempt -eq 0 ]] && _rr_is_lfs_pointer "$pre"; then
      printf '%s\t%s\t%s\n' "${v:-0}" 'lfs-pointer' \
        "preimage$v is a git-lfs pointer, i.e. this conflict was recorded through the very text-merge path the merge=binary policy exists to stop; suspect until re-verified (exempt it by id in \$FORK_DIR/rr-cache-verified.txt)"
      bad=1
    fi

    [[ -f "$post" ]] || continue   # preimage-only: unresolved, replays nothing

    if _rr_has_any_marker "$post"; then
      printf '%s\t%s\t%s\n' "${v:-0}" 'postimage-marker' \
        "postimage$v still contains conflict markers; replaying it would write a half-resolved file and report the merge clean"
      bad=1
    fi

    if [[ ! -s "$post" && -s "$pre" ]]; then
      printf '%s\t%s\t%s\n' "${v:-0}" 'postimage-empty' \
        "postimage$v is zero bytes while preimage$v is not; replaying it would empty the file"
      bad=1
    fi

    if [[ $exempt -eq 0 ]] && _rr_is_lfs_pointer "$post"; then
      printf '%s\t%s\t%s\n' "${v:-0}" 'lfs-pointer' \
        "postimage$v is a git-lfs pointer, i.e. a snapshot resolution recorded through a text merge; replaying it would install a pointer whose payload may be marker text (git lfs fsck would still pass)"
      bad=1
    fi
  done

  # The three rules above are syntactic, and NONE of them can see a resolution
  # that is merely wrong. Entry f8cb8ae9ac balanced its braces, carried no
  # marker and was not a pointer, while replaying a resolution that had lost a
  # fast-path guard and glued a closing brace onto a `return`. rr_semantic.py
  # asks the semantic questions; every rule in it was validated to fire zero
  # times across all 4240 committed .kt files before being switched on.
  local sem py
  py="$(_rr_semantic_py)"
  if [[ -f "$py" ]] && command -v python3 >/dev/null 2>&1; then
    if ! sem="$(python3 "$py" "$dir" 2>/dev/null)"; then
      if [[ -n "$sem" ]]; then
        printf '%s\n' "$sem"
        bad=1
      fi
    fi
  fi

  return "$bad"
}

# Validate every entry. Reports every bad entry, then stops the run -- replaying
# a wrong resolution is worse than not running.
audit_rerere_cache() {
  local d total=0 replayable=0 preonly=0 quarantined=0 resolutions=0
  local dir id probs n first=''
  d="$(rr_cache_dir)"

  if [[ ! -d "$d" ]]; then
    log "rerere cache: nothing at $d, nothing to audit"
    return 0
  fi

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    total=$((total + 1))
    id="${dir##*/}"

    if probs="$(_rr_entry_problems "$dir")"; then
      n="$(find "$dir" -maxdepth 1 -type f -name 'postimage*' | wc -l | tr -d '[:space:]')"
      if [[ "$n" -gt 0 ]]; then
        replayable=$((replayable + 1))
        resolutions=$((resolutions + n))
      else
        preonly=$((preonly + 1))
      fi
    else
      quarantined=$((quarantined + 1))
      while IFS=$'\t' read -r v rule detail; do
        [[ -z "$rule" ]] && continue
        warn "rr-cache QUARANTINE $id variant=$v rule=$rule: $detail"
        [[ -z "$first" ]] && first="$id ($rule)"
      done <<< "$probs"
    fi
  done < <(find "$d" -mindepth 1 -maxdepth 1 -type d | sort)

  log "rerere cache $d: $total entries, $replayable replayable ($resolutions recorded resolution(s) counting variants), $preonly preimage-only, $quarantined quarantined"

  if [[ $quarantined -gt 0 ]]; then
    die "$quarantined rerere cache entry/entries failed the audit (first: $first). rerere would replay these unattended; delete them, or list the id in \$FORK_DIR/rr-cache-verified.txt if the LFS-pointer rule is the only one broken and you have re-verified it by hand."
  fi
  return 0
}

# Move ONE failing entry aside, with the reason that condemned it.
#
# Quarantine, never clear. The cache holds hundreds of resolutions that work;
# clearing it to deal with a handful would re-ask every conflict already
# answered once, and on --continue that is the difference between an operator's
# resolution being replayed and being lost. The entry is moved, not deleted, so
# a wrong quarantine is undone with a mv.
rr_quarantine_entry() {
  local id="$1" reason="$2" q d
  d="$(rr_cache_dir)"
  q="$(_audit_gitdir)/rr-cache-quarantine"
  [[ -d "$d/$id" ]] || return 0
  run mkdir -p -- "$q"
  if [[ -e "$q/$id" ]]; then
    run rm -rf -- "$q/$id"
  fi
  run mv -- "$d/$id" "$q/$id"
  if [[ ${DRY_RUN:-0} -eq 0 && -d "$q/$id" ]]; then
    printf '%s\n' "$reason" > "$q/$id/QUARANTINE_REASON.txt"
  fi
  warn "rr-cache QUARANTINED $id -> $q/$id ($reason)"
  return 0
}

# The set of entry ids present in the live cache right now.
rr_snapshot_ids() {
  local d
  d="$(rr_cache_dir)"
  [[ -d "$d" ]] || return 0
  find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# Record the pre-integration snapshot so rr_reaudit_recorded can diff against it.
rr_reaudit_begin() {
  RR_SNAPSHOT_FILE="${STATE:-$(_audit_gitdir)/fork-sync}.rr-before"
  rr_snapshot_ids > "$RR_SNAPSHOT_FILE" 2>/dev/null || : > "$RR_SNAPSHOT_FILE"
  log "rerere cache: snapshotted $(wc -l < "$RR_SNAPSHOT_FILE" | tr -d '[:space:]') entry id(s) before integration"
  return 0
}

# Audit ONLY what this run recorded.
#
# audit_rerere_cache runs over the cache as IMPORTED, before the first merge.
# Every resolution recorded DURING the run is therefore never audited at all,
# and rerere.autoUpdate -- which cannot be turned off, see sync-upstream.sh --
# stages a replayed one automatically. That is the hole that made an unattended
# publish unsafe: an answer nobody checked could reach $INTEGRATION and be
# pushed. Diffing against the snapshot keeps the cost proportional to what
# actually changed, and a failure quarantines that one entry rather than
# stopping a run whose other 200 entries are fine.
rr_reaudit_recorded() {
  local before after id probs first='' n=0 bad=0
  before="${RR_SNAPSHOT_FILE:-${STATE:-$(_audit_gitdir)/fork-sync}.rr-before}"
  if [[ ! -f "$before" ]]; then
    warn "no pre-integration rerere snapshot at $before; re-auditing the WHOLE cache instead"
    : > "$before"
  fi
  after="$(mktemp)"
  rr_snapshot_ids > "$after"

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    if ! probs="$(_rr_entry_problems "$(rr_cache_dir)/$id")"; then
      bad=$((bad + 1))
      local reason
      reason="$(printf '%s\n' "$probs" | head -1 | cut -f2,3 | tr '\t' ' ')"
      [[ -z "$first" ]] && first="$id ($reason)"
      while IFS=$'\t' read -r v rule detail; do
        [[ -z "$rule" ]] && continue
        warn "rr-cache RECORDED-AND-REJECTED $id variant=$v rule=$rule: $detail"
      done <<< "$probs"
      rr_quarantine_entry "$id" "recorded during sync $(date -u +%Y-%m-%dT%H:%M:%SZ): $reason"
    fi
  done < <(comm -13 "$before" "$after")
  rm -f -- "$after"

  log "rerere re-audit: $n entry/entries recorded during this run, $bad quarantined"
  if [[ $bad -gt 0 ]]; then
    warn "The quarantined resolution(s) were staged by rerere.autoUpdate during this run and are now moved aside (first: $first)."
    warn "They are still in the tree that was built. Re-resolve those paths by hand and re-run with --continue."
  fi
  return 0
}

# rebuild_integration runs `git checkout -B master develop`, and develop has no
# .fork/ directory, so every tracked file under .fork/rr-cache/ is deleted from
# the worktree at that moment. setup-local-git.sh symlinks $GITDIR/rr-cache to
# that worktree path -- under that setup the cache evaporates mid-run and rerere
# silently stops replaying. Break the symlink before the first checkout.
# Seed $GITDIR/rr-cache from the COMMITTED cache. Without this the 87 entries on
# feat/fork-tooling are inert: rerere only ever reads $GITDIR/rr-cache, which is
# local, unshared, and pruned by git gc. A fresh clone, a CI runner or a pruned
# cache would re-ask every conflict that has already been answered once, and on
# --continue that is the difference between the operator's resolution being
# replayed and being lost.
rr_cache_import() {
  local d src id n=0
  d="$(rr_cache_dir)"
  src="$FORK_DIR/rr-cache"
  [[ -d "$src" ]] || { log "no committed rerere cache at $src"; return 0; }
  mkdir -p -- "$d"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    # Never overwrite a local entry: it may be a resolution recorded since, and
    # the committed copy is the older answer.
    [[ -e "$d/$(basename "$id")" ]] && continue
    cp -a -- "$id" "$d/" 2>/dev/null || continue
    n=$((n + 1))
  done < <(find "$src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  if [[ $n -gt 0 ]]; then
    log "imported $n committed rerere resolution(s) into $d"
  else
    log "committed rerere cache already present in $d"
  fi
  return 0
}

rr_cache_stage() {
  local d target root n
  d="$(rr_cache_dir)"

  if [[ ! -L "$d" ]]; then
    if [[ -d "$d" ]]; then
      log "rerere cache is already a real directory, safe across a checkout: $d"
    else
      log "rerere cache does not exist yet: $d"
    fi
    return 0
  fi

  target="$(readlink -f -- "$d" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    warn "rerere cache symlink $d is dangling; leaving it alone"
    return 0
  fi

  root="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
  root="$(readlink -f -- "$root")"
  case "$target/" in
    "$root"/*) ;;
    *) log "rerere cache symlink target $target is outside the worktree; a checkout cannot delete it, leaving it alone"
       return 0 ;;
  esac

  log "rerere cache $d -> $target lives inside the worktree; a 'git checkout -B $INTEGRATION $MIRROR' would delete it mid-run. Converting to a real directory."
  rm -f -- "$d"                       # the symlink only; never the target
  mkdir -p -- "$d"
  if [[ -d "$target" ]]; then
    cp -a -- "$target/." "$d/" 2>/dev/null || true
  fi
  n="$(find "$d" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
  log "rerere cache staged out of the worktree: $n entry/entries at $d"
  return 0
}

# Copy entries back into $FORK_DIR/rr-cache/ so a human can review and commit
# them. Never deletes on either side, and REFUSES -- does not warn -- when an
# entry fails the audit.
#
# The old behaviour skipped the bad entry and carried on. A warning is a line
# the run continues past: the export "succeeded", the operator committed what
# landed, and the entry that failed stayed in the LIVE cache replaying anyway.
# Exporting a wrong resolution is what makes it permanent and shared, so a
# failure here has to stop the run and name the entry.
rr_cache_export() {
  local src dest dir id probs exported=0 skipped=0 first_bad=''
  src="$(rr_cache_dir)"

  if [[ -z "${FORK_DIR:-}" ]]; then
    warn "FORK_DIR is unset; not exporting the rerere cache"
    return 0
  fi
  dest="$FORK_DIR/rr-cache"

  if [[ ! -d "$src" ]]; then
    log "no rerere cache to export"
    return 0
  fi
  if [[ -L "$src" && "$(readlink -f -- "$src" 2>/dev/null || true)" == "$(readlink -f -- "$dest" 2>/dev/null || true)" ]]; then
    log "rerere cache is still a symlink to $dest; nothing to export"
    return 0
  fi

  run mkdir -p -- "$dest"
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    id="${dir##*/}"
    if ! probs="$(_rr_entry_problems "$dir")"; then
      while IFS=$'\t' read -r v rule detail; do
        [[ -z "$rule" ]] && continue
        warn "rr-cache export REFUSED $id variant=$v rule=$rule: $detail"
      done <<< "$probs"
      skipped=$((skipped + 1))
      [[ -z "$first_bad" ]] && first_bad="$id"
      continue
    fi
    run mkdir -p -- "$dest/$id"
    run cp -a -- "$dir/." "$dest/$id/"
    exported=$((exported + 1))
  done < <(find "$src" -mindepth 1 -maxdepth 1 -type d | sort)

  log "rerere cache export: $exported entry/entries copied to $dest, $skipped rejected"

  if [[ $skipped -gt 0 ]]; then
    die "rerere cache export refused: $skipped entry/entries in $src fail the cache audit (first: $first_bad). They were NOT exported, and they are still live -- rerere will replay them on the next run. Quarantine each one (rr_quarantine_entry <id> <reason>, or mv it to $(_audit_gitdir)/rr-cache-quarantine/) or re-resolve it by hand, then re-run."
  fi

  # .fork/.gitignore carries `rr-cache/*` with `!rr-cache/.gitkeep`, so a plain
  # `git add .fork/rr-cache` stages NOTHING and the export looks like it worked.
  # Say so with the command that actually works.
  if [[ $exported -gt 0 && ${DRY_RUN:-0} -eq 0 ]]; then
    local probe
    probe="$(find "$dest" -mindepth 2 -maxdepth 2 -type f -name 'preimage*' -print -quit 2>/dev/null || true)"
    if [[ -n "$probe" ]] && git check-ignore -q -- "$probe" 2>/dev/null; then
      warn "the exported entries are git-ignored ($(git check-ignore -v -- "$probe" 2>/dev/null | cut -f1)); 'git add $dest' would stage nothing. Use: git add -f $dest"
    fi
  fi
  return 0
}
