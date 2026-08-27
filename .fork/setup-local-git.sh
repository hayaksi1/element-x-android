#!/usr/bin/env bash
# One-time local git setup for this fork. Idempotent -- safe to re-run.
# Everything it writes is LOCAL and uncommitted, so upstream files never
# conflict.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
GITDIR="$(git rev-parse --git-common-dir)"

say() { printf '  %s\n' "$*"; }
echo "Configuring local git for the element-x-android fork"

# 1. rerere -- resolve a conflict once, replay it forever.
#    The cache is committed under .fork/rr-cache so resolutions survive a
#    re-clone and are shared. rerere skips binary paths, so snapshots never
#    pollute it (measured).
git config rerere.enabled true
git config rerere.autoUpdate true
mkdir -p "$ROOT/.fork/rr-cache"
if [[ -e "$GITDIR/rr-cache" && ! -L "$GITDIR/rr-cache" ]]; then
  say "NOTE: $GITDIR/rr-cache exists and is not a symlink; leaving it alone."
else
  ln -sfn "$ROOT/.fork/rr-cache" "$GITDIR/rr-cache"
  say "rerere enabled, cache -> .fork/rr-cache"
fi

# 2. Snapshot merge policy.
#    .gitattributes (an UPSTREAM file we must not edit) declares merge=lfs,
#    but no driver of that name exists at any scope. Git therefore TEXT-merges
#    the LFS pointer, and a later `git add` re-encodes the conflict markers
#    into a structurally valid pointer whose payload is marker text --
#    `git lfs fsck` passes and nothing notices until a PNG fails to decode.
#    Declaring merge=binary here overrides that per-clone: the file conflicts
#    with no markers, ours' real bytes stay in the worktree, and there is
#    nothing corruptible for the clean filter to re-encode.
ATTR="$GITDIR/info/attributes"
mkdir -p "$(dirname "$ATTR")"
add_attr() {
  local rule="$1"
  grep -qxF "$rule" "$ATTR" 2>/dev/null || { echo "$rule" >> "$ATTR"; say "attr: $rule"; }
}
add_attr '**/snapshots/**/*.png merge=binary'
add_attr 'screenshots/**/*.png merge=binary'
add_attr 'libraries/compound/screenshots/** merge=binary'

# 3. Submodule policy: always upstream's gitlink, never initialised.
#    The owner has no access to element-android-enterprise (private).
#    isEnterpriseBuild = File("enterprise/README.md").exists() -> false,
#    which selects the FOSS build we want. Upstream CI skips it for forks too.
git config submodule.recurse false
say "submodule.recurse=false (enterprise stays uninitialised, by design)"

# 4. Guard: refuse commits on the mirror branch.
#    develop is a byte-exact mirror of upstream/develop. This hook is what
#    actually stops an agent -- agents read error messages, not rules files.
HOOK="$GITDIR/hooks/pre-commit"
if [[ -e "$HOOK" ]] && ! grep -q 'fork-mirror-guard' "$HOOK" 2>/dev/null; then
  say "NOTE: a pre-commit hook already exists; not overwriting. Add the guard by hand."
else
  cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# fork-mirror-guard
branch="$(git symbolic-ref -q --short HEAD || true)"
if [[ "$branch" == "develop" ]]; then
  cat >&2 <<'MSG'

  REFUSED: develop is a pristine mirror of upstream/develop.

  It must fast-forward from upstream, so it can never carry a fork commit.
  Put this work on a feature branch instead:

      git branch feat/<slug>
      git checkout feat/<slug>
      git commit ...
      echo feat/<slug> >> .fork/features.txt

  Then rebuild the integration branch:

      .fork/sync-upstream.sh

  If a maintainer is pushing to an open PR branch, commit on THAT branch.

MSG
  exit 1
fi
MSG_UNUSED=""
HOOK_EOF
  chmod +x "$HOOK"
  say "pre-commit guard installed (refuses commits on develop)"
fi

echo "Done. Read .fork/FORK_RULES.md next."
