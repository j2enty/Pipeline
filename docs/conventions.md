# Pipeline 컨벤션 레퍼런스

> CLAUDE.md에서 분리한 **참조 문서**. 매 세션 로드되지 않으며, 다음 작업 시 펴본다:
> 새 input/secret/output 추가 · 변수/파일 이름 결정 · 코드 배치 위치 결정 · config(`pipeline-config.yml`) 작성.
> **새 input/secret/output·모듈 동작 플래그는 yml/SKILL에서 즉흥적으로 만들지 말고 아래 카탈로그에 먼저 추가한다.**

## 인터페이스 컨벤션

### 1. input vs secret 분류 원칙

**누설 영향 기준**:

| 분류 | 정의 | 예시 |
|---|---|---|
| input | 누설돼도 보안 영향 없음 | `module`, `owner`, `working-directory` |
| secret | 누설되면 권한·리소스 도난 가능 | `AUTHOR_APP_ID`, `AUTHOR_PRIVATE_KEY`, `SLACK_WEBHOOK_URL` |

App ID·Installation ID는 공식적으로 공개 가능하지만, fingerprinting 위험이 있어 **보수적으로 secret**으로 분류.

### 2. 전달 모델: 개별 input

GHA 표준 패턴 — 각 값을 개별 input으로 명시 노출. JSON config나 vars fallback은 사용 안 함 (외부 사용자에게 명시성 ↓).

### 3. 변수명 케이스

| 종류 | 케이스 | 이유 |
|---|---|---|
| input | **kebab-case** | GHA 표준 |
| job ID / step ID / output | **kebab-case** | 일관성 |
| secret | **SCREAMING_SNAKE_CASE** | 환경변수 표준과 묶임 |

### 4. 표준 input 카탈로그

새 input은 이 카탈로그에 먼저 추가. yml 내에서 즉흥적으로 새 이름 만들지 않음.

| input | 타입 | 사용 시점 | 의미 |
|---|---|---|---|
| `module` | string | module 동작 yml | 어느 모듈 (`Backend`, `iOS` 등) |
| `owner` | string | 거의 모든 yml | GitHub 조직/사용자 |
| `parent-repository` | string | parent 추적 yml | `<owner>/<repo>` 형식 |
| `modules-ignore` | string | multi-module yml | JSON 배열. 제외 모듈 (예: `'["Design"]'`) |
| `working-directory` | string | slash command 실행 yml | runner 작업 디렉토리 |
| `slack-channel` | string | 알림 yml (옵션) | 슬랙 채널 |
| `ci-workflow-name` | string | auto-merge yml | 해당 모듈의 CI workflow 이름 (예: `Backend CI`) |
| `reviewer-bot-login` | string | review·critic yml | Reviewer 봇 GitHub 로그인 이름 (예: `reclip-review-bot[bot]`) |
| `verdict-state-dir` | string | critic·critic-dispatch yml | verdict 상태 파일 디렉토리 (예: `.pipeline/state/reviews`) |
| `strict-review-bot-check` | boolean | review·critic yml | `true`: 누구의 CHANGES_REQUESTED든 차단 / `false`: Reviewer 봇 것만 확인 |
| `project-owner` | string | merge yml (옵션) | Project v2 소유자 (org/user 로그인). 미설정 시 머지 후 Status 전환 스킵 |
| `project-number` | string | merge yml (옵션) | Project v2 번호. 미설정 시 머지 후 Status 전환 스킵 |
| `tracking-enabled` | boolean | review·critic yml | finding 추적 이슈 생성 on/off |
| `major-label` | string | review·critic yml | major finding 추적 라벨명 (기본 `major-issue`) |
| `minor-label` | string | review·critic yml | minor finding 추적 라벨명 (기본 `minor-issue`) |

### 5. 표준 secret 카탈로그

**Author / Reviewer 봇 분리** — AI 자동화는 봇이 PR 생성 + 봇이 리뷰함. self-approve 차단 회피 위한 entity 분리.

| secret | 필수도 | 의미 |
|---|---|---|
| `AUTHOR_APP_ID` | 모든 자동화 yml 필수 | PR 작성 봇의 App ID |
| `AUTHOR_PRIVATE_KEY` | 동일 | PEM |
| `AUTHOR_INSTALLATION_ID` | 동일 | Installation ID |
| `REVIEWER_APP_ID` | review 부착 yml에서만 필수 | PR 리뷰 봇의 App ID |
| `REVIEWER_PRIVATE_KEY` | 동일 | PEM |
| `REVIEWER_INSTALLATION_ID` | 동일 | Installation ID |
| `SLACK_WEBHOOK_URL` | 옵션 | 슬랙 인커밍 웹훅 — Janus 미설정·실패 시 장애 알림 폴백 경로 |
| `JANUS_AUTH_TOKEN` | 옵션 | Janus 게이트웨이 Bearer 인증 토큰 — Janus 알림 경로 활성화에 필요 |

옵셔널 동작:
- Reviewer secret 미설정 + AI 리뷰 yml 미호출 → 정상 (사람이 리뷰하는 일반 자동화)
- Reviewer secret 미설정 + AI 리뷰 yml 호출 → secret 누락으로 적절히 fail
- 장애 알림 경로: `JANUS_BASE_URL`·`JANUS_AUTH_TOKEN`·`JANUS_ALERT_CHANNEL` 셋 다 있어야 Janus 경로 활성, 아니면 `SLACK_WEBHOOK_URL` 웹훅 폴백. 셋 다 미설정 + webhook 도 미설정 → 알림 자동 스킵(본 로직은 정상 진행)

### 6. output 컨벤션

두 가지 메커니즘이 역할 분리되어 공존:

- **명시적 outputs** (workflow_call) — 단일 yml의 결과 노출. 같은 run 안에서 후속 job이 사용
- **chain은 App에서 처리** — yml에서 `repository_dispatch`로 chain 트리거하지 않음. App이 webhook 수신 후 다음 단계 dispatch

표준 output 카탈로그:

| output | 타입 | 노출 yml | 의미 |
|---|---|---|---|
| `pr-number` | string | PR 생성 yml | PR 번호 |
| `pr-url` | string | PR 생성 yml | PR HTML URL |
| `merged-sha` | string | 머지 yml | 머지된 commit SHA |
| `verdict` | string | review/critic yml | `approved` / `changes-requested` / `escalated` |
| `escalated` | boolean | review/critic yml | 에스컬레이션 발생 여부 |

---

## 명명 컨벤션

> **yml 파일명** 규칙은 `.claude/rules/workflows.md`로 이동(워크플로 작성 시 자동 로드).

### Org Variables

`PIPELINE_*` prefix 사용. 이름 확정 후 일괄 치환 가능 (grep + find & replace).

> **SSOT 주의**: 아래 표는 `install.sh` 의 `register_variables()`(영역 레포에 `gh variable set`)가
> **실제로 자동 등록하는 값**과 1:1 로 맞춰져 있다. 이 표를 바꾸면 `install.sh` 도 함께 확인한다.
> (변수는 org 가 아니라 **영역 레포 단위**로 등록된다 — 이름은 관례상 "Org Variables" 로 부른다.)

**install.sh 가 자동 등록하는 변수** (호출자 yml 이 `vars.PIPELINE_*` 로 참조):

| 변수명 | input 매핑 | 의미 |
|---|---|---|
| `PIPELINE_OWNER` | `owner` | GitHub 조직명 |
| `PIPELINE_PARENT_REPOSITORY` | `parent-repository` | `<owner>/<repo>` |
| `PIPELINE_MODULES_IGNORE` | `modules-ignore` | 제외 모듈 JSON 배열 |
| `PIPELINE_WORKING_DIRECTORY` | `working-directory` | runner 작업 경로 |
| `PIPELINE_REVIEWER_BOT_LOGIN` | `reviewer-bot-login` | Reviewer 봇 로그인 이름 (예: `review-bot[bot]`) |
| `PIPELINE_VERDICT_DIR` | `verdict-state-dir` | critic verdict 상태 파일 디렉토리 |
| `PIPELINE_STRICT_REVIEW_BOT_CHECK` | `strict-review-bot-check` | Reviewer 봇 CHANGES_REQUESTED만 차단 기준으로 볼지 |
| `PIPELINE_CI_WORKFLOW_NAME` | `ci-workflow-name` | auto-merge 가 CI pass 확인 시 참조할 워크플로 이름 (config `ci-workflow-name` 비면 미등록) |
| `PIPELINE_TRACKING_ENABLED` | `tracking-enabled` | finding 추적 on/off |
| `PIPELINE_TRACKING_MAJOR_LABEL` | `major-label` | major 추적 라벨명 |
| `PIPELINE_TRACKING_MINOR_LABEL` | `minor-label` | minor 추적 라벨명 |

**호출자 yml 이 참조하지만 install.sh 가 자동 등록하지 않는 변수** (선택 기능 — 필요 시 **수동 등록**):

| 변수명 | input 매핑 | 의미 |
|---|---|---|
| `PIPELINE_PROJECT_OWNER` | `project-owner` | Project v2 소유자 (머지 후 Status=Done 전환용). 미설정 시 호출자 yml 이 빈 값을 넘겨 **머지 후 Status 전환을 스킵**(merge.yml). |
| `PIPELINE_PROJECT_NUMBER` | `project-number` | Project v2 번호 (머지 후 Status=Done 전환용). 위와 동일 — 둘 다 있어야 전환 동작. |

> `slack-channel`(config) 은 **영역 레포 변수(`PIPELINE_SLACK_CHANNEL`)로 등록되지 않는다**.
> 슬랙 채널은 App 쪽 알림 경로 설정(App 환경변수 `SLACK_CHANNEL` — 위 "App 환경변수" 참조)으로
> 흐르며, 리더(`pipeline-config.sh`)의 `slack-channel` 키로도 읽는다.

### App 환경변수

App 인증·자동화 동작 두 그룹.

**인증** — secret 카탈로그와 동일 이름 (GHA secret ↔ App 환경변수 1:1 매핑):

```env
AUTHOR_APP_ID=
AUTHOR_PEM=                # PEM 파일 절대경로 (App 은 파일을 읽음)
AUTHOR_INSTALLATION_ID=
REVIEWER_APP_ID=           # 옵션 (AI 리뷰 미사용 시 비워둠)
REVIEWER_PEM=              # 옵션
REVIEWER_INSTALLATION_ID=  # 옵션
SLACK_WEBHOOK_URL=         # 옵션
WEBHOOK_SECRET=            # GitHub App webhook secret
```

**자동화 동작** — App-내 결정 로직(폴러·핸들러)이 사용:

```env
OWNER=                          # 조직명 (Project v2 폴링 대상)
PROJECT_NUMBERS=[3,5]           # 폴러가 동시 모니터링할 Project v2 번호 배열
MODULES=["Backend","iOS"]       # 영역 모듈 이름 (폴러 dispatch 대상 식별)
MODULES_IGNORE=["Design"]       # sibling 집계 시 제외할 모듈
REVIEWER_BOT_LOGIN=             # Reviewer 봇 로그인 prefix (review 핸들러 검증용)
STATUS_POLLER_INTERVAL_MS=300000  # 폴링 간격 (옵션, 기본 5분)
STATUS_TRIGGERS_KICKOFF=       # 폴러가 kickoff 를 트리거할 Status 컬럼값 (옵션, 기본 "In Progress")
STATUS_TRIGGERS_REVIEW=        # 폴러가 review 를 트리거할 Status 컬럼값 (옵션, 기본 "Bot Review")
```

> `STATUS_TRIGGERS_*` 는 config `project.status-triggers.{kickoff,review}` 에서 온다. **같은 config 키를 두 소비자가 읽어 정렬한다**: (1) App 폴러가 env 로 읽어 dispatch 판정, (2) `/kickoff`·`/review` SKILL 이 리더 친화키 `status-trigger-kickoff`/`status-trigger-review` 로 읽어 sub-issue Status 비교·전환. 둘이 같은 값을 봐야 "폴러 dispatch ↔ SKILL 비교"가 end-to-end 로 맞물린다(컬럼명을 config 에서 바꾸면 양쪽이 함께 따라감). 미설정(빈 값)이면 App·리더 모두 기본 컬럼명으로 폴백 — 컬럼명이 기본과 같은 프로젝트는 설정 없이도 동작한다(이식 안전).
>
> **범위 한계**: config 로 재정의 가능한 건 이 **두 트리거 컬럼**(kickoff=`In Progress`, review=`Bot Review`)뿐이다. `In Review`(리뷰 승인 후 도착 상태)·`Ready`·`Backlog`·`Done` 등 비-트리거 컬럼은 SKILL 에 기본명 고정 — 이 컬럼들을 리네임하는 건 아직 미지원이다(전면 파라미터화는 후속 #115 추적).

**장애 알림 경로** — App 이 장애 알림을 보낼 때 쓰는 설정(전부 옵션). Janus 게이트웨이를 우선하고, 비활성/실패 시 Slack 웹훅으로 폴백한다:

```env
# 활성 조건: 아래 3키가 모두 있으면 Janus 경로 활성, 하나라도 비면 웹훅 폴백.
JANUS_BASE_URL=                 # Janus REST 베이스 URL (컨테이너→호스트: http://host.docker.internal:8700)
JANUS_AUTH_TOKEN=               # Janus Bearer 인증 토큰 (secret 카탈로그에 등재)
JANUS_ALERT_CHANNEL=            # Janus 알림 채널 ID
JANUS_SOURCE_ID=pipeline        # 발신 소스 식별자 (옵션, 기본 "pipeline")
SLACK_WEBHOOK_URL=              # Janus 미설정·실패 시 폴백 웹훅 (secret 카탈로그에 등재)
```

---

## 구조 컨벤션

"어떤 코드를 어디에 둘지" 기준.

| 상황 | 도구 | 위치 |
|---|---|---|
| GitHub 이벤트 받고 다음 단계 결정 (chain 로직) | **App 코드** | `app/src/` |
| GitHub API 복잡하게 다루기 (sub-issue 조회·sibling 추적·GraphQL) | **App 코드** | `app/src/` |
| 영역 레포가 호출하는 단위 작업 (kickoff·review·merge 한 번) | **Reusable workflow** | `.github/workflows/*.yml` |
| 여러 yml에서 반복되는 step 묶음 | **Composite action** | `actions/<name>/action.yml` |
| 단순 쉘 명령 묶음 (Slack 알림·token 발급 등) | **Script** | `scripts/*.sh` |

**기준 한 줄**: 결정하면 App, 실행하면 Reusable workflow, 단계 묶으면 Composite action, 순수 명령이면 Script.

**경계선**:
- token 발급 → Script (순수 쉘 명령)
- Slack 알림 → Script (curl 한 방)
- sub-issue 조회·sibling 추적 → App 코드 (복잡한 상태 판단 포함)
- App과 Script의 경계: GHA 기능(secrets·matrix·outputs) 필요 없고 순수 명령이면 Script

---

## 버전 컨벤션

플러그인 버전 = `plugin/.claude-plugin/plugin.json` 의 `version` (semver `X.Y.Z`).

| 단계 | 의미 | 예시 |
|---|---|---|
| **major** (X) | 호환 깨짐 / 정식 출시 | `0.2.0` → `1.0.0` |
| **minor** (Y) | 기능 추가 (하위호환) | `0.1.0` → `0.2.0` |
| **patch** (Z) | 버그 수정 (하위호환) | `0.1.0` → `0.1.1` |

올릴 때는 손으로 고치지 말고 `bash scripts/bump-version.sh <patch|minor|major>` 로 올린다(version 값만 치환, 나머지 형식 보존). `plugin/` 코드를 바꾼 PR 에서 버전을 안 올리면 CI 의 `version-gate` 잡이 빨강으로 막는다.

---

## 설정 컨벤션

### 설정 파일 형태

**YAML** — GHA와 동일 포맷, 주석 가능, 읽기 쉬움.

### 디렉토리 역할

| 디렉토리 | 역할 | 내용 |
|---|---|---|
| `config/` | 스키마·템플릿 | 빈 껍데기 — 어떤 값을 채워야 하는지 주석으로 안내 |
| `examples/<project>/` | 실제 적용 사례 | 채워진 예시 — 새 프로젝트 이식 시 참고용 |

```
config/
└── pipeline-config.example.yml     # 빈 껍데기 + 항목별 설명 주석

examples/
└── reclip/
    ├── pipeline-config.yml          # Reclip 설정 (채워진 버전)
    └── .github/workflows/           # 영역 레포 호출자 yml 예시
```

### 이식 흐름

1. `config/pipeline-config.example.yml` 복사
2. 자기 프로젝트 값 채워넣기
3. `install.sh`에 파일 경로 전달 → org variables·secrets 자동 등록

### 모듈 동작 플래그 카탈로그 (`modules:` 항목)

슬래시커맨드(`/plan`·`/review`·`/kickoff`)는 모듈 동작을 **하드코딩하지 않고** config의 동작 플래그를
런타임에 읽어 결정한다. 리더(`pipeline-config.sh`)의 `--modules-table`·`--modules-where`·`module.<Name>.<flag>`로 노출.
새 동작 축이 필요하면 yml/SKILL에서 즉흥적으로 만들지 말고 이 카탈로그에 먼저 추가한다.

| 필드 | 타입 | 기본값(미지정) | 의미 |
|---|---|---|---|
| `name` | string | (필수) | 모듈 이름 = 영역 레포명 (`<owner>/<name>`) |
| `role` | string | 빈 값 | **순수 사람용 라벨**(server/client/design/admin). 리더·코드는 읽지 않음 — 동작은 아래 플래그로만 결정 |
| `area-id` | string | 빈 값 → legacy `area-ids.<Name>` 폴백 | Project v2 Area 옵션 ID. kickoff 가 sub-issue Area 세팅에 사용 |
| `planner` | boolean | `true` | `/plan` 이 planner 호출 대상에 포함할지. `false` 면 placeholder 처리 |
| `review` | boolean | `true` | `/review` 대상에 포함할지. `false` 면 리뷰 제외 |
| `kickoff` | boolean | `true` | `/kickoff` 대상에 포함할지. `false` 면 실행 제외 |
| `lead` | boolean | `false` | 선행(먼저 처리) 모듈. `true` 가 2개 이상이면 정의순 직렬 선행 |
| `default-status` | string | `Ready` | kickoff 시 부여할 기본 Project Status (예: `Backlog`) |
| `cross-area-group` | string | 빈 값 | 같은 비어있지 않은 값을 가진 모듈이 2개 이상 선택되면 `/plan` 이 Cross-area 일관성 섹션 추가 |
| `ci-workflow-name` | string | 빈 값 | auto-merge 가 CI pass 확인 시 참조할 워크플로 이름 |
| `strict-review-bot-check` | boolean | `true` | Reviewer 봇 CHANGES_REQUESTED만 차단 기준으로 볼지 |

- **레포 등록 제외**: `modules-ignore`에 있는 모듈은 `modules:`에 있어도 `install.sh`가 레포 등록(secret/variable/yml)·폴러 dispatch에서 제외한다. "config는 알지만 자동화 레포 관리는 안 하는 모듈"(예: Design)을 표현.

### `/plan`·`/kickoff` 동작 키 카탈로그 (`claude-commands:` 항목)

슬래시커맨드(`/plan`·`/kickoff`)가 실행 시 리더(`pipeline-config.sh`)로 읽는 동작 토글·도구 키. 새 동작 키가 필요하면 SKILL 에서 즉흥적으로 만들지 말고 이 카탈로그에 먼저 추가한다. (`.plan` 접미 키는 `/plan` 전용, `claude-commands` 직속 스칼라는 소비 skill 이 개별로 다름 — 의미 열 참조.)

| 키 | 위치 | 타입 | 기본값(미지정) | 의미 |
|---|---|---|---|---|
| `completeness-critic-enabled` | `claude-commands.plan` | boolean | `true` | ③ 완결성 critic on/off |
| `consistency-critic-enabled` | `claude-commands.plan` | boolean | `true` | ⑤ 정합성 critic on/off |
| `consistency-critic-dual-model` | `claude-commands.plan` | boolean | `true` | ⑤ 2차 모델 교차검증 on/off (on 이면 `cross-check-tool` 사용) |
| `contract-doc-enabled` | `claude-commands.plan` | boolean | `true` | ② 영역 간 공유 계약 문서 생성 on/off |
| `cross-check-tool` | `claude-commands` (직속) | string | `codex` | ⑤ plan 교차검증용 외부 도구 CLI 이름 — 범용 `pipeline:ask` 에이전트에 전달됨(교차검증 용도로 best-effort 호출, 미설치·실패 시 스킵). codex 하드코딩 회피용 주입 키. (`pipeline:ask` = 외부 AI CLI 에게 작업을 위임하는 범용 호출 레이어, 옛 oh-my-claudecode:ask 의 Pipeline 자체 대체) |
| `base-branch` | `claude-commands` (직속) | string | `develop` | `/kickoff` 이 PR 생성(`gh pr create --base`)·재개 rebase(`git rebase origin/<base>`) 대상으로 쓰는 base 브랜치. `main` 이 기본인 새 프로젝트로 이식할 때 존재하지 않는 develop 참조 실패를 막는 주입 키. 빈값도 `develop` 로 폴백(항상 비지 않음). `install.sh` 는 파싱하지 않음 — 런타임 리더 전용(3벌 리더 공유 코어) |
| `status-trigger-kickoff` | `project.status-triggers.kickoff` | string | `In Progress` | `/kickoff` 이 처리 대상 sub-issue 를 고르는 Status 컬럼명(G1 대상 판정·lead 게이트·skip 분류). App 폴러 env `STATUS_TRIGGERS_KICKOFF` 와 **같은 config 키**를 읽어 dispatch↔비교를 정렬. 빈값도 기본으로 폴백. 리더 전용(App 은 env 로 별도 수신) |
| `status-trigger-review` | `project.status-triggers.review` | string | `Bot Review` | `/kickoff` 이 PR 생성 후 전환하고 `/review` 가 전환 출발점으로 비교하는 Status 컬럼명. App 폴러 env `STATUS_TRIGGERS_REVIEW` 와 같은 config 키. 빈값도 기본으로 폴백. 리더 전용 |

### 계측 토글 카탈로그 (`claude-commands.metrics:` 항목)

워크플로의 claude 호출 래퍼(`scripts/claude-with-usage.sh`)가 실행 시 리더(`pipeline-config.sh`)로 읽는 계측 토글. `/plan` 토글과 달리 **기본 OFF(opt-in)** — 이식 안전성(새 프로젝트는 계측이 꺼진 상태로 시작)을 위해 install.sh 가 강제하지 않고, 사용자가 config 에 명시할 때만 켜진다.

| 키 | 위치 | 타입 | 기본값(미지정) | 의미 |
|---|---|---|---|---|
| `usage-tracking-enabled` | `claude-commands.metrics` | boolean | `false` | 이슈/PR 1건 처리 시 claude 호출의 시간·토큰·비용을 대상 이슈/PR 코멘트로 박제 on/off. on 이면 kickoff/review/critic/critic-dispatch 의 각 claude 호출이 `📊 usage …` 코멘트를 남긴다(`--output-format stream-json` 의 `result` 이벤트에서 추출). off 면 claude 직접 호출과 100% 동일 동작(코멘트 없음). **추가**: `/plan` 의 단계별 소요시간 계측(§9.7)도 이 토글로 게이트된다 — on 이면 parent 이슈에 `📊 plan timing` 코멘트(단계별 소요시간 표)를 남긴다. off 여도 콘솔 최종 리포트의 시간 표는 항상 출력된다(코멘트만 토글). 계측 자체는 `plugin/skills/plan/scripts/plan-metrics.sh` 가 단계 경계 시각(`date +%s`)을 temp 상태파일(`${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv`)에 기록·집계하며, plan 산출물·dry-run 로컬 문서는 바꾸지 않는다. |

### GraphQL Project v2 식별자 카탈로그 (`claude-commands:` 항목) — 자동조회 대상

`/kickoff`·`/review`·`/plan` 가 GitHub Project v2 를 GraphQL 로 조작(Status·Area 필드 변경)할 때 쓰는 노드 ID 들. 사용자가 알기 어려운 해시값이라 `install.sh` 가 **자동조회**한다.

| 키 | 위치 | 타입 | 의미 |
|---|---|---|---|
| `project-id` | `claude-commands` (직속) | string(`PVT_...`) | Project v2 노드 ID |
| `status-field-id` | `claude-commands` (직속) | string(`PVTSSF_...`) | Project v2 의 `Status` 필드 ID |
| `area-field-id` | `claude-commands` (직속) | string(`PVTSSF_...`) | Project v2 의 `Area` 필드 ID |

**자동조회 동작 ("명시 > 자동 > 실패")** — `install.sh generate_pipeline_config`:

1. config 에 값이 **명시**돼 있으면 그대로 사용(자동조회 스킵, 절대 덮어쓰지 않음).
2. 비어 있고 `project.owner`+`project-numbers[0]` 가 있으면 GraphQL 로 **자동조회**(organization→user 순차 폴백)해 **빈 키만** 채운다. gh 내장 `--jq` 만 사용(외부 `jq` 불필요).
3. 자동조회도 실패(또는 못 찾은 필드)하고 값도 비면 install 시점 self-check 에서 **fail-fast**.

**이식성 주의**: 자동조회는 `Status`·`Area` 라는 표준 필드명만 찾는다. `Status` 는 Project v2 표준이라 거의 항상 있지만, `Area` 는 프로젝트마다 커스텀 필드명일 수 있어 못 찾을 수 있다 → 그 경우 위 표의 `area-field-id` 를 config 에 **수동 명시**(명시가 자동조회보다 우선). 다른 필드명을 본체에 하드코딩하지 않는다.

### install 시점 self-check 필수 키 (`generate_pipeline_config`)

원격쓰기 전 fail-fast 게이트. 리더의 `--require` 로 검증하며, 비면 배치를 중단한다.

| 필수 키 집합 | 조건 |
|---|---|
| `owner` · `project-number` · `project-id` · `status-field-id` · `area-field-id` | 항상(reviewer 사용 여부 무관) |
| + `reviewer-app-id` · `reviewer-bot-slug` · `reviewer-token-key` | `reviewer.enabled: true` 일 때만 조건부 추가 |

> 위 GraphQL 3키는 self-check 전에 자동조회로 채워질 수 있으므로, config 에 비워둬도 자동조회만 성공하면 통과한다.
