# Schema v2 Static DAG Contract

Read this reference only after the Planning Council selects schema v2. The DAG,
task IDs, dependency edges, ownership, contracts, and handoff artifact names are
frozen before launch.

## Required semantics

- `selected_worker_count` equals `workers.Count` and is the total selected task
  session count, from 1 through 7.
- `ready_track_count` equals the computed number of tasks whose `depends_on` is
  empty at launch. It may be smaller than `selected_worker_count`.
- `concurrency_limit` is an integer from 1 through
  `min(selected_worker_count, 7)` and is the only simultaneous-active cap.
- `candidate_schedules` covers every worker count from 0 through
  `selected_worker_count`. The selected candidate has the lowest predicted
  total, and its worker wall equals the runner's deterministic DAG simulation.
- Dependencies must name another selected task. Missing, duplicate, self, and
  cyclic edges fail validation. All worker/worker and root/worker write paths
  remain globally disjoint even when tasks are sequential.
- `rolling-dag-v1` fills each freed slot immediately from the critical-path-first
  ready queue. `barrier-dag-v1` waits for the current batch to drain.
- A predecessor succeeds only after its worker exits successfully. Its
  descendants become `skipped` on failure; unrelated branches continue.

No dynamic DAG changes, retry, speculative write, checkpoint/resume, or
cancellation behavior is defined.

## Complete-shape example

The example abbreviates only repeated prompt prose. Replace every absolute path
and retain all shown fields in a real manifest.

```json
{
  "schema_version": 2,
  "plan": {
    "council_used": true,
    "goal": "Build and verify the API/UI integration",
    "selection_reason": "Rolling can admit a successor while the API branch remains active.",
    "expected_bottleneck": "spec -> api -> integration",
    "contracts_ready": true,
    "council_notes": {
      "strategist": "The four-task DAG is frozen.",
      "skeptic": "Dependencies and write paths are valid.",
      "creative": "Rolling removes avoidable barrier wait.",
      "operator": "Every task has scoped checks.",
      "audience_advocate": "Sol returns one combined verified result."
    },
    "ready_track_count": 1,
    "selected_worker_count": 4,
    "planning_seconds_estimate": 20,
    "candidate_schedules": [
      {"worker_count": 0, "predicted_worker_wall_seconds": 0, "coordination_seconds": 0, "root_serial_seconds": 1500, "integration_verification_seconds": 180},
      {"worker_count": 1, "predicted_worker_wall_seconds": 1200, "coordination_seconds": 0, "root_serial_seconds": 200, "integration_verification_seconds": 160},
      {"worker_count": 2, "predicted_worker_wall_seconds": 900, "coordination_seconds": 30, "root_serial_seconds": 100, "integration_verification_seconds": 160},
      {"worker_count": 3, "predicted_worker_wall_seconds": 760, "coordination_seconds": 45, "root_serial_seconds": 80, "integration_verification_seconds": 170},
      {"worker_count": 4, "predicted_worker_wall_seconds": 650, "coordination_seconds": 60, "root_serial_seconds": 60, "integration_verification_seconds": 180}
    ],
    "root_tasks_during_workers": ["Prepare combined checks without touching task paths"],
    "root_owned_paths": ["C:\\absolute\\project\\root-checks"],
    "scheduler_mode": "rolling-dag-v1",
    "concurrency_limit": 2
  },
  "workers": [
    {
      "name": "spec",
      "working_directory": "C:\\absolute\\project",
      "sandbox_mode": "danger-full-access",
      "review_only": false,
      "owned_paths": ["contracts/api.json"],
      "depends_on": [],
      "estimated_seconds": 100,
      "contract_ids": ["api-v2"],
      "acceptance": ["The frozen contract is complete"],
      "verification": ["python scripts/validate_contract.py"],
      "prompt": "Create only the frozen contract artifact."
    },
    {
      "name": "api",
      "working_directory": "C:\\absolute\\project",
      "sandbox_mode": "danger-full-access",
      "review_only": false,
      "owned_paths": ["server.py"],
      "depends_on": ["spec"],
      "estimated_seconds": 400,
      "contract_ids": ["api-v2"],
      "acceptance": ["The server implements the frozen contract"],
      "verification": ["python -m unittest tests.test_server"],
      "prompt": "Read the spec artifact and implement only server.py."
    },
    {
      "name": "ui",
      "working_directory": "C:\\absolute\\project",
      "sandbox_mode": "danger-full-access",
      "review_only": false,
      "owned_paths": ["web"],
      "depends_on": ["spec"],
      "estimated_seconds": 250,
      "contract_ids": ["api-v2"],
      "acceptance": ["The UI consumes the frozen contract"],
      "verification": ["npm test -- ui"],
      "prompt": "Read the spec artifact and edit only web."
    },
    {
      "name": "integration",
      "working_directory": "C:\\absolute\\project",
      "sandbox_mode": "danger-full-access",
      "review_only": false,
      "owned_paths": ["tests/integration"],
      "depends_on": ["api", "ui"],
      "estimated_seconds": 150,
      "contract_ids": ["api-v2"],
      "acceptance": ["The API/UI contract passes integration checks"],
      "verification": ["python -m unittest tests.integration"],
      "prompt": "Verify the completed API and UI artifacts."
    }
  ]
}
```

Persist `task_count`, `concurrency_limit`, `initial_ready_count`, ordered
`critical_path` plus seconds, `peak_active_workers`, queue-wait aggregates,
completed/failed/skipped counts, cap-based utilization, idle-slot seconds, and
per-task terminal state. Compare
`predicted_schedule.predicted_worker_wall_seconds` with measured
`wall_duration_seconds`; never call the estimate a speed result.
