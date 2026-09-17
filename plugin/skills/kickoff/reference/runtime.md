# 런타임 결정

> Step 7(런타임 결정)·Step 8-b(실행 단계)에서 참조. 런타임 추천 룰 표 + 호출 형태.
> `<프로젝트명>` 등은 SKILL.md 의 config 주입값으로 채운다.

## 런타임 추천 룰 (G: 영역 수 = In Progress + Design 제외)

| G | 추천 플래그 | 호출 방식 |
|---|---|---|
| 1 | `--serial` | `pipeline:executor` 순차 |
| 2~5 | `--agent` | `pipeline:executor` 병렬 (한 메시지에 N개) |

> 대상 영역은 최대 5개(Backend/Admin/Frontend/iOS/Android — Design 제외). G≥6 은 구조적으로
> 발생 불가.

두 경로 모두 같은 플러그인의 sibling 에이전트 `pipeline:executor` 를 직접 호출하므로 외부
오케스트레이터 없이 항상 동작한다.

- **`--serial`**: In Progress 영역을 `Agent(subagent_type="pipeline:executor")` 로 **순차** 호출.
- **`--agent`**: In Progress 영역들을 **한 메시지 안에서 `Agent(subagent_type="pipeline:executor")` N개** 호출(실제 병렬).

### 호환 별칭 `--team` / `--ultra`

옛 사용법 호환을 위해 `--team`·`--ultra` 도 받지만 **`--agent` 의 별칭**이다. 입력 파싱 시
`--agent` 로 정규화하고(`runtime.mode="agent"`, `runtime.flagOverride` 에는 사용자가 친 원래
플래그를 기록), 사용자에게 "`--team`/`--ultra` 는 `--agent` 와 같게 동작합니다" 안내 한 줄을 남긴다.
`--bot` 모드면 안내 없이 진행한다. 추천·재질문 옵션에는 별칭을 노출하지 않는다.

## 호출 형태 (요약)

```python
# --serial
for area in in_progress_areas:
    Agent(description="<area> 구현", subagent_type="pipeline:executor", prompt=EXECUTOR_PROMPT)  # 순차

# --agent (별칭 --team·--ultra) — 한 메시지에서 N개 병렬
# [Agent(..., subagent_type="pipeline:executor", ...) for area in in_progress_areas]
```

> **G12 주의**: Backend 선행 + 병렬 전환 시점에도 런타임 모드는 변경하지 않음(시작 시 결정된
> 모드 유지). Backend 단독 기간엔 단일 실행, Backend PR 생성 후 나머지 N-1개를 같은 모드로
> 병렬 실행.
