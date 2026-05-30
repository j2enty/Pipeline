#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 되며, 설정하는 변수들은 함께 source 된
# install.sh 함수가 소비한다(shellcheck 가 못 봄). 미사용 경고를 끈다.
# shellcheck disable=SC2034
# Phase 2 — WEBHOOK_SECRET 보존 로직 (gh 불필요, 격리 함수 테스트).
# T1 기존 .env값 보존 / T2 .env없으면 새 hex / T3 --rotate면 기존과 다른값
# T4 비대화형 env-var 우선순위 하위호환 / T5 generate_env 출력 정확성

# T1 — 기존 .env 의 WEBHOOK_SECRET 값을 보존
it "T1 기존 .env 의 WEBHOOK_SECRET 보존"
(
  setup_install_env
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  printf 'WEBHOOK_SECRET=preserved_secret_abc123\nPORT=3000\n' > "$tmp_env"
  ROTATE_WEBHOOK_SECRET=false
  unset WEBHOOK_SECRET
  resolve_webhook_secret >/dev/null 2>&1
  assert_eq "preserved_secret_abc123" "$WEBHOOK_SECRET" "기존값 미보존" && pass
  rm -f "$tmp_env"
)

# T2 — .env 없으면 새 64자리 hex 생성
it "T2 .env 없으면 새 hex 생성 (64자리)"
(
  setup_install_env
  ENV_FILE="$(mktemp -u)"   # 존재하지 않는 경로
  ROTATE_WEBHOOK_SECRET=false
  unset WEBHOOK_SECRET
  resolve_webhook_secret >/dev/null 2>&1
  len="${#WEBHOOK_SECRET}"
  assert_eq "64" "$len" "token_hex(32)=64자리 아님" || return
  # hex 문자만인지
  case "$WEBHOOK_SECRET" in
    *[!0-9a-f]*) fail "hex 외 문자 포함: $WEBHOOK_SECRET"; return ;;
  esac
  pass
)

# T3 — --rotate 면 기존값 있어도 새 값(기존과 다름)
it "T3 --rotate-webhook-secret 면 기존값과 다른 새 값"
(
  setup_install_env
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  printf 'WEBHOOK_SECRET=old_value_should_rotate\n' > "$tmp_env"
  ROTATE_WEBHOOK_SECRET=true
  unset WEBHOOK_SECRET
  resolve_webhook_secret >/dev/null 2>&1
  assert_ne "old_value_should_rotate" "$WEBHOOK_SECRET" "회전 안 됨" || { rm -f "$tmp_env"; return; }
  assert_eq "64" "${#WEBHOOK_SECRET}" "회전값 64자리 아님" && pass
  rm -f "$tmp_env"
)

# T4 — 비대화형 env-var 우선순위 하위호환
#   .env 없음 + 환경변수 WEBHOOK_SECRET 있음 → 환경변수 사용 (③)
it "T4 .env 없을 때 환경변수 WEBHOOK_SECRET 사용 (하위호환)"
(
  setup_install_env
  ENV_FILE="$(mktemp -u)"   # .env 없음
  ROTATE_WEBHOOK_SECRET=false
  WEBHOOK_SECRET="env_provided_secret"
  resolve_webhook_secret >/dev/null 2>&1
  assert_eq "env_provided_secret" "$WEBHOOK_SECRET" "환경변수 미사용" && pass
)

# T4b — 우선순위: 기존 .env 값이 환경변수보다 우선 (운영 보존이 최우선)
it "T4b 기존 .env 값이 환경변수보다 우선"
(
  setup_install_env
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  printf 'WEBHOOK_SECRET=from_dotenv\n' > "$tmp_env"
  ROTATE_WEBHOOK_SECRET=false
  WEBHOOK_SECRET="from_envvar"
  resolve_webhook_secret >/dev/null 2>&1
  assert_eq "from_dotenv" "$WEBHOOK_SECRET" ".env 우선 안 됨" && pass
  rm -f "$tmp_env"
)

# T4c — .env 의 WEBHOOK_SECRET 값이 비면(키만) 경고 + 새 생성 (파손 방지)
it "T4c .env WEBHOOK_SECRET 값 빈칸이면 새로 생성"
(
  setup_install_env
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  printf 'WEBHOOK_SECRET=\nPORT=3000\n' > "$tmp_env"
  ROTATE_WEBHOOK_SECRET=false
  unset WEBHOOK_SECRET
  resolve_webhook_secret >/dev/null 2>&1
  assert_eq "64" "${#WEBHOOK_SECRET}" "빈값일 때 새 생성 안 됨" && pass
  rm -f "$tmp_env"
)

# T5 — generate_env 출력에 WEBHOOK_SECRET 이 정확히 1회 + 보존값
it "T5 generate_env 출력: WEBHOOK_SECRET 정확히 1회 + 보존값"
(
  setup_install_env
  eval "$(parse_config)"            # OWNER/MODULES_JSON 등 채움
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  # 기존 .env(보존 대상) — generate_env 가 읽지는 않지만 일관성 위해 동일 값 사용
  WEBHOOK_SECRET="preserved_xyz"
  # generate_env 가 참조하는 필수 변수 세팅
  AUTHOR_APP_ID="111"; AUTHOR_PEM_PATH="/tmp/a.pem"; AUTHOR_INSTALLATION_ID="222"
  REVIEWER_APP_ID="333"; REVIEWER_PEM_PATH="/tmp/r.pem"
  REVIEWER_INSTALLATION_ID="444"; REVIEWER_BOT_LOGIN="rev[bot]"
  SLACK_WEBHOOK_URL=""; PORT_VALUE="3000"
  generate_env >/dev/null 2>&1
  out="$(cat "$tmp_env")"
  count="$(grep -c '^WEBHOOK_SECRET=' "$tmp_env")"
  assert_eq "1" "$count" "WEBHOOK_SECRET 라인 1회 아님" || { rm -f "$tmp_env"; return; }
  assert_contains "$out" "WEBHOOK_SECRET=preserved_xyz" "보존값 미출력" || { rm -f "$tmp_env"; return; }
  # 회귀: 기존 포맷 핵심 키 존재
  assert_contains "$out" "AUTHOR_APP_ID=111" "포맷 회귀(AUTHOR_APP_ID)" || { rm -f "$tmp_env"; return; }
  assert_contains "$out" "PORT=3000" "포맷 회귀(PORT)" || { rm -f "$tmp_env"; return; }
  assert_contains "$out" "NODE_ENV=production" "포맷 회귀(NODE_ENV)" && pass
  rm -f "$tmp_env"
)
