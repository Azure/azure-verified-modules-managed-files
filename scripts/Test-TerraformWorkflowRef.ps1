#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $WorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check.yml'
    ),
    [string] $LabelWorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check-label.yml'
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
$expectedEventTypes = @('opened', 'reopened', 'synchronize')
if (-not $pullRequest.Success -or -not $types.Success -or
    [string]::Join(',', @($eventTypes | Sort-Object)) -cne [string]::Join(',', @($expectedEventTypes | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform PR workflow must run only for opened, reopened, and synchronize events.')
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
if (-not $jobName.Success -or $jobName.Groups[1].Value.Trim("'").Trim('"') -cne 'run managed workflow') {
    throw [System.InvalidOperationException]::new(
        "The Terraform caller job must retain the 'run managed workflow' name.")
}

$condition = [regex]::Match(
    $jobs[0].Value,
    '(?ms)^    if: >-\r?\n(?<condition>(?:      [^\r\n]*(?:\r?\n|\z))+)'
)
$conditionLines = @($condition.Groups['condition'].Value -split '\r?\n' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
$expectedCondition = @(
    "(github.event_name == 'workflow_dispatch') ||",
    "(github.event_name != 'pull_request') ||",
    '!(',
    "(github.event.pull_request.user.login == 'azure-verified-modules[bot]') &&",
    "startsWith(github.head_ref, 'avm-bot/pre-commit-') &&",
    '(github.event.pull_request.base.repo.full_name == github.repository) &&',
    '(github.event.pull_request.head.repo.full_name == github.repository)',
    ')'
)
if (-not $condition.Success -or
    [string]::Join(' ', $conditionLines) -cne [string]::Join(' ', $expectedCondition) -or
    $jobs[0].Value -match '(?m)github\.actor') {
    throw [System.InvalidOperationException]::new(
        'The Terraform caller must run workflow_dispatch and normal/fork PRs, but skip same-repository PRs created by the Azure Verified Modules app from avm-bot/pre-commit- branches; github.actor must not be used.')
}

$permissionBlock = [regex]::Match(
    $jobs[0].Value,
    '(?ms)^    permissions:\r?\n(?<permissions>(?:      [^\r\n]*\r?\n)+)'
)
$permissions = @($permissionBlock.Groups['permissions'].Value -split '\r?\n' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ })
$expectedPermissions = @('contents: read', 'id-token: write', 'issues: read', 'pull-requests: write')
if (-not $permissionBlock.Success -or
    [string]::Join(',', @($permissions | Sort-Object)) -cne [string]::Join(',', @($expectedPermissions | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform reusable workflow caller must grant contents: read, id-token: write, issues: read, and pull-requests: write.')
}

$references = [regex]::Matches($jobs[0].Value, '(?m)^    uses:[ \t]*(\S+)[ \t]*\r?$')
$expected = '^Azure/azure-verified-modules-tools/\.github/workflows/terraform-module\.yml@[0-9a-f]{40}$'
if ($references.Count -ne 1 -or $references[0].Groups[1].Value -cnotmatch $expected) {
    throw [System.InvalidOperationException]::new('The Terraform managed workflow must use the Tools terraform-module.yml workflow pinned to a full 40-character commit SHA; mutable references are not permitted.')
}
$expectedReference = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@6216cf3d7f8c0374effc3a9dc587d23e99d87e16'
if ($references[0].Groups[1].Value -cne $expectedReference) {
    throw [System.InvalidOperationException]::new(
        "The Terraform managed workflow must use the coordinated Tools revision '$expectedReference'.")
}

$labelContent = Get-Content -LiteralPath $LabelWorkflowPath -Raw
$labelTrigger = [regex]::Match(
    $labelContent,
    '(?ms)^  pull_request_target:\r?\n    types:[ \t]*\[(?<types>[^\]]+)\][ \t]*\r?$'
)
$labelEventTypes = @(
    $labelTrigger.Groups['types'].Value -split ',' |
        ForEach-Object { $_.Trim().Trim("'").Trim('"') }
)
$expectedLabelEventTypes = @('labeled', 'unlabeled')
if (-not $labelTrigger.Success -or
    [string]::Join(',', @($labelEventTypes | Sort-Object)) -cne [string]::Join(',', @($expectedLabelEventTypes | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform label workflow must use pull_request_target only for labeled and unlabeled events.')
}

$labelPermissions = [regex]::Match(
    $labelContent,
    '(?ms)^permissions:\r?\n(?<permissions>(?:  [^\r\n]+(?:\r?\n|\z))+)'
)
$permissionLines = @(
    $labelPermissions.Groups['permissions'].Value -split '\r?\n' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
$expectedLabelPermissions = @('actions: write', 'pull-requests: read')
if (-not $labelPermissions.Success -or
    [string]::Join(',', @($permissionLines | Sort-Object)) -cne [string]::Join(',', @($expectedLabelPermissions | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform label workflow must grant only actions: write and pull-requests: read.')
}

foreach ($label in @('PR: Run Required E2E Tests', 'PR: Run All E2E Tests')) {
    if ($labelContent -notmatch [regex]::Escape("github.event.label.name == '$label'")) {
        throw [System.InvalidOperationException]::new(
            "The Terraform label workflow must filter the '$label' label.")
    }
}

$requiredLabelWorkflowFragments = @(
    'pulls/$env:PULL_REQUEST',
    '$pullRequest.head.repo.full_name -cne $env:REPOSITORY',
    'use a same-repository release-branch handoff',
    '.head.sha',
    "^[0-9a-f]{40}$",
    'actions/workflows/pr-check.yml/runs?event=pull_request&head_sha=$headSha',
    '$_.pull_requests',
    '$_.number -eq $pullRequestNumber',
    'No pull_request PR Check run was found',
    "if (`$run[0].status -cne 'completed')",
    'Start-Sleep -Seconds 15',
    '$latestPullRequest.head.sha -cne $headSha',
    'actions/runs/$($run[0].id)/rerun'
)
foreach ($fragment in $requiredLabelWorkflowFragments) {
    if (-not $labelContent.Contains($fragment)) {
        throw [System.InvalidOperationException]::new(
            "The Terraform label workflow is missing required rerun behavior: '$fragment'.")
    }
}

if ($labelContent -match '(?m)^\s*(uses:|secrets:|actions/checkout@)' -or
    $labelContent -notmatch 'pull_request_target:' -or
    $labelContent -match '(?m)^\s*(workflow_dispatch:|repository_dispatch:)') {
    throw [System.InvalidOperationException]::new(
        'The Terraform label workflow must not execute PR code, consume secrets, or expose an alternate dispatch path.')
}

Write-Output 'Validated Terraform caller events, label rerun safety, permissions, managed workflow ref, and repo-sync PR guard.'
