#!/usr/bin/env bash
# Harness for .fork/lib/envcheck.sh.
#
# Every assert is exercised BOTH ways: silent when the environment is sound,
# and firing on a deliberately broken fixture. Prints PASS/FAIL per case and
# exits non-zero if any case fails.
#
# All fixtures live in throwaway git repos under ./t/, recreated each run.
# `git submodule update --init` is run ONLY inside those fixtures -- never
# anywhere near a real element-x-android checkout, where it would populate
# enterprise/ and invalidate every Paparazzi golden.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/t"
REAL_JDK21="/usr/lib/jvm/java-21-openjdk"

# --- the helpers envcheck.sh is sourced next to, verbatim from sync-upstream.sh
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

DRY_RUN=0
REPO_ROOT="$T"

# shellcheck source=/home/jack/exa-wpd/envcheck.sh
# The module lives in .fork/lib/; the harness in .fork/tests/.
. "${FORK_LIB:-$HERE/../lib}/envcheck.sh"

# --- scoreboard -------------------------------------------------------------
declare -i PASSED=0 FAILED=0
ok()   { PASSED+=1; printf '\n\033[1;32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAILED+=1; printf '\n\033[1;31mFAIL\033[0m  %s\n        %s\n' "$1" "$2"; }
show() { [[ -n "$1" ]] && printf '%s\n' "$1" | sed 's/^/      | /'; return 0; }

expect_ok() {
  local name="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then ok "$name"; else bad "$name" "expected success, got rc=$rc"; fi
  show "$out"
}

# expect_die <name> <substring the message must contain> <cmd...>
expect_die() {
  local name="$1" needle="$2"; shift 2
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    bad "$name" "expected a die, got rc=0"
  elif [[ "$out" != *"$needle"* ]]; then
    bad "$name" "message does not mention: $needle"
  else
    ok "$name"
  fi
  show "$out"
}

# --- wrappers so each case can rebind a global inside its own subshell -------
# shellcheck disable=SC2034  # REPO_ROOT is read by the sourced module, not here
with_repo_root()  { REPO_ROOT="$1"; shift; "$@"; }
with_java_home()  { export JAVA_HOME="$1"; shift; "$@"; }
without_java_home() { unset JAVA_HOME; "$@"; }
check()           { "$@"; }   # plain assertions, so they can be graded too

# --- fixtures ---------------------------------------------------------------
g() { git -c protocol.file.allow=always -c user.name=t -c user.email=t@example.invalid -C "$1" "${@:2}"; }

build_base_fixture() {
  local base="$T/_base"
  mkdir -p "$base"
  git init -q -b main "$base/subrepo"
  : > "$base/subrepo/PLACEHOLDER"
  g "$base/subrepo" add PLACEHOLDER
  g "$base/subrepo" commit -q -m "enterprise stub"

  git init -q -b main "$base/repo"
  g "$base/repo" commit -q --allow-empty -m base
  g "$base/repo" submodule --quiet add "$base/subrepo" enterprise
  g "$base/repo" commit -q -m "add enterprise gitlink"
  # deinit: gitlink stays registered, working directory goes empty.
  g "$base/repo" submodule --quiet deinit -f enterprise
}

clone_fixture() { cp -a "$T/_base/repo" "$T/$1"; printf '%s\n' "$T/$1"; }

fake_jdk() {  # $1 name, $2 version string ("" = no javac at all)
  local d="$T/$1"
  mkdir -p "$d/bin"
  if [[ -n "$2" ]]; then
    printf '#!/bin/sh\necho "javac %s"\n' "$2" > "$d/bin/javac"
    chmod +x "$d/bin/javac"
  fi
  printf '%s\n' "$d"
}

# --- setup ------------------------------------------------------------------
rm -rf "$T"
mkdir -p "$T"
build_base_fixture

printf '\n======== envcheck.sh ========\n'
printf 'bash %s   fixtures: %s\n' "$BASH_VERSION" "$T"

# =============================================================================
printf '\n--- invariant 1: enterprise stays uninitialised ---\n'

F_OK="$(clone_fixture uninit)"
printf '  fixture %s -> submodule status: %s\n' "$F_OK" "$(g "$F_OK" submodule status enterprise)"
expect_ok "1. uninitialised gitlink is accepted" \
  with_repo_root "$F_OK" assert_enterprise_uninitialised

F_README="$(clone_fixture readme)"
mkdir -p "$F_README/enterprise"; : > "$F_README/enterprise/README.md"
expect_die "2. enterprise/README.md present -> dies" \
  "git submodule deinit -f enterprise" \
  with_repo_root "$F_README" assert_enterprise_uninitialised

F_INIT="$(clone_fixture inited)"
g "$F_INIT" submodule --quiet update --init enterprise
printf '  fixture %s -> submodule status: %s\n' "$F_INIT" "$(g "$F_INIT" submodule status enterprise)"
expect_die "3. genuinely initialised submodule -> dies" \
  "is initialised" \
  with_repo_root "$F_INIT" assert_enterprise_uninitialised

F_STRAY="$(clone_fixture stray)"
mkdir -p "$F_STRAY/enterprise"; : > "$F_STRAY/enterprise/build.gradle.kts"
expect_die "3b. gitlink placeholder populated behind git's back -> dies" \
  "not empty" \
  with_repo_root "$F_STRAY" assert_enterprise_uninitialised

F_UNSET="$(clone_fixture recurse-unset)"
printf '  before: submodule.recurse=[%s]\n' "$(g "$F_UNSET" config --get submodule.recurse || true)"
expect_ok "4a. submodule.recurse unset -> set to false" \
  with_repo_root "$F_UNSET" assert_enterprise_uninitialised
expect_ok "4b. submodule.recurse is now literally false" \
  check test "$(g "$F_UNSET" config --get submodule.recurse || true)" = false

F_TRUE="$(clone_fixture recurse-true)"
g "$F_TRUE" config submodule.recurse true
expect_die "4c. explicit submodule.recurse=true -> reported, not overwritten" \
  "submodule.recurse is set to 'true'" \
  with_repo_root "$F_TRUE" assert_enterprise_uninitialised
expect_ok "4d. ... and the operator's 'true' is still there afterwards" \
  check test "$(g "$F_TRUE" config --get submodule.recurse || true)" = true

# =============================================================================
printf '\n--- invariant 2: JDK 21 with a compiler ---\n'

expect_ok "5. real JDK 21 ($REAL_JDK21) is accepted" \
  with_java_home "$REAL_JDK21" assert_jdk21_with_compiler

expect_ok "5b. JAVA_HOME unset -> discovers a JDK 21" \
  without_java_home assert_jdk21_with_compiler

J17="$(fake_jdk fakejdk17 '17.0.9')"
expect_die "6. JAVA_HOME whose javac reports 17.0.9 -> dies" \
  "is JDK 17" \
  with_java_home "$J17" assert_jdk21_with_compiler

JRE="$(fake_jdk fakejre '')"
expect_die "7. JAVA_HOME with no bin/javac (a JRE) -> dies" \
  "JAVA_COMPILER" \
  with_java_home "$JRE" assert_jdk21_with_compiler

# =============================================================================
printf '\n--- invariant 3: the build produced NEW artifacts ---\n'

B="$T/buildrepo"
mkdir -p "$B/app/build/outputs/apk/gplayDebug"
: > "$B/app/build/outputs/apk/gplayDebug/app-gplay-debug.apk"
expect_ok "8a. clean_build_outputs removes a populated outputs/" \
  with_repo_root "$B" clean_build_outputs
expect_ok "8b. ... and the directory is really gone" \
  check test ! -e "$B/app/build/outputs"
expect_ok "8c. clean_build_outputs is a no-op when absent" \
  with_repo_root "$B" clean_build_outputs

STAMP="$(build_start_stamp)"
printf '  build_start_stamp -> %s\n' "$STAMP"

mkdir -p "$B/app/build/outputs/apk/gplay debug"
FRESH="$B/app/build/outputs/apk/gplay debug/app-gplay-debug.apk"
: > "$FRESH"; touch -d "@$((STAMP + 5))" "$FRESH"
expect_ok "9. APK newer than the stamp is accepted (path has a space)" \
  with_repo_root "$B" assert_artifacts_fresh "$STAMP"

touch -d "@$((STAMP - 3600))" "$FRESH"
expect_die "10. APK older than the stamp -> dies with the OOM signature" \
  "OLDER than the build start" \
  with_repo_root "$B" assert_artifacts_fresh "$STAMP"
STALE_OUT="$( (REPO_ROOT="$B" assert_artifacts_fresh "$STAMP") 2>&1 || true )"
expect_ok "10b. ... and does NOT claim the artifact is missing" \
  check test "${STALE_OUT#*no artifact at all}" = "$STALE_OUT"

rm -rf "$B/app/build/outputs"
expect_die "11. no APK at all -> dies with a DIFFERENT message" \
  "no artifact at all" \
  with_repo_root "$B" assert_artifacts_fresh "$STAMP"

# =============================================================================
printf '\n========================================\n'
printf 'passed: %d   failed: %d\n' "$PASSED" "$FAILED"
if [[ $FAILED -gt 0 ]]; then
  printf '\033[1;31mHARNESS FAILED\033[0m\n'
  exit 1
fi
printf '\033[1;32mHARNESS OK\033[0m\n'
