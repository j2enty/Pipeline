#!/usr/bin/env bash
# ask-model-injection.test.sh — ask.md codex 분기의 모델·effort 주입 셸 계약 회귀 가드 (#83).
#
# 배경:
#   ask.md 는 LLM 이 수행하는 에이전트라 프롬프트 파싱 상단은 테스트로 못 박지만,
#   codex 분기의 셸 조각
#       codex exec ${MODEL:+-c model="$MODEL"} ${EFFORT:+-c model_reasoning_effort="$EFFORT"} "$REQUEST"
#   은 순수 셸이라 계약을 실행 기준으로 박제할 수 있다. code-reviewer 가 수동 검증한
#   안전성(빈값→플래그 소멸 / 공백값 단일 인자 / 주입 불가)을 회귀 가드로 남긴다.
#
# 검증 대상은 "인자 배열이 어떻게 구성되는가"이므로, codex 를 실제로 부르지 않고
# 동일 확장으로 argv 를 만들어(set --) 개수·내용·주입여부를 단언한다.
#
# 종료코드: 전부 통과 0, 하나라도 실패 1.

set -uo pipefail

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s — %s\n' "$1" "$2"; }

# ask.md 와 동일한 확장으로 argv 를 구성해 그대로 반환(개행 구분).
build_argv() {
  local MODEL="$1" EFFORT="$2" REQUEST="검증요청"
  set -- ${MODEL:+-c model="$MODEL"} ${EFFORT:+-c model_reasoning_effort="$EFFORT"} "$REQUEST"
  printf '%s\n' "$#"        # 첫 줄 = 인자 개수
  printf '%s\n' "$@"        # 이후 = 각 인자
}

# 기대 인자 배열과 실제가 일치하는지 (개수 + 각 요소 정확 일치)
assert_argv() {
  local label="$1" model="$2" effort="$3"; shift 3
  local expected=("$@")
  local out; out="$(build_argv "$model" "$effort")"
  local got_n; got_n="$(printf '%s' "$out" | head -1)"
  local -a got=(); local i=0
  while IFS= read -r line; do [ "$i" -gt 0 ] && got+=("$line"); i=$((i+1)); done <<EOF
$out
EOF
  if [ "$got_n" != "$((${#expected[@]}))" ]; then
    bad "$label" "인자 개수 기대=${#expected[@]} 실제=$got_n"; return
  fi
  local j
  for j in "${!expected[@]}"; do
    if [ "${got[$j]:-}" != "${expected[$j]}" ]; then
      bad "$label" "인자[$j] 기대='${expected[$j]}' 실제='${got[$j]:-}'"; return
    fi
  done
  ok "$label"
}

# 1) 둘 다 빈값 → 플래그 완전 소멸(REQUEST 만 남음, 회귀 없음)
assert_argv "빈값이면 codex 플래그 미부착" "" "" "검증요청"

# 2) 모델만 지정 → -c model=<값> 두 인자 + REQUEST
assert_argv "모델만 지정" "gpt-5.5" "" "-c" "model=gpt-5.5" "검증요청"

# 3) 모델+effort 둘 다 → 네 인자 + REQUEST
assert_argv "모델+effort 둘 다" "gpt-5.5" "high" \
  "-c" "model=gpt-5.5" "-c" "model_reasoning_effort=high" "검증요청"

# 4) 공백 포함 값 → 단어분리 없이 단일 인자 유지
assert_argv "공백 포함 값 단일 인자 보존" "gpt 5 pro" "" "-c" "model=gpt 5 pro" "검증요청"

# 5) 셸 메타문자 주입 시도 → 리터럴 단일 인자(명령 실행 안 됨)
PWNED_MARK="$(mktemp -u)/PWNED"
assert_argv "주입 시도는 리터럴 처리" 'x"; touch '"$PWNED_MARK"'; "' "" \
  "-c" 'model=x"; touch '"$PWNED_MARK"'; "' "검증요청"
if [ -e "$PWNED_MARK" ]; then bad "주입 부작용 없음" "PWNED 파일이 생성됨: $PWNED_MARK"; rm -f "$PWNED_MARK"; else ok "주입 부작용 없음(PWNED 미생성)"; fi

# ── 결과 ──
printf '\n── 결과 ──\n통과 %d · 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo "전부 통과"; exit 0; } || { echo "실패 있음"; exit 1; }
