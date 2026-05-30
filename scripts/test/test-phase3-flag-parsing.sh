#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Phase 3 — --rotate-webhook-secret / --reapply 플래그 파싱 검증 + 회귀.
# install.sh 의 인자 파서는 top-level 에서 실행되므로, 특정 인자로 source 해
# 플래그 전역변수가 올바로 set 되는지 확인한다.

# 플래그 미지정 시 기본값 false
it "Phase3 플래그 미지정 시 기본 false"
(
  export PATH="$STUBS_DIR:$PATH"
  # shellcheck disable=SC1090
  source "$INSTALL_SH" "" >/dev/null 2>&1 || true
  assert_eq "false" "$ROTATE_WEBHOOK_SECRET" "rotate 기본값" || return
  assert_eq "false" "$REAPPLY" "reapply 기본값" && pass
)

# --rotate-webhook-secret 지정 시 true
it "--rotate-webhook-secret 파싱 → true"
(
  export PATH="$STUBS_DIR:$PATH"
  # shellcheck disable=SC1090
  source "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" --rotate-webhook-secret >/dev/null 2>&1 || true
  assert_eq "true" "$ROTATE_WEBHOOK_SECRET" "rotate 미설정" && pass
)

# --reapply 지정 시 true
it "--reapply 파싱 → true"
(
  export PATH="$STUBS_DIR:$PATH"
  # shellcheck disable=SC1090
  source "$INSTALL_SH" "$FIXTURES_DIR/config-basic.yml" --reapply >/dev/null 2>&1 || true
  assert_eq "true" "$REAPPLY" "reapply 미설정" && pass
)

# 회귀: 알 수 없는 플래그는 여전히 exit 1
it "회귀: 알 수 없는 플래그는 exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  code=0
  bash "$INSTALL_SH" --bogus-flag >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "알 수 없는 플래그가 exit 1 아님" && pass
)

# 회귀: --env-file 값 누락 시 exit 1
it "회귀: --env-file 값 누락 exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  code=0
  bash "$INSTALL_SH" --env-file >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "--env-file 값누락 exit 1 아님" && pass
)

# 회귀: 위치인자 중복은 exit 1
it "회귀: 위치인자 중복 exit 1"
(
  export PATH="$STUBS_DIR:$PATH"
  code=0
  bash "$INSTALL_SH" a.yml b.yml >/dev/null 2>&1 || code=$?
  assert_eq "1" "$code" "위치인자 중복 exit 1 아님" && pass
)
