# Pipeline 검증 프로토콜

이 문서는 Pipeline의 **이식성**과 **자동화 사이클**이 실제로 작동하는지 *재현 가능하게* 검증하는 절차와, 검증에서 드러난 한계를 기록한다. (Phase 5 산출물)

> 배경: 자동화 회로가 몇 주간 깨진 채 방치된 적이 있다(커밋 시점 검증·테스트·알림 부재). 이 문서는 "조용한 실패"를 막기 위해, 다음 사람이 같은 절차로 재검증할 수 있게 한다.

---

## 1. 환경 분리 원칙

검증은 **운영을 절대 건드리지 않는 별도 sandbox**에서 한다 (CLAUDE.md "환경 분리").

| 환경 | org | App | 용도 |
|---|---|---|---|
| 운영 | 실제 org (예: `MKFactory-Reclip`) | 운영 App 2개 | 실제 자동화 |
| sandbox | 버리는 org (예: `MKFactory-Reclip-Sandbox`) | dev App 2개 (운영 재사용 ✗) | 검증·실험 |

- dev App과 운영 App을 같은 레포에 설치하면 같은 이벤트를 두 번 처리해 충돌 → 반드시 분리.
- install.sh는 `--env-file`/`--port`로 운영 `app/.env`(포트 3000)를 건드리지 않고 dev 환경(`app/.env.sandbox`, 포트 3001)을 만든다.

---

## 2. 시나리오 A — install.sh 이식성  `[✅ 검증됨: 2026-05-30]`

**목표:** 새 프로젝트에 install.sh로 Pipeline을 자동 설치할 수 있는가.

### 사전 준비 (사람 손)
1. 버리는 sandbox **org** 1개 (개인 계정 ✗ — 폴러가 owner 단위로 Project 조회)
2. 더미 레포 2개 (멀티모듈 집계 검증엔 2개면 충분)
3. Project v2 1개
4. dev GitHub App 2개(Author/Reviewer) 등록 → org 설치 → App ID·Installation ID·PEM 확보

### 실행 (비대화형)
```bash
# App 자격을 환경변수로 주입 (secret 은 config 에 넣지 않음)
export AUTHOR_APP_ID=... AUTHOR_PEM=/abs/path/author.pem AUTHOR_INSTALLATION_ID=...
export REVIEWER_APP_ID=... REVIEWER_PEM=/abs/path/reviewer.pem REVIEWER_INSTALLATION_ID=... \
       REVIEWER_BOT_LOGIN='<app-name>[bot]'

# 레포 admin 권한 있는 계정으로 실행
./scripts/install.sh <config.yml> \
  --env-file app/.env.sandbox --port 3001 --non-interactive
```

### 검증 항목 (체크리스트)
- [ ] `rc=0` 으로 완주
- [ ] 운영 `app/.env` 무변경 (`diff app/.env <백업>`)
- [ ] 생성된 `app/.env.sandbox` 의 OWNER/MODULES/PORT 정확, `MODULES=["A","B"]` 형식(공백 없음)
- [ ] 각 영역 레포에 secrets(AUTHOR_*/REVIEWER_*) + variables(PIPELINE_*) 등록됨
- [ ] 각 영역 레포에 호출자 yml 6개 설치, **잔존 placeholder 0개**:
  ```bash
  # 설치된 yml 에 __PIPELINE_REPO__ 등 placeholder 가 남지 않아야 함
  gh api /repos/<org>/<repo>/contents/.github/workflows/<yml> \
    -H "Accept: application/vnd.github.raw" | grep -c "__PIPELINE\|__CI_WORKFLOW"   # → 0
  ```
- [ ] 모듈별 치환 정확 (예: Admin 레포 auto-merge.yml 의 `workflows: ["Admin CI"]`)

### 검증 결과 (2026-05-30, MKFactory-Reclip-Sandbox)
- 완주 rc=0, 운영 .env 무변경 확인.
- Backend/Admin 각 6 secrets + variables + 호출자 yml 6개 설치, 12개 yml **잔존 placeholder 0**.
- 모듈별 치환 정확: Admin `["Admin CI"]`, 리뷰어 로그인 `vars.PIPELINE_REVIEWER_BOT_LOGIN`.
- 이 과정에서 install.sh 버그를 발견·수정 (아래 §4 참조) — **여태 멀티모듈로 끝까지 돈 적이 없었음이 드러남**.

---

## 3. 시나리오 B — full webhook 사이클  `[⏳ 부분 검증]`

**목표:** PR APPROVE → 웹훅 → sibling 집계 → critic dispatch 가 실제로 도는가.

### sandbox 에서 검증 가능한 범위
- **App 의 결정 로직** (DRY_RUN=true): Reviewer 봇 APPROVE → 웹훅 수신 → sibling 집계 → "critic-triggered dispatch 발사 여부" 판단·로그. **이것이 과거 404 로 깨졌던 핵심 경로.**
- App 인증(`createAppAuth` 토큰 발급)은 별도 실측 검증됨 (Author/Reviewer 토큰 발급 + 설치 레포 확인).
- 집계 로직(`aggregateSiblingApprovalStatus`)은 단위 테스트로 커버됨.

### sandbox 에서 검증 **불가**한 범위 (한계 — §5)
- App 이 dispatch 를 실발사(DRY_RUN=false)한 뒤의 **GHA executor 단계(`/review` 실행)** 는 sandbox 에서 안 됨:
  - `/review`·`/kickoff` 슬래시 커맨드(Reclip 워크스페이스 `review.md`)가 **org 를 하드코딩** → sandbox org 를 못 가리킴.
  - sandbox org 에 **self-hosted 러너 없음**.
- 따라서 실제 `/review` 실행 검증은 **운영 사용 중 확인**한다.

### 재현 방법 (DRY_RUN replay — 터널 불필요)
1. sandbox 에 parent 이슈 + sub-issue 2개 + PR 2개 생성, Reviewer 봇으로 둘 다 APPROVE.
2. dev 컨테이너를 `app/.env.sandbox`(DRY_RUN=true, 포트 3001)로 기동.
3. `pull_request_review.submitted`(APPROVE) 페이로드를 `probot receive` 로 재생.
4. App 로그에서 집계 결과 + "DRY_RUN — dispatch 발사 skip" 확인.

---

## 4. 종속성 제로 — 발견·수정한 위반 (Scenario A 부산물)

install.sh 를 실제로 돌려 드러난 버그·위반 (전부 수정 완료):

| 항목 | 내용 | 커밋 |
|---|---|---|
| eval 버그 | parse_config 의 JSON 배열 emit 이 따옴표 없이 나가 `eval` 이 공백에서 깨짐 (멀티모듈 install 불가의 원인) | `a2745e8` |
| 인자 검증 | `--env-file`/`--port` 값 누락·플래그 흡수 시 침묵 실패 | `a2745e8` |
| Admin 하드코딩 | `[ "$MOD_NAME" = "Admin" ]` → 모듈별 `strict-review-bot-check` config | `1310a20` |
| 호출자 yml 고정 | `examples/reclip` 출처 + `j2enty/Pipeline@main` + `"Backend CI"` + `'reclip-review-bot'` 하드코딩 → 제네릭 템플릿(`templates/caller-workflows/`) + config 주입/vars 참조 | `2be98e4` |
| organization() 고정 | Project v2 조회가 org 전용 → `repositoryOwner{ ... on ProjectV2Owner }` (org/user 둘 다) | `ab23250` |

> organization→repositoryOwner 는 reclip org project#3 실측으로 하위호환 확인 (old 33개 == new 33개).

---

## 5. 알려진 한계 / 후속 작업

| 한계 | 영향 | 소관 |
|---|---|---|
| `review.md`(/review·/kickoff)가 org·레포 하드코딩 | sandbox 에서 GHA 실행 단계 e2e 불가 | Reclip 워크스페이스 (Pipeline 외) |
| sandbox org 에 self-hosted 러너 없음 | GHA 호출자 실행 검증 불가 | sandbox 운영 시 러너 등록 필요 |
| dev App 권한에 Projects 누락 | 폴러가 Project v2 조회 시 `NOT_FOUND`. (운영 App 실제 권한 조회로 확인: Author=`organization_projects:write`, README 목록엔 빠져있었음.) | ✅ `app/README.md` 정정 완료 (Author: Organization→Projects R&W + Actions:Read, Reviewer: Contents:Read 추가). 기존 sandbox dev App 은 생성 시 빠뜨려서 *폴러* 사용 시 권한 추가 필요 — 단 Scenario B webhook replay 는 폴러 불필요 |
| CI 이름 없는 모듈(`ci-workflow-name: ""`) | auto-merge 의 `workflow_run.workflows: [""]` 로 비활성 (단 `pull_request_review` 트리거로 머지는 동작) | 기능 회귀 아님 — 필요 시 조건부 트리거 검토 |

---

## 6. 검증 이력

- 2026-05-30: Scenario A 검증 완료 (MKFactory-Reclip-Sandbox). install.sh 멀티환경·비대화형화 + 종속성 제로 위반 3종 수정. 커밋 `a2745e8`·`1310a20`·`2be98e4`·`ab23250`.
- Scenario B: App 인증·집계 로직 검증됨. DRY_RUN replay 사이클은 미실행(설정 준비됨).
