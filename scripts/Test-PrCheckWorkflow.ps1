#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $WorkflowPath = (Join-Path $PSScriptRoot '..\terraform\root\.github\workflows\pr-check.yml')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$expected = @'
---
name: PR Check
on:
  pull_request:
    types: ['opened', 'reopened', 'synchronize']
  merge_group:
  workflow_dispatch:

jobs:
  run-managed-workflow:
    uses: Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@main
    name: run managed workflow
    secrets: inherit
    permissions:
      id-token: write
      contents: read
'@

$actual = Get-Content -LiteralPath $WorkflowPath -Raw
$expectedLines = @($expected -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$actualLines = @($actual -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$differences = @(Compare-Object -ReferenceObject $expectedLines -DifferenceObject $actualLines -CaseSensitive -SyncWindow 0)
if ($differences.Count -gt 0) {
    $details = ($differences | Format-Table -AutoSize | Out-String).TrimEnd()
    throw [System.InvalidOperationException]::new(
        "PR caller contract changed. Preserve the existing triggers and unconditional reusable call for forks, same-repository PRs, and drafts. Privileged-test gates belong in the reusable workflow.`n$details"
    )
}

Write-Host 'Validated the unconditional PR caller, unchanged triggers, and delegated permissions.'
