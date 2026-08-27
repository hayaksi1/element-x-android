# `.fork/` — fork sync tooling

Everything fork-specific lives here. Upstream will never create a `.fork/`
directory, so **nothing in here can ever conflict**. Same layout as the
`element-web` fork, so both repos share one mental model.

| File | Purpose |
| :--- | :--- |
| `FORK_RULES.md` | The rules. Read first. |
| `FORK_AUDIT.md` | Phase 1 findings — what this fork actually changes. |
| `sync-upstream.sh` | Rebuilds `master` from scratch. The only sync mechanism. |
| `setup-local-git.sh` | One-time local setup. Idempotent. |
| `features.txt` | Fork-only branches — **rebased**. |
| `pr-branches.txt` | Open upstream PR heads — **merged as-is**. |
| `integration-patches/` | Cross-feature fixes that belong to no branch. |
| `rr-cache/` | Committed rerere cache — resolve once, replay forever. |

## Why each choice

**Two manifests, not one naming convention.** 50 of 75 live branches back an
open upstream PR. Maintainers push commits onto them, so rebasing or renaming
detaches review threads and re-fires their CI. Fork-only branches have no such
constraint and are rebased for a clean history. Opposite treatment, so a branch
in both is a hard error rather than a silent bug.

**`develop` is never checked out.** A branch nobody has checked out cannot be
committed to by accident — `git commit` physically cannot land there. The
script updates it with `git update-ref`, and a `pre-commit` hook refuses
commits on it as a second layer.

**Attributes go in `.git/info/attributes`, never `.gitattributes`.**
`.gitattributes` is an upstream file; editing it creates exactly the conflicts
we are removing. `.git/info/attributes` overrides it per-clone and is never
committed.

**Snapshot PNGs merge as `binary`.** This one is subtle and was measured, not
assumed. `.gitattributes` declares `merge=lfs`, but **no driver of that name
exists at any scope**, so git silently falls back to a *text* merge of the LFS
pointer. A later `git add` then re-encodes the conflict markers into a
structurally valid pointer whose payload is marker text — `git lfs fsck`
passes, `git lfs ls-files` looks healthy, and nothing notices until Paparazzi
fails to decode a PNG. A nightly job resolving with `git add -A` would ship
288 of them. Declaring `merge=binary` closes it: no markers, ours' real bytes
stay in the worktree, nothing corruptible exists. Bonus — rerere does not
record binary paths, so the committed cache stays free of dead snapshot
preimages.

**Snapshot conflicts resolve by status code, not blindly.** `UU`/`AA`/`UD` take
`checkout --ours`; `DU` (upstream modified a screen the fork deleted) has no
stage 2 and needs `git rm` — `checkout --ours` errors there and would abort the
loop.

**Retirement detection is advisory only.** Upstream absorbs this fork's work
continuously, so a manifest rots. But "merged clean and changed nothing" has a
false positive: a branch whose merge *conflicted* and was auto-resolved shows
an empty diff while its work is gone. So the check is gated on the merge
exiting 0, and it only ever prints a suggestion. **Nothing is deleted or
renamed, ever.**

**Conflicts exit 0.** A conflict is the job's expected output, not a failure.
A nightly red badge is one nobody reads. Red is reserved for the job itself
breaking.

**The script re-execs from a temp copy.** It switches branches while running,
and bash reads scripts incrementally — without this, editing the tree under
ourselves would corrupt execution mid-run.

## Rebuilding

```bash
.fork/sync-upstream.sh --dry-run
.fork/sync-upstream.sh
```

Flags: `--dry-run`, `--no-push`, `--continue`, `--features=a,b`, `--skip-verify`.
`--skip-verify` exists for iteration and **blocks pushing**.

## Known manual steps

- **Issues must be enabled** on the fork for conflict reporting
  (`gh api -X PATCH repos/hayaksi1/element-x-android -f has_issues=true`).
- Scheduled workflows only run from the **default branch**, so the workflow
  file must live there.

## Lessons from the first rebuild (2026-08-28)

**`git merge-tree` is ground truth only while the rerere cache is empty.**
On the first rebuild this repo had no `rr-cache` at all, so merge-tree's verdict
(51 of 73 branches clean, 22 conflicting) was exactly right. The cache now holds
~40 recorded resolutions, and from here merge-tree will report conflicts that
rerere silently fixes. That is why the detect job is **two-phase** — merge-tree
screens cheaply, and anything it flags gets a real worktree merge with rerere
replayed. It is not an optimisation; it is load-bearing the moment the cache is
non-empty.

**Never merge a PR-backed branch whose base predates the mirror.** The merge
drags its stale base across everything already integrated and conflicts in files
the branch never touched — one branch touching three files under
`features/messages` conflicted on four unrelated `DeveloperSettings` files. PR
branches must not be rebased, so the script cherry-picks their unique commits
instead. **Signature to watch for:** conflicts that look topically unrelated to
what the branch does.

**Mechanical "keep both sides" resolution is not safe on its own.** It silently
spliced two generations of `CodeBlockOverlay` together: duplicate
`CodeBlockCopyButtons` and `computeCodeBlockBounds` definitions, a caller passing
both APIs at once, and an off-by-one brace. Two checks are needed after any
automatic resolution, and **neither alone is sufficient**:

1. brace balance + no conflict markers
2. **no duplicate top-level declarations** — this caught a third damaged file
   that check 1 passed clean, because the union emitted a function twice with
   identical bodies and balanced braces

A real parse would catch both and is the better long-term answer.

**The toolchain must be a JDK 21 with a compiler.** A JRE-only installation on
the toolchain path fails while *configuring the root project* with
`does not provide the required capabilities: [JAVA_COMPILER]`, which reads like
a project fault. The script now checks for this first.

**Upstream absorbs this fork continuously, and that reshapes branches.** During
this work upstream merged PR #7539 and had already taken the message-search
matrix layer (#7249) behind `FeatureFlags.MessageSearch`. The search branches
therefore conflict by re-adding what upstream now ships; the resolution is to
keep upstream's version of upstream logic and merge only the fork's UI on top.
