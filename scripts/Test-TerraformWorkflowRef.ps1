#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $WorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check.yml'
    )
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$content = Get-Content -LiteralPath $WorkflowPath -Raw
$pullRequest = [regex]::Match(
    $content,
    '(?ms)^  pull_request:\r?\n(?<body>(?:(?!^  \S).*(?:\r?\n|\z))*)'
)
$types = [regex]::Match($pullRequest.Groups['body'].Value, '(?m)^    types:[ \t]*\[(?<types>[^\]]+)\][ \t]*$')
$eventTypes = @($types.Groups['types'].Value -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') })
$expectedEventTypes = @('opened', 'reopened', 'synchronize', 'labeled', 'unlabeled')
if (-not $pullRequest.Success -or -not $types.Success -or
    [string]::Join(',', @($eventTypes | Sort-Object)) -cne [string]::Join(',', @($expectedEventTypes | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform PR workflow must retain opened, reopened, and synchronize while admitting labeled and unlabeled events.')
}
if ($content -match '(?m)^  merge_group:\s*$' -or
    $content -notmatch '(?m)^  workflow_dispatch:\s*$') {
    throw [System.InvalidOperationException]::new(
        'The Terraform PR workflow must disable merge_group and preserve workflow_dispatch.')
}

$jobs = [regex]::Matches($content, '(?m)^  run-managed-workflow:\r?\n(?:(?!^  \S)[^\r\n]*(?:\r?\n|\z))*')
if ($jobs.Count -ne 1) {
    throw [System.InvalidOperationException]::new('Expected exactly one run-managed-workflow job.')
}

$jobName = [regex]::Match($jobs[0].Value, '(?m)^    name:[ \t]*([^\r\n]+)$')
$jobCondition = [regex]::Match(
    $jobs[0].Value,
    '(?ms)^    if:[ \t]*>-\r?\n(?<condition>(?:      [^\r\n]*\r?\n)+)(?=    \S|\z)'
)
$normalizedCondition = ($jobCondition.Groups['condition'].Value -replace '\s+', ' ').Trim()
$expectedCondition = "github.event_name != 'pull_request' || (github.event.action != 'labeled' && github.event.action != 'unlabeled') || github.event.label.name == 'PR: Run Required E2E Tests' || github.event.label.name == 'PR: Run All E2E Tests'"
if (-not $jobName.Success -or $jobName.Groups[1].Value.Trim("'").Trim('"') -cne 'run managed workflow' -or
    -not $jobCondition.Success -or $normalizedCondition -cne $expectedCondition) {
    throw [System.InvalidOperationException]::new(
        "The Terraform caller job must retain the 'run managed workflow' name and skip only unrelated label events.")
}

$permissionBlock = [regex]::Match(
    $jobs[0].Value,
    '(?ms)^    permissions:\r?\n(?<permissions>(?:      [^\r\n]*\r?\n)+)'
)
$permissions = @($permissionBlock.Groups['permissions'].Value -split '\r?\n' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
$expectedPermissions = @('contents: read', 'id-token: write', 'pull-requests: write')
if (-not $permissionBlock.Success -or
    [string]::Join(',', @($permissions | Sort-Object)) -cne [string]::Join(',', @($expectedPermissions | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform reusable workflow caller must grant only contents: read, id-token: write, and pull-requests: write.')
}

$references = [regex]::Matches($jobs[0].Value, '(?m)^    uses:[ \t]*(\S+)[ \t]*\r?$')
$expected = '^Azure/azure-verified-modules-tools/\.github/workflows/terraform-module\.yml@[0-9a-f]{40}$'
if ($references.Count -ne 1 -or $references[0].Groups[1].Value -cnotmatch $expected) {
    throw [System.InvalidOperationException]::new('The Terraform managed workflow must use the Tools terraform-module.yml workflow pinned to a full 40-character commit SHA; mutable references are not permitted.')
}

Write-Output 'Validated Terraform caller permissions, managed workflow ref, and PR event filter.'
