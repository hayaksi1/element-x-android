# Cutover report — 2026-08-28

What changed, ref by ref, and what is left for the owner.

## Refs

| Ref | Before | After | Note |
| :--- | :--- | :--- | :--- |
| `develop` | `502b130548` (238 ahead) | `3ec30d7c94` | **pristine ff-only mirror**, 0 ahead of upstream |
| `master` | did not exist | `ceeb66c750` | integration branch, 180 commits, **default branch** |
| `backup/develop-20260828-0119` | — | `502b130548` | immutable snapshot of the **old `develop`**, from *before* `master` existed. Regression baseline only — **not** a rollback point for `master` |
| `feat/fork-tooling` | did not exist | pushed | `.fork/` + workflow + rerere cache |
| `feat/fork-misc` | did not exist | pushed | 16 commits that lived only on the old develop |

**No branch was deleted or renamed.** All 76 pre-existing branches are untouched.

## What is on `master`

73 branches integrated: 50 PR-backed (merged/cherry-picked as-is, never rebased)
plus 23 fork-only. 51 merged clean; 22 needed conflict resolution.

## Completeness

Verified against the backup, not assumed:

- **0 upstream files lost** (`comm` of the full file lists).
- 64 files initially looked missing; **59 were upstream renames** (`*Events.kt` →
  `*Event.kt`), confirmed individually.
- Of 23 develop-only commits with no branch, **16 became `feat/fork-misc`**; the
  other 7 were already applied, each checked by content rather than trusting the
  cherry-pick failure.
- Only 2 merge artefacts existed: a resurrected view (upstream deleted the
  screen in `c2b3b0fe0f`) and `shortcuts.xml`, which is legitimate fork work.

## Commits dropped, and why

| Commit | Reason |
| :--- | :--- |
| 8 commits patch-id-identical to upstream | already in `upstream/develop` |
| ~16 glue commits (konsist fixes, import ordering, licence-header churn, two identical "Drop the narration comments") | artefacts of merging into a shared develop; the model that produced them is gone |
| `tmp-7538`, `fix/developer-options-toggle` | another session's scratch branch; a superseded 165-commit aggregate. **Both branches still exist**, they are only absent from the manifest |
| `feature/message-search`, `feature/search-index-button`, 3 `search/*` slices | superseded — upstream absorbed the matrix layer in #7249 and the remaining UI came in via `search/room-search-screen` + `search/message-search-index` |

## Damage caused by automatic conflict resolution, and how it was found

The union ("keep both sides") resolver was correct for imports and for two
branches adding separate helpers, and **wrong** whenever both sides were
different generations of the same code. It produced:

- duplicate functions with different signatures, and a caller passing both APIs
- a function emitted twice with identical bodies **and balanced braces**
- three `<resources>` roots in one XML file
- dropped KDoc openings, so `*` lines parsed as member declarations
- two sealed interfaces (`FooEvent` and `FooEvents`) side by side
- three fork-only files dropped entirely

**Every structural heuristic written to catch this had false positives** — 66,
then 96, measured by negative control against pure upstream files. Raw strings
defeat brace counting; overloads look like duplicate declarations. The checker
now reports only problems that are *new versus the same file upstream*.

**The compiler was the only reliable detector.** The repair that worked was
mechanical and safe: for any file upstream has not touched since the old merge
base, restore the pre-cutover tree's version wholesale.

## Manual steps for the owner

- [x] Default branch → `master` (done)
- [x] Issues enabled (done)
- [ ] Branch protection on `develop` so nothing can push to the mirror
- [ ] Nothing else: detect/publish use `GITHUB_TOKEN`, and the `enterprise`
      deploy key is deliberately unused

## Rollback

### Undoing a bad *sync* (the common case)

Every successful `.fork/sync-upstream.sh` run tags its `master` tip
`sync/<YYYYMMDD-HHMM>`. That tag is the rollback point. `master` is
fast-forward-only, so rolling back is a new commit restoring the old tree — never
a reset and never a force-push:

```bash
git fetch origin --tags
git tag --list 'sync/*' --sort=-creatordate | head      # pick the last good build

GOOD=sync/<YYYYMMDD-HHMM>
BAD=$(git rev-parse origin/master)

git checkout master
git reset --hard "$BAD"
new=$(git commit-tree "$GOOD^{tree}" -p "$BAD" -m "rollback: restore $GOOD")
git update-ref refs/heads/master "$new" "$BAD"
git diff "$GOOD" master                                 # MUST print nothing
git push origin master
```

To merely *build* an older known-good app, skip all of that:
`git checkout sync/<YYYYMMDD-HHMM>` and build from the detached head.

### Undoing the *cutover itself* (historical, almost certainly not what you want)

> **`backup/develop-20260828-0119` is a snapshot of the old `develop` taken before
> `master` existed. It contains none of the 75 integrated branches.** Resetting
> `master` to it does not restore a working app — it publishes the pre-cutover tree
> over the accumulated one and discards every integrated branch. Use it as a
> regression *baseline* (`git diff backup/develop-20260828-0119 master`), never as a
> rollback target.

Reverting the branch-model change itself means restoring the old `develop`, not
`master`:

```bash
git push --force-with-lease origin backup/develop-20260828-0119:develop
```

No branch was ever deleted or renamed, so every feature branch survives either way.
