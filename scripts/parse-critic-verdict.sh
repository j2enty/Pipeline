#!/usr/bin/env bash
# parse-critic-verdict.sh — "이번 critic 실행이 쓴 상태파일"의 verdict 를 결정적으로 파싱
#
# 배경:
#   critic verdict 는 머지/blocker 분기를 결정하므로 "현재 parent" 상태파일을 정확히 읽어야 한다.
#   이 로직은 원래 critic.yml "Critic verdict 파싱" step 에 인라인돼 있었으나, 캐노니컬 머지
#   경로(critic-dispatch.yml)가 verdict 를 안 읽고 무조건 머지하던 fail-open 구멍(#99)을 닫기
#   위해 한 곳으로 추출해 두 워크플로가 같은 fail-closed 부품을 공유한다. 추출은 "리팩터
#   (동작 불변)"다 — 아래 #9/#A/#B/#54 방어 로직은 원본과 100% 동일하게 보존한다.
#
# 사용법:
#   parse-critic-verdict.sh
#
# 환경변수(입력):
#   VERDICT_STATE_DIR      상태파일 디렉토리 (필수)
#   PARENT_URL             기대하는 parent issue URL (필수)
#   CRITIC_RUN_MARKER      critic 실행 직전 touch 된 marker 파일 경로 (#B stale 검증용)
#   REVIEW_STATE_SENTINEL  /review 가 자기 상태파일 절대경로를 기록한 sentinel (선택 — #9)
#   RESOLVE_SH             resolve-review-statefile.sh 경로
#                          (기본 './scripts/resolve-review-statefile.sh')
#
# 출력(stdout, 고정 계약 — 정확히 두 줄):
#   verdict=<pass|concerns|blocker|indeterminate>
#   state_file=<식별된 상태파일 절대경로 또는 빈값>
#
# 종료코드:
#   0  항상 (검증불능은 verdict=indeterminate 로 표현 — 셸 exit 로 신호하지 않는다)
#
# 진단 로그(::error 등)는 전부 stderr 로 낸다 — stdout 은 위 두 줄 계약만 담아야 하므로.

set -euo pipefail

VERDICT_STATE_DIR="${VERDICT_STATE_DIR:-}"
PARENT_URL="${PARENT_URL:-}"
CRITIC_RUN_MARKER="${CRITIC_RUN_MARKER:-}"
REVIEW_STATE_SENTINEL="${REVIEW_STATE_SENTINEL:-}"
RESOLVE_SH="${RESOLVE_SH:-./scripts/resolve-review-statefile.sh}"

# [이슈 #9 — 결정적 식별 + 추측매칭 폴백]
# 1순위: resolve-review-statefile.sh 가 있으면 그걸로 식별한다.
#   이 스크립트는 sentinel(이번 실행 /review 가 직접 기록한 절대경로)을 신뢰하고,
#   sentinel 이 없거나 무효이면 기존 추측매칭(.parent.url 정확매칭·단일강제)으로 폴백한다.
#   성공 시 STATE_FILE 절대경로를 stdout 1줄로 주고 exit 0, indeterminate 면 빈출력+exit 1.
# 2순위(폴백): resolve 스크립트가 없으면(구경로·미체크아웃) 인라인 추측매칭으로 식별한다.
#   → 회귀 0(스크립트 폴백과 동일 로직).
#
# 어느 경로든 결과는 "STATE_FILE(절대경로) + MATCH_COUNT(1=식별/0=indeterminate)"로 통일해
# 아래 marker(-nt) stale 검증 + verdict 읽기는 그대로 재사용한다.
# marker -nt 검증은 "어느 파일"과 별개의 방어(이번 실행이 그 파일을 새로 썼는지)라 계속 둔다.
MATCH_COUNT=0
STATE_FILE=""
if [ -f "$RESOLVE_SH" ]; then
  rc=0
  STATE_FILE="$(VERDICT_STATE_DIR="$VERDICT_STATE_DIR" PARENT_URL="$PARENT_URL" \
    REVIEW_STATE_SENTINEL="$REVIEW_STATE_SENTINEL" \
    bash "$RESOLVE_SH" critic)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$STATE_FILE" ]; then
    MATCH_COUNT=1
  else
    MATCH_COUNT=0
    STATE_FILE=""
  fi
else
  # 인라인 폴백 — .parent.url 정확매칭(jq) 단일강제. grep 부분매칭 금지
  # (issues/3 이 issues/30·issues/35 까지 잡는 문제 회피).
  if [ -d "$VERDICT_STATE_DIR" ]; then
    for f in "$VERDICT_STATE_DIR"/*.json; do
      [ -f "$f" ] || continue
      if [ "$(jq -r '.parent.url // empty' "$f" 2>/dev/null)" = "$PARENT_URL" ]; then
        MATCH_COUNT=$((MATCH_COUNT + 1))
        STATE_FILE="$f"
      fi
    done
  fi
fi

if [ "$MATCH_COUNT" -eq 1 ]; then
  # 정확히 1개 매칭 — 정상 흐름 후보. 단, "이번 실행이 쓴 파일"인지 marker 로 검증한다.
  #
  # [버그 #B 방어 — stale 상태파일 오신뢰 차단, fail-closed]
  # 매칭된 STATE_FILE 이 critic 실행 step 이 만든 marker 보다 "새것"(-nt)이어야
  # "이번 실행이 새로 쓴 verdict"로 신뢰할 수 있다. marker 보다 older 면 이전 critic
  # 실행이 남긴 stale 파일이고, 이번 실행이(버그/스키마 문제로) verdict 를 못 쓴 것이므로
  # 낡은 pass 로 머지되지 않게 indeterminate 로 강등한다.
  # marker 가 없으면(이론상 안 일어나지만 방어적으로) 검증 불능으로 처리한다.
  if [ -z "${CRITIC_RUN_MARKER:-}" ] || [ ! -e "$CRITIC_RUN_MARKER" ]; then
    echo "::error::critic verdict 검증 불능 — marker 파일 없음(critic 실행 step 미수행 의심). fail-closed 로 머지 차단." >&2
    CRITIC_VERDICT="indeterminate"
  elif [ ! "$STATE_FILE" -nt "$CRITIC_RUN_MARKER" ]; then
    echo "::error::critic verdict 검증 불능 — 매칭 상태파일($STATE_FILE)이 marker 보다 오래됨(stale). 이번 실행이 verdict 를 쓰지 않음. fail-closed 로 머지 차단." >&2
    CRITIC_VERDICT="indeterminate"
  else
    # 이번 실행이 쓴 파일 확정 — 그 파일의 verdict 를 읽는다.
    CRITIC_VERDICT=$(jq -r '.aggregate.verdict // empty' "$STATE_FILE" 2>/dev/null || echo "")
    # verdict 필드가 비어 있으면(스키마 손상 등) 검증 불능으로 강등 — fail-closed.
    if [ -z "$CRITIC_VERDICT" ]; then
      echo "::error::critic verdict 검증 불능 — 상태파일($STATE_FILE)에 .aggregate.verdict 없음/빈값" >&2
      CRITIC_VERDICT="indeterminate"
    fi
  fi
else
  # 0개 또는 2개+ — 검증 불능(indeterminate). 어느 머지 step 의 if 에도 안 걸려 머지 안 됨.
  echo "::error::critic verdict 검증 불능 — PARENT_URL($PARENT_URL) 매칭 상태파일 $MATCH_COUNT 개(0 또는 2개+). fail-closed 로 머지 차단." >&2
  CRITIC_VERDICT="indeterminate"
fi

# [버그 #A 방어 — verdict enum allowlist 정규화, GHA output 인젝션 차단]
# 비정상 multiline/임의 문자열이 GITHUB_OUTPUT(env-file 형식)을 깨거나 pass 로 오해석되지
# 않도록, 출력 "직전" allowlist 로 정규화한다. 화이트리스트 밖 값은 전부 indeterminate 로
# 흡수 → 출력은 항상 pass|concerns|blocker|indeterminate 중 하나.
# 비정상 값은 위 fail-closed 머지 차단 경로(if != pass/concerns/blocker)가 처리한다.
case "$CRITIC_VERDICT" in
  pass|concerns|blocker) ;;
  *) CRITIC_VERDICT="indeterminate" ;;
esac

# 고정 두 줄 출력 계약 — 호출자(composite action)가 이 두 줄만 파싱한다.
# [수정 4] STATE_FILE(식별된 경로)도 내보낸다 — concerns-merge step 이 재식별 없이
# 이 값을 재사용한다(TOCTOU 제거 + 일관성). indeterminate 경로에서 STATE_FILE 이 비었어도
# 다운스트림은 critic_verdict==concerns 일 때만 이 값을 쓰므로 안전하다.
printf 'verdict=%s\n' "$CRITIC_VERDICT"
printf 'state_file=%s\n' "$STATE_FILE"
