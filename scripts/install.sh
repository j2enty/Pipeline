#!/usr/bin/env bash
# install.sh — Pipeline 이식 자동화 스크립트
#
# 사용법:
#   ./scripts/install.sh [<pipeline-config.yml 경로>]
#
# 기본 config 경로: examples/reclip/pipeline-config.yml
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
CONFIG_FILE="${1:-$REPO_ROOT/examples/reclip/pipeline-config.yml}"

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
print(f"PROJECT_NUMBERS_JSON={json.dumps(pn_items)}")

# modules-ignore JSON 배열
mi = re.search(r'modules-ignore:\s*\n((?:\s+-\s*.+\n?)*)', content)
items = re.findall(r'-\s*"?([^"\n]+)"?', mi.group(1)) if mi else []
print(f"MODULES_IGNORE_JSON={json.dumps([i.strip() for i in items])}")

# reviewer enabled
rev = re.search(r'reviewer:\s*\n\s+enabled:\s*(\w+)', content)
print(f"REVIEWER_ENABLED={rev.group(1) if rev else 'false'}")

# modules
names = re.findall(r'^\s+-\s+name:\s*(.+)$', content, re.MULTILINE)
ci_names = re.findall(r'^\s+ci-workflow-name:\s*"?([^"#\n]*)"?\s*$', content, re.MULTILINE)
for i, name in enumerate(names):
    ci = ci_names[i].strip().strip("'\"") if i < len(ci_names) else ''
    print(f"MODULE_{i}_NAME='{name.strip()}'")
    print(f"MODULE_{i}_CI='{ci}'")
print(f"MODULE_COUNT={len(names)}")

# 영역 모듈 이름들을 JSON 배열로 (App 폴러 환경변수 MODULES 용)
print(f"MODULES_JSON={json.dumps([n.strip() for n in names])}")
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
  local env_file="$REPO_ROOT/app/.env"
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
PORT=3000
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

  show_checklist
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

  # Secrets 입력
  section "Secrets 입력"
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

  VERDICT_DIR=".omc/state/reviews"

  # 각 모듈 처리
  section "영역 레포 등록"
  for i in $(seq 0 $((MODULE_COUNT - 1))); do
    local_name_var="MODULE_${i}_NAME"
    local_ci_var="MODULE_${i}_CI"
    MOD_NAME="${!local_name_var}"
    MOD_CI="${!local_ci_var}"
    REPO="$OWNER/$MOD_NAME"

    # Admin은 strict=false (review bot 체크 완화)
    STRICT="true"
    [ "$MOD_NAME" = "Admin" ] && STRICT="false"

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
