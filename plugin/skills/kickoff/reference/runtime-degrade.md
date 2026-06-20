# 런타임 결정 + OMC degrade

> Step 7(런타임 결정)·Step 8-b(실행 단계)에서 참조. 런타임 추천 룰 표 + 호출 형태 +
> **OMC(oh-my-claudecode) 부재 시 자동 폴백** 규칙.
> `<프로젝트명>` 등은 SKILL.md 의 config 주입값으로 채운다.

## 런타임 추천 룰 (G: 영역 수 = In Progress + Design 제외)

| G | 추천 플래그 | 호출 방식 (OMC 있음) | OMC 없으면 폴백 |
|---|---|---|---|
| 1 | `--serial` | `pipeline:executor` 순차 (OMC 무관) | — (이미 OMC 무관) |
| 2~3 | `--agent` | `pipeline:executor` 병렬 (한 메시지에 N개, OMC 무관) | — (이미 OMC 무관) |
| 4 | `--team` | `Skill("oh-my-claudecode:team")` (tmux 분리로 parent context 압박 완화) | `--agent` (`pipeline:executor` 병렬 N개) |
| 5 | `--ultra` | `Skill("oh-my-claudecode:ultrawork")` (태스크 풀 — 단일 기능에 5영역 동시 의존 시) | `--agent` (`pipeline:executor` 병렬 N개) |

> 대상 영역은 최대 5개(Backend/Admin/Frontend/iOS/Android — Design 제외). G≥6 은 구조적으로
> 발생 불가. 단일 기능이 5영역 모두 건드리는 케이스(예: 인증·딥링크처럼 풀스택 변경 동반)는
> 드물지만 발생 시 `--ultra` 활성화.

## ★ OMC degrade (oh-my-claudecode 의존 분리)

이 skill 은 **OMC 같은 외부 오케스트레이터 없이도** 동작해야 한다. 런타임 호출 경로를 두
부류로 나눈다.

### (1) executor 직접 실행 경로 — OMC 무관 (항상 가능)

- **`--serial`**: In Progress 영역을 `Agent(subagent_type="pipeline:executor")` 로 **순차** 호출.
- **`--agent`**: In Progress 영역들을 **한 메시지 안에서 `Agent(subagent_type="pipeline:executor")` N개** 호출(실제 병렬).

이 두 경로는 OMC 가 설치돼 있든 없든 동일하게 작동한다. `pipeline:executor` 는 같은 플러그인의
sibling 에이전트라 항상 사용 가능.

### (2) `--team` / `--ultra` — OMC 있을 때만, 없으면 `--agent` 로 degrade

`--team`·`--ultra` 는 OMC 의 `oh-my-claudecode:team` / `oh-my-claudecode:ultrawork` skill 에
의존한다. 정책(epic #31): **OMC 가 있으면 그대로 쓰고, 없으면 `--agent`(= `pipeline:executor`
병렬 N개)로 자동 폴백**한다.

분기 (prose):

1. 사용자가 `--team`(또는 추천 G=4) 을 골랐다 → OMC `oh-my-claudecode:team` skill 호출을
   **시도**한다.
   - skill 호출이 가능하면(OMC 설치됨) → `Skill("oh-my-claudecode:team", task_list=[...], worker_count=N)` 로 실행.
   - skill 이 없거나 호출이 "skill not found / 사용 불가" 로 실패하면 → **`--agent` 로 폴백**:
     같은 In Progress 영역들을 **한 메시지 안에서 `pipeline:executor` N개 병렬** 호출.
     최종 리포트의 런타임 표기는 `agent (team→agent degrade)` 로 남긴다.
2. 사용자가 `--ultra`(또는 추천 G=5) 를 골랐다 → 위와 동일하게 `oh-my-claudecode:ultrawork`
   호출을 **시도**, 불가 시 **`--agent` 로 폴백**(런타임 표기 `agent (ultra→agent degrade)`).
3. **기본 추천(G=4/5)도 OMC 부재 시 `--agent` 로 수렴**한다 — 추천이 `--team`/`--ultra` 라도
   OMC 가 없으면 사용자에게 OMC 부재를 알리고(또는 `--bot` 모드면 조용히) `--agent` 병렬로
   진행한다.

핵심: **degrade 의 종착지는 항상 `--agent`(= `pipeline:executor` 병렬)** 다. OMC 의존은
`--team`/`--ultra` 경로에서만 발생하고, 그마저도 "있으면 쓰고 없으면 `--agent`"로 흡수되므로
이 skill 의 정상 동작은 OMC 설치 여부와 무관하다.

## 호출 형태 (요약)

```python
# --serial — OMC 무관
for area in in_progress_areas:
    Agent(description="<area> 구현", subagent_type="pipeline:executor", prompt=EXECUTOR_PROMPT)  # 순차

# --agent — OMC 무관 (한 메시지에서 N개 병렬)
# [Agent(..., subagent_type="pipeline:executor", ...) for area in in_progress_areas]

# --team — OMC 있으면:
Skill("oh-my-claudecode:team", task_list=[...], worker_count=N)
#        없으면 → --agent 폴백 (pipeline:executor 병렬 N개)

# --ultra — OMC 있으면:
Skill("oh-my-claudecode:ultrawork")
#        없으면 → --agent 폴백 (pipeline:executor 병렬 N개)
```

> **G12 주의**: Backend 선행 + 병렬 전환 시점에도 런타임 모드는 변경하지 않음(시작 시 결정된
> 모드 유지). Backend 단독 기간엔 단일 실행, Backend PR 생성 후 나머지 N-1개를 같은 모드로
> 병렬 실행. degrade 결정(team/ultra→agent)은 시작 시 1회만 내리고 이후 고정.
