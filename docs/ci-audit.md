# Core CI audit — 17 November 2026

## Scope and baseline

The audited source revision is `82e83488a6c9c1adb35f8f7256395ac3ff56722c`.
The initial comparisons keep its entire Core tree
(`83cf9940abfc6009ce155c056ef5eb2be94664c7`) unchanged. A subsequent verification
run exposed a test synchronization race, repaired separately below. CI changes
are on `codex/ci-efficiency`; they do not change `main`.

There is one workflow, **Core tests**, with one job, **test**, on `macos-26`.
It runs on Core/workflow changes in PRs and pushes to `main`, or on manual dispatch.
It checks out shallowly, shows the toolchain, caches dependencies and runs
`swift test --package-path Packages/Core`. PR updates already cancel superseded
runs. The timeout is 30 minutes and token permissions are `contents: read`.

The GitHub rulesets API returned an empty list; `main` protection returned 404,
“Branch not protected.” The workflow was explicitly documented as non-required.
Nevertheless, the workflow name, job ID, triggers, timeout, permissions and
cancellation policy are preserved. No required-check or repository settings were
changed. If this becomes required, replace workflow-level path filtering with
an always-reporting check before requiring it: a filtered-out workflow can leave
a required status pending. See [GitHub's workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore).

Core has eight production targets, seven test targets, 230 source files and
130 test/support files at this revision. All 128 files importing a test framework
use Swift Testing. It already [runs tests concurrently](https://developer.apple.com/xcode/swift-testing/).
The ordinary suite reports 960 tests in 141 suites; the three `ListBenchmarks`
tests remain opt-in via `TERN_BENCHMARKS=1`, exactly as before.

Hosted app, Claude helper and UI tests under `Tests/` are **not covered by this
workflow**, and never were. They remain the separate local/Xcode checks described
in [development.md](development.md#build-and-test). This audit validates the full
existing CI suite; it does not claim whole-app or live-provider coverage.

Only one historical Actions run existed before the audit:
43481582349,
13 November, source `1e490bee12`. Its job took 133 seconds, including a 118-second
test step (95.50-second build, 16.776-second suite), with 955 tests passing and
a cold dependency cache. That older source is context, not an equal-work baseline.

## What transfers from OpenClaw

[Vincent Koc's article](https://vincent.build/openclaw-ci-cost-reduction/) separates
runner time, estimated compute value and author waiting time, and acknowledges
changes in workload and sponsored capacity. Its headline percentage is not a
prediction for Tern. We examined the linked
[pinned workflow](https://github.com/openclaw/openclaw/blob/a7d05c7af04aa17ac57c994da238d0c60f058ca6/.github/workflows/ci.yml),
including the native Swift lanes and final gate. It uses toolchain/graph-aware
build caches, timestamp restoration, selected-lane validation and a full-suite
fallback. Its TypeScript ownership/import planner is not a Swift dependency model.

The useful principle here is to measure setup and compilation before removing
tests. Tern has one job and roughly 11–17 seconds of test execution, with much
more time spent compiling. There is no evidence that new sharding, a learned
selector, a different runner vendor, test deletion or a schedule would pay for
their complexity. Full Core tests remain mandatory whenever this job runs;
there is no affected-test selection, empty-selection success, result reuse,
`--filter`, `--skip-build` or failure retry.

## Reviewable changes

1. **Record evidence.** Time the unchanged invocation with macOS `/usr/bin/time`;
   retain its output and the complete test log for seven days, including test
   failures. Show invocation timing in the job summary. Explicit `pipefail`
   propagates test failures through `tee`. The action job timestamps remain the
   measure for runner occupancy and cost, since invocation timing excludes
   checkout, cache transfer and artifact upload.
2. **Remove duplicate source caching.** Cache only SwiftPM's shared bare Git
   repositories. SwiftPM repopulates `.build/repositories` from that cache.
   The versioned key includes the lockfile hash; a source-only prefix fallback
   still lets SwiftPM resolve the pinned revisions. No object files, test
   executables, cached success results or compiler manifests are restored.
3. **Repair a demonstrated test race.** The first final-workflow warm-cache run
   failed `aReplyStillLoadingItsOriginalAtQuitGetsItAfterLaunch`. The test observed
   `importPending == false` before `completeReplyImport` enqueued the Gmail save
   in a later operation. It now waits for the durable save action with the existing
   bounded-wait helper, then makes the same quote, send-count and Gmail-call
   assertions. The engine is stopped on both success and thrown failure. No
   production behavior, assertion or test was removed; retries do not hide it.

A separate compiler experiment disabled IDE indexing and used line-table debug
information. Both the instrumented baseline and the trial occupied a runner for
100 seconds, at the same rounded compute value. Invocation CPU actually increased
from 258.24 to 265.82 seconds. Images differed, so this is not an isolated causal
comparison, but it provides no evidence of a worthwhile gain. The flags were
reverted in a separate commit: the final workflow keeps ordinary debug metadata
and indexing. The review history retains the experiment and its rollback.

Full `.build` caching is deferred: it needs compatible toolchain/SDK/architecture
keys, trustworthy content/timestamp validation across fresh checkouts, bounded
archive transfer and measured invalidation. A warm local build alone would not
prove a portable hosted-cache improvement. Changing runner size or moving to
Linux is also deferred; Core contains macOS framework dependencies.

## Measurement method

The initial hosted comparisons use manual dispatches of this branch, fresh macOS
runners, the same Core Git tree and dependency pins, and the same ordinary test
inventory. Post-fix verification uses Core tree
`cbab153cc24f26ad01efd4fc642c911e713db57d`; only the synchronization of the existing
reply-recovery test differs. Treat that run as verification, not a strict paired
performance experiment.
The runners use `macos-26-arm64`, Xcode 26.6 (`17F113`) and Swift 6.3.3. The pool
served both `20261102.0473.1` and `20261112.0504.1` images, so source and toolchain
are controlled but image and host load are not. Cache hit/miss state is recorded
separately. These are small samples, not p50/p95 or fleetwide estimates.

- **Build / suite:** SwiftPM's build duration and Swift Testing's suite duration.
- **Invocation:** wall, user and system CPU time from `/usr/bin/time -lp`.
- **Runner time:** job `completed_at - started_at`, including setup/post steps.
- **Feedback:** final job completion minus workflow creation, including queueing.
- **Estimated compute value:** `ceil(job_seconds / 60) × $0.062` for this single
  standard macOS job, at the [published rate](https://docs.github.com/en/billing/reference/actions-runner-pricing)
  checked on 17 November 2026. This is not an invoice: included minutes, credits,
  account terms and storage charges are excluded. Less runtime may leave the
  rounded compute value unchanged.

### Hosted results

Each run discovers the same 960 tests in 141 suites and starts with no compiled
build output. The first four passed; the failure is retained below, rather than
excluded from the comparison. Images A/B are `20261102.0473.1` / `20261112.0504.1`.

| Run | Profile / source cache | Image | Build / suite (s) | Runner (s) | Queue to job (s) | Feedback (s) | Estimated USD |
|---|---|---|---:|---:|---:|---:|---:|
| 44081076598 | Original workflow / hit | A | 62.42 / 11.274 | 91 | 3 | 94 | 0.124 |
| 44081417952 | Instrumented baseline / hit | B | 69.12 / 10.989 | 100 | 4 | 104 | 0.124 |
| 44081608595 | Compiler trial / hit | A | 68.20 / 11.927 | 100 | 35 | 135 | 0.124 |
| 44081825537 | Compiler trial + source cache / miss | B | 76.01 / 12.229 | 109 | 53 | 162 | 0.124 |
| 44082332844 | Final compiler settings + source cache / hit; **test race failed** | B | 74.08 / 15.789 | 109 | 3 | 112 | 0.124 |
| 44082995443 | Final workflow + synchronized test / hit; **passed** | B | 68.09 / 11.185 | 96 | 3 | 99 | 0.124 |

The baseline cache archive was 473,201,805 bytes; the source-only archive is
239,474,030 bytes, **49.4% smaller**. This directly measures reduced archive storage
and bytes to transfer, not a 49.4% compute or invoice saving. The cold-cache run
repopulated the sources and rebuilt/tested successfully. The compiler trial and
cache-miss run queued behind earlier manual runs; those waits are included in
feedback but not billed runner time. Instrumentation itself added one or two
seconds for artifact upload; the remaining between-run differences are not
attributable from these samples alone.

The failed warm run restored the new archive in two seconds, versus five/six
seconds for the old cache in earlier runs. Its build/test variation outweighed
that difference, so no overall feedback-time or rounded compute-cost reduction
has been established. The failure also exercised the real failure path: the
`test` check remained red, while summary and artifact upload both succeeded.
Both cache generations remain stored; no shared cache was deleted. The smaller
entry is not a claim of reduced account storage charges during migration.

Final verification passed all 960 tests, with a 96-second job and 99-second
feedback interval. The same-image instrumented baseline was 100/104 seconds;
the original workflow on image A was 91/94 seconds. These observations do not
establish a reliable overall speedup. Final invocation timing was 84.03 seconds
wall / 267.84 CPU seconds, versus 85.25 / 258.24 in the instrumented baseline.
Rounded compute value stayed **$0.124 per run** throughout all six audit runs
(an estimated $0.744 for the experiment, before allowances and storage).

### Local correctness and limitations

On the local Mac (10 CPUs, 32 GiB; Xcode 26.3 / Swift 6.2.4), a clean scratch
baseline passed all 960 tests in 141 suites: 116.85 seconds elapsed, 429.96 seconds
of user+system CPU, 93.85-second build and 13.663-second suite. Dependency sources
were already cached. Other CPU-heavy workloads were active during the subsequent
experiment, so local wall times are not used as hosted savings estimates.

The rejected compiler trial also passed the 960-test suite locally, taking
414.59 seconds elapsed / 542.03 CPU seconds (389.58-second build, 21.913-second
suite). Compiled output fell from about 640 to 565 MiB. Concurrent work on the
machine, and a scratch test file appearing in the shared worktree during the run,
make this unsuitable for an isolated speed comparison. The hosted runs used
committed trees and are the authoritative correctness comparison. No concurrent
worktree files were changed or committed by this audit.

Final local verification used an isolated checkout of the test fix, with ordinary
compiler flags and no compiled cache. All 960 tests in 141 suites passed:
172.26 seconds elapsed, 531.36 CPU seconds, 156.46-second build and 12.469-second
suite. That run is correctness evidence, not a controlled timing comparison with
the earlier local baseline.

`actionlint` and `git diff --check` validate the workflow. A synthetic command
returning 37 through the exact `time | tee` pipeline still returns 37 and retains
both log and timing files; the success case returns 0. No test failure can be
converted to success by the logger.

## Reproduce and operate

To rerun the baseline and the **rejected** compiler experiment locally (run
sequentially with idle hardware; choose new scratch directories so neither reuses
compiled objects):

```sh
/usr/bin/time -lp swift test --package-path Packages/Core \
  --scratch-path build/ci-baseline
/usr/bin/time -lp swift test --package-path Packages/Core \
  --scratch-path build/ci-candidate \
  --disable-index-store -Xswiftc -gline-tables-only
```

For hosted evidence, dispatch `core-tests.yml` at an explicit committed ref, wait
for it to complete, and inspect the run's job timestamps and retained artifact.
Use one dispatch at a time: the existing concurrency group can replace pending
runs. To compare a cache miss and a hit, use a new versioned cache key in an
experiment branch, then repeat that same ref. Do not delete shared caches merely
to benchmark. Check Core tree IDs and toolchain/image versions before comparing.

```sh
gh workflow run core-tests.yml --ref <experiment-ref>
gh run view <run-id> --json headSha,createdAt,jobs,conclusion,url
gh api repos/{owner}/{repo}/actions/runs/<run-id>/jobs
gh run download <run-id> --dir build/ci-evidence/<run-id>
git rev-parse <experiment-ref>:Packages/Core
```

Retain a baseline when the runner image/toolchain or dependency graph changes.
Evaluate cold as well as warm cache behavior and failed as well as passing runs.
Roll back the source-cache change if total job time regresses consistently.
That requires no change to check identity or tests. The fresh build and full suite
remain the fallback for every cache miss and every uncertain dependency boundary.
