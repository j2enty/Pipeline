#!/usr/bin/env bash
# run-tests.sh — plan.md.tmpl 정적 분석 테스트 묶음 러너.
#
# 목적:
#   templates/claude-commands/test/ 아래의 standalone *.test.sh 들을 한 번에 실행한다.
#   각 테스트는 자체적으로 set·grep·exit 하는 독립 스크립트라, source 가 아니라
#   서브셸(별도 프로세스)로 실행해 한 테스트의 exit 가 러너를 끝내지 않게 격리한다.
#
# 사용법:
#   templates/claude-commands/test/run-tests.sh           # 전체
#   templates/claude-commands/test/run-tests.sh critic     # 이름에 critic 포함만
#
# 종료 코드: 모든 테스트 통과 0, 하나라도 실패 1.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

filter="${1:-}"
TOTAL=0
FAILED=0

# 실행할 테스트 목록 — 새 *.test.sh 추가 시 이 배열에 한 줄 추가.
TESTS=(
  "$TEST_DIR/dry-run-guard.test.sh"
  "$TEST_DIR/dry-run-guard.negative.test.sh"
  "$TEST_DIR/interview-structure.test.sh"
  "$TEST_DIR/critic-structure.test.sh"
)

printf "${C_CYAN}══ plan.md.tmpl 정적 분석 테스트 묶음 ══${C_NC}\n"

for test_file in "${TESTS[@]}"; do
  base="$(basename "$test_file")"
  if [ -n "$filter" ]; then
    case "$base" in
      *"$filter"*) ;;
      *) continue ;;
    esac
  fi
  if [ ! -f "$test_file" ]; then
    printf "${C_RED}✗ 테스트 파일 없음: %s${C_NC}\n" "$base"
    FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); continue
  fi
  printf "\n${C_CYAN}── %s ──${C_NC}\n" "$base"
  TOTAL=$((TOTAL + 1))
  # 서브셸 실행으로 exit 격리 — 한 테스트가 죽어도 다음 테스트 진행.
  if bash "$test_file"; then :; else FAILED=$((FAILED + 1)); fi
done

printf "\n${C_CYAN}══════════════════════════════${C_NC}\n"
if [ "$FAILED" -eq 0 ]; then
  printf "${C_GREEN}전체 통과: %d개 스크립트${C_NC}\n" "$TOTAL"
  exit 0
else
  printf "${C_RED}실패: %d (총 %d개 스크립트)${C_NC}\n" "$FAILED" "$TOTAL"
  exit 1
fi
