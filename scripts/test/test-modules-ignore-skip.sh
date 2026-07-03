#!/usr/bin/env bash
# test-modules-ignore-skip.sh — 영역 레포 등록 루프의 modules-ignore 스킵 검증.
#
# 배경(#42): Design 을 의미론 표(--modules-table) 노출용으로 modules: 에 추가하면서,
#   modules-ignore: [Design] 와 양쪽에 존재하게 됐다. 등록 루프가 modules-ignore 를
#   안 거르면 Design 레포에 secret/variable/caller-yml/label 이 잘못 등록된다(회귀).
#   → is_ignored_module 로 걸러 기존 동작(Design 레포 등록 안 함)을 복원한다.
#
# 검증:
#   T-MI-1: is_ignored_module 정확매칭 — "Design" 은 ignored, "DesignSystem"·"design" 은 아님
#   T-MI-2: 빈 배열·파싱실패 → false(아무것도 제외 안 함, 안전 기본값)
#   T-MI-3: reclip config 등록 대상에서 Design 만 빠지고 나머지 5개 유지
# shellcheck disable=SC2034

# T-MI-1: is_ignored_module 정확매칭(부분일치·대소문자 거부)
it "T-MI-1 is_ignored_module 정확매칭: Design=ignored / DesignSystem·design=아님"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  MODULES_IGNORE_JSON='["Design"]'
  assert_exit 0 is_ignored_module "Design"        || return  # 멤버 → true(0)
  assert_exit 1 is_ignored_module "DesignSystem"  || return  # 부분일치 거부
  assert_exit 1 is_ignored_module "design"        || return  # 대소문자 구분
  assert_exit 1 is_ignored_module "Backend"       && pass    # 비멤버
)

# T-MI-2: 빈 배열 / 파싱 실패 → 아무것도 제외 안 함(false)
it "T-MI-2 빈배열·파싱실패 → false(안전 기본값)"
(
  setup_install_env "$FIXTURES_DIR/config-basic.yml"
  MODULES_IGNORE_JSON='[]';       assert_exit 1 is_ignored_module "Design" || return
  MODULES_IGNORE_JSON='not-json'; assert_exit 1 is_ignored_module "Design" || return
  MODULES_IGNORE_JSON='';         assert_exit 1 is_ignored_module "Design" && pass  # 미설정(빈)
)

# T-MI-3: reclip config — 등록 대상에서 Design 만 빠지고 5개 유지
it "T-MI-3 reclip 등록 대상: Design 제외, Backend/Admin/Frontend/iOS/Android 유지"
(
  setup_install_env "$REPO_ROOT/projects/reclip/pipeline-config.yml"
  eval "$(parse_config 2>/dev/null)"
  registered=""
  for i in $(seq 0 $((MODULE_COUNT - 1))); do
    nv="MODULE_${i}_NAME"; mname="${!nv}"
    is_ignored_module "$mname" && continue
    registered="$registered $mname"
  done
  registered="${registered# }"   # 선행 공백 제거
  assert_eq "Backend Admin Frontend iOS Android" "$registered" "등록 대상 목록 불일치" || return
  # Design 은 modules: 에는 있으되(MODULE_COUNT 6) 등록 대상엔 없음
  assert_eq "6" "$MODULE_COUNT" "MODULE_COUNT 가 6 아님(Design 이 modules 에 있어야 함)" || return
  assert_not_contains "$registered" "Design" "Design 이 등록 대상에 포함됨(회귀)" && pass
)

# T-MI-4: MODULES_JSON(App 폴러용)에서도 modules-ignore 제외 — 폴러 dispatch 정합성
#   status-poller 는 MODULES 에 든 모듈만 kickoff/review dispatch 대상으로 본다.
#   Design 을 MODULES 에 남기면 폴러가 dispatch 대상으로 오인 → 제외돼야 함.
it "T-MI-4 MODULES_JSON 에서 modules-ignore(Design) 제외"
(
  setup_install_env "$REPO_ROOT/projects/reclip/pipeline-config.yml"
  eval "$(parse_config 2>/dev/null)"
  assert_eq '["Backend","Admin","Frontend","iOS","Android"]' "$MODULES_JSON" "MODULES_JSON 에 Design 이 남음(폴러 오인)" || return
  assert_not_contains "$MODULES_JSON" "Design" "MODULES_JSON 에 Design 포함" && pass
)
