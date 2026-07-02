---
description: /kickoff 또는 수동으로 생성된 PR을 code-reviewer+verifier로 리뷰하고 GitHub Review 판정·코멘트까지 수행
argument-hint: <pr-url-or-parent-issue-url-or-number> [--restart] [--bot] [--codex] [--critic-only]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, AskUserQuestion
disable-model-invocation: true
---

<!-- 이 skill 의 프로젝트값(owner·project-id·리뷰어봇·토큰키 등)은 설치 시 치환이 아니라
     실행 시 .claude/pipeline-config.yml 에서 읽는다. 코드펜스는 scripts/pipeline-config.sh
     리더로 값을 주입하고, 프로즈는 아래 "프로젝트 설정 (실행시 주입)" 블록을 참조한다.
     사람이 /pipeline:review 로만 호출한다 (모델 자동호출 차단).
     민감 4키(reviewer-app-id·reviewer-bot-slug·reviewer-token-key·slack-token-key)는
     --dump 에 노출하지 않으므로 코드펜스에서 개별 키 읽기로만 가져온다. -->

# /review — PR 리뷰 파이프라인

`/kickoff` 또는 수동으로 만들어진 PR을 받아 **code-reviewer**(품질) + **verifier**(플랜 준수) Agent로 검토하고 GitHub Review(APPROVE / REQUEST_CHANGES)로 판정해요. Parent issue 모드에서는 **선행(lead) 영역 먼저 → 나머지 병렬 → critic 종합 리뷰**로 하이브리드 실행해요. APPROVE 판정된 PR의 sub-issue는 Prep Project Status를 **Bot Review → In Review** 로 전환해 사용자 hands-on 검증 단계로 넘겨요.

## 프로젝트 설정 (실행시 주입)

아래는 이 프로젝트의 실제 설정값이다. 프로즈·제목·Agent 프롬프트에서 `프로젝트명`·`org`·`대표 레포`·Project ID 등을 언급할 때는 이 값을 쓴다 (하드코딩 금지 — 전부 config 런타임 읽기).

!`bash "${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh" --dump 2>/dev/null || echo "(config 없음)"`

> **민감 4키는 --dump 에 없다** (보안 결정): `reviewer-app-id`·`reviewer-bot-slug`·`reviewer-token-key`·`slack-token-key` 는 식별성이 높아 LLM 컨텍스트에 통째로 흘리지 않는다. 필요한 펜스에서 개별 키 읽기(`$(bash "$CFG" reviewer-token-key)`)로만 가져온다.

## 사용법

```
/review <pr-url>                         # 단일 PR 모드
/review <pr-number>                      # 단일 PR 모드 (번호만 — 영역 레포 지정 필요)
/review <parent-issue-url>               # parent 모드 (parent의 모든 영역 PR 리뷰)
/review <parent-issue-number>            # parent 모드 (대표 레포 기준)
/review <url-or-number> --restart        # 상태 파일 무시, 처음부터 재리뷰
```

예 (`<owner>`·`<parent-repo-name>`·`<영역>` 은 위 주입된 설정값/모듈명):
- `/review https://github.com/<owner>/<영역>/pull/2`
- `/review https://github.com/<owner>/<parent-repo-name>/issues/2`
- `/review 2` (parent issue 2 기준 parent 모드)
- `/review 2 --restart`

## 사전 조건

- 로컬 `gh auth status` 통과
- 단일 PR 모드에서 번호만 주는 경우: **영역 레포명을 URL 형태로 주는 것 권장** (번호만은 모호)
- Parent 모드:
  - parent 이슈가 **OPEN** 상태
  - 해당 parent의 sub-issue에 연결된 PR이 1건 이상 존재 (open, non-draft)
- Docs 레포가 `Docs/` 하위에 있으면 플랜 materialize·Context md 갱신에 사용 (없으면 자동 스킵 — Docs 미사용 프로젝트도 지원)

## 상수

이 섹션의 상수(Org·대표 레포·Project 번호·Project ID·Status 필드 ID 등)는 **실행 시 config에서 읽는다** — 위 "프로젝트 설정 (실행시 주입)" 블록의 `--dump` 출력을 참조한다. 코드펜스에서는 아래 패턴으로 직접 읽어 주입한다:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
bash "$CFG" owner              # Org
bash "$CFG" parent-repo-name   # 대표 레포
bash "$CFG" project-number     # Prep Project 번호
bash "$CFG" project-id         # Prep Project ID
bash "$CFG" status-field-id    # Status 필드 ID (Backlog/Planning/Ready/In Progress/Bot Review/In Review/Done)
bash "$CFG" docs-context-dir   # Context md 디렉토리 (parent 모드 한정)
```

| 이름 | 값 |
|---|---|
| Base 브랜치 | `develop` (PR 대상 대부분 — 다를 경우 R2 minor gap 적용) |
| 상태 파일 (parent 모드) | `.pipeline/state/reviews/<slug>.json` |
| 상태 파일 (단일 수동 PR) | `.pipeline/state/reviews/pr-<repo>-<number>.json` |
| Context md | `<docs-context-dir>/<slug>-status.md` (parent 모드 한정) |
| review-blocked 라벨 | 색상 `#d73a4a`, 설명: "`/review` 에스컬 또는 REQUEST_CHANGES — 코드 수정 후 재실행 필요" |

## 영역 ↔ 레포 매핑

리뷰 대상 영역은 **실행 시 config 의 모듈 동작표에서 읽는다** — 모듈 이름을 SKILL.md 에 하드코딩하지 않는다. 리더가 표를 출력하고 그 stdout 으로 판단한다 (위 `--dump` 패턴과 동일).

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
bash "$CFG" --modules-where review=true   # 리뷰 대상 모듈명 (정의순)
bash "$CFG" --modules-table               # 전체 동작표(name·lead·review·area-id 등)
```

- 리뷰 대상 = `review=true` 인 각 모듈. 그 모듈의 레포는 `<owner>/<name>` (`<owner>` 는 위 주입된 설정값).
- `review=false` 인 모듈(예: 코드 없는 디자인 영역)은 **자동 제외** — 카운트·수집·리포트 모두. 제외 목록은 `bash "$CFG" --modules-where review=false` 로 확인 가능 (특정 모듈명 하드코딩 금지 — 플래그로 판단).
- 코드 도입 전이라 PR 0건인 영역은 `review=true` 라도 수집 단계에서 PR 0건이면 자연히 빠진다.

> **대소문자 정확**: `module.<Name>.<flag>` 의 `<Name>` 은 표의 `name` 컬럼과 정확히 일치해야 한다 (예: `module.iOS.area-id` ≠ `module.IOS.area-id`).

## 수행 순서

### 1. 입력 파싱 및 모드 판별

- `$ARGUMENTS`에서 URL 또는 번호 추출
- `--restart` 플래그 추출
- `--bot` 플래그 추출 → `BOT_MODE=true` (GHA 자동화 컨텍스트 — AskUserQuestion 스킵, 상태 파일 자동 재개)
- `--codex` 플래그 추출 → `CODEX_MODE=true` (개별 PR 리뷰 완료 후 Codex 2차 리뷰 추가 실행)
- `--critic-only` 플래그 추출 → `CRITIC_ONLY=true` (개별 PR 재리뷰 스킵, cross-area critic 만 실행)
- URL 패턴으로 모드 판별:
  - `.../pull/<N>` → **단일 PR 모드**
  - `.../issues/<N>` → **parent 모드**
  - 번호만 주어지면 대표 레포(config `parent-repo-name`) 기준 **parent 모드**로 해석
  - 번호가 영역 레포 PR을 의도하는 경우는 URL 필수 (모호성 방지)
- **`--critic-only` 검증** — 이 플래그는 **parent 모드 전용**. 단일 PR 모드(`.../pull/<N>`)에서 `--critic-only`가 오면 즉시 중단 + 안내: "critic-only는 parent 모드 전용 — 단일 PR엔 cross-area critic이 없음"

### 2. 대상 PR 수집

#### 2-a. 단일 PR 모드

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
gh pr view <N> --repo "$OWNER/<영역>" --json number,url,state,isDraft,baseRefName,headRefOid,title,body
```

- `state != "OPEN"` → 중단 ("PR이 닫혀 있거나 머지됨")
- `isDraft == true` → 중단 ("draft PR은 리뷰 대상 아님 — Ready for review로 전환 후 재시도")
- 영역 레포명에서 `<area>` 판별

#### 2-b. Parent 모드

1. parent 이슈 조회:
   ```bash
   CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
   OWNER="$(bash "$CFG" owner)"
   PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
   gh issue view <parent-N> --repo "$OWNER/$PARENT_REPO_NAME" --json number,title,body,url,state
   ```
   - `state != "OPEN"` → 중단

2. **slug 추출** (본문에서 `**Slug:**` 라인 파싱 → `SLUG` 저장. 없으면 `null`)

3. **PR 수집** (스펙 C1 순서):

   **우선 A**: `.pipeline/state/sessions/<SLUG>.json` 존재하면 `areas.<area>.pr.url` 수집

   **Fallback B**: 세션 파일 없거나 누락 영역이 있으면, parent의 sub-issue → linked PR 조회:
   ```bash
   CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
   OWNER="$(bash "$CFG" owner)"
   PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
   gh api /repos/$OWNER/$PARENT_REPO_NAME/issues/<parent-N>/sub_issues
   # 각 sub-issue에 대해:
   gh pr list --repo "$OWNER/<영역>" \
     --search "linked:$OWNER/<영역>#<sub-N>" \
     --state open --json number,url,headRefOid,isDraft,baseRefName
   ```

4. 수집된 PR 중 `isDraft=true`, `state!=OPEN` 제외. `review=false` 모듈(`--modules-where review=false`)의 PR 도 제외.
5. PR이 0건이면 중단 + 안내:
   > 이 parent에 리뷰 가능한 PR이 없음. `/kickoff` 실행 결과 확인 필요.

### 3. 플랜 유무 확인 + 로컬 캐시 materialize (영역별)

플랜은 Docs 레포의 **`plan/<SLUG>` 브랜치**에, 파일명은 **소문자 영역**으로 저장됨 (`/plan` 커맨드 산출물). 현재 체크아웃된 Docs 브랜치(`context/<SLUG>` 등)와 다를 수 있으므로 `git show`로 추출해 로컬 캐시에 풀어낸 뒤 Agent에 전달.

```bash
# Docs 가 "독립 git 레포 루트"인지 판정. rev-parse --git-dir 은 부모로 거슬러 올라가
# 워크스페이스 루트(예: 워크스페이스 자체가 git 레포)의 .git 을 잡아 오판하므로 쓰지 않는다.
# toplevel 이 Docs 자신과 일치할 때만 독립 Docs 레포로 인정.
docs_top="$(git -C Docs rev-parse --show-toplevel 2>/dev/null || true)"
docs_abs="$(cd Docs 2>/dev/null && pwd -P || true)"
if [ -n "$docs_top" ] && [ "$docs_top" = "$docs_abs" ]; then HAS_DOCS=1; else HAS_DOCS=0; fi

if [ "$HAS_DOCS" = "1" ]; then
  AREA_LOWER=$(echo "<area>" | tr '[:upper:]' '[:lower:]')
  PLAN_GIT_PATH="claude/plans/${SLUG}-${AREA_LOWER}.md"
  REQ_GIT_PATH="claude/requirements/${SLUG}.md"

  # plan/<SLUG> 브랜치 fetch (없으면 조용히 패스)
  git -C Docs fetch origin "plan/${SLUG}" 2>/dev/null || true

  # 로컬 브랜치 우선, 없으면 원격 ref 사용
  PLAN_REF="plan/${SLUG}"
  git -C Docs rev-parse --verify "refs/heads/${PLAN_REF}" >/dev/null 2>&1 \
    || PLAN_REF="origin/plan/${SLUG}"

  # 캐시 디렉토리
  mkdir -p .pipeline/state/reviews/cache

  PLAN_CACHE=".pipeline/state/reviews/cache/${SLUG}-${AREA_LOWER}-plan.md"
  REQ_CACHE=".pipeline/state/reviews/cache/${SLUG}-requirements.md"

  # 플랜 존재 확인 + 캐시 추출
  if git -C Docs cat-file -e "${PLAN_REF}:${PLAN_GIT_PATH}" 2>/dev/null; then
    git -C Docs show "${PLAN_REF}:${PLAN_GIT_PATH}" > "${PLAN_CACHE}"
    planPath="$PLAN_CACHE"
    planSource="Docs@${PLAN_REF}:${PLAN_GIT_PATH}"
  else
    planPath=null
    planSource=null
  fi

  # 요구사항(parent 공통) 존재 시 캐시 추출 — verifier 입력용
  if git -C Docs cat-file -e "${PLAN_REF}:${REQ_GIT_PATH}" 2>/dev/null; then
    git -C Docs show "${PLAN_REF}:${REQ_GIT_PATH}" > "${REQ_CACHE}"
    reqPath="$REQ_CACHE"
  else
    reqPath=null
  fi
else
  planPath=null
  planSource=null
  reqPath=null
fi
```

> **Docs 독립 레포 가드**: 위는 `HAS_DOCS=1`(Docs 가 독립 git 레포 루트)일 때만 실행한다. Docs 미클론(부재/빈 dir)이거나 부모 git 의 하위 일반 dir 이면 `HAS_DOCS=0` → planPath/reqPath=null 로 **플랜 없이 정상 진행**. (`rev-parse --git-dir` 은 부모 .git 을 오인하므로 쓰지 않음.)

- `planPath != null` → verifier 호출 대상 (프롬프트에 `PLAN_CACHE` 경로 전달)
- `planPath == null` → code-reviewer 단독 리뷰
- 캐시 파일은 `.pipeline/state/reviews/cache/` 하위에 남김 (재개 시 재사용)

### 4. 상태 파일 감지 + 재개 분기 (C8)

```bash
# Parent 모드
STATE_FILE=".pipeline/state/reviews/${SLUG}.json"

# 단일 수동 PR
STATE_FILE=".pipeline/state/reviews/pr-<repo>-<number>.json"
```

**분기 A. `--restart` 플래그 있음** → 기존 상태 파일 백업 후 초기화, 처음부터

**분기 A-1. `CRITIC_ONLY=true`** → 상태 파일 유무·내용 무관하게 바로 진행 (개별 리뷰를 안 하므로 재개/처음부터 선택이 의미 없음). 상태 파일이 있으면 읽기만 해서 PR URL·플랜 경로 등 컨텍스트 활용.

**분기 B. `STATE_FILE` 존재 + `--restart` 없음** → `AskUserQuestion`:
> 이전 리뷰 상태 감지됨 — 어떻게 할까요?
> `[재개]` `[처음부터]` `[취소]`

- `[재개]` → SHA 비교 기반 차등 재리뷰 (아래 G5 로직):
  | 이전 verdict | 현재 SHA 상태 | 동작 |
  |---|---|---|
  | `approved` | 새 커밋 없음 | 스킵 |
  | `approved` | 새 커밋 있음 | 재리뷰 |
  | `request_changes` · `escalated` | (무관) | 재리뷰 |
  | `pending` | (무관) | 재리뷰 |

- `[처음부터]` → 상태 파일 백업 → 초기화 → 전부 재리뷰
- `[취소]` → 종료

**분기 C. `STATE_FILE` 없음** → 바로 처음부터

### 5. 상태 파일 초기화 / 갱신

상태 파일 스키마(schemaVersion 1.1) 전문·하위호환 규칙은 [상태 파일 스키마](reference/state-schema.md) 참조.

핵심:
- 파일 쓰기는 원자적 (temp + `mv`). 매 상태 전이·retry 증가·에스컬·SIGINT 시 갱신.
- schemaVersion 1.1 은 finding 영구 보존 필드(`findingsSummary`·`findings.codeReview[]`·`findings.verifier`·`aggregate.criticFindings[]`)를 **추가만** 한 것이며 기존 필드·동작은 불변.
- `prs.<area>.repo` 의 `<owner>` 는 config `owner` 로 채운다.

#### 5-a. parent 필드 결정적 기록 (parent 모드 한정)

> **#94: 이 write 가 빠지면 `.parent` 가 null 로 남아 소비자 critic 이 fail-closed 로 머지를 영구 차단한다 — 8-c-bis(`aggregate.verdict` write)와 동형 버그다.**

parent 모드에서 상태 파일을 **처음 만든 직후**, Step 2-b 에서 이미 조회한 parent 이슈의 URL·number 를 `.parent` 에 **결정적으로** 기록한다. LLM 의 비결정적 채움에 의존하지 않는다. 소비자(`critic-dispatch.yml` 이 부르는 `scripts/parse-critic-verdict.sh` / `scripts/resolve-review-statefile.sh`)는 `.parent.url == PARENT_URL` 정확매칭으로 "이번 실행의 상태파일"을 식별하므로, 이 값이 비면 indeterminate → fail-closed.

- **단일 PR 모드(`pr-<repo>-<number>.json`, `mode:single`)는 건드리지 않는다** — `parent:null` 이 정상이다. 이 단계는 **parent 모드에서만** 실행한다.
- STATE_FILE 은 라이브 변수 `${SLUG}`(리터럴 `<slug>` 금지 — 별개 셸에서 치환 누락 시 존재하지 않는 경로가 되어 #94 회귀). 8-c-bis 와 동일 컨벤션.
- fail-fast: parent URL 이 `https://github.com/*/issues/*` 패턴이 아니거나, number 가 비었거나 비정수거나, URL 말미 번호와 number 가 어긋나면 잘못된 값이 상태파일에 박히기 전에 즉시 중단(8-c-bis 의 verdict allowlist 게이트와 동형).

```bash
# parent 모드에서만 실행. 단일 PR 모드(mode:single)는 parent:null 이 정상이므로 건너뛴다.
# STATE_FILE 은 Step 4/5/8-c-bis 와 동일한 라이브 변수 컨벤션(${SLUG}).
#   리터럴 angle-bracket(<slug>)을 박으면 별개 셸에서 치환 누락 시 존재하지 않는 경로가 되어
#   jq 가 "no such file" → `&& mv` 스킵 → parent 미기록 → #94(fail-closed) 회귀한다.
STATE_FILE=".pipeline/state/reviews/${SLUG}.json"
PARENT_URL="<Step 2-b 에서 조회한 parent 이슈 url>"     # gh issue view ... --json url 의 .url
PARENT_NUMBER="<Step 2-b 에서 조회한 parent 이슈 number>"  # gh issue view ... --json number 의 .number

# fail-fast: parent URL 이 issues URL 패턴이 아니거나 number 가 비면 즉시 중단.
#   잘못된 null/이상치가 상태파일에 박히면 소비자 critic 이 indeterminate→fail-closed 로
#   머지를 영구 차단하므로(#94), 잘못된 값 기록 자체를 여기서 막는다.
case "$PARENT_URL" in
  https://github.com/*/issues/*) ;;
  *) echo "::error::parent URL 이상치('$PARENT_URL') — 5-a parent write 중단. Step 2-b 의 gh issue view .url 확인 필요." >&2; exit 1 ;;
esac
# number 게이트도 URL 게이트와 대칭으로 패턴 검증한다(빈값+비정수 모두 차단). 비정수면
# 아래 --argjson 이 JSON 파싱 실패로 jq 를 죽여 parent 미기록(#94 회귀)되므로 미리 막는다.
case "$PARENT_NUMBER" in
  ''|*[!0-9]*) echo "::error::parent number 이상치('$PARENT_NUMBER') — 5-a parent write 중단. Step 2-b 의 gh issue view .number 확인 필요." >&2; exit 1 ;;
esac
# URL↔number 정합성 — 둘은 같은 gh issue view <parent-N> 호출(Step 2-b)에서 와야 하므로
# URL 말미 번호와 PARENT_NUMBER 가 일치해야 한다. 어긋나면 서로 다른 이슈를 가리키는 배선
# 실수이므로, 잘못된 parent 가 박혀 소비자가 엉뚱한 상태파일을 매칭하기 전에 차단한다.
if [ "${PARENT_URL##*/issues/}" != "$PARENT_NUMBER" ]; then
  echo "::error::parent URL 말미 번호(${PARENT_URL##*/issues/}) ≠ PARENT_NUMBER($PARENT_NUMBER) — 서로 다른 이슈 배선 의심, 5-a write 중단. Step 2-b 의 url·number 가 같은 이슈인지 확인." >&2; exit 1
fi

# parent 를 한 jq 트랜잭션으로 기록. 원자적 temp + mv (L250 규칙 준수).
# [#94] jq 실패(STATE_FILE 부재/오염 등)는 loud 하게 exit 1 한다. `&& mv ... || rm -f` 로
#   쓰면 마지막 rm -f 가 0 을 반환해 jq 실패가 전체 exit 0 으로 삼켜지고, parent 미기록인데
#   무성 통과해 정확히 #94 가 회귀한다. 같은 5-a 블록의 URL/number 게이트가 exit 1 로
#   fail-fast 하는 것과 일관되게, 실제 write 실패도 fail-closed 로 노출한다(8-c-bis 보다 강함).
#   본파일은 temp 경유라 부분쓰기로 오염되지 않으며, 실패 시 orphan temp 만 정리하고 죽는다.
TEMP="$STATE_FILE.tmp.$$"
if jq --arg pu "$PARENT_URL" --argjson pn "$PARENT_NUMBER" \
     '.parent = {url: $pu, number: $pn}' \
     "$STATE_FILE" > "$TEMP"; then
  mv "$TEMP" "$STATE_FILE"
else
  rm -f "$TEMP"
  echo "::error::5-a parent write 실패(STATE_FILE 부재/오염 의심) — Step 5 상태파일 생성 여부 확인 필요." >&2
  exit 1
fi
```

### 6. 리뷰 오케스트레이션 (C3 하이브리드)

#### 6-a. Parent 모드 순서

선행 모듈은 `bash "$CFG" --modules-where lead=true` (= `<lead>`). 리뷰 대상은 `review=true` 모듈 중 수집된 PR이 있는 영역.

```
if <lead> PR 존재:                        # <lead> = --modules-where lead=true
    run_individual_review(<lead>)         # 단독 실행, 완료 대기 (lead 2개 이상이면 정의순 직렬)
    # <lead> 판정 결과 무관하게 계속 (G2 — /kickoff 와 달리 lead escalated 여도 나머지 진행)

# 나머지 리뷰 대상 영역 병렬 (한 메시지 내 여러 Agent 호출)
parallel:
    for area in (review=true 모듈 PR − <lead>):
        run_individual_review(area)

# 전부 완료 후 종합 리뷰
run_aggregate_review()
```

> lead 모듈이 없거나(미지정) 그 PR이 수집되지 않았으면 선행 단계를 건너뛰고 모든 리뷰 대상 영역을 병렬 실행한다.

**`CRITIC_ONLY=true` 분기** — critic-only 모드면 위 순서에서 **개별 리뷰만 빼고 종합 단계는 그대로**:

```
if CRITIC_ONLY:
    # 개별 리뷰 전부 스킵: run_individual_review(...) 호출들 + 7단계(개별 GitHub Review 제출) + 7-h(Status 전환) 통째로 건너뜀
    # critic이 어떤 PR을 볼지 알아야 하므로 2단계(대상 PR 수집)·3단계(플랜 캐시)는 유지
    run_aggregate_review()                # 8단계 critic 만 곧장 실행
```

- critic-only에서도 **유지**: 2단계(대상 PR 수집), 3단계(플랜 캐시 — cross-area 플랜 일관성 입력), 8단계(critic), 8-c(parent 코멘트), **8-c-bis(상태 파일 `aggregate.verdict`·`criticFindings` 기록 — 후속 GHA가 verdict 를 읽어 머지 분기하므로 반드시 실행)**
- critic-only에서 **스킵**: 개별 리뷰(`run_individual_review`) 전부, 7단계(개별 GitHub Review 제출), 7-h(Status `Bot Review → In Review` 전환)
- 배경: critic 발사 시점엔 개별 PR이 이미 전부 APPROVED 라 개별 재리뷰는 낭비. critic-only로 개별 단계만 빼서 시간 단축 (20~30분 → 5~10분)

#### 6-b. 단일 PR 모드 순서

```
run_individual_review(<area>)
# 종합 리뷰 없음
```

### 7. 개별 PR 리뷰 블록 (`run_individual_review`)

#### 7-a. 리뷰어 Agent 호출

**플랜 있음** — 둘을 병렬 호출 (동일 메시지 내 두 개 Agent):

```
[1] Agent(
      description="<영역> code-review",
      subagent_type="pipeline:code-reviewer",
      prompt=CODE_REVIEW_PROMPT
    )
[2] Agent(
      description="<영역> spec-verify",
      subagent_type="pipeline:verifier",
      prompt=VERIFIER_PROMPT
    )
```

**플랜 없음** — code-reviewer만.

> `CODE_REVIEW_PROMPT`·`VERIFIER_PROMPT` 의 입력 배선은 [리뷰어 Agent 프롬프트 템플릿](reference/agent-prompts.md) 참조. severity 분류·체크리스트·반환 JSON 스키마는 이미 `pipeline:code-reviewer`·`pipeline:verifier` 시스템프롬프트에 승격되어 있어, 호출 프롬프트는 입력만 전달한다.

#### 7-d. JSON 파싱 및 재시도 (C6)

반환 JSON 파싱 실패 또는 스키마 위반 → `fixing` 카운트 +1
- `fixing < 3` → 동일 프롬프트에 "JSON 엄격 준수 필요" 추가해 재호출
- `fixing ≥ 3` → **에스컬** (category=`fixing`)

Agent 호출 자체 실패 (timeout·tool error) → `transient` 카운트 +1
- `transient < 3` → 지수 백오프 (2s → 4s → 8s) 후 재호출
- `transient ≥ 3` → **에스컬** (category=`transient`)

권한·PR 접근 불가·명시적 `immediate` 사유 → 즉시 **에스컬** (category=`immediate`)

**finding 보존 (schemaVersion 1.1)** — 파싱에 성공한 결과를 7-i 상태 파일 기록을 위해 그대로 들고 간다:
- code-reviewer 의 `findings[]` 각 항목(`severity, file, line, title, description, suggestion` 6개 필드)을 보존 → 7-i 에서 `prs.<area>.findings.codeReview[]` 에 기록.
- severity별 카운트를 집계해 보존 → 7-i 에서 `prs.<area>.findingsSummary` 에 기록.
- verifier 의 `{verdict, reasons}` 를 보존 → 7-i 에서 `prs.<area>.findings.verifier` 에 기록. (플랜 없어 verifier 미실행이면 `{"verdict":"pass","reasons":[]}` 로 둔다.)

#### 7-e. 판정 (C5)

```
# 플랜 있음
if verifier.verdict == "pass" AND code_review.findings (blocker count) == 0:
    verdict = "approved"
else:
    verdict = "request_changes"

# 플랜 없음
if code_review.findings (blocker count) == 0:
    verdict = "approved"
else:
    verdict = "request_changes"
```

#### 7-f-pre. Codex 2차 리뷰 (`CODEX_MODE=true` 한정)

`--codex` 플래그가 있을 때 개별 PR 판정 직후 실행. **판정(verdict)은 변경하지 않음** — 보조 관점 제공용.

```bash
# <영역> 디렉토리에서 실행 — base 브랜치 대비 변경사항 리뷰
CODEX_OUTPUT=$(cd <영역> && codex review --base <baseRefName> -c model="gpt-5.3-codex-spark" 2>&1)
```

- 실행 실패(에러·타임아웃) 시 `CODEX_OUTPUT="(실행 실패)"` 로 처리하고 계속 진행 — Codex 실패가 파이프라인을 막지 않음
- 출력 마지막 `codex` 라인(리뷰 요약)을 `CODEX_SUMMARY`로 추출해 리포트에 사용

```bash
CODEX_SUMMARY=$(echo "$CODEX_OUTPUT" | grep -A2 "^codex$" | tail -1)
```

#### 7-f. GitHub Review 제출 — Reviewer 봇 App 토큰 + REST API

> **⚠️ 중요 (R10):** gh CLI 의 user 토큰 (config `author-login`) 으로 review 부착 시도하면 PR author 와 같은 entity 라 GitHub 가 self-approve 차단. 반드시 config `reviewer-bot-slug` GitHub App (App ID = config `reviewer-app-id`) 의 installation token 으로 호출해야 정식 `[bot]` 명의로 부착됨.

**호출 패턴 — 단일 REST POST 로 review + line comments 묶음 제출:**

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# [필수 config 게이트] self-approve 우회 토큰 발급에 필요한 민감 키가 비어있으면 즉시 실패(fail-fast).
# 빈 reviewer-bot-slug/reviewer-token-key 로 토큰 누락 상태에서 user 토큰 폴백되면
# self-approve 차단에 걸리거나 정체불명 명의로 부착되므로, 조기에 막는다.
bash "$CFG" --require reviewer-bot-slug reviewer-token-key || exit 1
OWNER="$(bash "$CFG" owner)"
REVIEWER_TOKEN_KEY="$(bash "$CFG" reviewer-token-key)"

# 1. .zshrc source + App installation token 발급
#    (실제 시크릿 App ID/PEM/Installation 은 env 에서 헬퍼가 읽는다 — config 아님.
#     env 변수 이름표 PREFIX 만 config reviewer-token-key 로 주입.)
source ~/.zshrc
TOKEN=$("${CLAUDE_SKILL_DIR}/scripts/gh-app-token.sh" "$REVIEWER_TOKEN_KEY")

# 2. Payload 구성 (python heredoc — escape 안전)
PAYLOAD=$(python3 <<'PY'
import json
findings = [
    # code_review.findings 의 각 항목을 다음 형태로 매핑:
    # {"path": "<repo-relative path>",
    #  "line": <NEW 파일 기준 line, file-level 의견이면 키 자체 생략>,
    #  "body": "**[<severity>] <title>**\n\n<description>\n\n**제안:**\n<suggestion>"}
]
event = "APPROVE"        # verdict==approved 면 APPROVE, 아니면 REQUEST_CHANGES
summary = "<G4 템플릿 렌더링 본문>"
print(json.dumps({"event": event, "body": summary, "comments": findings}))
PY
)

# 3. 단일 호출로 review + line comments 함께 제출
RESPONSE=$(curl -sS -X POST \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$OWNER/<영역>/pulls/<N>/reviews" \
  -d "$PAYLOAD")

REVIEW_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('html_url',''))")
```

**REST 한 번 호출 = atomic** — review + line comments 가 한 트랜잭션으로 처리됨. 부분 실패 (review 만 만들고 comments 실패) 가 일어나지 않음.

**line 위치 결정 규칙:**
- 코드 변경 라인을 정확히 가리키면 그 line (NEW 파일 기준 line 번호)
- 파일 단위 의견이면 `line` 키 생략 → file-level comment
- 새로 추가된 파일의 첫 라인이면 line=1

**대체 인증 (GHA 도입 후, M3+):** GitHub Actions workflow 안에서 호출하면 `${{ secrets.<REVIEWER_TOKEN_KEY>_PRIVATE_KEY }}` 로 같은 흐름. 로컬 `.pem` 사본 폐기 가능 — 이전 자동화 봇과 같은 보안 모델.

#### 7-g. REQUEST_CHANGES 시 추가 조치

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
# Issue comment로 "왜 거부" 요약 추가:
gh pr comment <N> --repo "$OWNER/<영역>" --body "<요약 멘트>"
# review-blocked 라벨 부착 (G7):
gh label create review-blocked --repo "$OWNER/<영역>" \
  --color "d73a4a" \
  --description "/review 에스컬 또는 REQUEST_CHANGES — 코드 수정 후 재실행 필요" \
  2>/dev/null || true
gh pr edit <N> --repo "$OWNER/<영역>" --add-label review-blocked
```

#### 7-h. APPROVE 시 라벨 해제 + Status 전환 (R9)

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
gh pr edit <N> --repo "$OWNER/<영역>" --remove-label review-blocked 2>/dev/null || true
```

**Status `Bot Review → In Review` 전환** — `/kickoff` 가 PR 생성 직후 올린 `Bot Review` 를, Claude 리뷰 통과 시점에 사용자 hands-on 검증 단계(`In Review`)로 넘김:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PROJECT_NUMBER="$(bash "$CFG" project-number)"
PROJECT_ID="$(bash "$CFG" project-id)"
STATUS_FIELD_ID="$(bash "$CFG" status-field-id)"

# sub-issue node id 확보
# 우선순위 A: /kickoff 세션 파일 있으면 areas.<area>.subIssue.nodeId 사용
# Fallback B: PR 본문의 "Closes <owner>/<area>#<sub-N>" 에서 파싱 → gh api로 node_id 조회

# Prep Project item id 조회 (G18-a)
ITEM_ID=$(gh api graphql -f query='
query($owner: String!, $number: Int!, $issueId: ID!) {
  organization(login: $owner) {
    projectV2(number: $number) {
      items(first: 100) {
        nodes { id content { ... on Issue { id } } }
      }
    }
  }
}' -f owner="$OWNER" -F number="$PROJECT_NUMBER" -f issueId="<SUB_ISSUE_NODE_ID>" \
  --jq '.data.organization.projectV2.items.nodes[] | select(.content.id=="<SUB_ISSUE_NODE_ID>") | .id')

# In Review option ID 동적 조회
IN_REVIEW_ID=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
  | jq -r '.fields[] | select(.name=="Status") | .options[] | select(.name=="In Review") | .id')

gh api graphql -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
    value: { singleSelectOptionId: $optionId }
  }) { projectV2Item { id } }
}' -f projectId="$PROJECT_ID" \
  -f itemId="$ITEM_ID" \
  -f fieldId="$STATUS_FIELD_ID" \
  -f optionId="$IN_REVIEW_ID"
```

**R9 보강 규칙**:

- 전환 대상은 **현재 `Status=Bot Review` 인 항목만**. `In Review`·`Done` 이면 이미 전환됐거나 사용자 수동 진행이므로 스킵
- `Status=In Progress` 면 경고 로그만 남기고 전환 진행 (누락 케이스 흡수)
- 전환 실패는 **에스컬 아님**. REQUEST_CHANGES 로 격상하지 않고, 리뷰는 APPROVE 유지. 상태 파일의 `statusTransition` 객체(`succeeded: false` + `error` 필드)에 기록 + 최종 리포트에 경고 표시 (스키마: state-schema.md 의 `statusTransition.error`)
- REQUEST_CHANGES 시에는 Status를 건드리지 않음 — `Bot Review` 유지 (review-blocked 라벨로 구분)

#### 7-i. 상태 파일 갱신

7-d 에서 보존한 결과를 상태 파일에 쓴다. JSON 구조·finding 기록 규칙(`findingsSummary`·`findings.codeReview[]`·`findings.verifier`·`statusTransition`)은 [상태 파일 스키마 §7-i](reference/state-schema.md) 참조.

### 8. 종합 리뷰 (Parent 모드 한정)

#### 8-a. Critic 호출

```
Agent(
  description="cross-area 종합 리뷰",
  subagent_type="pipeline:critic",
  prompt=CRITIC_PROMPT
)
```

> 영역 간 종합은 `pipeline:critic` 을 **영역 간 종합 리뷰 모드(모드 C)** 로 호출한다. `CRITIC_PROMPT` 의 입력 배선은 [리뷰어 Agent 프롬프트 템플릿 §8-b](reference/agent-prompts.md) 참조. cross-area 체크리스트·3축 격차·반환 JSON 스키마는 이미 `pipeline:critic` 모드 C 시스템프롬프트에 승격되어 있다.

#### 8-c. Parent 코멘트 + PR 포인터 (C4)

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
# Parent 코멘트
gh issue comment <parent-N> --repo "$OWNER/$PARENT_REPO_NAME" --body "$(cat <<EOF
## 🔍 /review 종합 리뷰

**Slug**: <slug>
**실행 시각**: <ISO-8601>
**verdict**: <pass | concerns | blocker>

### 개별 PR 판정
| 영역 | 판정 | PR | 비고 |
|---|---|---|---|
| Backend | ✅ APPROVE | #12 | - |
| Frontend | ❌ REQUEST_CHANGES | #13 | blocker 2건 |
...

### 종합 findings (critic)
<findings 표 — concerns일 때만>

### 요약
<critic.summary>

---
*자동 발송됨. 상태: \`.pipeline/state/reviews/<slug>.json\`*
EOF
)"
# → PARENT_COMMENT_URL 반환
```

각 영역 PR에 포인터 코멘트:
```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
gh pr comment <N> --repo "$OWNER/<영역>" \
  --body "ℹ️ 종합 리뷰는 <PARENT_COMMENT_URL> 참조"
```

#### 8-c-bis. critic verdict·findings 상태 파일 기록 (schemaVersion 1.1)

위 8-c 의 parent 코멘트 렌더와 **별개로**, 8-b critic Agent 가 반환한 **verdict 와 findings 를 상태 파일 `aggregate` 에 한 트랜잭션으로 기록**한다(코멘트는 휘발성, 상태 파일은 영구 보존·후속 추적용).

- `aggregate.verdict` ← 8-b critic 반환 verdict(`pass`/`concerns`/`blocker`). **`critic-dispatch.yml` 이 `critic-verdict-gate` composite action(→ `parse-critic-verdict.sh`)을 통해 이 값을 읽어 머지 분기**하며 allowlist(`pass`/`concerns`/`blocker`) 밖이면 indeterminate → fail-closed 로 머지 차단. **이 단계가 verdict 를 쓰는 유일한 실행 지점**이라 빠지면 verdict 가 초기값 null 로 남아 critic 자동머지가 영구 차단된다(#54).
- `aggregate.criticFindings` ← 8-b critic 반환 `findings[]`(0건이면 `[]`).
- 개별 PR verdict(`prs.<area>.verdict`: `approved`/`request_changes`)와는 **별개**다 — `aggregate.verdict` 는 critic 종합 verdict 다.

```bash
# 8-b critic Agent 가 반환한 verdict(pass|concerns|blocker)·findings 를 캡처해 변수에 둔다.
#   CRITIC_VERDICT  : 8-b 반환 JSON 의 .verdict (반드시 pass|concerns|blocker 중 하나)
#   CRITIC_FINDINGS : 8-b 반환 JSON 의 .findings 배열(JSON 문자열, 0건이면 '[]')
# STATE_FILE 은 Step4/5 와 동일한 라이브 변수 컨벤션(${SLUG})을 따른다.
#   리터럴 angle-bracket(<slug>)을 박으면 별개 셸에서 치환 누락 시 존재하지 않는 경로가 되어
#   jq 가 "no such file" → `&& mv` 스킵 → verdict 미기록 → #54(fail-closed) 회귀한다.
STATE_FILE=".pipeline/state/reviews/${SLUG}.json"
CRITIC_VERDICT="<8-b critic 반환 verdict: pass|concerns|blocker>"
CRITIC_FINDINGS='<8-b critic 반환 findings[] JSON, 0건이면 []>'

# fail-fast: verdict 가 allowlist(pass|concerns|blocker) 밖이면(빈값/이상치) 즉시 중단.
#   parse-critic-verdict.sh(critic-dispatch.yml 이 부름)도 allowlist 밖이면 fail-closed 하지만, 여기서 먼저 막아 잘못된 값이
#   상태파일에 기록되는 것 자체를 방지한다.
case "$CRITIC_VERDICT" in
  pass|concerns|blocker) ;;
  *) echo "::error::critic verdict 이상치('$CRITIC_VERDICT') — 8-c-bis write 중단. 8-b 반환 JSON 의 .verdict 확인 필요." >&2; exit 1 ;;
esac

# verdict·criticFindings 를 한 jq 트랜잭션으로 기록. 원자적 temp + mv (L250 규칙 준수).
TEMP="$STATE_FILE.tmp.$$"
jq --arg cv "$CRITIC_VERDICT" --argjson cf "$CRITIC_FINDINGS" \
  '.aggregate.verdict = $cv | .aggregate.criticFindings = $cf | .aggregate.completedAt = (now | todate)' \
  "$STATE_FILE" > "$TEMP" && mv "$TEMP" "$STATE_FILE"
```

`aggregate.criticFindings[]` 구조·기록 규칙은 [상태 파일 스키마 §8-c-bis](reference/state-schema.md) 참조.

#### 8-d. Critic 실패 처리

Critic Agent 호출이 에스컬 상한 초과 시 **parent issue에 에스컬 코멘트** (G9 템플릿). 개별 PR 판정은 유지.

### 9. 에스컬 플로우 (C6, C7)

개별 리뷰 또는 종합 리뷰에서 재시도 상한 초과 시 처리한다. 에스컬 코멘트 본문(G9)·진단 힌트 표·Slack 이중 발송 규칙·영역별 독립 원칙(G2)은 [에스컬레이션 템플릿](reference/escalation.md) 참조.

#### 9-a. `review-blocked` 라벨 부착 (개별 PR 실패 시)

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
gh label create review-blocked --repo "$OWNER/<영역>" \
  --color "d73a4a" \
  --description "/review 에스컬 또는 REQUEST_CHANGES — 코드 수정 후 재실행 필요" \
  2>/dev/null || true
gh pr edit <N> --repo "$OWNER/<영역>" --add-label review-blocked
```

#### 9-b. 에스컬 코멘트 부착 + Slack 이중 발송

실패 단위에 따라 부착 위치 결정 (C7): **개별 PR 실패** → 해당 PR / **종합 리뷰 실패** → parent issue. 코멘트 본문(G9)·Slack 규칙은 [에스컬레이션 템플릿](reference/escalation.md) 참조.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
SLACK_TOKEN_KEY="$(bash "$CFG" slack-token-key)"
SLACK_CHANNEL="$(bash "$CFG" slack-channel)"

# 개별 PR 실패: gh pr comment / 종합 리뷰 실패: gh issue comment <parent-N> --repo "$OWNER/$PARENT_REPO_NAME"
COMMENT_URL=$(gh pr comment <N> --repo "$OWNER/<영역>" --body "$COMMENT")
# (parent 모드 종합 리뷰 실패면 위 줄을:
#   COMMENT_URL=$(gh issue comment <parent-N> --repo "$OWNER/$PARENT_REPO_NAME" --body "$COMMENT")
# )

# Slack 이중 발송 (보조 채널 — 발송 실패해도 파이프라인 차단 안 함)
#   SLACK_TOKEN_KEY(slack-token-key 가 준 env 이름표)를 헬퍼에 env 로 넘긴다. 간접확장(env
#   이름표를 실제 값으로 푸는 bash 전용 문법)은 헬퍼(slack-notify.sh) 안에서 한다 — 헬퍼가
#   bash shebang 이라 안전. 이 펜스는 사용자 셸(zsh 가능)로 실행되므로 간접확장을 여기 두면
#   zsh 에서 "bad substitution" 으로 깨진다(그래서 펜스엔 안 둔다). 헬퍼는 SLACK_TOKEN_KEY
#   역참조 우선, 없으면 SLACK_WEBHOOK_URL 폴백, 둘 다 없으면 graceful skip.
SLACK_CONTEXT=$(printf '대상: %s\n실패 유형: %s %s/%s\n원인: %s' \
  "<PR #N or Parent #parent-N>" "<카테고리>" "<count>" "<limit>" "<핵심 요약>")
SLACK_TOKEN_KEY="$SLACK_TOKEN_KEY" \
  "${CLAUDE_SKILL_DIR}/scripts/slack-notify.sh" "/review 중단 — <영역 or cross-area>" "$COMMENT_URL" "$SLACK_CONTEXT"
```

> **순서 고정**: GitHub 코멘트 발송이 1차, Slack 은 항상 그 뒤 호출 (Slack 먼저 가면 사용자가 빈 링크 클릭 위험).

#### 9-c. 진단 힌트 표 + 9-d. 상태 파일 업데이트

진단 힌트 표(카테고리별)는 [에스컬레이션 템플릿 §9-c](reference/escalation.md), 상태 파일 업데이트 JSON 은 [상태 파일 스키마 §9-d](reference/state-schema.md) 참조.

#### 9-e. 영역별 독립 원칙 (G2)

한 영역 리뷰 실패·REQUEST_CHANGES 가 나머지 영역을 막지 않는다. 상세는 [에스컬레이션 템플릿 §9-e](reference/escalation.md) 참조.

### 10. Context md append (Parent 모드 한정, C8)

세션 종료 직전(성공·혼합·에스컬·SIGINT 포함) 항상 로컬에서 갱신한다. 저장 경로는 config `docs-context-dir` 로 결정:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
DOCS_CONTEXT_DIR="$(bash "$CFG" docs-context-dir)"
# 갱신 대상: $DOCS_CONTEXT_DIR/<slug>-status.md
```

기존 `/kickoff` 섹션은 **유지**하고 맨 아래에 `## 🔍 리뷰 (/review 실행 결과)` 섹션 append (이미 있으면 교체). 템플릿 본문·Docs 커밋 트리거(10-a)는 [Context md append 템플릿](reference/context-md.md) 참조.

#### 10-a. Docs 커밋 트리거 (`/kickoff` G7-c 동일 조건)

**먼저 Docs 가 독립 git 레포 루트인지**(`--show-toplevel` 일치) 확인하고, 아니면 이 커밋 단계 전체를 스킵한다. 트리거 조건 (a)~(d) 는 [Context md append 템플릿 §10-a](reference/context-md.md) 참조.

```bash
# Docs 가 "독립 git 레포 루트"인지 판정. rev-parse --git-dir 은 부모로 거슬러 올라가
# 워크스페이스 루트의 .git 을 잡아 오판하므로 쓰지 않는다.
# toplevel 이 Docs 자신과 일치할 때만 독립 Docs 레포로 인정.
docs_top="$(git -C Docs rev-parse --show-toplevel 2>/dev/null || true)"
docs_abs="$(cd Docs 2>/dev/null && pwd -P || true)"
if [ -n "$docs_top" ] && [ "$docs_top" = "$docs_abs" ]; then HAS_DOCS=1; else HAS_DOCS=0; fi

if [ "$HAS_DOCS" = "1" ]; then
  git -C Docs checkout context/<slug> 2>/dev/null || git -C Docs checkout -b context/<slug>
  git -C Docs add claude/context/<slug>-status.md
  git -C Docs commit -m "[context] <parent-title> /review 결과 반영 (#<parent-N>)"
  git -C Docs push -u origin context/<slug>
else
  echo "Docs 독립 레포 없음 — Context md 커밋 스킵 (Docs 미사용/미클론 프로젝트)"
fi
```

클린 성공(전부 approved · critic pass)은 Docs 커밋 생략.

### 11. 상태파일 sentinel 기록 (최종 리포트 직전 필수 pre-final step)

> **🛑 추론하지 말고 무조건 아래 Bash 블록을 실제로 실행하라.** `REVIEW_STATE_SENTINEL` 이 설정됐는지 **머리로 판단하지 마라**. "지금 로컬이니 env 가 없을 것이다" 같은 추론으로 이 단계를 건너뛰는 것은 **금지**다. 설정 여부 판단은 전적으로 셸의 `[ -n "${REVIEW_STATE_SENTINEL:-}" ]` 가드가 한다 — 너는 블록을 **실행하기만** 하면 된다. env 가 미설정이면 가드가 알아서 아무 것도 안 하고 끝나므로(완전 안전) 실행해도 무해하다. 실행 자체를 생략하면 상태파일 결정적 식별(소비자 critic 이 추측 없이 정확한 상태파일을 읽는 것)이 무력화된다.

**모든 모드(단일 PR / parent / critic-only)에서, `STATE_FILE` 이 확정된 직후·최종 리포트 출력 직전에 반드시 실행한다. 에스컬·SIGINT·조기종료 정리 경로에서도 동일하게 수행해야 sentinel 이 기록된다.**

> **이전 배치 문제**: 섹션 12(최종 리포트 뒤)에 두었을 때 에스컬·SIGINT·조기종료 경로에서 리포트 출력 전에 종료되면 sentinel 기록이 누락됐다. 최종 리포트 "직전"으로 이동해 모든 종료 경로에서 STATE_FILE 이 확정된 시점에 실행되게 한다.

```bash
# 최종 리포트 출력 직전 — STATE_FILE 확정 후 항상 실행.
# 에스컬/SIGINT 정리 핸들러에도 동일 블록을 포함시켜야 한다.
# 설정 여부는 아래 가드가 판단한다 — 이 블록은 추론으로 건너뛰지 말고 항상 실행하라. env 미설정이면 가드가 자동 스킵(하위호환).
if [ -n "${REVIEW_STATE_SENTINEL:-}" ] && [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ]; then
  # STATE_FILE 은 working-directory 기준 상대경로일 수 있으므로 절대경로로 정규화.
  # (소비자 critic-dispatch.yml / track-findings action 은 다른 working-dir 에서 실행됨)
  STATE_FILE_ABS=$(cd "$(dirname "$STATE_FILE")" && pwd)/$(basename "$STATE_FILE")
  printf '%s\n' "$STATE_FILE_ABS" > "$REVIEW_STATE_SENTINEL"
fi
```

규칙:
- **필수 pre-final step** — 성공·혼합·에스컬·SIGINT·critic-only 어느 종료 경로든, `STATE_FILE` 이 확정되면 최종 리포트 직전에 기록한다. (단일 PR 모드의 `pr-<repo>-<number>.json`, parent/critic-only 모드의 `<slug>.json` 모두 포함.)
- **에스컬·SIGINT 정리 경로 포함** — trap 핸들러나 에스컬 후 종료 블록에도 동일 스니펫을 실행해야 한다. 조기 종료 시 STATE_FILE 이 아직 안 만들어졌으면(`[ -f "$STATE_FILE" ]` 실패) 자동 스킵 — 소비자는 sentinel 부재로 보고 추측매칭 폴백한다(fail-closed 보존).
- **`set -u` 안전** — `${REVIEW_STATE_SENTINEL:-}`·`${STATE_FILE:-}` 형태로 미설정 변수도 안전하게 처리. `[ -f "$STATE_FILE" ]` 가드로 파일 미존재 시 스킵.
- **스킵 판단은 셸 가드가 한다 — 네가 추론으로 하지 마라.** `REVIEW_STATE_SENTINEL` 미설정 시 가드(`[ -n … ]`)가 자동으로 아무 것도 안 함 → 기존 동작 불변(하위호환). "로컬이니까"라는 이유로 블록 실행을 생략하면 안 된다.
- sentinel 에는 **절대경로 한 줄만** 기록한다(소비자가 `head -n 1` 로 읽음).

### 12. 최종 리포트

```
/review 완료 — <parent-title or "단일 PR #<N>">

모드: <parent | single | parent (critic-only)>
Slug: <slug or N/A>
상태 파일: .pipeline/state/reviews/<...>.json

# critic-only 모드면 아래 "영역별 판정" 표 대신 이 블록만 출력:
# ----------------------------------------
# (critic-only) 개별 리뷰 스킵 — 기존 APPROVED PR 재활용
# 영역별 PR: Backend #12 · Frontend #13 · ...
# ----------------------------------------

영역별 판정: (critic-only 가 아닐 때만 출력)
  ✅ Backend    APPROVE         PR #12  (blocker 0 / major 1 / minor 3)  → Status=In Review
  ❌ Frontend   REQUEST_CHANGES PR #13  (blocker 2 / major 4 / minor 2)  → review-blocked · Status=Bot Review 유지
  ⏳ iOS        pending         PR #14  (새 커밋 대기)
  🚨 Android   escalated       PR #15  (transient 3/3)  → <코멘트 URL>

Status 전환:
  Backend: Bot Review → In Review ✅
  (Frontend/iOS/Android: 전환 없음)

종합 리뷰:
  verdict: concerns
  주요 findings:
    - [major] FE/iOS 버전 표시 위치 불일치
    - [minor] Backend 응답 스키마와 FE 타입 정의 순서 차이
  parent 코멘트: <URL>

Context 문서:
  - <docs-context-dir>/<slug>-status.md  (Docs 커밋: 예/생략)

Codex 2차 리뷰: (--codex 플래그 사용 시만 표시)
  Backend:  <CODEX_SUMMARY>
  Frontend: <CODEX_SUMMARY>
  ...

▶ 다음:
  - In Review 영역 (Backend): 사용자 hands-on 검증 → 머지
  - REQUEST_CHANGES PR (Frontend): 코드 수정 후 커밋 push → /review <url> 재실행
  - escalated PR (Android): 코멘트 안내 따라 조치 후 /review <url> 재실행
```

Status 전환 실패가 있었다면 경고 블록을 추가:

```
⚠️ Status 전환 경고:
  - Backend: Bot Review → In Review 실패 (<error>). 사용자가 수동 전환 필요.
```

## 원칙 (지켜야 할 것)

- **판정 + Status 전환까지가 책임** (C10, R9) — `/review`는 머지·코드 수정은 안 하지만, APPROVE 판정 시 `Bot Review → In Review` Status 전환은 수행 (M2 스테이지 분리 이후)
- **플랜 유무로 동작 분기** (C1) — 있으면 verifier 포함, 없으면 code-reviewer 단독
- **critic-only 모드** — `--critic-only` 면 개별 PR 재리뷰를 스킵하고 종합 critic 만 실행. **parent 모드 전용** (단일 PR엔 cross-area critic 없음)
- **영역별 독립 실패** (G2) — 한 영역 REQUEST_CHANGES·에스컬이 다른 영역을 막지 않음 (`/kickoff` 와 달리 lead 선행 영역이 실패해도 나머지 리뷰 계속)
- **재시도 3분류 고정** (C6) — fixing 3 / transient 3 / immediate 0. 사용자 override 없음
- **draft PR 제외** (C1) — 명시적 차단
- **Status 전환 범위 제한** (R9) — APPROVE 시 `Bot Review → In Review` 만 수행. REQUEST_CHANGES·에스컬·`In Review`/`Done`/다른 Status 는 건드리지 않음. 전환 실패는 에스컬로 격상하지 않음
- **상태 파일 독립** (C8, G1) — `/kickoff` 세션 파일 수정 금지 (읽기만 — subIssue.nodeId 조회용)
- **상태 파일 원자적 쓰기** — temp + `mv`, partial write 방지
- **self-approve 차단 회피 보존** (R10) — review 제출은 반드시 Reviewer 봇 App(config `reviewer-bot-slug`) installation token 으로. user 토큰 폴백 금지. 토큰 키 누락 시 7-f 의 `--require` 게이트가 fail-fast.

## 자주 하는 실수 (주의!)

- 개별 리뷰 두 Agent(code-reviewer + verifier)는 **같은 메시지 내 병렬 호출**해야 실제 병렬. 순차 메시지는 직렬 실행됨
- Parent 모드 PR 병렬 리뷰도 마찬가지: 한 메시지에 `Agent()` N개
- `gh pr review` CLI는 사용하지 말고 7-f 의 REST API 단일 POST 사용. 이유: line-specific comment + 명시적 `event` 조작이 CLI에선 제한적이고, Reviewer 봇 토큰 명의 부착이 필요
- PR head SHA는 리뷰 시작 시점에 잠금. 리뷰 중 새 커밋이 push되면 SHA 불일치 경고 로그만 남기고 **진행한 리뷰는 제출** (다음 `/review`에서 재리뷰)
- `review-blocked` 라벨명을 `blocked`와 혼동 금지 (`blocked`는 `/kickoff` 소유)
- Status 전환 대상은 **`Status=Bot Review` 인 항목만**. `In Review`·`Done` 이면 스킵. Status=`In Progress` 면 `/kickoff` 가 Status 전환에 실패한 케이스 — 전환은 진행하되 경고 로그 남김
- 수동 PR은 `linkedKickoffSession=null`로 유지. PR 본문 파싱으로 slug 추정하지 않음 (G1). 수동 PR 도 `Closes <owner>/<area>#<sub-N>` 가 있으면 Status 전환 시도 — 없으면 전환 스킵
- 단일 모드 상태 파일 이름에 슬래시·특수문자 금지 (`pr-<repo>-<number>`에서 `<repo>`는 레포명만, org 생략)
- Agent가 JSON 아닌 자유 텍스트로 응답하면 `fixing` 카테고리로 분류. 파싱 재시도 3회 초과 시 즉시 에스컬

## Minor 격차 (구현 중 발견 시 결정)

R1~R11 경계 케이스 결정 기록은 [Minor 격차](reference/minor-gaps.md) 참조.
