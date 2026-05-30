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
#                        config 파싱 + Claude 슬래시커맨드 배포만 실행 후 종료
#                        (커맨드 템플릿 수정 후 빠른 로컬 재배포용)
#   --reapply            secrets/.env/커맨드/npm 전부 스킵하고
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
UPDATE_COMMANDS_ONLY=false  # --update-commands-only
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
info()    { echo -e "${GREEN}✅${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠️ ${NC} $1"; }
error()   { echo -e "${RED}❌${NC} $1" >&2; }
section() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

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
    mq = re.search(rf'^\s+{re.escape(key)}:\s*"([^"\n]*)"\s*$', content, re.MULTILINE)
    if not mq:
        mq = re.search(rf"^\s+{re.escape(key)}:\s*'([^'\n]*)'\s*$", content, re.MULTILINE)
    if mq:
        return mq.group(1).strip()
    # 무따옴표 폴백 — [^"#\n] 로 인라인 주석(# 이후) 제거
    m = re.search(rf'^\s+{re.escape(key)}:\s*([^"#\n]*)', content, re.MULTILINE)
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
    mq = re.search(rf'^\s+{re.escape(key)}:\s*"([^"\n]*)"\s*$', block, re.MULTILINE)
    if not mq:
        mq = re.search(rf"^\s+{re.escape(key)}:\s*'([^'\n]*)'\s*$", block, re.MULTILINE)
    if mq:
        return mq.group(1).strip()
    # 무따옴표 폴백 — [^"#\n] 로 인라인 주석(# 이후) 제거
    m = re.search(rf'^\s+{re.escape(key)}:\s*([^"#\n]*)', block, re.MULTILINE)
    return m.group(1).strip().strip("'\"") if m and m.group(1).strip() else default
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
name_iter = list(re.finditer(r'^\s+-\s+name:\s*"?([^"#\n]+)"?\s*$', modules_block, re.MULTILINE))
names = []
for idx, m in enumerate(name_iter):
    name = m.group(1).strip().strip("'\"")
    block_start = m.end()
    block_end = name_iter[idx + 1].start() if idx + 1 < len(name_iter) else len(modules_block)
    block = modules_block[block_start:block_end]

    ci_m = re.search(r'^\s+ci-workflow-name:\s*"?([^"#\n]*)"?\s*$', block, re.MULTILINE)
    ci = ci_m.group(1).strip().strip("'\"") if ci_m else ''

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
print(f"MODULES_JSON='{json.dumps(names, separators=(',', ':'))}'")

# ── claude-commands 섹션 — Claude 슬래시커맨드 로컬 배포용 ────────────
# claude-commands: 섹션부터 다음 최상위 키 직전까지 슬라이스해 그 안에서만 탐색
# (다른 섹션의 동명 키와 충돌 방지)
cc = re.search(r'^claude-commands:\s*\n(.*?)(?=^\S|\Z)', content, re.MULTILINE | re.DOTALL)
cc_block = cc.group(1) if cc else ''

# enabled — 미지정 시 기본 false
cc_en = re.search(r'^\s+enabled:\s*(\w+)', cc_block, re.MULTILINE)
cc_enabled = cc_en.group(1).strip().lower() if cc_en else 'false'
if cc_enabled not in ('true', 'false'):
    cc_enabled = 'false'
print(f"CMD_ENABLED={cc_enabled}")

# 스칼라 항목들 — claude-commands 블록 내부에서만 탐색
# (CLAUDE.md 설정 중복 방지 원칙: owner/project-number/slack-channel/parent-repo-name 은
#  여기서 새로 만들지 않고 기존 값에서 셸 측에서 파생)
print(f"CMD_PROJECT_NAME='{get_scalar_in(cc_block, 'project-name')}'")
print(f"CMD_PROJECT_ID='{get_scalar_in(cc_block, 'project-id')}'")
print(f"CMD_STATUS_FIELD_ID='{get_scalar_in(cc_block, 'status-field-id')}'")
print(f"CMD_AREA_FIELD_ID='{get_scalar_in(cc_block, 'area-field-id')}'")
print(f"CMD_REVIEWER_APP_ID='{get_scalar_in(cc_block, 'reviewer-app-id')}'")
print(f"CMD_REVIEWER_BOT_SLUG='{get_scalar_in(cc_block, 'reviewer-bot-slug')}'")
print(f"CMD_REVIEWER_TOKEN_KEY='{get_scalar_in(cc_block, 'reviewer-token-key')}'")
print(f"CMD_SLACK_TOKEN_KEY='{get_scalar_in(cc_block, 'slack-token-key')}'")
print(f"CMD_AUTHOR_LOGIN='{get_scalar_in(cc_block, 'author-login')}'")
print(f"CMD_LOCAL_ACCOUNT='{get_scalar_in(cc_block, 'local-account')}'")
print(f"CMD_DOCS_CONTEXT_DIR='{get_scalar_in(cc_block, 'docs-context-dir')}'")

# area-ids 매핑 (영역명 → 해시) — area-ids: 하위의 `<name>: <hash>` 들을 추출
# CMD_AREA_ID_<UPPER> 형태로 emit (예: Backend → CMD_AREA_ID_BACKEND)
ai = re.search(r'^\s+area-ids:\s*\n((?:\s+\S+:\s*.+\n?)*)', cc_block, re.MULTILINE)
area_ids_block = ai.group(1) if ai else ''
for am in re.finditer(r'^\s+([A-Za-z0-9_]+):\s*"?([^"#\n]+)"?\s*$', area_ids_block, re.MULTILINE):
    area_name = am.group(1).strip()
    area_hash = am.group(2).strip().strip("'\"")
    print(f"CMD_AREA_ID_{area_name.upper()}='{area_hash}'")

# ── tracking 섹션 — finding 추적 라벨 자동 등록용 ───────────────────────
# tracking: 섹션부터 다음 최상위 키 직전까지 슬라이스해 그 안에서만 탐색
# (claude-commands 블록 파싱과 동일 방식 — 다른 섹션의 동명 키와 충돌 방지)
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
  # `^WEBHOOK_SECRET=` 앵커 — 첫 매칭 라인만. 값은 '=' 이후 전체(공백·특수문자 포함 가능)
  line="$(grep -m1 '^WEBHOOK_SECRET=' "$ENV_FILE" 2>/dev/null || true)"
  [ -n "$line" ] || { printf '%s' ""; return 0; }
  value="${line#WEBHOOK_SECRET=}"
  if [ -z "$value" ]; then
    warn "기존 .env 의 WEBHOOK_SECRET 값이 비어있음 — 새로 생성합니다 ($ENV_FILE)" >&2
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

# ── 레포의 기존 GitHub variable 값 조회 ──────────────────────
# `gh variable list --json name,value` 로 기존 variable 값을 읽어 반환.
# 없거나 빈 값이면 빈 문자열. reapply 모드에서 config 에서 파생 불가능한
# secret-time 입력값(PIPELINE_REVIEWER_BOT_LOGIN 등)을 보존할 때 사용.
read_existing_repo_variable() {
  local repo="$1" var_name="$2"
  local raw
  # python3 로 json 파싱 — jq 의존 없이 이식 가능
  raw="$(gh variable list --repo "$repo" --json name,value 2>/dev/null || true)"
  [ -n "$raw" ] || { printf '%s' ""; return 0; }
  printf '%s' "$raw" | python3 -c "
import sys, json
data = json.load(sys.stdin)
name = sys.argv[1]
for item in data:
    if item.get('name') == name:
        print(item.get('value', ''), end='')
        sys.exit(0)
" "$var_name" 2>/dev/null || true
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
  # ② 기존 레포 variable 읽기
  local existing
  existing="$(read_existing_repo_variable "$repo" "PIPELINE_REVIEWER_BOT_LOGIN")"
  if [ -n "$existing" ]; then
    REVIEWER_BOT_LOGIN="$existing"
    info "PIPELINE_REVIEWER_BOT_LOGIN — 기존 레포 값 보존 ($repo)"
    return 0
  fi
  # ③ 둘 다 없음 — skip 표시
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
register_variables() {
  local repo="$1" ci_name="$2" strict="$3"
  echo "  variables 등록 중..."
  gh variable set PIPELINE_OWNER                    --repo "$repo" --body "$OWNER"
  gh variable set PIPELINE_PARENT_REPOSITORY        --repo "$repo" --body "$PARENT_REPO"
  gh variable set PIPELINE_MODULES_IGNORE           --repo "$repo" --body "$MODULES_IGNORE_JSON"
  gh variable set PIPELINE_WORKING_DIRECTORY        --repo "$repo" --body "$WORKING_DIR"
  # REVIEWER_BOT_LOGIN 이 "_SKIP_"(reapply 보존 불가 표시) 또는 빈 값이면 등록 스킵.
  # - 풀 install: 항상 값이 채워져 있으므로 이 분기에 진입 안 함 (동작 불변).
  # - reapply: 환경변수·기존값 어디서도 값을 못 얻은 경우만 스킵.
  if [ "${REVIEWER_BOT_LOGIN:-}" != "_SKIP_" ] && [ -n "${REVIEWER_BOT_LOGIN:-}" ]; then
    gh variable set PIPELINE_REVIEWER_BOT_LOGIN     --repo "$repo" --body "$REVIEWER_BOT_LOGIN"
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
             auto-critic.yml auto-critic-dispatch.yml parent-autoclose.yml; do
    [ -f "$src/$yml" ] || continue
    local content sha msg tmp_file
    tmp_file=$(mktemp)
    # 모든 yml 공통: Pipeline 레포 경로·ref placeholder 치환
    #   값에 '/' 가 들어가므로(레포 경로) sed 구분자를 '|' 로 사용
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

# ── Claude 슬래시커맨드 로컬 배포 ─────────────────────────────
# templates/claude-commands/*.md.tmpl 을 config 값으로 치환해
# 워크스페이스 루트($WORKING_DIR)의 .claude/commands/ 에 로컬 파일로 배포한다.
#
# caller-yml(install_caller_ymls)과의 차이:
#   caller-yml = gh api PUT 으로 "원격 레포"에 커밋
#   command    = 로컬 워크스페이스 파일 → 단순 로컬 write
#
# 원자성: 임시 디렉토리에 3개 전부 생성·검증 성공 후에야 대상 디렉토리로 이동
#         (부분 실패로 일부만 갱신되는 상황 방지)
install_claude_commands() {
  # enabled=false 면 스킵 (로그만)
  if [ "${CMD_ENABLED:-false}" != "true" ]; then
    info "claude-commands.enabled=false — 슬래시커맨드 배포 스킵"
    return 0
  fi

  local src="$REPO_ROOT/templates/claude-commands"
  if [ ! -d "$src" ]; then
    error "템플릿 디렉토리 없음: $src"
    return 1
  fi

  # 배포 대상 — working-directory 재사용 (별도 dir 항목 안 만듦)
  if [ -z "${WORKING_DIR:-}" ]; then
    error "claude-commands 배포 실패 — working-directory 가 비어있습니다 (배포 경로 산출 불가)"
    return 1
  fi
  local dest_dir="$WORKING_DIR/.claude/commands"

  # ── 기존 재사용 값에서 파생 (설정 중복 방지) ──────────────────
  # __ORG__            ← OWNER
  # __PARENT_REPO_NAME__ ← PARENT_REPO(<owner>/<repo>)의 repo 부분
  # __PROJECT_NUMBER__ ← PROJECT_NUMBERS_JSON 의 첫 요소
  # __SLACK_CHANNEL__  ← SLACK_CHANNEL
  local org="$OWNER"
  local parent_repo_name="${PARENT_REPO##*/}"   # 'a/b' → 'b'
  local project_number
  project_number=$(printf '%s' "${PROJECT_NUMBERS_JSON:-[]}" | python3 -c "import sys,json; a=json.load(sys.stdin); print(a[0] if a else '')")
  local slack_channel="${SLACK_CHANNEL:-}"

  echo "  Claude 슬래시커맨드 배포 중... (→ $dest_dir)"

  # 임시 작업 디렉토리 — 원자적 배포용
  local tmp_dir
  tmp_dir=$(mktemp -d)
  # 함수 종료 시 임시 디렉토리 정리 (성공/실패 무관)
  trap 'rm -rf "$tmp_dir"' RETURN

  # sed 치환 인자 배열 — 모든 placeholder 1:1 매핑
  #   값에 '/'(예: Docs/claude/context)·'&' 가 들어갈 수 있으므로 sed 구분자는 '|' 사용.
  #   치환값 내부의 '|'·'&'·'\' 는 이스케이프 (sed 메타문자 안전).
  #   placeholder 가 '__' 로 끝나고 결합형 suffix 는 '_' 로 시작하므로
  #   (__REVIEWER_TOKEN_KEY___PRIVATE_KEY) 경계가 정확히 보존된다.
  esc() { printf '%s' "$1" | sed -e 's/[\|&\\]/\\&/g'; }

  local sed_args=(
    -e "s|__ORG__|$(esc "$org")|g"
    -e "s|__PARENT_REPO_NAME__|$(esc "$parent_repo_name")|g"
    -e "s|__PROJECT_NAME__|$(esc "$CMD_PROJECT_NAME")|g"
    -e "s|__PROJECT_NUMBER__|$(esc "$project_number")|g"
    -e "s|__PROJECT_ID__|$(esc "$CMD_PROJECT_ID")|g"
    -e "s|__STATUS_FIELD_ID__|$(esc "$CMD_STATUS_FIELD_ID")|g"
    -e "s|__AREA_FIELD_ID__|$(esc "$CMD_AREA_FIELD_ID")|g"
    -e "s|__REVIEWER_APP_ID__|$(esc "$CMD_REVIEWER_APP_ID")|g"
    -e "s|__REVIEWER_BOT_SLUG__|$(esc "$CMD_REVIEWER_BOT_SLUG")|g"
    -e "s|__REVIEWER_TOKEN_KEY__|$(esc "$CMD_REVIEWER_TOKEN_KEY")|g"
    -e "s|__SLACK_CHANNEL__|$(esc "$slack_channel")|g"
    -e "s|__SLACK_TOKEN_KEY__|$(esc "$CMD_SLACK_TOKEN_KEY")|g"
    -e "s|__AUTHOR_LOGIN__|$(esc "$CMD_AUTHOR_LOGIN")|g"
    -e "s|__LOCAL_ACCOUNT__|$(esc "$CMD_LOCAL_ACCOUNT")|g"
    -e "s|__DOCS_CONTEXT_DIR__|$(esc "$CMD_DOCS_CONTEXT_DIR")|g"
    -e "s|__AREA_ID_BACKEND__|$(esc "${CMD_AREA_ID_BACKEND:-}")|g"
    -e "s|__AREA_ID_ADMIN__|$(esc "${CMD_AREA_ID_ADMIN:-}")|g"
    -e "s|__AREA_ID_FRONTEND__|$(esc "${CMD_AREA_ID_FRONTEND:-}")|g"
    -e "s|__AREA_ID_IOS__|$(esc "${CMD_AREA_ID_IOS:-}")|g"
    -e "s|__AREA_ID_ANDROID__|$(esc "${CMD_AREA_ID_ANDROID:-}")|g"
    -e "s|__AREA_ID_DESIGN__|$(esc "${CMD_AREA_ID_DESIGN:-}")|g"
  )

  # 3개 템플릿 치환 → 임시 디렉토리에 생성
  local tmpl base out
  for tmpl in review.md.tmpl kickoff.md.tmpl plan.md.tmpl; do
    if [ ! -f "$src/$tmpl" ]; then
      error "템플릿 파일 없음: $src/$tmpl"
      return 1
    fi
    base="${tmpl%.tmpl}"   # review.md.tmpl → review.md
    out="$tmp_dir/$base"
    sed "${sed_args[@]}" "$src/$tmpl" > "$out"
  done

  # self-check — 미치환 placeholder 잔존 검사 (배포 전 차단)
  local leftover
  leftover=$(grep -rl '__[A-Z_]*__' "$tmp_dir" 2>/dev/null || true)
  if [ -n "$leftover" ]; then
    error "치환 누락 — 배포본에 placeholder 잔존:"
    grep -rohn '__[A-Z_]*__' "$tmp_dir" | sort -u >&2
    error "config 의 claude-commands 항목을 확인하세요. 배포 중단."
    return 1
  fi

  # 원자적 이동 — 검증 통과한 임시본을 대상 디렉토리로 일괄 배치
  mkdir -p "$dest_dir"
  for tmpl in review.md.tmpl kickoff.md.tmpl plan.md.tmpl; do
    base="${tmpl%.tmpl}"
    mv -f "$tmp_dir/$base" "$dest_dir/$base"
    echo "    ✅ $base"
  done

  info "Claude 슬래시커맨드 배포 완료 ($dest_dir)"
}

# ── 메인 ─────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Pipeline install.sh            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════╝${NC}"

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

  # ── --update-commands-only — 커맨드만 빠른 재배포 후 종료 ──────────
  # secrets/variables/caller-yml/env 전부 스킵 (config 파싱은 이미 수행됨)
  if [ "$UPDATE_COMMANDS_ONLY" = "true" ]; then
    section "Claude 슬래시커맨드 배포 (전용 모드)"
    install_claude_commands
    echo ""
    info "커맨드 재배포 완료 — 다른 단계는 스킵됨 (--update-commands-only)"
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
  # secrets / generate_env(.env) / 커맨드 / npm 전부 스킵 →
  # app/.env(WEBHOOK_SECRET 포함) 를 일절 건드리지 않아 운영 App 파손 위험 0.
  if [ "$REAPPLY" = "true" ]; then
    VERDICT_DIR=".omc/state/reviews"
    section "부분 재적용 (--reapply)"
    warn "secrets/.env/커맨드/npm 스킵 — variables·라벨·호출자 yml 만 재적용"
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
      echo ""
      echo -e "${CYAN}▶ $REPO${NC}"
      # 매 레포마다 환경변수 원본으로 리셋 후 결정 — 이전 레포의 기존값이 오염 안 되도록.
      REVIEWER_BOT_LOGIN="$_REAPPLY_REVIEWER_ENV"
      resolve_reviewer_bot_login_for_reapply "$REPO"
      register_variables "$REPO" "$MOD_CI" "$STRICT"
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
    info "부분 재적용 완료 — secrets/.env/커맨드/npm 스킵됨 (--reapply)"
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

  VERDICT_DIR=".omc/state/reviews"

  # 각 모듈 처리
  section "영역 레포 등록"
  for i in $(seq 0 $((MODULE_COUNT - 1))); do
    local_name_var="MODULE_${i}_NAME"
    local_ci_var="MODULE_${i}_CI"
    local_strict_var="MODULE_${i}_STRICT"
    MOD_NAME="${!local_name_var}"
    MOD_CI="${!local_ci_var}"
    REPO="$OWNER/$MOD_NAME"

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

  # Claude 슬래시커맨드 배포 — 워크스페이스 1개라 모듈 루프 밖 1회 호출
  section "Claude 슬래시커맨드 배포"
  install_claude_commands

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
