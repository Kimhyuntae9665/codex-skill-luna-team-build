---
name: luna-team-build
description: Coordinate complex development with GPT-5.6 Sol at max reasoning as the root conductor, automatically run a compact five-role Council to compare zero to seven choices (k=0 root-only or k=1..min(7, ready tracks) ready-wave options), choose Sol-only or the lowest-time isolated GPT-5.6 Luna team at max reasoning, then integrate and verify the result. Use only when the user explicitly invokes $luna-team-build for a coding, refactoring, data, UI, or validation task.
---

# Luna Team Build

Keep the model roles invariant while choosing the smallest team with the lowest
predicted end-to-end time:

```text
GPT-5.6 Sol + max (root conductor and planning Council synthesizer)
|- k=0: Sol completes the task directly; no Luna worker process
`- k=1..7: selected GPT-5.6 Luna + max workers in one ready wave
```

The root owns reconnaissance, Council synthesis, architecture, contracts,
decomposition, worker selection, integration, final verification, and reporting.
Treat k=0 as a planning result, not a worker process. Never change the root model
to Luna to make worker creation succeed. Seven is a hard ceiling, not a target;
zero is a deliberate root-only choice, not a failed launch.

Every launched worker has this fixed effective runtime contract:

- model `gpt-5.6-luna`;
- reasoning effort `max`;
- service tier `fast`;
- approval policy `never`;
- sandbox `danger-full-access`; and
- nested multi-agent delegation disabled.

The runner accepts old sandbox values only in legacy manifests and normalizes
their effective runtime to `danger-full-access`. Every structured Council
manifest must explicitly request `danger-full-access`; a narrower declaration
is rejected instead of being silently widened. Full access is an execution
capability only; it does not expand the user's authorization or a worker's
bounded task and file scope.

## Latency Model

Parallel workers shorten elapsed time only when substantial work is ready and
independent. They do not make one worker reason faster.

```text
team elapsed time =
  planning and contract-freeze time
  + slowest ready worker track
  + uncovered root integration and final verification
  + startup, conflict, and rework overhead
```

Do not optimize `parallelism_ratio` by padding small workers with low-value work.
Optimize the user-visible critical path and verified outcome.

For k=0, set worker wall and coordination to zero. Put the complete task in root
serial work plus integration and verification, and do not launch Luna.

## Preflight

1. Read the user request, repository instructions, current Git state, and
   relevant skills before editing.
2. Confirm `~/.codex/config.toml` selects `gpt-5.6-sol` with `max` reasoning.
3. Confirm either `~/.codex/agents/luna-worker.toml` or
   `~/.codex/agents/luna_worker.toml` selects `gpt-5.6-luna` with `max`
   reasoning. On this machine the registered file may use the hyphenated name.
4. Use `scripts/run-luna-team.ps1`. In runtimes where Sol cannot directly create
   a Luna child, do not retry the unsupported cross-backend call or substitute
   Terra.
5. Perform a bounded root reconnaissance once. Give workers the discovered
   files, symbols, contracts, and commands so they do not repeat a broad scan.
6. When a comparable prior `run-summary.json` is available, calibrate estimates
   with its actual slowest-worker time, utilization, balance, and start skew.
   When no comparable history exists, state the uncertainty and budget
   conservative startup and coordination overhead.

## Run the Planning Council Automatically

Before building the structured manifest, read and follow
`references/planning-council.md`. Also load the installed `$council` skill when
available and apply its Strategist, Skeptic, Creative, Operator, and Audience
Advocate roles to worker planning.

Always run the five roles. By default, Sol performs a compact in-thread Council
so planning does not become the new bottleneck. Use separate read-only Luna
planning advisors only when decomposition itself is unusually ambiguous,
high-risk, or evidence-heavy and their expected benefit exceeds their startup
and synthesis cost. Never launch external advisors merely to satisfy the role
count. Run the roles even when k=0 wins, and keep no more than seven external
Luna sessions active at once.

The Council must produce a short Plan Card containing:

- user-visible goal and acceptance boundary;
- frozen shared contracts such as API, DOM, schema, cache, or CLI formats;
- atomic work items, dependency edges, and exact write ownership;
- estimated effort and critical-path status for each item;
- candidate schedules for `k = 0` and `k = 1..min(7, ready tracks)`;
- chosen worker count, selection reason, and expected bottleneck;
- root work that can overlap a positive worker stage or complete k=0 directly;
- worker-scoped checks and one root-owned combined verification pass.

Persist one non-empty decision note for each Council role. The runner treats
these notes as an auditable planning record; Sol remains responsible for
actually performing the reasoning rather than merely filling fields.

## Choose Zero to Seven Workers

Compare k=0 with every positive candidate through `min(7, ready tracks)`. Choose
the count from the Council Plan Card, not from the number of available slots:

- Use k=0 when Luna startup, handoff, and integration cost erase delegation
  benefit. Sol must perform and verify the whole task directly.
- Use k=1 for a short task, a dominant single file, or a tightly coupled chain.
- Use k=2 or k=3 for independently writable implementation surfaces.
- Use k=4..7 only when that many substantial tracks are ready at launch,
  contracts are frozen, write sets are disjoint, and predicted elapsed time is
  lower than a smaller-team schedule after coordination and integration costs.
- Keep dependent tests and documentation with their implementation owner or in
  a later ready wave. Never invent a worker solely to fill a slot.
- Split a straggler only across a real module or contract seam. Never assign two
  writers to one file merely to balance estimates.
- Treat predicted `max duration / median duration > 1.5` or predicted capacity
  utilization below `0.70` as a warning that requires an explicit exception or
  a smaller/rebalanced team.

For every positive selection, use one ready wave and set every worker's
`depends_on` to an empty list. Launch dependency-bound work in a later manifest
only after its inputs have terminal successful handoffs. For k=0, use no worker
wave and follow the root-only validation path below.

The runner permits only one live positive ready wave per Windows session. This
makes the seven-worker ceiling global across concurrent runner invocations, not
merely a per-manifest promise. A second live run fails fast; wait for the current
run or combine genuinely independent work into its Council plan.

## Build the Structured Manifest

Use the Council envelope for every new run, including k=0. Legacy worker arrays
remain accepted for compatibility, but use this structured plan for every
zero-to-seven choice:

```json
{
  "schema_version": 1,
  "plan": {
    "council_used": true,
    "goal": "Short measurable outcome",
    "selection_reason": "Why this worker count minimizes predicted elapsed time",
    "expected_bottleneck": "Likely critical-path track or root tail",
    "contracts_ready": true,
    "council_notes": {
      "strategist": "Two independent implementation tracks are ready.",
      "skeptic": "Write sets are disjoint and contracts are frozen.",
      "creative": "No safer split shortens the backend straggler.",
      "operator": "Each worker has exact ownership and scoped checks.",
      "audience_advocate": "The split preserves the requested verified outcome."
    },
    "ready_track_count": 2,
    "selected_worker_count": 2,
    "planning_seconds_estimate": 20,
    "candidate_schedules": [
      {
        "worker_count": 0,
        "predicted_worker_wall_seconds": 0,
        "coordination_seconds": 0,
        "root_serial_seconds": 1400,
        "integration_verification_seconds": 180
      },
      {
        "worker_count": 1,
        "predicted_worker_wall_seconds": 1050,
        "coordination_seconds": 0,
        "root_serial_seconds": 60,
        "integration_verification_seconds": 120
      },
      {
        "worker_count": 2,
        "predicted_worker_wall_seconds": 600,
        "coordination_seconds": 30,
        "root_serial_seconds": 60,
        "integration_verification_seconds": 130
      }
    ],
    "root_tasks_during_workers": ["Prepare integration checks without touching owned files"],
    "root_owned_paths": ["C:\\absolute\\project\\integration"]
  },
  "workers": [
    {
      "name": "backend",
      "working_directory": "C:\\absolute\\project",
      "sandbox_mode": "danger-full-access",
      "review_only": false,
      "owned_paths": ["server.py", "tests/test_server.py"],
      "depends_on": [],
      "estimated_seconds": 600,
      "contract_ids": ["api-v1"],
      "acceptance": ["New endpoint behavior is covered"],
      "verification": ["python -m unittest tests.test_server"],
      "prompt": "Bounded assignment with symbols, contracts, and handoff requirements."
    },
    {
      "name": "frontend",
      "working_directory": "C:\\absolute\\project",
      "sandbox_mode": "danger-full-access",
      "review_only": false,
      "owned_paths": ["web", "tests/ui"],
      "depends_on": [],
      "estimated_seconds": 450,
      "contract_ids": ["api-v1"],
      "acceptance": ["The UI consumes the frozen response contract"],
      "verification": ["npm test -- ui"],
      "prompt": "Implement only the frozen frontend contract and owned paths."
    }
  ]
}
```

For a winning k=0, keep the same envelope but set
`plan.selected_worker_count` to `0`, set `workers` to `[]`, include the k=0
candidate and every positive candidate through `min(7, ready_track_count)`, and
set k=0 `predicted_worker_wall_seconds` and `coordination_seconds` to `0`.
Assign all task work to `root_serial_seconds` plus
`integration_verification_seconds`; use `root_tasks_during_workers: []` and
list exact absolute `root_owned_paths`. The runner audits k=0 and every positive
count through `min(7, ready_track_count)`, requires the selected count to have
the lowest predicted total time (smaller count wins an exact tie), and checks
that a positive selected worker-wall estimate equals the largest selected
worker estimate. It rejects unresolved same-wave dependencies, worker/worker
ownership overlap, root/worker ownership overlap, and incomplete Council or
worker metadata. Review-only workers must set `review_only: true` and leave
`owned_paths` empty.

### Validate and Complete k=0 Without Luna

When k=0 wins, serialize the structured manifest with `workers: []` and
`selected_worker_count: 0`, then run the runner with `-ValidateOnly` only:

```powershell
$manifestJson = $manifest | ConvertTo-Json -Depth 10
& $runnerPath -ManifestJson $manifestJson -OutputDirectory $runDirectory -ValidateOnly
```

The root-only plan must retain every Council field and use this complete shape:

```json
{
  "schema_version": 1,
  "plan": {
    "council_used": true,
    "goal": "Short measurable outcome",
    "selection_reason": "Luna startup, handoff, and integration cost erase delegation benefit",
    "expected_bottleneck": "Root serial task and final verification",
    "contracts_ready": true,
    "council_notes": {
      "strategist": "The complete task is a root-owned serial path.",
      "skeptic": "Delegation overhead exceeds the benefit of the ready tracks.",
      "creative": "No disjoint split shortens the verified outcome.",
      "operator": "Sol owns the exact paths and direct verification.",
      "audience_advocate": "The root-only plan preserves the requested outcome."
    },
    "ready_track_count": 2,
    "selected_worker_count": 0,
    "planning_seconds_estimate": 20,
    "candidate_schedules": [
      {
        "worker_count": 0,
        "predicted_worker_wall_seconds": 0,
        "coordination_seconds": 0,
        "root_serial_seconds": 400,
        "integration_verification_seconds": 80
      },
      {
        "worker_count": 1,
        "predicted_worker_wall_seconds": 1050,
        "coordination_seconds": 0,
        "root_serial_seconds": 60,
        "integration_verification_seconds": 120
      },
      {
        "worker_count": 2,
        "predicted_worker_wall_seconds": 600,
        "coordination_seconds": 30,
        "root_serial_seconds": 60,
        "integration_verification_seconds": 130
      }
    ],
    "root_tasks_during_workers": [],
    "root_owned_paths": ["C:\\absolute\\project"]
  },
  "workers": []
}
```

Do not pass `-Detached` or launch any Luna session for k=0. After validation,
Sol completes the entire task directly and runs the root-owned verification.
Normal positive launches validate automatically.

Use exact paths rather than globs. Worker checks must cover owned behavior only.
Run the combined full suite once in the root after integration unless an earlier
full run is required to resolve a specific risk.

## Launch Positive k=1..7 Luna Workers

Always choose an explicit output directory. For k=2..7 workers, use
`-Detached` by default so the root can continue non-overlapping work:

```powershell
$manifestJson = $manifest | ConvertTo-Json -Depth 10
$codexHomePath = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
  Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex"
} else {
  $env:CODEX_HOME
}
$runnerPath = Join-Path $codexHomePath `
  "skills\luna-team-build\scripts\run-luna-team.ps1"
$runDirectory = Join-Path ([System.IO.Path]::GetTempPath()) `
  ("luna-team-" + [Guid]::NewGuid().ToString("N"))
$runHandle = & $runnerPath `
  -ManifestJson $manifestJson `
  -OutputDirectory $runDirectory `
  -Detached |
  ConvertFrom-Json
```

Use synchronous mode only when the root has no useful non-overlapping work or
immediate JSON results are more convenient.

For a positive selection, the launcher starts the selected positive number of
isolated `codex exec` processes, at most seven, and pins every session to the
fixed Luna runtime. It does not run for k=0. Every worker prompt must state:

- exact responsibility and owned paths or review-only status;
- shared contracts and acceptance criteria;
- that other workers share the filesystem;
- that it must preserve and adapt to concurrent edits;
- required scoped verification and concise handoff format.

For detached runs, poll `run-status.json` without blocking for long periods.
Consume terminal successful handoffs early when root integration can proceed
without reading or changing files still being written. Never integrate a
partially written owned path.

At the end of a positive run, read `run-results.json` and `run-summary.json`. The
summary includes:

- worker count, start/end times, wall duration, and slowest worker;
- summed worker time, overlap ratio, and worker-overlap seconds;
- actual capacity utilization, balance ratio, idle-slot seconds, and start skew;
- Council plan metadata, plan warnings, and predicted schedule metrics.

Compare the selected predicted worker-wall time with the actual slowest-worker
time. Feed material underestimation, overestimation, or runtime variance into
the next Council instead of assuming the same task-size model remains valid.

For k=0, retain the `-ValidateOnly` result and root verification evidence; do not
expect worker handoffs or a Luna run summary.

These workers are external isolated Codex sessions, not native child threads.
Coordinate them through the structured plan, status artifacts, terminal
handoffs, and shared filesystem.

## Coordinate and Integrate

For k=0, skip worker handoffs and integration, complete the root-owned task, and
run the required root verification directly.

1. Continue only root work listed in `root_tasks_during_workers` that does not
   overlap worker ownership.
2. Inspect each completed handoff and resulting diff; do not cherry-pick shared
   filesystem changes as though workers used separate worktrees.
3. Reconcile contract mismatches centrally and record material rework.
4. Run the proportionate combined suite once and any real-target or UI
   verification required by the user.
5. Do not broaden external writes, deployments, messages, purchases, or
   destructive actions beyond the user's authorization.

## Report the Actual Hierarchy

Lead with the completed outcome, then report:

- the Council's chosen k from zero to seven and selection reason;
- the actual conductor and every worker that ran;
- each responsibility and result;
- worker-stage wall time, slowest worker, utilization, balance, and overlap (all
  zero when k=0);
- predicted-versus-actual slowest-worker error and how it changes the next plan;
- material root-only serial work and contract rework, including the whole task
  when k=0;
- important files changed, combined verification, and limitations;
- any omitted, failed, timed-out, or later-wave worker.

Use a compact tree when it helps:

```text
GPT-5.6 Sol + max (root conductor and Council synthesizer)
|- k=0: Sol-only completion; no Luna worker process ran
`- k=1..7: each selected luna_worker (GPT-5.6 Luna + max), one ready wave
```

For k=0, state that zero is a planning result, not a worker process, and that
Sol completed and verified the task directly. For positive k, state that workers
ran as isolated Codex worker sessions rather than native `spawn_agent` children.
Never present Council roles, tools, skills, browser sessions, or data providers
as Agents unless separate worker sessions actually ran.
