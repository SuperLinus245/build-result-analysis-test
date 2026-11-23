# Streaming early-failure fixture

This branch is a disposable experiment fixture for Build Insights, based on
`fixtures/known-issue-only`. Do not merge it into `main`. The primary pipeline
triggers on PRs targeting `fixtures/streaming-early-failure`.

Stage A publishes one intentionally unmatched agent test failure and submits a
different unmatched test to Helix. `HelixJobMonitor` uses the real pinned
monitor to publish Helix results to Azure DevOps. Its `continueOnError`
parameter defaults to `false`; set it to `true` to investigate the
`SucceededWithIssues` variant. The agent test still fails the stage in either
case. Stage B runs after stage A and holds the build open for 15 minutes.

The test names and messages are intentionally distinct from the known-issue
fixture, but their unmatched classification must be verified against the Int
known-issue catalog during the experiment.

## Running the experiment

The following actions are for the operator, after the job-state webhook
subscriptions are in place:

1. Commit and push this branch, create a disposable branch from it, and open a
   PR targeting `fixtures/streaming-early-failure`. Record the PR URL and the
   primary pipeline build ID. Confirm that the build is still running after
   `FailFast` completes and that the Helix monitor publishes a failing test.
2. After the build completes, retry the failed `FailFast` job. Record its build
   ID, stage/job attempts and the retry test runs. Use a separate completed
   build to retry stage A; record the same evidence for all stage A jobs.
   Capture a run with `continueOnError` enabled as well. If the PR-triggered
   run does not allow choosing parameters, queue the same pipeline against the
   fixture branch with that parameter selected.
3. Configure `Build Insights` as a required check on the fixture branch. For
   the check-generation experiment use a disposable same-repository PR targeting
   this branch whose head is not being updated and on which the service is not
   actively publishing checks. Supply an installation token for the existing
   Build Insights - Int app with checks write permission, and a read token with
   PR, checks and branch-protection read permissions:

   ```powershell
   $env:GITHUB_TOKEN = '<read token>'
   $env:BUILD_INSIGHTS_APP_TOKEN = '<Int app installation token>'
   .\probe-check-generations.ps1 -PullRequest <number> | Tee-Object -FilePath check-probe.jsonl
   Remove-Item Env:\GITHUB_TOKEN, Env:\BUILD_INSIGHTS_APP_TOKEN
   ```

   The probe creates three real same-name checks on the PR head: failure,
   pending, and success. It does not create or close PRs or modify protection.
   It records immediate and delayed GitHub snapshots for each generation; use
   `-ObservationSeconds` to increase the default 30-second delay. A completed
   check cannot be moved back to pending, so these are separate check runs.
   Review the rollup's required contexts and the PR UI as well as mergeability:
   aggregate state can reflect other checks, be stale, or be blocked for other
   reasons. If `concurrentAppChanges` is true or `changedProbeRunIds` is not
   empty, the probe is confounded by other publications. If a generation is
   absent from the rollup or a state has not stabilized, capture additional
   observations; do not infer a selected run.
   Do not merge the probe PR based on these synthetic checks.

To validate the probe locally without contacting GitHub, run
`pwsh -NoProfile -File .\test\probe-check-generations-tests.ps1`.

## Evidence to collect

For each initial build, failed-job retry, stage retry, and `continueOnError`
variant, capture the build ID, UTC time, run and stage results, and:

- Job-state-changed webhook samples and delivery/log timestamps for `FailFast`,
  `SubmitHelix`, `HelixJobMonitor`, `Hold`, and retried jobs.
- The build timeline:
  `GET https://dev.azure.com/{organization}/{project}/_apis/build/builds/{buildId}/timeline?api-version=7.1`.
  Record job IDs, names, state, result and attempts; compare retried and
  untouched jobs.
- Test runs:
  `GET https://dev.azure.com/{organization}/{project}/_apis/test/runs?buildIds={buildId}&api-version=7.1`.
  For each relevant run, read
  `GET https://dev.azure.com/{organization}/{project}/_apis/test/runs/{runId}/results?api-version=7.1`.
  Preserve run IDs/names, state, outcome, tags, failed result IDs, and full
  `PipelineReference` including stage, phase, job and attempts. Verify that
  the two new failures are unmatched and that monitor-created runs identify
  the monitor job.
- All Helix tags and job identifiers on monitor-created runs, correlated with
  the monitor timeline record and `PipelineReference`.
- The probe output, the PR head SHA, GitHub check-run IDs/app IDs/statuses,
  required-check configuration and the PR's mergeability and check UI after
  each generation.

The evidence reads are observational. Pushing, creating PRs, setting branch
protection, retrying builds, and running the check probe are operator actions.
