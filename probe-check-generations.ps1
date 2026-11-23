param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int] $PullRequest,

    [ValidateRange(1, 300)]
    [int] $ObservationSeconds = 30
)

$ErrorActionPreference = 'Stop'
$owner = 'maestro-auth-test'
$repository = 'build-result-analysis-test'
$fixtureBranch = 'fixtures/streaming-early-failure'
$checkName = 'Build Insights'
$appId = 2989452
$api = "https://api.github.com/repos/$owner/$repository"

if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -or
    [string]::IsNullOrWhiteSpace($env:BUILD_INSIGHTS_APP_TOKEN)) {
    throw 'Set GITHUB_TOKEN for read access and BUILD_INSIGHTS_APP_TOKEN to an Int Build Insights installation token with checks:write.'
}

$readHeaders = @{
    Authorization = "Bearer $env:GITHUB_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$writeHeaders = @{
    Authorization = "Bearer $env:BUILD_INSIGHTS_APP_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Get-AllCheckRuns {
    param([string] $Sha)
    $runs = @()
    $page = 1
    do {
        $response = Invoke-RestMethod -Headers $readHeaders -Uri "$api/commits/$Sha/check-runs?check_name=Build%20Insights&filter=all&per_page=100&page=$page"
        $batch = @($response.check_runs)
        $runs += $batch
        $page++
    } while ($batch.Count -eq 100)
    return $runs
}

function Get-Rollup {
    $query = @'
query($owner: String!, $repository: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repository) {
    pullRequest(number: $number) {
      headRefOid
      mergeStateStatus
      commits(last: 1) {
        nodes {
          commit {
            oid
            statusCheckRollup {
              state
              contexts(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  __typename
                  ... on CheckRun {
                    id databaseId name status conclusion
                    isRequired(pullRequestNumber: $number)
                    checkSuite { app { databaseId name } }
                  }
                  ... on StatusContext {
                    context state
                    isRequired(pullRequestNumber: $number)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
'@
    $contexts = @()
    $cursor = $null
    do {
        $body = @{
            query = $query
            variables = @{ owner = $owner; repository = $repository; number = $PullRequest; cursor = $cursor }
        } | ConvertTo-Json -Depth 10
        $result = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/graphql' -Headers $readHeaders -ContentType 'application/json' -Body $body
        if ($result.errors) {
            throw "GitHub GraphQL query failed: $($result.errors | ConvertTo-Json -Compress)"
        }
        $pr = $result.data.repository.pullRequest
        $commit = $pr.commits.nodes[0].commit
        if ($pr.headRefOid -ne $headSha -or $commit.oid -ne $headSha) {
            throw 'The PR head changed during the experiment.'
        }
        $rollup = $commit.statusCheckRollup
        if ($null -eq $rollup) {
            return @{ headSha = $pr.headRefOid; mergeStateStatus = $pr.mergeStateStatus; state = $null; contexts = @() }
        }
        $contexts += @($rollup.contexts.nodes)
        $cursor = $rollup.contexts.pageInfo.endCursor
    } while ($rollup.contexts.pageInfo.hasNextPage)

    return @{
        headSha = $pr.headRefOid
        mergeStateStatus = $pr.mergeStateStatus
        state = $rollup.state
        contexts = @($contexts | Where-Object { $_.name -eq $checkName -or $_.context -eq $checkName })
    }
}

$pr = Invoke-RestMethod -Headers $readHeaders -Uri "$api/pulls/$PullRequest"
if ($pr.state -ne 'open' -or $pr.base.ref -ne $fixtureBranch -or
    $pr.head.repo.full_name -ne "$owner/$repository") {
    throw "Use an open, same-repository PR targeting $fixtureBranch."
}
$headSha = $pr.head.sha
$branch = [Uri]::EscapeDataString($fixtureBranch)
$protection = Invoke-RestMethod -Headers $readHeaders -Uri "$api/branches/$branch/protection/required_status_checks"
$requiredCheck = @($protection.checks | Where-Object { $_.context -eq $checkName })
if ($checkName -notin $protection.contexts -and $requiredCheck.Count -eq 0) {
    throw "'$checkName' must be required on $fixtureBranch before running this probe."
}
foreach ($check in $requiredCheck) {
    if ($null -ne $check.app_id -and $check.app_id -ne -1 -and $check.app_id -ne $appId) {
        throw "The required check is bound to app $($check.app_id), not the Int app $appId."
    }
}

$baseline = @(Get-AllCheckRuns $headSha | Where-Object { $_.app.id -eq $appId })
$baselineFingerprint = @($baseline | Sort-Object id | ForEach-Object { "$($_.id):$($_.status):$($_.conclusion):$($_.updated_at)" }) -join '|'
$probeIds = [System.Collections.Generic.HashSet[long]]::new()
$expectedRuns = @{}

foreach ($phase in @(
    @{ name = 'failure'; status = 'completed'; conclusion = 'failure' },
    @{ name = 'pending'; status = 'in_progress' },
    @{ name = 'success'; status = 'completed'; conclusion = 'success' }
)) {
    $currentPr = Invoke-RestMethod -Headers $readHeaders -Uri "$api/pulls/$PullRequest"
    if ($currentPr.head.sha -ne $headSha -or $currentPr.state -ne 'open') {
        throw 'The PR head changed or the PR closed during the experiment.'
    }
    $run = @{
        name = $checkName
        head_sha = $headSha
        status = $phase.status
        details_url = "https://github.com/$owner/$repository/commit/$headSha"
        output = @{ title = "Generation probe: $($phase.name)"; summary = "Generation probe: $($phase.name)" }
    }
    if ($phase.conclusion) {
        $run.conclusion = $phase.conclusion
    }
    $created = Invoke-RestMethod -Method Post -Headers $writeHeaders -Uri "$api/check-runs" -ContentType 'application/json' -Body ($run | ConvertTo-Json -Depth 5)
    if ($created.app.id -ne $appId) {
        throw "Created check $($created.id) using app $($created.app.id), not the Int app $appId; stopping."
    }
    [void] $probeIds.Add([long] $created.id)
    $expectedRuns["$($created.id)"] = @{ status = $phase.status; conclusion = $phase.conclusion }

    foreach ($sample in 1..2) {
        if ($sample -eq 2) {
            Start-Sleep -Seconds $ObservationSeconds
        }
        $runs = @(Get-AllCheckRuns $headSha | Where-Object { $_.app.id -eq $appId })
        $otherFingerprint = @($runs | Where-Object { -not $probeIds.Contains([long] $_.id) } |
            Sort-Object id | ForEach-Object { "$($_.id):$($_.status):$($_.conclusion):$($_.updated_at)" }) -join '|'
        $changedProbeRuns = @($runs | Where-Object {
            $expected = $expectedRuns["$($_.id)"]
            $null -ne $expected -and ($_.status -ne $expected.status -or $_.conclusion -ne $expected.conclusion)
        } | Select-Object -ExpandProperty id)
        $currentPr = Invoke-RestMethod -Headers $readHeaders -Uri "$api/pulls/$PullRequest"
        if ($currentPr.head.sha -ne $headSha -or $currentPr.state -ne 'open') {
            throw 'The PR head changed or the PR closed during the experiment.'
        }
        @{
            observedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            phase = $phase.name
            createdRunId = $created.id
            concurrentAppChanges = $otherFingerprint -ne $baselineFingerprint
            changedProbeRunIds = $changedProbeRuns
            requiredChecks = $protection
            sameAppRuns = @($runs | Select-Object id, node_id, status, conclusion, created_at, updated_at)
            mergeable = $currentPr.mergeable
            mergeableState = $currentPr.mergeable_state
            rollup = Get-Rollup
        } | ConvertTo-Json -Depth 30 -Compress
    }
}
