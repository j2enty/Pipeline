#!/usr/bin/env bash
# test-empty-scalar-absorb.sh — 빈 스칼라 값이 다음 줄 키를 흡수하지 않는지(이중리뷰 버그).
#
# 배경: get_scalar/get_scalar_in 및 modules 블록의 area-id/ci 추출 정규식에서 값 앞
#   공백을 \s* 로 쓰면 python 의 \s 가 개행을 포함해, 값이 비면 다음 줄 키를 값으로
#   빨아들였다(예: 빈 area-id 가 다음 줄 ci-workflow-name 을 흡수 → legacy 폴백 깨짐).
#   수정: 값 앞 공백을 [ \t]* 로 바꿔 개행 비흡수.
#
# 검증(리더 parity 포함):
#   T-EA-1: 빈 modules.area-id → 다음 줄 키 비흡수 + legacy area-ids 맵 폴백 (리더 SSOT)
#   T-EA-2: 빈 ci-workflow-name → 다음 줄 키 비흡수(빈 값)
#   T-EA-3: 채워진 area-id/ci 는 그대로(Beta)
# 주의: area-id resolve 는 P3.4 에서 install.sh 에서 제거 → 리더가 단일 SSOT.
#   빈 스칼라 비흡수의 install 측 검증은 ci-workflow-name(여전히 install 파싱)로 유지.
# shellcheck disable=SC2034

READER="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"

# T-EA-1: 빈 area-id → legacy 폴백 (리더 SSOT)
it "T-EA-1 빈 area-id → 다음 줄 키 비흡수 + legacy 폴백 (리더)"
(
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
#   ci-workflow-name 은 install.sh 도 여전히 파싱 → install↔리더 둘 다 검증.
#   area-id 는 리더 SSOT 기준(install area 파싱 P3.4 제거).
it "T-EA-3 채워진 area-id/ci 는 정상 (Beta)"
(
  setup_install_env "$FIXTURES_DIR/config-empty-scalar-absorb.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "Beta CI" "$MODULE_1_CI" "install.sh: Beta ci 누락" || return
  rb="$(PIPELINE_CONFIG="$FIXTURES_DIR/config-empty-scalar-absorb.yml" bash "$READER" module.Beta.area-id 2>/dev/null)"
  assert_eq "beta-real" "$rb" "리더: Beta area-id 누락" && pass
)
