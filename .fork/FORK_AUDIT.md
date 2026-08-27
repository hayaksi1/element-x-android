# Fork Audit — hayaksi1/element-x-android

Generated 2026-08-27. Phase 1 (read-only investigation). No refs were changed;
the only write was this file. `upstream` remote already existed and was fetched.

---

## 0. State of the fork — summary

**Your fork is in far better shape than the brief assumed.** Three of the four
"permanent conflict generator" categories you asked me to hunt for have **zero**
commits behind them. The pain you are feeling is real, but it comes from a
different source than you think.

| Assumption in the brief | Reality |
| :--- | :--- |
| `gradle/libs.versions.toml` is a conflict source | **0 of your commits touch it** |
| `CHANGES.md` is a conflict source | **0 commits** |
| `.github/workflows/*` is a conflict source | **0 commits** |
| `.idea/` churn leaks into commits | **0 commits** |
| Stray `enterprise` submodule pointer bumps | **0 commits, on develop and on all 76 feature branches** |
| Localazy strings get hand-edited | **0 commits touch `localazy.xml`** |
| Features live only as commits on `develop` | **76 feature branches already exist** |

What actually hurts:

1. **`develop` cannot fast-forward.** 236 commits ahead / 130 behind
   `upstream/develop`, built from **67 merge commits**. This is the root cause
   you correctly identified.
2. **Screenshot snapshots.** 288 distinct PNGs, 348 touches, 21 dedicated
   "Update screenshots" commits. This is your #1 real conflict generator.
3. **`temporary.xml`.** 18 commits across 9 copies of the file. Your #2.
4. **Hot code files** where several features overlap — `CodeBlockOverlay.kt`
   (11 commits), `ToHtmlDocument.kt` (9), `MessagesPresenter.kt` (5).
5. **Upstream keeps absorbing your work**, silently invalidating branches.
   **58 local branches now contain nothing upstream doesn't already have.**

### Headline numbers

| Metric | Value |
| :--- | :--- |
| `develop` vs `upstream/develop` | **236 ahead, 130 behind** |
| Merge-base | `6ab3d7393b` (2026-08-24) |
| Non-merge commits of yours on `develop` | **169** |
| Merge commits on `develop` | **67** |
| Net diff | **595 files, +12 169 / −892** |
| Net diff excluding snapshots | **314 files, +11 538 / −464** |
| Snapshot PNGs in the net diff | **281** (all Git LFS) |
| New files the fork adds | **68** |
| Upstream files the fork modifies | **246** ← the true conflict surface |
| Local branches | 153 |
| — with unique work | **76** |
| — fully absorbed by upstream (prunable) | **58** |
| — stale (>3 months) | **0** |

---

## 1. Environment and repo health

| Check | Result |
| :--- | :--- |
| Working tree | **clean** (`git status --porcelain` empty) |
| Submodule `enterprise` | **uninitialised** (`-e633a343b1 enterprise`) — not dirty, just never checked out |
| `git lfs` | **git-lfs/3.7.1** installed; 4 377 LFS objects resolve |
| Secrets | **none introduced by the fork** — see below |
| Linked worktrees | **7** (2 permanent under `/home/jack/`, 5 session scratch) |
| Peer sessions in this checkout | **4 busy** at audit time ⚠ |

### The `enterprise` submodule is inaccessible — and that is fine

```
git@github.com:element-hq/element-android-enterprise.git  → Permission denied (publickey)
https://github.com/element-hq/element-android-enterprise  → Repository not found (private)
```

You confirmed you have no access. **This breaks nothing.** Upstream's own CI
deliberately skips the submodule for fork PRs:

```yaml
# .github/workflows/tests.yml:57-64 (same block in quality.yml, danger.yml, release.yml)
- name: Add SSH private keys for submodule repositories
  uses: webfactory/ssh-agent@...
  if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == 'element-hq/element-x-android' }}
  with:
    ssh-private-key: ${{ secrets.ELEMENT_ENTERPRISE_DEPLOY_KEY }}
- name: Clone submodules
  if: ${{ ... same condition ... }}
  run: git submodule update --init --recursive
```

The FOSS build path is selected by `plugins/src/main/kotlin/Enterprise.kt:14`:

```kotlin
val isEnterpriseBuild = File("enterprise/README.md").exists()
```

An empty `enterprise/` directory means `isEnterpriseBuild == false`, which is
exactly the build you want. **No Gradle task you need is broken.** Only
`:enterprise:*` modules and `build_enterprise.yml` are unavailable, and you use
neither.

> **Policy implication:** the correct submodule policy is *(a) always take
> upstream's gitlink verbatim, never initialise it, and hard-fail any feature
> branch that moves it.* No feature branch moves it today — this policy
> preserves a property you already have rather than fixing a problem.

### Secrets — clean, with one thing to know

Two keystores are tracked:

```
app/signature/debug.keystore    upstream blob 4a15fc9eca == ours 4a15fc9eca
app/signature/nightly.keystore  upstream blob a0e9ba413b == ours a0e9ba413b
```

**Both are upstream's own files and byte-identical to upstream's copies.** Your
commits never touch `app/signature/`, any `*.keystore`, or `signing.properties`.
No secret scan hit anywhere in your 169 commits. **No action needed, and
emphatically no history rewrite.**

### Build and quality gates — extracted, not assumed

| Gate | Exact command | Source |
| :--- | :--- | :--- |
| Assemble debug | `./gradlew :app:assembleGplayDebug app:assembleFDroidDebug -PallWarningsAsErrors=true` | `build.yml:74` |
| Unit tests | `./gradlew :app:testGplayDebugUnitTest testDebugUnitTest -x :tests:konsist:testDebugUnitTest` | `tests.yml:76` |
| Konsist | `./gradlew :tests:konsist:testDebugUnitTest --no-daemon` | `quality.yml:120` |
| Lint | `./gradlew :app:lintGplayDebug :app:lintFdroidDebug lintDebug --continue` | `quality.yml:199` |
| Detekt | `./gradlew detekt --no-daemon` | `quality.yml:240` |
| ktlint | `./gradlew ktlintCheck` | `quality.yml:281` |
| Screenshot **verify** | `./gradlew :tests:uitests:verifyPaparazziDebug` | `tests.yml:79` |
| Screenshot **record** | `./gradlew removeOldSnapshots && ./gradlew recordPaparazziDebug && ./gradlew removeOldScreenshots && ./gradlew :libraries:compound:recordRoborazziDebug` | `scripts/recordScreenshots.sh:55-64` |
| Umbrella | `./gradlew runQualityChecks` | `build.gradle.kts:176` |

- **Flavours:** one dimension `store` → `gplay` (default) + `fdroid`.
  Build types: `debug`, `release`, `nightly`.
- **JDK 21** (temurin), AGP 9.3.1, Kotlin 2.4.10, compileSdk/targetSdk 37.
- **LFS in CI** is `nschloe/action-cached-lfs-checkout@v1.2.5`, *not*
  `actions/checkout` with `lfs: true`. `validate-lfs.yml` runs
  `./tools/git/validate_lfs.sh` on every PR.
- ⚠ Note the typo you must reproduce verbatim: `app:assembleFDroidDebug`
  (capital D, no leading colon) in `build.yml`, but `assembleFdroidRelease`
  (lowercase d) in `release.yml`.
- **Scheduled workflows run from the default branch only** — `nightly.yml`
  (`0 4 * * *`), `nightlyReports.yml` (`0 5 * * *`) and four others assume
  `develop`. This is the caveat behind §4.6's default-branch switch.

---

## 2. Git topology

`upstream` = `https://github.com/element-hq/element-x-android.git`, fetched with
`--prune`. `origin` = `https://github.com/hayaksi1/element-x-android.git`.

```
merge-base   6ab3d7393b  2026-08-24  Merge PR #7447 from hayaksi1/fix/6518-encryption-indicator
develop      423e884db5  2026-08-27  Update screenshots              (236 ahead / 130 behind)
upstream/dev eb946c6daf  2026-08-27  Merge PR #7583                  
```

An existing tag `backup/pre-sync-develop` is already present but **does not
point at today's tip** — a fresh timestamped backup is still required.

### Branch classes

| Class | Count | Disposition |
| :--- | ---: | :--- |
| Live feature branches with unique work | **76** | keep → become `feat/*` |
| Fully absorbed by upstream (`ahead == 0`) | **58** | **prune** |
| Aggregate / scratch (`batch*`, `rebuild`, `audit-*`, `pr7*`, `wip/*`, `work/*`) | ~17 | **prune** |
| Backup refs | 2 | keep |
| Stale (>3 months) | **0** | — |

**58 branches are dead.** Upstream merged your PRs — for many, the *exact SHAs*
are now reachable from `upstream/develop`. Example: `fix/4639-system-theme` tip
`ddd89f46df` (authored by you) is an ancestor of both `upstream/develop` and
`upstream/main`. That is upstream taking your commit verbatim.

---

## 3. Change-surface analysis

### 3.1 Where your 169 develop commits came from

I matched every commit three ways — subject, SHA-containment and **`git patch-id
--stable`** (authoritative). Results:

| Bucket | Count | Meaning |
| :--- | ---: | :--- |
| **Exact patch-id match** to a live feature branch | **92** | already safely captured on 55 branches |
| **Drifted** — same subject, patch moved during rebase | **29** | branch exists; develop's copy is stale |
| **Develop-only feature work** | **23** | needs a home |
| **Glue / noise** | **16** | drop or convert to integration patches |
| **Already in upstream** (patch-id) | **8** | drop |
| Screenshot-only | **1** (+20 folded into features) | keep with its feature |

**Conclusion: your features are already branch-shaped.** This is not a
"reconstruct 169 orphan commits" job. It is a *"stop merging them into develop"*
job. That massively de-risks Phase 3.

### 3.2 Conflict hot-spot map (ranked by number of your commits)

| # | File |
| ---: | :--- |
| 11 | `features/messages/impl/.../event/CodeBlockOverlayTest.kt` |
| 11 | `features/messages/impl/.../event/CodeBlockOverlay.kt` |
| 9 | `libraries/matrixui/.../messages/ToHtmlDocument.kt` |
| 7 | `features/messagesearch/impl/.../MessageSearchPresenter.kt` |
| **6** | **`libraries/ui-strings/src/main/res/values/temporary.xml`** |
| 6 | `libraries/matrixui/.../ToHtmlDocumentTest.kt` |
| 6 | `libraries/matrix/impl/.../search/backfill/SearchBackfillWorker.kt` |
| 6 | `features/messages/impl/.../factories/TimelineItemsFactoryTest.kt` |
| 6 | `features/messages/impl/.../event/TimelineItemTextView.kt` |
| 5 | `libraries/mediaupload/impl/.../AndroidMediaPreProcessor.kt` |
| 5 | `features/preferences/impl/.../developer/DeveloperSettingsView.kt` |
| 5 | `features/messages/impl/.../MessagesView.kt`, `MessageComposerPresenter.kt` |
| 4 | the four `AppPreferencesStore` / `SessionPreferencesStore` files (api+impl+test) |

1 017 distinct files are touched across your commits; 246 of them are
*modifications to upstream files* — that number is the honest measure of your
recurring conflict debt.

### 3.3 Known conflict generators — measured, not assumed

| Path | Your commits | Verdict |
| :--- | ---: | :--- |
| `gradle/libs.versions.toml` | **0** | ✅ non-issue |
| `CHANGES.md` | **0** | ✅ non-issue |
| `.github/workflows/*` | **0** | ✅ non-issue |
| `.idea/` | **0** | ✅ non-issue |
| `localazy.xml` | **0** | ✅ non-issue |
| `enterprise` gitlink | **0** (develop **and** all 76 branches) | ✅ non-issue |
| `**/temporary.xml` | **18** across 9 files | ⚠ **real generator** |
| `tests/uitests/**/snapshots/*.png` | **348 touches / 288 files** | ⚠ **top generator** |

**Snapshots are all LFS-tracked** (`.gitattributes:3`
`**/snapshots/**/*.png filter=lfs diff=lfs merge=lfs -text`), so conflicts there
are *pointer* conflicts — one line, always resolvable by re-recording. They must
never be hand-merged.

> ⚠ Screenshot commits are **not** droppable noise. `verifyPaparazziDebug` is a
> CI gate; deleting them turns the integration branch red. They belong *with the
> feature that changed the UI*, and are re-recorded after every rebase.

### 3.4 The 16 glue/noise commits

These exist only because features were merged into a shared `develop` and then
patched up afterwards. They are the textbook `.fork/integration-patches/` case:

`7ab9a14781` konsist + settings-view fixes on the merged tree · `f38affb0f4`
konsist for two cherry-picks · `c38e81d805` adapt to develop's event names ·
`cb69aef664` import ordering after an upstream merge · `710b36f526` adapt tests
to the reworked voice-recorder fake · `985693eb1b` + `0a59e41c00` PreviewParam
renames · `5af0a02b03` / `86b7d91be5` / `68f9a2caeb` licence-header churn on one
test file (three commits fighting each other) · `3d7e29665c` + `da3e2a9b4c`
*identical subject, committed twice* · `4780094481` comment removal ·
`4d68fb7509` redundant `@Inject` · `a53d4a2ca3` linkify test merge ·
`7b150329cb` design-system rename follow-up.

---

## 4. Android extension points — what a zero-edit fork can actually use

### ✅ The strongest lever is module auto-discovery, not product flavours

`settings.gradle.kts:54-72` auto-includes any directory under `features/`,
`libraries/`, `services/` that contains a `build.gradle.kts`:

```kotlin
fun includeProjects(directory: File, path: String, maxDepth: Int = 1) { ... }
includeProjects(File(rootDir, "features"), ":features")
```

and `plugins/src/main/kotlin/extension/DependencyHandleScope.kt:155-173` +
`app/build.gradle.kts:279` auto-wire every `:features:*:impl` onto `:app`:

```kotlin
fun DependencyHandlerScope.allFeaturesImpl(project: Project) = addAll(project, ":features", ":impl")
```

**A new `features/<name>/{api,impl}` module is included, compiled and DI-merged
with zero edits to any upstream file — not even `settings.gradle.kts`.**

Caveat: `allLibrariesImpl()` (`DependencyHandleScope.kt:87-127`) is a hardcoded
39-entry list, and `allServicesImpl()` likewise. A new `libraries/*` or
`services/*` module **does** need a 1-line upstream edit.

### ✅ Metro `replaces` works — but is unused here

Metro 1.4.2 (`libs.versions.toml:57`). The annotation as shipped:

```java
public interface dev.zacsweers.metro.ContributesBinding {
  Class<?> scope();  binding<?> binding();  Class<?>[] replaces();
}
```

Upstream binds on the **impl class** (341 `@ContributesBinding` sites), e.g.
`DefaultSystemClock.kt:15-16` — the replaceable shape. So

```kotlin
@ContributesBinding(AppScope::class, replaces = [DefaultSystemClock::class])
class MyClock : SystemClock
```

in a new `features/*/impl` module displaces upstream's binding with no upstream
edit. **Two honest caveats:** `replaces =` and `rank =` appear **0 times** in
this repo, so you would be first to exercise it; and this was verified from the
annotation signature in the jar, **not** from a compile (no Gradle was run).
Konsist does not constrain it.

### ⚠ Product flavours are weaker here than the brief assumes

- One dimension `store`, flavours `gplay`/`fdroid`.
- **`ls app/src/` → `main` and `test` only.** There are *no* flavour source sets
  on disk anywhere in the repo; the only flavour-scoped wiring is one line,
  `app/build.gradle.kts:285`.
- Adding a flavour still means editing `app/build.gradle.kts` (upstream file),
  plus literal `apk/gplay/...` paths in 5 workflows and
  `tools/manifest/gplay/release/aaptDump.txt`.

So flavours are **PARTIAL**, not the "single strongest lever". The module +
`replaces` path is strictly better here.

### ⚠ `appconfig/` has no DI seam

15 files of `object X { const val ... }`, read directly at 64 call sites. Not
injected → **cannot** be overridden; changing a default means editing the
upstream file. Branding lives in
`plugins/src/main/kotlin/config/BuildTimeConfig.kt:11-36` as checked-in
constants — upstream's own enterprise build *replaces this file in place*.
**INVASIVE.**

### ✅ Strings are free

`libraries/ui-strings/src/main/res/values/` merges every `values/*.xml`. A fork
can add `values/fork_strings.xml` — or better, keep strings in its own module's
`res/` — and touch neither `localazy.xml` nor `temporary.xml`. Only a duplicate
key collides, so prefix them.

### Classification

| Class | What qualifies |
| :--- | :--- |
| **MODULARIZABLE** (0 upstream edits) | New feature as `features/<name>/{api,impl}`; overriding any upstream `@ContributesBinding`/`@ContributesTo` via `replaces`; fork strings/resources in that module |
| **PARTIAL** (1–3 line edit) | New `libraries/*` or `services/*` module (hardcoded `allLibrariesImpl` list); new product flavour; custom launcher icon (the `isEnterpriseBuild` if/else, `app/build.gradle.kts:270-276`) |
| **INVASIVE** | `appconfig/` default changes (no DI seam, 64 consumers); branding via `BuildTimeConfig.kt`; behaviour changes *inside* an existing upstream presenter/view — which is what **most of your 76 branches actually are** |

**Sober conclusion:** your fork is ~76 small bug-fixes and UX changes *inside*
upstream's own presenters and views (`MessagesPresenter`, `TimelineItemsFactory`,
`DeveloperSettingsView`). Those are **INVASIVE by nature** — they are upstream
patches, and their real destination is upstream, not a plugin seam. Modularization
will not remove that conflict debt; **upstreaming will.** The genuinely
modularizable candidate is the message-search feature (its own
`features/messagesearch` module already).

---

## 5. Proposed feature grouping

76 branches already carry a correct `fix/<issue>-<slug>` / `feature/<slug>` name.
**The recommendation is to keep those names rather than rename everything to
`feat/*`** — renaming 76 branches breaks the 30+ open upstream PRs that point at
them. This is the one place I would deviate from the brief; I will argue it in
Phase 2.

Grouped:

| Group | Branches | Note |
| :--- | ---: | :--- |
| **Message search** (`feature/message-search`, `feature/search-index-button`, `search/*` ×5) | 7 | largest feature; own module; MODULARIZABLE |
| **Timeline rendering** (code-block copy, strikethrough, headings, state events, membership, redaction…) | ~18 | heavy overlap on `CodeBlockOverlay`/`ToHtmlDocument` |
| **Preferences / developer options** | ~8 | overlap on `DeveloperSettingsView`, `AppPreferencesStore` |
| **Room list / spaces** | ~9 | |
| **Media upload / mime types** | ~7 | |
| **Notifications** | ~5 | |
| **Verification / encryption** | ~4 | |
| **Composer** | ~5 | |
| **Accessibility** | ~4 | |
| **Misc one-offs** → `feat/fork-misc` | ~14 | explicitly a bucket |
| **`feat/fork-tooling`** (new) | 1 | `.fork/` + sync workflow, merged first |

`fix/developer-options-toggle` (165 commits, 150 files) is **not** a feature
branch — it is an old aggregate. Prune it.

---

## 6. Risks to settle before Phase 3

1. ⚠ **Four peer Claude sessions were busy in this checkout during the audit**,
   and 7 linked worktrees share these branch refs. A `git reset --hard` on
   `develop` or a force-push while another session is mid-build will corrupt
   its work. **Phase 3 must not start until the checkout is quiet.**
2. **Renaming 76 branches to `feat/*` would break your open upstream PRs.**
3. Upstream absorbs your work continuously — the sync script must *detect and
   retire* absorbed branches, or `features.txt` will rot into 58 dead entries.
4. `verifyPaparazziDebug` is a hard gate; every rebase that changes UI needs a
   re-record, which upstream's CI does via a `Record-Screenshots` PR label.

---

## 7. Recommendation

Proceed with the target model, with **three deviations** to be argued in Phase 2:

1. **Keep existing branch names**; add the `Fork-Feature:` trailer and
   `.fork/features.txt` ordering instead of renaming.
2. **Prune the 58 absorbed + ~17 aggregate branches first.** Restructuring
   around 153 branches when 76 are live is wasted motion.
3. **Treat modularization as a non-goal for most branches.** They are upstream
   patches; the highest-value follow-up is upstreaming, not plugin seams.

Everything else in §3's target model fits this repo well.

---

## 8. Addendum — three claims verified after the first report

Prompted by cross-checking with the element-web fork work. All three were
measured here, not assumed.

### 8.1 ⛔ 50 of your 76 live branches back an OPEN upstream PR

Not ~30 — **50**, confirmed via `gh pr list --repo element-hq/element-x-android
--author hayaksi1 --state open` (identity `hayaksi1`). Every open PR's head
branch is still a live local branch; none have gone missing.

**That is 66% of your live branches, and they are shared working surfaces.**
Renaming, rebasing, amending or force-pushing any of them detaches review
threads and re-fires CI on element-hq maintainers.

This settles the branch-naming question decisively: **the `feat/*` rename in the
brief must not be applied to these 50.** The split:

| Class | Count | Treatment |
| :--- | ---: | :--- |
| **PR-backed** | **50** | names frozen; **merged as-is into integration, never rebased** |
| **Fork-only** | **26** | safe to rebase onto the mirror each sync; safe to rename |

The 26 fork-only branches:
`feature/message-search`, `feature/search-index-button`,
`fix/2690-verification-shows-account`, `fix/2870-heading-line-break`,
`fix/3756-edit-composer-send-button`, `fix/3964-preserve-image-transparency`,
`fix/4236-mention-list-not-updated`, `fix/4328-strikethrough-tags`,
`fix/4702-push-gateway-rate-limited`, `fix/4770-fake-voice-recorder`,
`fix/5267-room-alias-resolver-timeout`, `fix/5356-sender-name-fallback`,
`fix/5797-carry-notification-setting`, `fix/5813-no-own-read-receipt`,
`fix/5966-details-summary`, `fix/6276-voice-message-audio-focus`,
`fix/6703-developer-options-layout-jump`, `fix/6839-undelivered-image-preview`,
`fix/7066-decline-invite-navigate-up`, `fix/7205-intent-replayed-from-history`,
`fix/7270-emoji-picker-keyboard`, `fix/7397-keep-thread-after-redaction`,
`fix/786-top-bar-hitbox`, `fix/developer-options-toggle` (aggregate — prune),
`search/backfill-sweep`, `search/matrix-layer`.

⇒ **Two manifests, not one.** `.fork/features.txt` (rebased) and
`.fork/pr-branches.txt` (merged as-is). The script must hard-fail if a branch
appears in both — they get opposite treatment and the mistake is silent.

### 8.2 ⚠ The `lfs` merge driver does not exist — rerere cannot save snapshots

`.gitattributes:1-5` declares `merge=lfs` on every snapshot path, but:

```
$ git config --get-regexp 'merge\.lfs\..*'
  (nothing — local, global or system)
```

**`merge=lfs` names a driver that is not configured anywhere.** Combined with
`-text`, git falls back to a binary merge: every snapshot conflict is a manual
binary conflict that no automatic strategy resolves. `rerere` records *textual*
hunk resolutions and is structurally incapable of helping here.

⇒ The snapshot strategy is **regenerate, not merge**. On conflict in
`tests/uitests/**/snapshots/*.png`, take either side to unblock, then re-record
and let `verifyPaparazziDebug` be the judge. `rerere` is still worth enabling —
for the *code* hot-spots in §3.2, which is where it genuinely pays.

### 8.3 ⚠ There are THREE verification surfaces, not one — a naive gate misses two

| Surface | Task | Where |
| :--- | :--- | :--- |
| JVM unit tests | `testDebugUnitTest` | all modules |
| **Konsist** | `:tests:konsist:testDebugUnitTest` | **explicitly `-x`-excluded** from the test command (`tests.yml:76`), run separately in `quality.yml:120` |
| **Paparazzi** | `:tests:uitests:verifyPaparazziDebug` | separate task, `tests/uitests` |
| **Roborazzi** | folded *inside* unit tests via `roborazzi.test.verify=true` (`gradle.properties:64`) | `libraries/compound` only |

A gate that runs only `./gradlew test` **silently skips Konsist and Paparazzi**
— the two things this fork breaks most often. The sync script must run all
four explicitly. (Confirms the "two runners" trap from the element-web work;
here it is worse.)

### 8.4 Carried-over lessons worth encoding in the script

- Tooling changes land on `feat/fork-tooling`, never on the disposable
  integration branch — a rebuild deletes them irrecoverably.
- Do **not** use `git merge-tree` as a conflict preflight; it cannot replay
  rerere or custom resolvers and reports false conflicts. Do the real merge in
  a throwaway worktree.
- Bash: `local a="$1" b="...$a..."` expands `$a` as the *global* before the
  assignment lands. Split the declarations.
- Detect "branch merged but contributed nothing" **after** the merge — that is
  the auto-retire signal for absorbed branches, and 58 already qualify.
