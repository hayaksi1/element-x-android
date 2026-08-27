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
