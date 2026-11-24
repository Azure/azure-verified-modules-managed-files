#Requires -Version 7.4

[CmdletBinding()]
param(
    [string]$WorkflowPath = './terraform/root/.github/workflows/dependabot-precommit.yml'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $WorkflowPath -ErrorAction Stop).ProviderPath
$content = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop

$requirements = [ordered]@{
    'PSResourceGet minimum version' = '-MinimumVersion 1.2.0'
    'MAR repository name' = 'Register-PSResourceRepository -Name MAR'
    'MAR URI' = '-Uri "$marUri/"'
    'MAR Avm.Authoring repository' = '-Repository MAR'
    'Avm.Authoring package name' = '-Name avm.authoring'
    'module update notice opt-out' = 'avm pre-commit -SkipModuleVersionCheck'
}

$missing = @(
    foreach ($requirement in $requirements.GetEnumerator()) {
        if (-not $content.Contains($requirement.Value)) {
            "$($requirement.Key): '$($requirement.Value)'"
        }
    }
)

if ($missing.Count -gt 0) {
    throw "Dependabot pre-commit workflow contract failed for $resolvedPath. Missing:`n$($missing -join "`n")"
}

Write-Output "Dependabot pre-commit workflow contract passed."
