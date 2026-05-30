#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Fix 2 — _SKIP_/빈값 가드가 reapply 전용으로 격리됐는지 검증.
# (a) 풀 install + reviewer 빈값 → PIPELINE_REVIEWER_BOT_LOGIN 등록(기존 동작 보존)
# (b) reapply + _SKIP_ → 등록 스킵(기존 T12 회귀)

# (a) 풀 install: REVIEWER_BOT_LOGIN 빈 값이어도 무조건 등록
it "F2-a 풀 install + REVIEWER_BOT_LOGIN 빈값 → PIPELINE_REVIEWER_BOT_LOGIN 등록"
(
  setup_install_env
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG

  # register_variables 직접 호출 (is_reapply=false = 기본값)
  eval "$(parse_config)"
  VERDICT_DIR=".omc/state/reviews"
  REVIEWER_BOT_LOGIN=""   # 빈 값 — 풀 install 에서 reviewer.enabled=false 케이스

  register_variables "test-org/ModuleA" "ModuleA CI" "true" "false" >/dev/null 2>&1

  log="$(cat "$GH_LOG")"
  # 빈 값이라도 PIPELINE_REVIEWER_BOT_LOGIN 은 set 돼야 함 (기존 동작)
  assert_contains "$log" "PIPELINE_REVIEWER_BOT_LOGIN" \
    "풀 install 에서 PIPELINE_REVIEWER_BOT_LOGIN 등록 안 됨(회귀)" && pass
)

# (b) reapply + _SKIP_ → 등록 스킵
it "F2-b reapply + REVIEWER_BOT_LOGIN=_SKIP_ → PIPELINE_REVIEWER_BOT_LOGIN 스킵"
(
  setup_install_env
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG

  eval "$(parse_config)"
  VERDICT_DIR=".omc/state/reviews"
  REVIEWER_BOT_LOGIN="_SKIP_"

  register_variables "test-org/ModuleA" "ModuleA CI" "true" "true" >/dev/null 2>&1

  log="$(cat "$GH_LOG")"
  assert_not_contains "$log" "PIPELINE_REVIEWER_BOT_LOGIN" \
    "reapply + _SKIP_ 인데 등록됨" || return
  # 다른 variables 는 여전히 등록됨
  assert_contains "$log" "PIPELINE_OWNER" "PIPELINE_OWNER 등록 안 됨" && pass
)

# (c) reapply + REVIEWER_BOT_LOGIN 빈 값 → 등록 스킵
it "F2-c reapply + REVIEWER_BOT_LOGIN 빈값 → PIPELINE_REVIEWER_BOT_LOGIN 스킵"
(
  setup_install_env
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG

  eval "$(parse_config)"
  VERDICT_DIR=".omc/state/reviews"
  REVIEWER_BOT_LOGIN=""

  register_variables "test-org/ModuleA" "ModuleA CI" "true" "true" >/dev/null 2>&1

  log="$(cat "$GH_LOG")"
  assert_not_contains "$log" "PIPELINE_REVIEWER_BOT_LOGIN" \
    "reapply + 빈값 인데 등록됨" && pass
)
