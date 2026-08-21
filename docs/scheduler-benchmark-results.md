# Scheduler Benchmark Results

측정일은 2026-08-21 KST입니다. 두 비교 모두 같은 DAG와 동시성 상한 2를
사용했습니다. 초기 ready task는 `long-a`, `short-b`이고 `dependent-c`는
`short-b` 성공에 의존합니다. correctness, dependency ordering, handoff,
`peak_active_workers <= 2`를 먼저 통과한 run만 아래 요약에 포함했으며,
실패 run을 조용히 제거하지 않았습니다.

## Deterministic fake-Codex paired fixture

명령:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\benchmark-scheduler.ps1 -Trials 5 -Warmups 1 -KeepArtifacts
```

고정 지연은 `long-a=1200ms`, `short-b=200ms`,
`dependent-c=800ms`였습니다. warm-up은 모드별 1회 제외했고, 측정 순서를
barrier-first와 rolling-first로 교차했습니다. 10개 측정 run은 모두
correctness gate를 통과했습니다.

| mode | measured walls (s) | median (s) | p95 (s) |
|---|---|---:|---:|
| `barrier-dag-v1` | 4.357, 4.115, 4.309, 4.096, 4.250 | 4.250 | 4.357 |
| `rolling-dag-v1` | 3.211, 3.213, 3.157, 3.440, 3.331 | 3.213 | 3.440 |

rolling median은 barrier보다 1.037초, 24.400% 짧았습니다. 로컬 artifact
식별자는 `luna-scheduler-benchmark-a1bad4b12fc14e3b9a7801da132e6799`입니다.
이 fixture는 scheduler 상태기계만 격리하므로 live model latency, token,
throttling, cache, model drift, 또는 integration rework를 측정하지 않습니다.

## Live GPT-5.6 Luna paired diagnostic

세 task 모두 `gpt-5.6-luna`, max reasoning, Fast service tier,
`danger-full-access`, `approval_policy=never`, disabled nested delegation으로
실행했습니다. 두 모드는 동일한 prompt, estimates, dependency, cap, 작업
디렉터리를 사용했습니다. `long-a`는 PowerShell 25초 wait, 나머지 두 task는
각 1초 wait 후 exact literal handoff를 반환했습니다.

| metric | `barrier-dag-v1` | `rolling-dag-v1` | difference |
|---|---:|---:|---:|
| wall seconds | 53.252 | 38.764 | -14.488 (-27.206%) |
| actual capacity utilization | 0.669 | 0.859 | +0.190 |
| idle-slot seconds | 35.305 | 10.914 | -24.391 |
| peak active workers | 2 | 2 | 0 |
| completed / failed / skipped | 3 / 0 / 0 | 3 / 0 / 0 | same |

rolling에서 `short-b` 완료 후 0.030초 뒤 `dependent-c`가 시작됐고, 이때
`long-a`는 약 23.3초 더 실행 중이었습니다. 두 run 모두 `LONG_A_DONE`,
`SHORT_B_DONE`, `DEPENDENT_C_DONE`을 정확히 반환했습니다.

Live summary provenance:

| mode | bytes | SHA-256 |
|---|---:|---|
| barrier | 9,170 | `0AFD9A50367FEFCE86B84FC234076AF6D7D4EDA58747EF735ACEC6C7F76CC901` |
| rolling | 9,065 | `3E67CCC7E95658D01C16CE3B7CAC85F764A2A750D64BCF084D5AFCC530983866` |

로컬 artifact 식별자는
`luna-scheduler-live-paired-d137bf98536945ed83205b87eb707e08`입니다. 이 live
비교는 1 pair이며 barrier를 먼저 실행했습니다. 따라서 27.206%를 일반적인
속도 보장으로 해석하면 안 됩니다. 같은 대표 workload를 여러 날 반복하고
token/rate-limit/rework까지 수집해야 배포 성능 결론을 강화할 수 있습니다.

참고로 수정 전 v1에서 같은 세 prompt를 두 ready wave로 실행한 진단 합계는
54.132초였습니다. 별도 wave 사이의 root 대기시간은 제외한 값이며, 새 live
pair 계산에는 넣지 않았습니다.
