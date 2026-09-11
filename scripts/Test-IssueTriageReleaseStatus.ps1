#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the canonical issue-triage release pre-step against deterministic GitHub API fixtures.
.DESCRIPTION
    Requires Bash, jq, and timeout (Ubuntu or Git Bash on Windows). Executes the actual workflow shell, including the existing PR evidence validator, without network access. No comparison algorithm is duplicated in this test.
#>

[CmdletBinding()]
param(
    [string] $WorkflowPath = (Join-Path $PSScriptRoot '..\terraform\canary-ring-0\.github\workflows\issue-triage.md'),
    [string] $BashPath = $(if ($IsWindows) { 'C:\Program Files\Git\bin\bash.exe' } else { 'bash' }),
    [string[]] $CaseName = @('*')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-WorkflowShell {
    param([string] $Name)
    $lines = [IO.File]::ReadAllLines((Resolve-Path $WorkflowPath))
    $nameIndex = @(0..($lines.Length - 1) | Where-Object { $lines[$_].Trim() -in @("name: $Name", "- name: $Name") })
    if ($nameIndex.Count -ne 1) { throw "Expected exactly one step named '$Name'." }
    $runIndex = $nameIndex[0] + 1
    while ($runIndex -lt $lines.Length -and $lines[$runIndex] -notmatch '^\s+run: \|[-+]?$') { $runIndex++ }
    if ($runIndex -eq $lines.Length) { throw "No shell body for '$Name'." }
    $indent = $lines[$runIndex].Length - $lines[$runIndex].TrimStart().Length + 2
    $body = [Collections.Generic.List[string]]::new()
    for ($i = $runIndex + 1; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Trim().Length -eq 0) { $body.Add(''); continue }
        if (-not $lines[$i].StartsWith(' ' * $indent)) { break }
        $body.Add($lines[$i].Substring($indent))
    }
    return ($body -join "`n") + "`n"
}

function ConvertTo-BashPath {
    param([string] $Path)
    if ($IsWindows) { return '/' + $Path.Substring(0, 1).ToLowerInvariant() + $Path.Substring(2).Replace('\', '/') }
    return $Path
}

function Write-Json {
    param([string] $Path, $Value)
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 40 -Compress), [Text.UTF8Encoding]::new($false))
}

function Add-Response {
    param($Case, [string] $Request, $Body, [int] $ExitCode = 0)
    $Case.Responses[$Request] = @{
        body = (ConvertTo-Json -InputObject $Body -Depth 40 -Compress)
        exit_code = $ExitCode
    }
}

function New-Comparison {
    param([string] $Base, [string] $Head, [string] $Status = 'ahead', [int] $Ahead = 301)
    $common = switch ($Status) { 'behind' { $Head } 'diverged' { 'e' * 40 } default { $Base } }
    return @{
        base_commit = @{ sha = $Base }
        merge_base_commit = @{ sha = $common }
        status = $Status
        ahead_by = $(if ($Status -in @('identical', 'behind')) { 0 } else { $Ahead })
        behind_by = $(if ($Status -in @('behind', 'diverged')) { 3 } else { 0 })
        total_commits = $Ahead
        # Deliberately incomplete, and unrelated to the PR number.
        commits = @(@{ commit = @{ message = 'chore: run avm pre-commit [skip ci]' } })
    }
}

function New-Release {
    param([int] $Id = 1, [string] $Tag = 'v1.0.0', [string] $Published = '2026-09-01T00:00:00Z')
    return @{ id = $Id; tag_name = $Tag; published_at = $Published; draft = $false; prerelease = $false }
}

function New-Pr {
    param([int] $Number = 270)
    return @{
        number = $Number; merged = $true; draft = $false; merge_commit_sha = $script:Merge
        base = @{ ref = 'main'; repo = @{ full_name = 'owner/module' } }
    }
}

function New-Case {
    param([string] $Name, [string] $Expected = 'released', [string] $Reason = 'release_contains_merge_commit')
    $case = @{
        Name = $Name; Numbers = @(270); Complete = $true; MissingIndex = $false; Budget = 200
        Expected = @{ '270' = @($Expected, $Reason) }; Responses = @{}
        HasRelease = $true; Loaded = $true; Tags = @{}; Mode = 'prefetched'; Selected = '270'
    }
    Add-Response $case $script:ReleaseRequest @(New-Release)
    Add-Response $case $script:DefaultRequest @{ sha = $script:Default }
    Add-Response $case $script:TagRequest @{ sha = $script:Release }
    Add-Response $case 'api repos/owner/module/pulls/270' (New-Pr)
    Add-Response $case $script:DefaultCompare (New-Comparison $script:Merge $script:Default)
    Add-Response $case $script:ReleaseCompare (New-Comparison $script:Merge $script:Release)
    return $case
}

function Add-OlderRelease {
    param($Case, [string] $Status = 'ahead')
    Add-Response $Case $script:ReleaseRequest @((New-Release), (New-Release 2 'v0.9.0' '2026-08-01T00:00:00Z'))
    Add-Response $Case 'api repos/owner/module/commits/refs%2Ftags%2Fv0.9.0' @{ sha = $script:Older }
    Add-Response $Case "api repos/owner/module/compare/$script:Merge...$script:Older`?per_page=1" (New-Comparison $script:Merge $script:Older $Status)
}

function Write-Evidence {
    param($Case, [string] $Directory)
    $candidates = @($Case.Numbers | ForEach-Object {
        @{
            number = $_; title = 'Fix reported behavior'; url = "https://github.com/owner/module/pull/$_"
            state = 'MERGED'; draft = $false; merged = $true; body_excerpt = 'Fixes #1'
            sources = @('issue_number_search_body', 'merged_pr_inventory')
            file_names = @('main.tf'); file_names_truncated = $false
            open_inventory = $false; merged_inventory = $true
            lexical_relevance = @{ score = 20; plausible = $true; signals = @{} }
        }
    })
    $shared = @{
        loaded = $true; complete = $Case.Complete; success = $Case.Complete; errors = @()
        candidate_count = $candidates.Count; open_inventory_count = 0; merged_inventory_count = $candidates.Count
        required_inspection_count = $candidates.Count; required_inspection_numbers = $Case.Numbers
    }
    $status = $shared.Clone()
    $status.exact_required_inspection_count = $candidates.Count
    $status.exact_required_inspection_numbers = $Case.Numbers
    $status.timeline_required_inspection_count = 0
    $status.timeline_required_inspection_numbers = @()
    $status.commit_required_inspection_count = 0
    $status.commit_required_inspection_numbers = @()
    $status.screening_index_path = "$Directory/pr-candidate-screening-index.json"
    $status.index_version = 1
    $index = $shared.Clone()
    $index.version = 1
    $index.required_inspection = $candidates
    $index.open_inventory_screening = @()
    if ($Case.MissingIndex) { $index = @{} }
    Write-Json (Join-Path $Directory 'pr-candidate-status.json') $status
    Write-Json (Join-Path $Directory 'pr-candidate-screening-index.json') $index
    Write-Json (Join-Path $Directory 'issue-candidate-index.json') @{ loaded = $false }
}

$script:Merge = 'c' * 40
$script:Default = 'd' * 40
$script:Release = 'b' * 40
$script:Older = 'a' * 40
$script:ReleaseRequest = 'api --paginate repos/owner/module/releases?per_page=100'
$script:DefaultRequest = 'api repos/owner/module/commits/refs%2Fheads%2Fmain'
$script:TagRequest = 'api repos/owner/module/commits/refs%2Ftags%2Fv1.0.0'
$script:DefaultCompare = "api repos/owner/module/compare/$Merge...$Default`?per_page=1"
$script:ReleaseCompare = "api repos/owner/module/compare/$Merge...$Release`?per_page=1"
$cases = [Collections.Generic.List[hashtable]]::new()

$case = New-Case 'released beyond 250 commits without PR numbers'
$comparison = New-Comparison $Merge $Release
$comparison.commits = @(1..250 | ForEach-Object { @{ commit = @{ message = 'Maintenance without PR identifiers' } } })
Add-Response $case $ReleaseCompare $comparison
$cases.Add($case)

foreach ($style in @('normal merge', 'squash merge', 'GitHub rebase merge')) {
    $cases.Add((New-Case "$style uses the post-merge commit, not head commits"))
}

$case = New-Case 'identical release and merge commits'
Add-Response $case $TagRequest @{ sha = $Merge }
Add-Response $case "api repos/owner/module/compare/$Merge...$Merge`?per_page=1" (New-Comparison $Merge $Merge 'identical')
$cases.Add($case)

$case = New-Case 'released summary needs no commits array'
$comparison = New-Comparison $Merge $Release
$comparison.Remove('commits')
Add-Response $case $ReleaseCompare $comparison
$cases.Add($case)

$case = New-Case 'unreleased PR absent from commit messages' 'awaiting_release' 'all_releases_precede_merge_commit'
Add-Response $case $ReleaseCompare (New-Comparison $Merge $Release 'behind')
Add-OlderRelease $case 'behind'
$cases.Add($case)

$case = New-Case 'misleading issue number in an unrelated commit does not imply release'
$comparison = New-Comparison $Merge $Release
$comparison.commits = @(@{ commit = @{ message = 'Unrelated maintenance refs #270 and #999' } })
Add-Response $case $ReleaseCompare $comparison
$cases.Add($case)

foreach ($relation in @('behind', 'diverged')) {
    $case = New-Case "older release proves inclusion after latest is $relation"
    Add-Response $case $ReleaseCompare (New-Comparison $Merge $Release $relation)
    Add-OlderRelease $case
    $case.Tags['270'] = 'v0.9.0'
    $cases.Add($case)
}

$case = New-Case 'latest divergent history is unknown' 'unknown' 'release_history_diverged'
Add-Response $case $ReleaseCompare (New-Comparison $Merge $Release 'diverged')
$cases.Add($case)

$case = New-Case 'cherry-picked equivalent commit is not ancestry proof' 'unknown' 'release_history_diverged'
Add-Response $case $ReleaseCompare (New-Comparison $Merge $Release 'diverged')
$cases.Add($case)

$case = New-Case 'older proof survives failed newest tag lookup'
Add-Response $case $TagRequest @{} 1
Add-OlderRelease $case
$case.Tags['270'] = 'v0.9.0'
$cases.Add($case)

$case = New-Case 'failed older comparison blocks awaiting release' 'unknown' 'release_comparison_unavailable'
Add-Response $case $ReleaseCompare (New-Comparison $Merge $Release 'behind')
Add-OlderRelease $case 'behind'
Add-Response $case "api repos/owner/module/compare/$Merge...$Older`?per_page=1" @{} 1
$cases.Add($case)

foreach ($failure in @('release listing fails after partial output', 'malformed release page', 'missing stable release timestamp')) {
    $case = New-Case $failure 'unknown' 'release_list_unavailable'
    $case.Loaded = $false
    $case.HasRelease = $null
    switch ($failure) {
        'release listing fails after partial output' { Add-Response $case $ReleaseRequest @(New-Release) 1 }
        'malformed release page' { Add-Response $case $ReleaseRequest @{} }
        default { $releaseEntry = New-Release; $releaseEntry.Remove('published_at'); Add-Response $case $ReleaseRequest @($releaseEntry) }
    }
    $cases.Add($case)
}

foreach ($empty in @('no releases', 'draft and prerelease only')) {
    $case = New-Case $empty 'unknown' 'no_published_release'
    $case.HasRelease = $false
    $releases = @()
    if ($empty -ne 'no releases') {
        $draft = New-Release; $draft.draft = $true
        $preview = New-Release 2; $preview.prerelease = $true
        $releases = @($draft, $preview)
    }
    Add-Response $case $ReleaseRequest $releases
    $cases.Add($case)
}

$case = New-Case 'all release pages sorted by publication date'
$case.Responses[$ReleaseRequest].body = (ConvertTo-Json -InputObject @((New-Release 2 'v0.9.0' '2026-08-01T00:00:00Z')) -Compress) + "`n" + (ConvertTo-Json -InputObject @((New-Release)) -Compress)
$cases.Add($case)

foreach ($duplicate in @('ID', 'tag')) {
    $case = New-Case "duplicate release $duplicate is ambiguous" 'unknown' 'release_list_unavailable'
    $case.Loaded = $false
    $case.HasRelease = $null
    $other = if ($duplicate -eq 'ID') { New-Release 1 'v0.9.0' } else { New-Release 2 'v1.0.0' }
    Add-Response $case $ReleaseRequest @((New-Release), $other)
    $cases.Add($case)
}

$case = New-Case 'partial PR evidence veto' 'unknown' 'incomplete_pr_evidence'
$case.Complete = $false
$case.Loaded = $false
$case.HasRelease = $null
$cases.Add($case)

$case = New-Case 'missing candidate index yields no proof' 'unknown' 'candidate_index_unavailable'
$case.MissingIndex = $true
$case.Expected = @{}
$case.Loaded = $false
$case.HasRelease = $null
$cases.Add($case)

foreach ($failure in @('PR fetch fails', 'wrong PR identity', 'unmerged test merge', 'draft PR', 'wrong base branch', 'wrong base repository', 'missing merge commit')) {
    $reason = switch ($failure) {
        { $_ -in @('PR fetch fails', 'wrong PR identity') } { 'pr_metadata_unavailable' }
        { $_ -in @('unmerged test merge', 'draft PR') } { 'pr_not_merged' }
        { $_ -in @('wrong base branch', 'wrong base repository') } { 'pr_not_targeting_default_branch' }
        default { 'merge_commit_unavailable' }
    }
    $case = New-Case $failure 'unknown' $reason
    $pr = New-Pr
    $exitCode = 0
    switch ($failure) {
        'PR fetch fails' { $exitCode = 1 }
        'wrong PR identity' { $pr.number = 271 }
        'unmerged test merge' { $pr.merged = $false }
        'draft PR' { $pr.draft = $true }
        'wrong base branch' { $pr.base.ref = 'maintenance' }
        'wrong base repository' { $pr.base.repo.full_name = 'different/module' }
        'missing merge commit' { $pr.merge_commit_sha = $null }
    }
    Add-Response $case 'api repos/owner/module/pulls/270' $pr $exitCode
    $cases.Add($case)
}

foreach ($relation in @('behind', 'diverged')) {
    $case = New-Case "merge missing from default branch ($relation)" 'unknown' 'default_branch_membership_unverified'
    Add-Response $case $DefaultCompare (New-Comparison $Merge $Default $relation)
    $cases.Add($case)
}

$case = New-Case 'default branch lookup fails' 'unknown' 'default_branch_unavailable'
Add-Response $case $DefaultRequest @{} 1
$case.Loaded = $false
$cases.Add($case)

$case = New-Case 'release tag lookup fails' 'unknown' 'release_tag_unavailable'
Add-Response $case $TagRequest @{} 1
$cases.Add($case)

foreach ($failure in @('comparison fails', 'missing summary with commits present', 'inconsistent counters', 'wrong merge base', 'wrong comparison base')) {
    $case = New-Case $failure 'unknown' 'release_comparison_unavailable'
    $comparison = New-Comparison $Merge $Release
    $exitCode = 0
    switch ($failure) {
        'comparison fails' { $exitCode = 1 }
        'missing summary with commits present' { $comparison.Remove('status') }
        'inconsistent counters' { $comparison.behind_by = 1 }
        'wrong merge base' { $comparison.merge_base_commit.sha = $Older }
        'wrong comparison base' { $comparison.base_commit.sha = $Older }
    }
    Add-Response $case $ReleaseCompare $comparison $exitCode
    $cases.Add($case)
}

$case = New-Case 'contradictory summary for identical commits' 'unknown' 'release_comparison_unavailable'
Add-Response $case $TagRequest @{ sha = $Merge }
Add-Response $case "api repos/owner/module/compare/$Merge...$Merge`?per_page=1" (New-Comparison $Merge $Merge 'behind')
$cases.Add($case)

$case = New-Case 'per-PR failure does not poison another proof'
$case.Numbers = @(269, 270, 271)
$case.Expected['269'] = @('unknown', 'pr_metadata_unavailable')
$case.Expected['271'] = @('released', 'release_contains_merge_commit')
Add-Response $case 'api repos/owner/module/pulls/269' @{} 1
Add-Response $case 'api repos/owner/module/pulls/271' (New-Pr 271)
$cases.Add($case)

$case = New-Case 'request budget preserves earlier proof and leaves the rest unknown'
$case.Numbers = @(270, 271)
$case.Budget = 6
$case.Expected['271'] = @('unknown', 'request_budget_exhausted')
$cases.Add($case)

$case = New-Case 'unrelated candidates exhaust the budget without implying release'
$case.Numbers = @(270..280)
$case.Budget = 8
foreach ($number in 271..280) {
    $pr = New-Pr $number
    $pr.merged = $false
    Add-Response $case "api repos/owner/module/pulls/$number" $pr
    $reason = if ($number -le 272) { 'pr_not_merged' } else { 'request_budget_exhausted' }
    $case.Expected[[string] $number] = @('unknown', $reason)
}
$cases.Add($case)

$case = New-Case 'encoded tag with slash'
Add-Response $case $ReleaseRequest @((New-Release 1 'module/v1.0.0'))
Add-Response $case 'api repos/owner/module/commits/refs%2Ftags%2Fmodule%2Fv1.0.0' @{ sha = $Release }
$case.Tags['270'] = 'module/v1.0.0'
$cases.Add($case)

$renderShell = Get-WorkflowShell 'Render triage evidence blocks'
$prepareShell = Get-WorkflowShell 'Prepare release proof verifier'
$releaseShell = Get-WorkflowShell 'Fetch release status'
if (-not ($prepareShell.Contains('REQUEST_LIMIT=200') -and $prepareShell.Contains('DEADLINE=$((SECONDS + 180))') -and $prepareShell.Contains('timeout 20s gh api'))) {
    throw 'Expected the production budgets: 200 invocations, 180 seconds, 20 seconds per invocation.'
}
if ($prepareShell -match 'unreleased_pr_numbers|unreleased_shas') { throw 'Release proof must not use a negative identifier list.' }
if (-not $releaseShell.Contains('triage-release-proof.sh prefetched')) { throw 'Prefetch must call the shared verifier.' }
if ($cases.Count -ne 45) { throw "Expected the original 45 scenarios, found $($cases.Count)." }
# Exercise the same positive algorithm for one selected PR outside the initial
# index. Do not manufacture an index entry or replace the validation marker.
foreach ($original in @($cases.ToArray())) {
    if ($original.Expected.Count -ne 1 -or -not $original.Complete -or $original.MissingIndex) { continue }
    $selected = $original | ConvertTo-Json -Depth 50 -Compress | ConvertFrom-Json -AsHashtable
    $selected.Name = 'selected outside index: ' + $original.Name
    $selected.Mode = 'selected'
    $selected.Numbers = @(227)
    $cases.Add($selected)
}
$case = New-Case 'selected mode does not fabricate discovery success'
$case.Mode = 'selected'; $case.MissingIndex = $true; $case.Complete = $false
$cases.Add($case)
foreach ($invalid in @('0', '-1', '1.5', '9007199254740992', '56;echo unsafe', 'abc')) {
    $case = New-Case "selected rejects invalid number $invalid"
    $case.Mode = 'selected'; $case.Selected = $invalid
    $case.Expected = @{}; $case.Loaded = $false; $case.HasRelease = $null
    $cases.Add($case)
}
$case = New-Case 'selected request budget fails closed' 'unknown' 'request_budget_exhausted'
$case.Mode = 'selected'; $case.Budget = 3
$cases.Add($case)
$cases = @($cases | Where-Object {
    $name = $_.Name
    @($CaseName | Where-Object { $name -like $_ }).Count -gt 0
})
if ($cases.Count -eq 0) { throw 'No release-proof scenarios matched CaseName.' }
$mockHeader = @'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_RELEASE_FIXTURE_DIR}/calls.txt"
case "$*" in
'@
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('avm-release-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $bin = Join-Path $temporaryRoot 'bin'
    [IO.Directory]::CreateDirectory($bin) | Out-Null
    if ($IsWindows) {
        # Native Windows jq emits CRLF unless --binary is set. Match the Ubuntu runner.
        $jqShim = "#!/usr/bin/env bash`n" + 'exec "$GH_RELEASE_REAL_JQ" --binary "$@"' + "`n"
        [IO.File]::WriteAllText((Join-Path $bin 'jq'), $jqShim, [Text.UTF8Encoding]::new($false))
    }
    $number = 0
    foreach ($case in $cases) {
        $number++
        $directory = Join-Path $temporaryRoot "case-$number"
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        Write-Evidence $case $directory
        # A shell-only transport avoids spawning a JSON parser for each mocked request.
        $mock = $mockHeader.Replace("`r`n", "`n") + "`n"
        foreach ($request in $case.Responses.Keys) {
            $response = $case.Responses[$request]
            $quotedRequest = $request.Replace("'", "'\''")
            $quotedBody = $response.body.Replace("'", "'\''")
            $mock += "'$quotedRequest') printf '%s\n' '$quotedBody'; exit $($response.exit_code);;`n"
        }
        $mock += '*) printf "Unexpected API request: %s\n" "$*" >&2; exit 99;;' + "`nesac`n"
        [IO.File]::WriteAllText((Join-Path $bin 'gh'), $mock, [Text.UTF8Encoding]::new($false))
        $bashDirectory = ConvertTo-BashPath $directory
        $bashBin = ConvertTo-BashPath $bin
        $script = 'export GH_RELEASE_REAL_JQ="$(command -v jq)"' + "`n"
        $script += "export PATH='$bashBin':`"`$PATH`"`nchmod +x '$bashBin/gh'`n"
        if ($IsWindows) { $script += "chmod +x '$bashBin/jq'`n" }
        $script += $renderShell.Replace('/tmp/gh-aw/agent', $bashDirectory)
        # Lower only the constant for the boundary case; execute the same budget logic.
        $script += $prepareShell.Replace('/tmp/gh-aw/agent', $bashDirectory).Replace('REQUEST_LIMIT=200', "REQUEST_LIMIT=$($case.Budget)")
        if ($case.Mode -eq 'selected') {
            $selectedNumber = $case.Selected.Replace("'", "'\''")
            $script += "bash '$bashDirectory/triage-release-proof.sh' selected '$bashDirectory' '$bashDirectory/release-status.json' '$selectedNumber'`n"
        } else {
            $script += $releaseShell.Replace('/tmp/gh-aw/agent', $bashDirectory)
        }
        $scriptPath = Join-Path $directory 'run.sh'
        [IO.File]::WriteAllText($scriptPath, $script, [Text.UTF8Encoding]::new($false))
        $start = [Diagnostics.ProcessStartInfo]::new($BashPath)
        $start.ArgumentList.Add((ConvertTo-BashPath $scriptPath))
        $start.Environment['GH_RELEASE_FIXTURE_DIR'] = $bashDirectory
        $start.Environment['GH_AW_GITHUB_REPOSITORY'] = 'owner/module'
        $start.Environment['DEFAULT_BRANCH'] = 'main'
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill($true)
            throw "$($case.Name): shell exceeded two minutes."
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$($case.Name): shell failed.`n$output" }
        $raw = Get-Content -LiteralPath (Join-Path $directory 'release-status.json') -Raw
        $result = $raw | ConvertFrom-Json
        if ($result.loaded -ne $case.Loaded -or $result.has_release -ne $case.HasRelease) { throw "$($case.Name): wrong shared result.`n$raw`n$output" }
        if ($result.prs.Count -ne $case.Expected.Count) { throw "$($case.Name): wrong per-PR count.`n$raw" }
        foreach ($proof in $result.prs) {
            $expected = $case.Expected[[string] $proof.number]
            if ($proof.status -ne $expected[0] -or $proof.reason -ne $expected[1]) { throw "$($case.Name): wrong proof.`n$raw`n$output" }
            $tag = if ($case.Tags.ContainsKey([string] $proof.number)) { $case.Tags[[string] $proof.number] } else { 'v1.0.0' }
            if ($proof.status -eq 'released' -and $proof.release_tag -ne $tag) { throw "$($case.Name): wrong proven release tag.`n$raw" }
            if ($proof.status -ne 'released' -and $null -ne $proof.release_tag) { throw "$($case.Name): unverified release tag leaked.`n$raw" }
        }
        if ($raw -match '[0-9a-f]{40}|unreleased_shas|unreleased_pr_numbers') { throw "$($case.Name): raw SHA or negative-list data leaked." }
        $callsPath = Join-Path $directory 'calls.txt'
        $calls = @(if (Test-Path $callsPath) { Get-Content $callsPath })
        foreach ($call in $calls) {
            if (-not $case.Responses.ContainsKey($call)) { throw "$($case.Name): unexpected request '$call'." }
        }
        if (@($calls | Where-Object { $_ -eq $TagRequest }).Count -gt 1) { throw "$($case.Name): release tag was not pinned once." }
        if ($calls.Count -gt $case.Budget) { throw "$($case.Name): request budget exceeded." }
        if ($case.Mode -eq 'prefetched' -and (-not $case.Complete -or $case.MissingIndex) -and $calls.Count -gt 0) { throw "$($case.Name): ignored evidence veto." }
        if ($case.Mode -eq 'selected') {
            if (@($calls | Where-Object { $_ -match '/pulls/' -and $_ -ne 'api repos/owner/module/pulls/270' }).Count -gt 0) { throw "$($case.Name): looked up a PR other than the selection." }
            if ($case.Expected.Count -eq 0 -and $calls.Count -ne 0) { throw "$($case.Name): invalid input performed API calls." }
            if ($case.MissingIndex) {
                $marker = Get-Content (Join-Path $directory 'pr-evidence-validation.json') -Raw | ConvertFrom-Json
                if ($marker.valid) { throw "$($case.Name): selected mode fabricated a validation marker." }
            }
        }
        Write-Host "PASS $($case.Name)"
    }
    Write-Host "All $($cases.Count) release-proof scenarios passed: $WorkflowPath"
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}
