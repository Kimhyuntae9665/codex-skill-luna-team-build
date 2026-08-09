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

작업자 수를 k라고 할 때:

~~~text
parallelism_ratio = summed_worker_seconds / wall_seconds
utilization       = summed_worker_seconds / (k × wall_seconds)
balance_ratio     = min(worker_duration_seconds) / max(worker_duration_seconds)
start_skew        = latest_worker_start - earliest_worker_start
~~~

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
