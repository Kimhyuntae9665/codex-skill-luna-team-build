# 벤치마크 방법론

기준일: **2026-08-09** (Asia/Seoul)

## 목적과 범위

이 자료는 luna-team-build 런너가 실제 실행에서 기록한 wall time과 작업자별 소요 시간을 바탕으로 오케스트레이션 동작을 설명하기 위한 것입니다. [benchmark-data.csv](benchmark-data.csv)에 원본 표시 정밀도인 소수점 세 자리로 값을 보존했습니다.

네 행의 workload는 서로 다릅니다.

- one-worker token smoke
- seven-worker equal token smoke
- seven-worker varied Council audit
- one-worker architecture review

그러므로 이 자료는 apples-to-apples 속도 향상, 표준화된 throughput, 모델 간 성능 순위 또는 비용 비교가 아닙니다. 병렬 실행에서 시간이 얼마나 겹치는지, 슬롯이 얼마나 활용되는지, 작업자 길이가 얼마나 균형적인지, 시작 편차와 straggler가 어떤 영향을 주는지를 보여주는 관측 기록입니다.

## Paired scheduler benchmark protocol

`barrier-dag-v1`과 `rolling-dag-v1`을 비교할 때는 두 scheduler mode만 바꾸는
paired experiment를 사용합니다. 이 절차는 아직 실행된 결과를 기록하는 절차
이며, 아래 규칙만으로 측정값을 만들어 내거나 기존 historical rows를
재분류하지 않습니다.

1. 같은 user prompt, model/reasoning/service runtime, repository commit, clean
   workspace, frozen task DAG, task ownership, acceptance tests, and
   `concurrency_limit`을 두 조건에 고정합니다. 두 manifest의 task IDs,
   dependency edges, handoff artifact names, and root verification command도
   동일해야 하며 `plan.scheduler_mode`만 바꿉니다.
2. 각 조건에 최소 한 번의 warm-up run을 먼저 수행하고 측정값에서 제외합니다.
   그 뒤 사전에 정한 동일한 반복 횟수(권장 5회 이상)를 조건별로 수행합니다.
   같은 trial 번호의 두 run을 pair로 묶고, barrier를 항상 먼저 실행하지
   않도록 순서를 교차하거나 무작위화합니다.
3. 각 run에서 correctness를 먼저 gate합니다. task handoff, root combined
   verification, dependency ordering, ownership disjointness가 모두
   통과했는지 기록하고, 실패한 run을 조용히 제거하지 않습니다.
4. 결과는 조건별 wall의 median과 p95를 함께 보고합니다. task count,
   concurrency cap, initial-ready count, critical path, peak active workers,
   per-task/aggregate queue wait, skipped and failure states,
   predicted-versus-actual wall, utilization, idle-slot seconds, and
   dependency-order violations도 같은 표에 보존합니다.
5. token usage, rate limits, throttling, cache/warm state, model drift,
   filesystem contention, and integration rework를 별도 caveat로 기록합니다.
   이 요인으로 pair가 오염되면 결과를 단정적인 scheduler speedup으로
   해석하지 않고 해당 trial과 원인을 공개합니다.

이 protocol은 동일 DAG에서 barrier가 만드는 wait와 rolling의 event-driven
unlock 차이를 비교하기 위한 것입니다. task를 추가하거나 runtime에 DAG를
재작성하지 않으며, retries, speculative writes, checkpoint/resume,
cancellation semantics도 실험 조건에 포함하지 않습니다. 새로 측정한
결과는 새 artifact ID·hash·조건과 함께 별도 rows로 추가해야 하며, 기존
네 행을 comparable한 것처럼 수정하거나 덮어쓰지 않습니다.

결정적 scheduler-only fixture는 저장소 루트에서 다음처럼 실행합니다.

```powershell
pwsh -NoLogo -NoProfile -File .\tests\benchmark-scheduler.ps1 -Trials 5 -Warmups 1
```

이 fixture는 fake Codex의 고정 지연을 사용하므로 ready/unlock/barrier 상태기계와
median/p95 계산을 재현하는 용도입니다. live 모델 속도·token·throttling·통합
재작업을 대신 측정하지 않습니다. 실제 Luna 비교는 같은 manifest/prompt를
유지한 별도 paired trial로 보고해야 합니다.

2026-08-21에 실행한 deterministic 5-pair와 live 1-pair 진단은
[scheduler-benchmark-results.md](scheduler-benchmark-results.md)에 조건,
correctness gate, raw walls, provenance hash, 한계와 함께 기록했습니다.

## 원본 아티팩트 식별자와 무결성

측정 당시 로컬 Windows Temp에 생성된 `run-summary.json`을 직접 읽었습니다. 공개 저장소에는 사용자 환경의 절대 경로나 원본 Temp 디렉터리를 넣지 않고, 아래의 비식별 아티팩트 ID·파일 크기·SHA-256을 남깁니다. 원본을 보관한 환경에서는 이 값으로 공개 CSV가 어느 파일에서 추출됐는지 확인할 수 있습니다.

| source artifact ID | bytes | SHA-256 |
|---|---:|---|
| `luna-current-smoke-27ab345726c645629a6b261be428c319/run-summary.json` | 4,078 | `2306819451a4fbebb0e1b583625fcb3488afedd1f8d33ac89a8f03f8329c318f` |
| `luna-final-seven-smoke-6b6d60cb1e484ef88e83d58af1a89760/run-summary.json` | 11,300 | `f54c156bd96e35f6bccd315c8b7d3f0d5d7dc7e3b8555dfb6fda2e9aa812729e` |
| `luna-team-seven-forward-20260809-201502/run-summary.json` | 5,955 | `d689cd4f147b83cd1bc5109ca2eae6f3aaed940db11dc9c16faf21df014c621e` |
| `luna-skill-review-93731a7458144b6bbb079f0bfe1e6677/run-summary.json` | 4,713 | `508e8c2c1a891f45e21349afa207143d73bc97da023a47a0bdb30c86094f5e7b` |

각 JSON의 기록 필드는 다음과 같이 매핑했습니다.

| CSV 열 | run-summary.json 필드 |
|---|---|
| workers | worker_count |
| wall_seconds | wall_duration_seconds |
| summed_worker_seconds | summed_worker_duration_seconds |
| parallelism_ratio | parallelism_ratio |
| utilization | actual_capacity_utilization |
| balance_ratio | actual_balance_ratio |
| start_skew_seconds | start_skew_seconds |

## 공식과 정의

wall은 해당 run의 실제 시작 시각과 완료 시각 사이의 경과 시간입니다. summed worker는 run summary에 기록된 모든 작업자의 duration_seconds 합입니다.

schema v1에서 작업자 수를 k라고 할 때:

~~~text
parallelism_ratio = summed_worker_seconds / wall_seconds
utilization       = summed_worker_seconds / (k × wall_seconds)
balance_ratio     = min(worker_duration_seconds) / max(worker_duration_seconds)
start_skew        = latest_worker_start - earliest_worker_start
~~~

schema v2에서는 k가 전체 selected task count이므로 utilization의 capacity
분모를 `concurrency_limit × wall_seconds`로 해석합니다. 즉 task count와
동시 active slot 수를 섞어 계산하지 않습니다. 새 v2 summary는 가능하면
이 cap 기반 utilization과 `idle_slot_seconds`를 함께 보존하고, 기존 v1
historical rows의 공식을 소급 변경하지 않습니다.

작업자가 하나이면 balance_ratio는 정의상 1.000입니다. 원본 JSON은 계산 결과를 소수점 세 자리로 반올림해 기록하므로, 공개 CSV의 값을 다시 나눠 원본보다 더 높은 정밀도를 추정하지 않습니다.

## 측정값

| workload | k | wall | summed worker | parallelism | utilization | balance | start skew |
|---|---:|---:|---:|---:|---:|---:|---:|
| one-worker token smoke | 1 | 8.513 | 8.294 | 0.974 | 0.974 | 1.000 | 0.000 |
| seven-worker equal token smoke | 7 | 18.407 | 87.661 | 4.762 | 0.680 | 0.542 | 0.254 |
| seven-worker varied Council audit | 7 | 404.988 | 1697.198 | 4.191 | 0.599 | 0.132 | 0.223 |
| one-worker architecture review | 1 | 180.643 | 180.561 | 1.000 | 1.000 | 1.000 | 0.000 |

## 제한 사항

- 서로 다른 prompt, 작업량, Council 구성과 실행 길이를 비교하므로 causal speedup을 계산하지 않습니다.
- Windows 프로세스 시작 비용, 파일 I/O, 네트워크, rate limit, 모델 응답 길이와 일시적인 시스템 부하가 결과에 영향을 줍니다.
- parallelism_ratio가 높아도 최종 wall time이 가장 짧다는 뜻은 아닙니다. root-only 직렬 구간, 느린 작업자, 통합과 검증이 전체 경로를 지배할 수 있습니다.
- utilization은 슬롯 사용량의 단순한 시간 비율이고, CPU 사용률·토큰 효율·품질 점수가 아닙니다.
- balance_ratio는 길이의 min/max 비율이므로, 작업자 내부의 품질·정확성·산출물 가치는 측정하지 않습니다.
- 원본 Temp 파일은 측정 환경에만 존재할 수 있습니다. 원본이 정리되면 공개 CSV와 이 방법론에 보존된 수치·해시를 바탕으로만 확인할 수 있습니다.
- 이 자료는 오케스트레이션 관찰용이며, 모델·계정·서비스 계층에 대한 성능 보증이나 비용 예측이 아닙니다.
