#Requires -Version 7.4

<#
    .SYNOPSIS
        Runs the issue-triage regression suite against the sandbox repository.

    .DESCRIPTION
        The triage workflow is a prompt, so its behaviour can shift without any
        code changing. This suite pins the behaviour that matters: one case per
        decision path, each asserting the observable outcome rather than the
        prose around it.

        The suite stages everything it needs. It creates its own issues, drives
        them through triage, checks the results, and then closes and locks them.
        Nothing has to exist beforehand, so deleting last run's fixtures cannot
        break the next run.

        Issues are the only thing staged. Release state is read from the
        repository as it stands: the workflow decides released versus unreleased
        by comparing the newest release tag against the default branch, so the
        suite picks one anchor pull request from each side of that line and
        verifies both are still where the case file expects before staging
        anything. Repositioning the release line itself is not an option, because
        the sandbox permits only vN.N.N tags and forbids deleting them.

        Triage fires on `issues: opened` and `issues: reopened`, so staging an
        issue is normally what starts a run. That does not hold inside Actions:
        events raised by GITHUB_TOKEN are suppressed to prevent recursion, so a
        staged issue sits there untriaged. Pass -Dispatch in that case.
        `workflow_dispatch` is explicitly exempt from the suppression rule, so
        an explicit dispatch always produces a run. Outputs are unioned across
        every run that touched an issue, which keeps the answer right whether it
        was triaged once or twice.

        Assertions read the GitHub API and the run's own safeoutputs.jsonl. They
        never read the posted comment, because a comment on an issue may have
        been written by a different run.

    .PARAMETER CasePath
        Case definitions. Defaults to issue-triage-regression-cases.json beside
        this script.

    .PARAMETER Repository
        Sandbox repository in owner/name form. Defaults to the value in the case
        file.

    .PARAMETER Version
        Managed-files version under test. Recorded in the output for comparison
        across releases.

    .PARAMETER Id
        Run only the named cases. Phase 2 cases are skipped when the phase 1 case
        they chain from is not also selected.

    .PARAMETER KeepFixtures
        Leave staged issues open. Use when a failure needs investigating.

    .PARAMETER CleanupOrphans
        Close and lock any fixture left behind by an earlier run, then exit
        without staging anything.

    .PARAMETER Dispatch
        Start each triage run explicitly instead of relying on the issue event.
        Required when the token staging the issues is an Actions GITHUB_TOKEN,
        because Actions does not raise workflow events for its own token.

    .PARAMETER TimeoutMinutes
        How long to wait for each phase. A triage run takes five to ten minutes
        and the suite stages a phase in parallel.

    .EXAMPLE
        ./scripts/Test-IssueTriageRegression.ps1 -Version 1.0.28

    .NOTES
        Staged issues are scrubbed, closed and locked, never deleted. Deleting
        an issue needs admin on the repository, and a pull request cannot be
        deleted at all. Scrubbing replaces the title and body so a retired
        fixture cannot be matched as a duplicate of the next run's identical
        one; locking is what stops it being triaged again.

        Staging a case issue has three traps, each of which produced a false
        result while this suite was being written.

        A case issue must be one that nothing else duplicates. A duplicate
        closure short-circuits every other assertion, so the path under test
        never runs. Scrubbing retired fixtures is what keeps that true across
        repeated runs.

        A case issue must not carry reopen history unless the case is about the
        reopen override. That override vetoes closure on its own and will mask a
        failure in whatever else you meant to test.

        The reopen override cannot be staged with a bare API close, because it
        looks for a closure by the workflow actor correlated with a triage
        comment. That is why it chains off fix-released rather than standing
        alone.
#>

[CmdletBinding()]
param(
    [string] $CasePath = (Join-Path $PSScriptRoot "issue-triage-regression-cases.json"),
    [string] $Repository,
    [string] $Version = "unknown",
    [string[]] $Id,
    [switch] $KeepFixtures,
    [switch] $CleanupOrphans,
    [switch] $Dispatch,
    [int] $TimeoutMinutes = 30
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

function Get-AvmUnreleasedPullRequestNumber {
    <#
        Mirrors the workflow's own release check: newest release by published_at,
        compared against the default branch, with pull request numbers scraped
        from the commit messages in between.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository
    )

    # --slurp wraps each page in one outer array, which is the only form
    # ConvertFrom-Json can read; without it gh emits several concatenated arrays.
    $raw = gh api "repos/$Repository/releases?per_page=100" --paginate --slurp 2>$null
    if (-not $raw) {
        throw "Could not list releases for $Repository."
    }

    $releases = @(foreach ($page in (($raw -join "") | ConvertFrom-Json)) { $page })

    $newest = $releases |
        Where-Object { -not $_.draft -and -not $_.prerelease } |
        Sort-Object published_at |
        Select-Object -Last 1

    if (-not $newest) {
        throw "$Repository has no published release, so released and unreleased cannot be told apart."
    }

    $branch = (gh api "repos/$Repository" --jq '.default_branch' 2>$null).Trim()

    # Deliberately unpaginated, matching the workflow. The compare endpoint
    # returns at most 250 commits, so both truncate at the same point and agree.
    $comparison = ((gh api "repos/$Repository/compare/$($newest.tag_name)...$branch" 2>$null) -join "") | ConvertFrom-Json

    $numbers = @(
        $comparison.commits |
            ForEach-Object { [regex]::Matches($_.commit.message, '#(\d+)') } |
            ForEach-Object { [int] $_.Groups[1].Value } |
            Sort-Object -Unique
    )

    return [pscustomobject]@{
        Tag     = $newest.tag_name
        Numbers = $numbers
    }
}

function Test-AvmAnchorState {
    <#
        A case is only meaningful while its anchor sits on the expected side of
        the release line. Cutting a release moves pull requests from unreleased
        to released, which would quietly invert a case instead of failing it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Anchors,
        [Parameter(Mandatory)] [object] $ReleaseLine
    )

    $problems = @()

    foreach ($name in $Anchors.PSObject.Properties.Name) {
        $anchor = $Anchors.$name
        $isUnreleased = $ReleaseLine.Numbers -contains [int] $anchor.pr
        $wantReleased = [bool] $anchor.released

        $actual = if ($isUnreleased) { "unreleased" } else { "released" }
        $wanted = if ($wantReleased) { "released" } else { "unreleased" }

        Write-Host ("  anchor {0,-11} PR #{1,-5} {2}" -f $name, $anchor.pr, $actual)

        if ($wantReleased -eq $isUnreleased) {
            $problems += "anchor '$name' (PR #$($anchor.pr)) is $actual but the case file expects $wanted"
        }
    }

    return @($problems)
}

function New-AvmFixtureIssue {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [object] $Case,
        [Parameter(Mandatory)] [string] $WorkingDirectory
    )

    # Sent as a file rather than -f arguments: issue bodies are multi-line and
    # contain fenced code, which does not survive shell argument handling.
    $payloadPath = Join-Path $WorkingDirectory "create-$($Case.id).json"
    $payload = [ordered]@{ title = $Case.title; body = $Case.body } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($payloadPath, $payload, (New-Object System.Text.UTF8Encoding $false))

    if (-not $PSCmdlet.ShouldProcess("$Repository", "create fixture issue for $($Case.id)")) {
        return $null
    }

    $raw = gh api -X POST "repos/$Repository/issues" --input $payloadPath 2>$null
    if (-not $raw) {
        throw "Could not create a fixture issue for case '$($Case.id)'."
    }

    return (($raw -join "") | ConvertFrom-Json).number
}

function Start-AvmTriageRun {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $Issue
    )

    if (-not $PSCmdlet.ShouldProcess("$Repository#$Issue", "dispatch a triage run")) {
        return
    }

    gh workflow run issue-triage.lock.yml --repo $Repository -f issue_number=$Issue 2>$null | Out-Null
}

function Get-AvmTriageIssueFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $Issue
    )

    $raw = gh api "repos/$Repository/issues/$Issue" 2>$null
    if (-not $raw) {
        throw "Could not read $Repository#$Issue."
    }

    # Not $issue: PowerShell variable names are case-insensitive, so that would
    # assign this object over the [int] $Issue parameter and fail the cast.
    $payload = ($raw -join "") | ConvertFrom-Json

    return [pscustomobject]@{
        State  = $payload.state
        Reason = if ($payload.PSObject.Properties.Name -contains "state_reason" -and $payload.state_reason) { $payload.state_reason } else { "-" }
        Type   = if ($payload.PSObject.Properties.Name -contains "type" -and $payload.type) { $payload.type.name } else { "NONE" }
        Labels = @($payload.labels | ForEach-Object { $_.name })
    }
}

function Get-AvmTriageRunArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $WorkingDirectory
    )

    $runDirectory = Join-Path $WorkingDirectory $RunId
    if (-not (Test-Path -LiteralPath $runDirectory)) {
        gh run download $RunId --repo $Repository --dir $runDirectory -n agent 2>$null | Out-Null
    }

    $numberFile = Get-ChildItem -LiteralPath $runDirectory -Recurse -Filter "issue-number.txt" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $outputFile = Get-ChildItem -LiteralPath $runDirectory -Recurse -Filter "safeoutputs.jsonl" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    $outputs = @()
    if ($outputFile) {
        $outputs = @(
            Get-Content -LiteralPath $outputFile.FullName |
                Where-Object { $_.Trim() } |
                ForEach-Object {
                    try { ($_ | ConvertFrom-Json).type } catch { $null }
                } |
                Where-Object { $_ }
        )
    }

    return [pscustomobject]@{
        Issue   = if ($numberFile) { (Get-Content -LiteralPath $numberFile.FullName -Raw).Trim() } else { $null }
        Outputs = $outputs
    }
}

function Wait-AvmTriageRun {
    <#
        Runs have to finish before they can be identified, because
        issue-number.txt lives in the agent artifact and artifacts are not
        published until completion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [datetime] $SinceUtc,
        [Parameter(Mandatory)] [int] $Expected,
        [Parameter(Mandatory)] [int] $TimeoutMinutes
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $seen = @()

    do {
        Start-Sleep -Seconds 45

        # createdAt arrives as a DateTime, so it must be compared with one.
        # Comparing it against an ISO string coerces that string through the
        # local time zone, which silently widened this window by seven hours and
        # matched 28 unrelated runs instead of 1.
        $seen = @(
            gh run list --repo $Repository --workflow issue-triage.lock.yml --limit 60 `
                --json databaseId,createdAt,status 2>$null |
                ConvertFrom-Json |
                Where-Object { [datetime]::SpecifyKind($_.createdAt, [System.DateTimeKind]::Utc) -ge $SinceUtc }
        )

        $pending = @($seen | Where-Object { $_.status -ne "completed" }).Count
        Write-Host ("  {0}  runs {1}/{2}, {3} still running" -f (Get-Date -Format HH:mm:ss), $seen.Count, $Expected, $pending)
    }
    while ((($pending -gt 0) -or ($seen.Count -lt $Expected)) -and (Get-Date) -lt $deadline)

    return @($seen | Sort-Object createdAt -Descending | ForEach-Object { "$($_.databaseId)" })
}

function Test-AvmTriageCase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Case,
        [Parameter(Mandatory)] [object] $Fact,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Output
    )

    $failures = @()
    $fields = $Case.PSObject.Properties.Name

    if ($fields -contains "expectState" -and $Fact.State -ne $Case.expectState) {
        $failures += "state is '$($Fact.State)', expected '$($Case.expectState)'"
    }

    if ($fields -contains "expectReason" -and $Fact.Reason -ne $Case.expectReason) {
        $failures += "state reason is '$($Fact.Reason)', expected '$($Case.expectReason)'"
    }

    if ($fields -contains "expectType" -and $Fact.Type -ne $Case.expectType) {
        $failures += "issue type is '$($Fact.Type)', expected '$($Case.expectType)'"
    }

    if ($fields -contains "expectLabel") {
        if (-not ($Fact.Labels | Where-Object { $_ -like "*$($Case.expectLabel)*" })) {
            $failures += "label '$($Case.expectLabel)' was not applied"
        }
    }

    if ($fields -contains "expectAbsentLabel") {
        if ($Fact.Labels | Where-Object { $_ -like "*$($Case.expectAbsentLabel)*" }) {
            $failures += "label '$($Case.expectAbsentLabel)' was applied but must not be"
        }
    }

    if ($fields -contains "expectOutput" -and $Output -notcontains $Case.expectOutput) {
        $failures += "$($Case.expectOutput) was not emitted"
    }

    if ($fields -contains "expectAbsentOutput" -and $Output -contains $Case.expectAbsentOutput) {
        $failures += "$($Case.expectAbsentOutput) was emitted but must not be"
    }

    # Wrapped so a single failure does not unroll to a bare string. Under
    # Set-StrictMode the caller's .Count check would then throw.
    return @($failures)
}

function Remove-AvmFixture {
    <#
        Retires a fixture by scrubbing it, closing it, and locking it.

        Scrubbing is the part that matters. Triage searches open *and* closed
        issues for duplicates, and every run stages the same wording, so last
        run's retired fixture is an exact match for this run's live one. Left
        intact it would be found, and the new issue would be closed as a
        duplicate before the path under test ever ran. Replacing the title and
        body removes anything for that search to match on.

        Deleting would be simpler but needs admin, which the suite deliberately
        does not assume.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [int[]] $Issue
    )

    $scrubbed = @(
        "This issue was staged by the issue-triage regression suite and has been retired."
        ""
        "Its original title and body were removed so that a later run staging the same"
        "wording is not closed as a duplicate of it."
        ""
        "<!-- avm-triage-regression-fixture-retired -->"
    ) -join "`n"

    foreach ($number in $Issue) {
        if (-not $PSCmdlet.ShouldProcess("$Repository#$number", "scrub, close and lock fixture")) {
            continue
        }

        gh api -X PATCH "repos/$Repository/issues/$number" `
            -f title="Retired triage regression fixture" `
            -f body="$scrubbed" `
            -f state=closed `
            -f state_reason=not_planned 2>$null | Out-Null

        gh api -X PUT "repos/$Repository/issues/$number/lock" -f lock_reason=resolved 2>$null | Out-Null
        Write-Host "  retired #$number"
    }
}

function Get-AvmOrphanFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Marker
    )

    # Best effort. GitHub's code search does index HTML comments in issue
    # bodies, but indexing lags creation by a minute or so.
    $found = gh search issues --repo $Repository --state open --match body $Marker `
        --limit 50 --json number 2>$null

    if (-not $found) {
        return @()
    }

    return @((($found -join "") | ConvertFrom-Json) | ForEach-Object { [int] $_.number })
}

$caseFile = Get-Content -LiteralPath $CasePath -Raw | ConvertFrom-Json

if (-not $Repository) {
    $Repository = $caseFile.repository
}

$workingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "avm-triage-regression-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null

if ($CleanupOrphans) {
    Write-Host "Sweeping fixtures left behind in $Repository"
    $orphans = @(Get-AvmOrphanFixture -Repository $Repository -Marker $caseFile.fixtureMarker)

    if ($orphans.Count -eq 0) {
        Write-Host "  none found"
        return
    }

    Remove-AvmFixture -Repository $Repository -Issue $orphans
    return
}

$cases = @($caseFile.cases)
if ($Id) {
    $cases = @($cases | Where-Object { $Id -contains $_.id })
}

if ($cases.Count -eq 0) {
    throw "No cases selected from $CasePath."
}

$phaseOne = @($cases | Where-Object { $_.phase -eq 1 })
$phaseTwo = @($cases | Where-Object { $_.phase -eq 2 })

Write-Host "Repository: $Repository"
Write-Host "Version:    $Version"
Write-Host "Cases:      $($cases.Count)  ($($phaseOne.Count) staged, $($phaseTwo.Count) chained)"
Write-Host ""

Write-Host "Checking anchors against the current release line"
$releaseLine = Get-AvmUnreleasedPullRequestNumber -Repository $Repository
Write-Host "  newest release $($releaseLine.Tag), unreleased PRs: $($releaseLine.Numbers -join ', ')"

$anchorProblems = @(Test-AvmAnchorState -Anchors $caseFile.anchors -ReleaseLine $releaseLine)
if ($anchorProblems.Count -gt 0) {
    Write-Host ""
    foreach ($problem in $anchorProblems) {
        Write-Host "  $problem"
    }

    throw "The release line moved. Re-anchor the affected cases onto pull requests that are still on the expected side, then rerun."
}

Write-Host ""

$staged = @{}
$fixtures = @()
$results = @()

try {
    $phaseOneStart = (Get-Date).ToUniversalTime()

    Write-Host "Staging phase 1"
    foreach ($case in $phaseOne) {
        $number = New-AvmFixtureIssue -Repository $Repository -Case $case -WorkingDirectory $workingDirectory
        $staged[$case.id] = $number
        $fixtures += [int] $number

        if ($Dispatch) {
            Start-AvmTriageRun -Repository $Repository -Issue ([int] $number)
        }

        Write-Host "  $($case.id) -> #$number"
        Start-Sleep -Seconds 5
    }

    Write-Host ""
    Write-Host "Waiting for phase 1"
    $runIds = @(Wait-AvmTriageRun -Repository $Repository -SinceUtc $phaseOneStart `
            -Expected $phaseOne.Count -TimeoutMinutes $TimeoutMinutes)

    $outputsByIssue = @{}
    foreach ($runId in $runIds) {
        $artifact = Get-AvmTriageRunArtifact -Repository $Repository -RunId $runId -WorkingDirectory $workingDirectory
        if (-not $artifact.Issue) {
            continue
        }

        if (-not $outputsByIssue.ContainsKey($artifact.Issue)) {
            $outputsByIssue[$artifact.Issue] = @()
        }

        $outputsByIssue[$artifact.Issue] += $artifact.Outputs
    }

    Write-Host ""

    foreach ($case in $phaseOne) {
        $number = $staged[$case.id]
        $key = "$number"

        if (-not $outputsByIssue.ContainsKey($key)) {
            $results += [pscustomobject]@{
                Case = $case.id; Issue = "#$number"; Verdict = "NO RUN"
                Detail = "No completed triage run was found for this issue"
            }
            continue
        }

        $fact = Get-AvmTriageIssueFact -Repository $Repository -Issue $number
        $output = @($outputsByIssue[$key] | Select-Object -Unique)
        $failures = @(Test-AvmTriageCase -Case $case -Fact $fact -Output $output)

        $results += [pscustomobject]@{
            Case = $case.id; Issue = "#$number"
            Verdict = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
            Detail = ($failures -join "; ")
        }
    }

    foreach ($case in $phaseTwo) {
        $parentId = $case.reopenOf

        if (-not $staged.ContainsKey($parentId)) {
            $results += [pscustomobject]@{
                Case = $case.id; Issue = "-"; Verdict = "SKIP"
                Detail = "Chains from '$parentId', which was not staged in this run"
            }
            continue
        }

        $number = $staged[$parentId]
        $parentResult = @($results | Where-Object { $_.Case -eq $parentId })

        # The override only exists once the workflow has closed the issue and
        # written the triage comment that proves it. Reopening something the
        # workflow left open tests nothing.
        if ($parentResult.Count -gt 0 -and $parentResult[0].Verdict -ne "PASS") {
            $results += [pscustomobject]@{
                Case = $case.id; Issue = "#$number"; Verdict = "SKIP"
                Detail = "'$parentId' did not close the issue, so there is no workflow closure to override"
            }
            continue
        }

        Write-Host "Staging phase 2: reopening #$number as a human"
        $phaseTwoStart = (Get-Date).ToUniversalTime()
        gh api -X PATCH "repos/$Repository/issues/$number" -f state=open 2>$null | Out-Null

        if ($Dispatch) {
            Start-AvmTriageRun -Repository $Repository -Issue ([int] $number)
        }

        Write-Host "Waiting for phase 2"
        $reopenRunIds = @(Wait-AvmTriageRun -Repository $Repository -SinceUtc $phaseTwoStart `
                -Expected 1 -TimeoutMinutes $TimeoutMinutes)

        $reopenOutputs = @()
        foreach ($runId in $reopenRunIds) {
            $artifact = Get-AvmTriageRunArtifact -Repository $Repository -RunId $runId -WorkingDirectory $workingDirectory
            if ("$($artifact.Issue)" -eq "$number") {
                $reopenOutputs += $artifact.Outputs
            }
        }

        $fact = Get-AvmTriageIssueFact -Repository $Repository -Issue $number
        $failures = @(Test-AvmTriageCase -Case $case -Fact $fact -Output @($reopenOutputs | Select-Object -Unique))

        $results += [pscustomobject]@{
            Case = $case.id; Issue = "#$number"
            Verdict = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
            Detail = ($failures -join "; ")
        }

        Write-Host ""
    }
}
finally {
    if ($KeepFixtures) {
        Write-Host ""
        Write-Host "Fixtures kept open: $(($fixtures | ForEach-Object { "#$_" }) -join ', ')"
    }
    elseif ($fixtures.Count -gt 0) {
        Write-Host ""
        Write-Host "Retiring fixtures"
        Remove-AvmFixture -Repository $Repository -Issue $fixtures
    }
}

$results = @($results)
Write-Host ""
$results | Format-Table -AutoSize -Property Case, Issue, Verdict, Detail

$passed = @($results | Where-Object { $_.Verdict -eq "PASS" }).Count
Write-Host ""
Write-Host "$passed of $($results.Count) passed against managed-files $Version"
Write-Host "Artifacts: $workingDirectory"

if ($passed -lt $results.Count) {
    exit 1
}
