# Phase 2 — Plan

Status: **awaiting owner approval.** Nothing here has been executed.
Baseline re-measured 2026-08-28 after `develop` moved mid-audit.

---

## 0. Live-state warning — read this first

`develop` **moved while the audit was being written**:

```
423e884db5   audit baseline (2026-08-27 15:36)
  ef4e7723b9   Give the removal confirmation the dialog the team asked for   (cherry-pick 23:07)
  502b130548   Update screenshots                                            (cherry-pick 23:08)
```

`origin/develop` moved with it. Upstream also moved — its tip is now
`3ec30d7c94 Merge pull request #7539 from hayaksi1/fix/5356-sender-name-fallback`,
i.e. **upstream absorbed another fork PR during the audit.**

Refreshed baseline:

| Metric | Audit | Now |
| :--- | ---: | ---: |
| ahead / behind `upstream/develop` | 236 / 130 | **238 / 143** |
| non-merge fork commits on `develop` | 169 | **171** |
| merge commits | 67 | 67 |
| net files changed | 595 | **597** |

Neither new commit exists on any feature branch — they are develop-only, and
they appeared at a rate of **~2 commits per 2 hours** while other sessions work.

**Consequence for the plan:** the pollution is not historical, it is *ongoing*.
A reset that is not accompanied by a mechanism to stop other agents committing
to `develop` will be undone within hours. §4 addresses this directly.

---

## 1. Target model

```
upstream/develop ──► develop              pristine mirror, ff-only, never a fork commit
                       ├── feat/fork-tooling      .fork/ + workflows + rerere cache (merged FIRST)
                       ├── feat/<a>               fork-only work, REBASED each sync
                       ├── feat/<b>
                       └── <pr-backed branches>   MERGED AS-IS, never rebased/renamed
                             ↓
                          combined            rebuilt from scratch every run, disposable
```

Two manifests, opposite treatment, hard-fail if a branch appears in both:

| Manifest | Contents | Treatment |
| :--- | :--- | :--- |
| `.fork/features.txt` | fork-only branches | `git rebase --onto develop` |
| `.fork/pr-branches.txt` | heads of open upstream PRs | `git merge --no-ff`, **never rebased** |

---

## 2. Branch disposition

| Class | Count | Action |
| :--- | ---: | :--- |
| PR-backed (open upstream PR) | **50** | into `pr-branches.txt`, names frozen |
| Fork-only, live | **25** | into `features.txt`, rebased (excl. the aggregate below) |
| `fix/developer-options-toggle` | 1 | aggregate of 165 commits — **prune** |
| Fully absorbed upstream (`ahead == 0`) | **58** | **prune** (after retirement check) |
| Aggregates / scratch (`batch*`, `rebuild`, `audit-*`, `pr7*`, `wip/*`, `work/*`) | ~17 | **prune** |
| Develop-only feature commits with no branch | **23 + 2 new** | see §3 |

Deletion is **local-only in this phase.** No remote branch is deleted without a
separate, explicit approval listing refs and SHAs.

---

## 3. The develop-only commits

171 non-merge commits classified by `git patch-id --stable`:

| Bucket | Count | Disposition |
| :--- | ---: | :--- |
| Exact patch-id match to a live branch | 92 | already safe — drop develop's copy |
| Drifted (branch exists, develop's copy stale) | 29 | already safe — branch is authoritative |
| **Develop-only feature work** | **23 (+2 new)** | **needs a decision — see below** |
| Glue / noise | 16 | → `.fork/integration-patches/` or dropped |
| Already upstream (patch-id) | 8 | drop |

The develop-only work is real user-facing behaviour — conversation-channel
thread notifications, image-compression relaxation, encryption-badge hiding,
wildcard mime types, focused-field keyboard handling, the new removal-confirmation
dialog. **This is the one place I want an explicit decision from you** (§8 Q1).

---

## 4. Making the rule stick — the part that actually matters

The brief's model fails if other agents keep cherry-picking onto `develop`.
Three layers, cheapest first:

1. **Soft cutover, not hard.** Rename today's polluted `develop` to `combined`
   *first*, then create a fresh `develop` from `upstream/develop`. Nobody's
   in-flight work sits under a ref that vanishes; a session that pushes to
   `combined` is doing the right thing by accident.
2. **A local `pre-commit` hook** installed by `.fork/setup-local-git.sh` that
   refuses any commit while `HEAD` is `develop`, with a message naming the
   correct destination. This is what stops an *agent* — agents read error
   messages, they do not reliably read rules files.
3. **Branch protection on `origin/develop`** (owner action, §9) so a push that
   slips past the hook is rejected server-side.

Layer 2 is the load-bearing one. Layers 1 and 3 are cheap insurance.

---

## 5. Execution order

Each step verified before the next.

| # | Step | Verification |
| ---: | :--- | :--- |
| 1 | **Quiesce.** Confirm no peer session holds uncommitted work or is mid-cherry-pick. Re-check `git status --porcelain` and every linked worktree. | all clean; peers acknowledged |
| 2 | **Backup.** `git tag backup/develop-<ts> develop`; push tag. Record `enterprise` gitlink SHA (`e633a343b1`). | tag resolves on `origin`; SHA printed |
| 3 | **Snapshot.** `git branch combined develop`; push `-u`. | `combined == 502b130548` |
| 4 | **Build `feat/fork-tooling`** from `upstream/develop`: `.fork/` scripts, manifests, rerere cache, `FORK_RULES.md`, the one-line `CLAUDE.md`/`AGENTS.md` import, workflows. | script is shellcheck-clean; `--dry-run` runs |
| 5 | **Populate manifests** from the measured 50/25 split. | script hard-fails on a deliberate duplicate entry |
| 6 | **Reset `develop`** to `upstream/develop`; `push --force-with-lease`. | `git log upstream/develop..develop` empty |
| 7 | **Rebase the 25 fork-only branches** onto `develop`, one at a time. | per-branch diff contains only that feature; no gitlink change |
| 8 | **Rebuild `combined`** via the script. | gates pass (§6) |
| 9 | **Add CI** (detect + publish). | `--dry-run` in CI; detect opens exactly one issue |

Step 6 is the only destructive step, and it is gated on step 3 succeeding.

---

## 6. Verification gates — all four, explicitly

A gate that runs `./gradlew test` **silently skips konsist and Paparazzi**, the
two things this fork breaks most. The script runs:

```bash
./gradlew :app:assembleGplayDebug app:assembleFDroidDebug -PallWarningsAsErrors=true
./gradlew :app:testGplayDebugUnitTest testDebugUnitTest -x :tests:konsist:testDebugUnitTest
./gradlew :tests:konsist:testDebugUnitTest --rerun          # konsist caches stale; force it
./gradlew :tests:uitests:verifyPaparazziDebug
./gradlew detekt ktlintCheck :app:lintGplayDebug
```

`--skip-verify` exists for iteration and **blocks push**.

---

## 7. Submodule policy — (a), enforced

**Always take upstream's `enterprise` gitlink verbatim; never initialise it;
hard-fail any branch that moves it.**

Justification, measured: the owner has no access (SSH no key, HTTPS 404);
`isEnterpriseBuild = File("enterprise/README.md").exists()` is false without it,
selecting the FOSS build we want; upstream's own CI skips the submodule for fork
PRs; and **zero** of the 76 live branches or 171 develop commits touch the
gitlink today. The policy preserves a property we already have.

Enforcement: `git config submodule.recurse false`, plus a script check that
`git diff --name-only <base>...<branch>` never contains `enterprise`.

---

## 8. Decisions I need from you

**Q1 — the 23+2 develop-only feature commits.** (a) one `feat/*` branch per
coherent group (~6-8 branches), (b) a single `feat/fork-misc` bucket, or
(c) leave them on the backup tag only. I lean (a) for the coherent clusters and
(b) for the true one-offs — but these are your features and I will not guess at
their intent.

**Q2 — remote branch deletion.** The 58 absorbed + ~17 aggregate branches also
exist on `origin`. Delete them remotely now, or local-only and leave `origin`
alone? I default to **local-only** until you say otherwise.

**Q3 — default branch switch.** Scheduled workflows run only from the default
branch, and `develop` must stay pristine. Switching the fork's default to
`combined` is the standard fix — but I am verifying whether that affects the 50
open upstream PRs before recommending it.

---

## 9. Manual steps for you (not automatable)

- Switch fork default branch to `combined` (pending Q3 verification).
- Enable branch protection on `origin/develop`.
- No new secrets needed: detect/publish use `GITHUB_TOKEN`; the `enterprise`
  deploy key is deliberately unused.

---

## 10. Rollback

Two different rollbacks, and confusing them destroys the app.

**A bad sync** — the routine case. Every successful run tags its `master` tip
`sync/<YYYYMMDD-HHMM>`. `master` is fast-forward-only, so restore the old tree with a
new commit rather than a reset:

```bash
git fetch origin --tags
GOOD=sync/<YYYYMMDD-HHMM>; BAD=$(git rev-parse origin/master)
git checkout master && git reset --hard "$BAD"
new=$(git commit-tree "$GOOD^{tree}" -p "$BAD" -m "rollback: restore $GOOD")
git update-ref refs/heads/master "$new" "$BAD"
git diff "$GOOD" master && git push origin master
```

**The cutover itself** — historical. `backup/develop-<ts>` snapshots the *old
`develop`*, from before `master` existed; it holds none of the integrated branches, so
it is never a rollback target for `master`:

```bash
git push --force-with-lease origin backup/develop-<ts>:develop
```

Feature branches are untouched either way. The backup tag is immutable and pushed
before step 6.

---

# Phase 2 addendum — findings from delegated research

Three sessions reported. Two overturned my design; one overturned a decision in
the brief. All claims below are **measured**, with the measuring session named.

## A. BLOCKER — Issues are disabled on the fork (e1, re-verified by f5)

```
gh api repos/hayaksi1/element-x-android --jq '{has_issues,visibility}'
  {"has_issues":false,"visibility":"public"}
```

**The entire one-issue-ever design cannot run.** Owner must flip repo
Settings → Features → Issues, or run
`gh api -X PATCH repos/hayaksi1/element-x-android -f has_issues=true`.

## B. BLOCKER — the pollution is a standing order (3e/Fable, verified by f5)

`memory/every-branch-also-lands-on-develop.md` is a 🔴 owner standing command
quoting the owner: *"When i create a branch, you should always send also to
develop branch."* Every session loads it. It must be rewritten before any ref
moves, or `develop` is repolluted within the hour — correctly, per instructions.
Two dependent memories: `build-release-apk-for-phone`,
`search-feature-lives-on-feature-branch`.

## C. Snapshots — my design AND Fable's were both wrong (73, experimental)

Undefined `merge=lfs` falls back to **text merge**, not binary. Git silently
ignores a wholly-absent driver section. Consequence:

```
$ git add foo.png && git commit
$ git lfs ls-files      →  911547e8f6 * foo.png     # looks healthy
$ cat .git/lfs/objects/91/15/911547e8...
version https://git-lfs.github.com/spec/v1
<<<<<<< HEAD
```
**A structurally valid LFS pointer whose payload is conflict-marker text.**
`git lfs fsck` passes. Nothing notices until Paparazzi fails to decode a PNG.
Any nightly job resolving with `git add -A` ships 288 of these.

**Decision: `.git/info/attributes` gets `**/snapshots/**/*.png merge=binary`**
(uncommitted, overrides `.gitattributes`, matches the brief's §4.4 requirement).
Equivalent `merge.lfs.driver 'false'` is the measured fallback. 73 is verifying
the `merge=binary` variant now.

Rejected — **Fable's take-theirs driver**: safe for data, but it launders the
problem. It manufactures the F-case below on all 288 snapshot paths.

Kept from Fable: re-record **only the conflicted modules**, then
`verifyPaparazziDebug` over everything. A full regen every run is *tautological*
— it verifies what it just wrote, so the gate never catches anything.

## D. Retirement — (d) and (e) have false positives (73, fixture-tested)

The decisive case: branch **F** carries real un-upstreamed work, its merge
conflicts, auto-resolution takes ours, `git diff --quiet HEAD^1 HEAD` is EMPTY →
**F is wrongly retired and its work is unrecoverable.**

Adopted, in order:
```bash
git merge-base --is-ancestor "$b" upstream/develop        && retire   # zero FP
[ -z "$(git cherry upstream/develop "$b" | grep '^+')" ]  && retire   # zero FP
git merge --no-ff "$b"; [ $? -eq 0 ] && git diff --quiet "$before" HEAD && flag_for_review
```
Step 3 is **gated on merge exit 0** — that gate is what closes the F-hole. It
also bars `-X ours` and any always-take-one-side driver from the pipeline.
Residual: absorbed-modified branches never auto-retire. False negative — the
affordable direction.

## E. `git merge-tree` — the brief's ban was right for the wrong repo (e1, verified by f5)

Spot-checked on real branches here:

| branch | exit | conflicted paths |
| :--- | ---: | ---: |
| `fix/4388-media-upload-progress` | 0 | 0 |
| `fix/943-permission-rationale` | 0 | 0 |
| `feature/message-search` | 1 | 46 |
| `fix/6031-pin-keypad-randomiser` | 0 | 0 |

`merge-tree --write-tree` performs a **full real merge in the object database** —
no worktree, no checkout, no LFS smudge. It is accurate. The element-web false
positives came from one specific gap: **`merge-tree` cannot consult rerere.**

This repo has **no rr-cache and `rerere.enabled` unset**, so merge-tree is
currently ground truth. Once a cache is populated it would over-report.

**Two-phase design honours the brief and is far cheaper:** `merge-tree` screens
all branches → only the conflicting subset gets a real worktree merge with
rerere replayed. Every branch that matters still gets a real merge.

## F. Default branch — orphan `ci` branch, not `combined` (e1)

`schedule` only runs workflows present on the default branch (GitHub docs,
quoted). Options:
- **`combined`** — PUBLISH rebuilds it from scratch; if a rebuild ever drops
  `.github/workflows/`, the schedule dies silently. Self-deleting foot-gun.
- **`develop`** — would carry a fork commit; kills the ff-only mirror.
- **orphan `ci` branch** holding only `.github/workflows/` ✅ — mirror stays
  byte-exact, `combined` stays freely rebuildable, nothing force-pushes it.

**All 50 open PRs are unaffected** either way: base is `element-hq:develop`,
head is `hayaksi1:<branch>`; the fork's default branch is not part of that
pointer. Verified across all 50 rows.

## G. Corrections to my own plan

- `cache-read-only: ${{ github.ref != 'refs/heads/combined' }}` is a **no-op** —
  scheduled runs always report `github.ref` = default branch, so it is always
  true and the cache would never be written. Drop it.
- Issue lookup must filter by a dedicated `fork-sync` **label**, never
  `--search` (fuzzy full-text, matches unrelated issues).
- Conflict-set state goes in an **HTML comment** in the issue body, hashed over
  the **sorted** branch list — unsorted would read as "changed" every night.
- There is **no amber**. `neutral` is settable only by a GitHub App via the
  Checks API. Exit 0 → green, full stop.
