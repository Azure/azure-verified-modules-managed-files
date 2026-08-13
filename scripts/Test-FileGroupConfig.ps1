#Requires -Version 7.4

<#
.SYNOPSIS
    Validates the per-file-group `_config.json` files in this repository.

.DESCRIPTION
    Every folder directly under a language folder (for example `terraform/`) is a
    file group. Each group must carry a reserved `_config.json` at its root that
    is never synced to target repositories. This script asserts that:

      * every file group has a `_config.json`;
      * each `_config.json` is valid JSON and declares a non-empty `description`;
      * only known keys are declared;
      * `deletedFiles` is an array of non-empty strings;
      * `managedLines` maps relative paths to `required` / `removed` string arrays;
      * no `.gitkeep` placeholder files remain.
#>

[CmdletBinding()]
param(
    [string] $Root
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:ConfigFileName = '_config.json'
$script:LanguageFolders = @('terraform')
$script:KnownKeys = @('description', 'deletedFiles', 'managedLines')

function Get-AvmFileGroupDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    $groups = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    foreach ($language in $script:LanguageFolders) {
        $languagePath = Join-Path -Path $Root -ChildPath $language
        if (-not (Test-Path -LiteralPath $languagePath)) {
            continue
        }

        foreach ($directory in @(Get-ChildItem -LiteralPath $languagePath -Directory | Sort-Object -Property Name)) {
            $groups.Add($directory)
        }
    }

    return $groups
}

function Get-AvmFileGroupConfigFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        return @("$GroupName : $script:ConfigFileName is not valid JSON. $($_.Exception.Message)")
    }

    if ($null -eq $config) {
        return @("$GroupName : $script:ConfigFileName is empty.")
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $keys = @($config.PSObject.Properties.Name)

    if ($keys -notcontains 'description') {
        $failures.Add("$GroupName : $script:ConfigFileName must declare a 'description'.")
    } elseif ([string]::IsNullOrWhiteSpace([string] $config.description)) {
        $failures.Add("$GroupName : 'description' must not be empty.")
    }

    foreach ($key in $keys) {
        if ($script:KnownKeys -notcontains $key) {
            $failures.Add("$GroupName : unknown key '$key'. Known keys are $($script:KnownKeys -join ', ').")
        }
    }

    if ($keys -contains 'deletedFiles') {
        foreach ($entry in @($config.deletedFiles)) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                $failures.Add("$GroupName : 'deletedFiles' must contain non-empty strings.")
                break
            }
        }
    }

    if ($keys -contains 'managedLines') {
        foreach ($property in @($config.managedLines.PSObject.Properties)) {
            $spec = $property.Value
            $specKeys = @($spec.PSObject.Properties.Name)
            foreach ($specKey in $specKeys) {
                if (@('required', 'removed') -notcontains $specKey) {
                    $failures.Add("$GroupName : managedLines['$($property.Name)'] has unknown key '$specKey'.")
                }
            }

            foreach ($specKey in @('required', 'removed')) {
                if ($specKeys -notcontains $specKey) {
                    continue
                }

                foreach ($line in @($spec.$specKey)) {
                    if ($line -isnot [string] -or [string]::IsNullOrWhiteSpace($line)) {
                        $failures.Add("$GroupName : managedLines['$($property.Name)'].$specKey must contain non-empty strings.")
                        break
                    }
                }
            }
        }
    }

    return @($failures)
}

function Test-AvmFileGroupConfig {
    [CmdletBinding()]
    param(
        [string] $Root
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = $PWD.Path
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $groups = @(Get-AvmFileGroupDirectory -Root $Root)

    if ($groups.Count -eq 0) {
        throw [System.InvalidOperationException]::new("No file groups found under $Root.")
    }

    foreach ($group in $groups) {
        $groupName = Join-Path -Path $group.Parent.Name -ChildPath $group.Name
        $configPath = Join-Path -Path $group.FullName -ChildPath $script:ConfigFileName

        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            $failures.Add("$groupName : missing $script:ConfigFileName.")
            continue
        }

        foreach ($failure in @(Get-AvmFileGroupConfigFailure -GroupName $groupName -ConfigPath $configPath)) {
            $failures.Add($failure)
        }

        Write-Host "Validated $groupName"
    }

    foreach ($placeholder in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter '.gitkeep' -ErrorAction SilentlyContinue)) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $placeholder.FullName).Replace('\', '/')
        $failures.Add("$relative : .gitkeep placeholders are not allowed. Every file group carries a $script:ConfigFileName instead.")
    }

    if ($failures.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "File group config validation failed:`n$($failures -join "`n")"
        )
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Test-AvmFileGroupConfig -Root $Root
}
