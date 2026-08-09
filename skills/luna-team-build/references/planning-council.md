# Planning Council

Run this compact decision process after root reconnaissance and before creating
the structured manifest. Compare k=0 root-only Sol work with positive ready-wave
options. The goal is minimum verified end-to-end time, not maximum worker count.

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
   contract that can be decided before implementation.
2. Break the request into atomic work items with `write paths`, `read inputs`,
   `depends_on`, `estimated_seconds`, deliverables, and verification.
3. Mark items ready only when every dependency and input contract is satisfied.
4. Evaluate k=0 with no worker bundle. Compare it with each positive candidate
   `k=1..min(7, ready tracks)`, assigning the longest ready item to the currently
   lightest bundle (LPT approximation).
5. Estimate:

   ```text
   predicted elapsed(k) =
     largest worker bundle
     + worker-count coordination cost
     + root work not hidden behind workers
     + expected integration and verification
   ```

   For k=0, set predicted worker wall and coordination to zero; place all task
   work in root serial plus integration and verification.
6. Choose the smallest `k` from zero through the positive ready-track limit with
   the lowest credible predicted elapsed time. Select k=0 when Luna startup,
   handoff, and integration cost erase delegation benefit. Prefer the smaller
   count when estimates are effectively tied.
7. Name the predicted bottleneck. Reduce or split it only through disjoint file
   ownership and a stable contract seam.

## Gates

Fail a positive ready wave when write paths overlap, a dependency is unresolved,
a contract is still being produced by another same-wave worker, acceptance is
missing, or root verification has no owner.

Warn and rebalance positive waves when:

- predicted `max / median > 1.5`;
- predicted `sum / (worker_count * max) < 0.70`;
- a worker exists only for dependent tests, documentation, or cosmetic filler;
- multiple workers repeat the same broad scan or full test suite;
- the root would remain idle while safe integration preparation is available.

For k=0, require no worker wave, no Luna launch, and root-owned paths that cover
the complete task. Treat zero as a planning result, not a worker process.

Warnings are diagnostic, not targets to game. Removing useful work from a fast
worker does not shorten the critical path. Move only ready, valuable work off
the predicted straggler.

## Council output

Return a Plan Card with the goal, frozen contracts, work-item DAG, k=0 plus
positive candidate counts, selected count and reason, expected bottleneck,
ready-wave worker cards when k is positive, later-wave items, root overlap work,
and final combined verification.

Record these exact structured plan fields for runner validation:

- `council_used: true` and non-empty `council_notes` for `strategist`,
  `skeptic`, `creative`, `operator`, and `audience_advocate`;
- `ready_track_count` as the number of available ready tracks, capped at seven,
  `selected_worker_count` from zero through that limit, and
  `planning_seconds_estimate`;
- one `candidate_schedules` entry for `worker_count: 0` and one for every
  positive count through `min(7, ready_track_count)`, each with
  `predicted_worker_wall_seconds`, `coordination_seconds`,
  `root_serial_seconds`, and `integration_verification_seconds`;
- `workers: []` and `root_tasks_during_workers: []` when k=0; otherwise one
  positive ready wave whose workers all have `depends_on: []`;
- exact absolute `root_owned_paths`.

For the k=0 candidate, set `predicted_worker_wall_seconds: 0` and
`coordination_seconds: 0`; make root serial work plus integration and
verification contain the complete task. Validate that manifest with
`-ValidateOnly` only, then have Sol complete and verify the task directly.

The selected candidate must minimize the sum of planning, worker-wall,
coordination, uncovered root-serial, and integration/verification time. For a
positive selected candidate, worker-wall time must equal the largest
`estimated_seconds` among its ready-wave worker cards; for k=0, it must be zero.
Treat an exact tie as a reason to choose the smaller count.

Run the Council in Sol by default. Use separate Luna planning advisors only when
the planning uncertainty or risk justifies their latency, and include that cost
in the decision.
