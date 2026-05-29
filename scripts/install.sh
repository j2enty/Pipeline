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
#
# 비대화형 모드(--non-interactive)에서 읽는 환경변수:
#   AUTHOR_APP_ID, AUTHOR_PEM(=PEM 파일 경로), AUTHOR_INSTALLATION_ID  — 필수
#   REVIEWER_APP_ID, REVIEWER_PEM, REVIEWER_INSTALLATION_ID, REVIEWER_BOT_LOGIN
#                        — reviewer.enabled=true 일 때만 필수
#   SLACK_WEBHOOK_URL    — 옵션 (없으면 빈 값)
#   WEBHOOK_SECRET       — 옵션 (없으면 자동 생성)
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
    m = re.search(rf'^\s+{re.escape(key)}:\s*"?([^"#\n]+)"?\s*$', content, re.MULTILINE)
    return m.group(1).strip().strip("'\"") if m else default

# 스칼라 값
print(f"OWNER='{get_scalar('owner')}'")
print(f"PARENT_REPO='{get_scalar('parent-repository')}'")
print(f"WORKING_DIR='{get_scalar('working-directory')}'")
print(f"SLACK_CHANNEL='{get_scalar('slack-channel')}'")

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

  # Webhook Secret — 옵션 (없으면 자동 생성)
  if [ -n "${WEBHOOK_SECRET:-}" ]; then
    info "Webhook Secret — 환경변수 사용"
  else
    WEBHOOK_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    info "Webhook Secret 자동 생성"
  fi

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
  gh variable set PIPELINE_REVIEWER_BOT_LOGIN       --repo "$repo" --body "$REVIEWER_BOT_LOGIN"
  gh variable set PIPELINE_VERDICT_DIR              --repo "$repo" --body "$VERDICT_DIR"
  gh variable set PIPELINE_STRICT_REVIEW_BOT_CHECK  --repo "$repo" --body "$strict"
  [ -n "$ci_name" ] && \
    gh variable set PIPELINE_CI_WORKFLOW_NAME       --repo "$repo" --body "$ci_name"
  info "variables 등록 완료"
}

# ── 호출자 yml 설치 ──────────────────────────────────────────
install_caller_ymls() {
  local repo="$1" mod_ci="${2:-}"
  local src="$REPO_ROOT/examples/reclip/.github/workflows"
  echo "  호출자 yml 설치 중..."
  for yml in auto-kickoff.yml auto-review.yml auto-merge.yml \
             auto-critic.yml auto-critic-dispatch.yml parent-autoclose.yml; do
    [ -f "$src/$yml" ] || continue
    local content sha msg tmp_file
    # auto-merge.yml: workflow_run.workflows CI 이름을 영역별로 치환
    if [ "$yml" = "auto-merge.yml" ] && [ -n "$mod_ci" ]; then
      tmp_file=$(mktemp)
      sed "s|workflows: \[\"Backend CI\"\]|workflows: [\"$mod_ci\"]|g" "$src/$yml" > "$tmp_file"
      content=$(base64 < "$tmp_file" | tr -d '\n')
      rm -f "$tmp_file"
    else
      content=$(base64 < "$src/$yml" | tr -d '\n')
    fi
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

    WEBHOOK_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    info "Webhook Secret 자동 생성"
  fi

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
  done

  # App .env 생성
  section "App 환경변수 생성"
  generate_env

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

main "$@"
