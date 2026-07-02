# Pipeline 아키텍처 레퍼런스

> CLAUDE.md에서 분리한 **참조 문서**. 매 세션 로드되지 않으며, 다음 작업 시 펴본다:
> 디렉토리 구조 파악 · App/yml/이식 메커니즘 설계 이해 · 배포·운영 환경 작업 · 운영 결정 배경 확인.

## 디렉토리 구조

```
Pipeline/
├── .claude-plugin/         # 마켓플레이스 카탈로그 (레포 루트)
│   └── marketplace.json    # 자체 마켓플레이스 (source: ./plugin)
├── plugin/                 # ★ 플러그인 루트 (격리 — 설치 시 이 디렉토리만 실림)
│   ├── .claude-plugin/
│   │   └── plugin.json     # 플러그인 정의 (name: pipeline)
│   ├── agents/             # 플러그인 일꾼 에이전트 (pipeline:critic·planner 등)
│   └── skills/             # 플러그인 슬래시커맨드(skill — plan·kickoff·review)
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
        ├── pipeline-config.yml      # 모듈 리스트·프로젝트 번호 등
        └── .github/workflows/      # 영역 레포에 설치할 호출자 yml 예시
```

- 본체 = `.claude-plugin/` + `plugin/`(= `agents/` + `skills/`) + `app/` + `.github/workflows/` + `actions/` + `scripts/`
- **플러그인 격리**: 플러그인 루트는 `plugin/`. 마켓플레이스(`.claude-plugin/marketplace.json`)는
  레포 루트에 남아 `./plugin` 을 카탈로그한다. 레포 루트 CLAUDE.md 가 플러그인 루트 밖이라
  설치 시 딸려가지 않고, `claude plugin validate plugin/ --strict` 도 깨끗하다. 로드: `claude --plugin-dir plugin`
- `plugin/agents/`·`plugin/skills/` 는 Claude Code 플러그인 컴포넌트. 외부 오케스트레이터(자동 조율 레이어)
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

### self-hosted 러너 사전 요구사항

`review.yml`의 fix-loop는 claude 호출이 멈추지 않도록 **step 단위** `timeout`/`gtimeout`(#20 hung 방지)으로 감싼다. (`kickoff`·`critic`·`critic-dispatch` 워크플로는 `TIMEOUT_CMD`를 쓰지 않고 job-level `timeout-minutes`로 hung을 막으므로 coreutils가 필요 없다.) 러너 OS별:

- **macOS**: 기본 `timeout`이 없으므로 `brew install coreutils`(→ `gtimeout`) 필요. **미설치 시 review 워크플로가 claude 호출 전 `TIMEOUT_CMD` 결정에서 실패**한다 — `install.sh` 실행 시점이 아니라 **러너에서 워크플로가 도는 시점**에 워크플로 에러로 드러난다.
- **Linux**: 대부분의 배포판은 `timeout`(coreutils)이 기본 포함 — 단 BusyBox 등 최소/커스텀 이미지는 별도 설치가 필요할 수 있다.
- `claude` CLI와 Pipeline 플러그인은 워크플로의 `ensure-plugin`(`scripts/ensure-plugin-installed.sh`)이 매 실행 설치 — 러너엔 `claude` CLI만 사전 설치돼 있으면 된다.

`install.sh`의 `check_requirements`가 `timeout`/`gtimeout` 부재를 경고로 안내한다(중단 안 함). 단 이 체크는 **install 머신 기준**이라(install≠러너일 수 있음), 실제 요구는 review가 도는 러너 OS임에 유의.

#### 러너 config 격리 — 인터랙티브 세션과 디커플 (이슈 #96)

러너가 개발자 머신과 **같은 사용자로 같은 `~/.claude`(user scope)** 를 공유하면, 러너의 매-실행 플러그인 재설치가 `pipeline` 마켓플레이스를 자기 체크아웃 폴더(detached SHA, 냉동)로 되돌려 **인터랙티브 `/pipeline:*` 가 옛 버전에 묶인다**(같은 마켓플레이스명·플러그인명·버전이라 캐시까지 공유 — 로컬 전용 우회 불가). 프론트로 치면, 자동화(CI)와 사람이 같은 전역 `node_modules` 를 공유해 CI 가 매 실행 특정 커밋 버전으로 되돌려버리는 상황.

**해법(방향 A)**: 러너에 **전용 `CLAUDE_CONFIG_DIR`** 를 부여해 레지스트리·캐시·enable 상태를 인터랙티브 기본 `~/.claude` 와 완전히 분리한다. `install.sh` 가 자동 세팅한다:

- `install.sh --runner-root <러너 디렉토리>` → 격리 config dir 프로비저닝(인증은 `~/.claude/.credentials.json` **심링크** — 토큰 회전에도 최신 유지, 원본 불변 + `oauthAccount` 만 최소 `.claude.json` 으로 복사) + `<러너>/.env` 에 `CLAUDE_CONFIG_DIR` 기록. 러너는 `.env` 를 읽어 모든 job 에 이 값을 주입하므로 러너의 모든 `claude` 호출이 격리 dir 을 쓴다.
- `install.sh --install-local-plugin` → 인터랙티브 기본 `~/.claude` 의 `pipeline` 마켓플레이스를 **개발 레포**(main 추적)로 재배선. 러너가 더는 기본 `~/.claude` 를 안 건드리므로 유지된다.
- **적용 조건**: `.env` 변경은 러너 서비스 **재시작** 후 적용(GHA self-hosted 러너 특성). 재시작 전까진 러너가 기본 `~/.claude` 를 계속 사용한다.

세부 플래그·`.env` 키 카탈로그는 `docs/conventions.md` "러너 격리" 섹션 참조. 인증 동작 자체(격리 dir 로 `claude -p` 통과)는 실 러너에서만 최종 검증 가능하다.

### 환경 분리 — 운영 App / 개발 App

| 환경 | GitHub App entity | install 대상 | 목적 |
|---|---|---|---|
| 운영 | 운영용 App | 진짜 모듈 레포 (Backend·Admin·iOS 등) | 실제 자동화 작동 |
| 개발 | 개발용 App | sandbox 레포 (`<org>-Sandbox/<module>` 등) | 코드 수정·테스트 |

- 두 App은 **서로 다른 GitHub 데이터**를 봄 — 같은 레포에 둘 다 install하면 같은 이벤트 두 번 처리되어 충돌
- 개발 흐름: 맥미니에서 코드 수정 → sandbox 레포에서 동작 확인 → 운영 배포
- 운영 버그 디버깅: 운영 webhook payload 캡처 → 맥미니에서 재생 → 디버깅 → 수정 후 재배포
- **데이터 동기화 불필요** — GitHub이 데이터 소유, App은 이벤트 처리만 함

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

## 비-목표 (스코프 경계 — 새 기능 검토 시 참조)

- 특정 프로젝트 전용 자동화 (Reclip은 첫 적용 사례일 뿐 — 종속성 제로 원칙으로 강제)
- 비즈니스 로직 (각 프로젝트 레포 소관)
- 백오피스 / 관리 UI
