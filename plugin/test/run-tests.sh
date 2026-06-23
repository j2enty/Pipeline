#!/usr/bin/env bash
# run-tests.sh — plugin 셸 테스트 묶음 러너(aggregate).
#
# 목적:
#   plugin/ 아래 흩어진 standalone *.test.sh 들을 한 번에 실행해 CI 에서 강제한다.
#   테스트가 여러 디렉토리(skills/*/test, agents/test)에 분산돼 있고 새 테스트가
#   계속 추가되므로, 명시적 배열이 아니라 glob 재귀 수집으로 "새 테스트 자동 포함"을
#   보장한다(테스트가 silently 썩는 것 방지 — 이슈 #45).
#
#   각 테스트는 자체적으로 set·grep·exit 하는 독립 스크립트라, source 가 아니라
#   서브셸(별도 프로세스)로 실행해 한 테스트의 exit 가 러너를 끝내지 않게 격리한다.
#
# 수집 대상(정렬해 결정적 순서로 실행):
#   plugin/skills/*/test/*.test.sh
#   plugin/agents/test/*.test.sh
#
# 사용법:
#   plugin/test/run-tests.sh           # 전체
#   plugin/test/run-tests.sh config     # 이름에 config 포함만
#
# 종료 코드:
#   모든 테스트 통과 0, 하나라도 실패 1.
#   수집된 테스트가 0개여도 1 — 수집 실패(경로 오타·이동 등)를 "통과"로 오인하지 않기 위함.

set -uo pipefail

# plugin/ 루트 = 이 스크립트의 부모 디렉토리. 절대경로로 고정해 CWD 무관하게 동작.
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
else
  C_GREEN=''; C_RED=''; C_CYAN=''; C_NC=''
fi

filter="${1:-}"
TOTAL=0
FAILED=0

# 테스트 수집 — glob 재귀. nullglob 으로 매칭 0개면 패턴 리터럴이 아니라 빈 배열이 되게 한다.
# (nullglob 미설정 시 매칭 없으면 패턴 문자열 자체가 원소로 남아 "파일 없음" 오판 유발.)
shopt -s nullglob
RAW_TESTS=(
  "$PLUGIN_DIR"/skills/*/test/*.test.sh
  "$PLUGIN_DIR"/agents/test/*.test.sh
)
shopt -u nullglob

# 결정적 순서 — 줄 단위 정렬 후 배열로 되돌림.
# mapfile 은 bash 4+ 전용(macOS 기본 bash 3.2 에 없음)이라 while-read 로 채운다(이식성).
# 테스트 경로엔 개행이 없다고 가정(파일명에 개행 금지) — 안전.
TESTS=()
if [ "${#RAW_TESTS[@]}" -gt 0 ]; then
  while IFS= read -r line; do
    TESTS+=("$line")
  done < <(printf '%s\n' "${RAW_TESTS[@]}" | sort)
fi

printf "%b══ plugin 셸 테스트 묶음 ══%b\n" "$C_CYAN" "$C_NC"

# 수집 0개 = 에러. 빈 통과로 위장하지 않는다.
if [ "${#TESTS[@]}" -eq 0 ]; then
  printf "%b✗ 수집된 테스트가 없습니다 — 경로 확인: %s/{skills/*/test,agents/test}/*.test.sh%b\n" \
    "$C_RED" "$PLUGIN_DIR" "$C_NC" >&2
  exit 1
fi

for test_file in "${TESTS[@]}"; do
  base="$(basename "$test_file")"
  if [ -n "$filter" ]; then
    case "$base" in
      *"$filter"*) ;;
      *) continue ;;
    esac
  fi
  if [ ! -f "$test_file" ]; then
    printf "%b✗ 테스트 파일 없음: %s%b\n" "$C_RED" "$base" "$C_NC"
    FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); continue
  fi
  # 출력 라벨은 plugin/ 기준 상대경로 — 같은 base 이름(structure.test.sh 등)이 여러 개라 구분 필요.
  rel="${test_file#"$PLUGIN_DIR"/}"
  printf "\n%b── %s ──%b\n" "$C_CYAN" "$rel" "$C_NC"
  TOTAL=$((TOTAL + 1))
  # 서브셸 실행으로 exit 격리 — 한 테스트가 죽어도 다음 테스트 진행.
  if bash "$test_file"; then :; else FAILED=$((FAILED + 1)); fi
done

# filter 로 인해 한 건도 안 돌았으면(필터 오타 등) 알린다 — 빈 통과 오인 방지.
if [ "$TOTAL" -eq 0 ]; then
  printf "\n%b✗ 필터 '%s' 에 매칭된 테스트가 없습니다%b\n" "$C_RED" "$filter" "$C_NC" >&2
  exit 1
fi

printf "\n%b══════════════════════════════%b\n" "$C_CYAN" "$C_NC"
if [ "$FAILED" -eq 0 ]; then
  printf "%b전체 통과: %d개 스크립트%b\n" "$C_GREEN" "$TOTAL" "$C_NC"
  exit 0
else
  printf "%b실패: %d (총 %d개 스크립트)%b\n" "$C_RED" "$FAILED" "$TOTAL" "$C_NC"
  exit 1
fi
