#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Fix 5 — 기존 .env 보존 시 환경변수 WEBHOOK_SECRET 침묵 무시 가시화.
# .env 값과 환경변수가 다를 때 warn 1회 출력. 동작(보존 우선)은 불변.

# F5-1 — .env 값과 env-var 다를 때 warn 출력 + 보존값 사용
it "F5-1 .env 값과 WEBHOOK_SECRET 환경변수 다를 때 warn 출력"
(
  setup_install_env
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  printf 'WEBHOOK_SECRET=dotenv_value\n' > "$tmp_env"
  ROTATE_WEBHOOK_SECRET=false
  WEBHOOK_SECRET="envvar_value"   # 다른 값
  # warn() 은 stderr 로 쓴다 — 아래 병합 캡처(>"$warn_log" 2>&1)로 확인.
  # resolve_webhook_secret 는 직접 호출
  # (서브셸 금지 — WEBHOOK_SECRET 변경이 현재 셸에 반영돼야 함).
  # stdout+stderr 를 임시 파일로 병합 캡처하여 warn 메시지를 확인.
  warn_log="$(mktemp)"
  resolve_webhook_secret >"$warn_log" 2>&1
  stderr_out="$(cat "$warn_log")"; rm -f "$warn_log"
  # 보존 우선 — WEBHOOK_SECRET 는 dotenv 값
  assert_eq "dotenv_value" "$WEBHOOK_SECRET" "dotenv 보존 실패" || { rm -f "$tmp_env"; return; }
  # warn 메시지 포함 확인
  assert_contains "$stderr_out" "rotate-webhook-secret" \
    "warn 메시지에 --rotate-webhook-secret 안내 없음" && pass
  rm -f "$tmp_env"
)

# F5-2 — .env 값과 env-var 같을 때 warn 없음 (불필요한 경고 방지)
it "F5-2 .env 값과 WEBHOOK_SECRET 환경변수 같으면 warn 없음"
(
  setup_install_env
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  printf 'WEBHOOK_SECRET=same_value\n' > "$tmp_env"
  ROTATE_WEBHOOK_SECRET=false
  WEBHOOK_SECRET="same_value"   # 동일 값
  warn_log="$(mktemp)"
  resolve_webhook_secret >"$warn_log" 2>&1
  out="$(cat "$warn_log")"; rm -f "$warn_log"
  assert_not_contains "$out" "rotate-webhook-secret" \
    "같은 값인데 warn 발생" && pass
  rm -f "$tmp_env"
)

# F5-3 — env-var 미제공 시 warn 없음 (조용히 보존)
it "F5-3 WEBHOOK_SECRET 환경변수 미제공 시 warn 없음"
(
  setup_install_env
  tmp_env="$(mktemp)"; ENV_FILE="$tmp_env"
  printf 'WEBHOOK_SECRET=dotenv_only\n' > "$tmp_env"
  ROTATE_WEBHOOK_SECRET=false
  unset WEBHOOK_SECRET
  warn_log="$(mktemp)"
  resolve_webhook_secret >"$warn_log" 2>&1
  out="$(cat "$warn_log")"; rm -f "$warn_log"
  assert_not_contains "$out" "rotate-webhook-secret" \
    "env-var 없는데 warn 발생" || { rm -f "$tmp_env"; return; }
  # unset 후 resolve_webhook_secret 가 WEBHOOK_SECRET 를 채웠는지 확인
  # set -u 환경에서 안전하게 참조
  assert_eq "dotenv_only" "${WEBHOOK_SECRET:-__UNSET__}" "dotenv 보존 실패" && pass
  rm -f "$tmp_env"
)

# F5-4 — .env 없을 때 env-var 사용(경고 없이 정상)
it "F5-4 .env 없을 때 환경변수 WEBHOOK_SECRET 조용히 사용"
(
  setup_install_env
  ENV_FILE="$(mktemp -u)"   # 존재하지 않는 경로
  ROTATE_WEBHOOK_SECRET=false
  WEBHOOK_SECRET="env_only_secret"
  warn_log="$(mktemp)"
  resolve_webhook_secret >"$warn_log" 2>&1
  out="$(cat "$warn_log")"; rm -f "$warn_log"
  assert_eq "env_only_secret" "$WEBHOOK_SECRET" "env-var 미사용" || return
  assert_not_contains "$out" "rotate-webhook-secret" \
    ".env 없는데 rotate 경고 발생" && pass
)
