#!/usr/bin/env bash
# Phase B — plan critic config 파싱 테스트
# T-B0-1: plan 섹션 있는 config → 3개 변수 올바르게 파싱
# T-B0-2: plan 섹션 없는 config → 기본값 true 적용 (backward-compat)
# T-B0-3: false 값 파싱 정확성
# T-B0-4: anti-drift — install.sh sed_args에 3개 placeholder 존재
# shellcheck disable=SC2034

# setup_install_env 가 CONFIG_FILE 을 세팅하므로, 같은 셸에서 parse_config 를
# 호출하면 그 config 가 파싱된다(parse_config 는 $CONFIG_FILE 을 읽음).
# 다른 테스트 파일과 동일한 패턴 — 별도 헬퍼 불필요.

# T-B0-1: plan 섹션 있는 config → 3개 변수 파싱
it "T-B0-1 plan 섹션 있는 config: 3개 critic 변수 파싱"
(
  setup_install_env "$FIXTURES_DIR/config-with-plan-section.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "true"  "$CMD_PLAN_COMPLETENESS_CRITIC_ENABLED" "completeness-critic-enabled 파싱 실패" || return
  assert_eq "false" "$CMD_PLAN_CONSISTENCY_CRITIC_ENABLED"  "consistency-critic-enabled 파싱 실패" || return
  assert_eq "false" "$CMD_PLAN_CONSISTENCY_CRITIC_DUAL_MODEL" "consistency-critic-dual-model 파싱 실패" && pass
)

# T-B0-2: plan 섹션 없는 config → 기본값 true (backward-compat)
it "T-B0-2 plan 섹션 없는 config: 기본값 true 적용"
(
  setup_install_env "$FIXTURES_DIR/config-without-plan-section.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "true" "$CMD_PLAN_COMPLETENESS_CRITIC_ENABLED"  "기본값 true 아님 (completeness)" || return
  assert_eq "true" "$CMD_PLAN_CONSISTENCY_CRITIC_ENABLED"   "기본값 true 아님 (consistency)" || return
  assert_eq "true" "$CMD_PLAN_CONSISTENCY_CRITIC_DUAL_MODEL" "기본값 true 아님 (dual-model)" && pass
)

# T-B0-3: false 값 파싱 정확성 (config-with-plan-section에서 false 항목 확인)
it "T-B0-3 false 값 파싱 정확성"
(
  setup_install_env "$FIXTURES_DIR/config-with-plan-section.yml"
  eval "$(parse_config 2>/dev/null)"
  # config-with-plan-section 에서 consistency=false, dual-model=false 로 설정
  assert_eq "false" "$CMD_PLAN_CONSISTENCY_CRITIC_ENABLED"  "false 파싱 안 됨" || return
  assert_eq "false" "$CMD_PLAN_CONSISTENCY_CRITIC_DUAL_MODEL" "false 파싱 안 됨 (dual)" && pass
)

# T-B0-4: anti-drift — install.sh sed_args에 3개 placeholder 모두 존재
it "T-B0-4 anti-drift: install.sh sed_args에 3개 PLAN placeholder 존재"
(
  grep -q '__PLAN_COMPLETENESS_CRITIC_ENABLED__' "$INSTALL_SH" || { fail "COMPLETENESS placeholder install.sh에 없음"; return; }
  grep -q '__PLAN_CONSISTENCY_CRITIC_ENABLED__'  "$INSTALL_SH" || { fail "CONSISTENCY placeholder install.sh에 없음"; return; }
  grep -q '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' "$INSTALL_SH" || { fail "DUAL_MODEL placeholder install.sh에 없음"; return; }
  pass
)
