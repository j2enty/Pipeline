# Pipeline

이식 가능한 AI 자동화 파이프라인 프레임워크.


## 정체성

AI 에이전트(Claude Code 등)와 GitHub Actions·GitHub App을 연결해서 개발 워크플로 — 기획·실행·리뷰·머지 — 를 자동화하는 도구 모음.

이 레포의 본질적 가치는 **재사용 가능한 자산**이라는 점이다. 첫 적용 대상은 Reclip 프로젝트지만, 다른 어떤 프로젝트에도 그대로 이식 가능해야 한다. 장기적으로 오픈소스화 가능성을 염두에 둔다.


## 최종 목표 — 이식 UX

**새 프로젝트에 5분 안에 Pipeline 전체를 적용 가능해야 한다.**

이상적인 이식 UX:

```bash
./scripts/install.sh --project BlueProject --org BlueOrg --modules Backend,Admin,iOS
```

사용자 액션:
1. 명령 실행
2. 출력된 GitHub App Manifest URL 클릭 (Author 봇·Reviewer 봇 등록 — 각 1회)
3. 끝

자동 처리되는 것:
- App 등록 후 PEM·App ID·Installation ID 자동 수신 → org secrets 자동 등록
- App 코드 배포 (`docker compose up -d` 또는 `wrangler deploy`)
- 영역 레포에 호출자 yml 자동 PR로 설치
- org variables (`OWNER`, `PROJECT_NUMBER`, `MODULES_IGNORE` 등) 자동 등록

이 목표를 달성하지 못하면 Pipeline은 자산이 아니라 **Reclip 전용 자동화**일 뿐이다.


## 큰 결정 체크리스트 (강제)

새 기능·변경·아키텍처 결정 시 다음 4가지를 **반드시 검토**한다. 하나라도 답이 부정적이면 결정을 보류하거나 재설계한다.

1. **이식 UX 영향** — 이 결정이 `install.sh`에서 자동화 가능한가? 새 수동 단계를 만들지는 않는가?
2. **사용자 클릭 수** — 새 프로젝트 적용 시 사용자 클릭이 늘어나는가? (목표: App 등록 2회 클릭이 전부)
3. **본체 종속성** — 본체 코드(`app/`, `.github/workflows/`, `scripts/`)에 프로젝트 식별자가 들어가는가? (들어가면 즉시 거부)
4. **5분 적용 목표** — 이 결정이 최종 목표(5분 적용)를 해치는가?

이 체크리스트는 모든 큰 결정에서 **명시적으로 평가**되어야 하며, CLAUDE.md의 다른 어떤 룰보다 우선한다.


## 작업 프로토콜 (강제)

Pipeline은 자동화 인프라라 버그 1건의 파급이 크다(잘못된 레포에 이슈, 잘못된 PR 머지 등). **보수적으로** 접근한다. 다음 3원칙을 모든 Pipeline 작업에 적용한다.

1. **플랜 우선** — 어떤 과제든 먼저 플랜을 잡고 진행한다. (단 진짜 사소해서 플랜이 오버인 경우만 스킵 가능)
2. **단계별 테스트 게이트** — 플랜의 각 Phase/Step마다 안전한 테스트케이스를 만들고, **그 통과를 다음 단계로 넘어가는 조건**으로 삼는다. "구현했다"가 아니라 "테스트가 통과했다"가 단계 종료 기준이다. 라이브로만 드러나는 것(GHA checkout 컨텍스트, self-hosted 동시성, 상태파일 경합 등)도 "나중에 확인"으로 미루지 말고 가능한 테스트 게이트를 만든다.
3. **Claude + Codex 이중 코드리뷰** — 코드량이 적어도, 하나의 플랜이 끝나고 **PR 이후에는 반드시 Claude와 Codex 둘 다** 코드리뷰를 돌린다(`omc ask codex`로 교차검증). 정합성 검증(verifier)만으론 부족하며, 적대적 코드리뷰 + 모델 교차가 필수다.

> 근거: 정합성 검증만 한 Claude 리뷰가 "통과"라 한 코드를 Codex 교차검증이 치명 버그까지 잡아낸 사례가 있다(2026-05-30 Phase 3). 단일 모델 리뷰는 과신이다.


## 핵심 원칙

### 1. 프로젝트 종속성 제로

본체 코드(`app/`, `.github/workflows/`, `actions/`, `scripts/`)에는 **어떠한 특정 프로젝트 식별자도 하드코딩하지 않는다**.

- 레포 owner / 레포명
- GitHub App ID, Installation ID
- 토큰 이름 (`RECLIP_*` 같은 prefix 금지)
- 슬랙 채널, 알림 대상
- 모듈 이름 (`Backend`, `iOS` 등)

이 모든 값은 **외부 설정**(env, secrets, org variables, config 파일)으로 주입받는다. 새 프로젝트로 이식할 때 바꿔야 할 것은 설정값뿐이어야 한다.

### 2. 한 곳에서 전체 파이프라인 가시성

App 코드와 GHA workflow를 한 레포(Pipeline)에서 본다. yml 디렉토리 트리는 깊이 1단계로 유지. 클릭 한 번으로 전체 파이프라인 구조 파악 가능해야 한다.

### 3. 각 yml = 하나의 동작

한 yml 파일에 여러 동작을 욱여넣지 않는다. yml은 단순 executor로만 작동.

- 동작 추가 = 새 yml 추가
- 파일명 컨벤션: `<동작>-<대상>.yml` (예: `auto-kickoff.yml`, `auto-review.yml`)
- chain 로직은 yml이 아니라 **App 안**에 있다 (yml은 호출만 받음)

### 4. 공통 로직은 reusable로

- 반복되는 job → **reusable workflow** (`workflow_call`)
- 반복되는 step → **composite action** (`actions/`)
- 반복되는 쉘 로직 → `scripts/` 단일 파일
- 반복되는 App 로직 → App 내부 함수

### 5. 한 yml은 한 가지만 한다

트리거(`on:`)와 동작(`jobs:`)이 1:1이 안 되면 yml을 쪼갠다. "이 워크플로는 무엇을 하는가"에 한 문장으로 답할 수 없으면 분리.


## 디렉토리 구조

```
Pipeline/
├── .claude-plugin/         # 플러그인 매니페스트 (레포 = 플러그인 = 마켓플레이스)
│   ├── plugin.json         # 플러그인 정의 (name: pipeline)
│   └── marketplace.json    # 자체 마켓플레이스 (source: ./)
├── agents/                 # 플러그인 일꾼 에이전트 (pipeline:critic·planner 등)
├── skills/                 # 플러그인 슬래시커맨드(skill) — P2 예정 (명령어 이전)
├── app/                    # GitHub App 코드 (webhook 수신 + chain orchestrator)
│   ├── src/                # App 본체 — 일반화된 코드
│   ├── Dockerfile          # 표준 배포 단위
│   ├── .env.example        # 필요한 환경변수 명세
│   └── README.md           # App 등록·배포 가이드
├── .github/workflows/      # GHA executor (App이 호출하는 단순 작업 단위)
├── actions/                # composite actions (재사용 step)
├── scripts/                # yml·App에서 호출하는 헬퍼 + install.sh
├── config/                 # 프로젝트별 설정 스키마·템플릿
└── examples/               # 적용 사례 (Reclip 등)
    └── <project>/
        ├── app-config.yml          # 모듈 리스트·프로젝트 번호 등
        └── .github/workflows/      # 영역 레포에 설치할 호출자 yml 예시
```

- 본체 = `.claude-plugin/` + `agents/` (+예정 `skills/`) + `app/` + `.github/workflows/` + `actions/` + `scripts/`
- `agents/`·`skills/` 는 Claude Code 플러그인 컴포넌트. OMC 등 외부 오케스트레이터
  없이도 `pipeline:*` 일꾼이 따라오게 하는 자산 — 프로젝트 식별자 하드코딩 금지 동일 적용
- 프로젝트별 설정·예시는 `examples/`로 격리


## 이식 메커니즘

### 아키텍처: App-native

GitHub App을 **이벤트 수신기 + chain orchestrator**로 사용한다. 단순 토큰 발급기로 격하시키지 않는다.

```
GitHub event → App webhook 수신 → chain 로직 → repository_dispatch → GHA executor yml
                                              ↘ GitHub API 직접 호출
```

- App = chain 로직의 본체 (코드로 표현, 가시성 ↑)
- yml = 단순 executor (한 작업 단위, App이 트리거)
- 폴러 불필요 (실시간 webhook)

### 영역 레포의 yml 형태

영역 레포는 Pipeline의 reusable workflow를 호출만 한다. 얇은 호출자 yml:

```yaml
# 영역 레포의 .github/workflows/auto-kickoff.yml (호출자)
on:
  repository_dispatch: { types: [kickoff-triggered] }
jobs:
  kickoff:
    uses: <Pipeline-org>/Pipeline/.github/workflows/auto-kickoff.yml@<ref>
    with:
      module: ${{ vars.PIPELINE_MODULE }}
      owner: ${{ vars.PIPELINE_OWNER }}
      # 기타 input은 호출자 yml에 명시
    secrets: inherit
```

### 진화 경로

| Phase | 형태 | 적용 시점 |
|---|---|---|
| Phase 1 | Single-tenant App + `@main` | 현재 — Reclip 단독, 빠른 반복 |
| Phase 2 | `install.sh` 자동화 완성 + `@v1.0` 버전 핀 | Pipeline 안정화 — 5분 이식 가능해진 시점 |
| Phase 3 | (선택) Multi-tenant App / 오픈소스 배포 | 같은 App 인스턴스가 여러 프로젝트 처리, 또는 외부 사용자 갖다 씀 |

Phase 2가 사실상 최종 형태일 가능성이 높음. Phase 3는 운영자가 여러 명 또는 외부 사용자 등장 시점에 검토.


## 운영 환경

### App 스택

- **언어/프레임워크**: Probot (Node.js / TypeScript)
- **선택 근거**: GitHub 공식 후원, GitHub App 분야 표준 프레임워크. 외부인이 봐도 즉시 이해 가능 — 오픈소스화 친화적
- 어려운 부분(웹훅 서명 검증·인증·재시도)을 추상화해서 핵심 자동화 로직만 작성 가능

### 배포

- **패키징**: Docker 이미지 — 어디서든 같은 이미지로 배포 가능
- **첫 배포 위치**: 맥미니 (이미 24/7 가동 중, 추가 비용 0)
- **미래 배포 옵션**: VPS / Render / Fly.io / AWS Lambda — Docker 표준 패키징이라 코드 수정 없이 이전 가능. (Cloudflare Worker만 다른 패러다임이라 어댑터 필요)
- `install.sh`는 `docker compose up -d` 한 줄로 띄움 (5분 이식 UX 목표 부합)

### 환경 분리 — 운영 App / 개발 App

| 환경 | GitHub App entity | install 대상 | 목적 |
|---|---|---|---|
| 운영 | 운영용 App | 진짜 모듈 레포 (Backend·Admin·iOS 등) | 실제 자동화 작동 |
| 개발 | 개발용 App | sandbox 레포 (`<org>-Sandbox/<module>` 등) | 코드 수정·테스트 |

- 두 App은 **서로 다른 GitHub 데이터**를 봄 — 같은 레포에 둘 다 install하면 같은 이벤트 두 번 처리되어 충돌
- 개발 흐름: 맥미니에서 코드 수정 → sandbox 레포에서 동작 확인 → 운영 배포
- 운영 버그 디버깅: 운영 webhook payload 캡처 → 맥미니에서 재생 → 디버깅 → 수정 후 재배포
- **데이터 동기화 불필요** — GitHub이 데이터 소유, App은 이벤트 처리만 함


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
| `verdict-state-dir` | string | critic yml | verdict 상태 파일 디렉토리 (예: `.omc/state/reviews`) |
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
| `SLACK_WEBHOOK_URL` | 옵션 | 슬랙 인커밍 웹훅 — 미설정 시 알림 자동 스킵 |

옵셔널 동작:
- Reviewer secret 미설정 + AI 리뷰 yml 미호출 → 정상 (사람이 리뷰하는 일반 자동화)
- Reviewer secret 미설정 + AI 리뷰 yml 호출 → secret 누락으로 적절히 fail
- Slack webhook 미설정 → notify 스크립트 자동 스킵

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


## 명명 컨벤션

### yml 파일명

| 위치 | 패턴 | 예시 |
|---|---|---|
| Pipeline 본체 `.github/workflows/` | `<동작>.yml` (prefix 없음) | `kickoff.yml`, `review.yml`, `merge.yml`, `critic.yml`, `critic-dispatch.yml`, `parent-autoclose.yml` |
| 영역 레포 호출자 `.github/workflows/` | `auto-<동작>.yml` (권장, Pipeline이 강제 안 함) | `auto-kickoff.yml`, `auto-review.yml` |

- Pipeline 본체는 자동화 yml만 있어서 prefix redundant
- 영역 레포는 `ci.yml` 같은 일반 CI yml과 공존하므로 구분 위해 `auto-` prefix 권장

### Org Variables

`PIPELINE_*` prefix 사용. 이름 확정 후 일괄 치환 가능 (grep + find & replace).

| 변수명 | input 매핑 | 의미 |
|---|---|---|
| `PIPELINE_OWNER` | `owner` | GitHub 조직명 |
| `PIPELINE_PARENT_REPOSITORY` | `parent-repository` | `<owner>/<repo>` |
| `PIPELINE_MODULES_IGNORE` | `modules-ignore` | 제외 모듈 JSON 배열 |
| `PIPELINE_WORKING_DIRECTORY` | `working-directory` | runner 작업 경로 |
| `PIPELINE_SLACK_CHANNEL` | `slack-channel` | 슬랙 채널 |
| `PIPELINE_REVIEWER_BOT_LOGIN` | `reviewer-bot-login` | Reviewer 봇 로그인 이름 (예: `review-bot[bot]`) |
| `PIPELINE_VERDICT_DIR` | `verdict-state-dir` | critic verdict 상태 파일 디렉토리 |
| `PIPELINE_PROJECT_OWNER` | `project-owner` | Project v2 소유자 (머지 후 Status=Done 전환용) |
| `PIPELINE_PROJECT_NUMBER` | `project-number` | Project v2 번호 (머지 후 Status=Done 전환용) |
| `PIPELINE_TRACKING_ENABLED` | `tracking-enabled` | finding 추적 on/off |
| `PIPELINE_TRACKING_MAJOR_LABEL` | `major-label` | major 추적 라벨명 |
| `PIPELINE_TRACKING_MINOR_LABEL` | `minor-label` | minor 추적 라벨명 |

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
```


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


## 동작 컨벤션

### 로깅

- Probot 기본 로거 사용 (`app.log.info()`, `app.log.warn()`, `app.log.error()`)
- 구조화된 JSON 포맷 — 운영 서버에서 파싱·모니터링 용이
- 레벨 기준: DEBUG(개발), INFO(정상 흐름), WARN(비정상이지만 처리 가능), ERROR(처리 실패)

### 에러 처리

- 예상된 에러 (rate limit·timeout·일시적 API 오류) → 재시도
- 예상치 못한 에러 (파싱 실패·권한 없음 등) → 즉시 에스컬레이션
- GHA yml 실패 → App이 결과 수신 후 판단 (재시도 vs 에스컬레이션)

### 재시도 정책

- 최대 **3회**, 지수 백오프 (1초 → 2초 → 4초)
- GHA yml: `retry-on-failure: 3`
- App: Probot 내장 retry 또는 직접 구현

### 에스컬레이션

| 트리거 | 자동 액션 |
|---|---|
| 재시도 3회 전부 실패 | 슬랙 알림(옵션) + GitHub 이슈 자동 생성 |
| critic 결과 `escalated` | 슬랙 알림(옵션) + 백로그 이슈 자동 생성 |
| 사람 판단 필요 | 슬랙 + 해당 이슈에 코멘트 |

- 슬랙 알림은 `SLACK_WEBHOOK_URL` 미설정 시 자동 스킵 (파이프라인 전체는 정상 진행)
- GitHub 이슈 생성은 항상 수행 (영구 기록 목적)


## 운영 결정 사항

### secrets/variables 등록 방식 — 레포별 직접 등록 (org-level 아님)

**결정**: org-level secrets/variables 대신 각 영역 레포에 직접 Repository secrets/variables 등록.

**이유**:
- MKFactory-Reclip org가 GitHub Free 플랜
- Free 플랜에서 org secrets/variables는 **Private 레포에 적용 불가** (Public 레포에만 가능)
- 영역 레포(Backend·Admin·iOS 등)는 소스 코드 보호를 위해 Private 유지 필요
- Public 전환 시 비즈니스 로직·API 설계 전체 노출 → 채택 불가

**해결**: `install.sh`가 `gh secret set` / `gh variable set` CLI 명령어로 각 레포에 일괄 자동 등록.
새 프로젝트 이식 시에도 동일하게 재사용 가능 — org 플랜과 무관하게 작동.

**만약 향후 org 플랜 업그레이드 시**: `install.sh`에서 `--repo` 루프 대신 `--org` 한 번으로 교체 가능. 코드 변경 최소화.


## 비-목표

- 특정 프로젝트 전용 자동화 (Reclip은 첫 적용 사례일 뿐)
- 비즈니스 로직 (각 프로젝트 레포 소관)
- 백오피스 / 관리 UI


## 첫 적용 사례

Reclip 프로젝트(상위 워크스페이스). Reclip에서 학습한 패턴을 일반화해서 본체에 반영하고, Reclip 전용 설정은 `examples/reclip/` 또는 외부 secrets로만 둔다.

본체 코드에 Reclip 식별자가 들어가는 순간, 즉시 추출해서 일반화한다. **"이 프로젝트를 위해 만든 코드"는 본체에 들어갈 자격이 없다.**


## 규칙

- 모든 문서·주석·커밋은 한국어
- 커밋 메시지 prefix: `[App]`, `[워크플로]`, `[액션]`, `[스크립트]`, `[설정]`, `[플러그인]`, `[문서]`, `[기타]`
  - `[플러그인]` = `.claude-plugin/`·`agents/`·`skills/` 등 Claude Code 플러그인 컴포넌트 작업
- 새 yml 추가 시 — 다른 yml과 중복되는 로직이 있는지 먼저 확인. 있으면 reusable로 먼저 빼고 나서 yml 추가
- 본체 코드(`/.claude-plugin/`, `/agents/`, `/skills/`, `/app/`, `/.github/workflows/`, `/actions/`, `/scripts/`)에 프로젝트 식별자 하드코딩 시도 시 — 즉시 거부하고 설정 주입 방식으로 변경
- 새 input/secret/output — 표준 카탈로그에 먼저 추가, yml 내에서 즉흥적으로 새 이름 만들지 않음
- 큰 결정 시 — "큰 결정 체크리스트" 4항목을 명시적으로 평가


## 작업 추적 (강제) — 할 일은 GitHub 이슈로

**모든 할 일(기능·버그·후속과제·아이디어)은 GitHub 이슈로 등록한다. 자동 메모리(`~/.claude/.../memory/`)에 "할 일 목록·다음 단계·큐잉"을 넣지 않는다.** (메모리는 보기·관리가 어려워 추적에 부적합 — 사용자 지시 2026-06-03.)

- **등록 레포**: `j2enty/Pipeline` (Pipeline 프레임워크 작업 기준).
- **라벨로 카테고라이징** (여러 개 병용 가능):
  | 라벨 | 의미 |
  |---|---|
  | `epic` | 여러 단계로 쪼개지는 큰 작업(상위 추적) |
  | `plugin` | Pipeline 자체 플러그인화 / OMC 탈종속 |
  | `portability` | 종속성 제로·이식성 |
  | `test` | 테스트·골든픽스처·검증 |
  | `slack` | Slack 통합 |
  | `deferred` | 지금 안 함 — 보류/조건부 |
  | `idea` | 미확정 아이디어·백로그 |
  | `enhancement`/`bug`/`documentation` | 기본 GitHub 라벨 |
- **제목 prefix**(기존 컨벤션): `[기능]`, `[버그]`, `[백로그]`, `[문서]`, `[기타]` 등 한국어.
- **메모리에 남기는 것**: 작업방식 선호(feedback)·사용자 배경·확정 설계결정·외부 참조 같은 *배경/맥락*만. **진행상황·다음 할 일은 이슈/PR/git 히스토리로** 추적한다.
- 작업 착수 시 해당 이슈를 참조하고, 완료 시 PR에서 `Closes #N`으로 닫는다.
