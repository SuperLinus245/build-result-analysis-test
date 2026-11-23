$ErrorActionPreference = 'Stop'
$env:GITHUB_TOKEN = 'read-token'
$env:BUILD_INSIGHTS_APP_TOKEN = 'app-token'
$state = @{ runs = @(); wrongApp = $false; mutateProbe = $false }

function Start-Sleep { param($Seconds) }
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body)
    if ($Uri -like '*/pulls/*') {
        return @{ state = 'open'; base = @{ ref = 'fixtures/streaming-early-failure' }; head = @{ sha = 'abc'; repo = @{ full_name = 'maestro-auth-test/build-result-analysis-test' } }; mergeable = $true; mergeable_state = 'blocked' }
    }
    if ($Uri -like '*/protection/required_status_checks') {
        return @{ contexts = @('Build Insights'); checks = @(@{ context = 'Build Insights'; app_id = 2989452 }) }
    }
    if ($Uri -like '*/commits/*/check-runs?*') {
        if ($state.mutateProbe -and $state.runs.Count -gt 0) {
            $state.runs[0].conclusion = 'success'
        }
        return @{ check_runs = $state.runs }
    }
    if ($Uri -like '*/check-runs' -and $Method -eq 'Post') {
        $inputRun = $Body | ConvertFrom-Json
        $app = if ($state.wrongApp) { 123 } else { 2989452 }
        $run = @{ id = $state.runs.Count + 1; node_id = "node-$($state.runs.Count + 1)"; status = $inputRun.status; conclusion = $inputRun.conclusion; created_at = 'now'; updated_at = 'now'; app = @{ id = $app } }
        $state.runs += $run
        return $run
    }
    if ($Uri -eq 'https://api.github.com/graphql') {
        $latest = $state.runs[-1]
        return @{ data = @{ repository = @{ pullRequest = @{ headRefOid = 'abc'; mergeStateStatus = 'BLOCKED'; commits = @{ nodes = @(@{ commit = @{ oid = 'abc'; statusCheckRollup = @{ state = 'PENDING'; contexts = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @(@{ name = 'Build Insights'; databaseId = $latest.id; status = $latest.status; isRequired = $true }) } } } }) } } } } }
    }
    throw "Unexpected API call: $Method $Uri"
}

$probe = Join-Path $PSScriptRoot '..\probe-check-generations.ps1'
$observations = @(& $probe -PullRequest 123 -ObservationSeconds 1 | ForEach-Object { $_ | ConvertFrom-Json })
if ($observations.Count -ne 6) { throw "Expected 6 observations, got $($observations.Count)." }
if (($observations.phase -join ',') -ne 'failure,failure,pending,pending,success,success') { throw 'Incorrect transition order.' }
if ((@($state.runs | ForEach-Object { $_.status }) -join ',') -ne 'completed,in_progress,completed') { throw 'Incorrect run statuses.' }
if ((@($state.runs | ForEach-Object { $_.conclusion }) -join ',') -ne 'failure,,success') { throw 'Incorrect run conclusions.' }
if ($observations[-1].sameAppRuns.Count -ne 3 -or $observations[-1].concurrentAppChanges) { throw 'Incorrect check-run observations.' }

$state.runs = @()
$state.mutateProbe = $true
$observations = @(& $probe -PullRequest 123 -ObservationSeconds 1 | ForEach-Object { $_ | ConvertFrom-Json })
if ($observations[0].changedProbeRunIds -notcontains 1) { throw 'Concurrent changes to a probe run were not detected.' }

$state.runs = @()
$state.mutateProbe = $false
$state.wrongApp = $true
try {
    & $probe -PullRequest 123 -ObservationSeconds 1 | Out-Null
    throw 'Expected a wrong-app error.'
}
catch {
    if ($_.Exception.Message -notlike '*not the Int app*') { throw }
}
if ($state.runs.Count -ne 1) { throw 'The probe did not stop after the wrong app.' }
Write-Output 'Probe mocked transition, concurrency, and wrong-app guard tests passed.'
