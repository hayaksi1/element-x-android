# Fork rules

Rules for anyone — human or agent — working in `hayaksi1/element-x-android`.
Read this before touching git. Longer explanation lives in `.fork/README.md`.

## Branch model

```
upstream/develop ──► develop            pristine mirror. ff-only. Never a fork commit.
                       ├── feat/fork-tooling   .fork/ + workflows. Merged FIRST.
                       ├── feat/<slug>         fork-only work. REBASED each sync.
                       └── fix/<n>-<slug>      head of an OPEN upstream PR.
                                               MERGED AS-IS. Never rebased.
                             ↓
                          master        develop + every branch. Rebuilt from
                                        scratch each run. Disposable.
```

`master` is the branch you build and install. It is **the accumulated app** —
the role `develop` used to play.

## Never commit to `develop`

`develop` is a byte-exact mirror of `upstream/develop`. It must fast-forward,
so a single fork commit breaks every future sync.

If asked to "just commit this to develop", that is a mistake — say so, and put
the work on a feature branch instead. Two layers enforce it: `develop` is
**never checked out** (a branch nobody has checked out cannot be committed to by
accident — the script moves it with `git update-ref`), and a `pre-commit` hook
refuses commits on it. Do not bypass either with `--no-verify`.

## Where a change goes

| Change | Destination |
| :--- | :--- |
| New feature | new `feat/<slug>` cut from `develop`, added to `.fork/features.txt` |
| Bug in an existing feature | that feature's **own branch**, then rebuild |
| Fix to an open upstream PR | that **PR's branch**, never anywhere else |
| Cross-feature / integration-only fix | commit on `master`, then **immediately** export it into `.fork/integration-patches/` and commit that to `feat/fork-tooling` — otherwise the next rebuild deletes it |
| Sync tooling | `feat/fork-tooling` |

**Never commit tooling changes to `master`.** It is rebuilt from scratch; such a
commit is deleted with no way to recover it.

**`feat/fork-tooling` is append-only.** It is pushed and other work quotes line
numbers against it, so never amend, rebase, squash, reorder or force-push it —
correct it with a new commit on top.

## The two manifests get opposite treatment

- `.fork/features.txt` — fork-only branches. **Rebased** onto `develop`.
- `.fork/pr-branches.txt` — heads of open upstream PRs. **Merged as-is.**
  Never rename, rebase, amend or force-push these: element-hq maintainers push
  commits directly onto them, and rewriting detaches review threads and
  re-fires their CI.

A branch in **both** manifests is a bug; the script hard-fails on it. A branch on
`origin` in **neither** is silently never merged into `master`;
`.fork/unmanaged-branches.txt` is the acknowledged set, and anything appearing on
`origin` after that seed is reported.

**Never regenerate a manifest by overwriting it.** The obvious recipe —
`gh pr list --state open ... > pr-branches.txt` — drops every closed-but-unmerged
branch on the floor and hands back a clean-looking file that has quietly lost work.
Query `--state all`, diff it against the manifest, and *add* what is new. A line
leaves a manifest only under the retention rule below.

## Branch retention

**A branch may be deleted only if it is provably merged.** Everything else stays:
closed-but-unmerged PR branches, abandoned branches, experiments, and every branch
in `.fork/unmanaged-branches.txt`. This is the *only* licence to shrink the branch
set, and it is **not** licence to fold, rename, squash or consolidate anything —
branch identity is the thing the rule protects, so a "tidy them into one
`feat/fork-misc`" plan destroys exactly what it is there to preserve.

Provably merged means GitHub reports the PR `MERGED` **and** at least one of these
two mechanical proofs passes:

```bash
git merge-base --is-ancestor origin/$b upstream/develop   # A: literal ancestor
git cherry upstream/develop origin/$b | grep -c '^+'      # B: 0 => every patch absorbed
```

Proof B is the one that catches a squash-merge, where the tip is an ancestor of
nothing upstream yet every patch has an equivalent there. Read B's printed count,
never the exit status: `grep -c` exits 1 when the count is 0, which is the *passing*
case, so a `&&` chain or `set -e` inverts the answer.

**GitHub's `MERGED` is a signal, never the proof.** A squash-merged PR reads
`MERGED` while its tip is an ancestor of nothing; a merged PR whose commit was later
*reverted* upstream reads `MERGED` forever. If GitHub says merged and both proofs
fail, the branch is **not** prunable — report it and leave it.

Before anything is deleted, make it recoverable and make the record durable:

```bash
git update-ref "refs/fork/archive/$b" "$(git rev-parse "origin/$b")"
git push origin "refs/fork/archive/$b:refs/fork/archive/$b"
```

then append a row to the tracked `.fork/archived-branches.tsv` — branch, sha, PR
number, which proof passed, date. The ref is the recovery handle; the TSV is the
record that survives a fresh clone.

**Then stop and ask.** Deleting a remote branch moves a remote ref, and that has
always needed the owner's explicit approval. The sync script itself never deletes
or renames a branch, and that stays true — retirement is reported, never performed.

## Syncing is `.fork/sync-upstream.sh` and nothing else

No ad-hoc `git merge upstream/develop`. After changing any branch, rebuild with
the script — never by hand-merging.

```bash
.fork/sync-upstream.sh --dry-run     # see what would happen
.fork/sync-upstream.sh               # real run
.fork/sync-upstream.sh --continue    # resume after resolving a conflict
```

## Conflict policy

Resolve inside the **feature branch's** rebase, where the context is small —
never inside one giant integration merge. Keep upstream's version of upstream
logic and re-apply our intent on top. **Never blanket `-X ours`/`-X theirs`**:
it silently discards work and makes a branch look like it contributed nothing.

Snapshot PNGs are the exception: neither side is correct, so they resolve
mechanically and are re-recorded afterwards.

## Writing code so it does not conflict

- **New behaviour → a new Gradle module.** `features/<name>/{api,impl}` is
  auto-discovered by `settings.gradle.kts` and auto-wired onto `:app` by
  `allFeaturesImpl()`. **Zero upstream edits.** This is the strongest lever here.
- **Replacing upstream behaviour → a Metro binding**, from that new module:
  `@ContributesBinding(AppScope::class, replaces = [TheirImpl::class])`.
  No edit to the upstream class.
- **Strings → your own module's `res/`**, or a new `values/fork_strings.xml`.
  Never hand-edit `localazy.xml`; prefer not to touch `temporary.xml` either
  (it is the fork's #2 conflict generator). Prefix fork keys.
- **Branding / icons / applicationId → flavour source sets**, not edits to
  `main` or `app/build.gradle.kts`.
- **Config constants → `appconfig/`**, not scattered across features.
- Touch `gradle/libs.versions.toml` **as little as possible**; prefer
  upstream's versions. Today the fork touches it zero times — keep it that way.
- Never commit `.idea/` changes, screenshot churn, or a submodule pointer bump
  as part of a feature.
- Keep commits small and single-purpose.

## Submodule

`enterprise` is **inaccessible** (private, no key) and must stay uninitialised.
`isEnterpriseBuild = File("enterprise/README.md").exists()` → false selects the
FOSS build, which is what we want and what the goldens were recorded under.
Always take upstream's gitlink verbatim. **No feature branch may move it.**

## Commit convention

Every fork commit carries a trailer:

```
Fork-Feature: <slug>
```

so the fork's work is always greppable: `git log --grep="Fork-Feature:"`.

## Force-push policy

`--force` is banned outright. `--force-with-lease` only, and only for rebased
`feat/*`. **Never** for a branch in `pr-branches.txt`.

**`master` and `develop` are pushed plain, with no force of any kind.** The sync
grafts each rebuild onto the previous `master` tip, so the push is a genuine
fast-forward; `develop` only ever fast-forwards to `upstream/develop`. A rejected
push there is a real signal — someone pushed, or the graft parented a stale tip —
and forcing past it destroys the previous published build. Fetch and investigate.

## Rolling back

Every successful sync tags its `master` tip `sync/<YYYYMMDD-HHMM>`. **That tag is the
rollback point.** Roll back by restoring its tree onto the current tip so the branch
still fast-forwards:

```bash
GOOD=sync/<YYYYMMDD-HHMM>; BAD=$(git rev-parse origin/master)
git checkout master && git reset --hard "$BAD"
new=$(git commit-tree "$GOOD^{tree}" -p "$BAD" -m "rollback: restore $GOOD")
git update-ref refs/heads/master "$new" "$BAD"
git diff "$GOOD" master && git push origin master
```

**Never roll `master` back to a `backup/develop-*` tag.** Those snapshot the *old
`develop`* from before `master` existed and contain none of the integrated branches;
restoring one discards every branch the fork has integrated. They are regression
baselines, nothing more.

## Verification before push

All of these — `./gradlew test` alone silently skips konsist and Paparazzi,
the two things this fork breaks most:

```
:app:assembleGplayDebug app:assembleFDroidDebug -PallWarningsAsErrors=true
:app:testGplayDebugUnitTest testDebugUnitTest -x :tests:konsist:testDebugUnitTest
:tests:konsist:testDebugUnitTest --rerun
:tests:uitests:verifyPaparazziDebug
detekt ktlintCheck :app:lintGplayDebug
```

**Never weaken a guard to get a green run.** Every one of these exists because
that exact failure happened and nothing noticed. Guards get stricter, allowlists
shrink, and a stated limit is a documented boundary rather than a knob.

## Secrets

Keystores, `signing.properties`, service-account JSON, Localazy/Sentry tokens
never enter the repo. (`app/signature/*.keystore` are upstream's own files.)

## First 60 seconds

```bash
git fetch upstream --prune && git fetch origin --prune
cat .fork/features.txt .fork/pr-branches.txt
git rev-list --left-right --count upstream/develop...master
git log --oneline upstream/develop..develop   # MUST be empty
.fork/sync-upstream.sh --dry-run
```
