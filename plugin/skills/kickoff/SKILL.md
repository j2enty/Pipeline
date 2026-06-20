---
description: parent 이슈의 영역별 sub-issue를 영역별 executor로 실행해 테스트 그린 PR까지 제출하고 /review 자동 체이닝
argument-hint: <parent-issue-url-or-number> [--agent|--team|--serial|--ultra] [--restart] [--bot]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, Skill, AskUserQuestion
disable-model-invocation: true
---

<!-- 이 skill 의 프로젝트값(owner·project-id·area-id·docs 디렉토리 등)은 설치 시 치환이
     아니라 실행 시 .claude/pipeline-config.yml 에서 읽는다. 코드펜스는 scripts/pipeline-config.sh
     리더로 값을 주입하고, 프로즈는 아래 "프로젝트 설정 (실행시 주입)" 블록을 참조한다.
     사람이 /pipeline:kickoff 로만 호출한다 (모델 자동호출 차단).
     OMC(oh-my-claudecode) 의존은 --team/--ultra 경로에서만 발생하고, OMC 부재 시
     --agent(pipeline:executor 병렬)로 자동 degrade 한다 — 정상 동작은 OMC 와 무관. -->

# /kickoff — 영역별 코드 작업 파이프라인

`/plan`이 만든 영역별 sub-issue를 입력으로 받아 영역별 executor를 지정 런타임으로 실행해요. 각 영역이 자체 테스트 그린을 증빙한 PR을 **Bot Review** 상태로 제출하고, 모든 영역이 PR을 낸 직후 **`/review` 파이프라인을 자동 체이닝**해요. Claude 리뷰를 통과한 영역은 **In Review**로 올려 사용자 hands-on 검증으로 넘겨요.

## 프로젝트 설정 (실행시 주입)

아래 `--dump` 출력은 이 프로젝트의 비민감 핵심 설정값이다. 프로즈·제목·Agent 프롬프트에서 `프로젝트명`·`org`·`대표 레포`·Project ID 등을 언급할 때는 이 값을 쓴다 (하드코딩 금지 — 전부 config 런타임 읽기). **단 Area ID(`area-id.*`)는 --dump 에 없다** — "Area ID 참조표" 섹션처럼 필요한 펜스에서 `bash "$CFG" area-id.<영역>` 으로 개별 읽는다.

!`bash "${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh" --dump 2>/dev/null || echo "(config 없음)"`

> **민감키는 --dump 에 없다** (보안 결정): `slack-token-key` 등 식별성 높은 값은 LLM 컨텍스트에 통째로 흘리지 않는다. 필요한 펜스에서 개별 키 읽기(`$(bash "$CFG" slack-token-key)`)로만 가져온다. `/kickoff` 는 PR 생성에 로컬 PAT(`gh pr create`)만 쓰므로 Reviewer 봇 App 토큰은 필요 없다 (그건 `/review` 소관).

## 사용법

```
/kickoff <parent-issue-url-or-number>                   # 런타임 자동 추천
/kickoff <parent-issue-url-or-number> --agent           # Agent 병렬 강제
/kickoff <parent-issue-url-or-number> --serial          # Agent 순차
/kickoff <parent-issue-url-or-number> --team            # OMC team (tmux) — 없으면 --agent 폴백
/kickoff <parent-issue-url-or-number> --ultra           # OMC ultrawork — 없으면 --agent 폴백
/kickoff <parent-issue-url-or-number> --restart         # 상태 파일 무시, 처음부터
/kickoff <parent-issue-url-or-number> --bot             # GHA 봇 실행 모드 (AskUserQuestion 스킵)
```

예 (`<owner>`·`<parent-repo-name>` 은 위 주입된 설정값):
- `/kickoff https://github.com/<owner>/<parent-repo-name>/issues/2`
- `/kickoff 2 --serial`
- `/kickoff 2 --restart`
- `/kickoff 2 --bot`

## 사전 조건

- Parent 이슈에 **`/plan` 이미 실행 완료** (본문에 "📋 Plan 산출물" 섹션 존재)
- 처리 대상 sub-issue가 **Prep Project에서 `Status=In Progress`**로 이동되어 있어야 함 (G1)
- Backend sub-issue가 존재하면 Backend도 `In Progress`여야 함 (G1-a)
- 로컬 `gh auth status` 통과, config `local-account` PAT 활성 (M1)
- Docs 레포가 `Docs/` 하위에 클론되어 있어야 함 (없으면 Context md 커밋만 자동 스킵 — Docs 미사용 프로젝트도 지원)

## 상수

이 섹션의 상수(Org·대표 레포·Project 번호·Project ID·Status/Area 필드 ID·Area ID 등)는 **실행 시 config에서 읽는다** — 위 "프로젝트 설정 (실행시 주입)" 블록의 `--dump` 출력을 참조한다. 코드펜스에서는 아래 패턴으로 직접 읽어 주입한다:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
bash "$CFG" owner              # Org
bash "$CFG" parent-repo-name   # 대표 레포
bash "$CFG" project-name       # 프로젝트명 (프로즈·프롬프트 표기용)
bash "$CFG" project-number     # Prep Project 번호
bash "$CFG" project-id         # Prep Project ID
bash "$CFG" status-field-id    # Status 필드 ID (Backlog/Planning/Ready/In Progress/Bot Review/In Review/Done)
bash "$CFG" area-field-id      # Area 필드 ID
bash "$CFG" docs-context-dir   # Context md 디렉토리
```

| 이름 | 값 (config 키) |
|---|---|
| Org | `owner` |
| 대표 레포 | `parent-repo-name` |
| Project 번호 | `project-number` (Prep) |
| Project ID | `project-id` |
| Status 필드 ID | `status-field-id` (Backlog/Planning/Ready/**In Progress**/**Bot Review**/**In Review**/Done) |
| Area 필드 ID | `area-field-id` |
| 상태 파일 | `.omc/state/sessions/<slug>.json` |
| 컨텍스트 문서 | `<docs-context-dir>/<slug>-status.md` |

## Area ID 참조표 (Prep Project Area 필드)

영역별 Area 옵션 ID는 **실행 시 config 의 `area-id.<영역>` 키로 읽는다** (대소문자 정확히 — `area-id.iOS`, `area-id.Backend` 등). 리더의 `area-id.<Name>` 키로 가져온다 (`bash "$CFG" --keys` 로 지원 확인).

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
bash "$CFG" area-id.Backend
bash "$CFG" area-id.Admin
bash "$CFG" area-id.Frontend
bash "$CFG" area-id.iOS
bash "$CFG" area-id.Android
bash "$CFG" area-id.Design   # (/kickoff 대상 제외 — 참조표에만 포함)
```

- Backend: `area-id.Backend`
- Admin: `area-id.Admin`
- Frontend: `area-id.Frontend`
- iOS: `area-id.iOS`
- Android: `area-id.Android`
- Design: `area-id.Design` (`/kickoff` 대상 제외)

## 런타임 추천 룰 + OMC degrade

영역 수 `G`(= In Progress 대상 수, Design 제외, Backend 포함)별 추천 런타임과, OMC(oh-my-claudecode) 부재 시 폴백 규칙은 [런타임 결정 + OMC degrade](reference/runtime-degrade.md) 참조. 요지:

- `--serial`·`--agent` 는 **`pipeline:executor` 직접 실행 — OMC 무관 (항상 가능)**.
- `--team`·`--ultra` 는 OMC `oh-my-claudecode:team`/`oh-my-claudecode:ultrawork` 에 의존하되, **OMC 가 없으면 `--agent`(= `pipeline:executor` 병렬 N개)로 자동 degrade**. degrade 의 종착지는 항상 `--agent` 라, 이 skill 의 정상 동작은 OMC 설치 여부와 무관하다.

## 수행 순서

### 1. 입력 파싱

- `$ARGUMENTS`에서 parent URL 또는 번호 추출
- 런타임 플래그 중 하나 추출 (`--agent|--team|--serial|--ultra`), 없으면 `RUNTIME_FLAG=null`
- `--restart` 플래그 추출
- `--bot` 플래그 추출 → `BOT_MODE=true` (GHA 자동화 실행 컨텍스트)
- 번호만 주어지면 config `parent-repo-name` 레포 기준으로 해석
- 두 개 이상의 런타임 플래그가 함께 오면 fail-fast (사용자 실수 방지)

**`--bot` 플래그 동작**:
- 모든 `AskUserQuestion` 호출 스킵 → 추천값/첫 번째 옵션 자동 선택
- 상태 파일 감지 시 자동 `[재개]` 선택
- 상태 파일 초기화 시 `"triggeredBy": "bot"` 기록
- 에스컬 코멘트에 "🤖 봇 자동 실행 중 발생" 명시

### 2. Parent 이슈 조회 및 plan 산출물 확인

> **fail-fast 게이트 (원격 쓰기 전 필수)**: 리더는 fail-soft 라 config 누락 시 빈 값을 반환한다. 빈 `owner`/`project-id` 등으로 `gh issue view --repo "/<repo>"` 나 빈 `projectId` GraphQL mutation 같은 잘못된 원격 호출이 나가는 것을 막기 위해, 첫 원격 작업 직전에 핵심 키를 검증한다(하나라도 비면 즉시 중단). plan·review skill 과 동일한 정지선.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
bash "$CFG" --require owner parent-repo-name project-id project-number status-field-id area-field-id || exit 1
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
gh issue view <parent-N> --repo "$OWNER/$PARENT_REPO_NAME" --json number,title,body,url,state
```

- `state != "OPEN"` → 중단 ("parent 이슈가 닫혀 있음")
- 본문에 **"📋 Plan 산출물"** 섹션이 없으면 중단 + 안내:
  > 이 parent에 `/plan` 산출물이 없음. `/plan <parent-url>` 먼저 실행 필요.
- 본문에서 `Slug:` 추출 (또는 "Plan 산출물" 섹션의 `**Slug:**` 라인 파싱)
- `SLUG` 저장

### 3. Sub-issue 발견 및 영역 매핑

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
# GitHub 네이티브 sub-issues API
gh api /repos/$OWNER/$PARENT_REPO_NAME/issues/<parent-N>/sub_issues
```

각 sub-issue에 대해:
- `repository.name`으로 영역 판별 (`Backend`/`Admin`/`Frontend`/`iOS`/`Android`/`Design`)
- **Design sub-issue는 즉시 대상에서 분리** (카운트·실행·리포트 모두 제외) — C6
- Prep Project의 Status·Area 필드 값 조회

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PROJECT_NUMBER="$(bash "$CFG" project-number)"
# Project item + Status · Area 필드 조회
gh api graphql -f query='
query($owner: String!, $number: Int!, $issueId: ID!) {
  organization(login: $owner) {
    projectV2(number: $number) {
      items(first: 100) {
        nodes {
          id
          content { ... on Issue { id } }
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2FieldCommon { name } }
              }
            }
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -F number="$PROJECT_NUMBER" -f issueId=<sub-issue-node-id>
```

- 각 sub-issue별로 `{ area, repo, number, nodeId, status, assignees, branch:"feature/#<N>-<SLUG>" }` 구조체로 정리

### 4. Status 필터링 (G1)

영역별 sub-issue 상태를 다음 분류로 나눔:

- **대상**: `Status=In Progress`
- **스킵(리포트 표기)**: `Status=Ready`, `Status=Backlog`, sub-issue closed, `Status=Bot Review`·`In Review`·`Done` (이미 처리됨 — `/review` 사이클 또는 사용자 검증 단계)

**G1-b 가드**: 대상이 0건이면 **중단 + 안내**:

> 처리할 In Progress sub-issue 없음. Prep Project에서 대상 카드를 In Progress로 이동 후 재실행.

### 5. Backend 게이트 체크 (G1-a)

- Backend sub-issue 존재 + `Status=Ready` + 다른 영역 중 `In Progress` 존재 → **중단 + 안내**:

  > Backend sub-issue(`<owner>/Backend#<N>`)가 Ready 상태. 인터페이스 계약 문제 방지 위해 Backend도 In Progress로 올리고 재실행 권장. 의도적 우회는 향후 `--skip-backend-gate` 플래그로 지원 예정(M3+).

- Backend sub-issue 자체가 없음 → 게이트 생략, 모든 In Progress 영역 동시 시작 (스펙 C1)
- Backend `In Progress` → Backend를 **선행 영역**으로 표시 (8단계에서 먼저 실행)

### 6. 상태 파일 감지 + 재개 분기 (G4)

```bash
STATE_FILE=".omc/state/sessions/${SLUG}.json"
```

**분기 A. `--restart` 플래그 있음**
→ "처음부터" 경로로 직행 (아래 분기 C 동작)

**분기 B. `STATE_FILE` 존재 + `--restart` 없음**
→ `--bot` 플래그 있으면 자동 `[재개]` 선택 (AskUserQuestion 스킵)
→ `--bot` 없으면 `AskUserQuestion`: "이전 실행 상태 감지됨 — 어떻게 할까요?"
   - `[재개]` → 기존 `STATE_FILE` 로드, 영역별 재개 매트릭스(G4) 적용:

     | 이전 상태 | 동작 |
     |---|---|
     | PR 있음 + `Status=Bot Review` | 스킵 (PR 생성 완료 — `/review` 사이클에서 처리) |
     | PR 있음 + `Status=In Review` | 스킵 (사용자 hands-on 검증 단계) |
     | PR 있음 + 머지 (Done) | 스킵 |
     | PR 없음 + 브랜치 있음 + `blocked` 라벨 | 라벨 제거 → 브랜치 체크아웃 → 자동 rebase → executor 이어서 (G4-b) |
     | PR 없음 + 브랜치 있음 + 라벨 없음 | 세션 크래시 간주. 브랜치 체크아웃 + 자동 rebase → executor 이어서 |
     | PR 없음 + 브랜치 없음 | 처음부터 (브랜치 생성부터) |
     | `Status=Ready/Backlog` · 이슈 close | 스킵 (사용자 의사 존중) |

   - `[처음부터]` → 분기 C 진입
   - `[취소]` → 종료

**분기 C. "처음부터" 또는 `--restart`**
→ `AskUserQuestion`: "기존 산출물을 어떻게 할까요?" (G4-c)
   - `[정리]` → 영역별 원격·로컬 브랜치 삭제 + 열린 PR close (코멘트: "`/kickoff --restart` 선택으로 재생성됨")
   - `[유지]` → 기존 브랜치·PR 유지하고 새 브랜치로 진행 (이름 충돌 시 `-v2`, `-v3` suffix 자동)
   - `[취소]` → 분기 B의 이전 AskUserQuestion으로 복귀 (또는 종료)

`--restart`가 명시된 경우: 분기 C에서 기본 `[정리]`로 자동 선택(no-op).

**분기 D. `STATE_FILE` 없음**
→ 바로 처음부터 실행 (AskUserQuestion 없음)

**G4-b. 자동 rebase**
재개 경로에서 브랜치 체크아웃 후 `git -C <영역> fetch origin && git -C <영역> rebase origin/develop`. 충돌 발생 시 실패 유형 `즉시 에스컬 / 머지 충돌`로 분류하고 에스컬 플로우 발동.

### 7. 런타임 결정 및 사용자 승인

- **영역 수 `G`** = In Progress 대상 수 (Design 제외, Backend 포함)
- 플래그가 있으면 그걸 사용 (override)
- 플래그가 없으면 위 런타임 추천 룰로 `RECOMMENDED` 계산
- `--bot` 플래그 있으면 `RECOMMENDED` 런타임으로 자동 진행 (AskUserQuestion 스킵)
- `--bot` 없으면 `AskUserQuestion`:
  > `{G}개 영역 → {RECOMMENDED} 런타임 추천. 진행할까요?`
  > `[진행]` `[다른 런타임 선택]` `[취소]`
- "다른 런타임 선택" 시 options `[--agent, --team, --serial, --ultra]`로 재질문

**OMC degrade 결정 (시작 시 1회 고정)** — 결정된 런타임이 `--team`/`--ultra` 면, 8-b 실행 시 OMC skill 호출을 시도하고 불가하면 `--agent` 로 폴백한다. 상세 분기는 [런타임 결정 + OMC degrade](reference/runtime-degrade.md) 참조. `--bot` 모드면 OMC 부재 시 조용히 `--agent` 로 진행.

**G12 주의**: Backend 선행 + 병렬 전환 시점에도 런타임 모드는 변경하지 않음 (시작 시 결정된 모드 유지). Backend 단독 기간엔 단일 실행, Backend PR 생성 후 나머지 N-1개를 같은 모드로 병렬 실행.

### 8. Executor 오케스트레이션 (G8 하이브리드)

#### 8-a. 상태 파일 초기화 / 갱신

```json
{
  "schemaVersion": "1.0",
  "slug": "<SLUG>",
  "parent": {"url": "...", "repo": "<owner>/<parent-repo-name>", "number": <N>, "title": "..."},
  "runtime": {"mode": "agent", "flagOverride": null, "decidedAt": "...", "triggeredBy": "user" | "bot", "omcDegrade": null},
  "areas": {
    "<area>": {
      "subIssue": {"repo": "...", "number": 0, "nodeId": "..."},
      "branch": "feature/#<N>-<SLUG>",
      "status": "pending",
      "pr": null,
      "retry": {"fixing": {"count":0,"limit":5}, "transient": {"count":0,"limit":3}},
      "lastError": null, "escalation": null,
      "startedAt": null, "completedAt": null
    }
  },
  "lastCommand": "/kickoff ...",
  "createdAt": "...", "updatedAt": "...",
  "events": [{"ts":"...","type":"run_start","runtime":"agent"}]
}
```

- `parent.repo` 의 `<owner>`·`<parent-repo-name>` 은 config `owner`·`parent-repo-name` 로 채운다.
- `runtime.omcDegrade` — team/ultra 가 OMC 부재로 agent 폴백됐으면 `"team→agent"` 등 기록(아니면 null).
- 파일 쓰기는 원자적 (temp + `mv`). 매 상태 전이·retry 증가·에스컬·SIGINT 시 갱신.

#### 8-b. 실행 단계 (영역별)

**Backend 선행 (있을 때)**:
1. Backend executor 1회 실행 (아래 `8-c` 영역 단위 실행 블록)
2. Backend 상태가 `pr_created`가 되면 → 나머지 In Progress 영역 병렬 기동
3. Backend가 `escalated`로 끝나면 → Backend만 에스컬 발송, **나머지 영역은 실행 안 함**
   (Backend 계약 없이 FE/iOS/Android 진행하면 G1-a 근거가 깨짐)

**Backend 없음**:
- In Progress 영역 모두 런타임 플래그에 따라 병렬/직렬 실행

**런타임별 호출 형태** (OMC degrade 포함 — 상세는 [reference/runtime-degrade.md](reference/runtime-degrade.md)):

```python
# --serial — OMC 무관
for area in in_progress_areas:
    Agent(description="<area> 구현", subagent_type="pipeline:executor", prompt=EXECUTOR_PROMPT)  # 순차

# --agent — OMC 무관 (한 메시지에서 N개 병렬)
# [Agent(..., subagent_type="pipeline:executor", ...) for area in in_progress_areas]

# --team — OMC 있으면 Skill("oh-my-claudecode:team", task_list=[...], worker_count=N)
#          OMC 없으면 → --agent 폴백 (pipeline:executor 병렬 N개)
# --ultra — OMC 있으면 Skill("oh-my-claudecode:ultrawork")
#          OMC 없으면 → --agent 폴백 (pipeline:executor 병렬 N개)
```

> **degrade 분기 (prose)**: `--team`/`--ultra` 면 먼저 OMC skill 호출을 **시도**한다. 호출이 가능하면(OMC 설치됨) 그대로 OMC 에 위임하고, "skill not found / 사용 불가" 로 실패하면 **`--agent` 로 폴백**해 같은 In Progress 영역들을 한 메시지 안에서 `pipeline:executor` N개 병렬 호출한다. 폴백 시 상태 파일 `runtime.omcDegrade` 와 최종 리포트 런타임 표기를 `agent (team→agent degrade)` / `agent (ultra→agent degrade)` 로 남긴다. degrade 의 종착지는 항상 `--agent` 다.

#### 8-c. 영역 단위 실행 블록 (`run_area`)

```
1. executor 호출
   Agent(
     description="<area> 구현",
     subagent_type="pipeline:executor",
     prompt=EXECUTOR_PROMPT  # reference/agent-prompts.md §8-c-1
   )

2. 반환 파싱 → { status, branch, testSummary, commits[], errorSummary? }
   (JSON 아닌 자유 텍스트면 immediate / 반환 포맷 오류 — 재시도 1회 후 에스컬)

3. status == "ready_for_pr":
   → verifier 호출
     Agent(
       description="<area> verifier",
       subagent_type="pipeline:verifier",
       prompt=VERIFIER_PROMPT  # reference/agent-prompts.md §8-c-2
     )
   → verdict == "pass":
       → 8-f 원격 동기화 가드 (PR 생성 직전 필수)
       → PR 생성 (8-g 템플릿)
       → Sub-issue AC 체크박스 체크 (G17)
       → Status=Bot Review 전환 (GraphQL mutation — `/review` 대기)
       → blocked 라벨 제거 (있었다면)
       → 상태 파일: areas[area].status="pr_created", pr={...}
   → verdict == "fail":
       → fixing 카운트 +1
       → fixing < 5 → executor 재호출 (verifier reasons를 추가 입력)
       → fixing ≥ 5 → G2 에스컬 (category="fixing")

4. status == "escalated":
   → G2 에스컬 플로우 (9단계)
```

**재시도 정책은 오케스트레이터 소유** — executor 는 `errorSummary.category`(fixing/transient/immediate) 라벨만 달아 반환하고, 상한 적용은 이 8-c 루프가 한다:
- **fixing**: 코드·플랜 정합성 문제(verifier fail 포함). `fixing < 5` → executor 재호출(verifier reasons 추가) / `fixing ≥ 5` → 에스컬.
- **transient**: 일시 장애(네트워크·flaky·rate limit). `transient < 3` → 지수 백오프(2s→4s→8s) 후 재호출 / `transient ≥ 3` → 에스컬.
- **immediate**: 환경·권한·의존성 부재. 재시도 없이 즉시 에스컬.

> executor 프롬프트(`EXECUTOR_PROMPT`)·verifier 프롬프트(`VERIFIER_PROMPT`)의 입력 배선은 [executor·verifier 프롬프트 템플릿](reference/agent-prompts.md) 참조. 절차·반환 JSON 스키마·금지사항은 이미 `pipeline:executor`·`pipeline:verifier` 시스템프롬프트에 승격돼 있어, 호출 프롬프트는 입력만 전달한다.

#### 8-f. 원격 동기화 가드 (G15) — PR 생성 직전 필수

executor가 내부적으로 push에 실패했는데도 `status=ready_for_pr` 로 반환하는 경우가 있음 (2026-04-20 Android 사례). 오케스트레이터가 PR 생성 직전에 로컬-원격 동기화를 직접 확인:

```bash
# 로컬 브랜치가 원격보다 앞서 있는 커밋 수
AHEAD=$(git -C <영역> rev-list origin/<branch>..<branch> --count 2>/dev/null || echo "err")

if [ "$AHEAD" = "err" ]; then
  # 원격 브랜치가 아예 없음 → 최초 push
  git -C <영역> push -u origin <branch> || {
    # push 실패 → immediate 에스컬
    ESCAL_CATEGORY="immediate"
    ESCAL_SUBCATEGORY="원격 동기화 실패"
    goto_escalation
  }
elif [ "$AHEAD" -gt 0 ]; then
  # 미푸시 커밋 존재 → 보정 push
  git -C <영역> push origin <branch> || {
    ESCAL_CATEGORY="immediate"
    ESCAL_SUBCATEGORY="원격 동기화 실패"
    goto_escalation
  }
  # 재확인
  AHEAD=$(git -C <영역> rev-list origin/<branch>..<branch> --count)
  if [ "$AHEAD" -gt 0 ]; then
    ESCAL_CATEGORY="immediate"
    ESCAL_SUBCATEGORY="원격 동기화 실패"
    goto_escalation
  fi
fi
# AHEAD == 0 → PR 생성으로 진입
```

이유: executor의 `status=ready_for_pr` 자체 주장만 믿고 PR 생성하면, 불완전 diff로 PR이 만들어져 리뷰어가 잘못된 변경분을 보게 됨. 가드 비용은 `rev-list` 1회 + 조건부 push 1회로 미미.

#### 8-g. PR 생성 (verdict=pass 시 + 8-f 동기화 확인 후)

간소화된 템플릿(G16)으로 PR 본문 구성 → `gh pr create` → 반환 URL 저장:

**톤 가이드**: 개요는 친근한 존댓말("~ 추가했어요 / ~ 적용했어요") 기본. 기술 세부는 **변경** 섹션의 bullet으로 분리. 영역 간 문체 편차 방지.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
gh pr create \
  --repo "$OWNER/<영역>" \
  --base develop \
  --head feature/#<sub-N>-<slug> \
  --title "<parent-title> — <영역>" \
  --body "$(cat <<EOF
## 📌 개요
<2~3줄, "~ 추가했어요/적용했어요" 톤. 기술 세부는 변경 섹션으로>

Closes $OWNER/<영역>#<sub-N>
Parent: $OWNER/$PARENT_REPO_NAME#<parent-N>

## 📋 변경
- <bullet 3~5개 — 구현 가치 기준>

## ✅ 테스트
| 항목 | 결과 |
|---|---|
<표>

\`<실제 실행된 command>\` → **N passed, N failed, N skipped**

<필요시 주석 (예: "Compose UI 테스트는 에뮬레이터 미실행")>

## 🔗 참고
- 플랜: \`Docs/claude/plans/<parent-N>-<slug>-<영역소문자>.md\`
- 세션: \`.omc/state/sessions/<slug>.json\`
EOF
)"
```

> **`Closes`/`Parent` 라인은 무따옴표 heredoc(`<<EOF`)** 이라 `$OWNER`·`$PARENT_REPO_NAME` 가 실제 값으로 치환된다. 코드블록(`\``)·문장 내 `$` 충돌이 없도록 본문은 위 형태 유지.

**템플릿 축약 근거** (파일럿 3 PR 실측 기반):
- `<details>` 로그 블록 — 3 PR 모두 executor 자발적 생략. 제거
- `🤖 자동 생성` 푸터 — 리뷰어에 무가치(kickoff 최종 리포트로 이관). 제거
- `📋 변경 내용` → `📋 변경` — 간결화
- 개요 톤 가이드 추가 — Frontend/iOS 1줄 빈약함 방지
- "실제 실행된 command" 강조 — iOS `id=...` placeholder 잔존 bug 재발 방지

PR 생성 후 **Sub-issue AC 체크박스 체크** (G17):

`/plan`이 sub-issue 본문에 넣은 `## AC` 섹션의 체크박스(`- [ ]`)를 전부 `- [x]`로 치환. verifier=pass 확정 상태이므로 모든 AC가 구현됐다고 간주. 다른 섹션(`## 요약`, `## 참고` 등)은 건드리지 않음. 이미 체크된 박스는 그대로 — idempotent.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
BODY=$(gh issue view <sub-N> --repo "$OWNER/<영역>" --json body --jq .body)
NEW_BODY=$(printf '%s\n' "$BODY" | awk '
/^## AC([[:space:]]|$)/ { in_ac=1; print; next }
/^## / && in_ac { in_ac=0 }
in_ac { gsub(/- \[ \]/, "- [x]") }
{ print }
')
gh issue edit <sub-N> --repo "$OWNER/<영역>" --body "$NEW_BODY"
```

**실패 시**: 에스컬 아님. 경고 로그만 남기고 Status 전환은 계속 진행 (체크박스는 편의 기능이라 실패가 PR 품질 게이트를 막지 않음).

PR 생성 후 **Status=Bot Review 전환** (Claude `/review` 대기 단계):

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PROJECT_NUMBER="$(bash "$CFG" project-number)"
PROJECT_ID="$(bash "$CFG" project-id)"
STATUS_FIELD_ID="$(bash "$CFG" status-field-id)"

# Status option ID 동적 조회
BOT_REVIEW_ID=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
  | jq -r '.fields[] | select(.name=="Status") | .options[] | select(.name=="Bot Review") | .id')

# item id는 3단계에서 이미 보관됨
gh api graphql -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
    value: { singleSelectOptionId: $optionId }
  }) { projectV2Item { id } }
}' -f projectId="$PROJECT_ID" \
  -f itemId="<ITEM_ID>" \
  -f fieldId="$STATUS_FIELD_ID" \
  -f optionId="$BOT_REVIEW_ID"
```

> `In Review` 전환은 `/review` 가 APPROVE 판정한 뒤에만 발생 (review SKILL 7-h 참고). `/kickoff` 는 `Bot Review`까지만 책임.

### 9. 에스컬 플로우 (G2 + G3-b)

executor가 `status=escalated`로 반환했거나, fixing/transient 상한을 초과한 경우 처리한다. `blocked` 라벨 보장·부착(9-a), 에스컬 코멘트 본문(9-b), 상태 파일 업데이트(9-c), 영역별 독립 원칙(9-d), Slack 이중 발송 규칙은 [에스컬레이션 템플릿](reference/escalation.md) 참조.

핵심:
- **개별 PR/sub-issue 실패** → 해당 sub-issue 에 `blocked` 라벨 + 에스컬 코멘트.
- **Slack 이중 발송** — GitHub 코멘트가 1차, `"${CLAUDE_SKILL_DIR}/scripts/slack-notify.sh"` 가 그 뒤(순서 고정). config `slack-token-key`(가 가리키는 env webhook) 미설정 시 헬퍼가 graceful skip → 파이프라인 차단 없음.
- **영역별 독립** (G3) — 한 영역 에스컬돼도 나머지 영역은 계속(Backend 선행 제외 — 8-b).

### 10. `/review` 자동 체이닝 (G18)

모든 영역 `run_area` 루프가 끝난 직후 (성공·혼합·에스컬 전부 포함) 조건을 만족하면 `/review` 파이프라인을 같은 컨텍스트에서 이어서 실행해요. 의도: 사용자가 `/kickoff` 한 번 실행으로 "개발 → 자동 리뷰 → 사용자 검증 대기(`In Review`)" 까지 논스톱 진입.

#### 10-a. 체이닝 조건

다음을 **모두** 만족할 때만 `/review` 자동 호출:

1. 최소 1개 영역이 `status=pr_created` (리뷰할 PR 존재)
2. Parent 모드 (단일 sub-issue만 처리한 경우에도 parent-url이 있으면 parent 모드로 chain)
3. 사용자가 `--no-review` 플래그를 주지 않았음 (향후 옵션 — 현재는 무조건 체이닝)
4. **`--bot` 플래그가 없음** — `--bot` 실행 시 체이닝 스킵. GHA `auto-review.yml` 이 Bot Review 상태 감지 후 독립적으로 `/review` 를 트리거함

아래 경우에는 **체이닝 생략**하고 이유 로그 + 최종 리포트에 안내:

- 모든 영역이 `escalated` 또는 `skipped` → 리뷰 대상 PR 없음
- Backend 선행이 `escalated` → 8-b에 따라 나머지 영역 실행 안 됐고 Backend만 에스컬. 리뷰할 PR 0~1개지만 cross-area critic 무의미. 단일 Backend PR만 있는 경우엔 체이닝 진행 (10-a 1번 조건 충족)

#### 10-b. Skill 호출

`/review` 는 이제 같은 플러그인의 sibling skill (`pipeline:review`) 이다 — 네임스페이스를 명시해 호출한다:

```
Skill(
  skill="pipeline:review",
  args="<parent-issue-url>"
)
```

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
# 번호만 있으면 URL 로 변환:
#   https://github.com/$OWNER/$PARENT_REPO_NAME/issues/<N>
```

- `parent-issue-url` 은 1단계에서 파싱한 값 그대로 사용 (번호→URL 변환 필요 시 위 형태)
- `pipeline:review` 는 자체 상태 파일(`.omc/state/reviews/<slug>.json`)을 만들고, `/kickoff` 세션 파일은 건드리지 않음 (review SKILL C8, G1)
- `pipeline:review` 가 실패해도 `/kickoff` 는 이미 PR 생성까지 책임 완료 상태 — 최종 리포트에만 "리뷰 체이닝 실패" 로 표기

#### 10-c. 체이닝 실패 처리

`pipeline:review` Skill 호출 자체가 실패 (권한·네트워크·Skill not found 등) 하면:

- `events` 에 `{"type": "review_chain_failed", "reason": "..."}` 추가
- 최종 리포트에 "⚠️ `/review` 자동 체이닝 실패 — 수동 `/review <parent-url>` 실행 필요" 문구 포함
- `/kickoff` 자체는 성공 종료 (PR 생성은 이미 완료)

#### 10-d. 체이닝 결과 통합

`pipeline:review` 가 종료되면 그 상태 파일을 읽어서 `/kickoff` 최종 리포트(12단계)에 영역별 리뷰 판정을 같이 표시해요:

```bash
REVIEW_STATE=".omc/state/reviews/${SLUG}.json"
if [ -f "$REVIEW_STATE" ]; then
  REVIEW_VERDICTS=$(jq -r '.prs | to_entries[] | "\(.key): \(.value.verdict)"' "$REVIEW_STATE")
fi
```

리뷰 판정이 `approved` 인 영역은 `pipeline:review` 가 직접 `Status=In Review` 로 전환 (review SKILL 7-h 참고). `/kickoff` 는 여기서 Status 를 다시 건드리지 않아요.

### 11. Context md 생성 (G7)

세션 종료 직전(성공·혼합·에스컬·SIGINT 모두 포함) **항상** 로컬에서 생성. 저장 경로는 config `docs-context-dir` 로 결정:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
DOCS_CONTEXT_DIR="$(bash "$CFG" docs-context-dir)"
# 생성 대상: $DOCS_CONTEXT_DIR/<slug>-status.md
```

템플릿 본문·Docs 커밋 트리거(G7-c)는 [Context md 생성 템플릿](reference/context-md.md) 참조. Docs 커밋은 **Docs 가 독립 git 레포 루트일 때만**(`--show-toplevel` 일치) 수행하고, 아니면 자동 스킵(Docs 미사용/미클론 프로젝트도 지원). 클린 성공(전부 pr_created, 스킵·에스컬 0건)은 Docs 커밋 생략.

### 12. 최종 리포트

사용자에게 요약 출력 (`/review` 자동 체이닝 결과 포함):

```
/kickoff 완료 — <parent-title>

Slug: <slug>
런타임: <mode>   # OMC 폴백 시 "agent (team→agent degrade)" 등
세션: .omc/state/sessions/<slug>.json

영역별 상태 (/kickoff):
  ✅ Frontend   PR #12 생성         [feature/#1-<slug>]  Status=Bot Review
  ✅ iOS        PR #13 생성         [feature/#1-<slug>]  Status=Bot Review
  🔴 Android    escalated (빌드 오류)  [feature/#1-<slug>]  → <코멘트 URL>
  ⏳ Backend    스킵 (Status=Ready)

/review 자동 체이닝: 실행됨 (.omc/state/reviews/<slug>.json)

영역별 리뷰 판정:
  ✅ Frontend   APPROVE          Status=In Review (사용자 검증 대기)
  ❌ iOS        REQUEST_CHANGES  Status=Bot Review 유지 · review-blocked 라벨

종합 리뷰 (critic): concerns
  - [major] FE/iOS 버전 표시 위치 불일치
  parent 코멘트: <URL>

경고 (해당 시):
  - Android 에스컬 — 리뷰 대상에서 제외됨. 수정 후 /kickoff 재실행.
  - iOS REQUEST_CHANGES — 코드 수정 후 /review <pr-url> 재실행 필요.

Context 문서:
  - <docs-context-dir>/<slug>-status.md  (Docs 커밋: 예/생략)

▶ 다음:
  - In Review PR (Frontend): 사용자 hands-on 검증 → 머지
  - Bot Review + REQUEST_CHANGES (iOS): 수정 후 /review <pr-url> 재실행
  - escalated (Android): 코멘트 안내 따라 조치 후 /kickoff <parent-url>
```

`/review` 체이닝이 실패했거나 조건 미충족으로 건너뛴 경우 위 `/review 자동 체이닝` 블록을 다음 문구로 대체:

```
/review 자동 체이닝: 생략 (<이유>)
  → 수동 실행: /review <parent-url>
```

## 원칙 (지켜야 할 것)

- **Status In Progress만 처리** (G1) — Ready·Backlog는 스킵. 자동 전환 안 함
- **Status `In Progress → Bot Review`는 PR 생성 직후 자동 전환** (G1) — `/kickoff` 가 담당. `Bot Review → In Review` 전환은 `/review` APPROVE 후 `/review` 가 담당
- **Sub-issue AC 체크박스 자동 체크** (G17) — verifier=pass + PR 생성 확정 후 `## AC` 섹션의 `- [ ]`를 전부 `- [x]`로 갱신. 다른 섹션 영향 없음. 실패해도 Status 전환은 계속
- **원격 동기화 가드 보존** (G15) — PR 생성 직전 `rev-list` 로 로컬-원격 동기화 확인. executor 가 push 실패하고도 ready 반환하는 케이스(2026-04-20) 차단
- **Backend 게이트는 계약 문제** (G1-a) — Ready Backend + In Progress 타 영역이면 중단
- **영역별 독립 실패** (G3) — 한 영역 에스컬돼도 다른 영역은 계속 (Backend 선행 제외)
- **실패 시 자동 복구 금지 (C7)** — 중간 단계 실패 시 즉시 중단 + 상태 저장 + 에스컬
- **재시도 3분류 고정** (C3) — 수정 5회 / 일시 3회+백오프 / 즉시 에스컬. 사용자 override 없음
- **PR 생성 ≠ 머지** — `/kickoff`는 "PR 생성 + `Bot Review` 전환 + `/review` 체이닝까지"가 책임. 머지는 사용자 hands-on 검증 후 (G4-a, G18)
- **`/review` 자동 체이닝** (G18) — 모든 영역 `run_area` 종료 후 리뷰 가능한 PR이 1개 이상이면 `pipeline:review` 자동 호출. 체이닝 실패는 `/kickoff` 자체 실패로 취급하지 않음
- **OMC degrade** — `--team`/`--ultra` 는 OMC 있을 때만, 없으면 `--agent`(pipeline:executor 병렬)로 폴백. `--serial`/`--agent` 는 OMC 무관. 정상 동작은 OMC 설치 여부와 무관
- **Design 영역은 항상 제외** (C6) — 카운트·실행·리포트 모두
- **Parent Status는 건드리지 않음** — 사용자 소유 (plan 과 일관)
- **상태 파일 원자적 쓰기** — temp + `mv`, partial write 방지

## 자주 하는 실수 (주의!)

- `Agent()` 병렬 호출 시 같은 메시지 내에 여러 tool_use 블록을 넣어야 실제 병렬. 순차 메시지는 직렬 실행됨
- Status option ID는 레포·프로젝트마다 다를 수 있음 → **동적 조회** (`gh project field-list`). 하드코딩 금지
- sub-issue 조회 시 `gh api ... /sub_issues` 응답의 `id`는 **database id** (integer). `node_id`와 구분
- 모든 git 명령은 `git -C <영역>` 형태로 호출 (compound `cd <영역> && git ...` 금지). 권한 샌드박스가 `Bash(git -C <영역> *)` 와일드카드만 허용
- PR 생성 후 Status 전환이 실패하면 PR은 남고 Status만 In Progress — **재실행 시 G4 매트릭스**에 따라 "PR 있음 + Status≠Bot Review·In Review"는 스킵 안 될 수도 있으므로, Status 전환 실패는 에스컬(`immediate`)로 처리 권장
- `Bot Review` 와 `In Review` 소유권 혼동 금지 — `Bot Review` 전환은 `/kickoff` (PR 생성 직후), `In Review` 전환은 `/review` (APPROVE 후). `/kickoff` 가 `In Review` 로 직접 전환하지 않음
- `/review` 자동 체이닝 시 Skill 호출은 `Skill(skill="pipeline:review", args="<parent-url>")` 형태 (같은 플러그인 sibling skill — 네임스페이스 명시). OMC 플러그인이 따로 제공하는 review skill 과 혼동 금지 (그쪽은 `oh-my-claudecode:` 네임스페이스 — 우리가 부를 대상 아님)
- `--team`/`--ultra` 는 OMC 없으면 `--agent` 로 자동 폴백 — OMC 없다고 조용히 직렬 실행하거나 실패하지 말 것. degrade 종착지는 항상 `--agent`(pipeline:executor 병렬)
- `--agent|--team|--serial|--ultra` 두 개 이상 동시 지정 시 fail-fast (조용히 무시 금지)
- executor 반환이 JSON 아닌 경우(모델 환각) → 재시도 1회 + 그래도 실패 시 `immediate / 반환 포맷 오류` 에스컬

## Minor 격차 (구현 중 발견 시 결정)

G9~G13 경계 케이스 결정 기록은 [Minor 격차](reference/minor-gaps.md) 참조.
