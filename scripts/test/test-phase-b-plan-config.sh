#!/usr/bin/env bash
# Phase B — plan critic config 파싱 테스트
#
# P3.4 이관: plan critic 토글·area-id 파싱은 install.sh 의 parse_config 에서 제거되고
#   (슬래시커맨드 .tmpl 치환 방식 폐기), 런타임 리더(pipeline-config.sh)가 단일 SSOT 가
#   되었다. 따라서 이 파일도 install.sh 가 아니라 리더 기준으로 동일 동작을 고정한다.
#
# T-B0-1: plan 섹션 있는 config → 3개 토글 올바르게 파싱
# T-B0-2: plan 섹션 없는 config → 기본값 true 적용 (backward-compat)
# T-B0-3: false 값 파싱 정확성
# T-B0-5: contract-doc-enabled 파싱 (false 명시 / 누락 시 기본 true)
# T-B0-6: get_plan_bool 견고성 (따옴표 false / 레거시 키 누락 기본 true)
# T-B0-7: area-ids 파서가 인접 plan 블록을 침범하지 않음 (회귀 잠금)
# shellcheck disable=SC2034

READER="$REPO_ROOT/plugin/skills/plan/scripts/pipeline-config.sh"

# T-B0-1: plan 섹션 있는 config → 3개 토글 파싱
it "T-B0-1 plan 섹션 있는 config: 3개 critic 토글 파싱 (리더)"
(
  FIX="$FIXTURES_DIR/config-with-plan-section.yml"
  c="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.completeness-critic-enabled 2>/dev/null)"
  e="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.consistency-critic-enabled 2>/dev/null)"
  d="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.consistency-critic-dual-model 2>/dev/null)"
  assert_eq "true"  "$c" "completeness-critic-enabled 파싱 실패" || return
  assert_eq "false" "$e" "consistency-critic-enabled 파싱 실패" || return
  assert_eq "false" "$d" "consistency-critic-dual-model 파싱 실패" && pass
)

# T-B0-2: plan 섹션 없는 config → 기본값 true (backward-compat)
it "T-B0-2 plan 섹션 없는 config: 기본값 true 적용 (리더)"
(
  FIX="$FIXTURES_DIR/config-without-plan-section.yml"
  c="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.completeness-critic-enabled 2>/dev/null)"
  e="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.consistency-critic-enabled 2>/dev/null)"
  d="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.consistency-critic-dual-model 2>/dev/null)"
  assert_eq "true" "$c" "기본값 true 아님 (completeness)" || return
  assert_eq "true" "$e" "기본값 true 아님 (consistency)" || return
  assert_eq "true" "$d" "기본값 true 아님 (dual-model)" && pass
)

# T-B0-3: false 값 파싱 정확성 (config-with-plan-section 에서 false 항목 확인)
it "T-B0-3 false 값 파싱 정확성 (리더)"
(
  FIX="$FIXTURES_DIR/config-with-plan-section.yml"
  e="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.consistency-critic-enabled 2>/dev/null)"
  d="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.consistency-critic-dual-model 2>/dev/null)"
  assert_eq "false" "$e" "false 파싱 안 됨" || return
  assert_eq "false" "$d" "false 파싱 안 됨 (dual)" && pass
)

# T-B0-5: contract-doc-enabled 파싱 — 명시 false / 누락 시 기본 true
it "T-B0-5 contract-doc-enabled 파싱: 명시 false / 누락 시 기본 true (리더)"
(
  WITH="$FIXTURES_DIR/config-with-plan-section.yml"
  WITHOUT="$FIXTURES_DIR/config-without-plan-section.yml"
  cf="$(PIPELINE_CONFIG="$WITH" bash "$READER" plan.contract-doc-enabled 2>/dev/null)"
  assert_eq "false" "$cf" "contract-doc-enabled false 파싱 실패" || return
  ct="$(PIPELINE_CONFIG="$WITHOUT" bash "$READER" plan.contract-doc-enabled 2>/dev/null)"
  assert_eq "true" "$ct" "contract-doc-enabled 기본값 true 아님" && pass
)

# T-B0-6: get_plan_bool 견고성
#   ① 따옴표 boolean("false") → false (opt-out 이 조용히 무력화되면 안 됨)
#   ② plan 블록은 있으나 contract 키만 누락(레거시 업그레이드) → 기본 true
it "T-B0-6 get_plan_bool 견고성: quoted false=false / 레거시 키 누락=true (리더)"
(
  QF="$FIXTURES_DIR/config-plan-quoted-false.yml"
  qf="$(PIPELINE_CONFIG="$QF" bash "$READER" plan.contract-doc-enabled 2>/dev/null)"
  assert_eq "false" "$qf" "따옴표 false 가 false 로 안 잡힘 (opt-out 무력화)" || return
  NC="$FIXTURES_DIR/config-plan-no-contract.yml"
  nc="$(PIPELINE_CONFIG="$NC" bash "$READER" plan.contract-doc-enabled 2>/dev/null)"
  assert_eq "true" "$nc" "레거시(contract 키 누락) 기본값 true 아님" || return
  ne="$(PIPELINE_CONFIG="$NC" bash "$READER" plan.consistency-critic-enabled 2>/dev/null)"
  assert_eq "true" "$ne" "레거시에서 기존 토글 값 보존 실패" && pass
)

# T-B0-7: area-id 파서가 인접 plan 블록을 침범하지 않음 (회귀 잠금)
#   area-ids 뒤에 plan 이 인접해도 area resolve 가 plan 자식을 빨아들이지 않고,
#   plan 토글은 정상 파싱돼야 한다.
it "T-B0-7 area-id 파서: 인접 plan 블록 침범 안 함 (리더)"
(
  FIX="$FIXTURES_DIR/config-area-ids-plan-adjacent.yml"
  # 실제 area 는 정상 파싱
  bk="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.Backend 2>/dev/null)"
  ad="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.Admin 2>/dev/null)"
  assert_eq "bk111" "$bk" "Backend area-id 파싱 실패" || return
  assert_eq "ad222" "$ad" "Admin area-id 파싱 실패" || return
  # plan 블록은 area 로 새지 않음 + 단일따옴표 plan 값도 정상 파싱
  cf="$(PIPELINE_CONFIG="$FIX" bash "$READER" plan.contract-doc-enabled 2>/dev/null)"
  assert_eq "false" "$cf" "단일따옴표 contract 파싱 실패(area 파서 plan 침범 의심)" && pass
)
