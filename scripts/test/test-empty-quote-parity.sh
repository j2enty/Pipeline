#!/usr/bin/env bash
# test-empty-quote-parity.sh — #57 후속(Claude major): 빈 따옴표 '' / "" parity.
#
# 배경: QUOTED_VALUE 의 따옴표 분기가 +(1글자+)였을 때 빈 따옴표(''/"")가 분기 미매치 →
#   무따옴표 폴백 [^"#\n]+? 가 두 따옴표 `''` 자체를 캡처 → 리터럴 ''(2글자) 누출.
#   비대칭: install 은 QUOTED_VALUE 경로(리터럴 '' 출력), reader per-module 은 get_scalar_in
#   경로(빈값) → 다른 값. 다운스트림: 모듈 area-id '' (truthy) 가 legacy area-ids 폴백을
#   덮어써 가짜 '' 박힘(config 오염). 수정: 따옴표 분기 *(0글자+) + 폴백 그룹 .strip("'\"").
#
# 검증(install ↔ 리더 동일값, 둘 다 빈값/legacy — 리터럴 '' 아님):
#   T-EQ-1: 모듈 area-id: '' + legacy belegacy → 둘 다 belegacy ('' 가 legacy 안 덮음)
#   T-EQ-2: 모듈 ci-workflow-name: '' → 둘 다 빈값
#   T-EQ-3: 모듈 area-id: "" + legacy 없음 → 둘 다 빈값
#   T-EQ-4: area-ids 맵 K: '' / "" → 둘 다 빈값(리터럴 '' 아님)
#   T-EQ-5: 무회귀 — 채워진 따옴표값(Admin CI)·legacy(belegacy) 정상
# shellcheck disable=SC2034

READER="$REPO_ROOT/plugin/skills/kickoff/scripts/pipeline-config.sh"
FIX="$FIXTURES_DIR/config-empty-quote.yml"

# T-EQ-1: 모듈 area-id '' + legacy → legacy 폴백(install↔리더), '' 가 안 덮음
it "T-EQ-1 모듈 area-id: '' + legacy → belegacy ('' 가 legacy 안 덮음)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  # install: '' 는 falsy(빈문자열)라 module override 안 함 → legacy belegacy 유지
  assert_eq "belegacy" "${CMD_AREA_ID_BACKEND:-}" "install.sh: 빈 따옴표 area-id 가 legacy 를 덮음(config 오염)" || return
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Backend.area-id 2>/dev/null)"
  assert_eq "belegacy" "$rv" "리더: 빈 따옴표 area-id legacy 폴백 실패" || return
  assert_eq "${CMD_AREA_ID_BACKEND:-}" "$rv" "area-id '' 폴백 parity 불일치" && pass
)

# T-EQ-2: 모듈 ci-workflow-name '' → 빈값(리터럴 '' 아님)
it "T-EQ-2 모듈 ci-workflow-name: '' → 빈값 (install↔리더)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "" "$MODULE_0_CI" "install.sh: 빈 따옴표 ci 가 리터럴 '' 로 샘" || return
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Backend.ci-workflow-name 2>/dev/null)"
  assert_eq "" "$rv" "리더: 빈 따옴표 ci 가 리터럴 '' 로 샘" || return
  assert_eq "$MODULE_0_CI" "$rv" "ci '' parity 불일치" && pass
)

# T-EQ-3: 모듈 area-id "" + legacy 없음 → 빈값
it "T-EQ-3 모듈 area-id: \"\" + legacy 없음 → 빈값 (install↔리더)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "" "${CMD_AREA_ID_ADMIN:-}" "install.sh: 빈 이중따옴표 area-id 가 리터럴 로 샘" || return
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Admin.area-id 2>/dev/null)"
  assert_eq "" "$rv" "리더: 빈 이중따옴표 area-id" && pass
)

# T-EQ-4: area-ids 맵 K: '' / "" → 빈값(리터럴 '' 아님)
it "T-EQ-4 area-ids 맵 '' / \"\" → 빈값 (install↔리더)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  # 빈 area-ids 항목은 빈 문자열이므로 CMD_AREA_ID_KSINGLE 도 빈값으로 emit
  assert_eq "" "${CMD_AREA_ID_KSINGLE:-}" "install.sh: area-ids '' 가 리터럴 '' 로 샘" || return
  assert_eq "" "${CMD_AREA_ID_KDOUBLE:-}" "install.sh: area-ids \"\" 가 리터럴 로 샘" || return
  rs="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.KSingle 2>/dev/null)"
  rd="$(PIPELINE_CONFIG="$FIX" bash "$READER" area-id.KDouble 2>/dev/null)"
  assert_eq "" "$rs" "리더: area-id.KSingle '' 가 리터럴 로 샘" || return
  assert_eq "" "$rd" "리더: area-id.KDouble \"\" 가 리터럴 로 샘" && pass
)

# T-EQ-5: 무회귀 — 채워진 따옴표값/legacy 정상
it "T-EQ-5 무회귀 — 채워진 따옴표값(Admin CI)·legacy(belegacy)"
(
  setup_install_env "$FIX"
  eval "$(parse_config 2>/dev/null)"
  assert_eq "Admin CI" "$MODULE_1_CI" "install.sh: 채워진 따옴표 ci 손상" || return
  rv="$(PIPELINE_CONFIG="$FIX" bash "$READER" module.Admin.ci-workflow-name 2>/dev/null)"
  assert_eq "Admin CI" "$rv" "리더: 채워진 따옴표 ci 손상" && pass
)

# T-EQ-6: parse_config 의 raw stdout 직접 검사 — 빈 따옴표가 리터럴 '' 로 emit 되면 안 됨.
#   (주의: eval 경유 시 MODULE_0_CI='''' 는 bash 에서 빈 문자열로 collapse 돼 var 검사로는
#    리터럴 '' 누출이 가려진다. 그래서 raw 출력 라인을 직접 단언해 install 측 레드입증을 확보.)
it "T-EQ-6 빈 따옴표 → raw emit 가 리터럴 '' 아님 (eval collapse 우회 직접 검사)"
(
  setup_install_env "$FIX"
  raw="$(parse_config 2>/dev/null)"
  # Backend(MODULE_0) ci-workflow-name: '' → 정확히 MODULE_0_CI='' 여야 함(리터럴 '' = '''' 아님)
  ci_line="$(printf '%s\n' "$raw" | grep '^MODULE_0_CI=')"
  assert_eq "MODULE_0_CI=''" "$ci_line" "install.sh: 빈 따옴표 ci 가 raw 에서 리터럴 '' 로 누출" || return
  # area-ids KSingle: '' → CMD_AREA_ID_KSINGLE='' (리터럴 '' 아님)
  ks_line="$(printf '%s\n' "$raw" | grep '^CMD_AREA_ID_KSINGLE=')"
  assert_eq "CMD_AREA_ID_KSINGLE=''" "$ks_line" "install.sh: area-ids '' 가 raw 에서 리터럴 '' 로 누출" && pass
)

# T-EQ-7: 미종결 따옴표 모듈 — stderr 경고 + 정상 모듈 유지 (#57 minor, install↔리더 동작 일치)
it "T-EQ-7 미종결 따옴표 모듈 → stderr 경고 + 정상 모듈 유지"
(
  setup_install_env "$FIX"
  MW="$(mktemp)"
  printf 'project:\n  owner: O\nmodules:\n  - name: "ab\n  - name: Good\nmodules-ignore: []\n' > "$MW"
  CONFIG_FILE="$MW"
  err="$(parse_config 2>&1 >/dev/null)"
  printf '%s' "$err" | grep -q "모듈 name 파싱 실패" || { fail "install.sh: 미종결 따옴표 경고 누락" "stderr='$err'"; rm -f "$MW"; return; }
  eval "$(parse_config 2>/dev/null)"
  assert_eq "1" "$MODULE_COUNT" "install.sh: 미종결 따옴표 시 정상 모듈(Good) 수 어긋남" || { rm -f "$MW"; return; }
  assert_eq "Good" "$MODULE_0_NAME" "install.sh: 정상 모듈 누락" || { rm -f "$MW"; return; }
  rm -f "$MW"
  pass
)
