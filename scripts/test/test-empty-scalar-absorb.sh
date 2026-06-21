#!/usr/bin/env bash
# test-empty-scalar-absorb.sh — 빈 스칼라 값이 다음 줄 키를 흡수하지 않는지(이중리뷰 버그).
#
# 배경: get_scalar/get_scalar_in 및 modules 블록의 area-id/ci 추출 정규식에서 값 앞
#   공백을 \s* 로 쓰면 python 의 \s 가 개행을 포함해, 값이 비면 다음 줄 키를 값으로
#   빨아들였다(예: 빈 area-id 가 다음 줄 ci-workflow-name 을 흡수 → legacy 폴백 깨짐).
#   수정: 값 앞 공백을 [ \t]* 로 바꿔 개행 비흡수.
#
# 검증(리더 parity 포함):
#   T-EA-1: 빈 modules.area-id → 다음 줄 키 비흡수 + legacy area-ids 맵 폴백
#           (install.sh CMD_AREA_ID_ALPHA == 리더 module.Alpha.area-id == legacyfallback)
#   T-EA-2: 빈 ci-workflow-name → 다음 줄 키 비흡수(빈 값)
#   T-EA-3: 채워진 area-id 는 그대로(Beta)
# shellcheck disable=SC2034

READER="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"

# T-EA-1: 빈 area-id → legacy 폴백 (install.sh ↔ 리더 parity)
it "T-EA-1 빈 area-id → 다음 줄 키 비흡수 + legacy 폴백 (install↔리더 parity)"
(
  setup_install_env "$FIXTURES_DIR/config-empty-scalar-absorb.yml"
  eval "$(parse_config 2>/dev/null)"
  # install.sh: Alpha area-id 비었으니 legacy 맵으로 폴백
  assert_eq "legacyfallback" "$CMD_AREA_ID_ALPHA" "install.sh: 빈 area-id 가 다음 줄 키 흡수/폴백 실패" || return
  # 리더: 동일 결과
  rval="$(PIPELINE_CONFIG="$FIXTURES_DIR/config-empty-scalar-absorb.yml" bash "$READER" module.Alpha.area-id 2>/dev/null)"
  assert_eq "legacyfallback" "$rval" "리더: 빈 area-id 폴백 실패" || return
  # 친화 키도 동일
  rval2="$(PIPELINE_CONFIG="$FIXTURES_DIR/config-empty-scalar-absorb.yml" bash "$READER" area-id.Alpha 2>/dev/null)"
  assert_eq "legacyfallback" "$rval2" "리더: area-id.Alpha 폴백 실패" && pass
)

# T-EA-2: 빈 ci-workflow-name → 비흡수(빈 값)
it "T-EA-2 빈 ci-workflow-name → 다음 줄 키 비흡수(빈 값)"
(
  setup_install_env "$FIXTURES_DIR/config-empty-scalar-absorb.yml"
  eval "$(parse_config 2>/dev/null)"
  # Alpha 의 ci 는 빈 값 — 다음 줄 strict-review-bot-check 를 흡수하면 안 됨
  assert_eq "" "$MODULE_0_CI" "install.sh: 빈 ci 가 다음 줄 키 흡수" || return
  rci="$(PIPELINE_CONFIG="$FIXTURES_DIR/config-empty-scalar-absorb.yml" bash "$READER" module.Alpha.ci-workflow-name 2>/dev/null)"
  assert_eq "" "$rci" "리더: 빈 ci 흡수" && pass
)

# T-EA-3: 채워진 area-id/ci 는 그대로 (Beta)
it "T-EA-3 채워진 area-id/ci 는 정상 (Beta)"
(
  setup_install_env "$FIXTURES_DIR/config-empty-scalar-absorb.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "beta-real" "$CMD_AREA_ID_BETA" "install.sh: Beta area-id 누락" || return
  assert_eq "Beta CI" "$MODULE_1_CI" "install.sh: Beta ci 누락" || return
  rb="$(PIPELINE_CONFIG="$FIXTURES_DIR/config-empty-scalar-absorb.yml" bash "$READER" module.Beta.area-id 2>/dev/null)"
  assert_eq "beta-real" "$rb" "리더: Beta area-id 누락" && pass
)
