[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repositoryRoot "skills\luna-team-build\scripts\run-luna-team.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("luna-k0-regression-" + [Guid]::NewGuid().ToString("N"))
$passed = [Collections.Generic.List[string]]::new()
$suiteSucceeded = $false

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

function New-V2Manifest {
    param(
        [object[]]$Workers,
        [string]$SchedulerMode = "rolling-dag-v1",
        [int]$ConcurrencyLimit = 1,
        [double]$SelectedWall = 1
    )
    $taskCount = $Workers.Count
    $readyTrack = @(
        $Workers | Where-Object { @($_.depends_on).Count -eq 0 }
    ).Count
    $candidates = @(
        [ordered]@{
            worker_count = 0
            predicted_worker_wall_seconds = 0
            coordination_seconds = 0
            root_serial_seconds = 100
            integration_verification_seconds = 0
        }
    )
    if ($taskCount -gt 1) {
        foreach ($candidateCount in 1..($taskCount - 1)) {
            $candidates += [ordered]@{
                worker_count = $candidateCount
                predicted_worker_wall_seconds = $SelectedWall + 100
                coordination_seconds = 0
                root_serial_seconds = 100
                integration_verification_seconds = 0
            }
        }
    }
    $candidates += [ordered]@{
        worker_count = $taskCount
        predicted_worker_wall_seconds = $SelectedWall
        coordination_seconds = 0
        root_serial_seconds = 0
        integration_verification_seconds = 0
    }
    [ordered]@{
        schema_version = 2
        plan = [ordered]@{
            council_used = $true
            goal = "Validate the frozen DAG scheduler contract."
            selection_reason = "The selected deterministic candidate is lowest."
            expected_bottleneck = "The selected DAG critical path."
            contracts_ready = $true
            council_notes = [ordered]@{
                strategist = "Mapped the static DAG."
                skeptic = "Checked dependencies and ownership."
                creative = "Considered rolling and barrier execution."
                operator = "Assigned deterministic task contracts."
                audience_advocate = "Preserved the requested outcome."
            }
            ready_track_count = $readyTrack
            selected_worker_count = $Workers.Count
            planning_seconds_estimate = 0
            candidate_schedules = $candidates
            root_tasks_during_workers = if ($Workers.Count -gt 1) { @("Root verifies after workers.") } else { @() }
            root_owned_paths = @()
            scheduler_mode = $SchedulerMode
            concurrency_limit = $ConcurrencyLimit
        }
        workers = $Workers
    }
}

function Invoke-Runner {
    param(
        [object]$Manifest,
        [switch]$ValidateOnly,
        [switch]$Detached,
        [switch]$CaptureFailure,
        [string]$CodexExecutable = ""
    )
    $outputDirectory = Join-Path $testRoot ([Guid]::NewGuid().ToString("N"))
    $json = $Manifest | ConvertTo-Json -Depth 15
    try {
        if ($ValidateOnly) {
            $raw = & $runner -ManifestJson $json -OutputDirectory $outputDirectory `
                -ValidateOnly -CodexExecutable $CodexExecutable 2>&1 | Out-String
        } elseif ($Detached) {
            $raw = & $runner -ManifestJson $json -OutputDirectory $outputDirectory `
                -Detached -CodexExecutable $CodexExecutable 2>&1 | Out-String
        } else {
            $raw = & $runner -ManifestJson $json -OutputDirectory $outputDirectory `
                -CodexExecutable $CodexExecutable 2>&1 | Out-String
        }
    } catch {
        if (-not $CaptureFailure) {
            throw
        }
        $raw = $_ | Out-String
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

function Wait-RunTerminal {
    param(
        [string]$Directory,
        [int]$TimeoutSeconds = 20
    )
    $statusPath = Join-Path $Directory "run-status.json"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                if ($status.status -in @("completed", "failed")) {
                    return $status
                }
            } catch {
                # Atomic replacement can briefly race a read on slower hosts.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for terminal runner status in $Directory."
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
$fakeRoot = Join-Path $testRoot "fake-codex"
New-Item -ItemType Directory -Path $fakeRoot | Out-Null
$fakeCodexScript = Join-Path $fakeRoot "fake-codex.ps1"
$fakeCodexCommand = Join-Path $fakeRoot "fake-codex.cmd"
@'
$arguments = [string[]]$args
$prompt = [Console]::In.ReadToEnd()
$taskMatch = [regex]::Match($prompt, '(?m)^Task name: ([A-Za-z0-9_-]+)\s*$')
$taskName = if ($taskMatch.Success) { $taskMatch.Groups[1].Value } else { 'unknown' }
$logPath = [Environment]::GetEnvironmentVariable('LUNA_FAKE_CODEX_LOG')
$delayMap = @{}
$delayText = [Environment]::GetEnvironmentVariable('LUNA_FAKE_CODEX_DELAYS')
foreach ($entry in ($delayText -split ';')) {
    if ($entry -match '^([^=]+)=(\d+)$') { $delayMap[$matches[1]] = [int]$matches[2] }
}
$delay = if ($delayMap.ContainsKey($taskName)) { $delayMap[$taskName] } else { 25 }
$failureText = [Environment]::GetEnvironmentVariable('LUNA_FAKE_CODEX_FAIL_TASKS')
$failTasks = @($failureText -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    [IO.File]::AppendAllText($logPath, "START $taskName`n", [Text.UTF8Encoding]::new($false))
}
Start-Sleep -Milliseconds $delay
$lastMessageIndex = [Array]::IndexOf($arguments, '--output-last-message')
if ($lastMessageIndex -ge 0 -and $lastMessageIndex + 1 -lt $arguments.Count) {
    [IO.File]::WriteAllText($arguments[$lastMessageIndex + 1], "fake handoff for $taskName", [Text.UTF8Encoding]::new($false))
}
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    [IO.File]::AppendAllText($logPath, "END $taskName`n", [Text.UTF8Encoding]::new($false))
}
if ($failTasks -contains $taskName) { exit 9 }
Write-Output '{"type":"fake.completed"}'
exit 0
'@ | Set-Content -LiteralPath $fakeCodexScript -Encoding UTF8
@'
@echo off
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-codex.ps1" %*
'@ | Set-Content -LiteralPath $fakeCodexCommand -Encoding ASCII
$oldFakeLog = $null
$oldFakeDelays = $null
$oldFakeFailures = $null

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

    $v2Missing = New-V2Manifest @(
        (New-Worker "v2-missing" 1 $true @() @("not-present"))
    ) "rolling-dag-v1" 1 1
    Assert-Fails "v2 missing dependency rejected" "missing dependency" {
        Invoke-Runner $v2Missing -ValidateOnly
    }

    $v2Self = New-V2Manifest @(
        (New-Worker "v2-self" 1 $true @() @("v2-self"))
    ) "rolling-dag-v1" 1 1
    Assert-Fails "v2 self dependency rejected" "cannot depend on itself" {
        Invoke-Runner $v2Self -ValidateOnly
    }

    $v2Duplicate = New-V2Manifest @(
        (New-Worker "v2-duplicate" 1 $true @() @("v2-root", "v2-root")),
        (New-Worker "v2-root" 1)
    ) "rolling-dag-v1" 1 2
    Assert-Fails "v2 duplicate dependency rejected" "duplicate dependency" {
        Invoke-Runner $v2Duplicate -ValidateOnly
    }

    $v2Cycle = New-V2Manifest @(
        (New-Worker "v2-cycle-a" 1 $true @() @("v2-cycle-b")),
        (New-Worker "v2-cycle-b" 1 $true @() @("v2-cycle-a"))
    ) "rolling-dag-v1" 1 2
    Assert-Fails "v2 cycle rejected" "contains a cycle" {
        Invoke-Runner $v2Cycle -ValidateOnly
    }

    $v2Cap = New-V2Manifest @(
        (New-Worker "v2-cap-a" 1),
        (New-Worker "v2-cap-b" 1)
    ) "rolling-dag-v1" 3 1
    Assert-Fails "v2 concurrency cap rejected" "concurrency_limit must be between 1 and 2" {
        Invoke-Runner $v2Cap -ValidateOnly
    }

    $v2ReadyMismatch = New-V2Manifest @(
        (New-Worker "v2-ready-root" 1),
        (New-Worker "v2-ready-child" 1 $true @() @("v2-ready-root"))
    ) "rolling-dag-v1" 1 2
    $v2ReadyMismatch.plan.ready_track_count = 2
    Assert-Fails "v2 initial-ready count mismatch rejected" "initial-ready task count" {
        Invoke-Runner $v2ReadyMismatch -ValidateOnly
    }

    $v2MissingMode = New-V2Manifest @(
        (New-Worker "v2-mode" 1)
    ) "rolling-dag-v1" 1 1
    $v2MissingMode.plan.scheduler_mode = $null
    Assert-Fails "v2 scheduler mode required" "scheduler_mode" {
        Invoke-Runner $v2MissingMode -ValidateOnly
    }

    $v2MissingLimit = New-V2Manifest @(
        (New-Worker "v2-limit" 1)
    ) "rolling-dag-v1" 1 1
    $v2MissingLimit.plan.concurrency_limit = $null
    Assert-Fails "v2 concurrency limit required" "concurrency_limit" {
        Invoke-Runner $v2MissingLimit -ValidateOnly
    }

    $v2SequentialOverlapWorkers = @(
        (New-Worker "v2-overlap-a" 1 $false @("sequential-same-path")),
        (New-Worker "v2-overlap-b" 1 $false @("sequential-same-path") @("v2-overlap-a"))
    )
    $v2SequentialOverlap = New-V2Manifest $v2SequentialOverlapWorkers "rolling-dag-v1" 1 2
    Assert-Fails "v2 sequential ownership overlap rejected" "overlapping owned paths" {
        Invoke-Runner $v2SequentialOverlap -ValidateOnly
    }

    $v2DagWorkers = @(
        (New-Worker "v2-a" 4),
        (New-Worker "v2-b" 2),
        (New-Worker "v2-c" 3 $true @() @("v2-a")),
        (New-Worker "v2-d" 1 $true @() @("v2-b"))
    )
    $v2WrongWall = New-V2Manifest $v2DagWorkers "rolling-dag-v1" 2 6
    Assert-Fails "v2 critical-path predicted wall rejected" "deterministic DAG worker wall" {
        Invoke-Runner $v2WrongWall -ValidateOnly
    }
    $v2Valid = New-V2Manifest $v2DagWorkers "rolling-dag-v1" 2 7
    $v2ValidResult = Assert-Succeeds "v2 rolling DAG validates" {
        Invoke-Runner $v2Valid -ValidateOnly
    }
    $v2ValidJson = $v2ValidResult.Output | ConvertFrom-Json
    if ($v2ValidJson.scheduler_mode -ne "rolling-dag-v1" -or
        $v2ValidJson.concurrency_limit -ne 2 -or
        $v2ValidJson.task_count -ne 4 -or
        $v2ValidJson.initial_ready_count -ne 2 -or
        ($v2ValidJson.critical_path -join ",") -ne "v2-a,v2-c" -or
        $v2ValidJson.critical_path_seconds -ne 7 -or
        $v2ValidJson.predicted_schedule.utilization_capacity_denominator -ne 2 -or
        $v2ValidJson.predicted_schedule.predicted_capacity_utilization -ne 0.714 -or
        $v2ValidJson.predicted_schedule.predicted_worker_wall_seconds -ne 7) {
        throw "FAIL [v2 validation metrics] missing or incorrect DAG prediction fields"
    }
    [void]$passed.Add("v2 validation exposes DAG metrics")

    $oldFakeLog = $env:LUNA_FAKE_CODEX_LOG
    $oldFakeDelays = $env:LUNA_FAKE_CODEX_DELAYS
    $oldFakeFailures = $env:LUNA_FAKE_CODEX_FAIL_TASKS
    $env:LUNA_FAKE_CODEX_DELAYS = "v2-a=150;v2-b=600;v2-c=150;v2-d=75"
    $env:LUNA_FAKE_CODEX_FAIL_TASKS = ""
    $env:LUNA_FAKE_CODEX_LOG = Join-Path $testRoot "rolling-events.log"
    $rollingRunResult = Invoke-Runner $v2Valid -CodexExecutable $fakeCodexCommand
    $rollingSummary = Get-Content -LiteralPath (Join-Path $rollingRunResult.Directory "run-summary.json") -Raw |
        ConvertFrom-Json
    $rollingStatus = Get-Content -LiteralPath (Join-Path $rollingRunResult.Directory "run-status.json") -Raw |
        ConvertFrom-Json
    $rollingManifest = Get-Content -LiteralPath (Join-Path $rollingRunResult.Directory "run-manifest.json") -Raw |
        ConvertFrom-Json
    $rollingResults = Get-Content -LiteralPath (Join-Path $rollingRunResult.Directory "run-results.json") -Raw |
        ConvertFrom-Json
    $rollingByName = @{}
    foreach ($workerResult in @($rollingResults)) { $rollingByName[$workerResult.name] = $workerResult }
    if ($rollingSummary.status -ne "completed" -or
        $rollingStatus.status -ne "completed" -or
        $rollingSummary.scheduler_mode -ne "rolling-dag-v1" -or
        $rollingSummary.concurrency_limit -ne 2 -or
        $rollingSummary.task_count -ne 4 -or
        $rollingSummary.initial_ready_count -ne 2 -or
        $rollingSummary.peak_active_workers -gt 2 -or
        $rollingSummary.utilization_capacity_denominator -ne 2 -or
        ($rollingSummary.critical_path -join ",") -ne "v2-a,v2-c" -or
        $rollingSummary.critical_path_seconds -ne 7 -or
        $rollingSummary.completed_count -ne 4 -or
        $rollingSummary.failed_count -ne 0 -or
        $rollingSummary.skipped_count -ne 0 -or
        $rollingSummary.total_queue_wait_seconds -lt 0 -or
        $rollingSummary.maximum_queue_wait_seconds -lt 0 -or
        $rollingStatus.state_counts.completed -ne 4) {
        throw "FAIL [rolling metrics] scheduler metrics or terminal state is not truthful"
    }
    if (-not ($rollingByName["v2-c"].started_at -lt $rollingByName["v2-b"].completed_at)) {
        throw "FAIL [rolling immediate unlock] dependent task did not start while unrelated long task was active"
    }
    if ($rollingByName["v2-c"].queue_wait_seconds -le 0 -or
        $rollingByName["v2-c"].critical_path_seconds -ne 3) {
        throw "FAIL [rolling task observability] queue wait or critical path is incorrect"
    }
    if ($rollingManifest.task_count -ne 4 -or
        $rollingManifest.peak_active_workers -ne 2 -or
        $rollingManifest.workers[2].state -ne "completed" -or
        $rollingStatus.workers[2].ready_at -eq $null -or
        $rollingResults[0].initial_ready_count -ne 2 -or
        $rollingResults[0].peak_active_workers -ne 2 -or
        $rollingResults[0].state -eq $null) {
        throw "FAIL [v2 artifacts] manifest/status/results omit truthful task observability"
    }
    [void]$passed.Add("rolling DAG unlocks immediately and reports truthful metrics")

    $env:LUNA_FAKE_CODEX_LOG = Join-Path $testRoot "barrier-events.log"
    $barrierManifest = New-V2Manifest $v2DagWorkers "barrier-dag-v1" 2 7
    $barrierRunResult = Invoke-Runner $barrierManifest -CodexExecutable $fakeCodexCommand
    $barrierSummary = Get-Content -LiteralPath (Join-Path $barrierRunResult.Directory "run-summary.json") -Raw |
        ConvertFrom-Json
    $barrierResults = Get-Content -LiteralPath (Join-Path $barrierRunResult.Directory "run-results.json") -Raw |
        ConvertFrom-Json
    $barrierByName = @{}
    foreach ($workerResult in @($barrierResults)) { $barrierByName[$workerResult.name] = $workerResult }
    if ($barrierSummary.status -ne "completed" -or
        $barrierSummary.scheduler_mode -ne "barrier-dag-v1" -or
        $barrierSummary.peak_active_workers -gt 2 -or
        -not ($barrierByName["v2-c"].started_at -ge $barrierByName["v2-b"].completed_at)) {
        throw "FAIL [barrier behavior] barrier batch did not drain before the next batch"
    }
    [void]$passed.Add("barrier DAG waits for each batch")

    $env:LUNA_FAKE_CODEX_LOG = Join-Path $testRoot "detached-events.log"
    $detachedRunResult = Invoke-Runner $v2Valid `
        -Detached `
        -CodexExecutable $fakeCodexCommand
    $detachedResponse = $detachedRunResult.Output | ConvertFrom-Json
    $detachedStatus = Wait-RunTerminal -Directory $detachedRunResult.Directory
    $detachedSummary = Get-Content `
        -LiteralPath (Join-Path $detachedRunResult.Directory "run-summary.json") `
        -Raw | ConvertFrom-Json
    if (-not $detachedResponse.detached -or
        $detachedResponse.process_id -le 0 -or
        $detachedStatus.status -ne "completed" -or
        $detachedSummary.status -ne "completed" -or
        $detachedSummary.scheduler_mode -ne "rolling-dag-v1" -or
        $detachedSummary.peak_active_workers -gt 2) {
        throw "FAIL [v2 detached] detached child did not complete the frozen DAG"
    }
    [void]$passed.Add("v2 detached rolling DAG completes")

    $failureWorkers = @(
        (New-Worker "v2-fail" 1),
        (New-Worker "v2-child" 2 $true @() @("v2-fail")),
        (New-Worker "v2-grand" 1 $true @() @("v2-child")),
        (New-Worker "v2-unrelated" 3)
    )
    $failureManifest = New-V2Manifest $failureWorkers "rolling-dag-v1" 2 4
    $env:LUNA_FAKE_CODEX_DELAYS = "v2-fail=150;v2-child=100;v2-grand=100;v2-unrelated=500"
    $env:LUNA_FAKE_CODEX_FAIL_TASKS = "v2-fail"
    $env:LUNA_FAKE_CODEX_LOG = Join-Path $testRoot "failure-events.log"
    $failureRunResult = Invoke-Runner $failureManifest `
        -CodexExecutable $fakeCodexCommand `
        -CaptureFailure
    if ($null -eq $failureRunResult -or $null -eq $failureRunResult.Directory) {
        throw "FAIL [failure cascade] runner did not produce an output directory"
    }
    $failureSummary = Get-Content -LiteralPath (Join-Path $failureRunResult.Directory "run-summary.json") -Raw |
        ConvertFrom-Json
    $failureResults = Get-Content -LiteralPath (Join-Path $failureRunResult.Directory "run-results.json") -Raw |
        ConvertFrom-Json
    $failureByName = @{}
    foreach ($workerResult in @($failureResults)) { $failureByName[$workerResult.name] = $workerResult }
    if ($failureSummary.status -ne "failed" -or
        $failureSummary.peak_active_workers -gt 2 -or
        $failureSummary.completed_count -ne 1 -or
        $failureSummary.failed_count -ne 1 -or
        $failureSummary.skipped_count -ne 2 -or
        $failureByName["v2-fail"].state -ne "failed" -or
        $failureByName["v2-child"].state -ne "skipped" -or
        $failureByName["v2-grand"].state -ne "skipped" -or
        $failureByName["v2-unrelated"].state -ne "completed" -or
        [string]::IsNullOrWhiteSpace($failureByName["v2-child"].skip_reason) -or
        $failureByName["v2-child"].blocked_by -notcontains "v2-fail" -or
        $null -ne $failureByName["v2-child"].started_at) {
        throw "FAIL [failure cascade] descendants were not skipped or unrelated branch did not continue"
    }
    [void]$passed.Add("failure cascade skips descendants and preserves unrelated branch")

    $suiteSucceeded = $true
    [pscustomobject]@{ passed = $passed.Count; tests = [string[]]$passed } |
        ConvertTo-Json -Depth 4
} finally {
    $env:LUNA_FAKE_CODEX_LOG = $oldFakeLog
    $env:LUNA_FAKE_CODEX_DELAYS = $oldFakeDelays
    $env:LUNA_FAKE_CODEX_FAIL_TASKS = $oldFakeFailures
    $fullTestRoot = [IO.Path]::GetFullPath($testRoot)
    $fullTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $leaf = Split-Path -Leaf $fullTestRoot
    if ($suiteSucceeded -and
        $fullTestRoot.StartsWith($fullTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        $leaf -like "luna-k0-regression-*") {
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
