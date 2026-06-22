#!/usr/bin/env bash
# PostToolUse hook — 방금 편집/생성된 파일을 확장자에 따라 가볍게 검증한다.
#
# 동작 원리:
#   Claude Code 가 Edit/Write 직후 이 스크립트를 호출하며, tool 정보(JSON)를 stdin 으로 준다.
#   여기서 file_path 만 뽑아 확장자별로 린터를 돌린다.
#     *.sh                          → shellcheck (셸 문법·버그)
#     .github/workflows/*.yml|yaml  → actionlint (워크플로 + 내부 run 블록)
#     *.json                        → jq (JSON 유효성)
#
# 종료코드 규약(Claude Code):
#   exit 2  → stderr 가 Claude 에게 피드백됨(즉시 수정 유도). 검증 실패 시 사용.
#   exit 0  → 통과/스킵. 대상 아님·도구 미설치·실제 파일 아님이면 흐름을 막지 않는다.

set -u

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"

# 대상 경로가 없거나(예: 파일 없는 tool) 실제 파일이 아니면(삭제 등) 조용히 통과
[ -z "$file_path" ] && exit 0
[ -f "$file_path" ] || exit 0

case "$file_path" in
  *.sh)
    command -v shellcheck >/dev/null 2>&1 || exit 0
    # info 등급까지 잡되(따옴표 누락 SC2086 등 실버그), 의도적 관용구·오탐 잦은
    # 4종(SC2015 A&&B||C / SC2016 작은따옴표 / SC2030·SC2031 서브셸 변수)은 제외해 노이즈 억제
    if ! out="$(shellcheck -S info --exclude=SC2015,SC2016,SC2030,SC2031 "$file_path" 2>&1)"; then
      printf 'shellcheck 경고/오류 — %s\n%s\n' "$file_path" "$out" >&2
      exit 2
    fi
    ;;
  *.github/workflows/*.yml|*.github/workflows/*.yaml)
    command -v actionlint >/dev/null 2>&1 || exit 0
    if ! out="$(actionlint "$file_path" 2>&1)"; then
      printf 'actionlint 오류 — %s\n%s\n' "$file_path" "$out" >&2
      exit 2
    fi
    ;;
  *.json)
    command -v jq >/dev/null 2>&1 || exit 0
    if ! err="$(jq empty "$file_path" 2>&1)"; then
      printf '깨진 JSON — %s\n%s\n' "$file_path" "$err" >&2
      exit 2
    fi
    ;;
esac

exit 0
