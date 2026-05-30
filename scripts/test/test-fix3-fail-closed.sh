#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Fix 3 — read_existing_repo_variable fail-closed + resolve_reviewer_bot_login_for_reapply 전파.
# gh 실패(exit≠0) / 깨진 JSON → exit 1 전파. 성공+키부재 → 빈 문자열(정상).

# F3-1 — gh 성공 + 키 존재 → 정상 값 반환
it "F3-1 gh 성공 + 키 존재 → 값 반환"
(
  setup_install_env
  export PATH="$STUBS_DIR:$PATH"
  export GH_STUB_VARLIST_TEST_ORG_MODULEA='[{"name":"PIPELINE_REVIEWER_BOT_LOGIN","value":"bot[bot]"}]'
  result="$(read_existing_repo_variable "test-org/ModuleA" "PIPELINE_REVIEWER_BOT_LOGIN" 2>/dev/null)"
  assert_eq "bot[bot]" "$result" "키 있을 때 값 반환 실패" && pass
)

# F3-2 — gh 성공 + 키 부재 → 빈 문자열 (exit 0, 정상 케이스)
it "F3-2 gh 성공 + 키 부재 → 빈 문자열(exit 0)"
(
  setup_install_env
  export PATH="$STUBS_DIR:$PATH"
  export GH_STUB_VARLIST_TEST_ORG_MODULEA='[]'
  rc=0
  result="$(read_existing_repo_variable "test-org/ModuleA" "PIPELINE_REVIEWER_BOT_LOGIN" 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "키 부재 시 exit 0 아님" || return
  assert_eq "" "$result" "키 부재 시 빈 문자열 아님" && pass
)

# F3-3 — gh 실패(exit 1) → exit 1 반환 (fail-closed)
it "F3-3 gh 실패(exit 1) → read_existing_repo_variable exit 1"
(
  setup_install_env
  export PATH="$STUBS_DIR:$PATH"
  export GH_STUB_VARLIST_FAIL_TEST_ORG_MODULEA=1
  rc=0
  read_existing_repo_variable "test-org/ModuleA" "PIPELINE_REVIEWER_BOT_LOGIN" >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "gh 실패 시 exit 1 아님" && pass
)

# F3-4 — 깨진 JSON → exit 1 반환 (fail-closed)
it "F3-4 깨진 JSON 응답 → read_existing_repo_variable exit 1"
(
  setup_install_env
  export PATH="$STUBS_DIR:$PATH"
  export GH_STUB_VARLIST_BROKEN_TEST_ORG_MODULEA=1
  rc=0
  read_existing_repo_variable "test-org/ModuleA" "PIPELINE_REVIEWER_BOT_LOGIN" >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "깨진 JSON 시 exit 1 아님" && pass
)

# F3-5 — gh 실패 시 reapply 전체가 exit 1 로 중단
it "F3-5 reapply 중 gh variable list 실패 → 스크립트 exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  # ModuleA 의 variable list 조회를 실패시킴
  export GH_STUB_VARLIST_FAIL_TEST_ORG_MODULEA=1
  unset REVIEWER_BOT_LOGIN
  code=0
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" --reapply --non-interactive \
    --env-file "$(mktemp -u)" >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "gh 실패 시 reapply exit 1 아님" && pass
)

# F3-6 — 깨진 JSON 시 reapply 전체가 exit 1 로 중단
it "F3-6 reapply 중 깨진 JSON 응답 → 스크립트 exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  export GH_STUB_VARLIST_BROKEN_TEST_ORG_MODULEA=1
  unset REVIEWER_BOT_LOGIN
  code=0
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" --reapply --non-interactive \
    --env-file "$(mktemp -u)" >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "깨진 JSON 시 reapply exit 1 아님" && pass
)

# ── Fix2: reviewer.enabled=false 시 조회 스킵 ───────────────────────────────

# F3-7 — reviewer.enabled=false + gh 실패 시뮬 + reapply → 중단 안 하고 정상 진행
# (reviewer 비활성이면 PIPELINE_REVIEWER_BOT_LOGIN 조회 자체를 건너뜀)
it "F3-7 reviewer.enabled=false + gh 실패 → reapply 정상 진행(reviewer variable만 스킵)"
(
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  # ModuleA variable list 실패 시뮬 — reviewer.enabled=false 면 이 실패가 무시돼야 함
  export GH_STUB_VARLIST_FAIL_TEST_ORG_MODULEA=1
  unset REVIEWER_BOT_LOGIN
  code=0
  # config-no-tracking.yml: reviewer.enabled=false
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-no-tracking.yml" --reapply --non-interactive \
    --env-file "$(mktemp -u)" >/dev/null 2>&1 || code=$?
  assert_eq "0" "$code" "reviewer=false 인데 gh 실패로 exit 1 (reviewer 조회 스킵 안 됨)" || return
  # PIPELINE_REVIEWER_BOT_LOGIN 은 등록 안 됨(_SKIP_ 처리)
  log="$(cat "$GH_LOG")"
  assert_not_contains "$log" "PIPELINE_REVIEWER_BOT_LOGIN" \
    "reviewer=false 인데 PIPELINE_REVIEWER_BOT_LOGIN 등록됨" || return
  # 나머지 variables 는 정상 등록
  assert_contains "$log" "PIPELINE_OWNER" "PIPELINE_OWNER 등록 안 됨" && pass
)

# F3-8 — reviewer.enabled=true + gh 실패 + reapply → 기존대로 fail-closed exit 1
it "F3-8 reviewer.enabled=true + gh 실패 → reapply fail-closed exit 1 유지"
(
  export PATH="$STUBS_DIR:$PATH"
  GH_LOG="$(mktemp)"; export GH_LOG
  export GH_STUB_VARLIST_FAIL_TEST_ORG_MODULEA=1
  unset REVIEWER_BOT_LOGIN
  code=0
  # config-basic.yml: reviewer.enabled=true
  bash "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" --reapply --non-interactive \
    --env-file "$(mktemp -u)" >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "reviewer=true + gh 실패인데 exit 1 아님" && pass
)
