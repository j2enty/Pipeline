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
