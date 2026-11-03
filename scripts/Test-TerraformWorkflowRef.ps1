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
$jobs = [regex]::Matches($content, '(?m)^  run-managed-workflow:\r?\n(?:(?!^  \S)[^\r\n]*(?:\r?\n|\z))*')
if ($jobs.Count -ne 1) {
    throw [System.InvalidOperationException]::new('Expected exactly one run-managed-workflow job.')
}

$references = [regex]::Matches($jobs[0].Value, '(?m)^    uses:[ \t]*(\S+)[ \t]*\r?$')
$expected = '^Azure/azure-verified-modules-tools/\.github/workflows/terraform-module\.yml@[0-9a-f]{40}$'
if ($references.Count -ne 1 -or $references[0].Groups[1].Value -cnotmatch $expected) {
    throw [System.InvalidOperationException]::new('The Terraform managed workflow must use the Tools terraform-module.yml workflow pinned to a full 40-character commit SHA; mutable references are not permitted.')
}

Write-Output 'Validated Terraform managed workflow ref.'
