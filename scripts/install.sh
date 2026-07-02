#!/usr/bin/env bash
# install.sh — Pipeline 이식 자동화 스크립트
#
# 사용법:
#   ./scripts/install.sh [<pipeline-config.yml 경로>] [옵션]
#
# 기본 config 경로: examples/reclip/pipeline-config.yml
#
# 옵션:
#   --env-file <path>    생성할 .env 경로 (기본: app/.env)
#                        운영 .env 를 덮어쓰지 않고 sandbox 용 별도 .env 를 만들 때 사용
#   --port <n>           .env 에 쓸 PORT 값 (기본: 3000)
#                        운영 컨테이너와 포트 충돌을 피할 때 사용
#   --non-interactive    프롬프트·체크리스트 스킵, App 자격을 환경변수에서 읽음
#                        (off 가 기본 — 플래그 없으면 기존 대화형 동작 유지)
#   --update-commands-only
#                        secrets/variables/caller-yml/env 전부 스킵하고
#                        config 파싱 + 런타임 config(.claude/pipeline-config.yml) 재생성만
#                        실행 후 종료 (config 수정 후 빠른 로컬 재생성용)
#                        (플래그명은 하위호환 위해 유지 — 플러그인 전환으로 실역할은 config 재생성)
#   --reapply            secrets/.env/런타임 config/npm 전부 스킵하고
#                        variables + 추적 라벨 + 호출자 yml 만 멱등 재적용 후 종료.
#                        운영 App 가동 중 부분 재적용용 — app/.env(WEBHOOK_SECRET) 불변 보장.
#   --rotate-webhook-secret
#                        기존 .env 의 WEBHOOK_SECRET 을 보존하지 않고 새로 생성(의도적 회전).
#                        풀 install 시에만 의미 있음(--reapply 는 .env 자체를 안 건드림).
#                        회전 후 양쪽 GitHub App 의 webhook secret 재설정 필요.
#
# 비대화형 모드(--non-interactive)에서 읽는 환경변수:
#   AUTHOR_APP_ID, AUTHOR_PEM(=PEM 파일 경로), AUTHOR_INSTALLATION_ID  — 필수
#   REVIEWER_APP_ID, REVIEWER_PEM, REVIEWER_INSTALLATION_ID, REVIEWER_BOT_LOGIN
#                        — reviewer.enabled=true 일 때만 필수
#   SLACK_WEBHOOK_URL    — 옵션 (없으면 빈 값)
#   WEBHOOK_SECRET       — 옵션 (기존 .env 값 보존 > 환경변수 > 자동 생성 순)
#
# 예시:
#   ./scripts/install.sh my-config.yml
#   ./scripts/install.sh my-config.yml --env-file app/.env.sandbox --port 3001 --non-interactive
#
# 자동화 범위:
#   - 영역 레포별 GitHub secrets 등록 (AUTHOR_*, REVIEWER_*, SLACK_*)
#   - 영역 레포별 GitHub variables 등록 (PIPELINE_*)
#   - 영역 레포에 호출자 yml 설치
#   - app/.env 파일 생성
#   - app/package-lock.json 생성 (Docker build 준비)
#
# 사용자 수동 작업 (스크립트 완료 후):
#   1. GitHub App 두 개의 Webhook Secret 업데이트
#   2. cd app && docker compose up -d --build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── 인자 파싱 — 위치인자(config 경로) + 플래그 공존 ─────────────
# 플래그 기본값 (없으면 기존 대화형 동작과 동일)
CONFIG_FILE=""              # 위치인자로 받음 (미지정 시 아래에서 기본 경로)
ENV_FILE=""                 # --env-file (미지정 시 아래에서 app/.env)
PORT_VALUE="3000"           # --port
NON_INTERACTIVE=false       # --non-interactive
UPDATE_COMMANDS_ONLY=false  # --update-commands-only (런타임 config 재생성 전용)
REAPPLY=false               # --reapply (variables+labels+caller-yml만 멱등 재적용)
ROTATE_WEBHOOK_SECRET=false # --rotate-webhook-secret (WEBHOOK_SECRET 의도적 회전)

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
        echo "❌ --env-file 에 값이 필요합니다 (예: --env-file app/.env.sandbox)" >&2; exit 1
      fi
      ENV_FILE="$2"; shift 2 ;;
    --port)
      if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
        echo "❌ --port 에 값이 필요합니다 (예: --port 3001)" >&2; exit 1
      fi
      PORT_VALUE="$2"; shift 2 ;;
    --non-interactive)
      NON_INTERACTIVE=true; shift ;;
    --update-commands-only)
      UPDATE_COMMANDS_ONLY=true; shift ;;
    --reapply)
      REAPPLY=true; shift ;;
    --rotate-webhook-secret)
      ROTATE_WEBHOOK_SECRET=true; shift ;;
    -*)
      echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    *)
      # 위치인자 = config 경로 (첫 번째 것만 사용)
      if [ -z "$CONFIG_FILE" ]; then
        CONFIG_FILE="$1"
      else
        echo "예상치 못한 인자: $1" >&2; exit 1
      fi
      shift ;;
  esac
done

# 기본값 적용
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/examples/reclip/pipeline-config.yml}"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/app/.env}"

# 색상 출력
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
# 모든 로그는 stderr 로 — 커맨드치환($(...))으로 stdout 값을 캡처하는 함수가
# 내부에서 이들을 호출해도 캡처가 오염되지 않도록(eval "$(parse_config)" 등 보호).
info()    { echo -e "${GREEN}✅${NC} $1" >&2; }
warn()    { echo -e "${YELLOW}⚠️ ${NC} $1" >&2; }
error()   { echo -e "${RED}❌${NC} $1" >&2; }
section() { echo -e "\n${CYAN}══ $1 ══${NC}" >&2; }

# ── 사전 준비 체크리스트 ─────────────────────────────────────
show_checklist() {
  echo ""
  echo -e "${YELLOW}📋 시작 전 준비 확인:${NC}"
  echo "   ✔ GitHub App 2개 생성 완료? (Automation Bot, Review Bot)"
  echo "     → github.com/organizations/<org>/settings/apps/new"
  echo "   ✔ 각 App에서 Private Key 생성 → .pem 파일 다운로드 완료?"
  echo "     → App 페이지 → Private keys → Generate a private key"
  echo "   ✔ 각 App을 org에 Install 완료?"
  echo "     → App 페이지 → Install App → org 선택"
  echo ""
  read -rp "$(echo -e "${CYAN}?${NC} 준비됐으면 Enter, 취소는 Ctrl+C: ")" _
}

# ── 필수 도구 체크 ──────────────────────────────────────────
check_requirements() {
  section "환경 체크"
  local ok=true
  for cmd in gh python3 npm; do
    if command -v "$cmd" &>/dev/null; then
      info "$cmd 확인"
    else
      error "$cmd 없음 — 설치 필요"
      ok=false
    fi
  done
  if gh auth status &>/dev/null; then
    info "gh 인증 확인 ($(gh api user --jq .login))"
  else
    error "gh 인증 안 됨 — gh auth login 실행 필요"
    ok=false
  fi
  # self-hosted 러너 요구사항 — review.yml 의 fix-loop 가 claude 호출을 step 단위
  #   timeout/gtimeout(#20 hung 방지)으로 감싼다. (kickoff·critic·critic-dispatch 는
  #   TIMEOUT_CMD 미사용 — job-level timeout-minutes 로 hung 을 막으므로 coreutils 불요.)
  #   macOS 는 기본 timeout 이 없어 gtimeout(brew coreutils)이 필요하다.
  #   ⚠️ 이 체크는 "install 을 실행하는 머신" 기준이라, install 머신과 러너가 다르면
  #   (예: Linux 에서 install + macOS 러너) 거짓 안심을 줄 수 있다 — 실제 요구는 review 가
  #   도는 self-hosted 러너 OS 다. install 자체는 중단하지 않는다(경고만).
  if command -v gtimeout &>/dev/null || command -v timeout &>/dev/null; then
    info "timeout/gtimeout 확인 (review 타임아웃 — 단 실제 요구는 review 가 도는 self-hosted 러너 OS)"
  else
    warn "timeout/gtimeout 미설치 — self-hosted 러너에서 review 자동화(fix-loop)가 claude 호출 전 실패합니다(#20). install 은 계속 진행됩니다. macOS: brew install coreutils (대부분의 Linux 는 coreutils 포함 — BusyBox 등 최소 이미지는 예외)"
  fi
  [ "$ok" = "true" ] || exit 1
}

# ── Config 파싱 (python3, pyyaml 불필요) ────────────────────
parse_config() {
  python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, re, json

path = sys.argv[1]
with open(path) as f:
    content = f.read()

def get_scalar(key, default=''):
    # 따옴표로 감싼 값 우선 매칭 — 내부 # 허용 (예: slack-channel: "#alerts")
    # 값 앞 공백은 [ \t]* (개행 비흡수). \s* 는 개행 포함이라 값이 비면 다음 줄 키를 흡수.
    # 닫는 따옴표 뒤 줄끝에 선택적 인라인 주석((?:#.*)?$) 허용 — `key: "X"  # 주석` 에서
    # 따옴표 분기 실패 → 무따옴표 폴백 빈 캡처되는 값 소실 방지(#52, 리더와 parity).
    mq = re.search(rf'^\s+{re.escape(key)}:[ \t]*"([^"\n]*)"\s*(?:#.*)?$', content, re.MULTILINE)
    if not mq:
        mq = re.search(rf"^\s+{re.escape(key)}:[ \t]*'([^'\n]*)'\s*(?:#.*)?$", content, re.MULTILINE)
    if mq:
        return mq.group(1).strip()
    # 무따옴표 폴백 — [^"#\n] 로 인라인 주석(# 이후) 제거
    m = re.search(rf'^\s+{re.escape(key)}:[ \t]*([^"#\n]*)', content, re.MULTILINE)
    return m.group(1).strip().strip("'\"") if m and m.group(1).strip() else default

# 스칼라 값
print(f"OWNER='{get_scalar('owner')}'")
print(f"PARENT_REPO='{get_scalar('parent-repository')}'")
print(f"WORKING_DIR='{get_scalar('working-directory')}'")
print(f"SLACK_CHANNEL='{get_scalar('slack-channel')}'")

# pipeline 섹션 — 호출자 yml의 uses: 경로 치환에 사용
# modules 블록 파싱과 동일 방식으로 pipeline: 섹션만 슬라이스한 뒤
# 그 안에서만 repo:/ref: 를 찾아 다른 섹션의 같은 키와 충돌 방지
# repo: 없으면 빈 문자열로 emit (필수 검증은 main 에서)
# ref:  없으면 'main' 기본
ps = re.search(r'^pipeline:\s*\n(.*?)(?=^\S|\Z)', content, re.MULTILINE | re.DOTALL)
pipeline_block = ps.group(1) if ps else ''
def get_scalar_in(block, key, default=''):
    # 따옴표로 감싼 값 우선 매칭 — 내부 # 허용
    # 값 앞 공백은 [ \t]* (개행 비흡수). \s* 는 개행 포함이라 값이 비면 다음 줄 키를 흡수.
    # 닫는 따옴표 뒤 줄끝에 선택적 인라인 주석((?:#.*)?$) 허용 — `key: "X CI"  # 주석` 에서
    # 따옴표 분기 실패 → 무따옴표 폴백 빈 캡처되는 값 소실 방지(#52, 리더와 parity).
    mq = re.search(rf'^\s+{re.escape(key)}:[ \t]*"([^"\n]*)"\s*(?:#.*)?$', block, re.MULTILINE)
    if not mq:
        mq = re.search(rf"^\s+{re.escape(key)}:[ \t]*'([^'\n]*)'\s*(?:#.*)?$", block, re.MULTILINE)
    if mq:
        return mq.group(1).strip()
    # 무따옴표 폴백 — [^"#\n] 로 인라인 주석(# 이후) 제거
    m = re.search(rf'^\s+{re.escape(key)}:[ \t]*([^"#\n]*)', block, re.MULTILINE)
    return m.group(1).strip().strip("'\"") if m and m.group(1).strip() else default

# 따옴표 분기 우선 값 캡처 조각 — 따옴표 안 # 보존(#57). get_scalar_in 과 동일 철학:
#   "..."  → 그룹1(닫는 따옴표까지, # 포함. * 라 ""→빈문자열) / '...'  → 그룹2(''→빈문자열) /
#   무따옴표 → 그룹3([^"#\n]+? 비탐욕). 줄끝 선택적 인라인 주석은 호출부가 붙인다. 리더와 동일.
# 빈 따옴표(#57 후속): 두 따옴표 분기 * 로 ""/'' 가 빈 문자열로 캡처되게 한다. (+ 였으면
#   빈 따옴표가 미매치 → 무따옴표 폴백이 `''` 자체를 리터럴 캡처 → install↔reader parity 깨짐
#   + 모듈 area-id '' 가 truthy 라 legacy 폴백을 덮어쓰는 config 오염.)
QUOTED_VALUE = r'''(?:"([^"\n]*)"|'([^'\n]*)'|([^"#\n]+?))'''
def pick_quoted_value(m):
    # 따옴표 분기는 .strip() 만(내용 보존), 무따옴표 폴백 그룹은 추가로 .strip("'\"")
    # — 폴백으로 샌 따옴표를 벗겨 빈값 통일(belt&suspenders). 리더 pick_quoted_value 와 동일.
    if m.group(1) is not None:
        return m.group(1).strip()
    if m.group(2) is not None:
        return m.group(2).strip()
    if m.group(3) is not None:
        return m.group(3).strip().strip("'\"")
    return ''
print(f"PIPELINE_REPO='{get_scalar_in(pipeline_block, 'repo')}'")
print(f"PIPELINE_REF='{get_scalar_in(pipeline_block, 'ref', 'main')}'")

# project-numbers 배열 (예: project-numbers: [3, 5])
pn = re.search(r'project-numbers:\s*\[([^\]]*)\]', content)
pn_items = [int(n) for n in re.findall(r'\d+', pn.group(1))] if pn else []
print(f"PROJECT_NUMBERS_JSON='{json.dumps(pn_items, separators=(',', ':'))}'")

# modules-ignore JSON 배열
mi = re.search(r'modules-ignore:\s*\n((?:\s+-\s*.+\n?)*)', content)
items = re.findall(r'-\s*"?([^"\n]+)"?', mi.group(1)) if mi else []
print(f"MODULES_IGNORE_JSON='{json.dumps([i.strip() for i in items], separators=(',', ':'))}'")


# reviewer enabled
rev = re.search(r'reviewer:\s*\n\s+enabled:\s*(\w+)', content)
print(f"REVIEWER_ENABLED={rev.group(1) if rev else 'false'}")

# modules — 블록 단위 파싱
# 주의: ci-workflow-name 은 모든 모듈에 있지만 strict-review-bot-check 는
#       일부 모듈에만 있어, 전체에서 위치(positional)로 뽑으면 모듈↔값 정렬이
#       어긋난다. 따라서 각 `- name:` 부터 다음 `- name:` 전까지를 한 블록으로
#       잘라 블록 내부에서만 ci·strict 를 찾아 정렬을 보장한다.

# modules: 섹션부터 다음 최상위 키(modules-ignore / reviewer 등) 직전까지 추출
ms = re.search(r'^modules:\s*\n(.*?)(?=^\S|\Z)', content, re.MULTILINE | re.DOTALL)
modules_block = ms.group(1) if ms else ''

# 각 `- name:` 위치를 기준으로 블록 분할
# 따옴표 분기 우선(따옴표 안 # 보존, #57) → 무따옴표 폴백(인라인 주석 제거, #52).
# 무따옴표 모듈명에 # 가 오면 주석 경계(값 밖 # 만 주석). 따옴표로 감싸면 보존.
# 리더 pipeline-config.sh module_blocks 와 동일 패턴(parity).
# 미종결 따옴표 등 name 파싱 실패 행은 stderr 경고(조용한 누락 = #52 footgun 방지). 리더와 동일.
for lm in re.finditer(r'^\s+-\s+name:.*$', modules_block, re.MULTILINE):
    if not re.match(rf'^\s+-\s+name:\s*{QUOTED_VALUE}\s*(?:#.*)?$', lm.group(0)):
        sys.stderr.write(f"⚠️  parse_config: 모듈 name 파싱 실패(미종결 따옴표 등) — "
                         f"해당 모듈 누락: {lm.group(0).strip()}\n")
name_iter = list(re.finditer(rf'^\s+-\s+name:\s*{QUOTED_VALUE}\s*(?:#.*)?$', modules_block, re.MULTILINE))
names = []
for idx, m in enumerate(name_iter):
    name = pick_quoted_value(m)
    block_start = m.end()
    block_end = name_iter[idx + 1].start() if idx + 1 < len(name_iter) else len(modules_block)
    block = modules_block[block_start:block_end]

    # 값 앞 공백은 [ \t]* (개행 비흡수) — 빈 ci-workflow-name 이 다음 줄 키를 흡수하는 것 방지.
    # 따옴표 분기 우선(따옴표 안 # 보존, #57) → 무따옴표 폴백(인라인 주석 제거, #52).
    # 빈 값은 어느 분기도 매칭 안 됨(group3 은 1글자 이상) → ci_m None → '' (빈값 동작 유지).
    ci_m = re.search(rf'^\s+ci-workflow-name:[ \t]*{QUOTED_VALUE}\s*(?:#.*)?$', block, re.MULTILINE)
    ci = pick_quoted_value(ci_m) if ci_m else ''

    # strict-review-bot-check — 미지정 시 기본 true
    strict_m = re.search(r'^\s+strict-review-bot-check:\s*(\w+)', block, re.MULTILINE)
    strict = strict_m.group(1).strip().lower() if strict_m else 'true'
    if strict not in ('true', 'false'):
        strict = 'true'

    names.append(name)
    print(f"MODULE_{idx}_NAME='{name}'")
    print(f"MODULE_{idx}_CI='{ci}'")
    print(f"MODULE_{idx}_STRICT='{strict}'")
print(f"MODULE_COUNT={len(names)}")

# 영역 모듈 이름들을 JSON 배열로 (App 폴러 환경변수 MODULES 용)
# 주의: modules-ignore 모듈(예: Design)은 제외한다.
#   App Status 폴러는 MODULES 에 든 모듈만 kickoff/review dispatch 대상으로 본다
#   (status-poller.ts: modules.includes(repo) 인 아이템만 처리). Design 처럼 등록
#   대상에서 빠지는 모듈을 MODULES 에 남기면 폴러가 dispatch 대상으로 오인한다.
#   modules: 에는 의미론 표(--modules-table) 노출용으로 두되 여기선 걸러 정합성 유지.
#   (ignore_set = modules-ignore 멤버. 위 items 는 modules-ignore 파싱 결과.)
ignore_set = {i.strip() for i in items}
poller_modules = [n for n in names if n not in ignore_set]
print(f"MODULES_JSON='{json.dumps(poller_modules, separators=(',', ':'))}'")

# ── tracking 섹션 — finding 추적 라벨 자동 등록용 ───────────────────────
# tracking: 섹션부터 다음 최상위 키 직전까지 슬라이스해 그 안에서만 탐색
# (pipeline/modules 블록 파싱과 동일 방식 — 다른 섹션의 동명 키와 충돌 방지)
tk = re.search(r'^tracking:\s*\n(.*?)(?=^\S|\Z)', content, re.MULTILINE | re.DOTALL)
tk_block = tk.group(1) if tk else ''

# enabled — 미지정 시 기본 false
tk_en = re.search(r'^\s+enabled:\s*(\w+)', tk_block, re.MULTILINE)
tk_enabled = tk_en.group(1).strip().lower() if tk_en else 'false'
if tk_enabled not in ('true', 'false'):
    tk_enabled = 'false'
print(f"TRACKING_ENABLED={tk_enabled}")

# 라벨명 — 미지정 시 기본값 (major-issue / minor-issue)
print(f"TRACKING_MAJOR_LABEL='{get_scalar_in(tk_block, 'major-label', 'major-issue')}'")
print(f"TRACKING_MINOR_LABEL='{get_scalar_in(tk_block, 'minor-label', 'minor-issue')}'")

# ── status-triggers 섹션 — App 폴러가 kickoff/review 를 트리거할 Status 컬럼명 (#106 app-p5) ──
# project.status-triggers.{kickoff,review} 하위맵을 슬라이스한 뒤 그 안에서만 읽는다.
#   ⚠️ kickoff/review 키는 modules[].kickoff/review 플래그와 이름이 겹치므로 반드시 블록
#   격리한다. 블록 경계는 area-ids 블록과 동일 패턴 — status-triggers 보다 '더 깊이'
#   들여쓴 줄(\1[ \t]+\S)만 포함하고, 같은/얕은 들여쓰기(다음 형제 키·최상위 modules:)에서
#   멈춘다. (\1\S 만 보는 앵커식은 col0 dedent 를 못 잡아 modules: 로 새어 module 의
#   kickoff/review 플래그를 오독하므로 쓰지 않는다.)
# 미지정 시 빈 값으로 emit → generate_env 가 그대로 .env 에 쓰고, App(lib/env.ts)이
# 빈 값을 기본 컬럼명("In Progress"/"Bot Review")으로 폴백한다(기본값 단일 진실원 = App).
st = re.search(r'^([ \t]+)status-triggers:[ \t]*\n((?:\1[ \t]+\S.*\n?|[ \t]*\n)*)', content, re.MULTILINE)
st_block = st.group(2) if st else ''
print(f"STATUS_TRIGGERS_KICKOFF='{get_scalar_in(st_block, 'kickoff')}'")
print(f"STATUS_TRIGGERS_REVIEW='{get_scalar_in(st_block, 'review')}'")

PYEOF
}

# ── modules-ignore 멤버 판정 ─────────────────────────────────
# 주어진 모듈명이 MODULES_IGNORE_JSON(형태 ["Design"]) 에 들어있으면 0(true).
# 영역 레포 등록 루프에서 제외 모듈(예: Design)을 걸러내는 데 사용한다.
#   - 정확(exact) 비교: "Design" 이 "DesignSystem" 같은 다른 모듈을 매칭하지 않도록
#     python 으로 JSON 파싱 후 고정문자열 멤버십 비교(부분일치·정규식 함정 없음).
#   - MODULES_IGNORE_JSON 미설정/빈 배열/파싱 실패 → false(아무것도 제외 안 함, 안전 기본값).
is_ignored_module() {
  local name="$1"
  python3 - "$name" "${MODULES_IGNORE_JSON:-[]}" <<'PYEOF'
import sys, json
name = sys.argv[1]
try:
    ignored = json.loads(sys.argv[2])
    if not isinstance(ignored, list):
        ignored = []
except (json.JSONDecodeError, ValueError):
    ignored = []
# 고정문자열 정확 비교 — 부분일치 방지(Design ≠ DesignSystem)
sys.exit(0 if name in ignored else 1)
PYEOF
}

# ── 대화형 입력 ─────────────────────────────────────────────
prompt() {
  local msg="$1" default="${2:-}"
  if [ -n "$default" ]; then
    read -rp "$(echo -e "${CYAN}?${NC} $msg [$default]: ")" val
    echo "${val:-$default}"
  else
    read -rp "$(echo -e "${CYAN}?${NC} $msg: ")" val
    echo "$val"
  fi
}

prompt_pem() {
  local label="$1"
  echo -e "  ${YELLOW}→ App 페이지 → Private keys → Generate a private key → Downloads에 저장됨${NC}" >&2
  while true; do
    read -rp "$(echo -e "${CYAN}?${NC} ${label} PEM 파일 경로: ")" pem_path
    pem_path="${pem_path/#\~/$HOME}"
    if [ -f "$pem_path" ] && [ -r "$pem_path" ]; then
      echo "$pem_path"
      return
    fi
    error "파일 없음 또는 읽기 불가: $pem_path"
  done
}

prompt_app_id() {
  local label="$1"
  echo -e "  ${YELLOW}→ github.com/organizations/<org>/settings/apps → App 클릭 → 상단 App ID${NC}" >&2
  prompt "$label App ID"
}

prompt_installation_id() {
  local label="$1"
  echo -e "  ${YELLOW}→ github.com/organizations/<org>/settings/installations → Configure → URL 마지막 숫자${NC}" >&2
  prompt "$label Installation ID"
}

# ── 비대화형 PEM 경로 검증 + 확장 ──────────────────────────────
# prompt_pem 의 비대화형 버전 — 환경변수로 받은 경로의 ~ 확장 + 존재 검증
resolve_pem_path() {
  local label="$1" raw="$2"
  local expanded="${raw/#\~/$HOME}"
  if [ -f "$expanded" ] && [ -r "$expanded" ]; then
    echo "$expanded"
    return 0
  fi
  error "$label PEM 파일 없음 또는 읽기 불가: $expanded"
  return 1
}

# ── 기존 .env 의 WEBHOOK_SECRET 읽기 ──────────────────────────
# ENV_FILE 이 존재하면 `WEBHOOK_SECRET=` 라인의 값을 추출(없으면 빈 문자열).
# 운영 App 가동 중 재실행 시 webhook 서명 secret 이 회전되어 수신이 깨지는 것을 막기 위함.
# 값이 비어있으면(키만 있고 값 없음) 경고 — resolve_webhook_secret 가 새로 생성하도록 빈 값 반환.
read_existing_webhook_secret() {
  [ -f "$ENV_FILE" ] || { printf '%s' ""; return 0; }
  local line value
  # docker compose dotenv 호환 파싱:
  #   - 선택적 `export ` 접두 허용
  #   - 키와 `=` 사이/뒤 공백 허용
  #   - 정확히 WEBHOOK_SECRET 키만 매칭 (유사키 OLD_WEBHOOK_SECRET·WEBHOOK_SECRET_BAK 제외)
  #   앵커: 줄 시작 + (export + 공백)? + WEBHOOK_SECRET + 공백? + = + 공백? + 값
  line="$(grep -m1 -E '^(export[[:space:]]+)?WEBHOOK_SECRET[[:space:]]*=' "$ENV_FILE" 2>/dev/null || true)"
  [ -n "$line" ] || { printf '%s' ""; return 0; }
  # = 이후를 값으로 추출
  value="${line#*=}"
  # ① 선행 공백 제거
  value="${value#"${value%%[! ]*}"}"
  # ② 후행 CR 제거 (CRLF 파일 대응) — CR이 닫는 따옴표 뒤에 붙어 따옴표 매칭을 깨뜨리므로
  #    반드시 CR을 먼저 털고 나서 따옴표를 벗겨야 한다.
  value="${value%$'\r'}"
  # ③ 짝맞는 큰따옴표 제거
  if [ "${value#\"}" != "$value" ]; then
    value="${value#\"}"
    value="${value%\"}"
  # 짝맞는 작은따옴표 제거
  elif [ "${value#\'}" != "$value" ]; then
    value="${value#\'}"
    value="${value%\'}"
  fi
  if [ -z "$value" ]; then
    warn "기존 .env 의 WEBHOOK_SECRET 값이 비어있음 — 새로 생성합니다 ($ENV_FILE)"
    printf '%s' ""
    return 0
  fi
  printf '%s' "$value"
}

# ── WEBHOOK_SECRET 결정 (우선순위 통합) ──────────────────────────
# 대화형·비대화형 양쪽이 공유하는 단일 결정 로직. 우선순위:
#   ① --rotate-webhook-secret  → 항상 새로 생성 (의도적 회전)
#   ② 기존 .env 에 값 있음      → 보존 (운영 App 파손 방지 — 안전 기본값)
#   ③ 환경변수 WEBHOOK_SECRET   → 사용 (비대화형 하위호환)
#   ④ 그 외                     → 새로 생성
# 결과를 전역 WEBHOOK_SECRET 에 채운다.
resolve_webhook_secret() {
  local existing
  if [ "${ROTATE_WEBHOOK_SECRET:-false}" = "true" ]; then
    WEBHOOK_SECRET="$(python3 -c "import secrets; print(secrets.token_hex(32))")"
    info "Webhook Secret — 회전(--rotate-webhook-secret) 새로 생성"
    return 0
  fi

  existing="$(read_existing_webhook_secret)"
  if [ -n "$existing" ]; then
    # 환경변수도 제공됐고 .env 값과 다르면 warn — 보존 우선이지만 조용한 무시는 위험
    if [ -n "${WEBHOOK_SECRET:-}" ] && [ "${WEBHOOK_SECRET:-}" != "$existing" ]; then
      warn "환경변수 WEBHOOK_SECRET 이 제공됐으나 기존 .env 값을 보존합니다. 회전하려면 --rotate-webhook-secret 을 사용하세요."
    fi
    WEBHOOK_SECRET="$existing"
    info "Webhook Secret — 기존 .env 값 보존 ($ENV_FILE)"
    return 0
  fi

  if [ -n "${WEBHOOK_SECRET:-}" ]; then
    info "Webhook Secret — 환경변수 사용"
    return 0
  fi

  WEBHOOK_SECRET="$(python3 -c "import secrets; print(secrets.token_hex(32))")"
  info "Webhook Secret 자동 생성"
}

# ── 레포의 기존 GitHub variable 값 조회 (fail-closed) ───────
# `gh variable list --json name,value` 로 기존 variable 값을 읽어 반환.
# 반환 규칙:
#   - 성공 + 키 존재 → 값 출력 (exit 0)
#   - 성공 + 키 부재 → 빈 문자열 출력 (exit 0)  ← "키 없음" 정상 케이스
#   - gh 실패(exit≠0) / JSON 파싱 오류 → exit 1 (fail-closed — 호출자가 중단)
# reapply 보존 경로가 운영 실패를 "값 없음"으로 위장하는 것을 방지.
read_existing_repo_variable() {
  local repo="$1" var_name="$2"
  local raw rc=0
  # gh 실패는 즉시 캐치 — stderr 는 보존해 호출자/운영자가 원인 확인 가능
  raw="$(gh variable list --repo "$repo" --json name,value 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    error "gh variable list 실패 (repo=$repo, exit=$rc): $raw" >&2
    return 1
  fi
  # JSON 파싱 — python3 로 jq 의존 없이 처리. 파싱 실패 시 exit 1
  printf '%s' "$raw" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError) as e:
    print('JSON 파싱 오류: ' + str(e), file=sys.stderr)
    sys.exit(1)
name = sys.argv[1]
for item in data:
    if item.get('name') == name:
        print(item.get('value', ''), end='')
        sys.exit(0)
# 키 부재 — 빈 문자열 (정상 케이스)
" "$var_name"
}

# ── reapply 모드 전용: REVIEWER_BOT_LOGIN 보존 결정 ──────────────
# config 에서 파생 불가능한 secret-time 입력값이므로, reapply 에서는
# 기존 레포 variable 값을 읽어 보존한다. 우선순위:
#   ① 환경변수 REVIEWER_BOT_LOGIN 이 명시 제공된 경우 → 그 값 사용
#   ② 해당 레포의 기존 PIPELINE_REVIEWER_BOT_LOGIN 이 있으면 → 보존
#   ③ 둘 다 없거나 빈 값 → REVIEWER_BOT_LOGIN 을 "_SKIP_" 로 표시
#      (register_variables 내부 가드가 skip 처리 — 빈 값 덮어쓰기 방지)
# 전역 REVIEWER_BOT_LOGIN 에 결과를 채운다.
resolve_reviewer_bot_login_for_reapply() {
  local repo="$1"
  # ① 환경변수 명시 제공
  if [ -n "${REVIEWER_BOT_LOGIN:-}" ]; then
    return 0
  fi
  # ② 기존 레포 variable 읽기 (fail-closed — gh 실패 시 exit 1 전파)
  local existing
  existing="$(read_existing_repo_variable "$repo" "PIPELINE_REVIEWER_BOT_LOGIN")" || {
    error "PIPELINE_REVIEWER_BOT_LOGIN 조회 실패 ($repo) — reapply 중단." >&2
    error "REVIEWER_BOT_LOGIN 환경변수를 명시 제공하거나 gh 권한을 확인하세요." >&2
    return 1
  }
  if [ -n "$existing" ]; then
    REVIEWER_BOT_LOGIN="$existing"
    info "PIPELINE_REVIEWER_BOT_LOGIN — 기존 레포 값 보존 ($repo)"
    return 0
  fi
  # ③ 둘 다 없음 — skip 표시 (gh 성공·키 부재 케이스만 여기 도달)
  REVIEWER_BOT_LOGIN="_SKIP_"
  warn "PIPELINE_REVIEWER_BOT_LOGIN 값 없음 — 이 레포 등록 스킵 ($repo)"
}

# ── 비대화형 모드 — 환경변수에서 App 자격 로드 ─────────────────
# 필수 env 누락 시 어느 변수가 빠졌는지 명시하고 exit 1
load_credentials_from_env() {
  local missing=()

  # Author 봇 — 필수
  [ -n "${AUTHOR_APP_ID:-}" ]          || missing+=("AUTHOR_APP_ID")
  [ -n "${AUTHOR_PEM:-}" ]             || missing+=("AUTHOR_PEM")
  [ -n "${AUTHOR_INSTALLATION_ID:-}" ] || missing+=("AUTHOR_INSTALLATION_ID")

  # Reviewer 봇 — reviewer.enabled=true 일 때만 필수
  if [ "$REVIEWER_ENABLED" = "true" ]; then
    [ -n "${REVIEWER_APP_ID:-}" ]          || missing+=("REVIEWER_APP_ID")
    [ -n "${REVIEWER_PEM:-}" ]             || missing+=("REVIEWER_PEM")
    [ -n "${REVIEWER_INSTALLATION_ID:-}" ] || missing+=("REVIEWER_INSTALLATION_ID")
    [ -n "${REVIEWER_BOT_LOGIN:-}" ]       || missing+=("REVIEWER_BOT_LOGIN")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    error "비대화형 모드 필수 환경변수 누락: ${missing[*]}"
    echo "  --non-interactive 모드는 위 변수를 환경변수로 받습니다." >&2
    exit 1
  fi

  # Author — PEM 경로(검증·확장) + 내용 분리 채움
  AUTHOR_PEM_PATH=$(resolve_pem_path "Author 봇" "$AUTHOR_PEM") || exit 1
  AUTHOR_PRIVATE_KEY="$(cat "$AUTHOR_PEM_PATH")"

  # Reviewer — 기본 빈 값, enabled 시 채움
  REVIEWER_APP_ID="${REVIEWER_APP_ID:-}"
  REVIEWER_INSTALLATION_ID="${REVIEWER_INSTALLATION_ID:-}"
  REVIEWER_BOT_LOGIN="${REVIEWER_BOT_LOGIN:-}"
  REVIEWER_PEM_PATH=""; REVIEWER_PRIVATE_KEY=""
  if [ "$REVIEWER_ENABLED" = "true" ]; then
    REVIEWER_PEM_PATH=$(resolve_pem_path "Reviewer 봇" "$REVIEWER_PEM") || exit 1
    REVIEWER_PRIVATE_KEY="$(cat "$REVIEWER_PEM_PATH")"
  fi

  # Slack — 옵션 (없으면 빈 값)
  SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

  # Webhook Secret 결정은 main 에서 resolve_webhook_secret 로 통합 처리
  # (기존 .env 보존 > 환경변수 > 새 생성 — 운영 App 파손 방지)

  info "App 자격 — 환경변수에서 로드 완료"
}

# ── Secrets 등록 ─────────────────────────────────────────────
register_secrets() {
  local repo="$1"
  echo "  secrets 등록 중..."
  gh secret set AUTHOR_APP_ID            --repo "$repo" --body "$AUTHOR_APP_ID"
  gh secret set AUTHOR_PRIVATE_KEY       --repo "$repo" --body "$AUTHOR_PRIVATE_KEY"
  gh secret set AUTHOR_INSTALLATION_ID   --repo "$repo" --body "$AUTHOR_INSTALLATION_ID"

  if [ "$REVIEWER_ENABLED" = "true" ]; then
    gh secret set REVIEWER_APP_ID            --repo "$repo" --body "$REVIEWER_APP_ID"
    gh secret set REVIEWER_PRIVATE_KEY       --repo "$repo" --body "$REVIEWER_PRIVATE_KEY"
    gh secret set REVIEWER_INSTALLATION_ID   --repo "$repo" --body "$REVIEWER_INSTALLATION_ID"
  fi

  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    gh secret set SLACK_WEBHOOK_URL --repo "$repo" --body "$SLACK_WEBHOOK_URL"
  fi
  info "secrets 등록 완료"
}

# ── Variables 등록 ───────────────────────────────────────────
# $4=reapply — "true" 일 때만 REVIEWER_BOT_LOGIN 스킵 로직 적용.
# 풀 install(기본 "false")에서는 이전과 동일하게 무조건 등록(빈 값 포함).
register_variables() {
  local repo="$1" ci_name="$2" strict="$3" is_reapply="${4:-false}"
  echo "  variables 등록 중..."
  gh variable set PIPELINE_OWNER                    --repo "$repo" --body "$OWNER"
  gh variable set PIPELINE_PARENT_REPOSITORY        --repo "$repo" --body "$PARENT_REPO"
  gh variable set PIPELINE_MODULES_IGNORE           --repo "$repo" --body "$MODULES_IGNORE_JSON"
  gh variable set PIPELINE_WORKING_DIRECTORY        --repo "$repo" --body "$WORKING_DIR"
  # reapply 모드에서만 _SKIP_ / 빈 값 스킵. 풀 install 은 무조건 등록(기존 동작 보존).
  if [ "$is_reapply" = "true" ] && \
     { [ "${REVIEWER_BOT_LOGIN:-}" = "_SKIP_" ] || [ -z "${REVIEWER_BOT_LOGIN:-}" ]; }; then
    : # 빈 값 덮어쓰기 방지 — 등록 스킵
  else
    gh variable set PIPELINE_REVIEWER_BOT_LOGIN     --repo "$repo" --body "${REVIEWER_BOT_LOGIN:-}"
  fi
  gh variable set PIPELINE_VERDICT_DIR              --repo "$repo" --body "$VERDICT_DIR"
  gh variable set PIPELINE_STRICT_REVIEW_BOT_CHECK  --repo "$repo" --body "$strict"
  [ -n "$ci_name" ] && \
    gh variable set PIPELINE_CI_WORKFLOW_NAME       --repo "$repo" --body "$ci_name"
  gh variable set PIPELINE_TRACKING_ENABLED         --repo "$repo" --body "$TRACKING_ENABLED"
  gh variable set PIPELINE_TRACKING_MAJOR_LABEL     --repo "$repo" --body "$TRACKING_MAJOR_LABEL"
  gh variable set PIPELINE_TRACKING_MINOR_LABEL     --repo "$repo" --body "$TRACKING_MINOR_LABEL"
  info "variables 등록 완료"
}

# ── 추적 라벨 등록 ───────────────────────────────────────────
# finding(리뷰 지적) 추적 이슈에 붙일 라벨을 영역/parent 레포에 등록.
# tracking.enabled=false 면 스킵. 이미 존재하는 라벨은 gh label create 가
# 실패하므로 '|| true' 로 무시(idempotent).
register_labels() {
  local repo="$1"
  [ "$TRACKING_ENABLED" = "true" ] || return 0
  echo "  추적 라벨 등록 중..."
  gh label create "$TRACKING_MAJOR_LABEL" --repo "$repo" \
    --color "d93f0b" --description "릴리즈 전 필수 수정 (finding 추적)" 2>/dev/null || true
  gh label create "$TRACKING_MINOR_LABEL" --repo "$repo" \
    --color "fbca04" --description "후속 처리 대상 (finding 추적)" 2>/dev/null || true
  info "추적 라벨 등록 완료"
}

# ── 호출자 yml 설치 ──────────────────────────────────────────
install_caller_ymls() {
  local repo="$1" mod_ci="${2:-}"
  # 제네릭 템플릿을 소스로 사용 — placeholder 를 config 값으로 치환해 설치
  local src="$REPO_ROOT/templates/caller-workflows"
  echo "  호출자 yml 설치 중..."
  for yml in auto-kickoff.yml auto-review.yml auto-merge.yml \
             auto-critic-dispatch.yml parent-autoclose.yml; do
    [ -f "$src/$yml" ] || continue
    local content sha msg tmp_file
    tmp_file=$(mktemp)
    # 모든 yml 공통: Pipeline 레포 경로·ref placeholder 치환
    #   값에 '/' 가 들어가므로(레포 경로) sed 구분자를 '|' 로 사용
    # shellcheck disable=SC2153  # PIPELINE_REF 는 parse_config 가 emit → `eval "$(parse_config)"`(L952)로 동적 할당. PIPELINE_REPO 와 동일 경로, 오타 아님(오탐).
    sed -e "s|__PIPELINE_REPO__|$PIPELINE_REPO|g" \
        -e "s|__PIPELINE_REF__|$PIPELINE_REF|g" \
        "$src/$yml" > "$tmp_file"
    # auto-merge.yml: workflow_run.workflows CI 이름을 영역별로 치환
    #   (GHA 제약상 workflow_run.workflows 는 리터럴만 가능 → 텍스트 치환)
    if [ "$yml" = "auto-merge.yml" ]; then
      sed -i.bak "s|__CI_WORKFLOW_NAME__|$mod_ci|g" "$tmp_file"
      rm -f "$tmp_file.bak"
    fi
    content=$(base64 < "$tmp_file" | tr -d '\n')
    rm -f "$tmp_file"
    sha=$(gh api "/repos/$repo/contents/.github/workflows/$yml" \
      --jq .sha 2>/dev/null || echo "")
    msg="[자동화] Pipeline 호출자 yml 설치 — install.sh"
    if [ -n "$sha" ]; then
      gh api -X PUT "/repos/$repo/contents/.github/workflows/$yml" \
        -f message="$msg" -f content="$content" -f sha="$sha" > /dev/null
    else
      gh api -X PUT "/repos/$repo/contents/.github/workflows/$yml" \
        -f message="$msg" -f content="$content" > /dev/null
    fi
    echo "    ✅ $yml"
  done
}

# ── App .env 생성 ────────────────────────────────────────────
generate_env() {
  local env_file="$ENV_FILE"
  cat > "$env_file" <<EOF
# 자동 생성 — install.sh $(date +%Y-%m-%d)
AUTHOR_APP_ID=$AUTHOR_APP_ID
AUTHOR_PEM=$AUTHOR_PEM_PATH
AUTHOR_INSTALLATION_ID=$AUTHOR_INSTALLATION_ID
EOF
  if [ "$REVIEWER_ENABLED" = "true" ]; then
    cat >> "$env_file" <<EOF
REVIEWER_APP_ID=$REVIEWER_APP_ID
REVIEWER_PEM=$REVIEWER_PEM_PATH
REVIEWER_INSTALLATION_ID=$REVIEWER_INSTALLATION_ID
REVIEWER_BOT_LOGIN=$REVIEWER_BOT_LOGIN
EOF
  fi
  cat >> "$env_file" <<EOF
OWNER=$OWNER
PROJECT_NUMBERS=$PROJECT_NUMBERS_JSON
MODULES=$MODULES_JSON
MODULES_IGNORE=$MODULES_IGNORE_JSON
STATUS_TRIGGERS_KICKOFF=${STATUS_TRIGGERS_KICKOFF:-}
STATUS_TRIGGERS_REVIEW=${STATUS_TRIGGERS_REVIEW:-}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
WEBHOOK_SECRET=$WEBHOOK_SECRET
PORT=$PORT_VALUE
LOG_LEVEL=info
NODE_ENV=production
EOF
  info "app/.env 생성 완료 ($env_file)"
}

# ── package-lock.json 생성 ───────────────────────────────────
generate_package_lock() {
  local app_dir="$REPO_ROOT/app"
  if [ ! -f "$app_dir/package-lock.json" ]; then
    echo "  npm install 실행 중..."
    npm install --prefix "$app_dir" --silent
    info "package-lock.json 생성 완료"
  else
    info "package-lock.json 이미 존재 — 스킵"
  fi
}

# ── Project v2 식별자 자동조회 (GraphQL) ───────────────────────
# project-number(사용자가 쉽게 아는 값 = 프로젝트 URL 끝 숫자)만 있으면
# GitHub GraphQL 로 project-id·status-field-id·area-field-id 를 자동 획득한다.
#
# 인자: <owner> <project-number>
# 출력(성공): "project-id<TAB>status-field-id<TAB>area-field-id" 한 줄(stdout) + return 0
# 출력(실패): 아무것도 안 내고 return 1 (project-id 를 못 구하면 실패로 간주)
#
# org→user 순차 폴백 이유:
#   GraphQL 통합 쿼리(organization 과 user 를 한 번에)는 owner 가 한쪽 타입이 아니면
#   그쪽이 NOT_FOUND 로 떨어지면서 전체 응답이 에러가 된다(부분 성공 안 됨).
#   그래서 organization 으로 먼저 시도하고, owner 가 user 계정이라 NOT_FOUND 면
#   gh 가 exit 비0 → user 쿼리로 폴백한다.
#
# Area 필드명 가변성 주의:
#   "Status" 는 GitHub Project v2 표준 필드라 거의 항상 존재한다.
#   "Area" 는 프로젝트마다 다른 커스텀 필드명일 수 있어 못 찾을 수 있다 — 그 경우
#   tsv 의 area 칸이 빈 문자열로 나온다. 이때는 config 에 area-field-id 를 명시해야
#   한다("명시 > 자동 > 실패"의 명시 폴백). "Status"·"Area" 외 다른 필드명은
#   프로젝트 식별자라 본체에 하드코딩하지 않는다(이식성 — config 명시로 처리).
#
# 의존성: gh 내장 --jq 만 사용(외부 jq 불필요).
resolve_project_field_ids() {
  local lookup_owner="$1" lookup_number="$2" tsv

  # org 시도 — organization(login).projectV2(number) 에서 id + Status/Area 필드 추출.
  #   --jq: project-id, Status 필드 id, Area 필드 id 를 tsv 한 줄로. 못 찾은 칸은 "".
  # shellcheck disable=SC2016  # $o·$n 은 GraphQL 변수(shell 변수 아님) — 펼쳐지면 안 되고 -F 로 주입한다.
  tsv="$(gh api graphql \
    -f query='query($o:String!,$n:Int!){ organization(login:$o){ projectV2(number:$n){ id fields(first:50){nodes{...on ProjectV2SingleSelectField{id name}}} } } }' \
    -F o="$lookup_owner" -F n="$lookup_number" \
    --jq '.data.organization.projectV2 | [.id, (.fields.nodes|map(select(.name=="Status"))|.[0].id // ""), (.fields.nodes|map(select(.name=="Area"))|.[0].id // "")] | @tsv' \
    2>/dev/null)" || tsv=""

  # org 실패(owner 가 user 계정 → organization NOT_FOUND 로 gh exit 비0)거나
  # project-id 칸(첫 칸)이 비면 user 쿼리로 폴백.
  if [ -z "${tsv%%	*}" ]; then
    # shellcheck disable=SC2016  # $o·$n 은 GraphQL 변수(shell 변수 아님) — 펼쳐지면 안 되고 -F 로 주입한다.
    tsv="$(gh api graphql \
      -f query='query($o:String!,$n:Int!){ user(login:$o){ projectV2(number:$n){ id fields(first:50){nodes{...on ProjectV2SingleSelectField{id name}}} } } }' \
      -F o="$lookup_owner" -F n="$lookup_number" \
      --jq '.data.user.projectV2 | [.id, (.fields.nodes|map(select(.name=="Status"))|.[0].id // ""), (.fields.nodes|map(select(.name=="Area"))|.[0].id // "")] | @tsv' \
      2>/dev/null)" || tsv=""
  fi

  # project-id(첫 칸)가 비면 자동조회 실패. (Status/Area 칸이 비는 건 부분성공 —
  #  여기선 성공으로 보고 빈 칸은 호출부가 주입 안 함 → self-check 가 최종 판정.)
  if [ -z "${tsv%%	*}" ]; then
    return 1
  fi
  printf '%s\n' "$tsv"
  return 0
}

# ── config upsert — claude-commands 섹션의 키를 비어있을 때만 채움 ───────
# 인자: <config-file> <key> <value>
#   - claude-commands: 블록 안의 <key> 가 있고 값이 비어있을 때만 <value> 로 교체.
#   - 값이 이미 있으면 보존(명시 우선). 키가 없으면 블록에 추가(블록 직속 들여쓰기).
#   - claude-commands: 섹션 자체가 없으면 파일 끝에 섹션 생성 후 추가.
#   - <value> 가 빈 문자열이면 아무것도 안 함(빈값으로 덮지 않음 — 호출부도 가드하지만 belt&suspenders).
#
# 리더 parity(중요 — install↔reader 가 같은 라인을 보게):
#   ① 헤더 매칭은 리더 section() 과 정확히 동일하게 한다(`^claude-commands:[ \t]*$` —
#      콜론 뒤 공백/탭만, 인라인 주석·내용 불허). 리더 section() 의
#      `^claude-commands:\s*\n` 정규식은 헤더 라인 뒤에 공백/탭만 허용하고 즉시 개행하므로,
#      `claude-commands:  # 주석` 같은 인라인 주석 헤더는 리더가 섹션을 못 읽는다. upsert 가
#      그런 헤더를 채우면 self-check 가 방금 채운 키를 못 읽어 설치를 거부하게 된다(#2).
#   ② 키 라인은 claude-commands "직속" 들여쓰기 레벨만 매칭한다. 리더 get_scalar_in 은
#      claude-commands 블록(CC)에서 첫 매칭을 읽는데, 들여쓰기 무관이라 plan: 등 서브블록의
#      동명 키가 텍스트상 먼저 나오면 그걸 읽는다(#1). upsert 가 임의 들여쓰기 첫 매칭을
#      잡으면 서브블록 키에 자동조회값을 잘못 기록할 수 있다 → 직속 레벨로 한정해 막는다.
# 리더가 python 을 쓰므로 여기도 python3 인라인으로 구현(일관·YAML 안전).
upsert_claude_command_key() {
  local config_file="$1" key="$2" value="$3"
  [ -n "$value" ] || return 0
  python3 - "$config_file" "$key" "$value" <<'PYEOF'
import sys, re, json

config_path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(config_path) as f:
    lines = f.read().split('\n')

# 값 직렬화 — json.dumps 로(YAML 은 JSON 상위집합이라 따옴표/특수문자 안전, codex F3).
#   value 출처가 GraphQL ID라 실위험은 낮지만 저비용 방어.
def yaml_value(v):
    return json.dumps(v)

# claude-commands: 최상위 키 라인 위치 찾기 — 리더 section() 헤더 매칭과 정확히 동일(#2 parity).
#   리더는 `^claude-commands:\s*\n` (콜론 뒤 공백/탭만 후 즉시 개행)으로 섹션을 슬라이스하므로
#   인라인 주석 헤더(`claude-commands:  # x`)는 섹션으로 인식하지 못한다. upsert 도 동일 기준.
cc_idx = None
for i, ln in enumerate(lines):
    if re.match(r'^claude-commands:[ \t]*$', ln):
        cc_idx = i
        break

# claude-commands: 블록 범위 [cc_idx+1, end) — 다음 최상위 키(들여쓰기 없는 비빈 줄) 직전까지.
def block_end(start):
    j = start
    while j < len(lines):
        ln = lines[j]
        if ln.strip() == '' or ln.startswith((' ', '\t')):
            j += 1
            continue
        break  # 들여쓰기 없는 비빈 줄 = 다음 최상위 키
    return j

def block_direct_indent(start, end):
    """블록 직속(top-level of block) 들여쓰기 문자열을 탐지.
       블록 안 비빈 줄들의 최소 들여쓰기 = 직속 키 레벨(보통 2칸). 비면 기본 2칸."""
    best = None
    for j in range(start, end):
        ln = lines[j]
        if ln.strip() == '':
            continue
        ind = ln[:len(ln) - len(ln.lstrip(' \t'))]
        if best is None or len(ind) < len(best):
            best = ind
    return best if best is not None else '  '

if cc_idx is None:
    # claude-commands 섹션 없음 — 파일 끝에 섹션 생성 후 키 추가.
    # 끝의 빈 줄 정리 후 섹션을 append.
    while lines and lines[-1].strip() == '':
        lines.pop()
    lines.append('claude-commands:')
    lines.append(f'  {key}: {yaml_value(value)}')
else:
    end = block_end(cc_idx + 1)
    direct_indent = block_direct_indent(cc_idx + 1, end)
    # 직속 레벨 key 라인만 매칭 — 서브블록(plan: 등)의 동명 키를 건드리지 않게(#1).
    KEY_RE = re.compile(r'^(' + re.escape(direct_indent) + r')'
                        + re.escape(key) + r':[ \t]*(.*)$')
    # 블록 안에서 직속 key 라인 탐색
    found = None
    for i in range(cc_idx + 1, end):
        m = KEY_RE.match(lines[i])
        if m:
            found = (i, m.group(1), m.group(2))
            break
    if found is not None:
        i, indent, cur = found
        # 인라인 주석 보존용 — 원본 값 부분에서 줄끝 인라인 주석을 분리해 둔다(#7).
        inline_comment = ''
        v = cur.strip()
        if v.startswith(('"', "'")):
            # 따옴표 값 — 닫는 따옴표까지가 값, 그 뒤는 인라인 주석일 수 있음
            q = v[0]
            mq = re.match(rf'{q}([^{q}\n]*){q}(.*)$', v)
            if mq:
                v = mq.group(1)
                rest = mq.group(2).strip()
                if rest.startswith('#'):
                    inline_comment = rest
            else:
                v = v.strip(q)
        else:
            # 무따옴표 — # 이전이 값, # 이후가 인라인 주석
            parts = v.split('#', 1)
            v = parts[0].strip().strip('\'"')
            if len(parts) > 1:
                inline_comment = '#' + parts[1]
        if v == '':
            # 비어있을 때만 교체(들여쓰기 보존 + 인라인 주석 보존)
            suffix = f'  {inline_comment}' if inline_comment else ''
            lines[i] = f'{indent}{key}: {yaml_value(value)}{suffix}'
        # 값이 있으면 보존(아무것도 안 함)
    else:
        # 키 없음 — 블록 끝(섹션 내부 마지막 비빈 줄 다음)에 직속 들여쓰기로 삽입.
        # end 직전의 trailing 빈 줄들은 블록 밖으로 밀지 말고 그 앞에 삽입.
        k = end - 1
        while k > cc_idx and lines[k].strip() == '':
            k -= 1
        insert_at = k + 1
        lines.insert(insert_at, f'{direct_indent}{key}: {yaml_value(value)}')

with open(config_path, 'w') as f:
    f.write('\n'.join(lines))
PYEOF
}

# ── Pipeline config 생성 (플러그인 런타임 리더용) ──────────────
# 입력 config($CONFIG_FILE)를 워크스페이스 루트($WORKING_DIR)의
# .claude/pipeline-config.yml 로 복사하고, 비어있는 GraphQL 식별자는 자동조회로 채운다.
#
# 배경:
#   P3 에서 슬래시커맨드 배포 방식이 ".tmpl 치환·복사" → "플러그인 + 런타임 config 읽기"
#   로 전환된다. 플러그인 skill 은 실행 시 .claude/pipeline-config.yml 을 읽어
#   (plugin/skills/*/scripts/pipeline-config.sh) 프로젝트값을 주입한다.
#   이 함수는 그 런타임 config 파일을 영역 워크스페이스에 배치하는 역할.
#
# 설계 결정(D=ⓐ 복사 방식 + 자동조회):
#   런타임 리더(pipeline-config.sh)와 install.sh 의 parse_config() 는 동일 스키마의
#   같은 pipeline-config.yml 을 읽는다. 입력 config 를 (거의) 그대로 복사하되,
#   project-id·status-field-id·area-field-id 가 비어있으면 owner+project-number 로
#   자동조회해 빈 키만 채운다("명시 > 자동 > 실패"). 명시값은 절대 덮어쓰지 않는다.
#   (이식 UX — 사용자는 알기 쉬운 project-number 만 채우면 나머지는 자동.)
#
# self-check 필수 키:
#   owner·project-number(영역/이슈 식별) + project-id·status-field-id·area-field-id
#   (GraphQL Project v2 조작). reviewer.enabled=true 면 reviewer-* 3키도 조건부 추가.
#
# 원자성: 임시 파일에 쓰고 self-check 통과 후 mv.
# 멱등: 재실행 시 덮어쓰기 — 항상 입력 config 와 동일 상태로 수렴(이미 채워진 키는 보존).
generate_pipeline_config() {
  # 배포 대상 — working-directory 재사용
  if [ -z "${WORKING_DIR:-}" ]; then
    error "pipeline-config 생성 실패 — working-directory 가 비어있습니다 (배포 경로 산출 불가)"
    return 1
  fi

  # 입력 config 존재 확인 (main 에서 이미 검증하지만 단위 호출 안전성 위해 재확인)
  if [ ! -f "$CONFIG_FILE" ]; then
    error "pipeline-config 생성 실패 — 입력 config 없음: $CONFIG_FILE"
    return 1
  fi

  local dest_dir="$WORKING_DIR/.claude"
  local dest="$dest_dir/pipeline-config.yml"

  echo "  Pipeline config 복사 중... (→ $dest)" >&2

  # 런타임 리더 경로 — 3개 skill 의 리더는 동일 스키마를 읽으므로 self-check·값읽기엔
  # 아무거나 써도 무방. kickoff 리더를 기준으로 한다.
  local reader="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
  if [ ! -f "$reader" ]; then
    error "pipeline-config 생성 실패 — 런타임 리더 없음: $reader"
    return 1
  fi

  # 민감값 경고 — 현 스키마상 config 엔 실 시크릿이 없어야 정상.
  #   token-key 항목들은 "env 변수 이름표"일 뿐 토큰 자체가 아니다(실 시크릿은
  #   register_secrets / .env 경로). 만약 입력 config 에 PEM·실 토큰 패턴이 보이면
  #   잘못 배치되는 것이므로 경고만 한다(차단까진 안 함 — 오탐 가능성).
  if grep -qE 'BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{16,}|xox[bap]-[A-Za-z0-9-]{10,}' "$CONFIG_FILE" 2>/dev/null; then
    warn "입력 config 에 실 시크릿으로 보이는 패턴이 있습니다 — pipeline-config 는 시크릿 저장소가 아닙니다(검토 권장): $CONFIG_FILE"
  fi

  # 원자적 복사 — 임시 파일에 쓰고 self-check 통과 후 대상으로 이동.
  #   (부분 쓰기/잘못된 config 가 운영 워크스페이스에 남는 상황 방지)
  local tmp_file
  tmp_file=$(mktemp)
  # 함수 종료 시 임시 파일 정리 (성공/실패 무관)
  trap 'rm -f "$tmp_file"' RETURN

  cp "$CONFIG_FILE" "$tmp_file"

  # ── 자동조회로 빈 GraphQL 식별자 채우기 ("명시 > 자동 > 실패") ──────────
  #   owner·project-number 는 eval 전역변수($OWNER 등)에 의존하지 않고 리더로 읽는다
  #   (단위호출·테스트에서 parse_config 가 안 돌아도 안전하게).
  local cur_owner cur_pnum cur_pid cur_sfid cur_afid
  cur_owner="$(PIPELINE_CONFIG="$tmp_file" bash "$reader" owner 2>/dev/null)"
  cur_pnum="$(PIPELINE_CONFIG="$tmp_file" bash "$reader" project-number 2>/dev/null)"
  cur_pid="$(PIPELINE_CONFIG="$tmp_file" bash "$reader" project-id 2>/dev/null)"
  cur_sfid="$(PIPELINE_CONFIG="$tmp_file" bash "$reader" status-field-id 2>/dev/null)"
  cur_afid="$(PIPELINE_CONFIG="$tmp_file" bash "$reader" area-field-id 2>/dev/null)"

  # 자동조회를 실제로 시도했는지 추적 — self-check 실패 메시지 분기에 사용(#5/F).
  #   owner·project-number 가 비어 자동조회를 아예 스킵한 경우와, 시도했으나 못 채운
  #   경우를 구분해야 한다(스킵인데 "자동조회 시도했으나 실패" 라고 오도하지 않도록).
  local auto_attempted=false
  # 3키 중 하나라도 비고, owner·project-number 가 있으면 자동조회 시도.
  #   (owner/pnum 자체가 비면 자동조회 입력이 없으니 시도 무의미 → 스킵, self-check 가 잡음.)
  if { [ -z "$cur_pid" ] || [ -z "$cur_sfid" ] || [ -z "$cur_afid" ]; } \
     && [ -n "$cur_owner" ] && [ -n "$cur_pnum" ]; then
    auto_attempted=true
    local resolved
    if resolved="$(resolve_project_field_ids "$cur_owner" "$cur_pnum")"; then
      # tsv: project-id<TAB>status-field-id<TAB>area-field-id (빈 칸 가능 — 못 찾은 필드)
      local r_pid r_sfid r_afid
      IFS=$'\t' read -r r_pid r_sfid r_afid <<<"$resolved"
      # 빈 키만 자동조회값으로 채움(명시값 보존, 자동조회 빈 칸은 주입 안 함).
      [ -z "$cur_pid" ]  && [ -n "$r_pid" ]  && upsert_claude_command_key "$tmp_file" project-id "$r_pid"
      [ -z "$cur_sfid" ] && [ -n "$r_sfid" ] && upsert_claude_command_key "$tmp_file" status-field-id "$r_sfid"
      [ -z "$cur_afid" ] && [ -n "$r_afid" ] && upsert_claude_command_key "$tmp_file" area-field-id "$r_afid"
      # "성공" 메시지는 빈 키가 실제로 다 채워졌을 때만(#4). 부분 충족이면 못 채운 키를
      #   알리는 중립 메시지 — 직후 self-check 실패와의 모순을 없앤다.
      local still_missing=()
      { [ -z "$cur_pid" ]  && [ -z "$r_pid" ]; }  && still_missing+=(project-id)
      { [ -z "$cur_sfid" ] && [ -z "$r_sfid" ]; } && still_missing+=(status-field-id)
      { [ -z "$cur_afid" ] && [ -z "$r_afid" ]; } && still_missing+=(area-field-id)
      if [ ${#still_missing[@]} -eq 0 ]; then
        info "Project v2 식별자 자동조회 성공 (project-number=$cur_pnum)"
      else
        warn "Project v2 식별자 자동조회 — 일부만 채움 (project-number=$cur_pnum). 못 채운 키: ${still_missing[*]} (커스텀 필드명일 수 있어 config 명시 필요할 수 있음)"
      fi
    else
      # 자동조회 실패 — 경고만 하고 진행. 최종 판정은 아래 self-check.
      #   read:project 스코프 부재가 흔한 원인이라 힌트를 함께 노출(#3/G).
      warn "Project v2 식별자 자동조회 실패 (owner=$cur_owner, project-number=$cur_pnum) — config 명시값으로 폴백합니다."
      warn "gh 토큰에 read:project(Projects 읽기) 스코프가 없으면 자동조회가 전부 실패할 수 있습니다 — \`gh auth refresh -s read:project\` 로 보강하세요."
    fi
  fi

  # ── self-check — 런타임 리더로 필수 키가 실제로 읽히는지 검증 ──────────
  #   필수 키를 배열 하나로 SSOT 화(require·에러메시지가 같은 출처를 보게).
  #   기본 5키: owner·project-number(영역/이슈 식별) + project-id·status-field-id·
  #   area-field-id(GraphQL Project v2 조작 — Status/Area 변경). reviewer.enabled=true
  #   면 reviewer-* 3키를 조건부 추가(codex Finding 2). 이 키들이 비면 원격쓰기 전
  #   fail-fast 한다(P4 — Reclip 실적용에서 런타임 필수키 확정).
  local required_keys=(owner project-number project-id status-field-id area-field-id)
  # reviewer.enabled 는 검증 대상인 tmp_file 에서 직접 읽는다(#8/F2 — 다른 5키와 동일
  #   하게 tmp_file 이 판정 출처가 되도록). 이전엔 parse_config 가 $CONFIG_FILE 에서 eval 로
  #   흘린 전역 REVIEWER_ENABLED 에 의존했는데, 검증 대상(tmp_file)과 출처가 갈렸다.
  #   parse_config 의 정규식(reviewer:\n  enabled:) 을 그대로 재사용한다.
  local reviewer_enabled_in_tmp
  reviewer_enabled_in_tmp="$(python3 - "$tmp_file" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
m = re.search(r'reviewer:\s*\n\s+enabled:\s*(\w+)', content)
print((m.group(1).strip().lower() if m else 'false'))
PYEOF
)"
  if [ "$reviewer_enabled_in_tmp" = "true" ]; then
    required_keys+=(reviewer-app-id reviewer-bot-slug reviewer-token-key)
  fi

  #   PIPELINE_CONFIG env 로 임시본 경로를 주입 → 대상에 옮기기 전에 검증.
  #   실패 시 리더의 stderr(누락 키 목록)를 사용자에게 그대로 보여준다(codex Finding 3).
  local selfcheck_err
  if ! selfcheck_err="$(PIPELINE_CONFIG="$tmp_file" bash "$reader" \
       --require "${required_keys[@]}" 2>&1 >/dev/null)"; then
    error "pipeline-config self-check 실패 — 런타임 리더가 필수 키를 읽지 못했습니다."
    error "필수 키: ${required_keys[*]}"
    [ -n "$selfcheck_err" ] && printf '%s\n' "$selfcheck_err" >&2
    # 안내 메시지 분기(#5/F) — 자동조회를 실제 시도했는지에 따라 원인이 다르다:
    #   · 시도 안 함(owner/project-number 자체가 빔) → 그 값들을 채우라고 정확히 안내.
    #   · 시도했으나 못 채움 → Area 등 커스텀 필드 수동입력 안내.
    if [ "$auto_attempted" = "true" ]; then
      error "project-number 로 자동조회를 시도했으나 채우지 못한 키가 있습니다 — Area 등 커스텀 필드는 config 의 claude-commands 에 수동 입력이 필요할 수 있습니다. 배치 중단: $CONFIG_FILE"
    else
      error "자동조회를 건너뛰었습니다(owner·project-number 가 비어 입력이 없음) — config 의 project.owner / project.project-numbers / claude-commands 의 누락 키를 확인하세요. 배치 중단: $CONFIG_FILE"
    fi
    return 1
  fi

  # 원자적 이동 — 검증 통과한 임시본을 대상으로 일괄 배치(덮어쓰기 = 멱등)
  mkdir -p "$dest_dir"
  mv -f "$tmp_file" "$dest"

  info "Pipeline config 생성 완료 ($dest)"
}

# ── 메인 ─────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Pipeline install.sh            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════╝${NC}"

  # ── 상호배타 플래그 거부 ────────────────────────────────────────
  # 두 부분 모드를 동시에 지정하면 어느 쪽이 실행될지 불명확 → 즉시 거부.
  # --rotate-webhook-secret 은 reapply 가 .env 를 건드리지 않으므로 조용히 무시됨 → 거부.
  if [ "$REAPPLY" = "true" ] && [ "$ROTATE_WEBHOOK_SECRET" = "true" ]; then
    error "--reapply 와 --rotate-webhook-secret 은 함께 사용할 수 없습니다."
    echo "  --reapply 는 .env 를 건드리지 않으므로 --rotate-webhook-secret 이 무시됩니다." >&2
    echo "  secret 을 회전하려면 풀 install 에서 --rotate-webhook-secret 만 지정하세요." >&2
    exit 1
  fi
  if [ "$REAPPLY" = "true" ] && [ "$UPDATE_COMMANDS_ONLY" = "true" ]; then
    error "--reapply 와 --update-commands-only 는 함께 사용할 수 없습니다."
    echo "  둘 다 부분 모드입니다. 원하는 동작 한 가지만 지정하세요." >&2
    exit 1
  fi

  # 체크리스트는 대화형 모드에서만 노출 (비대화형은 스킵)
  [ "$NON_INTERACTIVE" = "true" ] || show_checklist
  check_requirements

  # Config 파일 확인
  section "Config 로드"
  if [ ! -f "$CONFIG_FILE" ]; then
    error "Config 파일 없음: $CONFIG_FILE"
    echo "  cp config/pipeline-config.example.yml my-config.yml 후 값 채워서 사용"
    exit 1
  fi
  info "Config: $CONFIG_FILE"

  # Config 파싱 (eval로 변수 로드)
  eval "$(parse_config)"
  info "프로젝트: $OWNER (parent: $PARENT_REPO)"
  info "모듈 수: $MODULE_COUNT"

  # ── --update-commands-only — 런타임 config 만 빠른 재생성 후 종료 ──────────
  # secrets/variables/caller-yml/env 전부 스킵 (config 파싱은 이미 수행됨).
  # 플러그인 시대엔 "커맨드 재배포"의 실질 역할 = 런타임 config(.claude/pipeline-config.yml) 재생성.
  if [ "$UPDATE_COMMANDS_ONLY" = "true" ]; then
    section "Pipeline config 재생성 (전용 모드)"
    generate_pipeline_config
    echo ""
    info "런타임 config 재생성 완료 — 다른 단계는 스킵됨 (--update-commands-only)"
    exit 0
  fi

  # pipeline.repo 필수 — 호출자 yml 의 uses: 경로에 들어감
  if [ -z "$PIPELINE_REPO" ]; then
    error "config 의 pipeline.repo 가 비어있습니다 — 호출자 yml 의 uses: 경로에 필요합니다."
    echo "  config 에 다음을 추가하세요 (예):" >&2
    echo "    pipeline:" >&2
    echo "      repo: <owner>/Pipeline" >&2
    echo "      ref: main" >&2
    exit 1
  fi
  info "Pipeline 레포: $PIPELINE_REPO@$PIPELINE_REF"

  # ── --reapply — 운영 중 부분 재적용 후 종료 ────────────────────────
  # variables + 추적 라벨 + 호출자 yml 만 멱등 재적용.
  # secrets / generate_env(.env) / 런타임 config / npm 전부 스킵 →
  # app/.env(WEBHOOK_SECRET 포함) 를 일절 건드리지 않아 운영 App 파손 위험 0.
  if [ "$REAPPLY" = "true" ]; then
    VERDICT_DIR=".pipeline/state/reviews"
    section "부분 재적용 (--reapply)"
    warn "secrets/.env/런타임 config/npm 스킵 — variables·라벨·호출자 yml 만 재적용"
    # 환경변수 REVIEWER_BOT_LOGIN 원본을 보존.
    # 미제공(빈 값)이면 레포마다 기존 variable 을 읽어 결정(보존 or skip).
    # 제공된 경우는 모든 레포에 동일 값 사용.
    _REAPPLY_REVIEWER_ENV="${REVIEWER_BOT_LOGIN:-}"
    for i in $(seq 0 $((MODULE_COUNT - 1))); do
      local_name_var="MODULE_${i}_NAME"
      local_ci_var="MODULE_${i}_CI"
      local_strict_var="MODULE_${i}_STRICT"
      MOD_NAME="${!local_name_var}"
      MOD_CI="${!local_ci_var}"
      STRICT="${!local_strict_var}"
      REPO="$OWNER/$MOD_NAME"
      # modules-ignore 모듈(예: Design)은 의미론 표(--modules-table)엔 나오되
      # 영역 레포 등록(variable/caller-yml/label) 대상에선 제외 — 기존 동작 유지.
      if is_ignored_module "$MOD_NAME"; then
        echo ""
        echo -e "${YELLOW}⊘${NC} $REPO — modules-ignore, 등록 스킵" >&2
        continue
      fi
      echo ""
      echo -e "${CYAN}▶ $REPO${NC}"
      # 매 레포마다 환경변수 원본으로 리셋 후 결정 — 이전 레포의 기존값이 오염 안 되도록.
      REVIEWER_BOT_LOGIN="$_REAPPLY_REVIEWER_ENV"
      # reviewer.enabled=true 일 때만 기존 레포 variable 조회(fail-closed).
      # false 면 reviewer bot login 은 불필요 — 조회 자체를 건너뛰고 _SKIP_ 처리.
      if [ "$REVIEWER_ENABLED" = "true" ]; then
        resolve_reviewer_bot_login_for_reapply "$REPO" || exit 1
      else
        REVIEWER_BOT_LOGIN="_SKIP_"
      fi
      register_variables "$REPO" "$MOD_CI" "$STRICT" "true"
      install_caller_ymls "$REPO" "$MOD_CI"
      register_labels "$REPO"
    done
    # parent 레포 추적 라벨 (tracking.enabled=false 면 register_labels 내부 스킵)
    if [ -n "$PARENT_REPO" ]; then
      echo ""
      echo -e "${CYAN}▶ $PARENT_REPO (parent)${NC}"
      register_labels "$PARENT_REPO"
    fi
    echo ""
    info "부분 재적용 완료 — secrets/.env/런타임 config/npm 스킵됨 (--reapply)"
    exit 0
  fi

  # Secrets 입력 — 비대화형은 환경변수에서, 대화형은 프롬프트로
  section "Secrets 입력"
  if [ "$NON_INTERACTIVE" = "true" ]; then
    load_credentials_from_env
  else
    warn "PEM 파일 내용 전체가 secret으로 등록돼요 (경로가 아닌 내용)"
    echo ""

    AUTHOR_APP_ID=$(prompt_app_id "Author 봇")
    AUTHOR_PEM_PATH=$(prompt_pem "Author 봇")
    AUTHOR_PRIVATE_KEY=$(cat "$AUTHOR_PEM_PATH")
    AUTHOR_INSTALLATION_ID=$(prompt_installation_id "Author 봇")

    REVIEWER_BOT_LOGIN=""
    REVIEWER_APP_ID=""; REVIEWER_PEM_PATH=""; REVIEWER_PRIVATE_KEY=""; REVIEWER_INSTALLATION_ID=""

    if [ "$REVIEWER_ENABLED" = "true" ]; then
      echo ""
      warn "Reviewer 봇 (AI 리뷰용)"
      REVIEWER_APP_ID=$(prompt_app_id "Reviewer 봇")
      REVIEWER_PEM_PATH=$(prompt_pem "Reviewer 봇")
      REVIEWER_PRIVATE_KEY=$(cat "$REVIEWER_PEM_PATH")
      REVIEWER_INSTALLATION_ID=$(prompt_installation_id "Reviewer 봇")
      REVIEWER_BOT_LOGIN=$(prompt "Reviewer 봇 로그인 이름 (예: my-review-bot[bot])")
    fi

    read -rp "$(echo -e "${CYAN}?${NC} Slack Webhook URL (없으면 Enter): ")" SLACK_WEBHOOK_URL || SLACK_WEBHOOK_URL=""
  fi

  # Webhook Secret 결정 — 대화형·비대화형 공통 (기존 .env 값 보존이 안전 기본값)
  resolve_webhook_secret

  VERDICT_DIR=".pipeline/state/reviews"

  # 각 모듈 처리
  section "영역 레포 등록"
  for i in $(seq 0 $((MODULE_COUNT - 1))); do
    local_name_var="MODULE_${i}_NAME"
    local_ci_var="MODULE_${i}_CI"
    local_strict_var="MODULE_${i}_STRICT"
    MOD_NAME="${!local_name_var}"
    MOD_CI="${!local_ci_var}"
    REPO="$OWNER/$MOD_NAME"

    # modules-ignore 모듈(예: Design)은 의미론 표(--modules-table)엔 나오되
    # 영역 레포 등록(secret/variable/caller-yml/label) 대상에선 제외 — 기존 동작 유지.
    if is_ignored_module "$MOD_NAME"; then
      echo ""
      echo -e "${YELLOW}⊘${NC} $REPO — modules-ignore, 등록 스킵" >&2
      continue
    fi

    # strict-review-bot-check — config에서 주입 (미지정 모듈은 parse_config가 true로 emit)
    STRICT="${!local_strict_var}"

    echo ""
    echo -e "${CYAN}▶ $REPO${NC}"
    register_secrets "$REPO"
    register_variables "$REPO" "$MOD_CI" "$STRICT"
    install_caller_ymls "$REPO" "$MOD_CI"
    register_labels "$REPO"
  done

  # parent 레포 추적 라벨 — critic 추적 이슈가 parent 레포에 생기므로 1회 등록
  # (모듈 루프 밖. tracking.enabled=false 면 register_labels 내부에서 스킵)
  if [ -n "$PARENT_REPO" ]; then
    echo ""
    echo -e "${CYAN}▶ $PARENT_REPO (parent)${NC}"
    register_labels "$PARENT_REPO"
  fi

  # App .env 생성
  section "App 환경변수 생성"
  generate_env

  # Pipeline config 생성 — 플러그인 런타임 리더용 .claude/pipeline-config.yml.
  # 워크스페이스 1개라 모듈 루프 밖 1회 호출.
  section "Pipeline config 생성"
  generate_pipeline_config

  # package-lock.json 생성
  section "npm install"
  generate_package_lock

  # 완료 + 다음 단계
  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  ✅ install.sh 완료                   ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
  echo ""
  echo "📋 남은 수동 작업:"
  echo ""
  echo -e "${YELLOW}1️⃣  GitHub App webhook URL + Secret 업데이트 (GitHub UI)${NC}"
  echo "   두 App 모두 → Webhook URL:"
  echo "   https://<tunnel-url>/api/github/webhooks"
  echo "   Webhook Secret:"
  echo "   $WEBHOOK_SECRET"
  echo ""
  echo -e "${YELLOW}2️⃣  App 실행${NC}"
  echo "   cd $REPO_ROOT/app"
  echo "   docker compose up -d --build"
  echo "   docker compose logs -f  # 로그 확인"
  echo ""
  info "모두 완료되면 자동화 파이프라인이 작동합니다 🚀"
}

# 직접 실행 시에만 main 실행. `source` 로 로드되면 함수만 등록(테스트 하니스용).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
