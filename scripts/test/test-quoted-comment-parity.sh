#!/usr/bin/env bash
# test-quoted-comment-parity.sh — #52 이중리뷰 parity 구멍 2건.
#
# [Claude major] 따옴표 값 + 인라인 주석에서 리더↔install parity 깨짐:
#   get_scalar/get_scalar_in 따옴표 분기 `"([^"\n]*)"\s*$` 가 `key: "X"  # 주석` 에서
#   뒤 주석 때문에 매칭 실패 → 무따옴표 폴백이 첫 글자 `"` 로 빈 캡처 → 값 소실.
#   수정: 따옴표 분기 줄끝에 (?:#.*)?$ 허용(리더 3복제본 + install 양쪽).
# [Codex major] legacy area-ids 키 패턴 하이픈 미지원(install [A-Za-z0-9_]+ vs 리더 re.escape):
#   `Frontend-1: h` 가 install 에서 미매칭 → 리더와 비대칭. 수정: install 키 패턴 [^\s:#]+.
#
# 검증(install ↔ 리더 동일값):
#   T-QC-1: project.owner 따옴표+주석 → 동일값(RedOrg)
#   T-QC-2: slack-channel 따옴표 안 # 보존(대조군) → #blue-alerts
#   T-QC-3: project-name 따옴표+주석 → Blue Proj (리더 SSOT — install 측 파싱은 P3.4 제거)
#   T-QC-4: per-module ci-workflow-name 따옴표+주석 → Backend CI (리더 get_scalar_in 경로)
#   T-QC-5: per-module area-id 따옴표+주석 → be-mod (리더 SSOT — install 측 파싱은 P3.4 제거)
#   T-QC-6: 하이픈 area-ids 키 Frontend-1 → 리더 area-id.Frontend-1 (install 측 파싱은 P3.4 제거)
# shellcheck disable=SC2034

READER="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
FIX="$FIXTURES_DIR/config-quoted-comment-hyphen.yml"

# T-QC-1: owner 따옴표+주석 parity
it "T-QC-1 project.owner 따옴표+주석 → install↔리더 동일값"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "RedOrg" "$OWNER" "install.sh: owner 따옴표+주석 소실" || return
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" owner 2>/dev/null)"
  assert_eq "RedOrg" "$rv" "리더: owner 따옴표+주석 소실" || return
  assert_eq "$OWNER" "$rv" "owner parity 불일치" && pass
)

# T-QC-2: slack-channel 따옴표 안 # 보존(대조군)
it "T-QC-2 slack-channel 따옴표 안 # 보존(대조군) → install↔리더 동일값"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "#blue-alerts" "$SLACK_CHANNEL" "install.sh: 따옴표 안 # 손상" || return
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" slack-channel 2>/dev/null)"
  assert_eq "#blue-alerts" "$rv" "리더: 따옴표 안 # 손상" && pass
)

# T-QC-3: project-name 따옴표+주석 — project-name 파싱은 P3.4 에서 install.sh 에서 제거
#   (claude-commands 블록 제거). 런타임 리더가 단일 SSOT → 리더 기준으로만 검증.
it "T-QC-3 project-name 따옴표+주석 → 'Blue Proj' (리더)"
(
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" project-name 2>/dev/null)"
  assert_eq "Blue Proj" "$rv" "리더: project-name 따옴표+주석 소실" && pass
)

# T-QC-4: per-module ci-workflow-name 따옴표+주석 (리더 get_scalar_in 경로 / install module_blocks)
it "T-QC-4 ci-workflow-name 따옴표+주석 → install↔리더 동일값"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "Backend CI" "$MODULE_0_CI" "install.sh: ci 따옴표+주석 소실" || return
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Backend.ci-workflow-name 2>/dev/null)"
  assert_eq "Backend CI" "$rv" "리더: ci 따옴표+주석 소실" || return
  assert_eq "$MODULE_0_CI" "$rv" "ci-workflow-name parity 불일치" && pass
)

# T-QC-5: per-module area-id 따옴표+주석 — area-id 파싱은 P3.4 에서 install.sh 에서 제거,
#   런타임 리더가 단일 SSOT → 리더 기준으로만 검증.
it "T-QC-5 modules area-id 따옴표+주석 → 'be-mod' (리더)"
(
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Backend.area-id 2>/dev/null)"
  assert_eq "be-mod" "$rv" "리더: modules area-id 따옴표+주석 소실" && pass
)

# T-QC-6: 하이픈 area-ids 키 Frontend-1 — area-id 파싱은 P3.4 에서 install.sh 에서 제거,
#   런타임 리더가 단일 SSOT → 리더 기준으로만 검증.
it "T-QC-6 하이픈 area-ids 키 Frontend-1 → 'feh' (리더)"
(
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.Frontend-1 2>/dev/null)"
  assert_eq "feh" "$rv" "리더: area-id.Frontend-1 미매칭" && pass
)
