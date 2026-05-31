#!/usr/bin/env bash
# 이 파일은 run-tests.sh 에서 source 된다.
# shellcheck disable=SC2034
# Fix 6 — info()/warn()/section() 이 stdout 이 아닌 stderr 로 출력하는지 검증.
# 근거: 커맨드치환($(...))으로 stdout 값을 캡처하는 함수가 내부에서 이들을
# 호출해도 캡처가 오염되지 않아야 한다(eval "$(parse_config)" 등 보호).

# F6-1 — info 는 stdout 에 안 나오고 stderr 로 감
it "F6-1 info() 는 stdout 비우고 stderr 로 출력"
(
  setup_install_env
  out="$( (info x) 2>/dev/null )"
  assert_eq "" "$out" "info 가 stdout 으로 샘" || return
  err="$( (info x) 2>&1 1>/dev/null )"
  assert_contains "$err" "x" "info 가 stderr 에 안 나옴" && pass
)

# F6-2 — warn 는 stdout 에 안 나오고 stderr 로 감
it "F6-2 warn() 는 stdout 비우고 stderr 로 출력"
(
  setup_install_env
  out="$( (warn y) 2>/dev/null )"
  assert_eq "" "$out" "warn 가 stdout 으로 샘" || return
  err="$( (warn y) 2>&1 1>/dev/null )"
  assert_contains "$err" "y" "warn 가 stderr 에 안 나옴" && pass
)

# F6-3 — section 는 stdout 에 안 나오고 stderr 로 감
it "F6-3 section() 는 stdout 비우고 stderr 로 출력"
(
  setup_install_env
  out="$( (section z) 2>/dev/null )"
  assert_eq "" "$out" "section 이 stdout 으로 샘" || return
  err="$( (section z) 2>&1 1>/dev/null )"
  assert_contains "$err" "z" "section 이 stderr 에 안 나옴" && pass
)
