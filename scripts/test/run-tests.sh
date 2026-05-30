#!/usr/bin/env bash
# 헬퍼 함수는 테스트 파일(source)에서 간접 호출되고, 일부 변수는
# source 한 install.sh 가 소비하므로 shellcheck 의 미사용 경고를 끈다.
# shellcheck disable=SC2034,SC2329
# run-tests.sh — install.sh 함수 단위 테스트 러너 (순수 bash, bats 의존 없음).
#
# 설계:
#   - install.sh 를 `source` 해 함수만 로드(main 가드 덕분에 부작용 없음).
#   - gh 호출은 scripts/test/stubs/gh 스텁이 PATH 로 가로채 $GH_LOG 에 기록.
#   - python3 는 실제 사용(secret 생성 등) — 출력의 형태/길이만 단언.
#
# 사용법:
#   scripts/test/run-tests.sh            # 전체 테스트
#   scripts/test/run-tests.sh phase2     # 이름에 phase2 포함된 테스트 파일만
#
# 종료 코드: 모든 테스트 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
INSTALL_SH="$REPO_ROOT/scripts/install.sh"
STUBS_DIR="$TEST_DIR/stubs"
export FIXTURES_DIR="$TEST_DIR/fixtures"
export REPO_ROOT INSTALL_SH

# ── 단언 카운터 ──────────────────────────────────────────────
# 각 테스트 파일은 서브셸에서 source 되므로(환경 격리) 카운터는
# 서브셸 경계를 넘지 못한다. 따라서 공유 결과파일에 append 하고
# 마지막에 집계한다. RESULTS_FILE 는 export 로 서브셸까지 전파.
RESULTS_FILE="$(mktemp)"; export RESULTS_FILE
CURRENT_TEST=""

# ── 색상 ─────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

# ── 테스트 등록 — 각 테스트 함수는 it() 로 시작 ─────────────────
it() {
  CURRENT_TEST="$1"
  CURRENT_FAILED=0
  printf 'RUN\n' >> "$RESULTS_FILE"
}

fail() {
  CURRENT_FAILED=1
  printf 'FAIL\n' >> "$RESULTS_FILE"
  printf "${C_RED}✗${C_NC} %s\n    %s\n" "$CURRENT_TEST" "$1" >&2
}

pass() {
  printf "${C_GREEN}✓${C_NC} %s\n" "$CURRENT_TEST"
}

# ── 단언 헬퍼 ────────────────────────────────────────────────
# 각 헬퍼는 실패 시 fail() 호출하고 1 반환 → 테스트 함수에서 return 으로 중단 가능.
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" != "$actual" ]; then
    fail "assert_eq 실패${msg:+ ($msg)}: expected='$expected' actual='$actual'"
    return 1
  fi
}

assert_ne() {
  local notexpected="$1" actual="$2" msg="${3:-}"
  if [ "$notexpected" = "$actual" ]; then
    fail "assert_ne 실패${msg:+ ($msg)}: 두 값이 같음='$actual'"
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "assert_contains 실패${msg:+ ($msg)}: '$needle' 미포함"; return 1 ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) fail "assert_not_contains 실패${msg:+ ($msg)}: '$needle' 포함됨"; return 1 ;;
    *) ;;
  esac
}

assert_file_absent() {
  local path="$1" msg="${2:-}"
  if [ -e "$path" ]; then
    fail "assert_file_absent 실패${msg:+ ($msg)}: 파일 존재함 '$path'"
    return 1
  fi
}

assert_file_present() {
  local path="$1" msg="${2:-}"
  if [ ! -e "$path" ]; then
    fail "assert_file_present 실패${msg:+ ($msg)}: 파일 없음 '$path'"
    return 1
  fi
}

# 명령 종료코드 단언 — assert_exit <expected-code> <command...>
assert_exit() {
  local expected="$1"; shift
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$expected" != "$actual" ]; then
    fail "assert_exit 실패: expected=$expected actual=$actual (cmd: $*)"
    return 1
  fi
}

# $GH_LOG 에서 특정 패턴 출현 횟수 카운트 — count_gh_log <패턴>
count_gh_log() {
  local pattern="$1" n
  [ -f "${GH_LOG:-/dev/null}" ] || { echo 0; return; }
  # grep -c 는 0 매치 시 "0" 출력 + exit 1 → 그대로 받고 빈 값만 0 보정
  n="$(grep -c -- "$pattern" "$GH_LOG" 2>/dev/null)"
  echo "${n:-0}"
}

# ── 테스트 컨텍스트 셋업 — install.sh 를 격리 환경에서 source ────────
# 각 테스트가 fresh GH_LOG·임시 .env 경로를 갖도록 보조.
# 사용 패턴(서브셸 안에서):
#   ( setup_install_env <config> ; ... 테스트 ... )
# PATH 에 스텁 prepend, GH_LOG 초기화, install.sh source.
setup_install_env() {
  local config="${1:-$FIXTURES_DIR/config-basic.yml}"
  export PATH="$STUBS_DIR:$PATH"
  export GH_LOG="${GH_LOG:-$(mktemp)}"
  : > "$GH_LOG"
  # install.sh 를 빈 위치인자로 source — main 가드로 main 미실행, 함수만 로드
  # shellcheck disable=SC1090
  source "$INSTALL_SH" "" >/dev/null 2>&1 || true
  # 테스트가 지정한 config 로 덮어쓰기
  CONFIG_FILE="$config"
}

# ── 러너 ─────────────────────────────────────────────────────
filter="${1:-}"
printf "${C_CYAN}══ install.sh 테스트 ══${C_NC}\n"

for test_file in "$TEST_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  base="$(basename "$test_file")"
  if [ -n "$filter" ]; then
    case "$base" in
      *"$filter"*) ;;
      *) continue ;;
    esac
  fi
  printf "\n${C_CYAN}── %s ──${C_NC}\n" "$base"
  # 각 테스트 파일은 서브셸에서 — 한 파일의 source(install.sh)·환경오염이
  # 다음 파일로 안 번지게 격리. 함수(it/assert_*)는 동일 프로세스라 상속됨.
  # shellcheck disable=SC1090
  ( source "$test_file" )
done

printf "\n${C_CYAN}══════════════════════════════${C_NC}\n"
tests_run="$(grep -c '^RUN$' "$RESULTS_FILE" 2>/dev/null)"; tests_run="${tests_run:-0}"
tests_failed="$(grep -c '^FAIL$' "$RESULTS_FILE" 2>/dev/null)"; tests_failed="${tests_failed:-0}"
rm -f "$RESULTS_FILE"
if [ "$tests_failed" -eq 0 ]; then
  printf "${C_GREEN}전체 통과: %d개${C_NC}\n" "$tests_run"
  exit 0
else
  printf "${C_RED}실패: %d (총 %d개 테스트)${C_NC}\n" "$tests_failed" "$tests_run"
  exit 1
fi
