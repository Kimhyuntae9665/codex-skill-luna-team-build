[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$Trials = 5,
    [ValidateRange(0, 10)]
    [int]$Warmups = 1,
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repositoryRoot "skills\luna-team-build\scripts\run-luna-team.ps1"
$benchmarkRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("luna-scheduler-benchmark-" + [Guid]::NewGuid().ToString("N"))
$benchmarkSucceeded = $false

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count % 2 -eq 1) {
        return [double]$sorted[[int][Math]::Floor($sorted.Count / 2)]
    }
    $upper = [int]($sorted.Count / 2)
    ([double]$sorted[$upper - 1] + [double]$sorted[$upper]) / 2.0
}

function Get-P95 {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Ceiling(0.95 * $sorted.Count) - 1)
    [double]$sorted[$index]
}

function New-Worker {
    param(
        [string]$Name,
        [double]$Estimate,
        [string[]]$DependsOn = @()
    )
    [ordered]@{
        name = $Name
        working_directory = $benchmarkRoot
        sandbox_mode = "danger-full-access"
        review_only = $true
        owned_paths = @()
        depends_on = $DependsOn
        estimated_seconds = $Estimate
        contract_ids = @("paired-scheduler-benchmark-v1")
        acceptance = @("Fake task exits with the configured result")
        verification = @("Inspect the fake handoff and scheduler timestamps")
        prompt = "Execute only this deterministic fake benchmark task."
    }
}

function New-BenchmarkManifest {
    param(
        [ValidateSet("rolling-dag-v1", "barrier-dag-v1")]
        [string]$Mode
    )
    $selectedWall = if ($Mode -eq "rolling-dag-v1") { 12 } else { 20 }
    [ordered]@{
        schema_version = 2
        plan = [ordered]@{
            council_used = $true
            goal = "Compare identical static DAG execution under rolling and barrier scheduling."
            selection_reason = "Three frozen tasks are required for the paired fixture."
            expected_bottleneck = "long-a for rolling and the barrier before dependent-c for barrier."
            contracts_ready = $true
            council_notes = [ordered]@{
                strategist = "Hold the DAG and runtime constant."
                skeptic = "Treat fake timing as scheduler evidence only."
                creative = "Use an unlock-under-straggler topology."
                operator = "Alternate measured run order and retain correctness gates."
                audience_advocate = "Report median, p95, and limitations."
            }
            ready_track_count = 2
            selected_worker_count = 3
            planning_seconds_estimate = 0
            candidate_schedules = @(
                [ordered]@{ worker_count = 0; predicted_worker_wall_seconds = 0; coordination_seconds = 0; root_serial_seconds = 60; integration_verification_seconds = 0 },
                [ordered]@{ worker_count = 1; predicted_worker_wall_seconds = 40; coordination_seconds = 0; root_serial_seconds = 20; integration_verification_seconds = 0 },
                [ordered]@{ worker_count = 2; predicted_worker_wall_seconds = 30; coordination_seconds = 0; root_serial_seconds = 10; integration_verification_seconds = 0 },
                [ordered]@{ worker_count = 3; predicted_worker_wall_seconds = $selectedWall; coordination_seconds = 0; root_serial_seconds = 0; integration_verification_seconds = 0 }
            )
            root_tasks_during_workers = @("Observe artifacts without changing task state.")
            root_owned_paths = @()
            scheduler_mode = $Mode
            concurrency_limit = 2
        }
        workers = @(
            (New-Worker "long-a" 12),
            (New-Worker "short-b" 2),
            (New-Worker "dependent-c" 8 @("short-b"))
        )
    }
}

function Invoke-BenchmarkRun {
    param(
        [ValidateSet("rolling-dag-v1", "barrier-dag-v1")]
        [string]$Mode,
        [string]$Phase,
        [int]$Index,
        [string]$FakeCodexCommand
    )
    $runDirectory = Join-Path $benchmarkRoot ("{0}-{1}-{2}" -f $Phase, $Index, $Mode)
    $env:LUNA_FAKE_CODEX_LOG = Join-Path $runDirectory "dispatch-events.log"
    $manifest = New-BenchmarkManifest -Mode $Mode
    $json = $manifest | ConvertTo-Json -Depth 15
    $null = & $runner `
        -ManifestJson $json `
        -OutputDirectory $runDirectory `
        -CodexExecutable $FakeCodexCommand

    $summary = Get-Content -LiteralPath (Join-Path $runDirectory "run-summary.json") -Raw |
        ConvertFrom-Json
    $results = @(Get-Content -LiteralPath (Join-Path $runDirectory "run-results.json") -Raw |
        ConvertFrom-Json)
    $byName = @{}
    foreach ($result in $results) { $byName[$result.name] = $result }
    $orderingCorrect =
        [DateTimeOffset]$byName["dependent-c"].started_at -ge
            [DateTimeOffset]$byName["short-b"].completed_at
    $modeBehaviorCorrect = if ($Mode -eq "rolling-dag-v1") {
        [DateTimeOffset]$byName["dependent-c"].started_at -lt
            [DateTimeOffset]$byName["long-a"].completed_at
    } else {
        [DateTimeOffset]$byName["dependent-c"].started_at -ge
            [DateTimeOffset]$byName["long-a"].completed_at
    }
    $correct =
        $summary.status -eq "completed" -and
        $summary.completed_count -eq 3 -and
        $summary.failed_count -eq 0 -and
        $summary.skipped_count -eq 0 -and
        $summary.peak_active_workers -le 2 -and
        $orderingCorrect -and
        $modeBehaviorCorrect
    if (-not $correct) {
        throw "Benchmark correctness gate failed for $Mode $Phase trial $Index."
    }

    [pscustomobject][ordered]@{
        phase = $Phase
        trial = $Index
        scheduler_mode = $Mode
        wall_duration_seconds = [double]$summary.wall_duration_seconds
        predicted_worker_wall_seconds = [double]$summary.predicted_schedule.predicted_worker_wall_seconds
        actual_capacity_utilization = [double]$summary.actual_capacity_utilization
        idle_slot_seconds = [double]$summary.idle_slot_seconds
        total_queue_wait_seconds = [double]$summary.total_queue_wait_seconds
        peak_active_workers = [int]$summary.peak_active_workers
        ordering_correct = $orderingCorrect
        mode_behavior_correct = $modeBehaviorCorrect
        run_directory = $runDirectory
    }
}

New-Item -ItemType Directory -Path $benchmarkRoot | Out-Null
$fakeRoot = Join-Path $benchmarkRoot "fake-codex"
New-Item -ItemType Directory -Path $fakeRoot | Out-Null
$fakeCodexScript = Join-Path $fakeRoot "fake-codex.ps1"
$fakeCodexCommand = Join-Path $fakeRoot "fake-codex.cmd"

@'
$arguments = [string[]]$args
$prompt = [Console]::In.ReadToEnd()
$taskMatch = [regex]::Match($prompt, '(?m)^Task name: ([A-Za-z0-9_-]+)\s*$')
$taskName = if ($taskMatch.Success) { $taskMatch.Groups[1].Value } else { 'unknown' }
$delays = @{ 'long-a' = 1200; 'short-b' = 200; 'dependent-c' = 800 }
$logPath = [Environment]::GetEnvironmentVariable('LUNA_FAKE_CODEX_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $logPath)) | Out-Null
    [IO.File]::AppendAllText($logPath, "START $taskName`n", [Text.UTF8Encoding]::new($false))
}
Start-Sleep -Milliseconds $delays[$taskName]
$lastMessageIndex = [Array]::IndexOf($arguments, '--output-last-message')
if ($lastMessageIndex -ge 0 -and $lastMessageIndex + 1 -lt $arguments.Count) {
    [IO.File]::WriteAllText(
        $arguments[$lastMessageIndex + 1],
        "fake handoff for $taskName",
        [Text.UTF8Encoding]::new($false)
    )
}
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    [IO.File]::AppendAllText($logPath, "END $taskName`n", [Text.UTF8Encoding]::new($false))
}
Write-Output '{"type":"fake.completed"}'
exit 0
'@ | Set-Content -LiteralPath $fakeCodexScript -Encoding UTF8
@'
@echo off
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-codex.ps1" %*
'@ | Set-Content -LiteralPath $fakeCodexCommand -Encoding ASCII

$oldFakeLog = $env:LUNA_FAKE_CODEX_LOG
try {
    foreach ($warmupIndex in 1..$Warmups) {
        if ($Warmups -eq 0) { break }
        $null = Invoke-BenchmarkRun "barrier-dag-v1" "warmup" $warmupIndex $fakeCodexCommand
        $null = Invoke-BenchmarkRun "rolling-dag-v1" "warmup" $warmupIndex $fakeCodexCommand
    }

    $measured = [Collections.Generic.List[object]]::new()
    foreach ($trialIndex in 1..$Trials) {
        $order = if ($trialIndex % 2 -eq 1) {
            @("barrier-dag-v1", "rolling-dag-v1")
        } else {
            @("rolling-dag-v1", "barrier-dag-v1")
        }
        foreach ($mode in $order) {
            [void]$measured.Add(
                (Invoke-BenchmarkRun $mode "measured" $trialIndex $fakeCodexCommand)
            )
        }
    }

    $rolling = @($measured | Where-Object { $_.scheduler_mode -eq "rolling-dag-v1" })
    $barrier = @($measured | Where-Object { $_.scheduler_mode -eq "barrier-dag-v1" })
    $rollingWalls = [double[]]@($rolling.wall_duration_seconds)
    $barrierWalls = [double[]]@($barrier.wall_duration_seconds)
    $rollingMedian = Get-Median $rollingWalls
    $barrierMedian = Get-Median $barrierWalls
    $medianReduction = if ($barrierMedian -gt 0) {
        [Math]::Round(100 * ($barrierMedian - $rollingMedian) / $barrierMedian, 3)
    } else {
        0.0
    }

    $benchmarkSucceeded = $true
    [ordered]@{
        benchmark_kind = "deterministic-fake-codex-paired-scheduler"
        workload = "long-a=1200ms, short-b=200ms, dependent-c=800ms depends_on short-b, cap=2"
        warmups_per_mode = $Warmups
        measured_trials_per_mode = $Trials
        all_correct = @($measured | Where-Object { -not $_.ordering_correct -or -not $_.mode_behavior_correct }).Count -eq 0
        rolling = [ordered]@{
            median_wall_seconds = [Math]::Round($rollingMedian, 3)
            p95_wall_seconds = [Math]::Round((Get-P95 $rollingWalls), 3)
        }
        barrier = [ordered]@{
            median_wall_seconds = [Math]::Round($barrierMedian, 3)
            p95_wall_seconds = [Math]::Round((Get-P95 $barrierWalls), 3)
        }
        rolling_median_reduction_percent = $medianReduction
        artifacts_retained = [bool]$KeepArtifacts
        benchmark_root = if ($KeepArtifacts) { $benchmarkRoot } else { $null }
        trials = [object[]]$measured
        limitation = "Fake codex isolates scheduler behavior; it does not predict live model latency, token use, throttling, or integration rework."
    } | ConvertTo-Json -Depth 8
} finally {
    $env:LUNA_FAKE_CODEX_LOG = $oldFakeLog
    if ($benchmarkSucceeded -and -not $KeepArtifacts) {
        $fullBenchmarkRoot = [IO.Path]::GetFullPath($benchmarkRoot)
        $fullTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($fullBenchmarkRoot.StartsWith($fullTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $fullBenchmarkRoot) -like "luna-scheduler-benchmark-*") {
            Remove-Item -LiteralPath $fullBenchmarkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
