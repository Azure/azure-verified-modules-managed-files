#Requires -Version 7.4
<#
.SYNOPSIS
    Keeps the staged triage pair out of root and every other overlay.
.DESCRIPTION
    Checks exact published v1.0.29 bytes without fetching tags. The tools repository owns cohort membership; canary-ring-0 must remain example-only until separately approved.
#>
[CmdletBinding()]
param(
    [string] $Root = (Join-Path $PSScriptRoot '..')
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$stable = @{
    'issue-triage.md' = '59fad2161edd79e8a3900121bb0ef8e73f89b223'
    'issue-triage.lock.yml' = 'c107d0f56dc889c973c0f33bce7eae622dcc5245'
}
$groups = @(Get-ChildItem -LiteralPath (Join-Path $Root 'terraform') -Directory)
foreach ($name in $stable.Keys) {
    $relative = ".github/workflows/$name"
    $rootFile = Join-Path $Root "terraform/root/$relative"
    $overlayFile = Join-Path $Root "terraform/canary-ring-0/$relative"
    foreach ($file in @($rootFile, $overlayFile)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing triage pair member: $file" }
    }
    $rootBlob = git hash-object --no-filters -- $rootFile
    if ($LASTEXITCODE -ne 0 -or $rootBlob -ne $stable[$name]) { throw "Root $name must match published v1.0.29 exactly." }
    $overlayBlob = git hash-object --no-filters -- $overlayFile
    if ($LASTEXITCODE -ne 0 -or $overlayBlob -eq $stable[$name]) { throw "Example overlay $name must contain the staged candidate." }
    foreach ($group in $groups) {
        $config = Get-Content -LiteralPath (Join-Path $group.FullName '_config.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($deleted in $config['deletedFiles']) {
            if ($relative -like $deleted.Replace('\', '/')) { throw "$($group.Name) deletes $relative and breaks triage isolation." }
        }
        if ($config['managedLines']) {
            foreach ($managed in $config['managedLines'].Keys) {
                if ($relative -like $managed.Replace('\', '/')) { throw "$($group.Name) modifies $relative through managedLines." }
            }
        }
        if ($group.Name -notin @('root', 'canary-ring-0') -and (Test-Path -LiteralPath (Join-Path $group.FullName $relative))) {
            throw "$($group.Name) shadows the triage pair."
        }
    }
    Write-Host "$name : non-example groups resolve v1.0.29 ($rootBlob); canary-ring-0 overrides root ($overlayBlob)."
}
