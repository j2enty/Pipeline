#!/usr/bin/env bash
# test-inline-comment.sh — modules 블록 추출의 인라인 주석 내성(#52).
#
# 배경: modules 블록 전용 추출(`- name:` / ci-workflow-name / area-id / legacy
#   area-ids 맵)은 값 뒤에 `"?(...)"?\s*$` 로 줄끝을 강제해, `- name: Backend  # 주석`
#   처럼 인라인 주석이 붙으면 `\s*$` 매칭이 실패 → 모듈/값이 통째로 사라졌다.
#   (install.sh 는 MODULE_COUNT 가 어긋남.) 수정: 값 캡처를 비탐욕(+?/*?)으로 바꾸고
#   줄끝 선택적 인라인 주석((?:#.*)?$)을 허용.
#
# 검증(install.sh ↔ 리더 parity):
#   T-IC-1: 인라인 주석 단 `- name:` 모듈이 사라지지 않음 — MODULE_COUNT/이름 정상
#   T-IC-2: 인라인 주석 단 ci-workflow-name 값 보존
#   T-IC-3: 인라인 주석 단 modules area-id 값 보존
#   T-IC-4: 인라인 주석 단 legacy area-ids 맵 값 보존(폴백)
#   각 항목 리더(--list-modules/module.*) 와 동일값 parity.
# shellcheck disable=SC2034

READER="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
FIX="$FIXTURES_DIR/config-inline-comment.yml"

# T-IC-1: name 인라인 주석 → 모듈 비소실 (MODULE_COUNT=2, Backend·iOS)
it "T-IC-1 인라인 주석 단 - name: 모듈 비소실 (install↔리더 parity)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "2" "$MODULE_COUNT" "install.sh: 인라인 주석 모듈 소실(MODULE_COUNT)" || return
  assert_eq "Backend" "$MODULE_0_NAME" "install.sh: Backend 이름 소실" || return
  assert_eq "iOS" "$MODULE_1_NAME" "install.sh: iOS 이름 소실" || return
  # 리더: --list-modules 가 둘 다 정의순으로
  rlist="$(PIPELINE_CONFIG="$FIX" bash "$READER" --list-modules 2>/dev/null | tr '\n' ',')"
  assert_eq "Backend,iOS," "$rlist" "리더: 인라인 주석 모듈 소실(--list-modules)" && pass
)

# T-IC-2: ci-workflow-name 인라인 주석 → 값 보존
it "T-IC-2 인라인 주석 단 ci-workflow-name 값 보존 (install↔리더 parity)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "Backend CI" "$MODULE_0_CI" "install.sh: 인라인 주석에서 ci 값 손실" || return
  rci="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Backend.ci-workflow-name 2>/dev/null)"
  assert_eq "Backend CI" "$rci" "리더: 인라인 주석에서 ci 값 손실" && pass
)

# T-IC-3: modules area-id 인라인 주석 → 값 보존
it "T-IC-3 인라인 주석 단 modules area-id 값 보존 (install↔리더 parity)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "be-mod" "$CMD_AREA_ID_BACKEND" "install.sh: 인라인 주석에서 area-id 손실" || return
  raid="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Backend.area-id 2>/dev/null)"
  assert_eq "be-mod" "$raid" "리더: 인라인 주석에서 modules area-id 손실" || return
  # 친화 키도 동일(modules 우선)
  raid2="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.Backend 2>/dev/null)"
  assert_eq "be-mod" "$raid2" "리더: area-id.Backend 인라인 주석 손실" && pass
)

# T-IC-4: legacy area-ids 맵 인라인 주석 → 값 보존(폴백)
it "T-IC-4 인라인 주석 단 legacy area-ids 맵 값 보존 (install↔리더 parity)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "fe-legacy" "$CMD_AREA_ID_FRONTEND" "install.sh: 인라인 주석에서 legacy area-id 손실" || return
  rfe="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.Frontend 2>/dev/null)"
  assert_eq "fe-legacy" "$rfe" "리더: area-id.Frontend 인라인 주석 손실(폴백)" && pass
)

# T-IC-5: strict-review-bot-check 인라인 주석(이미 안전한 \w+ 패턴) 정상 — false 보존
it "T-IC-5 strict-review-bot-check 인라인 주석 정상 (대조군)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "false" "$MODULE_0_STRICT" "install.sh: strict 인라인 주석 처리 실패" && pass
)
