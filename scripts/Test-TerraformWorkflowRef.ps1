#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $WorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check.yml'
    ),
    [string] $LabelWorkflowPath = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'terraform', 'root', '.github', 'workflows', 'pr-check-e2e-label.yml'
    )
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-PullRequestEventTypes {
    param([string] $Content, [string] $Path)

    $pullRequest = [regex]::Match(
        $Content,
        '(?ms)^  pull_request:\r?\n(?<body>(?:(?!^  \S).*(?:\r?\n|\z))*)'
    )
    $types = [regex]::Match(
        $pullRequest.Groups['body'].Value,
        '(?m)^    types:[ \t]*\[(?<types>[^\]]+)\][ \t]*$'
    )
    if (-not $pullRequest.Success -or -not $types.Success) {
        throw [System.InvalidOperationException]::new(
            "$Path must define inline pull_request types.")
    }
    return @($types.Groups['types'].Value -split ',' |
        ForEach-Object { $_.Trim().Trim("'").Trim('"') })
}

function Get-JobTextField {
    param([string] $Job, [string] $Field)

    $fieldMatch = [regex]::Match(
        $Job,
        "(?m)^    ${Field}:[ \t]*(?<inline>[^\r\n]*)\r?$"
    )
    if (-not $fieldMatch.Success) {
        return $null
    }

    $inline = $fieldMatch.Groups['inline'].Value.Trim()
    if ($inline -ne '>-') {
        return $inline
    }

    $foldedMatch = [regex]::Match(
        $Job,
        "(?ms)^    ${Field}:[ \t]*>-\r?\n(?<value>(?:      [^\r\n]*(?:\r?\n|\z))*)"
    )
    if (-not $foldedMatch.Success) {
        return $null
    }
    return ($foldedMatch.Groups['value'].Value -replace '\s+', ' ').Trim()
}

function Test-ManagedCaller {
    param([string] $Content, [string] $Path)

    $jobs = [regex]::Matches(
        $Content,
        '(?m)^  run-managed-workflow:\r?\n(?:(?!^  \S)[^\r\n]*(?:\r?\n|\z))*'
    )
    if ($jobs.Count -ne 1) {
        throw [System.InvalidOperationException]::new(
            "$Path must contain exactly one run-managed-workflow job.")
    }

    $job = $jobs[0].Value
    $permissionBlock = [regex]::Match(
        $job,
        '(?ms)^    permissions:\r?\n(?<permissions>(?:      [^\r\n]*\r?\n)+)'
    )
    $permissions = @($permissionBlock.Groups['permissions'].Value -split '\r?\n' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
    $expectedPermissions = @('contents: read', 'id-token: write', 'pull-requests: write')
    if (-not $permissionBlock.Success -or
        [string]::Join(',', @($permissions | Sort-Object)) -cne
        [string]::Join(',', @($expectedPermissions | Sort-Object))) {
        throw [System.InvalidOperationException]::new(
            "$Path must grant only contents: read, id-token: write, and pull-requests: write.")
    }

    $references = [regex]::Matches($job, '(?m)^    uses:[ \t]*(\S+)[ \t]*\r?$')
    $expected = '^Azure/azure-verified-modules-tools/\.github/workflows/terraform-module\.yml@[0-9a-f]{40}$'
    if ($references.Count -ne 1 -or $references[0].Groups[1].Value -cnotmatch $expected) {
        throw [System.InvalidOperationException]::new(
            "$Path must use terraform-module.yml pinned to a full 40-character commit SHA.")
    }

    $inputs = [regex]::Match(
        $job,
        '(?ms)^    with:\r?\n(?<inputs>(?:      [^\r\n]*\r?\n)+)'
    )
    if (-not $inputs.Success -or $job -notmatch '(?m)^    secrets:[ \t]*inherit[ \t]*\r?$') {
        throw [System.InvalidOperationException]::new(
            "$Path must preserve the reusable workflow inputs and inherited secrets.")
    }

    return [pscustomobject]@{
        Job       = $job
        Inputs    = ($inputs.Groups['inputs'].Value -replace '\s+', ' ').Trim()
        Reference = $references[0].Groups[1].Value
    }
}

$content = Get-Content -LiteralPath $WorkflowPath -Raw
$eventTypes = @(Get-PullRequestEventTypes -Content $content -Path $WorkflowPath)
$expectedEventTypes = @('opened', 'reopened', 'synchronize')
if ([string]::Join(',', @($eventTypes | Sort-Object)) -cne
    [string]::Join(',', @($expectedEventTypes | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform PR workflow must run only for opened, reopened, and synchronize events.')
}
if ($content -match '(?m)^  merge_group:\s*$' -or
    $content -notmatch '(?m)^  workflow_dispatch:\s*$') {
    throw [System.InvalidOperationException]::new(
        'The Terraform PR workflow must disable merge_group and preserve workflow_dispatch.')
}

$standardCaller = Test-ManagedCaller -Content $content -Path $WorkflowPath
if ($content -notmatch '(?m)^name:[ \t]*PR Check[ \t]*\r?$' -or
    (Get-JobTextField -Job $standardCaller.Job -Field 'name') -cne 'run managed workflow') {
    throw [System.InvalidOperationException]::new(
        "The Terraform caller must retain the 'PR Check' workflow and 'run managed workflow' job names.")
}

$labelContent = Get-Content -LiteralPath $LabelWorkflowPath -Raw
$labelEventTypes = @(Get-PullRequestEventTypes -Content $labelContent -Path $LabelWorkflowPath)
$expectedLabelEventTypes = @('labeled', 'unlabeled')
if ([string]::Join(',', @($labelEventTypes | Sort-Object)) -cne
    [string]::Join(',', @($expectedLabelEventTypes | Sort-Object))) {
    throw [System.InvalidOperationException]::new(
        'The Terraform label workflow must run only for labeled and unlabeled events.')
}
if ($labelContent -match '(?m)^  merge_group:\s*$' -or
    $labelContent -match '(?m)^  workflow_dispatch:\s*$' -or
    $labelContent -notmatch '(?m)^name:[ \t]*PR Check - E2E Labels[ \t]*\r?$') {
    throw [System.InvalidOperationException]::new(
        'The Terraform label workflow must remain a label-only, non-required-check workflow.')
}

$labelCaller = Test-ManagedCaller -Content $labelContent -Path $LabelWorkflowPath
$expectedCondition = "github.event.label.name == 'PR: Run Required E2E Tests' || github.event.label.name == 'PR: Run All E2E Tests'"
$expectedLabelJobName = "`$`{{ ($expectedCondition) && 'run managed workflow' || 'ignore unrelated label event' }}"
if ((Get-JobTextField -Job $labelCaller.Job -Field 'if') -cne $expectedCondition -or
    (Get-JobTextField -Job $labelCaller.Job -Field 'name') -cne $expectedLabelJobName) {
    throw [System.InvalidOperationException]::new(
        'The label caller must run only for E2E label events and use the required caller name only for those events.')
}
if ($standardCaller.Reference -cne $labelCaller.Reference) {
    throw [System.InvalidOperationException]::new(
        'The Terraform PR and E2E label workflows must use the same pinned reusable workflow.')
}
if ($standardCaller.Inputs -cne $labelCaller.Inputs) {
    throw [System.InvalidOperationException]::new(
        'The Terraform PR and E2E label workflows must pass the same reusable workflow inputs.')
}

Write-Output 'Validated Terraform caller permissions, managed workflow refs, and split PR event filters.'
