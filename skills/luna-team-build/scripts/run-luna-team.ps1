[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$ManifestJson,
    [string]$OutputDirectory,
    [switch]$Detached,
    [switch]$ValidateOnly,
    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$workerModel = "gpt-5.6-luna"
$workerReasoningEffort = "max"
$workerServiceTier = "fast"
$workerSandboxMode = "danger-full-access"
$workerApprovalPolicy = "never"
$workerNestedDelegation = "disabled"
$maxWorkers = 7
$workerConcurrencyScope = "one-live-run-per-windows-session"
$workerMutexName = "Local\Codex.LunaTeamBuild.Run"

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DurationSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Start,
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$End
    )

    [Math]::Round(($End - $Start).TotalSeconds, 3)
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parentDirectory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    }

    $fileName = [System.IO.Path]::GetFileName($Path)
    $temporaryPath = Join-Path $parentDirectory (".$fileName.$([Guid]::NewGuid().ToString('N')).tmp")
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $utf8NoBom)

        # Readers such as Get-Content can briefly deny delete sharing on Windows.
        # Retry the atomic swap instead of letting a harmless status poll abort
        # the whole worker run.
        $writeCompleted = $false
        $lastWriteError = $null
        for ($attempt = 1; $attempt -le 100; $attempt++) {
            try {
                if ([System.IO.File]::Exists($Path)) {
                    try {
                        [System.IO.File]::Replace($temporaryPath, $Path, $null, $true)
                    } catch {
                        # Retain an overwrite fallback for filesystems that do
                        # not implement File.Replace.
                        [System.IO.File]::Move($temporaryPath, $Path, $true)
                    }
                } else {
                    [System.IO.File]::Move($temporaryPath, $Path)
                }
                $writeCompleted = $true
                break
            } catch {
                $lastWriteError = $_
                if ($attempt -lt 100) {
                    [System.Threading.Thread]::Sleep(50)
                }
            }
        }

        if (-not $writeCompleted) {
            throw $lastWriteError
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [int]$Depth = 10
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    Write-AtomicText -Path $Path -Content ([string]$json)
}

function Get-OptionalProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    $property.Value
}

function Get-StringArray {
    param([object]$Value)

    $values = @()
    if ($null -ne $Value) {
        foreach ($item in @($Value)) {
            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $values += $text.Trim()
            }
        }
    }
    [string[]]$values
}

function Resolve-OwnedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -match '[\*\?\[\]]') {
        throw "Owned paths must be exact files or directories, not globs: $Path"
    }
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $WorkingDirectory $Path
    }
    [System.IO.Path]::GetFullPath($candidate).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $normalizedRoot = $Root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    if ([string]::Equals($Path, $normalizedRoot, $comparison)) {
        return $true
    }
    $prefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    $Path.StartsWith($prefix, $comparison)
}

function Test-OwnedPathOverlap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$First,
        [Parameter(Mandatory = $true)]
        [string]$Second
    )

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ([string]::Equals($First, $Second, $comparison)) {
        return $true
    }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $First.StartsWith($Second + $separator, $comparison) -or
        $Second.StartsWith($First + $separator, $comparison)
}

function Get-Median {
    param([double[]]$Values)

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return $null
    }
    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
        return [double]$sorted[$middle]
    }
    ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

if ($ManifestPath) {
    $manifestJson = Get-Content -LiteralPath $ManifestPath -Raw
} elseif (-not [string]::IsNullOrWhiteSpace($ManifestJson)) {
    $manifestJson = $ManifestJson
} else {
    $manifestJson = [Console]::In.ReadToEnd()
}

if ([string]::IsNullOrWhiteSpace($manifestJson)) {
    throw "Provide a JSON task manifest through stdin or -ManifestPath."
}

$parsedManifest = $manifestJson | ConvertFrom-Json
$manifestFormat = "legacy-array"
$planInput = $null
$schemaVersion = $null
if ($null -ne $parsedManifest -and
    $parsedManifest.PSObject.Properties.Name -contains "workers") {
    $manifestFormat = "planning-council-v1"
    $schemaVersion = Get-OptionalProperty -Object $parsedManifest -Name "schema_version"
    $planInput = Get-OptionalProperty -Object $parsedManifest -Name "plan"
    $tasks = @(Get-OptionalProperty -Object $parsedManifest -Name "workers")
} else {
    $tasks = @($parsedManifest)
}

if ($manifestFormat -eq "planning-council-v1") {
    if ($tasks.Count -lt 0 -or $tasks.Count -gt $maxWorkers) {
        throw "The structured manifest must contain between zero and $maxWorkers workers."
    }
} elseif ($tasks.Count -lt 1 -or $tasks.Count -gt $maxWorkers) {
    throw "The legacy manifest must contain between one and $maxWorkers workers."
}
if ($tasks.Count -gt 3 -and $manifestFormat -ne "planning-council-v1") {
    throw "Four to seven workers require the structured Planning Council manifest."
}

$planWarnings = [System.Collections.Generic.List[string]]::new()
$normalizedPlan = $null
$normalizedRootOwnedPaths = @()
if ($manifestFormat -eq "planning-council-v1") {
    if ([int]$schemaVersion -ne 1) {
        throw "The Planning Council manifest requires schema_version 1."
    }
    if ($null -eq $planInput) {
        throw "The Planning Council manifest is missing its plan object."
    }

    $councilUsedRaw = Get-OptionalProperty -Object $planInput -Name "council_used"
    if ($councilUsedRaw -isnot [bool] -or -not [bool]$councilUsedRaw) {
        throw "The plan must record council_used=true."
    }
    $goal = [string](Get-OptionalProperty -Object $planInput -Name "goal" -Default "")
    $selectionReason = [string](
        Get-OptionalProperty -Object $planInput -Name "selection_reason" -Default ""
    )
    $expectedBottleneck = [string](
        Get-OptionalProperty -Object $planInput -Name "expected_bottleneck" -Default ""
    )
    $contractsReadyRaw = Get-OptionalProperty -Object $planInput -Name "contracts_ready"
    $councilNotesInput = Get-OptionalProperty -Object $planInput -Name "council_notes"
    $rootTasksDuringWorkers = @(
        Get-StringArray -Value (
            Get-OptionalProperty -Object $planInput -Name "root_tasks_during_workers"
        )
    )
    $rootOwnedPathInputs = @(
        Get-StringArray -Value (
            Get-OptionalProperty -Object $planInput -Name "root_owned_paths"
        )
    )
    $normalizedRootOwnedPaths = @(
        foreach ($rootOwnedPathInput in $rootOwnedPathInputs) {
            if ($rootOwnedPathInput -match '[\*\?\[\]]') {
                throw "Root-owned paths must be exact files or directories: $rootOwnedPathInput"
            }
            if (-not [System.IO.Path]::IsPathRooted($rootOwnedPathInput)) {
                throw "Root-owned paths must be absolute: $rootOwnedPathInput"
            }
            [System.IO.Path]::GetFullPath($rootOwnedPathInput).TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            )
        }
    )

    $normalizedCouncilNotes = [ordered]@{}
    foreach ($councilRole in @(
            "strategist",
            "skeptic",
            "creative",
            "operator",
            "audience_advocate"
        )) {
        $roleNote = [string](
            Get-OptionalProperty `
                -Object $councilNotesInput `
                -Name $councilRole `
                -Default ""
        )
        if ([string]::IsNullOrWhiteSpace($roleNote)) {
            throw "The Council plan is missing the '$councilRole' note."
        }
        $normalizedCouncilNotes[$councilRole] = $roleNote.Trim()
    }

    try {
        $readyTrackCount = [int](
            Get-OptionalProperty -Object $planInput -Name "ready_track_count"
        )
        $selectedWorkerCount = [int](
            Get-OptionalProperty -Object $planInput -Name "selected_worker_count"
        )
        $planningSecondsEstimate = [double](
            Get-OptionalProperty -Object $planInput -Name "planning_seconds_estimate"
        )
    } catch {
        throw "The Council plan has invalid count or planning-time fields."
    }
    if ($readyTrackCount -lt 0 -or $readyTrackCount -gt $maxWorkers) {
        throw "ready_track_count must be between zero and $maxWorkers."
    }
    if ($selectedWorkerCount -ne $tasks.Count) {
        throw "selected_worker_count must equal the manifest worker count."
    }
    if ($selectedWorkerCount -gt $readyTrackCount) {
        throw "selected_worker_count cannot exceed ready_track_count."
    }
    if ($planningSecondsEstimate -lt 0) {
        throw "planning_seconds_estimate cannot be negative."
    }

    $candidateScheduleInputs = @(
        Get-OptionalProperty -Object $planInput -Name "candidate_schedules"
    )
    if ($candidateScheduleInputs.Count -ne ($readyTrackCount + 1)) {
        throw "candidate_schedules must cover every worker count from zero through ready_track_count."
    }
    $seenCandidateCounts = [System.Collections.Generic.HashSet[int]]::new()
    $normalizedCandidateSchedules = @(
        foreach ($candidateInput in $candidateScheduleInputs) {
            try {
                $candidateWorkerCount = [int](
                    Get-OptionalProperty -Object $candidateInput -Name "worker_count"
                )
                $candidateWorkerWall = [double](
                    Get-OptionalProperty `
                        -Object $candidateInput `
                        -Name "predicted_worker_wall_seconds"
                )
                $candidateCoordination = [double](
                    Get-OptionalProperty `
                        -Object $candidateInput `
                        -Name "coordination_seconds"
                )
                $candidateRootSerial = [double](
                    Get-OptionalProperty `
                        -Object $candidateInput `
                        -Name "root_serial_seconds"
                )
                $candidateIntegration = [double](
                    Get-OptionalProperty `
                        -Object $candidateInput `
                        -Name "integration_verification_seconds"
                )
            } catch {
                throw "A candidate schedule contains invalid numeric fields."
            }
            if ($candidateWorkerCount -lt 0 -or $candidateWorkerCount -gt $readyTrackCount) {
                throw "Candidate worker_count is outside the ready-track range: $candidateWorkerCount"
            }
            if (-not $seenCandidateCounts.Add($candidateWorkerCount)) {
                throw "Duplicate candidate worker_count: $candidateWorkerCount"
            }
            if ($candidateWorkerCount -eq 0 -and
                ($candidateWorkerWall -ne 0 -or $candidateCoordination -ne 0)) {
                throw "Candidate worker_count 0 requires worker-wall and coordination seconds to be exactly 0."
            }
            if ($candidateWorkerWall -lt 0 -or
                $candidateCoordination -lt 0 -or
                $candidateRootSerial -lt 0 -or
                $candidateIntegration -lt 0) {
                throw "Candidate schedule durations cannot be negative."
            }
            $candidateTotal = [Math]::Round(
                $planningSecondsEstimate +
                    $candidateWorkerWall +
                    $candidateCoordination +
                    $candidateRootSerial +
                    $candidateIntegration,
                3
            )
            [ordered]@{
                worker_count = $candidateWorkerCount
                predicted_worker_wall_seconds = [Math]::Round($candidateWorkerWall, 3)
                coordination_seconds = [Math]::Round($candidateCoordination, 3)
                root_serial_seconds = [Math]::Round($candidateRootSerial, 3)
                integration_verification_seconds = [Math]::Round($candidateIntegration, 3)
                predicted_total_seconds = $candidateTotal
            }
        }
    )
    foreach ($expectedCandidateCount in 0..$readyTrackCount) {
        if (-not $seenCandidateCounts.Contains($expectedCandidateCount)) {
            throw "Missing candidate worker_count: $expectedCandidateCount"
        }
    }
    $bestCandidate = $normalizedCandidateSchedules |
        Sort-Object `
            -Property `
                @{ Expression = { [double]$_.predicted_total_seconds } },
                @{ Expression = { [int]$_.worker_count } } |
        Select-Object -First 1
    if ([int]$bestCandidate.worker_count -ne $selectedWorkerCount) {
        throw "selected_worker_count is not the lowest predicted-time candidate; expected $($bestCandidate.worker_count)."
    }

    if ([string]::IsNullOrWhiteSpace($goal)) {
        throw "The Council plan must include a measurable goal."
    }
    if ([string]::IsNullOrWhiteSpace($selectionReason)) {
        throw "The Council plan must explain its worker-count selection."
    }
    if ([string]::IsNullOrWhiteSpace($expectedBottleneck)) {
        throw "The Council plan must name its expected bottleneck."
    }
    if ($contractsReadyRaw -isnot [bool] -or -not [bool]$contractsReadyRaw) {
        throw "The ready wave requires contracts_ready=true."
    }
    if ($tasks.Count -gt 1 -and $rootTasksDuringWorkers.Count -eq 0) {
        throw "Multi-worker plans must list root_tasks_during_workers."
    }
    if ($tasks.Count -eq 0 -and $rootTasksDuringWorkers.Count -ne 0) {
        throw "Zero-worker plans cannot list root_tasks_during_workers."
    }

    $normalizedPlan = [ordered]@{
        council_used = $true
        goal = $goal.Trim()
        selection_reason = $selectionReason.Trim()
        expected_bottleneck = $expectedBottleneck.Trim()
        contracts_ready = $true
        council_notes = $normalizedCouncilNotes
        ready_track_count = $readyTrackCount
        selected_worker_count = $selectedWorkerCount
        planning_seconds_estimate = [Math]::Round($planningSecondsEstimate, 3)
        candidate_schedules = [object[]]$normalizedCandidateSchedules
        root_tasks_during_workers = [string[]]$rootTasksDuringWorkers
        root_owned_paths = [string[]]$normalizedRootOwnedPaths
    }
} else {
    [void]$planWarnings.Add(
        "Legacy manifest: Planning Council metadata and deterministic ownership lint are incomplete."
    )
}

$seenNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$validatedTasks = @(
    foreach ($task in $tasks) {
    $name = [string]$task.name
    $prompt = [string]$task.prompt
    $workingDirectory = [string]$task.working_directory
    $requestedSandboxMode = [string](
        Get-OptionalProperty -Object $task -Name "sandbox_mode" -Default $workerSandboxMode
    )

    if ($name -notmatch "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$") {
        throw "Worker names must use 1-64 letters, digits, underscores, or hyphens: $name"
    }
    if (-not $seenNames.Add($name)) {
        throw "Worker names must be unique: $name"
    }
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        throw "Worker '$name' has an empty prompt."
    }
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw "Worker '$name' has an invalid working directory: $workingDirectory"
    }
    if ($requestedSandboxMode -notin @("read-only", "workspace-write", "danger-full-access")) {
        throw "Worker '$name' has an invalid sandbox_mode: $requestedSandboxMode"
    }
    if ($manifestFormat -eq "planning-council-v1" -and
        $requestedSandboxMode -ne $workerSandboxMode) {
        throw "Structured worker '$name' must explicitly request sandbox_mode=$workerSandboxMode."
    }

    $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $workingDirectory).Path
    $reviewOnlyRaw = Get-OptionalProperty -Object $task -Name "review_only" -Default $false
    if ($reviewOnlyRaw -isnot [bool]) {
        throw "Worker '$name' review_only must be a JSON boolean."
    }
    $reviewOnly = [bool]$reviewOnlyRaw
    $ownedPathInputs = @(
        Get-StringArray -Value (Get-OptionalProperty -Object $task -Name "owned_paths")
    )
    $ownedPaths = @(
        foreach ($ownedPathInput in $ownedPathInputs) {
            $resolvedOwnedPath = Resolve-OwnedPath `
                -WorkingDirectory $resolvedWorkingDirectory `
                -Path $ownedPathInput
            if (-not (Test-PathInsideRoot `
                    -Path $resolvedOwnedPath `
                    -Root $resolvedWorkingDirectory)) {
                throw "Worker '$name' owns a path outside its working directory: $resolvedOwnedPath"
            }
            $resolvedOwnedPath
        }
    )
    $dependsOn = @(
        Get-StringArray -Value (Get-OptionalProperty -Object $task -Name "depends_on")
    )
    $acceptance = @(
        Get-StringArray -Value (Get-OptionalProperty -Object $task -Name "acceptance")
    )
    $verification = @(
        Get-StringArray -Value (Get-OptionalProperty -Object $task -Name "verification")
    )
    $contractIds = @(
        Get-StringArray -Value (Get-OptionalProperty -Object $task -Name "contract_ids")
    )
    $estimatedRaw = Get-OptionalProperty -Object $task -Name "estimated_seconds"
    $estimatedSeconds = $null
    if ($null -ne $estimatedRaw) {
        try {
            $estimatedSeconds = [double]$estimatedRaw
        } catch {
            throw "Worker '$name' has invalid estimated_seconds."
        }
        if ($estimatedSeconds -le 0) {
            throw "Worker '$name' estimated_seconds must be positive."
        }
    }

    if ($dependsOn.Count -gt 0) {
        throw "Worker '$name' has unresolved same-wave dependencies: $($dependsOn -join ', ')"
    }
    if ($manifestFormat -eq "planning-council-v1") {
        if ($null -eq $estimatedSeconds) {
            throw "Worker '$name' is missing estimated_seconds."
        }
        if ($acceptance.Count -eq 0) {
            throw "Worker '$name' is missing acceptance criteria."
        }
        if ($verification.Count -eq 0) {
            throw "Worker '$name' is missing scoped verification."
        }
        if ($reviewOnly -and $ownedPaths.Count -gt 0) {
            throw "Review-only worker '$name' must not declare owned_paths."
        }
        if (-not $reviewOnly -and $ownedPaths.Count -eq 0) {
            throw "Implementation worker '$name' must declare owned_paths."
        }
    }

        [pscustomobject]@{
            name = $name
            prompt = $prompt
            working_directory = $resolvedWorkingDirectory
            review_only = $reviewOnly
            owned_paths = [string[]]$ownedPaths
            depends_on = [string[]]$dependsOn
            estimated_seconds = $estimatedSeconds
            acceptance = [string[]]$acceptance
            verification = [string[]]$verification
            contract_ids = [string[]]$contractIds
            model = $workerModel
            reasoning_effort = $workerReasoningEffort
            service_tier = $workerServiceTier
            sandbox_mode = $workerSandboxMode
            approval_policy = $workerApprovalPolicy
        }
    }
)

for ($firstIndex = 0; $firstIndex -lt $validatedTasks.Count; $firstIndex++) {
    for ($secondIndex = $firstIndex + 1; $secondIndex -lt $validatedTasks.Count; $secondIndex++) {
        $firstTask = $validatedTasks[$firstIndex]
        $secondTask = $validatedTasks[$secondIndex]
        foreach ($firstPath in @($firstTask.owned_paths)) {
            foreach ($secondPath in @($secondTask.owned_paths)) {
                if (Test-OwnedPathOverlap -First $firstPath -Second $secondPath) {
                    throw "Workers '$($firstTask.name)' and '$($secondTask.name)' have overlapping owned paths: $firstPath <> $secondPath"
                }
            }
        }
    }
}

foreach ($rootOwnedPath in $normalizedRootOwnedPaths) {
    foreach ($workerTask in $validatedTasks) {
        foreach ($workerOwnedPath in @($workerTask.owned_paths)) {
            if (Test-OwnedPathOverlap -First $rootOwnedPath -Second $workerOwnedPath) {
                throw "Root and worker '$($workerTask.name)' have overlapping owned paths: $rootOwnedPath <> $workerOwnedPath"
            }
        }
    }
}

$estimatedDurations = @(
    $validatedTasks |
        Where-Object { $null -ne $_.estimated_seconds } |
        ForEach-Object { [double]$_.estimated_seconds }
)
$predictedSchedule = $null
if ($estimatedDurations.Count -eq $validatedTasks.Count) {
    if ($validatedTasks.Count -eq 0) {
        # A root-only plan has no worker durations to measure. Keep the
        # schedule numeric and useful instead of dereferencing empty metrics.
        $estimatedMaximum = 0.0
        $estimatedMinimum = 0.0
        $estimatedSum = 0.0
        $estimatedMedian = 0.0
    } else {
        $estimatedMaximum = [double](
            $estimatedDurations | Measure-Object -Maximum
        ).Maximum
        $estimatedMinimum = [double](
            $estimatedDurations | Measure-Object -Minimum
        ).Minimum
        $estimatedSum = [double](
            $estimatedDurations | Measure-Object -Sum
        ).Sum
        $estimatedMedian = [double](Get-Median -Values $estimatedDurations)
    }
    $predictedCapacityUtilization = if ($estimatedMaximum -gt 0) {
        [Math]::Round(
            $estimatedSum / ($validatedTasks.Count * $estimatedMaximum),
            3
        )
    } else {
        0.0
    }
    $predictedBalanceRatio = if ($estimatedMaximum -gt 0) {
        [Math]::Round($estimatedMinimum / $estimatedMaximum, 3)
    } else {
        0.0
    }
    $predictedMaxMedianRatio = if ($estimatedMedian -gt 0) {
        [Math]::Round($estimatedMaximum / $estimatedMedian, 3)
    } else {
        0.0
    }
    $predictedSchedule = [ordered]@{
        worker_count = $validatedTasks.Count
        estimated_sum_seconds = [Math]::Round($estimatedSum, 3)
        estimated_slowest_seconds = [Math]::Round($estimatedMaximum, 3)
        estimated_median_seconds = [Math]::Round($estimatedMedian, 3)
        predicted_capacity_utilization = $predictedCapacityUtilization
        predicted_balance_ratio = $predictedBalanceRatio
        predicted_max_median_ratio = $predictedMaxMedianRatio
    }
    if ($manifestFormat -eq "planning-council-v1") {
        $selectedCandidateSchedule = @(
            $normalizedCandidateSchedules |
                Where-Object { [int]$_.worker_count -eq $validatedTasks.Count }
        )[0]
        if ([Math]::Abs(
                [double]$selectedCandidateSchedule.predicted_worker_wall_seconds -
                $estimatedMaximum
            ) -gt 0.001) {
            throw "The selected candidate's predicted_worker_wall_seconds must equal the slowest selected worker estimate ($estimatedMaximum)."
        }
        $predictedSchedule.selected_predicted_total_seconds =
            [double]$selectedCandidateSchedule.predicted_total_seconds
    }
    if ($validatedTasks.Count -gt 0 -and $predictedMaxMedianRatio -gt 1.5) {
        [void]$planWarnings.Add(
            "Predicted max/median duration exceeds 1.5; document or rebalance the expected straggler."
        )
    }
    if ($validatedTasks.Count -gt 0 -and $predictedCapacityUtilization -lt 0.70) {
        [void]$planWarnings.Add(
            "Predicted capacity utilization is below 0.70; a smaller or rebalanced team may finish sooner."
        )
    }
}

# Legacy sandbox values remain valid manifest input for compatibility, but the
# effective execution contract is always full access. Keep the persisted
# manifest truthful instead of retaining the caller's narrower request.
$normalizedTasks = @(
    $validatedTasks | ForEach-Object {
        [ordered]@{
            name = $_.name
            prompt = $_.prompt
            working_directory = $_.working_directory
            review_only = $_.review_only
            owned_paths = [string[]]$_.owned_paths
            depends_on = [string[]]$_.depends_on
            estimated_seconds = $_.estimated_seconds
            acceptance = [string[]]$_.acceptance
            verification = [string[]]$_.verification
            contract_ids = [string[]]$_.contract_ids
            model = $_.model
            reasoning_effort = $_.reasoning_effort
            service_tier = $_.service_tier
            sandbox_mode = $_.sandbox_mode
            approval_policy = $_.approval_policy
            nested_delegation = $workerNestedDelegation
        }
    }
)

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = [Guid]::NewGuid().ToString("N")
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "luna-team-$RunId"
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$runManifestPath = Join-Path $OutputDirectory "run-manifest.json"
$runStatusPath = Join-Path $OutputDirectory "run-status.json"
$runSummaryPath = Join-Path $OutputDirectory "run-summary.json"
$runResultsPath = Join-Path $OutputDirectory "run-results.json"
$runStartedAt = [DateTimeOffset]::UtcNow
$runStartedAtText = $runStartedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)

$workerRecordByName = @{}
$workerRecords = @(
    foreach ($task in $validatedTasks) {
        $record = [pscustomobject][ordered]@{
            name = $task.name
            working_directory = $task.working_directory
            review_only = $task.review_only
            owned_paths = [string[]]$task.owned_paths
            depends_on = [string[]]$task.depends_on
            estimated_seconds = $task.estimated_seconds
            acceptance = [string[]]$task.acceptance
            verification = [string[]]$task.verification
            contract_ids = [string[]]$task.contract_ids
            model = $workerModel
            reasoning_effort = $workerReasoningEffort
            service_tier = $workerServiceTier
            sandbox_mode = $workerSandboxMode
            approval_policy = $workerApprovalPolicy
            nested_delegation = $workerNestedDelegation
            state = "pending"
            started_at = $null
            completed_at = $null
            duration_seconds = $null
            exit_code = $null
            error = $null
            last_message_path = Join-Path $OutputDirectory "$($task.name)-last-message.txt"
            log_path = Join-Path $OutputDirectory "$($task.name)-events.log"
        }
        $workerRecordByName[$task.name] = $record
        $record
    }
)

function Get-StatusWorker {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Record
    )

    [ordered]@{
        name = $Record.name
        working_directory = $Record.working_directory
        review_only = $Record.review_only
        owned_paths = [string[]]$Record.owned_paths
        depends_on = [string[]]$Record.depends_on
        estimated_seconds = $Record.estimated_seconds
        acceptance = [string[]]$Record.acceptance
        verification = [string[]]$Record.verification
        contract_ids = [string[]]$Record.contract_ids
        model = $Record.model
        reasoning_effort = $Record.reasoning_effort
        service_tier = $Record.service_tier
        sandbox_mode = $Record.sandbox_mode
        approval_policy = $Record.approval_policy
        nested_delegation = $Record.nested_delegation
        state = $Record.state
        started_at = $Record.started_at
        completed_at = $Record.completed_at
        duration_seconds = $Record.duration_seconds
        exit_code = $Record.exit_code
        error = $Record.error
        last_message_path = $Record.last_message_path
        log_path = $Record.log_path
    }
}

function Write-RunStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunState,
        [object]$ProcessId = $PID
    )

    $statusWorkers = @($workerRecords | ForEach-Object { Get-StatusWorker -Record $_ })
    $statusDocument = [ordered]@{
        run_id = $RunId
        status = $RunState
        started_at = $runStartedAtText
        updated_at = Get-UtcTimestamp
        output_directory = $OutputDirectory
        process_id = $ProcessId
        worker_count = $workerRecords.Count
        max_workers = $maxWorkers
        worker_limit_scope = $workerConcurrencyScope
        manifest_format = $manifestFormat
        plan = $normalizedPlan
        plan_warnings = [string[]]$planWarnings
        predicted_schedule = $predictedSchedule
        model = $workerModel
        reasoning_effort = $workerReasoningEffort
        service_tier = $workerServiceTier
        sandbox_mode = $workerSandboxMode
        approval_policy = $workerApprovalPolicy
        nested_delegation = $workerNestedDelegation
        manifest_path = $runManifestPath
        results_path = $runResultsPath
        summary_path = $runSummaryPath
        workers = $statusWorkers
    }
    Write-AtomicJson -Path $runStatusPath -Value $statusDocument -Depth 10
}

function New-WorkerResult {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Record,
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [AllowEmptyString()]
        [string]$LastMessage,
        [AllowEmptyString()]
        [string]$ErrorMessage
    )

    $result = [ordered]@{
        name = $Record.name
        working_directory = $Record.working_directory
        review_only = $Record.review_only
        owned_paths = [string[]]$Record.owned_paths
        depends_on = [string[]]$Record.depends_on
        estimated_seconds = $Record.estimated_seconds
        acceptance = [string[]]$Record.acceptance
        verification = [string[]]$Record.verification
        contract_ids = [string[]]$Record.contract_ids
        model = $Record.model
        reasoning_effort = $Record.reasoning_effort
        service_tier = $Record.service_tier
        sandbox_mode = $Record.sandbox_mode
        approval_policy = $Record.approval_policy
        nested_delegation = $Record.nested_delegation
        exit_code = $ExitCode
        last_message = $LastMessage
        last_message_path = $Record.last_message_path
        log_path = $Record.log_path
        started_at = $Record.started_at
        completed_at = $Record.completed_at
        duration_seconds = $Record.duration_seconds
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $result.error = $ErrorMessage
    }
    [pscustomobject]$result
}

# Keep a manifest snapshot for both modes. Detached mode uses it to pass the
# already validated input to the child process without fragile JSON quoting.
if ($manifestFormat -eq "planning-council-v1") {
    $normalizedManifestDocument = [ordered]@{
        schema_version = 1
        plan = $normalizedPlan
        plan_warnings = [string[]]$planWarnings
        workers = [object[]]$normalizedTasks
    }
    $normalizedManifestJson = ConvertTo-Json `
        -InputObject $normalizedManifestDocument `
        -Depth 15
} else {
    $normalizedManifestJson = ConvertTo-Json `
        -InputObject ([object[]]$normalizedTasks) `
        -Depth 15
}
Write-AtomicText -Path $runManifestPath -Content ([string]$normalizedManifestJson)

if ($ValidateOnly) {
    Write-RunStatus -RunState "validated" -ProcessId $null
    [ordered]@{
        valid = $true
        run_id = $RunId
        worker_count = $validatedTasks.Count
        max_workers = $maxWorkers
        worker_limit_scope = $workerConcurrencyScope
        manifest_format = $manifestFormat
        plan = $normalizedPlan
        plan_warnings = [string[]]$planWarnings
        predicted_schedule = $predictedSchedule
        nested_delegation = $workerNestedDelegation
        manifest_path = $runManifestPath
        status_path = $runStatusPath
    } | ConvertTo-Json -Depth 10
    return
}

if ($validatedTasks.Count -eq 0) {
    throw "Zero-worker structured plans are ValidateOnly-only; rerun with -ValidateOnly. No worker process or live-run mutex was started."
}

if ($Detached) {
    $runStdoutPath = Join-Path $OutputDirectory "run-stdout.log"
    $runStderrPath = Join-Path $OutputDirectory "run-stderr.log"
    Write-RunStatus -RunState "queued"

    $scriptPath = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Detached mode requires a script file path."
    } else {
        [System.IO.Path]::GetFullPath($PSCommandPath)
    }
    $hostExecutable = if ($PSVersionTable.PSEdition -eq "Core") {
        Join-Path $PSHOME "pwsh.exe"
    } else {
        Join-Path $PSHOME "powershell.exe"
    }
    if (-not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
        $hostCommandName = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh" } else { "powershell" }
        $hostCommand = Get-Command $hostCommandName -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
        $hostExecutable = $hostCommand.Path
    }

    Write-AtomicText -Path $runStdoutPath -Content ""
    Write-AtomicText -Path $runStderrPath -Content ""

    # Start-Process can block until the child exits on this Windows host when
    # RedirectStandardOutput/Error are used. Let the hidden child perform its
    # own redirection so detached mode really returns immediately.
    $encodeUtf8 = {
        param([string]$Text)
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
    }
    $scriptPathBase64 = & $encodeUtf8 $scriptPath
    $manifestPathBase64 = & $encodeUtf8 $runManifestPath
    $outputDirectoryBase64 = & $encodeUtf8 $OutputDirectory
    $stdoutPathBase64 = & $encodeUtf8 $runStdoutPath
    $stderrPathBase64 = & $encodeUtf8 $runStderrPath
    $runIdBase64 = & $encodeUtf8 $RunId
    $childBootstrap = @"
`$decode = {
    param([string]`$Value)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$Value))
}
`$scriptPath = & `$decode '$scriptPathBase64'
`$manifestPath = & `$decode '$manifestPathBase64'
`$outputDirectory = & `$decode '$outputDirectoryBase64'
`$stdoutPath = & `$decode '$stdoutPathBase64'
`$stderrPath = & `$decode '$stderrPathBase64'
`$runId = & `$decode '$runIdBase64'
try {
    & `$scriptPath -ManifestPath `$manifestPath -OutputDirectory `$outputDirectory -RunId `$runId 1> `$stdoutPath 2> `$stderrPath
    if (`$null -ne `$LASTEXITCODE) {
        exit [int]`$LASTEXITCODE
    }
    exit 0
} catch {
    [System.IO.File]::AppendAllText(
        `$stderrPath,
        (`$_ | Out-String),
        [System.Text.UTF8Encoding]::new(`$false)
    )
    exit 1
}
"@
    $encodedBootstrap = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childBootstrap)
    )
    $childArguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        $encodedBootstrap
    )

    try {
        $childProcess = Start-Process `
            -FilePath $hostExecutable `
            -ArgumentList $childArguments `
            -WindowStyle Hidden `
            -PassThru
    } catch {
        Write-RunStatus -RunState "failed"
        throw
    }

    $detachedResponse = [ordered]@{
        detached = $true
        run_id = $RunId
        process_id = [int]$childProcess.Id
        pid = [int]$childProcess.Id
        output_directory = $OutputDirectory
        worker_count = $validatedTasks.Count
        max_workers = $maxWorkers
        worker_limit_scope = $workerConcurrencyScope
        manifest_format = $manifestFormat
        plan = $normalizedPlan
        plan_warnings = [string[]]$planWarnings
        predicted_schedule = $predictedSchedule
        model = $workerModel
        reasoning_effort = $workerReasoningEffort
        service_tier = $workerServiceTier
        sandbox_mode = $workerSandboxMode
        approval_policy = $workerApprovalPolicy
        nested_delegation = $workerNestedDelegation
        run_status_path = $runStatusPath
        run_summary_path = $runSummaryPath
        run_results_path = $runResultsPath
        status_path = $runStatusPath
        summary_path = $runSummaryPath
        results_path = $runResultsPath
        stdout_path = $runStdoutPath
        stderr_path = $runStderrPath
        manifest_path = $runManifestPath
        artifacts = [ordered]@{
            status_path = $runStatusPath
            summary_path = $runSummaryPath
            results_path = $runResultsPath
            manifest_path = $runManifestPath
            stdout_path = $runStdoutPath
            stderr_path = $runStderrPath
        }
    }
    $detachedResponse | ConvertTo-Json -Depth 5
    return
}

$workerScript = {
    param(
        [string]$TaskName,
        [string]$TaskPrompt,
        [string]$WorkingDirectory,
        [string]$RunOutputDirectory,
        [string]$AssignmentContract
    )

    $ErrorActionPreference = "Stop"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
    $lastMessagePath = Join-Path $RunOutputDirectory "$TaskName-last-message.txt"
    $logPath = Join-Path $RunOutputDirectory "$TaskName-events.log"
    $workerPrompt = @"
You are a bounded luna_worker running as GPT-5.6 Luna with max reasoning,
Fast service tier, approval_policy=never, and danger-full-access sandbox.
Work only on the assignment below. Do not spawn or delegate to other agents.
Other workers may share the same filesystem. Preserve their changes, never
revert unrelated work, and adapt to concurrent edits. Inspect only the current
state needed for your owned scope before editing; avoid a broad repository scan
unless the assignment requires it. Return a concise handoff with outcomes,
verification, and absolute file references.

Task name: $TaskName

Structured assignment contract:
$AssignmentContract

$TaskPrompt
"@

    $codexArguments = @(
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--model", "gpt-5.6-luna",
        "-c", 'model_reasoning_effort="max"',
        "-c", 'service_tier="fast"',
        "-c", 'approval_policy="never"',
        "--disable", "multi_agent",
        "--sandbox", "danger-full-access",
        "--cd", $WorkingDirectory,
        "--json",
        "--output-last-message", $lastMessagePath,
        "-"
    )

    $eventLines = @(
        $workerPrompt |
            & codex @codexArguments 2>&1 |
            ForEach-Object { $_.ToString() }
    )
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    [System.IO.File]::WriteAllLines(
        $logPath,
        [string[]]$eventLines,
        [System.Text.UTF8Encoding]::new($false)
    )

    $lastMessage = if (Test-Path -LiteralPath $lastMessagePath) {
        Get-Content -LiteralPath $lastMessagePath -Raw
    } else {
        ""
    }

    [pscustomobject]@{
        name = $TaskName
        model = "gpt-5.6-luna"
        reasoning_effort = "max"
        service_tier = "fast"
        sandbox_mode = "danger-full-access"
        approval_policy = "never"
        nested_delegation = "disabled"
        exit_code = $exitCode
        last_message = $lastMessage
        last_message_path = $lastMessagePath
        log_path = $logPath
    }
}

$jobEntriesById = @{}
$allJobs = @()
$resultsByName = @{}
$terminalJobStates = @("Completed", "Failed", "Stopped", "Disconnected", "Blocked")
$runMutex = [System.Threading.Mutex]::new($false, $workerMutexName)
$runMutexAcquired = $false

try {
    try {
        $runMutexAcquired = $runMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # The prior owner ended without releasing the mutex. Windows transfers
        # ownership to this process, so the ready wave can proceed safely.
        $runMutexAcquired = $true
    }
    if (-not $runMutexAcquired) {
        Write-RunStatus -RunState "failed"
        throw "Another luna-team-build worker wave is already running in this Windows session; the global live-worker ceiling is $maxWorkers."
    }

    Write-RunStatus -RunState "starting"
    foreach ($task in $validatedTasks) {
        $record = $workerRecordByName[$task.name]
        $startedAt = [DateTimeOffset]::UtcNow
        $record.started_at = $startedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
        try {
            $assignmentContract = [ordered]@{
                working_directory = $task.working_directory
                review_only = $task.review_only
                owned_paths = [string[]]$task.owned_paths
                depends_on = [string[]]$task.depends_on
                estimated_seconds = $task.estimated_seconds
                contract_ids = [string[]]$task.contract_ids
                acceptance = [string[]]$task.acceptance
                verification = [string[]]$task.verification
            } | ConvertTo-Json -Depth 8
            $job = Start-ThreadJob -ScriptBlock $workerScript -ArgumentList @(
                $task.name,
                $task.prompt,
                $task.working_directory,
                $OutputDirectory,
                [string]$assignmentContract
            )
            $record.state = "running"
            $jobEntriesById[[int]$job.Id] = [pscustomobject]@{
                job = $job
                record = $record
                started_at = $startedAt
            }
            $allJobs += $job
        } catch {
            $completedAt = [DateTimeOffset]::UtcNow
            $errorMessage = $_.Exception.Message
            $record.state = "failed"
            $record.completed_at = $completedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
            $record.duration_seconds = Get-DurationSeconds -Start $startedAt -End $completedAt
            $record.exit_code = 1
            $record.error = $errorMessage
            $resultsByName[$record.name] = New-WorkerResult `
                -Record $record `
                -ExitCode 1 `
                -LastMessage "" `
                -ErrorMessage $errorMessage
        }

        $startStatus = if ($jobEntriesById.Count -gt 0) { "running" } else { "failed" }
        Write-RunStatus -RunState $startStatus
    }

    while ($jobEntriesById.Count -gt 0) {
        $completedEntries = @()
        foreach ($entry in @($jobEntriesById.Values)) {
            $currentJob = Get-Job -Id ([int]$entry.job.Id) -ErrorAction SilentlyContinue
            if ($null -ne $currentJob) {
                $entry.job = $currentJob
            }
            if ($entry.job.State -in $terminalJobStates) {
                $completedEntries += $entry
            }
        }

        if ($completedEntries.Count -eq 0) {
            Write-RunStatus -RunState "running"
            # A one-second heartbeat keeps status observable without performing
            # thousands of atomic file replacements during long Luna runs.
            Start-Sleep -Milliseconds 1000
            continue
        }

        foreach ($entry in $completedEntries) {
            $record = $entry.record
            $completedAt = [DateTimeOffset]::UtcNow
            $record.completed_at = $completedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
            $record.duration_seconds = Get-DurationSeconds -Start $entry.started_at -End $completedAt
            $receiveError = $null
            $received = @()
            try {
                $received = @($entry.job | Receive-Job -ErrorAction Stop)
            } catch {
                $receiveError = $_.Exception.Message
            }

            $workerResult = $null
            if ($null -eq $receiveError) {
                foreach ($candidate in $received) {
                    if ($null -ne $candidate -and
                        $candidate.PSObject.Properties.Name -contains "exit_code") {
                        $workerResult = $candidate
                        break
                    }
                }
            }

            $exitCode = 1
            $lastMessage = ""
            $failureMessage = $null
            if ($entry.job.State -ne "Completed") {
                $failureMessage = "Thread job ended in state '$($entry.job.State)'."
                $reason = $entry.job.JobStateInfo.Reason
                if ($null -ne $reason -and -not [string]::IsNullOrWhiteSpace($reason.Message)) {
                    $failureMessage = "$failureMessage $($reason.Message)"
                }
            } elseif ($null -ne $receiveError) {
                $failureMessage = "Unable to receive worker result: $receiveError"
            } elseif ($null -eq $workerResult) {
                $failureMessage = "Worker completed without a result object."
            } else {
                try {
                    $exitCode = [int]$workerResult.exit_code
                } catch {
                    $failureMessage = "Worker returned an invalid exit code."
                }
                if ($workerResult.PSObject.Properties.Name -contains "last_message") {
                    $lastMessage = [string]$workerResult.last_message
                }
                if ($exitCode -ne 0 -and $null -eq $failureMessage) {
                    $failureMessage = "Worker exited with code $exitCode."
                }
            }

            $record.exit_code = $exitCode
            $record.error = $failureMessage
            $record.state = if ($exitCode -eq 0 -and $null -eq $failureMessage) {
                "completed"
            } else {
                "failed"
            }
            $resultsByName[$record.name] = New-WorkerResult `
                -Record $record `
                -ExitCode $exitCode `
                -LastMessage $lastMessage `
                -ErrorMessage ([string]$failureMessage)

            [void]$jobEntriesById.Remove([int]$entry.job.Id)
            $statusAfterCompletion = if ($jobEntriesById.Count -gt 0) { "running" } else { "finalizing" }
            Write-RunStatus -RunState $statusAfterCompletion
        }
    }
} finally {
    foreach ($job in @($allJobs)) {
        if ($null -ne $job) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    if ($runMutexAcquired) {
        try {
            $runMutex.ReleaseMutex()
        } catch {
            # Preserve the original worker error when cleanup itself fails.
        }
    }
    $runMutex.Dispose()
}

# Every normal path above supplies a result. Keep a failed result for any
# unexpected missing entry so the output and exit contract remain complete.
foreach ($task in $validatedTasks) {
    if (-not $resultsByName.ContainsKey($task.name)) {
        $record = $workerRecordByName[$task.name]
        $now = [DateTimeOffset]::UtcNow
        if ($null -eq $record.started_at) {
            $record.started_at = $now.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $record.completed_at = $now.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
        $record.duration_seconds = 0.0
        $record.exit_code = 1
        $record.state = "failed"
        $record.error = "Worker did not produce a result."
        $resultsByName[$task.name] = New-WorkerResult `
            -Record $record `
            -ExitCode 1 `
            -LastMessage "" `
            -ErrorMessage $record.error
    }
}

$results = @($validatedTasks | ForEach-Object { $resultsByName[$_.name] })
$resultsJson = $results | ConvertTo-Json -Depth 5
Write-AtomicText -Path $runResultsPath -Content ([string]$resultsJson)

$runCompletedAt = [DateTimeOffset]::UtcNow
$runCompletedAtText = $runCompletedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
$wallDurationSeconds = Get-DurationSeconds -Start $runStartedAt -End $runCompletedAt
$workerDurations = @(
    $workerRecords |
        Where-Object { $null -ne $_.duration_seconds } |
        ForEach-Object { [double]$_.duration_seconds }
)
$summedWorkerDurationSeconds = if ($workerDurations.Count -gt 0) {
    [Math]::Round(([double]($workerDurations | Measure-Object -Sum).Sum), 3)
} else {
    0.0
}
$parallelismRatio = if ($wallDurationSeconds -gt 0) {
    [Math]::Round(($summedWorkerDurationSeconds / $wallDurationSeconds), 3)
} else {
    0.0
}
$actualCapacityUtilization = if ($wallDurationSeconds -gt 0 -and $workerRecords.Count -gt 0) {
    [Math]::Round(
        $summedWorkerDurationSeconds / ($workerRecords.Count * $wallDurationSeconds),
        3
    )
} else {
    0.0
}
$actualMaximumDuration = if ($workerDurations.Count -gt 0) {
    [double]($workerDurations | Measure-Object -Maximum).Maximum
} else {
    0.0
}
$actualMinimumDuration = if ($workerDurations.Count -gt 0) {
    [double]($workerDurations | Measure-Object -Minimum).Minimum
} else {
    0.0
}
$actualBalanceRatio = if ($actualMaximumDuration -gt 0) {
    [Math]::Round($actualMinimumDuration / $actualMaximumDuration, 3)
} else {
    0.0
}
$idleSlotSeconds = [Math]::Round(
    [Math]::Max(
        0.0,
        ($workerRecords.Count * $wallDurationSeconds) - $summedWorkerDurationSeconds
    ),
    3
)
$workerStartTimes = @(
    $workerRecords |
        Where-Object { $null -ne $_.started_at } |
        ForEach-Object { [DateTimeOffset]$_.started_at }
)
$startSkewSeconds = if ($workerStartTimes.Count -gt 1) {
    $latestStart = $workerStartTimes | Sort-Object | Select-Object -Last 1
    $earliestStart = $workerStartTimes | Sort-Object | Select-Object -First 1
    [Math]::Round(($latestStart - $earliestStart).TotalSeconds, 3)
} else {
    0.0
}
$estimatedParallelTimeSavedSeconds = [Math]::Round(
    [Math]::Max(0.0, ($summedWorkerDurationSeconds - $wallDurationSeconds)),
    3
)
$workerFailures = @(
    $workerRecords |
        Where-Object {
            $_.state -eq "failed" -or
            ($null -ne $_.exit_code -and [int]$_.exit_code -ne 0)
        }
)
$finalStatus = if ($workerFailures.Count -gt 0) { "failed" } else { "completed" }
$slowestRecord = $workerRecords |
    Where-Object { $null -ne $_.duration_seconds } |
    Sort-Object -Property @{ Expression = { [double]$_.duration_seconds }; Descending = $true } |
    Select-Object -First 1
$slowestWorker = if ($null -eq $slowestRecord) {
    $null
} else {
    [ordered]@{
        name = $slowestRecord.name
        duration_seconds = $slowestRecord.duration_seconds
    }
}
$summaryWorkers = @(
    $workerRecords | ForEach-Object {
        [ordered]@{
            name = $_.name
            working_directory = $_.working_directory
            review_only = $_.review_only
            owned_paths = [string[]]$_.owned_paths
            depends_on = [string[]]$_.depends_on
            estimated_seconds = $_.estimated_seconds
            acceptance = [string[]]$_.acceptance
            verification = [string[]]$_.verification
            contract_ids = [string[]]$_.contract_ids
            model = $_.model
            reasoning_effort = $_.reasoning_effort
            service_tier = $_.service_tier
            sandbox_mode = $_.sandbox_mode
            approval_policy = $_.approval_policy
            nested_delegation = $_.nested_delegation
            state = $_.state
            exit_code = $_.exit_code
            started_at = $_.started_at
            completed_at = $_.completed_at
            duration_seconds = $_.duration_seconds
        }
    }
)
$runSummary = [ordered]@{
    run_id = $RunId
    status = $finalStatus
    worker_count = $workerRecords.Count
    max_workers = $maxWorkers
    worker_limit_scope = $workerConcurrencyScope
    manifest_format = $manifestFormat
    plan = $normalizedPlan
    plan_warnings = [string[]]$planWarnings
    predicted_schedule = $predictedSchedule
    model = $workerModel
    reasoning_effort = $workerReasoningEffort
    service_tier = $workerServiceTier
    sandbox_mode = $workerSandboxMode
    approval_policy = $workerApprovalPolicy
    nested_delegation = $workerNestedDelegation
    started_at = $runStartedAtText
    completed_at = $runCompletedAtText
    wall_duration_seconds = $wallDurationSeconds
    summed_worker_duration_seconds = $summedWorkerDurationSeconds
    parallelism_ratio = $parallelismRatio
    worker_overlap_seconds = $estimatedParallelTimeSavedSeconds
    estimated_parallel_time_saved_seconds = $estimatedParallelTimeSavedSeconds
    estimated_parallel_time_saved_is_legacy_overlap_alias = $true
    actual_capacity_utilization = $actualCapacityUtilization
    actual_balance_ratio = $actualBalanceRatio
    idle_slot_seconds = $idleSlotSeconds
    start_skew_seconds = $startSkewSeconds
    slowest_worker = $slowestWorker
    workers = $summaryWorkers
    artifacts = [ordered]@{
        manifest_path = $runManifestPath
        status_path = $runStatusPath
        results_path = $runResultsPath
        summary_path = $runSummaryPath
    }
}
Write-AtomicJson -Path $runSummaryPath -Value $runSummary -Depth 10
Write-RunStatus -RunState $finalStatus

# Preserve the original synchronous stdout contract: the result is still the
# JSON array/object of worker result records, with observability fields added.
$resultsJson
if ($workerFailures.Count -gt 0) {
    exit 1
}
