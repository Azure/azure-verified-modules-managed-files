#Requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('workflow-pins-' + [guid]::NewGuid().ToString('N'))
$validator = Join-Path $PSScriptRoot 'Test-WorkflowShaPins.ps1'
$cases = @(
    @{ Ref = 'actions/checkout@0123456789abcdef0123456789abcdef01234567'; Valid = $true }
    @{ Ref = 'owner/repo/path@ABCDEF0123456789ABCDEF0123456789ABCDEF01'; Valid = $true }
    @{ Ref = './.github/actions/local'; Valid = $true }
    @{ Ref = 'docker://alpine@sha256:' + ('a' * 64); Valid = $true }
    @{ Ref = 'actions/checkout@v7'; Valid = $false }
    @{ Ref = 'actions/checkout@main'; Valid = $false }
    @{ Ref = 'actions/checkout@refs/heads/main'; Valid = $false }
    @{ Ref = 'actions/checkout@0123456'; Valid = $false }
    @{ Ref = 'actions/checkout@' + ('g' * 40); Valid = $false }
    @{ Ref = 'actions/checkout@' + ('a' * 41); Valid = $false }
    @{ Ref = './actions/../outside'; Valid = $false }
    @{ Ref = 'docker://alpine:latest'; Valid = $false }
    @{ Ref = '${{ inputs.ref }}'; Valid = $false }
)
try {
    foreach ($group in @('root', 'canary', 'new-group')) {
        $directory = Join-Path $root 'terraform' $group '.github' 'workflows'
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $count = 0
    foreach ($case in $cases) {
        foreach ($form in @('step', 'job')) {
            foreach ($group in @('root', 'canary', 'new-group')) {
                $path = Join-Path $root 'terraform' $group '.github' 'workflows' 'test.yaml'
                $uses = if ($form -eq 'step') {
                    "    runs-on: ubuntu-latest`n    steps:`n      - uses: '$($case.Ref)' # pin"
                } else {
                    "    uses: '$($case.Ref)' # pin"
                }
                $content = "name: Fixture`non: push`njobs:`n  arbitrary-name:`n$uses`n"
                [System.IO.File]::WriteAllText($path, $content)
                $failure = $null
                try { $null = & $validator -Root $root } catch { $failure = $_ }
                if ($case.Valid -and $failure) { throw $failure }
                if (-not $case.Valid -and (-not $failure -or $failure.Exception.Message -notlike '*uses must*')) {
                    throw "Expected pin rejection for $form '$($case.Ref)' in $group; received '$failure'."
                }
                Remove-Item -LiteralPath $path
                $count++
            }
        }
    }
    $path = Join-Path $root 'terraform' 'root' '.github' 'workflows' 'test.yml'
    [System.IO.File]::WriteAllText($path, @'
jobs:
  script:
    runs-on: ubuntu-latest
    steps:
      - run: |
          uses: actions/checkout@main
          # uses: ignored script content
      - uses: "actions/checkout@0123456789abcdef0123456789abcdef01234567"
'@)
    $null = & $validator -Root $root
    [System.IO.File]::WriteAllText($path, 'jobs: [invalid')
    $failed = $false
    try { $null = & $validator -Root $root } catch { $failed = $true }
    if (-not $failed) { throw 'Malformed YAML was accepted.' }
    Write-Output "Workflow pin regression cases passed: $count reference cases, script-content and malformed-YAML cases."
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
