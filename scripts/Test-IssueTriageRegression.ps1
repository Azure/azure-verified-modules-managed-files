#Requires -Version 7.4

<#
    .SYNOPSIS
        Runs the issue-triage regression suite against the sandbox repository.

    .DESCRIPTION
        The triage workflow is a prompt, so its behaviour can shift without any
        code changing. This suite pins the behaviour that matters: one case per
        decision path, each asserting the observable outcome rather than the
        prose around it.

        Every case dispatches a triage run, waits for it, and then checks the
        issue's resulting state against expectations recorded alongside the case.
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
        Run only the named cases.

    .PARAMETER SkipDispatch
        Check the most recent dispatched run for each case instead of starting
        new ones. Useful when runs were dispatched by a previous invocation.

    .PARAMETER LookBackHours
        How far back to search for runs when -SkipDispatch is used.

    .PARAMETER TimeoutMinutes
        How long to wait for dispatched runs. A triage run takes five to ten
        minutes, and the suite dispatches them in parallel.

    .EXAMPLE
        ./scripts/Test-IssueTriageRegression.ps1 -Version 1.0.27

    .NOTES
        Staging a case issue has three traps, each of which produced a false
        result while this suite was being written.

        A case issue must be one that nothing else duplicates. A duplicate
        closure short-circuits every other assertion, so the path under test
        never runs.

        A case issue must not carry reopen history unless the case is about the
        reopen override. That override vetoes closure on its own and will mask a
        failure in whatever else you meant to test.

        Resetting a case by reopening it creates exactly that history. Stage a
        new issue instead.
#>

[CmdletBinding()]
param(
    [string] $CasePath = (Join-Path $PSScriptRoot "issue-triage-regression-cases.json"),
    [string] $Repository,
    [string] $Version = "unknown",
    [string[]] $Id,
    [switch] $SkipDispatch,
    [int] $LookBackHours = 3,
    [int] $TimeoutMinutes = 30
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

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

function Get-AvmTriageRunOutput {
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

    $outputFile = Get-ChildItem -LiteralPath $runDirectory -Recurse -Filter "safeoutputs.jsonl" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $outputFile) {
        return @()
    }

    return @(
        Get-Content -LiteralPath $outputFile.FullName |
            Where-Object { $_.Trim() } |
            ForEach-Object {
                try { ($_ | ConvertFrom-Json).type } catch { $null }
            } |
            Where-Object { $_ }
    )
}

function Get-AvmTriageRunIssueNumber {
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

    if (-not $numberFile) {
        return $null
    }

    return (Get-Content -LiteralPath $numberFile.FullName -Raw).Trim()
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

$caseFile = Get-Content -LiteralPath $CasePath -Raw | ConvertFrom-Json
$cases = @($caseFile.cases)

if ($Id) {
    $cases = @($cases | Where-Object { $Id -contains $_.id })
}

if ($cases.Count -eq 0) {
    throw "No cases selected from $CasePath."
}

if (-not $Repository) {
    $Repository = $caseFile.repository
}

$workingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "avm-triage-regression-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null

$startedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# When re-checking an earlier invocation's runs, look back far enough to find
# them. Without this the window starts at "now" and matches nothing.
if ($SkipDispatch) {
    $startedUtc = (Get-Date).ToUniversalTime().AddHours(-$LookBackHours).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

Write-Host "Repository:  $Repository"
Write-Host "Version:     $Version"
Write-Host "Cases:       $($cases.Count)"
Write-Host "Started UTC: $startedUtc"
Write-Host ""

if (-not $SkipDispatch) {
    foreach ($case in $cases) {
        gh workflow run issue-triage.lock.yml --repo $Repository -f issue_number=$($case.issue) 2>$null | Out-Null
        Write-Host "  dispatched $($case.id) for #$($case.issue)"
        Start-Sleep -Seconds 5
    }
    Write-Host ""
}

# Runs have to finish before they can be identified, because issue-number.txt
# lives in the agent artifact and artifacts are not published until completion.
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds 60

    $dispatched = @(
        gh run list --repo $Repository --workflow issue-triage.lock.yml --limit 60 --json databaseId,createdAt,status,event 2>$null |
            ConvertFrom-Json |
            Where-Object { $_.createdAt -ge $startedUtc }
    )

    $pending = @($dispatched | Where-Object { $_.status -ne "completed" }).Count
    Write-Host "$(Get-Date -Format HH:mm:ss)  runs $($dispatched.Count)/$($cases.Count), $pending still running"
}
while ((($pending -gt 0) -or ($dispatched.Count -lt $cases.Count)) -and (Get-Date) -lt $deadline)

Write-Host ""

# Resolve every run that touched each case issue during the window, not just one.
#
# Creating a fresh case issue fires an issues-triggered run, and dispatching then
# adds a second run for the same issue. The first does the work; the second finds
# it already done and emits nothing. Judging the case on either run alone gives
# the wrong answer, so outputs are unioned across all of them.
$runsByIssue = @{}
foreach ($run in ($dispatched | Sort-Object createdAt -Descending)) {
    $runId = "$($run.databaseId)"
    $issueNumber = Get-AvmTriageRunIssueNumber -Repository $Repository -RunId $runId -WorkingDirectory $workingDirectory

    if (-not $issueNumber) {
        continue
    }

    if (-not $runsByIssue.ContainsKey($issueNumber)) {
        $runsByIssue[$issueNumber] = @()
    }

    $runsByIssue[$issueNumber] += $runId
}

$results = foreach ($case in $cases) {
    $issueKey = "$($case.issue)"
    $runIds = if ($runsByIssue.ContainsKey($issueKey)) { @($runsByIssue[$issueKey]) } else { @() }

    if ($runIds.Count -eq 0) {
        [pscustomobject]@{
            Case    = $case.id
            Issue   = "#$($case.issue)"
            Run     = "-"
            Verdict = "NO RUN"
            Detail  = "No completed run was found for this issue"
            Version = $Version
        }
        continue
    }

    $fact = Get-AvmTriageIssueFact -Repository $Repository -Issue $case.issue

    $output = @()
    foreach ($runId in $runIds) {
        $output += @(Get-AvmTriageRunOutput -Repository $Repository -RunId $runId -WorkingDirectory $workingDirectory)
    }
    $output = @($output | Select-Object -Unique)

    $failures = @(Test-AvmTriageCase -Case $case -Fact $fact -Output $output)

    [pscustomobject]@{
        Case    = $case.id
        Issue   = "#$($case.issue)"
        Run     = ($runIds -join ",")
        Verdict = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
        Detail  = ($failures -join "; ")
        Version = $Version
    }
}

$results = @($results)
$results | Format-Table -AutoSize -Property Case, Issue, Verdict, Detail

$passed = @($results | Where-Object { $_.Verdict -eq "PASS" }).Count
Write-Host ""
Write-Host "$passed of $($results.Count) passed against managed-files $Version"
Write-Host "Artifacts: $workingDirectory"

if ($passed -lt $results.Count) {
    exit 1
}
