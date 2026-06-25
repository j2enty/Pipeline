---
description: parent 이슈로부터 영역별 기획서·플랜·sub-issue를 생성 (옵션 --deep으로 7구간 풀 인터뷰)
argument-hint: <parent-issue-url-or-number> [--deep] [--bot] [--dry-run] [--issue-fixture <path>]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, Skill, AskUserQuestion
disable-model-invocation: true
---

<!-- 이 skill 의 프로젝트값(owner·project-id·토글 등)은 설치 시 치환이 아니라
     실행 시 .claude/pipeline-config.yml 에서 읽는다. 코드펜스는 scripts/pipeline-config.sh
     리더로 값을 주입하고, 프로즈는 아래 "프로젝트 설정 (실행시 주입)" 블록을 참조한다.
     사람이 /pipeline:plan 으로만 호출한다 (모델 자동호출 차단). -->

# /plan — 기능 기획 파이프라인

사용자가 프로젝트 대표 레포에 등록한 parent 이슈를 입력받아 영역별 기획서·플랜·sub-issue를 생성하고 Prep Project에 자동 등록해요.

## 프로젝트 설정 (실행시 주입)

아래는 이 프로젝트의 실제 설정값이다. 프로즈·제목에서 `프로젝트명`·`org`·`대표 레포`·Project ID 등을 언급할 때는 이 값을 쓴다 (하드코딩 금지 — 전부 config 런타임 읽기).

!`bash "${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh" --dump 2>/dev/null || echo "(config 없음)"`

## 사용법

```
/plan <parent-issue-url-or-number>                       # 기본 모드 (가벼운 확인만)
/plan <parent-issue-url-or-number> --deep                # 7구간 풀 인터뷰 모드 (스킵 없이 전부)
/plan <parent-issue-url-or-number> --dry-run             # 안전 모드: 로컬 문서만 생성, 원격(PR·이슈·Project) 반영 스킵
/plan --issue-fixture <path> --dry-run                   # 이슈 입력을 로컬 JSON 픽스처로 격리 (실 GitHub 조회 우회)
```

예 (`<owner>`·`<parent-repo-name>` 은 위 주입된 설정값):
- `/plan https://github.com/<owner>/<parent-repo-name>/issues/12`
- `/plan 12 --deep`
- `/plan 12 --dry-run` — 로컬 문서만 생성하고 멈춤. 골든 픽스처 테스트·드라이런 검증용
- `/plan --issue-fixture test/fixtures/service-status-page.issue.json --dry-run` — 실 이슈 비의존 결정적 테스트 (테스트 하니스 전용 상대경로 — 배포 후에는 절대경로로 지정)

> **`--dry-run` (안전 정지선)**: 로컬 문서(`requirements/`·`plans/`)는 평소대로 쓰되, **원격 쓰기(Docs PR·sub-issue·Project·parent 본문 변경)는 전부 스킵**하고 정상 종료한다. LLM 재량이 아니라 쉘 변수(`DRY_RUN`) 분기로 강제되며, 정지선보다 앞에는 어떤 원격 쓰기 명령도 없다.
>
> **`--issue-fixture <path>`**: parent 이슈를 실제 GitHub에서 조회(`gh issue view`)하지 않고, 지정한 **로컬 JSON 파일**(같은 `--json number,title,body` 형태)에서 읽는다. 외부 상태 비의존 결정적 테스트용. 보통 `--dry-run`과 함께 쓴다.

## 사전 조건

- 활성 계정: 위 주입된 설정의 `local-account` (M1 로컬 단계). `gh auth status`로 확인
- 토큰 스코프: `repo`, `project`, `read:project`, `read:org`
- Parent 이슈는 **사용자가 이미 대표 레포에 생성하고 Prep Project에 등록해둔 상태**여야 함
- Docs 레포가 `Docs/` 하위에 클론되어 있어야 함

## 상수 (Prep Project)

이 섹션의 상수(Org·대표 레포·Project 번호·Project ID·Status/Area 필드 ID 등)는 **실행 시 config에서 읽는다** — 위 "프로젝트 설정 (실행시 주입)" 블록의 `--dump` 출력을 참조한다. 코드펜스에서는 아래 패턴으로 직접 읽어 주입한다:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
bash "$CFG" owner            # Org
bash "$CFG" parent-repo-name # 대표 레포
bash "$CFG" project-number   # Project 번호 (Prep)
bash "$CFG" project-id       # Project ID
bash "$CFG" status-field-id  # Status 필드 ID (Backlog/Planning/Ready/In Progress/In Review/Done)
bash "$CFG" area-field-id    # Area 필드 ID (영역별 옵션)
bash "$CFG" --list-modules   # config 에 정의된 영역(모듈) 목록 — 동작 분기는 이 목록 + 플래그로
```

- 영역(모듈) 목록은 **실행 시 config 에서 읽는다** (`--list-modules`). 모듈명을 SKILL.md 에 하드코딩하지 않는다 — 어느 모듈이 선행(lead)인지·planner 대상인지·기본 Status 가 무엇인지는 전부 모듈 동작표(`--modules-table`)의 플래그로 판단한다.

## 모듈 동작표 (실행시 주입)

영역별 동작 의미론은 **실행 시 config 의 모듈 동작표를 1회 읽어** 판단한다. 표를 출력하고 그 stdout 으로 분기한다 (위 `--dump` 패턴과 동일 — LLM 임의 루프 금지).

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
bash "$CFG" --modules-table   # TSV(헤더행 포함): name·role·planner·review·kickoff·lead·default-status·cross-area-group·area-id·ci-workflow-name
```

표 컬럼 중 `/plan` 이 쓰는 것:

| 컬럼 | 용도 |
|---|---|
| `name` | 영역(모듈)명 — sub-issue 레포·Area 옵션 매칭 |
| `planner` | planner 호출 대상 여부. `false` 면 planner 호출 없이 placeholder 산출물로 처리 |
| `lead` | 선행 영역 표시(`/plan` 은 모든 영역 sub-issue 를 동시 생성하므로 정보 표기용. 선행 실행은 `/kickoff` 소관) |
| `default-status` | 이 모듈 sub-issue 에 부여할 Project Status (예: `Ready` / `Backlog`) |
| `cross-area-group` | 같은 그룹값을 가진 모듈이 2개 이상 선택되면 'Cross-area 일관성' 섹션 추가 트리거 |
| `area-id` | Prep Project Area 옵션 ID |

조회 보조 인터페이스:

```bash
bash "$CFG" --modules-where planner=false     # planner 스킵(placeholder) 모듈명
bash "$CFG" --modules-where lead=true          # 선행(lead) 모듈명
bash "$CFG" module.<Name>.default-status       # 특정 모듈의 기본 Status (대소문자 정확)
bash "$CFG" module.<Name>.area-id              # 특정 모듈의 Area 옵션 ID
bash "$CFG" module.<Name>.cross-area-group     # 특정 모듈의 그룹값(빈 값일 수 있음)
```

> **대소문자 정확**: `module.<Name>.<flag>` 의 `<Name>` 은 표의 `name` 컬럼과 정확히 일치해야 한다 (예: `module.iOS.area-id` ≠ `module.IOS.area-id`).

## 수행 순서

### 0. 단계별 계측 (소요시간·토큰) — 무거운 단계 경계마다

> **왜**: `/plan` 1회가 ~20분 걸리는데 어느 무거운 단계(planner·완결성 critic·정합성
> critic·codex 교차검증)가 범인인지 **데이터로** 드러내기 위함. LLM 추정이 아니라 각 단계의
> **시작 직전·종료 직후에 shell `date +%s`** 로 상태 파일(TSV)에 박는다. 코드펜스는 펜스 간
> 변수 전파가 안 되므로(이 SKILL.md 가 명시) 시각은 **반드시 상태 파일**에 기록한다.

계측 헬퍼: `${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh` (순수 bash, 종속성 제로).
상태 파일 경로는 모든 펜스가 동일하게 재계산할 수 있도록 **parent 번호·slug 로만** 결정한다
(셸 변수 전파 불가 → 경로를 placeholder 로 고정):

```
<적절한 temp 경로> = ${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv
```

각 무거운 단계는 아래 두 펜스로 감싼다 (라벨: `planner`·`completeness-critic`·
`consistency-critic`·`codex-crosscheck`, 선택적으로 `interview`):

```bash
# 단계 시작 직전
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" <라벨> start
```
```bash
# 단계 종료 직후
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" <라벨> end
# [토큰 — best-effort, 선택] 이 단계 Agent 호출 결과에 **표기된** 서브에이전트 usage 토큰이
#   보이면 같은 파일에 기록한다. 추정 금지 — 결과에 명시된 정수만(없으면 시간만 남는다):
#   bash "$METRICS" token "$TSV" <라벨> in  <input_tokens>
#   bash "$METRICS" token "$TSV" <라벨> out <output_tokens>
```

> **계측은 plan 산출물을 절대 바꾸지 않는다**: 위 펜스는 temp TSV 에만 쓰고, 로컬
> 문서(requirements/plans)·원격 반영에 전혀 손대지 않는다. 따라서 `--dry-run` 의 로컬
> 산출물은 계측 유무와 무관하게 동일하다(골든 불변). 최종 리포트(§9.7)에서만 표로 드러난다.

### 1. 입력 파싱

- `$ARGUMENTS`에서 parent 이슈 URL 또는 번호, `--deep`, `--bot`, `--dry-run`, `--issue-fixture <path>` 플래그 추출
- `--bot` 플래그: AskUserQuestion 스킵 → slug·영역 자동 추론, 사용자 확인 없이 진행
- URL 형식: `https://github.com/<owner>/<parent-repo-name>/issues/N` → 번호 `N` 추출 (`<owner>`·`<parent-repo-name>` 은 위 주입된 설정값)
- 번호만 주어지면 대표 레포 기준으로 해석

**플래그를 쉘 변수로 코드화 (LLM 재량 아님 — 반드시 변수 분기로):**

`--dry-run`·`--issue-fixture`는 "실행하지 말라"는 비결정적 지시문이 아니라 **쉘 변수**로 못 박는다.
아래 변수를 먼저 set하고, 이후 모든 단계는 이 변수만 보고 분기한다.

```bash
# 기본값 — 플래그 미지정 시 평소(원격 반영) 동작
DRY_RUN=false        # --dry-run 지정 시 true
ISSUE_FIXTURE=       # --issue-fixture <path> 지정 시 경로, 미지정 시 빈 값
DEEP=false           # --deep 지정 시 true
BOT=false            # --bot  지정 시 true
PARENT_ARG=          # parent 이슈 URL 또는 번호

# glob 확장 비활성화 — ARGUMENTS 안의 * 가 파일 목록으로 펼쳐지는 것 방지
set -f
# $ARGUMENTS 를 토큰 단위로 파싱 — 모든 플래그를 한 루프에서 처리한다.
# (LLM 재량 아님 — 반드시 이 변수 분기로)
set -- $ARGUMENTS
set +f  # noglob 해제
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --deep)     DEEP=true ;;
    --bot)      BOT=true ;;
    # 등호형: --issue-fixture=/path/to/file
    --issue-fixture=*)
      ISSUE_FIXTURE="${1#*=}" ;;
    # 분리형: --issue-fixture /path/to/file
    --issue-fixture)
      case "${2:-}" in
        ""|--*)
          echo "❌ 중단: --issue-fixture 뒤에 경로가 없거나 플래그가 옴: '${2:-}'."
          exit 1 ;;
      esac
      ISSUE_FIXTURE="$2"; shift ;;
    # 미지원 플래그 — 오타 방지를 위해 즉시 거부
    --*)
      echo "❌ 중단: 알 수 없는 플래그 '$1'. 지원: --dry-run, --deep, --bot, --issue-fixture"
      exit 1 ;;
    *)
      # 나머지 토큰은 parent 이슈 URL 또는 번호로 해석
      PARENT_ARG="$1" ;;
  esac
  shift
done

# F3 가드: --issue-fixture 는 반드시 --dry-run 과 함께 사용해야 한다.
# 단독 사용 시 가짜 이슈로 실 PR·sub-issue·Project 가 오염되므로 즉시 거부.
if [ -n "$ISSUE_FIXTURE" ] && [ "$DRY_RUN" != true ]; then
  echo "❌ 중단: --issue-fixture 는 --dry-run 과 함께만 허용합니다 (실 원격 오염 방지)."
  echo "   올바른 사용: /plan --issue-fixture <path> --dry-run"
  exit 1
fi
```

- `DRY_RUN=true`이면 Step 6a 직후의 **🛑 DRY-RUN 정지선**에서 멈추고 정상 종료(exit 0). 원격(PR·이슈·Project·parent) 반영은 전부 스킵.
- `ISSUE_FIXTURE`가 비어있지 않으면 Step 2에서 `gh issue view` 대신 그 로컬 JSON 파일을 읽는다. **반드시 `--dry-run`과 함께** 써야 하며, 단독 사용 시 파싱 직후 즉시 종료된다.

### 2. Parent 이슈 조회

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# R3: 펜스 독립 실행 대비 — $ARGUMENTS 에서 ISSUE_FIXTURE 재파생
# (Step 1 에서 set 한 변수는 펜스 간 전파 보장 없음)
ISSUE_FIXTURE=
set -f; set -- $ARGUMENTS; set +f
while [ $# -gt 0 ]; do
  case "$1" in
    --issue-fixture=*) ISSUE_FIXTURE="${1#*=}" ;;
    --issue-fixture)   ISSUE_FIXTURE="${2:-}"; shift ;;
  esac
  shift
done

# ISSUE_FIXTURE 가 지정되면 실 GitHub 조회를 우회하고 로컬 JSON 픽스처를 읽는다.
#   (외부 상태 비의존 결정적 테스트 경로 — gh 호출 없음)
if [ -n "$ISSUE_FIXTURE" ]; then
  if [ ! -f "$ISSUE_FIXTURE" ]; then
    echo "❌ 중단: --issue-fixture 경로의 파일이 없음: $ISSUE_FIXTURE"
    exit 1
  fi
  # gh issue view 와 동일한 JSON 스키마(number,title,body,...)를 그대로 읽음
  ISSUE_JSON=$(cat "$ISSUE_FIXTURE")
else
  ISSUE_JSON=$(gh issue view <번호> --repo "$(bash "$CFG" owner)/$(bash "$CFG" parent-repo-name)" --json number,title,body,author,assignees,labels,url)
fi
# 이후 제목·본문은 $ISSUE_JSON 에서 추출 (예: echo "$ISSUE_JSON" | jq -r '.title')
```

제목·본문을 보존. 본문이 **50자 미만**이면 `--deep` 모드로 강제 전환 권유 후 사용자 승인 받고 진행.

**fixture 모드의 parent 번호 해소 (R2-F4)**: 쉘 변수는 다른 펜스로 전파되지 않으므로,
`<parent-N>` 같은 **LLM-채움 placeholder 방식은 유지**한다. fixture 모드에서는 LLM이
`$ISSUE_JSON`의 `.number` 값을 읽어 이후 단계의 `<parent-N>` 자리에 채운다.

```bash
# R3: 펜스 독립 실행 대비 — $ARGUMENTS 에서 ISSUE_FIXTURE 재파생
ISSUE_FIXTURE=
set -f; set -- $ARGUMENTS; set +f
while [ $# -gt 0 ]; do
  case "$1" in
    --issue-fixture=*) ISSUE_FIXTURE="${1#*=}" ;;
    --issue-fixture)   ISSUE_FIXTURE="${2:-}"; shift ;;
  esac
  shift
done

# fixture 모드: .number null 가드 — fixture 파일이 number 를 빠뜨리면 즉시 실패
if [ -n "$ISSUE_FIXTURE" ]; then
  PN=$(echo "$ISSUE_JSON" | jq -r '.number')
  case "$PN" in
    ""|null)
      echo "❌ 중단: fixture 파일에 .number 필드가 없거나 null 입니다: $ISSUE_FIXTURE"
      exit 1 ;;
  esac
  # args 에 번호/URL 이 함께 왔으면 일관성 경고 (실모드에서 이 블록은 실행되지 않음)
  if [ -n "${PARENT_ARG:-}" ]; then
    PARENT_ARG_NUM=$(echo "$PARENT_ARG" | grep -oE '[0-9]+$')
    if [ -n "$PARENT_ARG_NUM" ] && [ "$PARENT_ARG_NUM" != "$PN" ]; then
      echo "⚠️  args 번호($PARENT_ARG_NUM)와 fixture .number($PN)가 다릅니다. fixture 값($PN)을 사용합니다."
    fi
  fi
fi
# 이후 단계에서 <parent-N> / <parent-issue-title> 등 LLM-채움 placeholder 는
# fixture 모드이면 $ISSUE_JSON 의 .number / .title 을 읽어 대입하고,
# 실모드이면 args 의 번호·조회된 이슈 제목을 사용한다.
```

### 3. Slug 자동 생성 (영어 kebab-case)

이슈 제목을 읽고 영어 kebab-case **slug를 Claude가 자동 생성**:
- "앱 버전 표시 기능" → `app-version-display`
- "유튜브 쇼츠 가져오기" → `import-youtube-shorts`
- "레시피 저장 기능" → `save-recipe`

생성 규칙:
- 의미 핵심만 남기고 조사·접미사 제거
- 영어 소문자 + 하이픈만 사용
- 3~5단어 내외, 너무 길면 줄임
- 이슈 제목이 이미 영어면 그대로 kebab-case 정규화

파일명·브랜치명은 `<parent-N>-<slug>` 형식 사용 (예: `12-save-recipe`). parent 이슈 번호를 prefix로 붙여 slug 충돌을 원천 차단한다.

### 3.5. 재실행 가드 (Idempotency check)

**실수로 같은 parent에 `/plan`을 두 번 돌리면 중복 sub-issue·Project 아이템·Docs PR이 생기므로, 본 단계에서 fail-fast**:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
# R3: 펜스 독립 실행 대비 — $ARGUMENTS 에서 DRY_RUN·ISSUE_FIXTURE 재파생
# (Step 1 에서 set 한 변수는 펜스 간 전파 보장 없음)
DRY_RUN=false; ISSUE_FIXTURE=
set -f; set -- $ARGUMENTS; set +f
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)         DRY_RUN=true ;;
    --issue-fixture=*) ISSUE_FIXTURE="${1#*=}" ;;
    --issue-fixture)   ISSUE_FIXTURE="${2:-}"; shift ;;
  esac
  shift
done

# dry-run 이거나 --issue-fixture 가 지정된 경우 멱등성 가드 전체를 스킵한다.
# 이유: dry-run 은 아무것도 생성하지 않으므로 중복 방지 가드가 무의미하고,
#       fixture 경로는 실 GitHub/네트워크 비의존이어야 하므로 원격 조회(3.5-a)와
#       네트워크 호출(3.5-c git ls-remote)이 없어야 한다.
if [ "$DRY_RUN" = true ] || [ -n "$ISSUE_FIXTURE" ]; then
  echo "[DRY-RUN] 멱등성 가드(Step 3.5) 스킵 — dry-run/fixture 모드에서는 원격 조회 불필요"
else

# 3.5-a. Parent 이슈 본문에 "📋 Plan 산출물" 섹션이 이미 있는지 확인
BODY=$(gh api /repos/$OWNER/$PARENT_REPO_NAME/issues/<parent-N> --jq '.body')
if echo "$BODY" | grep -q "📋 Plan 산출물"; then
  echo "❌ 중단: $PARENT_REPO_NAME#<parent-N>은 이미 /plan 산출물이 연결되어 있음."
  echo "   재실행이 필요하면 parent 본문의 '📋 Plan 산출물' 섹션과 연관 sub-issue를 먼저 정리할 것."
  exit 1
fi

# 3.5-b. Docs 레포에 <parent-N>-<slug> 관련 파일이 이미 존재하는지 확인
# || exit 1 — 서브셸만 종료하면 부모가 계속 진행하므로 전파 필수
( cd Docs && \
  if [ -f "claude/requirements/<parent-N>-<slug>.md" ] || ls claude/plans/<parent-N>-<slug>-*.md 2>/dev/null | grep -q .; then
    echo "❌ 중단: Docs에 '<parent-N>-<slug>' 관련 기획서/플랜이 이미 존재함."
    echo "   다른 parent의 slug와 충돌했는지 확인하거나, 재실행이 필요하면 해당 파일을 먼저 정리할 것."
    exit 1
  fi
) || exit 1

# 3.5-c. plan/<parent-N>-<slug> 브랜치가 로컬·원격에 이미 존재하는지 확인
# || exit 1 — 동일: 서브셸 exit 1 을 부모로 전파
( cd Docs && \
  if git rev-parse --verify "plan/<parent-N>-<slug>" >/dev/null 2>&1 \
     || git ls-remote --exit-code --heads origin "plan/<parent-N>-<slug>" >/dev/null 2>&1; then
    echo "❌ 중단: 브랜치 plan/<parent-N>-<slug>가 이미 존재함."
    echo "   재실행이 필요하면 해당 브랜치를 먼저 삭제할 것."
    exit 1
  fi
) || exit 1

fi  # dry-run/fixture 스킵 블록 끝
```

**3건 중 어느 하나라도 걸리면 중단 후 사용자 이관.** 자동 복구·덮어쓰기 금지 (기존 산출물 훼손 방지).

정리 팁은 최종 출력에 간단히 안내:
- Parent 본문: 섹션 지우고 사용자 재호출
- Docs 파일: `git rm claude/requirements/<parent-N>-<slug>.md claude/plans/<parent-N>-<slug>-*.md && git commit`
- 브랜치: `git branch -D plan/<parent-N>-<slug>` + `git push origin --delete plan/<parent-N>-<slug>`

### 4. 사용자 인터뷰 (7구간) + 확인

이슈 본문을 먼저 읽고 각 구간의 답이 충분한지 판단한 뒤 질문을 선택적으로 수행한다.
**질문은 하나씩 — 이전 질문 완전 종결 후 다음으로.**

**모드 결정:**
- **기본 모드**: 각 구간 답이 이슈에 이미 있으면 스킵 (단 **4번·5번은 반드시 물어본다**)
- **`--deep` 모드**: 모든 구간 스킵 없이 + 꼬리질문 강화
- **`--bot` 모드**: AskUserQuestion 없이 이슈 본문에서 자동 추론, 미확정 항목은 전부 "○○로 가정함 ← 맞나요?" 형식으로 표시

> 7구간 질문 문구·출처(Heilmeier Catechism·5 Whys·MoSCoW·Working Backwards)·산출 매핑, 인터뷰 후 추가 확인(영역·slug) 상세는 [인터뷰 가이드](reference/interview-guide.md) 참조. 각 구간의 산출은 §3.6 사람용 문서 섹션과 ② AI용 명세로 흘러간다.

### 5. 영역별 플래닝 (planner 에이전트)

② AI용 명세는 **인터페이스 우선** 순서로 만든다: ②a 코드베이스 흡수 → ②b 계약 먼저 → ②c 영역별 명세.

#### ②a. 코드베이스 흡수

planner 호출 전, 프로젝트 SSOT·기존 패턴·관련 메모리를 깊이 읽어 "뻔한 일반론"이 아닌 이 코드베이스에 맞는 명세가 나오게 한다. (planner 에이전트가 영역 플랜 작성 시 자체 수행하되, 아래 계약 작성도 같은 흡수 위에서 한다.)

#### ②b. 영역 간 공유 계약 먼저 작성 (contract.md)

> **이 단계는 실행 시 config 토글로 결정됩니다: `plan.contract-doc-enabled`**
> 아래처럼 config에서 읽어 분기한다. TOGGLE 이 `false`면 contract.md를 만들지 않고 ②c로 진행하세요.
> 또한 **선택된 영역이 1개뿐이면** (인터페이스로 만나는 지점이 없으므로) 계약 문서를 **생략**하고 ②c로 진행하세요.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
TOGGLE="$(bash "$CFG" plan.contract-doc-enabled)"   # 기본 true (config 누락 시 true)
# TOGGLE 이 false 이거나 선택 영역이 1개뿐이면 이 단계(②b)를 스킵하고 ②c로 진행
echo "contract-doc-enabled = $TOGGLE"
```

선택된 영역이 **2개 이상**이고 토글이 `true`이면, 영역별 명세를 쓰기 **전에** 먼저 영역 간 계약을 작성합니다. 같은 API를 영역마다 따로 서술해 어긋나는 것(예: backend `db_status` ↔ admin `dbStatus`)을 원천 차단하는 SSOT입니다.

계약 내용을 [contract 템플릿](reference/contract-template.md)으로 작성해 다음 단계(Step 6a)에서 `plans/<parent-N>-<slug>-contract.md`로 저장할 수 있도록 LLM 컨텍스트에 둡니다.

#### ②c. 영역별 플래닝

**planner 대상 판별** — 선택된 영역 중 `planner=false` 인 모듈은 planner 호출 없이 placeholder 로 처리한다. 대상/스킵 분류는 모듈 동작표로 한다 (특정 모듈명 하드코딩 금지 — 플래그로 판단):

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# planner 스킵(placeholder) 모듈 — 선택 영역 중 이 목록에 든 것은 planner 호출 안 함
bash "$CFG" --modules-where planner=false
```

**Cross-area 일관성 트리거** — 선택된 영역들의 `cross-area-group` 값을 보고, **같은 그룹값을 가진 모듈이 2개 이상이면** 그 그룹의 각 영역 플랜에 'Cross-area 일관성' 섹션을 추가한다. 그룹 이름(예: 무엇이든)·의미 라벨은 하드코딩하지 않고, 오직 그룹값 동일성으로만 판정한다:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# 선택 영역마다 cross-area-group 값을 읽어, 같은 값이 2개 이상인 그룹을 찾는다.
#   예) module.<sel1>.cross-area-group == module.<sel2>.cross-area-group (빈 값 제외) → 그 그룹은 Cross-area 대상.
for area in <선택된 영역들>; do
  bash "$CFG" "module.$area.cross-area-group"
done
# → 동일 비어있지 않은 값이 2개 이상인 그룹의 영역들에 한해 'Cross-area 일관성' 섹션 추가.
```

**[계측] planner 페이즈 시작** — planner 는 여러 영역을 **병렬** 호출하므로, 첫 호출 직전에
페이즈 경계(start)를 한 번 박는다 (개별 영역이 아니라 "모든 planner 호출"을 한 구간으로 측정):

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
# 첫 계측 펜스 — 이전 실행이 §9.7 정리 전에 중단돼 남은 잔여 TSV 의 누적 오염(특히 토큰
#   합산)을 차단하려고 여기서 1회 truncate 한다(이후 mark/token 은 append).
bash "$METRICS" reset "$TSV"
bash "$METRICS" mark "$TSV" planner start
```

선택된 `planner=true` 영역마다 Agent 호출:

```
Agent(
  description="<영역> 플랜 작성",
  subagent_type="pipeline:planner",
  prompt="Parent issue title/body + 선택 영역 + 다른 영역과의 의존성을 받아 <영역> 구현 플랜을 작성.
          출력 섹션: 목표 / 구현 태스크 리스트 / 인수 기준 / 예상 난이도 / 다른 영역과의 인터페이스
          [계약 참조] ②b 계약 문서(contract.md)가 있으면, 영역 간 인터페이스(API 필드명·타입·규약)는 **다시 정의하지 말고 계약을 참조**한다('계약 §API 스키마의 X 필드를 소비' 식). 계약과 어긋나는 서술 금지.
          [추가] 이 영역이 'Cross-area 일관성' 트리거 그룹(같은 cross-area-group 값을 가진 영역이 2개 이상)에 속하면 'Cross-area 일관성' 섹션도 추가:
            - 비동기·타이머 취소 정책 (cancel/cleanup 패턴)
            - 미주입·에러 값 fallback 리터럴 (예: '-')
            - 접근성 라벨 전략 (merge vs override vs hint 분리)"
)
```

- `planner=false` 모듈은 planner 호출 없이 "TBD placeholder" 고정 내용으로 처리 (산출물 경로는 6a 참조)
- 여러 영역은 **병렬 실행**
- **Cross-area 3축 명시 룰**: 같은 `cross-area-group` 값을 가진 영역이 2개 이상 선택된 경우, 그 그룹 각 영역 플랜에 위 3축을 미리 명시해 격차 예방.

**[계측] planner 페이즈 종료** — 모든 planner 호출이 반환된 직후 페이즈 경계(end)를 박는다.
토큰이 각 planner 호출 결과에 표기됐으면 best-effort 로 기록(없으면 시간만):

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" planner end
# [선택·추정금지] 각 planner 호출 결과에 표기된 input/output 토큰이 보이면 합산해 기록:
#   bash "$METRICS" token "$TSV" planner in  <표기된 input_tokens 합>
#   bash "$METRICS" token "$TSV" planner out <표기된 output_tokens 합>
```

### 5.5. ③ 완결성 critic

> **이 단계는 실행 시 config 토글로 결정됩니다: `plan.completeness-critic-enabled`**
> 아래처럼 config에서 읽어 분기한다. TOGGLE 이 `false`면 이 단계 전체를 스킵하고 Step 6으로 진행하세요.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
TOGGLE="$(bash "$CFG" plan.completeness-critic-enabled)"   # 기본 true (config 누락 시 true)
echo "completeness-critic-enabled = $TOGGLE"
```

Step 5에서 생성한 각 영역 플랜(LLM 컨텍스트의 planner 출력)을 대상으로 완결성 critic을 실행합니다. 파일로 쓰기 전에 구멍을 먼저 잡는 단계입니다.

**Agent 호출** (완결성 모드):

> **모델 고정**: critic 품질은 모델에 민감하다(G-1 검증서 sonnet은 rate limit 누락을 놓치고 opus는 잡음).
> 약한 모델로 떨어지면 핵심 구멍을 놓치므로 **반드시 `model="opus"`로 호출**한다.

**[계측] 완결성 critic 시작** — toggle 이 `true`라 이 단계를 실제로 도는 경우에만 (스킵 시엔 안 박음):

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" completeness-critic start
```

```
Agent(
  description="③ 완결성 critic — AI용 명세 검토",
  subagent_type="pipeline:critic",
  model="opus",
  prompt="pipeline:critic 을 **완결성 모드**로 호출. [Step 5 planner 출력 내용 전달].
          출력은 '명세 보강 가능(자동 처리 가능)' / '★ 결정할 것(사람 판단 필요)' 2분류."
)
```

(체크리스트 전문 — 표준 보안 누락·에러경계·영역 인터페이스·acceptance 검증가능성·모호어·인터뷰 제약 반영 — 은 `pipeline:critic` 시스템프롬프트에 이미 승격되어 있다. 호출은 모드 키워드만 전달한다.)

**[계측] 완결성 critic 종료** — Agent 반환 직후:

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" completeness-critic end
# [선택·추정금지] 결과에 표기된 토큰이 보이면:
#   bash "$METRICS" token "$TSV" completeness-critic in  <표기된 input_tokens>
#   bash "$METRICS" token "$TSV" completeness-critic out <표기된 output_tokens>
```

**결과 반영 규칙 (Step 6a 문서 생성 시 적용):**
- "명세 보강 가능" 항목 → AI용 명세 파일에 직접 포함
- "★ 결정할 것" 항목 → 사람용 `## 당신이 결정할 것` 섹션에 추가

### 6. 문서 저장 (Docs 레포에 커밋·PR)

`Docs/` 하위 작업 (Docs는 별도 레포):

> **구조 — 펜스별 self-guard + 보조 정지선**: LLM은 각 코드펜스를 별도 Bash 호출로 실행할 수 있어 Step 1에서 set한 `DRY_RUN` 변수가 다른 펜스로 전파되지 않는다. 따라서 **실제 안전 보장은 원격 쓰기 펜스 각각의 상단에 박힌 `$ARGUMENTS` self-guard**가 담당한다. `$ARGUMENTS`는 모든 펜스에 substitution되므로 변수처럼 증발하지 않는다.
> 6a 직후의 🛑 정지선(DRY_RUN 분기)은 **가독성·참고용**으로 남기지만, 6b 이후 각 펜스가 자체 가드를 갖는다.

#### 6a. 로컬 파일 생성 (dry-run에서도 수행 — G-1 검증 대상)

**파일 생성:**
- `Docs/claude/requirements/<parent-N>-<slug>.md` — 사람용 기획서 (운영자가 GO/수정 판단하는 문서)
- [사람용 문서 템플릿(§3.6)](reference/requirements-template.md)을 채워서 작성한다.

> **편집 기준**: "이 정보가 운영자의 GO/수정 판단을 바꾸는가?" — 아니면 뺀다. 구현 디테일·자명한 것은 AI용 plans/로 내린다.
> **가정+표시**: AI가 인터뷰 답 없이 채운 항목은 반드시 "○○로 가정함 ← 맞나요?"로 `결정할 것` 섹션에 노출 (조용한 기정사실화 차단).

**또한 생성:**
- `Docs/claude/plans/<parent-N>-<slug>-contract.md` — **영역 간 공유 계약. ②b에서 실제로 작성된 경우에만 저장한다 (②b가 토글 off·단일 영역으로 스킵됐으면 이 파일은 없음 — 여기서 새로 만들지 말 것).**
- **선택된 각 영역마다** `Docs/claude/plans/<parent-N>-<slug>-<영역소문자>.md` (영역명 = `--list-modules` 의 이름을 소문자화). 예: 영역 `Backend` → `...-backend.md`.
  - `planner=true` 영역 → ②c planner 산출물을 저장.
  - `planner=false` 영역 → planner 호출 없이 [placeholder 템플릿](reference/design-placeholder-template.md) 으로 채운 placeholder 산출물 저장 (Parent 줄의 `<owner>/<parent-repo-name>` 은 위 주입된 설정값으로 채운다).

#### 6.5. ⑤ 정합성 critic

> **이 단계는 실행 시 config 토글로 결정됩니다: `plan.consistency-critic-enabled`**
> 아래처럼 config에서 읽어 분기한다. TOGGLE 이 `false`면 이 단계를 스킵하고 🛑 DRY-RUN 정지선으로 진행하세요.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
TOGGLE="$(bash "$CFG" plan.consistency-critic-enabled)"      # 기본 true (config 누락 시 true)
DUAL="$(bash "$CFG" plan.consistency-critic-dual-model)"     # 기본 true (config 누락 시 true)
echo "consistency-critic-enabled = $TOGGLE / dual-model = $DUAL"
```

Step 6a에서 생성한 사람용 + AI용 문서를 대상으로 정합성을 검증합니다. 사람 게이트 직전 마지막 기계 방어선입니다.

**이중 모델 설정: `plan.consistency-critic-dual-model` (위 `$DUAL`)**
- `true`: Claude + Codex 교차 검증 (두 결과 합산 후 처리)
- `false`: Claude만 실행

**1단계 — Claude critic** (정합성 모드, ③과 동일 이유로 **반드시 `model="opus"`** — 약한 모델은 핵심 누락을 놓친다):

**[계측] 정합성 critic(Claude) 시작** — toggle 이 `true`라 이 단계를 실제로 도는 경우에만:

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" consistency-critic start
```

```
Agent(
  description="⑤ 정합성 critic (Claude) — 사람용↔AI용 대조",
  subagent_type="pipeline:critic",
  model="opus",
  prompt="pipeline:critic 을 **정합성 모드**로 호출.
          - 사람용: Docs/claude/requirements/<parent-N>-<slug>.md
          - AI용: Docs/claude/plans/<parent-N>-<slug>-*.md
          [위 두 문서의 경로/내용 전달]. 불일치 항목과 수정 방향을 구체적으로 제시."
)
```

(체크리스트 전문 — 사람용↔AI용 일대일 대응·미승인 결정·가정 반영·영역교차·의도추적 — 은 `pipeline:critic` 시스템프롬프트에 이미 승격되어 있다. 호출은 모드 키워드와 문서 경로만 전달한다.)

**[계측] 정합성 critic(Claude) 종료** — Claude critic Agent 반환 직후 (codex 교차검증은 별도 라벨로 측정):

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" consistency-critic end
# [선택·추정금지] 결과에 표기된 토큰이 보이면:
#   bash "$METRICS" token "$TSV" consistency-critic in  <표기된 input_tokens>
#   bash "$METRICS" token "$TSV" consistency-critic out <표기된 output_tokens>
```

**`$DUAL`이 `true`이면 2단계 실행 — 외부 2차 모델 교차검증 (범용 `pipeline:ask` 에이전트를 교차검증 용도로 best-effort 호출):**

사용할 2차 도구는 config 키 `cross-check-tool`(기본 `codex`)에서 읽어 주입한다. codex 하드코딩이 아니라 도구명을 주입받는 방식이라, 다른 도구(gemini 등)로도 바꿀 수 있다.

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
TOOL="$(bash "$CFG" cross-check-tool)"   # 기본 codex (config 누락 시 codex)
echo "cross-check-tool = $TOOL"
```

**[계측] codex 교차검증 시작** — `$DUAL`이 `true`라 2단계를 실제로 도는 경우에만 (best-effort
호출이라 도구가 없어 즉시 스킵돼도 start~end 구간이 ~0초로 나오는 게 정상 — 그 자체가 "교차검증
비용 없음"의 증거):

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" codex-crosscheck start
```

```
Agent(
  description="⑤ 정합성 critic 2차 — 외부 모델 교차검증",
  subagent_type="pipeline:ask",
  prompt="도구=${TOOL}. 정책=best-effort(도구 없으면 조용히 스킵). 작업=정합성 교차검증.
          아래 두 문서의 정합성을 검토해줘: [사람용·AI용 문서 내용 전달]
          체크리스트: 사람용↔AI용 일대일 대응 / 미승인 결정 / 가정 반영 / 영역교차 일치 / 의도추적"
)
```

(범용 `pipeline:ask` 에이전트를 교차검증 용도로 best-effort 호출하므로, 도구 미설치·실패·무응답 시 자동 스킵된다. 2차 의견을 못 얻어도 파이프라인은 막히지 않고 1단계 Claude critic 결과만으로 진행한다. 즉 `dual-model=true` 라도 2차 도구가 없으면 단일 critic 으로 동작하므로, 2모델 교차를 보장하려면 `cross-check-tool` 도구를 러너에 설치해야 한다 — Pipeline 프로토콜의 "Codex 교차검증은 best-effort" 정책과 일치.)

**[계측] codex 교차검증 종료** — 2차 Agent 반환(또는 스킵) 직후:

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
bash "$METRICS" mark "$TSV" codex-crosscheck end
```

**결과 처리:**
- 불일치 발견 → Edit 도구로 해당 파일 직접 수정
- ★결정할것 중 AI용에서 미승인 결정 발견 → 사람용에 항목 추가 + 사용자에게 알림
- 양쪽 findings 합산해 처리
- 완료 후 한 줄 요약: "⑤ critic: [N]건 수정됨 — [수정 항목 목록]"

#### 🛑 DRY-RUN 정지선 (6a 직후 · 6b 직전)

**여기까지가 로컬 쓰기, 여기서부터가 원격 반영이다.** dry-run이면 이 지점에서 멈춘다.
이 정지선보다 **앞에는 원격 쓰기 명령이 하나도 없으므로**, 아래 분기 한 번으로 PR·이슈·Project·parent 변경을 전부 안전하게 스킵할 수 있다.

```bash
# R3: 펜스 독립 실행 대비 — $ARGUMENTS 에서 DRY_RUN 재파생 (가독성용 보조 정지선)
DRY_RUN=false
set -f; set -- $ARGUMENTS; set +f
while [ $# -gt 0 ]; do
  case "$1" in --dry-run) DRY_RUN=true ;; esac
  shift
done

if [ "$DRY_RUN" = true ]; then
  echo "[DRY-RUN] 로컬 문서 생성 완료. 원격(PR·이슈·Project·parent) 반영은 스킵합니다."
  echo "[DRY-RUN] 생성된 로컬 문서:"
  echo "  - Docs/claude/requirements/<parent-N>-<slug>.md"
  echo "  - Docs/claude/plans/<parent-N>-<slug>-*.md"
  echo "[DRY-RUN] 여기서 멈춤. Step 6b(git/PR)·Step 7(sub-issue)·Step 8(Project)·Step 9(parent 본문)는 실행하지 않습니다."
  # [계측] dry-run 도 콘솔 요약은 출력(원격 코멘트만 스킵). 출력 후 상태파일 정리.
  METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
  TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"
  bash "$METRICS" report "$TSV" || true
  rm -f "$TSV" 2>/dev/null || true
  exit 0
fi
```

#### 6b. 원격 반영 — git 커밋·PR (dry-run 아닐 때만)

**Git 작업 (Docs 레포 기준):**
```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# [R2 self-guard] 이 펜스는 원격 쓰기(git push·gh pr create)를 수행한다.
# $ARGUMENTS 는 모든 펜스에 substitution되므로 DRY_RUN 변수 전파 없이도 안전하게 검사 가능.
case " $ARGUMENTS " in *" --dry-run "*) echo "[DRY-RUN] Step 6b(git/PR) 원격 반영 스킵"; exit 0 ;; esac
# [필수 config 게이트] 빈 owner/parent-repo-name 이 gh/PR 로 흘러 엉뚱한 대상을 건드리는 것 차단(fail-fast).
bash "$CFG" --require owner parent-repo-name || exit 1
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
cd Docs
git checkout -b plan/<parent-N>-<slug>
git add claude/requirements/<parent-N>-<slug>.md claude/plans/<parent-N>-<slug>-*.md
git commit -m "[plan] <parent-issue-title> 기획서·플랜 추가 (#<parent-number>)"
git push -u origin plan/<parent-N>-<slug>
gh pr create --title "[plan] <parent-issue-title>" --body "Parent: $OWNER/$PARENT_REPO_NAME#<N>"
```

**Docs 영역 정책 (2026-05-07 확정):** plan PR(`plan/<parent-N>-<slug>` 브랜치) 만으로 기획·플랜 작업을 추적한다. **Docs 레포에 sub-issue를 만들지 않으며 Prep Project 칸반에도 Docs 카드를 만들지 않는다.** Step 7의 sub-issue 생성 대상은 config 에 정의된 코드 영역(`--list-modules`)에 한정 — Docs 는 모듈 목록에 없으므로 자연히 제외.

### 7. Sub-issue 생성 (영역 레포에)

선택된 영역마다:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# [R2 self-guard] 이 펜스는 원격 쓰기(gh label create·gh issue create·sub_issues)를 수행한다.
case " $ARGUMENTS " in *" --dry-run "*) echo "[DRY-RUN] Step 7(sub-issue 생성) 원격 반영 스킵"; exit 0 ;; esac
# [필수 config 게이트] 빈 값이 sub-issue 대상 레포·어싸이니로 흘러가는 것 차단(fail-fast).
bash "$CFG" --require owner author-login || exit 1
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"

# 7-a-pre. 'plan' 라벨이 없으면 생성 (이미 있으면 noop)
gh label create plan \
  --repo $OWNER/<영역> \
  --color "0075ca" \
  --description "/plan 커맨드로 생성된 기획-기반 sub-issue" \
  2>/dev/null || true

# 7-a. 영역 레포에 sub-issue 생성
#   제목은 parent 이슈 제목 그대로 사용 (영역/slug prefix 없음).
#   영역은 레포 자체 + Project Area 필드, parent 연결은 native sub_issues API로 식별.
SUB_URL=$(gh issue create \
  --repo $OWNER/<영역> \
  --title "<parent-issue-title>" \
  --body "Parent: $OWNER/$PARENT_REPO_NAME#<N>\n플랜: Docs/claude/plans/<parent-N>-<slug>-<영역>.md" \
  --assignee "$(bash "$CFG" author-login)" \
  --label plan)

SUB_NUMBER=$(echo "$SUB_URL" | grep -oE '[0-9]+$')

# 7-b. sub-issue의 database id 조회
SUB_ID=$(gh api /repos/$OWNER/<영역>/issues/$SUB_NUMBER --jq '.id')

# 7-c. parent와 sub-issue 링크 (GitHub 네이티브 sub-issues API)
gh api --method POST \
  /repos/$OWNER/$PARENT_REPO_NAME/issues/<parent-N>/sub_issues \
  -F sub_issue_id=$SUB_ID

# 7-d. [강제] Project "Sub-issues progress" 인덱서 race condition 방지
#   ── 배경 ────────────────────────────────────────────────────────────
#   GitHub Projects 의 "Sub-issues progress" 위젯은 sub-issue 관계
#   자체(GraphQL subIssues)가 아니라 별도 인덱서 캐시를 참조한다.
#   처음 sub-issue 가 추가되는 신규 영역 레포(예: 첫 Admin#1)에서는
#   인덱서가 그 레포를 등록하기 전에 add 이벤트가 먼저 도착해
#   카운트가 누락되는 race condition 이 발생할 수 있다.
#   관찰 사례: 신규 레포의 첫 sub-issue 추가 시 분모가 stale 되어
#   "0/1" 로 표시됨. GraphQL subIssues.totalCount 는 정상이라 데이터
#   레이어는 멀쩡, UI 인덱서만 stale 한 형태.
#   ── 대응 ────────────────────────────────────────────────────────────
#   add 직후 한 번 detach + re-add. 두 번째 add 는 인덱서가 해당
#   레포를 이미 알고 있는 상태에서 발생하므로 안전하게 카운트된다.
#   정상 케이스에는 잠깐 detach 되었다가 다시 붙는 무해한 동작이고
#   (총 추가 API 호출 2회), race 케이스에는 분모 보정 효과가 있다.
#   비용보다 효용이 명확해 모든 sub-issue 에 일괄 적용한다.
gh api --method DELETE \
  /repos/$OWNER/$PARENT_REPO_NAME/issues/<parent-N>/sub_issue \
  -F sub_issue_id=$SUB_ID >/dev/null
gh api --method POST \
  /repos/$OWNER/$PARENT_REPO_NAME/issues/<parent-N>/sub_issues \
  -F sub_issue_id=$SUB_ID >/dev/null
```

**주의:**
- `-F` (raw field, integer). `-f`는 string으로 보내서 422 실패.
- 7-d 는 절대 생략 금지. 신규 영역 레포의 첫 sub-issue 가 Project
  progress 분모에서 누락되는 race 를 막는 가드. 정상 케이스에도
  추가 호출 2회만으로 끝나므로 모두 통과시킨다.
- sub-issue 어싸이니는 `$(bash "$CFG" author-login)`(PR 작성 봇 또는 운영 계정 로그인)로 실행시 config에서 읽는다.

### 8. Prep Project에 sub-issue 추가 + Area/Status 세팅

각 sub-issue마다:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# [R2 self-guard] 이 펜스는 원격 쓰기(addProjectV2ItemById·updateProjectV2ItemFieldValue)를 수행한다.
case " $ARGUMENTS " in *" --dry-run "*) echo "[DRY-RUN] Step 8(Project 세팅) 원격 반영 스킵"; exit 0 ;; esac
# [필수 config 게이트] 빈 Project/필드 ID 로 잘못된 GraphQL mutation 을 날리는 것 차단(fail-fast).
bash "$CFG" --require project-id area-field-id status-field-id || exit 1
PROJECT_ID="$(bash "$CFG" project-id)"
AREA_FIELD_ID="$(bash "$CFG" area-field-id)"
STATUS_FIELD_ID="$(bash "$CFG" status-field-id)"

# 8-a. Project에 item으로 추가
ITEM_ID=$(gh api graphql -f query='
mutation($projectId: ID!, $contentId: ID!) {
  addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
    item { id }
  }
}' -f projectId="$PROJECT_ID" -f contentId="<sub-issue-node_id>" \
  --jq '.data.addProjectV2ItemById.item.id')

# 8-b. Area 필드 값 세팅
gh api graphql -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId
    itemId: $itemId
    fieldId: $fieldId
    value: { singleSelectOptionId: $optionId }
  }) { projectV2Item { id } }
}' -f projectId="$PROJECT_ID" \
  -f itemId="$ITEM_ID" \
  -f fieldId="$AREA_FIELD_ID" \
  -f optionId="<area-option-id>"

# 8-c. Status 세팅 — 모듈의 default-status 플래그를 따른다 (Status 이름 하드코딩 금지)
#   <area> = 이 sub-issue 의 영역명. 기본 Status 는 module.<area>.default-status (기본 Ready).
#   예: 디자인류 영역은 config 에서 default-status=Backlog → 그 값으로 세팅됨.
gh api graphql -f query='...updateProjectV2ItemFieldValue...' \
  -f fieldId="$STATUS_FIELD_ID" \
  -f optionId="<default-status-option-id>"
```

**Area option ID (실행 시 config 에서 읽음 — 모듈 동작표의 `area-id` 컬럼):**
```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# <area> = 이 sub-issue 의 영역명 (표의 name 컬럼과 정확히 일치 — 대소문자 주의)
bash "$CFG" "module.<area>.area-id"
# 전체 영역의 area-id 를 한 번에 보려면:
bash "$CFG" --modules-table   # area-id 컬럼 참조
```

**기본 Status 결정 — 모듈의 `default-status` 플래그 (Status 이름 하드코딩 금지):**
```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# 이 영역의 기본 Status 이름 (미지정 모듈은 Ready, 예: 디자인류는 Backlog)
DEFAULT_STATUS="$(bash "$CFG" "module.<area>.default-status")"   # 빈 값이면 Ready 로 간주
[ -n "$DEFAULT_STATUS" ] || DEFAULT_STATUS="Ready"
# 위 이름으로 option ID 동적 조회
gh project field-list "$(bash "$CFG" project-number)" --owner "$(bash "$CFG" owner)" --format json \
  | jq -r --arg s "$DEFAULT_STATUS" '.fields[] | select(.name=="Status") | .options[] | select(.name==$s) | .id'
```

### 9. Parent 이슈 본문 업데이트

Parent 이슈 본문 하단에 "📋 Plan 산출물" 섹션 추가 (또는 코멘트로 첨부). 아래 템플릿의 `<owner>` 는 위 주입된 설정값으로 채운다:

```markdown
---

## 📋 Plan 산출물 (by /plan)

**Slug:** <parent-N>-<slug>

- **기획서:** [Docs/claude/requirements/<parent-N>-<slug>.md](링크)
- **영역별 플랜:**
  - Backend: [Docs/claude/plans/<parent-N>-<slug>-backend.md](링크)
  - Frontend: [Docs/claude/plans/<parent-N>-<slug>-frontend.md](링크)
  - ...
- **Sub-issues:** (코드 영역만 — Docs는 sub-issue 없음)
  - <owner>/Backend#<N>
  - <owner>/Frontend#<N>
  - ...
- **Docs PR:** [plan/<parent-N>-<slug>](링크)

*Parent Status는 사용자가 직접 관리합니다. `/plan`은 Parent의 Status 필드를 건드리지 않습니다.*
```

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# [R2 self-guard] 이 펜스는 원격 쓰기(gh issue edit — parent 본문 업데이트)를 수행한다.
case " $ARGUMENTS " in *" --dry-run "*) echo "[DRY-RUN] Step 9(parent 본문 업데이트) 원격 반영 스킵"; exit 0 ;; esac
# [필수 config 게이트] 빈 owner/parent-repo-name 으로 엉뚱한 parent 이슈를 건드리는 것 차단(fail-fast).
bash "$CFG" --require owner parent-repo-name || exit 1
OWNER="$(bash "$CFG" owner)"
PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
gh issue edit <parent-N> --repo $OWNER/$PARENT_REPO_NAME --body "<기존 본문>\n\n<위 섹션>"
```

### 9.5. 자가 검증 체크 (Self-check)

최종 리포트 직전에 아래 항목을 각 sub-issue마다 확인하고, 누락된 게 있으면 **보정 후 진행**:

```bash
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
# [R2 self-guard] 이 펜스는 원격 쓰기(gh issue edit — 어싸이니 보정)를 수행할 수 있다.
case " $ARGUMENTS " in *" --dry-run "*) echo "[DRY-RUN] Step 9.5(자가 검증 보정) 원격 반영 스킵"; exit 0 ;; esac
# [필수 config 게이트] 빈 owner/author-login 으로 잘못된 어싸이니 보정을 하는 것 차단(fail-fast).
bash "$CFG" --require owner author-login || exit 1
OWNER="$(bash "$CFG" owner)"
# 각 sub-issue마다:
ASSIGNEES=$(gh api /repos/$OWNER/<영역>/issues/$SUB_NUMBER --jq '[.assignees[].login] | join(",")')
if [ -z "$ASSIGNEES" ]; then
  gh issue edit $SUB_NUMBER --repo $OWNER/<영역> --add-assignee "$(bash "$CFG" author-login)"
  echo "⚠️ 보정: <영역>#$SUB_NUMBER 어싸이니 추가"
fi
```

**체크리스트 (sub-issue별):**
- [ ] `assignees` 비어있지 않음 (기본: config의 `author-login`)
- [ ] `labels`에 `plan` 포함됨 — 없으면 `gh issue edit <N> --repo ... --add-label plan`으로 보정
- [ ] sub-issue가 parent(대표 레포#N)의 `sub_issues`에 링크됨 — `gh api /repos/<owner>/<parent-repo-name>/issues/<N>/sub_issues`로 확인
- [ ] Prep Project에 등록됨 + `Area` = 해당 영역 + `Status` = 해당 모듈의 `default-status` (`module.<area>.default-status`, 기본 Ready)

**체크리스트 (공통):**
- [ ] Docs PR 생성됨
- [ ] Parent 이슈 본문에 "📋 Plan 산출물" 섹션 추가됨

누락 항목은 즉시 보정. 보정 불가(권한/네트워크 등)면 최종 리포트에 ⚠️ 표기하여 사용자에게 이관.

### 9.7. 단계별 소요시간 리포트 (계측 집계 — §0 의 상태파일 읽기)

§0 에서 무거운 단계마다 박은 상태파일(TSV)을 읽어 **단계별 소요시간(+있으면 토큰) 표**를
집계한다. 이 단계는 **읽기 전용 집계 + (토글 ON 일 때만) parent 코멘트 박제**라 plan 산출물을
바꾸지 않는다. (dry-run 은 위 🛑 정지선에서 이미 콘솔 요약 후 종료했으므로 이 펜스엔 도달하지 않음 —
그래도 self-guard 를 둬 혹시 모를 도달 시 원격 코멘트만 막는다.)

```bash
METRICS="${CLAUDE_SKILL_DIR}/scripts/plan-metrics.sh"
CFG="${CLAUDE_SKILL_DIR}/scripts/pipeline-config.sh"
TSV="${TMPDIR:-/tmp}/plan-metrics-<parent-N>-<slug>.tsv"

# (1) 항상: 사람이 읽는 콘솔 표를 §10 최종 리포트 직전에 출력.
bash "$METRICS" report "$TSV" || true

# (2) 토글 ON + dry-run 아님 → parent 이슈에 '📊 plan timing' 코멘트로 박제(best-effort).
#     [R2 self-guard] 이 펜스는 원격 쓰기(gh issue comment)를 할 수 있다 — $ARGUMENTS 로 dry-run 차단.
#     (dry-run 은 코멘트만 스킵하고 위 콘솔 (1) 은 이미 출력됨.)
POST_COMMENT=true
case " $ARGUMENTS " in *" --dry-run "*) POST_COMMENT=false ;; esac
# 계측 토글(metrics.usage-tracking-enabled, 기본 false=opt-in)이 true 일 때만 박제.
TOGGLE="$(bash "$CFG" metrics.usage-tracking-enabled 2>/dev/null || echo false)"
[ "$TOGGLE" = "true" ] || POST_COMMENT=false

if [ "$POST_COMMENT" = true ]; then
  # [필수 config 게이트] 빈 owner/parent-repo-name 으로 엉뚱한 이슈에 코멘트하는 것 차단.
  if bash "$CFG" --require owner parent-repo-name; then
    OWNER="$(bash "$CFG" owner)"
    PARENT_REPO_NAME="$(bash "$CFG" parent-repo-name)"
    BODY="$(bash "$METRICS" report-comment "$TSV" || true)"
    # 데이터 없으면 report-comment 가 빈 출력 → 코멘트 스킵.
    if [ -n "$BODY" ] && command -v gh >/dev/null 2>&1; then
      gh issue comment "<parent-N>" --repo "$OWNER/$PARENT_REPO_NAME" --body "$BODY" >/dev/null 2>&1 \
        || echo "⚠️  plan timing 코멘트 박제 실패(best-effort 스킵)" >&2
    fi
  fi
fi

# (3) 상태파일 정리 — 집계·박제 끝났으면 제거(다음 실행 오염 방지).
rm -f "$TSV" 2>/dev/null || true
```

### 10. 최종 리포트

사용자에게 요약 출력:

```
/plan 완료 — <parent-issue-title>

Slug: <parent-N>-<slug>
영역: Backend, Frontend  (iOS/Android/Design 제외)

📄 문서:
  - Docs PR: <링크>

🔗 Sub-issues (Prep Project에 추가 완료, 코드 영역만):
  - Backend#N  [Status=Ready]
  - Frontend#N [Status=Ready]

📊 plan 단계별 소요시간 (§9.7 집계 — 예시):
  planner(영역 플래닝)   3m12s
  완결성 critic          4m05s
  정합성 critic          4m40s
  교차검증(codex 등)     2m10s
  합계(측정 구간)        14m07s

▶ 다음: /kickoff <parent-issue-url>
```

> 위 "📊 plan 단계별 소요시간" 블록은 §9.7 이 `plan-metrics.sh report` 로 출력한 표를 그대로
> 옮긴 것이다(실측값으로 채워짐). 계측 토글(`metrics.usage-tracking-enabled`)이 ON 이면 같은
> 표가 parent 이슈에도 `📊 plan timing` 코멘트로 박제된다.

## 원칙 (지켜야 할 것)

- **Parent Status는 건드리지 않음** — 사용자 소유
- **영역 선택 안 된 건 건너뜀** — 불필요한 sub-issue 생성 금지
- **lead(선행) 모듈의 선행 실행 규칙은 `/kickoff`에서 처리** — `/plan`은 모든 영역의 sub-issue를 동시 생성 (lead 여부는 정보 표기일 뿐 `/plan` 동작에 영향 없음)
- **실패 시 자동 복구 금지** — 중간 단계 실패 시 즉시 중단하고 현재까지 상태 리포트 후 사용자에게 이관
- **멱등성: 중복 생성 금지** — 이미 `/plan` 산출물이 연결된 parent 혹은 이미 존재하는 slug 산출물이 있으면 Step 3.5에서 중단 (덮어쓰기 없음, `--force` 없음)
- **`planner=false` 모듈은 TBD placeholder만** — planner 호출하지 않고 placeholder 산출물로 처리. sub-issue 는 만들되 Status 는 그 모듈의 `default-status`(예: Backlog) 를 따른다. 대상은 `--modules-where planner=false` 가 정함 (특정 모듈명 하드코딩 금지)

## 자주 하는 실수 (주의!)

- `gh api ... -f sub_issue_id=<숫자>` → **422 Invalid type**. 반드시 `-F` (raw) 사용
- Parent 이슈가 Prep Project에 없으면 "user가 직접 추가하지 않음" 상태 → 경고만 띄우고 진행 (`/plan`이 강제로 추가하지 않음 — parent 소유권 사용자)
- Docs 레포가 없으면 Docs 파일 저장 단계에서 안내 후 중단
