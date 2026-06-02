#!/usr/bin/env bash
# Phase B — plan critic config 파싱 테스트
# T-B0-1: plan 섹션 있는 config → 3개 변수 올바르게 파싱
# T-B0-2: plan 섹션 없는 config → 기본값 true 적용 (backward-compat)
# T-B0-3: false 값 파싱 정확성
# T-B0-4: anti-drift — install.sh sed_args에 4개 placeholder 존재
# T-B0-5: contract-doc-enabled 파싱 (false 명시 / 누락 시 기본 true)
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

# T-B0-4: anti-drift — install.sh sed_args에 4개 placeholder 모두 존재
it "T-B0-4 anti-drift: install.sh sed_args에 4개 PLAN placeholder 존재"
(
  grep -q '__PLAN_COMPLETENESS_CRITIC_ENABLED__' "$INSTALL_SH" || { fail "COMPLETENESS placeholder install.sh에 없음"; return; }
  grep -q '__PLAN_CONSISTENCY_CRITIC_ENABLED__'  "$INSTALL_SH" || { fail "CONSISTENCY placeholder install.sh에 없음"; return; }
  grep -q '__PLAN_CONSISTENCY_CRITIC_DUAL_MODEL__' "$INSTALL_SH" || { fail "DUAL_MODEL placeholder install.sh에 없음"; return; }
  grep -q '__PLAN_CONTRACT_DOC_ENABLED__' "$INSTALL_SH" || { fail "CONTRACT_DOC placeholder install.sh에 없음"; return; }
  pass
)

# T-B0-5: contract-doc-enabled 파싱 — 명시 false / 누락 시 기본 true
it "T-B0-5 contract-doc-enabled 파싱: 명시 false / 누락 시 기본 true"
(
  # plan 섹션 있는 config: contract-doc-enabled: false → 'false' 파싱
  setup_install_env "$FIXTURES_DIR/config-with-plan-section.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "false" "$CMD_PLAN_CONTRACT_DOC_ENABLED" "contract-doc-enabled false 파싱 실패" || return
  # plan 섹션 없는 config: 누락 → 기본 true
  setup_install_env "$FIXTURES_DIR/config-without-plan-section.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "true" "$CMD_PLAN_CONTRACT_DOC_ENABLED" "contract-doc-enabled 기본값 true 아님" && pass
)

# T-B0-6: get_plan_bool 견고성 (이중리뷰 Codex/Claude 지적)
#   ① 따옴표 boolean("false") → false (opt-out 이 조용히 무력화되면 안 됨)
#   ② plan 블록은 있으나 contract 키만 누락(레거시 업그레이드) → 기본 true
it "T-B0-6 get_plan_bool 견고성: quoted false=false / 레거시 키 누락=true"
(
  # ① 따옴표 값: contract-doc-enabled: "false" → 'false' 파싱돼야 함
  setup_install_env "$FIXTURES_DIR/config-plan-quoted-false.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "false" "$CMD_PLAN_CONTRACT_DOC_ENABLED" "따옴표 false 가 false 로 안 잡힘 (opt-out 무력화)" || return
  # ② plan 블록 존재 + contract 키만 누락 → 기본 true (기존 토글 값은 보존)
  setup_install_env "$FIXTURES_DIR/config-plan-no-contract.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "true" "$CMD_PLAN_CONTRACT_DOC_ENABLED" "레거시(contract 키 누락) 기본값 true 아님" || return
  assert_eq "true" "$CMD_PLAN_CONSISTENCY_CRITIC_ENABLED" "레거시에서 기존 토글 값 보존 실패" && pass
)

# T-B0-7: area-ids 파서가 인접한 plan 블록을 침범하지 않음 (선재 버그 회귀 잠금)
#   area-ids 뒤에 plan 이 인접하면, 콜론 뒤 개행 넘침으로 plan 자식을 빨아들여
#   정크 CMD_AREA_ID_PLAN emit + (값에 따옴표 있으면) eval 오염되던 문제.
it "T-B0-7 area-ids 파서: 인접 plan 블록 침범 안 함 + eval 오염 없음"
(
  setup_install_env "$FIXTURES_DIR/config-area-ids-plan-adjacent.yml"
  eval "$(parse_config 2>/dev/null)"
  # 실제 area 는 정상 파싱
  assert_eq "bk111" "$CMD_AREA_ID_BACKEND" "Backend area-id 파싱 실패" || return
  assert_eq "ad222" "$CMD_AREA_ID_ADMIN" "Admin area-id 파싱 실패" || return
  # plan 블록은 area 로 새지 않음 (정크 변수 없음)
  assert_eq "" "${CMD_AREA_ID_PLAN:-}" "정크 CMD_AREA_ID_PLAN 이 emit 됨 (area 파서 plan 침범)" || return
  # 단일따옴표 plan 값에도 eval 오염 없이 contract 정상 파싱
  assert_eq "false" "$CMD_PLAN_CONTRACT_DOC_ENABLED" "단일따옴표 contract 파싱/eval 오염" && pass
)
