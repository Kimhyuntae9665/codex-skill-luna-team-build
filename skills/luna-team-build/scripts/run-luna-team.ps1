[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$ManifestJson,
    [string]$OutputDirectory,
    [switch]$Detached,
    [switch]$ValidateOnly,
    [string]$RunId,
    [string]$CodexExecutable = "codex"
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
$schedulerMode = $null
$concurrencyLimit = $null
$isSchemaV2 = $false
$taskCount = 0
$initialReadyCount = 0
$peakActiveWorkers = 0

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
    $schemaVersion = Get-OptionalProperty -Object $parsedManifest -Name "schema_version"
    try {
        $schemaVersion = [int]$schemaVersion
    } catch {
        throw "The Planning Council manifest requires schema_version 1 or 2."
    }
    if ($schemaVersion -notin @(1, 2)) {
        throw "The Planning Council manifest requires schema_version 1 or 2."
    }
    $manifestFormat = "planning-council-v$schemaVersion"
    $isSchemaV2 = $schemaVersion -eq 2
    $planInput = Get-OptionalProperty -Object $parsedManifest -Name "plan"
    $tasks = @(Get-OptionalProperty -Object $parsedManifest -Name "workers")
} else {
    $tasks = @($parsedManifest)
}

if ($manifestFormat -like "planning-council-v*") {
    if ($tasks.Count -lt 0 -or $tasks.Count -gt $maxWorkers) {
        throw "The structured manifest must contain between zero and $maxWorkers workers."
    }
} elseif ($tasks.Count -lt 1 -or $tasks.Count -gt $maxWorkers) {
    throw "The legacy manifest must contain between one and $maxWorkers workers."
}
if ($tasks.Count -gt 3 -and $manifestFormat -notlike "planning-council-v*") {
    throw "Four to seven workers require the structured Planning Council manifest."
}

$planWarnings = [System.Collections.Generic.List[string]]::new()
$normalizedPlan = $null
$normalizedRootOwnedPaths = @()
if ($manifestFormat -like "planning-council-v*") {
    if ($null -eq $planInput) {
        throw "The Planning Council manifest is missing its plan object."
    }

    if ($isSchemaV2) {
        $schedulerMode = [string](
            Get-OptionalProperty -Object $planInput -Name "scheduler_mode" -Default ""
        )
        if ($schedulerMode -notin @("rolling-dag-v1", "barrier-dag-v1")) {
            throw "schema_version 2 requires plan.scheduler_mode to be rolling-dag-v1 or barrier-dag-v1."
        }
        if ($tasks.Count -lt 1) {
            throw "schema_version 2 requires at least one selected task for concurrency_limit."
        }
        try {
            $concurrencyRaw = Get-OptionalProperty -Object $planInput -Name "concurrency_limit"
            $concurrencyLimit = [int](
                $concurrencyRaw
            )
            if ($null -ne $concurrencyRaw -and
                [double]$concurrencyRaw -ne [double]$concurrencyLimit) {
                throw "not an integer"
            }
        } catch {
            throw "schema_version 2 requires an integer plan.concurrency_limit."
        }
        $maximumV2Concurrency = [Math]::Min($tasks.Count, $maxWorkers)
        if ($concurrencyLimit -lt 1 -or $concurrencyLimit -gt $maximumV2Concurrency) {
            throw "plan.concurrency_limit must be between 1 and $maximumV2Concurrency."
        }
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
    if (-not $isSchemaV2 -and $selectedWorkerCount -gt $readyTrackCount) {
        throw "selected_worker_count cannot exceed ready_track_count."
    }
    if ($planningSecondsEstimate -lt 0) {
        throw "planning_seconds_estimate cannot be negative."
    }

    $candidateScheduleInputs = @(
        Get-OptionalProperty -Object $planInput -Name "candidate_schedules"
    )
    $candidateCountLimit = if ($isSchemaV2) {
        $selectedWorkerCount
    } else {
        $readyTrackCount
    }
    if ($candidateScheduleInputs.Count -ne ($candidateCountLimit + 1)) {
        throw "candidate_schedules must cover every worker count from zero through the selected candidate limit."
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
            if ($candidateWorkerCount -lt 0 -or $candidateWorkerCount -gt $candidateCountLimit) {
                throw "Candidate worker_count is outside the selected candidate range: $candidateWorkerCount"
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
    foreach ($expectedCandidateCount in 0..$candidateCountLimit) {
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
    if ($isSchemaV2) {
        $normalizedPlan["scheduler_mode"] = $schedulerMode
        $normalizedPlan["concurrency_limit"] = $concurrencyLimit
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
    if ($manifestFormat -like "planning-council-v*" -and
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

    if (-not $isSchemaV2 -and $dependsOn.Count -gt 0) {
        throw "Worker '$name' has unresolved same-wave dependencies: $($dependsOn -join ', ')"
    }
    if ($manifestFormat -like "planning-council-v*") {
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

$taskCount = $validatedTasks.Count
$taskByName = @{}
$dependentsByName = @{}
$criticalPathByName = @{}
$criticalPathTaskNames = @()
$criticalPathSeconds = 0.0
$topologicalNames = [System.Collections.Generic.List[string]]::new()
$initialReadyNames = [System.Collections.Generic.List[string]]::new()
foreach ($task in $validatedTasks) {
    $taskByName[$task.name] = $task
    $dependentsByName[$task.name] = @()
}

if ($isSchemaV2) {
    foreach ($task in $validatedTasks) {
        $seenDependencies = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($dependencyName in @($task.depends_on)) {
            if (-not $seenDependencies.Add($dependencyName)) {
                throw "Worker '$($task.name)' has duplicate dependency '$dependencyName'."
            }
            if ([string]::Equals($task.name, $dependencyName, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Worker '$($task.name)' cannot depend on itself."
            }
            if (-not $taskByName.ContainsKey($dependencyName)) {
                throw "Worker '$($task.name)' has missing dependency '$dependencyName'."
            }
            $dependencyTask = $taskByName[$dependencyName]
            $dependentsByName[$dependencyTask.name] = @(
                $dependentsByName[$dependencyTask.name] + $task.name
            )
        }
    }

    $topologicalIndegree = @{}
    $topologicalReady = [System.Collections.Generic.List[string]]::new()
    foreach ($task in $validatedTasks) {
        $topologicalIndegree[$task.name] = @($task.depends_on).Count
        if (@($task.depends_on).Count -eq 0) {
            [void]$topologicalReady.Add($task.name)
        }
    }
    while ($topologicalReady.Count -gt 0) {
        $nextName = @($topologicalReady | Sort-Object)[0]
        [void]$topologicalReady.Remove($nextName)
        [void]$topologicalNames.Add($nextName)
        foreach ($dependentName in @($dependentsByName[$nextName] | Sort-Object)) {
            $topologicalIndegree[$dependentName] = [int]$topologicalIndegree[$dependentName] - 1
            if ([int]$topologicalIndegree[$dependentName] -eq 0) {
                [void]$topologicalReady.Add($dependentName)
            }
        }
    }
    if ($topologicalNames.Count -ne $validatedTasks.Count) {
        throw "The v2 dependency graph contains a cycle."
    }

    for ($topologicalIndex = $topologicalNames.Count - 1; $topologicalIndex -ge 0; $topologicalIndex--) {
        $taskName = $topologicalNames[$topologicalIndex]
        $childCriticalPath = 0.0
        foreach ($dependentName in @($dependentsByName[$taskName])) {
            if ([double]$criticalPathByName[$dependentName] -gt $childCriticalPath) {
                $childCriticalPath = [double]$criticalPathByName[$dependentName]
            }
        }
        $criticalPathByName[$taskName] = [Math]::Round(
            [double]$taskByName[$taskName].estimated_seconds + $childCriticalPath,
            3
        )
    }
    foreach ($task in $validatedTasks) {
        if (@($task.depends_on).Count -eq 0) {
            [void]$initialReadyNames.Add($task.name)
        }
    }
    $initialReadyCount = $initialReadyNames.Count
    if ($readyTrackCount -ne $initialReadyCount) {
        throw "schema_version 2 ready_track_count must equal the computed initial-ready task count ($initialReadyCount)."
    }

    $criticalPathSeconds = [double](
        $criticalPathByName.Values | Measure-Object -Maximum
    ).Maximum
    $criticalPathCursor = @(
        $initialReadyNames |
            Sort-Object `
                -Property `
                    @{ Expression = { [double]$criticalPathByName[[string]$_] }; Descending = $true },
                    @{ Expression = { [double]$taskByName[[string]$_].estimated_seconds }; Descending = $true },
                    @{ Expression = { [string]$_ }; Ascending = $true }
    )[0]
    $criticalPathTasks = [System.Collections.Generic.List[string]]::new()
    while (-not [string]::IsNullOrWhiteSpace($criticalPathCursor)) {
        [void]$criticalPathTasks.Add($criticalPathCursor)
        $nextCriticalTasks = @(
            $dependentsByName[$criticalPathCursor] |
                Sort-Object `
                    -Property `
                        @{ Expression = { [double]$criticalPathByName[[string]$_] }; Descending = $true },
                        @{ Expression = { [double]$taskByName[[string]$_].estimated_seconds }; Descending = $true },
                        @{ Expression = { [string]$_ }; Ascending = $true }
        )
        $criticalPathCursor = if ($nextCriticalTasks.Count -gt 0) {
            [string]$nextCriticalTasks[0]
        } else {
            $null
        }
    }
    $criticalPathTaskNames = [string[]]$criticalPathTasks
}

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

function Get-DeterministicReadyOrder {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable]$Names
    )

    @(
        $Names |
            Sort-Object `
                -Property `
                @{ Expression = { [double]$criticalPathByName[[string]$_] }; Descending = $true },
                @{ Expression = { [double]$taskByName[[string]$_].estimated_seconds }; Descending = $true },
                @{ Expression = { [string]$_ }; Ascending = $true }
    )
}

function Invoke-DagScheduleSimulation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("rolling-dag-v1", "barrier-dag-v1")]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [int]$Limit
    )

    $simulationState = @{}
    $simulationReady = [System.Collections.Generic.List[string]]::new()
    $simulationActive = @{}
    $simulationFinish = @{}
    foreach ($task in $validatedTasks) {
        $simulationState[$task.name] = "pending"
        if (@($task.depends_on).Count -eq 0) {
            [void]$simulationReady.Add($task.name)
        }
    }

    $simulationTime = 0.0
    $simulationPeak = 0
    $simulationCompleted = 0
    while ($simulationCompleted -lt $validatedTasks.Count) {
        if ($Mode -eq "barrier-dag-v1") {
            if ($simulationActive.Count -eq 0) {
                $batch = @(Get-DeterministicReadyOrder -Names $simulationReady |
                    Select-Object -First $Limit)
                if ($batch.Count -eq 0) {
                    throw "The v2 DAG scheduler simulation could not find ready work."
                }
                foreach ($taskName in $batch) {
                    [void]$simulationReady.Remove($taskName)
                    $simulationState[$taskName] = "running"
                    $simulationActive[$taskName] = $true
                    $simulationFinish[$taskName] = $simulationTime +
                        [double]$taskByName[$taskName].estimated_seconds
                }
                if ($simulationActive.Count -gt $simulationPeak) {
                    $simulationPeak = $simulationActive.Count
                }
            }
            $nextSimulationTime = [double](
                ($simulationActive.Keys |
                    ForEach-Object { [double]$simulationFinish[$_] } |
                    Measure-Object -Maximum).Maximum
            )
        } else {
            while ($simulationActive.Count -lt $Limit -and $simulationReady.Count -gt 0) {
                $nextTaskName = @(Get-DeterministicReadyOrder -Names $simulationReady)[0]
                [void]$simulationReady.Remove($nextTaskName)
                $simulationState[$nextTaskName] = "running"
                $simulationActive[$nextTaskName] = $true
                $simulationFinish[$nextTaskName] = $simulationTime +
                    [double]$taskByName[$nextTaskName].estimated_seconds
            }
            if ($simulationActive.Count -gt $simulationPeak) {
                $simulationPeak = $simulationActive.Count
            }
            if ($simulationActive.Count -eq 0) {
                throw "The v2 DAG scheduler simulation could not find ready work."
            }
            $nextSimulationTime = [double](
                ($simulationActive.Keys |
                    ForEach-Object { [double]$simulationFinish[$_] } |
                    Measure-Object -Minimum).Minimum
            )
        }

        $simulationTime = $nextSimulationTime
        $completedNow = @(
            $simulationActive.Keys |
                Where-Object { [double]$simulationFinish[$_] -le $simulationTime } |
                Sort-Object
        )
        foreach ($completedTaskName in $completedNow) {
            $simulationState[$completedTaskName] = "completed"
            [void]$simulationActive.Remove($completedTaskName)
            $simulationCompleted++
        }
        foreach ($completedTaskName in $completedNow) {
            foreach ($dependentName in @($dependentsByName[$completedTaskName])) {
                if ($simulationState[$dependentName] -ne "pending") {
                    continue
                }
                $allDependenciesCompleted = $true
                foreach ($dependencyName in @($taskByName[$dependentName].depends_on)) {
                    if ($simulationState[$dependencyName] -ne "completed") {
                        $allDependenciesCompleted = $false
                        break
                    }
                }
                if ($allDependenciesCompleted) {
                    $simulationState[$dependentName] = "ready"
                    [void]$simulationReady.Add($dependentName)
                }
            }
        }
    }

    [pscustomobject]@{
        worker_wall_seconds = [Math]::Round($simulationTime, 3)
        peak_active_workers = $simulationPeak
    }
}

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
        $predictedSchedule["selected_predicted_total_seconds"] =
            [double]$selectedCandidateSchedule.predicted_total_seconds
    } elseif ($isSchemaV2) {
        $dagSimulation = Invoke-DagScheduleSimulation `
            -Mode $schedulerMode `
            -Limit $concurrencyLimit
        $predictedCapacityUtilization = if (
            [double]$dagSimulation.worker_wall_seconds -gt 0 -and
            $concurrencyLimit -gt 0
        ) {
            [Math]::Round(
                $estimatedSum /
                    ($concurrencyLimit * [double]$dagSimulation.worker_wall_seconds),
                3
            )
        } else {
            0.0
        }
        $selectedCandidateSchedule = @(
            $normalizedCandidateSchedules |
                Where-Object { [int]$_.worker_count -eq $validatedTasks.Count }
        )[0]
        if ([Math]::Abs(
                [double]$selectedCandidateSchedule.predicted_worker_wall_seconds -
                [double]$dagSimulation.worker_wall_seconds
            ) -gt 0.001) {
            throw "The selected candidate's predicted_worker_wall_seconds must equal the v2 deterministic DAG worker wall time ($($dagSimulation.worker_wall_seconds))."
        }
        $predictedSchedule["scheduler_mode"] = $schedulerMode
        $predictedSchedule["concurrency_limit"] = $concurrencyLimit
        $predictedSchedule["task_count"] = $validatedTasks.Count
        $predictedSchedule["initial_ready_count"] = $initialReadyCount
        $predictedSchedule["peak_active_workers"] = $dagSimulation.peak_active_workers
        $predictedSchedule["utilization_capacity_denominator"] = $concurrencyLimit
        $predictedSchedule["predicted_capacity_utilization"] =
            $predictedCapacityUtilization
        $predictedSchedule["critical_path"] = [string[]]$criticalPathTaskNames
        $predictedSchedule["predicted_worker_wall_seconds"] =
            [double]$dagSimulation.worker_wall_seconds
        $predictedSchedule["critical_path_seconds"] = $criticalPathSeconds
        $predictedSchedule["selected_predicted_total_seconds"] =
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
        $normalizedTask = [ordered]@{
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
        if ($isSchemaV2) {
            $normalizedTask["scheduler_mode"] = $schedulerMode
            $normalizedTask["concurrency_limit"] = $concurrencyLimit
            $normalizedTask["task_count"] = $validatedTasks.Count
            $normalizedTask["state"] = if (@($_.depends_on).Count -eq 0) { "ready" } else { "pending" }
            $normalizedTask["ready_at"] = $null
            $normalizedTask["started_at"] = $null
            $normalizedTask["completed_at"] = $null
            $normalizedTask["queue_wait_seconds"] = $null
            $normalizedTask["critical_path_seconds"] = [double]$criticalPathByName[$_.name]
            $normalizedTask["blocked_by"] = [string[]]$_.depends_on
            $normalizedDependencyStates = [ordered]@{}
            foreach ($dependencyName in @($_.depends_on)) {
                $normalizedDependencyStates[$dependencyName] = "pending"
            }
            $normalizedTask["dependency_states"] = $normalizedDependencyStates
            $normalizedTask["skip_reason"] = $null
        }
        $normalizedTask
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
            scheduler_mode = $null
            concurrency_limit = $null
            task_count = $null
            ready_at = $null
            queue_wait_seconds = $null
            critical_path_seconds = $null
            blocked_by = [string[]]@()
            dependency_states = [ordered]@{}
            skip_reason = $null
            last_message_path = Join-Path $OutputDirectory "$($task.name)-last-message.txt"
            log_path = Join-Path $OutputDirectory "$($task.name)-events.log"
        }
        if ($isSchemaV2) {
            $record.scheduler_mode = $schedulerMode
            $record.concurrency_limit = $concurrencyLimit
            $record.task_count = $validatedTasks.Count
            $record.ready_at = if (@($task.depends_on).Count -eq 0) {
                $runStartedAtText
            } else {
                $null
            }
            $record.queue_wait_seconds = $null
            $record.critical_path_seconds = [double]$criticalPathByName[$task.name]
            $record.blocked_by = [string[]]$task.depends_on
            $record.dependency_states = [ordered]@{}
            foreach ($dependencyName in @($task.depends_on)) {
                $record.dependency_states[$dependencyName] = "pending"
            }
            $record.skip_reason = $null
            $record.state = if (@($task.depends_on).Count -eq 0) { "ready" } else { "pending" }
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

    $statusWorker = [ordered]@{
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
    if ($isSchemaV2) {
        $statusWorker["scheduler_mode"] = $Record.scheduler_mode
        $statusWorker["concurrency_limit"] = $Record.concurrency_limit
        $statusWorker["task_count"] = $Record.task_count
        $statusWorker["ready_at"] = $Record.ready_at
        $statusWorker["queue_wait_seconds"] = $Record.queue_wait_seconds
        $statusWorker["critical_path_seconds"] = $Record.critical_path_seconds
        $statusWorker["blocked_by"] = [string[]]$Record.blocked_by
        $statusWorker["dependency_states"] = $Record.dependency_states
        $statusWorker["skip_reason"] = $Record.skip_reason
    }
    $statusWorker
}

function Write-RunStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunState,
        [object]$ProcessId = $PID
    )

    $statusWorkers = @($workerRecords | ForEach-Object { Get-StatusWorker -Record $_ })
    $statusStateCounts = [ordered]@{
        pending = @($workerRecords | Where-Object { $_.state -eq "pending" }).Count
        ready = @($workerRecords | Where-Object { $_.state -eq "ready" }).Count
        running = @($workerRecords | Where-Object { $_.state -eq "running" }).Count
        completed = @($workerRecords | Where-Object { $_.state -eq "completed" }).Count
        failed = @($workerRecords | Where-Object { $_.state -eq "failed" }).Count
        skipped = @($workerRecords | Where-Object { $_.state -eq "skipped" }).Count
    }
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
    if ($isSchemaV2) {
        $statusDocument["scheduler_mode"] = $schedulerMode
        $statusDocument["concurrency_limit"] = $concurrencyLimit
        $statusDocument["task_count"] = $taskCount
        $statusDocument["initial_ready_count"] = $initialReadyCount
        $statusDocument["critical_path"] = [string[]]$criticalPathTaskNames
        $statusDocument["critical_path_seconds"] = $criticalPathSeconds
        $statusDocument["peak_active_workers"] = $peakActiveWorkers
        $statusDocument["active_workers"] = $statusStateCounts.running
        $statusDocument["state_counts"] = $statusStateCounts
        $statusDocument["completed_count"] = $statusStateCounts.completed
        $statusDocument["failed_count"] = $statusStateCounts.failed
        $statusDocument["skipped_count"] = $statusStateCounts.skipped
    }
    Write-AtomicJson -Path $runStatusPath -Value $statusDocument -Depth 10
}

function New-WorkerResult {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Record,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ExitCode,
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
    if ($isSchemaV2) {
        $result["scheduler_mode"] = $Record.scheduler_mode
        $result["concurrency_limit"] = $Record.concurrency_limit
        $result["task_count"] = $Record.task_count
        $result["initial_ready_count"] = $initialReadyCount
        $result["peak_active_workers"] = $peakActiveWorkers
        $result["state"] = $Record.state
        $result["ready_at"] = $Record.ready_at
        $result["queue_wait_seconds"] = $Record.queue_wait_seconds
        $result["critical_path_seconds"] = $Record.critical_path_seconds
        $result["blocked_by"] = [string[]]$Record.blocked_by
        $result["dependency_states"] = $Record.dependency_states
        $result["skip_reason"] = $Record.skip_reason
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
} elseif ($isSchemaV2) {
    $normalizedManifestDocument = [ordered]@{
        schema_version = 2
        scheduler_mode = $schedulerMode
        concurrency_limit = $concurrencyLimit
        task_count = $taskCount
        initial_ready_count = $initialReadyCount
        critical_path = [string[]]$criticalPathTaskNames
        critical_path_seconds = $criticalPathSeconds
        peak_active_workers = $peakActiveWorkers
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
    $validationOutput = [ordered]@{
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
    }
    if ($isSchemaV2) {
        $validationOutput["scheduler_mode"] = $schedulerMode
        $validationOutput["concurrency_limit"] = $concurrencyLimit
        $validationOutput["task_count"] = $taskCount
        $validationOutput["initial_ready_count"] = $initialReadyCount
        $validationOutput["critical_path"] = [string[]]$criticalPathTaskNames
        $validationOutput["critical_path_seconds"] = $criticalPathSeconds
        $validationOutput["peak_active_workers"] = $peakActiveWorkers
    }
    $validationOutput | ConvertTo-Json -Depth 10
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
    $codexExecutableBase64 = & $encodeUtf8 $CodexExecutable
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
`$codexExecutable = & `$decode '$codexExecutableBase64'
try {
    & `$scriptPath -ManifestPath `$manifestPath -OutputDirectory `$outputDirectory -RunId `$runId -CodexExecutable `$codexExecutable 1> `$stdoutPath 2> `$stderrPath
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
    if ($isSchemaV2) {
        $detachedResponse["scheduler_mode"] = $schedulerMode
        $detachedResponse["concurrency_limit"] = $concurrencyLimit
        $detachedResponse["task_count"] = $taskCount
        $detachedResponse["initial_ready_count"] = $initialReadyCount
        $detachedResponse["critical_path"] = [string[]]$criticalPathTaskNames
        $detachedResponse["critical_path_seconds"] = $criticalPathSeconds
        $detachedResponse["peak_active_workers"] = $peakActiveWorkers
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
        [string]$AssignmentContract,
        [string]$CodexExecutable
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

Dependency handoff (no raw predecessor output injection):
Predecessor task names: $([string]::Join(', ', @(
    try {
        $contractObject = $AssignmentContract | ConvertFrom-Json
        @($contractObject.predecessor_task_names)
    } catch {
        @()
    }
)))
Read only frozen artifacts/contracts declared by those predecessor tasks; do not expect predecessor output to be injected into this prompt.
Preserve owned-path writes and do not modify predecessor-owned paths.

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
            & $CodexExecutable @codexArguments 2>&1 |
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

function Get-V2DependencyStates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    $states = [ordered]@{}
    foreach ($dependencyName in @($taskByName[$TaskName].depends_on)) {
        $states[$dependencyName] = $workerRecordByName[$dependencyName].state
    }
    $states
}

function Get-V2ReadyOrder {
    $readyNames = @(
        $workerRecords |
            Where-Object { $_.state -eq "ready" } |
            ForEach-Object { $_.name }
    )
    @(Get-DeterministicReadyOrder -Names $readyNames)
}

function Set-V2TaskReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$ReadyAt
    )

    $record = $workerRecordByName[$TaskName]
    if ($record.state -ne "pending") {
        return
    }
    $record.state = "ready"
    $record.ready_at = $ReadyAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
    $record.blocked_by = [string[]]@()
    $record.dependency_states = Get-V2DependencyStates -TaskName $TaskName
}

function Mark-V2SkippedDescendants {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FailedTaskName,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$SkippedAt
    )

    foreach ($dependentName in @($dependentsByName[$FailedTaskName] | Sort-Object)) {
        $record = $workerRecordByName[$dependentName]
        if ($record.state -in @("completed", "failed", "skipped", "running")) {
            continue
        }
        $record.state = "skipped"
        $record.completed_at = $SkippedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
        $record.duration_seconds = $null
        $record.queue_wait_seconds = $null
        $record.exit_code = $null
        $record.error = $null
        $record.skip_reason = $Reason
        $record.dependency_states = Get-V2DependencyStates -TaskName $dependentName
        $record.blocked_by = [string[]]@(
            @($record.depends_on) |
                Where-Object {
                    $workerRecordByName[$_].state -in @("failed", "skipped")
                }
        )
        $resultsByName[$dependentName] = New-WorkerResult `
            -Record $record `
            -ExitCode $null `
            -LastMessage "" `
            -ErrorMessage ""
        Mark-V2SkippedDescendants `
            -FailedTaskName $dependentName `
            -Reason "Skipped because dependency '$dependentName' was skipped." `
            -SkippedAt $SkippedAt
    }
}

function Get-WorkerJobOutcome {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Entry
    )

    $currentJob = Get-Job -Id ([int]$Entry.job.Id) -ErrorAction SilentlyContinue
    if ($null -ne $currentJob) {
        $Entry.job = $currentJob
    }
    $receiveError = $null
    $received = @()
    try {
        $received = @($Entry.job | Receive-Job -ErrorAction Stop)
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
    if ($Entry.job.State -ne "Completed") {
        $failureMessage = "Thread job ended in state '$($Entry.job.State)'."
        $reason = $Entry.job.JobStateInfo.Reason
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
    [pscustomobject]@{
        exit_code = $exitCode
        last_message = $lastMessage
        error = $failureMessage
        success = ($exitCode -eq 0 -and $null -eq $failureMessage)
    }
}

function Start-V2Task {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [ref]$AllJobs,
        [Parameter(Mandatory = $true)]
        [ref]$PeakActiveWorkers
    )

    $task = $taskByName[$TaskName]
    $record = $workerRecordByName[$TaskName]
    $startedAt = [DateTimeOffset]::UtcNow
    $record.started_at = $startedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
    if ($null -ne $record.ready_at) {
        $record.queue_wait_seconds = Get-DurationSeconds `
            -Start ([DateTimeOffset]$record.ready_at) `
            -End $startedAt
    } else {
        $record.queue_wait_seconds = 0.0
    }
    $record.blocked_by = [string[]]@()
    $record.dependency_states = Get-V2DependencyStates -TaskName $TaskName
    $assignmentContract = [ordered]@{
        working_directory = $task.working_directory
        review_only = $task.review_only
        owned_paths = [string[]]$task.owned_paths
        depends_on = [string[]]$task.depends_on
        predecessor_task_names = [string[]]$task.depends_on
        dependency_handoff = "Read only frozen artifacts/contracts from the predecessor task names; no raw predecessor output injection."
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
        [string]$assignmentContract,
        $CodexExecutable
    )
    $record.state = "running"
    $jobEntriesById[[int]$job.Id] = [pscustomobject]@{
        job = $job
        record = $record
        started_at = $startedAt
    }
    $AllJobs.Value += $job
    if ($jobEntriesById.Count -gt $PeakActiveWorkers.Value) {
        $PeakActiveWorkers.Value = $jobEntriesById.Count
    }
}

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
    if (-not $isSchemaV2) {
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
                predecessor_task_names = [string[]]$task.depends_on
                dependency_handoff = "Read only frozen artifacts/contracts from the predecessor task names; no raw predecessor output injection."
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
                [string]$assignmentContract,
                $CodexExecutable
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
    } else {
        $v2BarrierBatchIds = [System.Collections.Generic.HashSet[int]]::new()
        $v2CompletedCount = 0
        $v2BatchOpen = $false
        Write-RunStatus -RunState "running"

        while ($true) {
            $v2NonTerminal = @(
                $workerRecords |
                    Where-Object { $_.state -in @("pending", "ready", "running") }
            )
            if ($v2NonTerminal.Count -eq 0) {
                break
            }

            if ($schedulerMode -eq "rolling-dag-v1") {
                while ($jobEntriesById.Count -lt $concurrencyLimit) {
                    $readyOrder = @(Get-V2ReadyOrder)
                    if ($readyOrder.Count -eq 0) {
                        break
                    }
                    $nextTaskName = $readyOrder[0]
                    try {
                        Start-V2Task `
                            -TaskName $nextTaskName `
                            -AllJobs ([ref]$allJobs) `
                            -PeakActiveWorkers ([ref]$peakActiveWorkers)
                    } catch {
                        $record = $workerRecordByName[$nextTaskName]
                        $failedAt = [DateTimeOffset]::UtcNow
                        $record.state = "failed"
                        $record.completed_at = $failedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
                        $record.duration_seconds = if ($null -ne $record.started_at) {
                            Get-DurationSeconds -Start ([DateTimeOffset]$record.started_at) -End $failedAt
                        } else {
                            0.0
                        }
                        $record.exit_code = 1
                        $record.error = $_.Exception.Message
                        $record.dependency_states = Get-V2DependencyStates -TaskName $nextTaskName
                        $resultsByName[$nextTaskName] = New-WorkerResult `
                            -Record $record `
                            -ExitCode 1 `
                            -LastMessage "" `
                            -ErrorMessage $record.error
                        Mark-V2SkippedDescendants `
                            -FailedTaskName $nextTaskName `
                            -Reason "Skipped because dependency '$nextTaskName' failed to start." `
                            -SkippedAt $failedAt
                    }
                    Write-RunStatus -RunState "running"
                }
            } elseif (-not $v2BatchOpen -and $jobEntriesById.Count -eq 0) {
                $batchOrder = @(Get-V2ReadyOrder | Select-Object -First $concurrencyLimit)
                if ($batchOrder.Count -eq 0) {
                    throw "The v2 DAG scheduler has pending work but no ready task."
                }
                $v2BatchOpen = $true
                foreach ($batchTaskName in $batchOrder) {
                    try {
                        Start-V2Task `
                            -TaskName $batchTaskName `
                            -AllJobs ([ref]$allJobs) `
                            -PeakActiveWorkers ([ref]$peakActiveWorkers)
                        $startedJobIds = @(
                            $jobEntriesById.Keys |
                                Where-Object { $jobEntriesById[$_].record.name -eq $batchTaskName }
                        )
                        if ($startedJobIds.Count -gt 0) {
                            [void]$v2BarrierBatchIds.Add([int]$startedJobIds[-1])
                        }
                    } catch {
                        $record = $workerRecordByName[$batchTaskName]
                        $failedAt = [DateTimeOffset]::UtcNow
                        $record.state = "failed"
                        $record.completed_at = $failedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
                        $record.duration_seconds = if ($null -ne $record.started_at) {
                            Get-DurationSeconds -Start ([DateTimeOffset]$record.started_at) -End $failedAt
                        } else {
                            0.0
                        }
                        $record.exit_code = 1
                        $record.error = $_.Exception.Message
                        $record.dependency_states = Get-V2DependencyStates -TaskName $batchTaskName
                        $resultsByName[$batchTaskName] = New-WorkerResult `
                            -Record $record `
                            -ExitCode 1 `
                            -LastMessage "" `
                            -ErrorMessage $record.error
                        Mark-V2SkippedDescendants `
                            -FailedTaskName $batchTaskName `
                            -Reason "Skipped because dependency '$batchTaskName' failed to start." `
                            -SkippedAt $failedAt
                    }
                    Write-RunStatus -RunState "running"
                }
                if ($v2BarrierBatchIds.Count -eq 0) {
                    $v2BatchOpen = $false
                }
            }

            $completedEntries = @()
            foreach ($entry in @($jobEntriesById.Values)) {
                $currentJob = Get-Job -Id ([int]$entry.job.Id) -ErrorAction SilentlyContinue
                if ($null -ne $currentJob) {
                    $entry.job = $currentJob
                }
                if ($entry.job.State -in $terminalJobStates) {
                    if ($schedulerMode -eq "rolling-dag-v1" -or
                        $v2BarrierBatchIds.Contains([int]$entry.job.Id)) {
                        $completedEntries += $entry
                    }
                }
            }
            $completedEntries = @(
                $completedEntries |
                    Sort-Object -Property @{ Expression = { [string]$_.record.name } }
            )

            if ($completedEntries.Count -eq 0) {
                Write-RunStatus -RunState "running"
                Start-Sleep -Milliseconds 100
                continue
            }

            foreach ($entry in $completedEntries) {
                $record = $entry.record
                $completedAt = [DateTimeOffset]::UtcNow
                $record.completed_at = $completedAt.ToString("O", [System.Globalization.CultureInfo]::InvariantCulture)
                $record.duration_seconds = Get-DurationSeconds -Start $entry.started_at -End $completedAt
                $outcome = Get-WorkerJobOutcome -Entry $entry
                $record.exit_code = $outcome.exit_code
                $record.error = $outcome.error
                $record.state = if ($outcome.success) { "completed" } else { "failed" }
                $record.dependency_states = Get-V2DependencyStates -TaskName $record.name
                $resultsByName[$record.name] = New-WorkerResult `
                    -Record $record `
                    -ExitCode $outcome.exit_code `
                    -LastMessage $outcome.last_message `
                    -ErrorMessage ([string]$outcome.error)
                [void]$jobEntriesById.Remove([int]$entry.job.Id)
                if ($v2BarrierBatchIds.Contains([int]$entry.job.Id)) {
                    [void]$v2BarrierBatchIds.Remove([int]$entry.job.Id)
                }
                if ($outcome.success) {
                    $v2CompletedCount++
                    foreach ($dependentName in @($dependentsByName[$record.name])) {
                        $dependentRecord = $workerRecordByName[$dependentName]
                        $dependentRecord.dependency_states = Get-V2DependencyStates -TaskName $dependentName
                        $dependentRecord.blocked_by = [string[]]@(
                            @($dependentRecord.depends_on) |
                                Where-Object {
                                    $workerRecordByName[$_].state -notin @("completed")
                                }
                        )
                        if ($dependentRecord.state -eq "pending" -and
                            @($dependentRecord.depends_on | Where-Object {
                                $workerRecordByName[$_].state -ne "completed"
                            }).Count -eq 0) {
                            Set-V2TaskReady -TaskName $dependentName -ReadyAt $completedAt
                        }
                    }
                } else {
                    Mark-V2SkippedDescendants `
                        -FailedTaskName $record.name `
                        -Reason "Skipped because dependency '$($record.name)' failed." `
                        -SkippedAt $completedAt
                }
                Write-RunStatus -RunState "running"
            }

            if ($schedulerMode -eq "barrier-dag-v1" -and $v2BarrierBatchIds.Count -eq 0) {
                $v2BatchOpen = $false
            }
        }
    }
} finally {
    foreach ($job in @($allJobs)) {
        if ($null -ne $job) {
            Remove-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
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

if ($isSchemaV2) {
    foreach ($resultName in $resultsByName.Keys) {
        $resultsByName[$resultName].initial_ready_count = $initialReadyCount
        $resultsByName[$resultName].peak_active_workers = $peakActiveWorkers
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
$capacityDenominator = if ($isSchemaV2) { $concurrencyLimit } else { $workerRecords.Count }
$actualCapacityUtilization = if ($wallDurationSeconds -gt 0 -and $capacityDenominator -gt 0) {
    [Math]::Round(
        $summedWorkerDurationSeconds / ($capacityDenominator * $wallDurationSeconds),
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
        ($capacityDenominator * $wallDurationSeconds) - $summedWorkerDurationSeconds
    ),
    3
)
$queueWaitValues = @(
    $workerRecords |
        Where-Object { $null -ne $_.queue_wait_seconds } |
        ForEach-Object { [double]$_.queue_wait_seconds }
)
$totalQueueWaitSeconds = if ($queueWaitValues.Count -gt 0) {
    [Math]::Round(([double]($queueWaitValues | Measure-Object -Sum).Sum), 3)
} else {
    0.0
}
$maximumQueueWaitSeconds = if ($queueWaitValues.Count -gt 0) {
    [Math]::Round(([double]($queueWaitValues | Measure-Object -Maximum).Maximum), 3)
} else {
    0.0
}
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
$workerSkips = @($workerRecords | Where-Object { $_.state -eq "skipped" })
$finalStatus = if ($workerFailures.Count -gt 0 -or $workerSkips.Count -gt 0) {
    "failed"
} else {
    "completed"
}
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
        $summaryWorker = [ordered]@{
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
        if ($isSchemaV2) {
            $summaryWorker["scheduler_mode"] = $_.scheduler_mode
            $summaryWorker["concurrency_limit"] = $_.concurrency_limit
            $summaryWorker["task_count"] = $_.task_count
            $summaryWorker["ready_at"] = $_.ready_at
            $summaryWorker["queue_wait_seconds"] = $_.queue_wait_seconds
            $summaryWorker["critical_path_seconds"] = $_.critical_path_seconds
            $summaryWorker["blocked_by"] = [string[]]$_.blocked_by
            $summaryWorker["dependency_states"] = $_.dependency_states
            $summaryWorker["skip_reason"] = $_.skip_reason
        }
        $summaryWorker
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
if ($isSchemaV2) {
    $runSummary["scheduler_mode"] = $schedulerMode
    $runSummary["concurrency_limit"] = $concurrencyLimit
    $runSummary["task_count"] = $taskCount
    $runSummary["initial_ready_count"] = $initialReadyCount
    $runSummary["critical_path"] = [string[]]$criticalPathTaskNames
    $runSummary["critical_path_seconds"] = $criticalPathSeconds
    $runSummary["peak_active_workers"] = $peakActiveWorkers
    $runSummary["utilization_capacity_denominator"] = $concurrencyLimit
    $runSummary["total_queue_wait_seconds"] = $totalQueueWaitSeconds
    $runSummary["maximum_queue_wait_seconds"] = $maximumQueueWaitSeconds
    $stateCounts = [ordered]@{
        pending = @($workerRecords | Where-Object { $_.state -eq "pending" }).Count
        ready = @($workerRecords | Where-Object { $_.state -eq "ready" }).Count
        running = @($workerRecords | Where-Object { $_.state -eq "running" }).Count
        completed = @($workerRecords | Where-Object { $_.state -eq "completed" }).Count
        failed = @($workerRecords | Where-Object { $_.state -eq "failed" }).Count
        skipped = @($workerRecords | Where-Object { $_.state -eq "skipped" }).Count
    }
    $runSummary["state_counts"] = $stateCounts
    $runSummary["completed_count"] = $stateCounts.completed
    $runSummary["failed_count"] = $stateCounts.failed
    $runSummary["skipped_count"] = $stateCounts.skipped
}
Write-AtomicJson -Path $runSummaryPath -Value $runSummary -Depth 10
if ($isSchemaV2) {
    foreach ($normalizedTask in $normalizedTasks) {
        $record = $workerRecordByName[$normalizedTask.name]
        $normalizedTask["state"] = $record.state
        $normalizedTask["ready_at"] = $record.ready_at
        $normalizedTask["started_at"] = $record.started_at
        $normalizedTask["completed_at"] = $record.completed_at
        $normalizedTask["queue_wait_seconds"] = $record.queue_wait_seconds
        $normalizedTask["blocked_by"] = [string[]]$record.blocked_by
        $normalizedTask["dependency_states"] = $record.dependency_states
        $normalizedTask["skip_reason"] = $record.skip_reason
    }
    $finalManifestDocument = [ordered]@{
        schema_version = 2
        scheduler_mode = $schedulerMode
        concurrency_limit = $concurrencyLimit
        task_count = $taskCount
        initial_ready_count = $initialReadyCount
        critical_path = [string[]]$criticalPathTaskNames
        critical_path_seconds = $criticalPathSeconds
        peak_active_workers = $peakActiveWorkers
        plan = $normalizedPlan
        plan_warnings = [string[]]$planWarnings
        workers = [object[]]$normalizedTasks
    }
    Write-AtomicJson -Path $runManifestPath -Value $finalManifestDocument -Depth 15
}
Write-RunStatus -RunState $finalStatus

# Preserve the original synchronous stdout contract: the result is still the
# JSON array/object of worker result records, with observability fields added.
$resultsJson
if ($workerFailures.Count -gt 0) {
    exit 1
}
