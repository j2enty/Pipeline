#!/usr/bin/env bash
# test-quoted-hash-parity.sh — #57: config 따옴표 값 안 # 보존.
#
# 배경: modules 블록 전용 추출(name / ci-workflow-name / area-id / area-ids 맵)은 #52
#   에서 줄끝 인라인 주석((?:#.*)?$)을 허용했으나 값 캡처가 [^"#\n] 라 따옴표로 감싼 값
#   안의 # 까지 주석으로 오인해 잘랐다(`name: "a#b"` → 'a'). get_scalar_in 은 따옴표
#   분기가 있어 이미 보존했지만, install 의 module_blocks·area-ids 추출은 분기가 없었다.
#   수정: get_scalar_in 과 동일 철학으로 따옴표 분기(QUOTED_VALUE) 우선 + 무따옴표 폴백.
#
# 검증(install ↔ 리더 동일값):
#   T-QH-1: name 따옴표 안 # → 'a#b' (모듈 비소실, MODULE_COUNT=2)
#   T-QH-2: ci-workflow-name 따옴표 안 # → 'CI#1'
#   T-QH-3: modules area-id 따옴표 안 # → 'h#1'
#   T-QH-4: area-ids 맵 값 따옴표 안 # → 'v#1'
#   T-QH-5: 무따옴표 인라인 주석 무회귀(#52) — Plain ci='Plain CI', Legacy='lv1'
# shellcheck disable=SC2034

READER="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
FIX="$FIXTURES_DIR/config-quoted-hash.yml"

# T-QH-1: name 따옴표 안 # 보존 (모듈 비소실)
it "T-QH-1 name 따옴표 안 # → 'a#b' 보존 (install↔리더 parity)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "2" "$MODULE_COUNT" "install.sh: 따옴표 안 # name 소실(MODULE_COUNT)" || return
  assert_eq "a#b" "$MODULE_0_NAME" "install.sh: name 따옴표 안 # 잘림" || return
  rlist="$(PIPELINE_CONFIG="$FIX" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
  assert_eq "a#b,Plain," "$rlist" "리더: name 따옴표 안 # 잘림(--list-modules)" && pass
)

# T-QH-2: ci-workflow-name 따옴표 안 #
it "T-QH-2 ci-workflow-name 따옴표 안 # → 'CI#1' (install↔리더 parity)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "CI#1" "$MODULE_0_CI" "install.sh: ci 따옴표 안 # 잘림" || return
  rci="$(PIPELINE_CONFIG="$FIX" bash "$READER" "module.a#b.ci-workflow-name" 2>/dev/null)"
  assert_eq "CI#1" "$rci" "리더: ci 따옴표 안 # 잘림" || return
  assert_eq "$MODULE_0_CI" "$rci" "ci 따옴표 안 # parity 불일치" && pass
)

# T-QH-3: modules area-id 따옴표 안 # — area-id 파싱은 P3.4 에서 install.sh 에서 제거,
#   런타임 리더(pipeline-config.sh)가 단일 SSOT. 리더 기준으로만 검증.
it "T-QH-3 modules area-id 따옴표 안 # → 'h#1' (리더)"
(
  raid="$(PIPELINE_CONFIG="$FIX" bash "$READER" "module.a#b.area-id" 2>/dev/null)"
  assert_eq "h#1" "$raid" "리더: modules area-id 따옴표 안 # 잘림" && pass
)

# T-QH-4: area-ids 맵 값 따옴표 안 # — 리더 SSOT 기준 검증(install 제거).
it "T-QH-4 area-ids 맵 값 따옴표 안 # → 'v#1' (리더)"
(
  rfe="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.Frontend 2>/dev/null)"
  assert_eq "v#1" "$rfe" "리더: area-ids 맵 따옴표 안 # 잘림" && pass
)

# T-QH-5: 무따옴표 인라인 주석 무회귀(#52)
#   ci-workflow-name 은 install.sh 도 여전히 파싱(modules 블록) → install↔리더 둘 다 검증.
#   area-ids 맵은 P3.4 에서 install.sh 에서 제거 → 리더 기준으로만 검증.
it "T-QH-5 무따옴표 인라인 주석 무회귀(#52) — Plain ci / Legacy"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "Plain CI" "$MODULE_1_CI" "install.sh: 무따옴표 인라인 주석 ci 손상(#52 회귀)" || return
  rci="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Plain.ci-workflow-name 2>/dev/null)"
  assert_eq "Plain CI" "$rci" "리더: 무따옴표 인라인 주석 ci 손상(#52 회귀)" || return
  rlg="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.Legacy 2>/dev/null)"
  assert_eq "lv1" "$rlg" "리더: 무따옴표 인라인 주석 area-ids 손상(#52 회귀)" && pass
)
