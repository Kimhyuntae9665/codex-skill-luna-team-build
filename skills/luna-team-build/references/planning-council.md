# Planning Council

Run this compact decision process after root reconnaissance and before creating
the structured manifest. The five views are planning lenses inside Sol, not five
full `$council` subagents. A full `$council` is reserved for an explicit user
invocation or a separately documented high-risk gate. Compare k=0 root-only Sol
work with positive scheduler options. The goal is minimum verified end-to-end
time, not maximum worker count.

When a comparable prior run summary exists, use its observed slowest-worker
time, utilization, balance, and start skew to calibrate the next estimates.
Treat the first run on a new task class as uncertain and include conservative
startup and coordination cost rather than assuming perfect scaling.

## Five mandatory views

1. **Strategist**: map deliverables, dependency DAG, critical path, shared
   contracts, and the root-only serial tail.
2. **Skeptic**: challenge independence, ownership, estimates, test duplication,
   semantic races, and whether another worker would create rework.
3. **Creative**: find safer module seams, alternative bundles, fixtures, stubs,
   or contract freezes that can shorten the straggler without shared writes.
4. **Operator**: assign exact paths, symbols, acceptance criteria, scoped checks,
   handoffs, waves, and root work during the worker stage.
5. **Audience Advocate**: ensure the plan still delivers the user's actual
   outcome and does not trade clarity or verification for a higher overlap score.

Keep each view to one or two decision-relevant points. Sol synthesizes one plan;
do not average the views mechanically.

## Scheduling method

1. Freeze every cross-worker API, DOM, schema, cache, CLI, or file-format
   contract that can be decided before implementation, plus unique task IDs and
   named handoff artifacts/contracts.
2. Break the request into atomic work items with `write paths`, `read inputs`,
   `depends_on`, `estimated_seconds`, deliverables, and verification. Keep all
   task and ownership edges static for the run.
3. Mark items ready only when every dependency and input contract is satisfied.
4. Choose the scheduler automatically:
   - Choose schema v1 for one independent ready wave. It is the default and
     rejects non-empty dependencies.
   - Choose schema v2 with `plan.scheduler_mode: rolling-dag-v1` only when a
     frozen static DAG has queued work likely to unlock while a straggler is
     active.
   - Choose schema v2 with `plan.scheduler_mode: barrier-dag-v1` only for an
     A/B benchmark or an explicitly documented compatibility investigation.
   - Require v2 `plan.concurrency_limit`; it is the simultaneous-active cap, not
     the total selected task count. Do not ask the user to tune these fields.
5. Evaluate k=0 with no worker bundle. Compare it with every positive candidate
   through the selected-task limit (0..7). For v1, k is the single-wave task
   count. For v2, k is the total selected task/session count and the cap is a
   separate field. Use critical-path-first ordering for ready work.
6. For rolling v2, admit a successor immediately on a predecessor's terminal
   success event. For barrier v2, hold newly eligible work until the current
   barrier drains. A predecessor failure skips its descendants; unrelated
   branches continue.
7. Estimate:

   ```text
   predicted elapsed(k) =
     largest worker bundle
     + worker-count coordination cost
     + root work not hidden behind workers
     + expected integration and verification
   ```

   For k=0, set predicted worker wall and coordination to zero; place all task
   work in root serial plus integration and verification.
8. Choose the smallest `k` from zero through the positive selected-task limit
   with the lowest credible predicted elapsed time. Select k=0 when Luna
   startup, handoff, and integration cost erase delegation benefit. Prefer the
   smaller count when estimates are effectively tied.
9. Name the predicted bottleneck. Reduce or split it only through globally
   disjoint file ownership and a stable contract seam. The root retains combined
   verification ownership.

The scheduler revision explicitly excludes dynamic replanning, runtime-created
tasks, retries, speculative writes, checkpoint/resume, and cancellation
semantics. Do not use a planning note to imply support for any of them.

## Gates

Fail a positive schedule when write paths overlap, a dependency is unresolved,
a contract is still being produced by another task, acceptance is missing, or
root verification has no owner. For v1 this also means every selected task must
be in the same independent ready wave. For v2 only initially ready tasks may
have empty `depends_on`; all other edges must refer to the frozen task list.

Warn and rebalance positive schedules when:

- predicted `max / median > 1.5`;
- predicted capacity utilization below `0.70` using v1
  `sum / (worker_count * max)` or v2
  `sum / (concurrency_limit * predicted DAG wall)`;
- a worker/task exists only for dependent tests, documentation, or cosmetic
  filler;
- multiple workers repeat the same broad scan or full test suite;
- the root would remain idle while safe integration preparation is available.

For k=0, require no worker wave, no Luna launch, and root-owned paths that cover
the complete task. Treat zero as a planning result, not a worker process.

Warnings are diagnostic, not targets to game. Removing useful work from a fast
worker does not shorten the critical path. Move only ready, valuable work off
the predicted straggler.

## Council output

Return a Plan Card with the goal, frozen contracts, work-item DAG, automatic
schema/mode choice, `concurrency_limit` when v2, k=0 plus positive candidate
counts, selected count and reason, expected bottleneck, initial-ready count,
critical path, ready-task cards, later DAG items, named handoff artifacts,
root overlap work, and final combined verification.

Record these exact structured plan fields for runner validation:

- `council_used: true` and non-empty `council_notes` for `strategist`,
  `skeptic`, `creative`, `operator`, and `audience_advocate`;
- `ready_track_count` as the number of available initial ready tracks for the
  plan, `selected_worker_count` as the total selected task/session count equal
  to the number of selected worker/task entries (zero through seven), and
  `planning_seconds_estimate`;
- one `candidate_schedules` entry for `worker_count: 0` and one for every
  positive count through `selected_worker_count` in v2 (through
  `ready_track_count` in v1), each with
  `predicted_worker_wall_seconds`, `coordination_seconds`,
  `root_serial_seconds`, and `integration_verification_seconds`;
- `workers: []` and `root_tasks_during_workers: []` when k=0; otherwise one
  positive v1 ready wave whose workers all have `depends_on: []`, or one frozen
  v2 DAG whose initial ready tasks have `depends_on: []`;
- exact absolute `root_owned_paths`.

The run artifacts should also expose `task_count` (equal to
`selected_worker_count`), `concurrency_limit`, computed `initial_ready_count`,
`critical_path`, `peak_active_workers`, `queue_wait_seconds`, skipped and
failure states, predicted versus actual wall, utilization, and idle-slot
seconds. A v2 cap must never be reported as the task count.

For the k=0 candidate, set `predicted_worker_wall_seconds: 0` and
`coordination_seconds: 0`; make root serial work plus integration and
verification contain the complete task. Validate that manifest with
`-ValidateOnly` only, then have Sol complete and verify the task directly.

The selected candidate must minimize the sum of planning, worker-wall,
coordination, uncovered root-serial, and integration/verification time. For a
positive v1 candidate, worker-wall time must equal the largest
`estimated_seconds` among its independent ready-wave cards. For v2, predicted
wall must account for the frozen DAG, critical path, queued work, and
`concurrency_limit`; do not use the cap as the task count. For k=0, worker-wall
and coordination are zero. Treat an exact tie as a reason to choose the smaller
count.

Run these five planning lenses in Sol by default. Use separate Luna planning
advisors only when the documented high-risk gate justifies their latency, and
include that cost in the decision; do not launch them merely to fill the role
count.
