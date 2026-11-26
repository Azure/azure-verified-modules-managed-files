#Requires -Version 7.4

[CmdletBinding()]
param(
    [string] $EventResponderPath = './terraform/root/.github/policies/eventResponder.yml',
    [string] $DependabotPath = './terraform/root/.github/dependabot.yml'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module -Name powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop

function Get-YamlKeyValues {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Key
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            if ($entry.Key -eq $Key) {
                $entry.Value
            }
            Get-YamlKeyValues -Value $entry.Value -Key $Key
        }
        return
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($entry in $Value) {
            Get-YamlKeyValues -Value $entry -Key $Key
        }
    }
}

function Test-IssueGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Task,

        [Parameter(Mandatory)]
        [string] $PayloadType
    )

    $payloadTypes = @(Get-YamlKeyValues -Value $Task.if -Key 'payloadType')
    if ($payloadTypes.Count -ne 1 -or $payloadTypes[0] -ne $PayloadType) {
        throw "Task '$($Task.description)' must only target payload type '$PayloadType'."
    }
}

$eventResponder = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $EventResponderPath -Raw) -ErrorAction Stop
$tasks = @($eventResponder.configuration.resourceManagementConfiguration.eventResponderTasks)
$tasksById = @{}

foreach ($task in $tasks) {
    if ($task.description -match '^(ITA\d+) -') {
        $tasksById[$Matches[1]] = $task
    }
}

foreach ($id in @('ITA06', 'ITA09', 'ITA10', 'ITA11', 'ITA24')) {
    if (-not $tasksById.ContainsKey($id)) {
        throw "Managed event responder task '$id' is missing."
    }
}

if ($tasksById.ContainsKey('ITA15')) {
    throw 'Managed event responder task ITA15 must not mutate pull request labels.'
}

Test-IssueGuard -Task $tasksById['ITA06'] -PayloadType 'Issues'
Test-IssueGuard -Task $tasksById['ITA24'] -PayloadType 'Issues'

foreach ($id in @('ITA09', 'ITA10', 'ITA11')) {
    $task = $tasksById[$id]
    Test-IssueGuard -Task $task -PayloadType 'Issue_Comment'

    $issueGuards = @($task.if | Where-Object { $_ -is [string] -and $_ -eq 'isIssue' })
    if ($issueGuards.Count -ne 1) {
        throw "Task '$($task.description)' must include exactly one 'isIssue' guard."
    }
}

$dependabot = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $DependabotPath -Raw) -ErrorAction Stop
foreach ($update in @($dependabot.updates)) {
    if (-not $update.ContainsKey('labels')) {
        throw "Dependabot '$($update.'package-ecosystem')' updates must explicitly set 'labels: []'."
    }
    if (@($update.labels).Count -ne 0) {
        throw "Dependabot '$($update.'package-ecosystem')' updates must not add pull request labels."
    }
}

Write-Output 'Terraform label automation contract passed.'
