[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repositoryRoot "skills\luna-team-build\scripts\run-luna-team.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("luna-k0-regression-" + [Guid]::NewGuid().ToString("N"))
$passed = [Collections.Generic.List[string]]::new()

function New-Candidate {
    param([int]$Count, [double]$Wall, [double]$Coordination, [double]$Root, [double]$Verification)
    [ordered]@{
        worker_count = $Count
        predicted_worker_wall_seconds = $Wall
        coordination_seconds = $Coordination
        root_serial_seconds = $Root
        integration_verification_seconds = $Verification
    }
}

function New-Worker {
    param(
        [string]$Name,
        [double]$Estimate = 10,
        [bool]$ReviewOnly = $true,
        [string[]]$OwnedPaths = @(),
        [string[]]$DependsOn = @()
    )
    [ordered]@{
        name = $Name
        working_directory = $testRoot
        sandbox_mode = "danger-full-access"
        review_only = $ReviewOnly
        owned_paths = $OwnedPaths
        depends_on = $DependsOn
        estimated_seconds = $Estimate
        contract_ids = @("contract-v1")
        acceptance = @("Bounded result")
        verification = @("Scoped check")
        prompt = "Perform only this bounded validation task; other workers share the filesystem."
    }
}

function New-Manifest {
    param(
        [int]$Ready,
        [int]$Selected,
        [object[]]$Candidates,
        [object[]]$Workers,
        [string[]]$RootTasks = @(),
        [string[]]$RootPaths = @()
    )
    [ordered]@{
        schema_version = 1
        plan = [ordered]@{
            council_used = $true
            goal = "Validate the root-only scheduling contract."
            selection_reason = "Lowest predicted verified elapsed time."
            expected_bottleneck = "Root verification or the slowest selected worker."
            contracts_ready = $true
            council_notes = [ordered]@{
                strategist = "Mapped candidate schedules."
                skeptic = "Checked overhead and conflicts."
                creative = "Considered a safer split."
                operator = "Assigned exact scopes and checks."
                audience_advocate = "Preserved the requested outcome."
            }
            ready_track_count = $Ready
            selected_worker_count = $Selected
            planning_seconds_estimate = 0
            candidate_schedules = $Candidates
            root_tasks_during_workers = $RootTasks
            root_owned_paths = $RootPaths
        }
        workers = $Workers
    }
}

function Invoke-Runner {
    param([object]$Manifest, [switch]$ValidateOnly, [switch]$Detached)
    $outputDirectory = Join-Path $testRoot ([Guid]::NewGuid().ToString("N"))
    $json = $Manifest | ConvertTo-Json -Depth 15
    if ($ValidateOnly) {
        $raw = & $runner -ManifestJson $json -OutputDirectory $outputDirectory -ValidateOnly 2>&1 |
            Out-String
    } elseif ($Detached) {
        $raw = & $runner -ManifestJson $json -OutputDirectory $outputDirectory -Detached 2>&1 |
            Out-String
    } else {
        $raw = & $runner -ManifestJson $json -OutputDirectory $outputDirectory 2>&1 |
            Out-String
    }
    [pscustomobject]@{ Output = $raw; Directory = $outputDirectory }
}

function Assert-Succeeds {
    param([string]$Name, [scriptblock]$Action)
    try {
        $value = & $Action
        [void]$passed.Add($Name)
        $value
    } catch {
        throw "FAIL [$Name] expected success: $($_.Exception.Message)"
    }
}

function Assert-Fails {
    param([string]$Name, [string]$Pattern, [scriptblock]$Action)
    try {
        $null = & $Action
        throw "FAIL [$Name] expected failure"
    } catch {
        if ($_.Exception.Message -like "FAIL *") { throw }
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "FAIL [$Name] wrong error: $($_.Exception.Message)"
        }
        [void]$passed.Add($Name)
    }
}

New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $runner, [ref]$tokens, [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
    [void]$passed.Add("PowerShell parser")

    $k0 = New-Manifest 0 0 @((New-Candidate 0 0 0 8 2)) @() @() @($testRoot)
    $k0Result = Assert-Succeeds "k0 ready=0 ValidateOnly" {
        Invoke-Runner $k0 -ValidateOnly
    }
    $k0Json = $k0Result.Output | ConvertFrom-Json
    if ($k0Json.worker_count -ne 0 -or
        $k0Json.predicted_schedule.worker_count -ne 0 -or
        $k0Json.predicted_schedule.estimated_slowest_seconds -ne 0) {
        throw "FAIL [k0 schedule] nonzero worker metric"
    }
    if ($k0Json.plan_warnings.Count -ne 0) {
        throw "FAIL [k0 schedule] worker-only warning unexpectedly exists"
    }
    if (Test-Path -LiteralPath (Join-Path $k0Result.Directory "run-summary.json")) {
        throw "FAIL [k0 schedule] worker summary unexpectedly exists"
    }
    [void]$passed.Add("k0 emits no worker summary and zero schedule")

    $k0Ready2 = New-Manifest 2 0 @(
        (New-Candidate 0 0 0 8 2),
        (New-Candidate 1 12 0 2 2),
        (New-Candidate 2 7 1 2 2)
    ) @() @() @($testRoot)
    $null = Assert-Succeeds "k0 ready=2 full candidate range" {
        Invoke-Runner $k0Ready2 -ValidateOnly
    }

    $badWall = New-Manifest 0 0 @((New-Candidate 0 1 0 8 2)) @() @() @($testRoot)
    Assert-Fails "k0 rejects nonzero worker wall" "worker-wall and coordination" {
        Invoke-Runner $badWall -ValidateOnly
    }
    $badCoordination = New-Manifest 0 0 @((New-Candidate 0 0 1 8 2)) @() @() @($testRoot)
    Assert-Fails "k0 rejects nonzero coordination" "worker-wall and coordination" {
        Invoke-Runner $badCoordination -ValidateOnly
    }
    $badRootTasks = New-Manifest 0 0 @((New-Candidate 0 0 0 8 2)) `
        @() @("Not during workers") @($testRoot)
    Assert-Fails "k0 rejects root_tasks_during_workers" "cannot list root_tasks_during_workers" {
        Invoke-Runner $badRootTasks -ValidateOnly
    }
    Assert-Fails "k0 normal launch is blocked" "ValidateOnly-only" { Invoke-Runner $k0 }
    Assert-Fails "k0 detached launch is blocked" "ValidateOnly-only" {
        Invoke-Runner $k0 -Detached
    }

    $tie0 = New-Manifest 1 0 @(
        (New-Candidate 0 0 0 8 2),
        (New-Candidate 1 5 0 3 2)
    ) @() @() @($testRoot)
    $null = Assert-Succeeds "exact tie selects k0" { Invoke-Runner $tie0 -ValidateOnly }
    $tieWrong = New-Manifest 1 1 @(
        (New-Candidate 0 0 0 8 2),
        (New-Candidate 1 5 0 3 2)
    ) @((New-Worker "tie-worker" 5)) @() @()
    Assert-Fails "exact tie rejects k1" "expected 0" {
        Invoke-Runner $tieWrong -ValidateOnly
    }

    $positive1 = New-Manifest 1 1 @(
        (New-Candidate 0 0 0 100 0),
        (New-Candidate 1 10 0 1 1)
    ) @((New-Worker "worker-one" 10)) @() @()
    $positiveResult = Assert-Succeeds "positive k1 remains valid" {
        Invoke-Runner $positive1 -ValidateOnly
    }
    $normalized = Get-Content `
        -LiteralPath (Join-Path $positiveResult.Directory "run-manifest.json") `
        -Raw | ConvertFrom-Json
    $pin = $normalized.workers[0]
    if ($pin.model -ne "gpt-5.6-luna" -or
        $pin.reasoning_effort -ne "max" -or
        $pin.service_tier -ne "fast" -or
        $pin.sandbox_mode -ne "danger-full-access" -or
        $pin.approval_policy -ne "never") {
        throw "FAIL [runtime pins] mismatch"
    }
    [void]$passed.Add("positive runtime pins preserved")

    $workers7 = @()
    foreach ($workerNumber in 1..7) {
        $workers7 += New-Worker "worker-$workerNumber" 10
    }
    $candidates7 = @((New-Candidate 0 0 0 100 0))
    foreach ($workerCount in 1..6) {
        $candidates7 += New-Candidate $workerCount 10 0 (80 - $workerCount * 8) 0
    }
    $candidates7 += New-Candidate 7 10 0 0 0
    $manifest7 = New-Manifest 7 7 $candidates7 $workers7 `
        @("Root prepares combined verification.") @()
    $null = Assert-Succeeds "structured k7 remains valid" {
        Invoke-Runner $manifest7 -ValidateOnly
    }

    $legacy1 = @([ordered]@{
        name = "legacy-one"
        prompt = "Legacy validation only."
        working_directory = $testRoot
    })
    $legacyResult = Assert-Succeeds "legacy k1 remains valid" {
        Invoke-Runner $legacy1 -ValidateOnly
    }
    $legacyJson = $legacyResult.Output | ConvertFrom-Json
    if (-not ($legacyJson.plan_warnings -match "Legacy manifest")) {
        throw "FAIL [legacy warning] missing"
    }
    [void]$passed.Add("legacy warning preserved")

    $legacy4 = @()
    foreach ($workerNumber in 1..4) {
        $legacy4 += [ordered]@{
            name = "legacy-$workerNumber"
            prompt = "Legacy validation only."
            working_directory = $testRoot
        }
    }
    Assert-Fails "legacy k4 remains rejected" "Four to seven workers require" {
        Invoke-Runner $legacy4 -ValidateOnly
    }

    $workers8 = @()
    foreach ($workerNumber in 1..8) {
        $workers8 += New-Worker "too-many-$workerNumber" 10
    }
    $tooMany = [ordered]@{ schema_version = 1; plan = [ordered]@{}; workers = $workers8 }
    Assert-Fails "structured k8 rejected" "between zero and 7" {
        Invoke-Runner $tooMany -ValidateOnly
    }

    $positive2Candidates = @(
        (New-Candidate 0 0 0 100 0),
        (New-Candidate 1 20 0 40 0),
        (New-Candidate 2 10 0 0 0)
    )
    $overlapWorkers = @(
        (New-Worker "overlap-a" 10 $false @("same-path") @()),
        (New-Worker "overlap-b" 10 $false @("same-path") @())
    )
    $overlapManifest = New-Manifest 2 2 $positive2Candidates $overlapWorkers `
        @("Root verifies.") @()
    Assert-Fails "ownership overlap rejected" "overlapping owned paths" {
        Invoke-Runner $overlapManifest -ValidateOnly
    }

    $dependencyWorkers = @(
        (New-Worker "dependency-a" 10 $true @() @("dependency-b")),
        (New-Worker "dependency-b" 10)
    )
    $dependencyManifest = New-Manifest 2 2 $positive2Candidates $dependencyWorkers `
        @("Root verifies.") @()
    Assert-Fails "same-wave dependency rejected" "unresolved same-wave dependencies" {
        Invoke-Runner $dependencyManifest -ValidateOnly
    }

    [pscustomobject]@{ passed = $passed.Count; tests = [string[]]$passed } |
        ConvertTo-Json -Depth 4
} finally {
    $fullTestRoot = [IO.Path]::GetFullPath($testRoot)
    $fullTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $leaf = Split-Path -Leaf $fullTestRoot
    if ($fullTestRoot.StartsWith($fullTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        $leaf -like "luna-k0-regression-*") {
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
