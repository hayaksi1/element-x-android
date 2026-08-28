#!/usr/bin/env bash
# .fork/lib/envcheck.sh -- environment invariants for the fork sync.
#
# SOURCED, never executed. Functions only, no top-level side effects, no exit.
# Runs under `set -euo pipefail`. Reads the globals and helpers documented in
# .fork/CONTRACT (REPO_ROOT, DRY_RUN; log/warn/die/run).
#
# Three invariants that are documented in FORK_RULES.md and enforced nowhere:
#
#   1. the `enterprise` submodule must stay uninitialised -- initialising it
#      flips isEnterpriseBuild to true and invalidates every Paparazzi golden,
#      all of which were recorded under the FOSS build;
#   2. JAVA_HOME must be a JDK 21 that actually has a compiler -- a JRE, or a
#      JDK of the wrong major, fails deep inside Gradle with a message that
#      reads like a project fault;
#   3. a build must be proven to have produced NEW artifacts -- an OOM-killed
#      release build prints no `BUILD FAILED` line and leaves the previous
#      run's APKs sitting in app/build/outputs/ looking fresh.

# --- invariant 1: the enterprise submodule stays uninitialised --------------
#
# `git submodule status` prefixes each line with one character:
#   '-'  not initialised          <- the only state we accept
#   ' '  initialised, at gitlink
#   '+'  initialised, different SHA
#   'U'  merge conflict
assert_enterprise_uninitialised() {
  local sub_dir="$REPO_ROOT/enterprise"
  local remedy="run: git submodule deinit -f enterprise && rm -rf .git/modules/enterprise"
  local why="enterprise is private (no key here) and isEnterpriseBuild=File(\"enterprise/README.md\").exists(); a true value selects the enterprise build, and every Paparazzi golden in this repo was recorded under the FOSS build."

  if [[ -e "$sub_dir/README.md" ]]; then
    die "enterprise/README.md exists -- the enterprise submodule is populated. $why  To fix: $remedy"
  fi

  local status_line=""
  status_line="$(git -C "$REPO_ROOT" submodule status enterprise 2>/dev/null || true)"
  if [[ -n "$status_line" ]]; then
    local flag="${status_line:0:1}"
    if [[ "$flag" != "-" ]]; then
      warn "git submodule status enterprise: $status_line"
      die "the enterprise submodule is initialised (status flag '${flag}'). $why  To fix: $remedy"
    fi
  fi

  # A deinitialised gitlink is an EMPTY directory (or no directory at all).
  # Anything inside it means a checkout populated it.
  if [[ -d "$sub_dir" ]]; then
    local stray=""
    stray="$(find "$sub_dir" -mindepth 1 -print -quit 2>/dev/null || true)"
    if [[ -n "$stray" ]]; then
      warn "unexpected content under enterprise/: $stray"
      die "the enterprise gitlink placeholder is not empty. $why  To fix: $remedy"
    fi
  fi

  # submodule.recurse=true makes every checkout/pull/clone re-populate it, so
  # the invariant would break again on the next git command.
  local recurse=""
  recurse="$(git -C "$REPO_ROOT" config --get submodule.recurse || true)"
  case "$recurse" in
    "")
      log "submodule.recurse unset -- setting it to false so no checkout re-populates enterprise"
      run git -C "$REPO_ROOT" config submodule.recurse false
      ;;
    false|0|no|off)
      : ;;
    *)
      # Deliberate operator setting. Report it and stop rather than silently
      # reversing someone's config -- but do not continue, because the next
      # checkout in this script would initialise enterprise.
      die "submodule.recurse is set to '$recurse'; every checkout would re-initialise enterprise. $why  To fix: git -C '$REPO_ROOT' config submodule.recurse false"
      ;;
  esac

  log "enterprise submodule uninitialised (ok)"
}

# --- invariant 2: JDK 21 WITH a compiler ------------------------------------
#
# Replaces the JAVA_HOME block in verify(). Difference from the old code: an
# explicit JAVA_HOME is authoritative (we validate it instead of silently
# falling back to another JVM), and the javac MAJOR VERSION is checked -- the
# old code accepted any javac at all.
assert_jdk21_with_compiler() {
  local -a candidates=()
  local explicit=0

  if [[ -n "${JAVA_HOME:-}" ]]; then
    candidates=("$JAVA_HOME")
    explicit=1
  else
    candidates=(/usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-21)
  fi

  local cand javac_bin ver_line major
  for cand in "${candidates[@]}"; do
    [[ -n "$cand" ]] || continue
    javac_bin="$cand/bin/javac"
    if [[ ! -x "$javac_bin" ]]; then
      if [[ $explicit -eq 1 ]]; then
        die "JAVA_HOME=$cand has no executable bin/javac -- that is a JRE, not a JDK. Gradle fails on it with 'does not provide the required capabilities: [JAVA_COMPILER]'. Set JAVA_HOME to a full JDK 21, e.g. export JAVA_HOME=/usr/lib/jvm/java-21-openjdk"
      fi
      continue
    fi

    ver_line="$("$javac_bin" -version 2>&1 | head -n 1)"
    if [[ ! "$ver_line" =~ ^javac[[:space:]]+([0-9]+) ]]; then
      if [[ $explicit -eq 1 ]]; then
        die "could not read a version from '$javac_bin -version' (got: ${ver_line:-<empty>}). Set JAVA_HOME to a full JDK 21, e.g. export JAVA_HOME=/usr/lib/jvm/java-21-openjdk"
      fi
      continue
    fi
    major="${BASH_REMATCH[1]}"

    if [[ "$major" != "21" ]]; then
      if [[ $explicit -eq 1 ]]; then
        die "JAVA_HOME=$cand is JDK $major ($ver_line), but this project needs JDK 21. Set JAVA_HOME to a full JDK 21, e.g. export JAVA_HOME=/usr/lib/jvm/java-21-openjdk"
      fi
      continue
    fi

    export JAVA_HOME="$cand"
    log "JAVA_HOME=$JAVA_HOME ($ver_line)"
    return 0
  done

  die "no JDK 21 with a compiler found (looked in: ${candidates[*]}). Set JAVA_HOME to a full JDK 21, not a JRE, e.g. export JAVA_HOME=/usr/lib/jvm/java-21-openjdk"
}

# --- invariant 3: a build produced NEW artifacts ----------------------------

# Remove app/build/outputs/ entirely, so no artifact from a previous run can be
# mistaken for the output of this one. Safe when the directory is absent.
clean_build_outputs() {
  local outputs="$REPO_ROOT/app/build/outputs"
  if [[ ! -e "$outputs" ]]; then
    log "no $outputs to clean"
    return 0
  fi
  log "removing stale build outputs: $outputs"
  run rm -rf -- "$outputs"
}

# Capture immediately BEFORE a build; feed to assert_artifacts_fresh after.
build_start_stamp() {
  date +%s
}

# assert_artifacts_fresh <start_epoch> [glob...]
#
# Dies unless at least one artifact matches AND every match is strictly newer
# than <start_epoch>. The two failure messages are deliberately different:
#
#   "no artifact"      -- the build never got as far as writing one.
#   "older than the build" -- THE OOM SIGNATURE. R8 reaches ~9 GB RSS, the
#                        systemd scope is OOM-killed mid-task, Gradle prints
#                        nothing conclusive, and the PREVIOUS run's APKs are
#                        still sitting there looking like a success.
assert_artifacts_fresh() {
  local start="$1"; shift
  local -a globs=("$@")
  if [[ ${#globs[@]} -eq 0 ]]; then
    globs=("$REPO_ROOT/app/build/outputs/**/*.apk")
  fi

  if [[ ! "$start" =~ ^[0-9]+$ ]]; then
    die "assert_artifacts_fresh: '$start' is not an epoch-seconds stamp (use build_start_stamp)"
  fi

  # Expand in a subshell so globstar/nullglob never leak to the caller. IFS= so
  # a pattern is never word-split; pathname expansion still splits the results,
  # which is what makes a path containing spaces safe here.
  local -a matches=()
  mapfile -d '' -t matches < <(
    IFS=
    shopt -s globstar nullglob
    for g in "${globs[@]}"; do
      for f in $g; do
        [[ -f "$f" ]] && printf '%s\0' "$f"
      done
    done
  )

  if [[ ${#matches[@]} -eq 0 ]]; then
    die "no artifact at all matched: ${globs[*]} -- the build produced nothing. Read the full Gradle log; if it ends without 'BUILD SUCCESSFUL' or 'BUILD FAILED' the task was killed."
  fi

  local -a stale=()
  local f
  for f in "${matches[@]}"; do
    if [[ -z "$(find "$f" -maxdepth 0 -newermt "@$start" -print 2>/dev/null || true)" ]]; then
      stale+=("$f")
    fi
  done

  if [[ ${#stale[@]} -gt 0 ]]; then
    for f in "${stale[@]}"; do
      warn "stale artifact: $f"
    done
    die "${#stale[@]} of ${#matches[@]} artifact(s) are OLDER than the build start ($start) -- they are left over from a PREVIOUS build, so this build did not produce them. This is the OOM signature: R8 is killed mid-task and Gradle exits without a 'BUILD FAILED' line. Re-run with more memory, and call clean_build_outputs before the build."
  fi

  log "${#matches[@]} artifact(s) newer than the build start (ok)"
}
