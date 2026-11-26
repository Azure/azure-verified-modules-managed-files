#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $WorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check.yml'
    ),
    [string] $LabelWorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check-label.yml'
    ),
    [string] $ObserverWorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check-label-observer.yml'
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
$expectedReference = 'Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@4ba5ab579d2a5074236aec42bfd831102fb70ca7'
if ($references[0].Groups[1].Value -cne $expectedReference) {
    throw [System.InvalidOperationException]::new(
        "The Terraform managed workflow must use the coordinated Tools revision '$expectedReference'.")
}

$observerContent = Get-Content -LiteralPath $ObserverWorkflowPath -Raw
$observerTrigger = [regex]::Match(
    $observerContent,
    '(?ms)^  pull_request:\r?\n    types:[ \t]*\[(?<types>[^\]]+)\][ \t]*\r?$'
)
$observerEventTypes = @(
    $observerTrigger.Groups['types'].Value -split ',' |
        ForEach-Object { $_.Trim().Trim("'").Trim('"') }
)
$expectedLabelEventTypes = @('labeled', 'unlabeled')
if ($observerContent -notmatch '(?m)^name: PR Check Label Observer\r?$' -or
    -not $observerTrigger.Success -or
    [string]::Join(',', @($observerEventTypes | Sort-Object)) -cne [string]::Join(',', @($expectedLabelEventTypes | Sort-Object)) -or
    $observerContent -notmatch '(?m)^permissions: \{\}\r?$') {
    throw [System.InvalidOperationException]::new(
        'The Terraform label observer must use only pull_request labeled/unlabeled events, retain its unique name, and grant no permissions.')
}

$labelContent = Get-Content -LiteralPath $LabelWorkflowPath -Raw
$labelTrigger = [regex]::Match(
    $labelContent,
    '(?ms)^  workflow_run:\r?\n    workflows:[ \t]*\[(?<workflows>[^\]]+)\][ \t]*\r?\n    types:[ \t]*\[(?<types>[^\]]+)\][ \t]*\r?$'
)
$labelWorkflows = @(
    $labelTrigger.Groups['workflows'].Value -split ',' |
        ForEach-Object { $_.Trim().Trim("'").Trim('"') }
)
$labelEventTypes = @(
    $labelTrigger.Groups['types'].Value -split ',' |
        ForEach-Object { $_.Trim().Trim("'").Trim('"') }
)
if (-not $labelTrigger.Success -or
    [string]::Join(',', $labelWorkflows) -cne 'PR Check Label Observer' -or
    [string]::Join(',', $labelEventTypes) -cne 'completed') {
    throw [System.InvalidOperationException]::new(
        'The Terraform label rerun must use workflow_run only for completed PR Check Label Observer runs.')
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
$expectedLabelPermissions = @(
    'actions: write',
    'contents: read',
    'issues: read',
    'pull-requests: read'
)
if (-not $labelPermissions.Success -or
    [string]::Join(',', @($permissionLines | Sort-Object)) -cne [string]::Join(',', @($expectedLabelPermissions | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform label workflow must grant exactly the reusable rerun workflow permissions: actions: write, contents: read, issues: read, and pull-requests: read.')
}

$labelJobsBlock = [regex]::Match($labelContent, '(?ms)^jobs:\r?\n(?<jobs>(?:  [^\r\n]*(?:\r?\n|\z))+)$')
$labelJobs = [regex]::Matches($labelJobsBlock.Groups['jobs'].Value, '(?m)^  [a-zA-Z0-9_-]+:\r?$')
$observerJobsBlock = [regex]::Match($observerContent, '(?ms)^jobs:\r?\n(?<jobs>(?:  [^\r\n]*(?:\r?\n|\z))+)$')
$observerJobs = [regex]::Matches($observerJobsBlock.Groups['jobs'].Value, '(?m)^  [a-zA-Z0-9_-]+:\r?$')
if (-not $labelJobsBlock.Success -or $labelJobs.Count -ne 1 -or
    -not $observerJobsBlock.Success -or $observerJobs.Count -ne 1) {
    throw [System.InvalidOperationException]::new(
        'Each Terraform label wrapper must contain exactly one reusable-workflow job.')
}

$labelUses = [regex]::Matches($labelContent, '(?m)^    uses:[ \t]*(\S+)[ \t]*\r?$')
$observerUses = [regex]::Matches($observerContent, '(?m)^    uses:[ \t]*(\S+)[ \t]*\r?$')
$expectedLabelReference = 'Azure/azure-verified-modules-tools/.github/workflows/pr-check-label-rerun.yml@' +
    $expectedReference.Substring($expectedReference.LastIndexOf('@') + 1)
$expectedObserverReference = 'Azure/azure-verified-modules-tools/.github/workflows/pr-check-label-observer.yml@' +
    $expectedReference.Substring($expectedReference.LastIndexOf('@') + 1)
if ($labelUses.Count -ne 1 -or $labelUses[0].Groups[1].Value -cne $expectedLabelReference) {
    throw [System.InvalidOperationException]::new(
        "The Terraform label job must use the coordinated Tools reusable workflow '$expectedLabelReference'.")
}
if ($observerUses.Count -ne 1 -or $observerUses[0].Groups[1].Value -cne $expectedObserverReference) {
    throw [System.InvalidOperationException]::new(
        "The Terraform observer job must use the coordinated Tools reusable workflow '$expectedObserverReference'.")
}

$toolsRef = [regex]::Match(
    $labelContent,
    '(?m)^      tools-ref:[ \t]*[''"]?(?<ref>[0-9a-f]{40})[''"]?[ \t]*\r?$'
)
if (-not $toolsRef.Success -or
    $toolsRef.Groups['ref'].Value -cne $labelUses[0].Groups[1].Value.Substring($labelUses[0].Groups[1].Value.LastIndexOf('@') + 1)) {
    throw [System.InvalidOperationException]::new(
        'The Terraform label workflow tools-ref input must match the pinned reusable workflow SHA.')
}

$observerPath = [regex]::Match(
    $labelContent,
    "(?m)^      observer-workflow-path:[ \t]*['`"]?\.github/workflows/pr-check-label-observer\.yml['`"]?[ \t]*\r?$"
)
if (-not $observerPath.Success) {
    throw [System.InvalidOperationException]::new(
        'The Terraform rerun caller must identify the exact observer workflow path.')
}

if (($labelContent + $observerContent) -match '(?m)^\s+(if|runs-on|timeout-minutes|steps|concurrency|secrets|env):' -or
    ($labelContent + $observerContent) -match 'pull_request_target:' -or
    ($labelContent + $observerContent) -match '(?m)^\s*(workflow_dispatch:|repository_dispatch:)') {
    throw [System.InvalidOperationException]::new(
        'The Terraform label wrappers must delegate rerun behavior to Tools without local filtering, orchestration, secrets, or alternate dispatch.')
}

Write-Output 'Validated Terraform PR Check, two-stage label caller wiring, permissions, managed workflow refs, and repo-sync PR guard.'
