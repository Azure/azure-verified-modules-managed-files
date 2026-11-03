#Requires -Version 7.4

<#
.SYNOPSIS
    Validate immutable action and reusable-workflow references in every file group.
.DESCRIPTION
    Parses all .github/workflows YAML files under Root, including this repository's
    own workflows. Remote GitHub references require a full commit SHA. Local
    references use the caller commit; Docker references require a SHA256 digest.
.PARAMETER Root
    Repository or fixture root to inspect.
.EXAMPLE
    ./scripts/Test-WorkflowShaPins.ps1
.OUTPUTS
    A validation summary. Throws when YAML or any reference is invalid.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop

function Assert-WorkflowReference {
    param([object] $Reference, [string] $Location)

    if ($Reference -is [string] -and (
        ($Reference -cmatch '^\./[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -and
        $Reference.Substring(2) -cnotmatch '(?:^|/)\.\.?(?:/|$)') -or
        $Reference -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[0-9a-fA-F]{40}$' -or
        $Reference -cmatch '^docker://[A-Za-z0-9._:/-]+@sha256:[0-9a-fA-F]{64}$'
    )) {
        return
    }
    throw [System.IO.InvalidDataException]::new(
        "${Location}: uses must be a local path, a GitHub reference pinned to a full commit SHA, or a Docker SHA256 digest; found '$Reference'.")
}

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.FullName -match '[\\/]\.github[\\/]workflows[\\/][^\\/]+\.ya?ml$'
    } | Sort-Object FullName)
if ($files.Count -eq 0) {
    throw [System.IO.InvalidDataException]::new("No workflow YAML files found under '$Root'.")
}
$references = 0
foreach ($file in $files) {
    $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName)
    $workflow = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $file.FullName -Raw)
    if ($workflow -isnot [System.Collections.IDictionary] -or
        $workflow['jobs'] -isnot [System.Collections.IDictionary] -or $workflow['jobs'].Count -eq 0) {
        throw [System.IO.InvalidDataException]::new("${relative}: expected a workflow with jobs.")
    }
    foreach ($jobName in $workflow['jobs'].Keys) {
        $job = $workflow['jobs'][$jobName]
        if ($job -isnot [System.Collections.IDictionary]) {
            throw [System.IO.InvalidDataException]::new("${relative}: job '$jobName' must be a mapping.")
        }
        if ($job.Contains('uses')) {
            Assert-WorkflowReference -Reference $job['uses'] -Location "${relative}:jobs.$jobName"
            $references++
        }
        foreach ($step in @($job['steps'])) {
            if ($null -eq $step) { continue }
            if ($step -isnot [System.Collections.IDictionary]) {
                throw [System.IO.InvalidDataException]::new("${relative}: job '$jobName' contains an invalid step.")
            }
            if ($step.Contains('uses')) {
                Assert-WorkflowReference -Reference $step['uses'] -Location "${relative}:jobs.$jobName.steps"
                $references++
            }
        }
    }
}
Write-Output "Validated $references uses references in $($files.Count) workflows."
